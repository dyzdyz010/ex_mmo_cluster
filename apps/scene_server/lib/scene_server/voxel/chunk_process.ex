defmodule SceneServer.Voxel.ChunkProcess do
  @moduledoc """
  Hot authoritative process for one leased voxel chunk.

  A chunk process owns scene-side chunk truth while its region lease is current.
  It can build snapshot payloads for subscribers and persist snapshots through
  DataService, which re-checks the world-issued write token before accepting the
  write.

  ## 进程身份与状态所有权（阶段3.1）

  本进程是 `{logical_scene_id, chunk_coord}` 的**唯一权威**，其身份注册进
  `SceneServer.Voxel.ChunkRegistry`（`Registry` `:unique`）。via-tuple 写进
  child_spec 的 `start` 参数，监督树重启天然去重——同 key 不会有第二个权威。

  状态所有权边界：

  * **ChunkProcess 拥有** voxel 真相（`storage`）、当前 lease、订阅者集合、
    异步持久化任务、per-region field worker 与 pending 事务 fence。
  * **ChunkDirectory 只是无状态 facade**：经注册表解析 pid 后转发调用，自身
    不持有任何 chunk 状态（无进程表）。
  * **ChunkSnapshotStore（DataService）是崩溃恢复的权威存储**：`init` 在
    lease 有效时无条件从它 hydrate，不再用 `Storage.empty` 兜底。

  ## init hydrate 不变式（阶段3.1）

  进程重启（崩溃恢复或监督树重建）后，`init` 的不变式是：

  1. 携带有效 lease 启动 → 无条件 `ChunkSnapshotStore.get_snapshot/2`：
     * `:loaded` —— 从持久化恢复 storage；
     * `:never_persisted` —— `:snapshot_not_found` 视为全新 chunk，用空
       storage（这是**唯一**允许空 storage 的合法分支）；
     * hydrate 失败（DB 不可达 / payload 损坏）→ 进入 `degraded` 态而非
       空跑，避免崩溃恢复静默丢数据。
  2. 不带 lease 启动 → `unauthorized` 态，不 hydrate、不持 lease，等待 World
     下发 lease 后才进入授权模拟。

  init 不再无条件 schedule 模拟 tick：只有授权（持有效 lease 且非 degraded）
  时才 schedule。

  ## 空闲驱逐 + 按需 tick（阶段2.4 voxel-storage-4）

  在阶段3 的 `:transient` + `terminate` + 注册化身份之上，本进程不再永久
  10Hz 空转，也不再永不回收：

  * **按需 tick**：模拟 tick 不再无条件每 100ms 重排。仅当
    `(有 simulator 且 dirty_bounds 非空)` 时 arm 下一个 tick；空闲态零 timer。
    写入路径（intent / commit / put_solid_block / field effect 等）产生 dirty
    时通过 `maybe_arm_simulation_tick/1` 显式补排一次。`init` 仅在已授权且
    “有 simulator 且 dirty” 时才 arm（全新空 chunk 不空转）。
  * **生命周期低频 timer**：lease 心跳 / 驱逐静默检查走独立的
    `@lifecycle_check_interval_ms`（默认 1s）节拍，**不是** 10Hz。
  * **驱逐显式状态机**：进程维护 `last_activity_ms`，任何外部活动（订阅 /
    授权写 / lease 应用 / 事务 / field region）刷新它。`:lifecycle_check`
    判定 chunk 空闲（无订阅 + 无 field region + 无 pending fence/commit +
    lease 失效或未持有 + 静默窗口已过）时，向 **ChunkDirectory facade**
    `cast {:request_evict, key, self()}`。
  * **退场所有权归 facade**：进程**不**自停。由 `ChunkDirectory` 在其单点
    串行 mailbox 里复核（与 `ensure_chunk` 同 lane，规避驱逐-ensure TOCTOU）：
    复核时若 chunk 又有订阅 / lease / fence 则取消驱逐；否则 **先 persist
    再 `DynamicSupervisor.terminate_child`**，注册项随进程退出由 Registry 摘除。
    facade 复核通过 `confirm_evict/1` 同步问 chunk“此刻是否仍空闲”，把
    “请求驱逐”与“真正终止”之间可能挤进来的活动窗口收口在 chunk 自身 mailbox。

  `tick_skipped` observe 不再每次空转刷日志：按 `@tick_skip_sample_n` 采样 +
  聚合计数，避免污染观测流。
  """

  use GenServer, restart: :transient

  alias DataService.Voxel.ChunkPendingTransactionStore
  alias DataService.Voxel.ChunkSnapshotStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkOccupancyTable
  alias SceneServer.Voxel.ChunkPersistPool
  alias SceneServer.Voxel.ChunkRegistry
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.Field.CircuitComponentAnalysis
  alias SceneServer.Voxel.Field.FieldCodec
  alias SceneServer.Voxel.Field.FieldRegion
  alias SceneServer.Voxel.Field.FieldTickSupervisor
  alias SceneServer.Voxel.Field.FieldTickWorker
  alias SceneServer.Voxel.Field.Kernels.CircuitCurrentKernel
  alias SceneServer.Voxel.Field.ParticipantProjection
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Phenomenon.Instance, as: PhenomenonInstance
  alias SceneServer.Voxel.SimulationTick
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  import Bitwise

  # Phase 5.E: 10 Hz simulation tick (100ms interval). 见
  # `docs/plans/2026-05-13-phase5e-simulation-tick-infrastructure.md` E-2。
  #
  # 阶段2.4：tick 改“按需 arm”。这仍是单次 tick 的间隔，但不再无条件每 100ms
  # 重排——只有 `(有 simulator 且 dirty)` 时才存在 timer（见
  # `maybe_arm_simulation_tick/1`）。空闲态下没有任何模拟 timer。
  @simulation_tick_interval_ms 100
  @auto_circuit_refresh_debounce_ms 50

  # 阶段2.4 空闲驱逐 + 生命周期低频节拍。
  #
  # * `@lifecycle_check_interval_ms` —— lease 心跳 / 空闲驱逐检查的独立低频
  #   timer 间隔（**不是** 10Hz）。无 fence / 无订阅时它也只是廉价地刷一下
  #   时间戳并判断静默窗口，远比 100ms 空转便宜。
  # * `@idle_evict_silence_ms` —— chunk 进入“可驱逐候选”所需的最小静默时长：
  #   最近一次外部活动距今超过它，且其它驱逐前置条件全部满足，才向 facade
  #   请求驱逐。取一个明显大于正常订阅抖动 / 短暂离开视野的保守值。
  @lifecycle_check_interval_ms 1_000
  @idle_evict_silence_ms 30_000

  # 阶段2.4：tick_skipped observe 采样。空转态（按需 tick 后基本不再触发，但
  # 保留兜底）只对每第 N 次 skip 发一条聚合 observe，避免刷日志。
  @tick_skip_sample_n 100

  # 阶段4 (2.2 world-2pc-6) prepared fence TTL 兜底参数。
  #
  # 统一 2PC 契约 #4：prepared fence 带基于 coordinator deadline 的 TTL。
  # 主路径是 World driver/reaper 主动清理孤儿事务；这里的 TTL 仅作兜底，
  # 处理 coordinator/driver 整体死亡导致 fence 永远收不到 commit/abort 的情况。
  #
  # 阶段2.4：fence 过期的周期检查节拍已并入 `@lifecycle_check_interval_ms`
  # （同一个低频 timer 承载 fence TTL + lease 心跳 + 空闲驱逐），不再单独排程。
  #
  # * `@default_fence_ttl_ms` —— 当 coordinator 未在 prepare 时显式下发
  #   `:fence_deadline_ms` 时，相对 `fenced_at_ms` 的默认存活时长。取一个
  #   明显大于正常事务往返（prepare→decision→commit）的保守值，避免误杀
  #   仍在进行中的事务。
  @default_fence_ttl_ms 30_000
  @fixed32_scale 65_536
  @temperature_attribute_name "temperature"
  @density_attribute_name "density"
  @specific_heat_capacity_attribute_name "specific_heat_capacity"
  @voxel_volume_cubic_meter 1.0
  @min_density 0.001
  @min_specific_heat_capacity 0.001

  @intent_option_keys [
    :cell_hash,
    :cell_version,
    :environment_index,
    :flags,
    :reject_occupied,
    :return_snapshot_payload
  ]

  # Wire sentinels for VoxelEditIntent (0x70) optimistic concurrency fields;
  # see docs/2026-04-10-线协议规范.md §13.6.1. Sentinel = "client did not pin a
  # baseline" → server skips the precondition check for that field.
  @expected_chunk_version_unspecified 0xFFFF_FFFF_FFFF_FFFF
  @expected_cell_hash_unspecified 0xFFFF_FFFF

  @doc """
  Returns the child spec used by `SceneServer.VoxelChunkSup`.

  阶段3.1：把进程身份 via-tuple（`ChunkRegistry.via/3`）写进 `start` 参数的
  name，使监督树重启天然去重。`restart: :transient`（来自 `use GenServer`）
  让正常退出 / lease 撤销不触发重启，崩溃才重启并经 `init` 从权威存储 hydrate。
  """
  def child_spec(opts) when is_list(opts) do
    # id 保持模块名：DynamicSupervisor 忽略 child id（去重由 ChunkRegistry
    # via-tuple 负责），而 ExUnit `start_supervised!/stop_supervised!(ChunkProcess)`
    # 仍按模块名解析。进程身份单主由注册表裁决，不依赖 child id。
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Starts one chunk process registered under its `{logical_scene_id, chunk_coord}`
  identity in `ChunkRegistry`.

  调用方一般不直接显式传 `:name`：身份 via-tuple 由 `:logical_scene_id` /
  `:chunk_coord` 推导。测试可传 `:chunk_registry` 指向隔离的 Registry。显式
  `:name`（向后兼容旧的具名启动）仍被尊重，但默认走注册化身份。
  """
  def start_link(opts) when is_list(opts) do
    {explicit_name, init_opts} = Keyword.pop(opts, :name)
    init_opts = Keyword.delete(init_opts, :chunk_registry)

    name = explicit_name || identity_name(opts)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  defp identity_name(opts) do
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    chunk_coord = coord!(Keyword.fetch!(opts, :chunk_coord))
    registry = Keyword.get(opts, :chunk_registry, ChunkRegistry.default_name())
    ChunkRegistry.via(logical_scene_id, chunk_coord, registry)
  end

  @doc "Applies the current region lease used for DataService writes."
  def apply_lease(server, lease, timeout \\ 5_000) do
    GenServer.call(server, {:apply_lease, normalize_lease(lease)}, timeout)
  end

  @doc """
  Loads a persisted snapshot into the hot chunk for migration prewarm.

  The load path does not write back to DataService. It is used by a target Scene
  before World cutover so the target chunk starts from the latest persisted
  version instead of an empty chunk. A stale snapshot never downgrades newer hot
  state.
  """
  def load_snapshot(server, attrs) do
    GenServer.call(server, {:load_snapshot, attrs})
  end

  @doc """
  Applies a World-authorized voxel write intent.

  The first supported intent writes one solid normal block into a macro cell.
  The write is atomic from the scene process point of view: the candidate
  snapshot is persisted through DataService's write-token fence first, and the
  hot chunk state plus subscriber snapshot fallback are updated only after that
  persistence succeeds.
  """
  def apply_intent(server, attrs) do
    GenServer.call(server, {:apply_intent, attrs})
  end

  @doc """
  Applies multiple World-authorized write intents to the same chunk atomically.

  The batch path is used by development seeding and migration helpers that need
  many cells to become visible together. The chunk process owns the hot storage
  mutation, persists exactly one fenced snapshot when anything changed, and
  pushes a snapshot fallback to current subscribers instead of a long delta list.
  """
  def apply_intents(server, attrs_list) when is_list(attrs_list) do
    GenServer.call(server, {:apply_intents, attrs_list}, 30_000)
  end

  @doc "Places a solid normal block and increments the chunk version."
  def put_solid_block(server, macro_index_or_coord, block, opts \\ []) do
    GenServer.call(server, {:put_solid_block, macro_index_or_coord, block, opts})
  end

  @doc """
  Writes a temperature value onto a solid voxel's authoritative attributes.

  This is the server-side effect behind the development heat skill: the request
  chooses a target voxel and a target Celsius value, but the resulting field is
  detected later by reading the voxel's effective `temperature` attribute.
  """
  @spec write_temperature_attribute(GenServer.server(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def write_temperature_attribute(server, attrs) when is_map(attrs) or is_list(attrs) do
    GenServer.call(server, {:write_temperature_attribute, attrs})
  end

  @doc """
  Injects heat energy into a solid voxel's authoritative temperature attribute.

  The request supplies joules, not a target Celsius value.  The chunk computes
  `ΔT = Q / (density * specific_heat_capacity * volume)` from the voxel's
  effective material attributes, writes the resulting temperature back to voxel
  truth, and lets FieldRuntime detect the abnormal value from storage.
  """
  @spec add_heat_energy_attribute(GenServer.server(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_heat_energy_attribute(server, attrs) when is_map(attrs) or is_list(attrs) do
    GenServer.call(server, {:add_heat_energy_attribute, attrs})
  end

  @doc """
  Applies field-kernel effects through this chunk's authoritative truth owner.

  Phase 7.D3 keeps `FieldTickWorker` side-effect free: workers may hand effects
  to the chunk, but only the chunk process mutates voxel truth or rejects the
  effect with an observable reason.
  """
  @spec apply_field_effects(GenServer.server(), [term()], map()) ::
          {:ok, map()} | {:error, term()}
  def apply_field_effects(server, effects, context \\ %{})
      when is_list(effects) and is_map(context) do
    GenServer.call(server, {:apply_field_effects, effects, context})
  end

  @doc """
  Subscribes a process to authoritative chunk updates.

  The subscriber is monitored and immediately receives the current snapshot
  payload. Legacy subscribers receive `{:voxel_chunk_snapshot_payload, payload}`;
  callers that pass `delivery_format: :envelope` receive
  `{:voxel_delivery_envelope, envelope}` with server-authoritative lease and
  chunk metadata.
  Pass `send_snapshot?: false`, or a matching `known_version`, to establish the
  subscription without re-sending a snapshot the caller already has.
  """
  def subscribe(server, subscriber, opts \\ []) when is_pid(subscriber) and is_list(opts) do
    GenServer.call(server, {:subscribe, subscriber, opts})
  end

  @doc "Removes a process subscription from this chunk."
  def unsubscribe(server, subscriber) when is_pid(subscriber) do
    GenServer.call(server, {:unsubscribe, subscriber})
  end

  @doc "Returns a decoded chunk snapshot map."
  def snapshot(server, request_id \\ 0) do
    GenServer.call(server, {:snapshot, request_id})
  end

  @doc "Returns the binary chunk snapshot payload used by the gate codec."
  def snapshot_payload(server, request_id \\ 0) do
    GenServer.call(server, {:snapshot_payload, request_id})
  end

  @doc """
  Reads authoritative occupancy for local macro/micro samples in this chunk.

  This is a read-only collision surface. The chunk process owns voxel truth;
  callers such as movement resolvers only submit local samples and consume the
  occupied subset returned here.
  """
  @spec collision_query(GenServer.server(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def collision_query(server, attrs, timeout \\ 5_000) when is_map(attrs) do
    GenServer.call(server, {:collision_query, attrs}, timeout)
  end

  @doc "Persists the current chunk through DataService's fenced snapshot store."
  def persist(server) do
    GenServer.call(server, :persist)
  end

  @doc """
  Blocks until background snapshot persistence tasks currently known by this
  chunk have finished.

  This is a CLI/test synchronization point for the hot-path split: subscribers
  can receive deltas before PostgreSQL has accepted the full snapshot.
  """
  def flush_persistence(server, timeout \\ 5_000) do
    GenServer.call(server, :flush_persistence, timeout)
  end

  @doc """
  Reserves a transaction fence for an upcoming voxel batch write.

  `intents` is a non-empty list of `apply_intent` payloads scoped to this chunk
  (every entry must agree on `:logical_scene_id` and `:chunk_coord` with the
  process state). The fence stores the normalized intent batch without
  applying it; while a fence is held, ad-hoc `apply_intent/2` /
  `apply_intents/2` for any other transaction is rejected. The transaction
  must use `commit_transaction/2` or `abort_transaction/2` to release the
  chunk. Re-preparing the same transaction with the same batch is idempotent
  and returns the original fence summary.

  Phase 3-bis: the fence row is also persisted into
  `voxel_chunk_pending_transactions` so that a Scene restart can reload the
  fence before the surrounding transaction reaches its commit decision.
  Persistence must succeed for prepare to accept the fence; on DB failure
  the call returns `{:error, :fence_persist_failed}` and the in-memory
  pending_fence is left untouched.

  `opts[:decision_version]` propagates the coordinator's `decision_version`
  into the persisted row for diagnostics. Defaults to 0; Phase 3-bis-3 wires
  the real value through `BuildTransactionApplier`.
  """
  def prepare_transaction(server, transaction_id, intents, opts \\ [])
      when is_binary(transaction_id) and is_list(intents) and is_list(opts) do
    GenServer.call(server, {:prepare_transaction, transaction_id, intents, opts})
  end

  @doc """
  Applies the previously fenced transaction intent batch and releases the fence.

  Returns the same shape as `apply_intents/2` so callers can publish the
  resulting snapshot payload. Calling commit on a chunk that does not hold the
  matching transaction fence returns `{:error, :transaction_not_prepared}`.
  """
  def commit_transaction(server, transaction_id) when is_binary(transaction_id) do
    GenServer.call(server, {:commit_transaction, transaction_id})
  end

  @doc """
  Releases the transaction fence without applying its intent.

  Idempotent: aborting a transaction that does not own the current fence (or
  any chunk that has no pending fence) returns `:ok`.
  """
  def abort_transaction(server, transaction_id) when is_binary(transaction_id) do
    GenServer.call(server, {:abort_transaction, transaction_id})
  end

  @doc """
  Phase 4 (D8):wipes every micro slot owned by `(object_id, part_id)` in
  this chunk. Iterates layers, clears matching mask bits, refreshes object
  refs, and persists. Idempotent — a chunk with no matching layers is a
  cheap no-op.

  `attrs` requires `:object_id` and `:part_id`.
  """
  def destroy_part(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:destroy_part, attrs})
  end

  @doc """
  Phase 4 (D9):drops any `ChunkObjectRef[]` entry pointing at the dead
  `object_id`. Defensive — `destroy_part` already cleared the layers and
  the next refresh removed the ChunkObjectRef.

  `attrs` requires `:object_id`.
  """
  def cleanup_object_refs(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:cleanup_object_refs, attrs})
  end

  @doc """
  Pushes a `ChunkInvalidate` payload to every subscriber and forgets them.

  Used when chunk ownership flips (migration cutover) or when the region is
  unassigned. The chunk process keeps its hot state — Gate / World decide
  whether to terminate the process — but it forgets the subscribers so later
  edits do not push stale snapshots / deltas back to clients that should be
  re-subscribing.

  `reason` accepts the byte values defined in
  `SceneServer.Voxel.Codec.invalidate_reason_name/1`.
  """
  def invalidate_subscribers(server, reason \\ 0x00)
      when is_integer(reason) and reason >= 0 and reason <= 0xFF do
    GenServer.call(server, {:invalidate_subscribers, reason})
  end

  @doc """
  Fan-out a pre-encoded `ObjectStateDelta` (0x6C) wire payload to every
  subscriber of this chunk process.

  Phase 4-bis (D1):this is the cast entry point used by `ObjectRegistry`
  after `lookup_chunk_pid/3` resolves a chunk pid for an affected coord.
  The caller is responsible for encoding the payload via
  `SceneServer.Voxel.Codec.encode_voxel_object_state_delta_payload/1` so
  the same binary can be reused across multiple subscriber sends.

  Cast(not call):the broadcast is fire-and-forget;the caller does not
  block on subscriber delivery. Subscribers receive
  `{:voxel_object_state_delta_payload, payload}` and forward it through
  the same gate-side pipeline used for ChunkDelta.
  """
  @spec push_object_state_delta_payload(GenServer.server(), binary()) :: :ok
  def push_object_state_delta_payload(server, payload) when is_binary(payload) do
    GenServer.cast(server, {:push_object_state_delta_payload, payload})
  end

  @doc """
  Phase 6: creates a new local FieldRegion bound to this chunk.

  Spawns a `SceneServer.Voxel.Field.FieldTickWorker` under
  `SceneServer.Voxel.Field.FieldTickSupervisor`. The worker independently
  schedules 10 Hz ticks and pushes 0x73 FieldRegionSnapshot payloads to
  this chunk via `push_field_snapshot_payload/2`.

  `attrs` is forwarded to `SceneServer.Voxel.Field.FieldRegion.new/1`
  with `:region_id` and `:lease_token` populated automatically.

  Returns `{:ok, region_id}` or `{:error, reason}`.
  """
  @spec create_field_region(GenServer.server(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def create_field_region(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:create_field_region, attrs})
  end

  @doc """
  Creates or reuses a `FieldRegion` for a stable source key.

  The `:source_key` is owned by the caller and should identify the abnormal
  source at the level where duplicates must collapse, for example
  `{:temperature, macro_index}`.  While the source's worker is alive, repeated
  calls return the existing region instead of spawning duplicate field workers.
  """
  @spec ensure_field_region(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def ensure_field_region(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:ensure_field_region, attrs})
  end

  @doc """
  Releases the active `FieldRegion` tracked under `source_key`.

  Reuses the normal field-destroy stop/fanout path and returns a structured
  lifecycle summary. Missing source keys become a no-op summary instead of an
  error so runtime cleanup can call this path unconditionally.
  """
  @spec release_field_region_source(GenServer.server(), term(), atom()) :: {:ok, map()}
  def release_field_region_source(server, source_key, destroy_reason \\ :explicit) do
    GenServer.call(server, {:release_field_region_source, source_key, destroy_reason})
  end

  @doc """
  Phase 6: destroys a FieldRegion by region_id. Stops the worker (if alive)
  and pushes a 0x74 FieldRegionDestroyed payload to subscribers.
  """
  @spec destroy_field_region(GenServer.server(), non_neg_integer()) :: :ok | {:error, term()}
  def destroy_field_region(server, region_id) when is_integer(region_id) do
    GenServer.call(server, {:destroy_field_region, region_id})
  end

  @doc """
  Phase 6: fan-out a pre-encoded FieldRegionSnapshot (0x73) payload to every
  subscriber. Called by FieldTickWorker each tick (GenServer.cast).
  """
  @spec push_field_snapshot_payload(GenServer.server(), binary()) :: :ok
  def push_field_snapshot_payload(server, payload) when is_binary(payload) do
    GenServer.cast(server, {:push_field_snapshot_payload, payload})
  end

  @doc """
  Phase 6: fan-out a pre-encoded FieldRegionDestroyed (0x74) payload to every
  subscriber. Called by FieldTickWorker on expiry / destroy.
  """
  @spec push_field_region_destroyed_payload(GenServer.server(), binary()) :: :ok
  def push_field_region_destroyed_payload(server, payload) when is_binary(payload) do
    GenServer.cast(server, {:push_field_region_destroyed_payload, payload})
  end

  @doc "Returns process state for CLI/debug inspection."
  def debug_state(server) do
    GenServer.call(server, :debug_state)
  end

  @doc """
  阶段2.4 空闲驱逐复核：由 `ChunkDirectory` 在收到本进程 `request_evict` 后
  同步调用，问 chunk“此刻是否仍空闲、可以被终止”。

  在 chunk 自身 mailbox 里重新评估驱逐前置条件（无订阅 / 无 field region /
  无 pending fence|commit / lease 失效或未持有 / 静默窗口仍过）。这一步把
  “请求驱逐 → 真正终止”之间可能挤进来的活动（如刚到达的订阅 / 写 / lease）
  收口在串行 mailbox 内：

  * `{:ok, :evicting}` —— 仍空闲，且**已先把当前 storage 持久化**（持有效
    lease 时）；facade 据此 `terminate_child`。
  * `{:cancel, reason}` —— 复核期间又活跃（或持久化失败），facade 取消本次
    驱逐，进程复用。

  持久化失败按 `{:cancel, {:persist_failed, _}}` 处理：宁可让进程多活一轮，
  也不在未落库时丢掉热状态。
  """
  @spec confirm_evict(GenServer.server()) ::
          {:ok, :evicting} | {:cancel, term()}
  def confirm_evict(server) do
    GenServer.call(server, :confirm_evict)
  end

  @impl true
  def init(opts) do
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    chunk_coord = coord!(Keyword.fetch!(opts, :chunk_coord))

    lease = normalize_optional_lease(Keyword.get(opts, :lease))

    # 阶段3.1 hydrate 不变式：lease 有效时无条件从权威存储 hydrate，区分
    # :loaded / :never_persisted；不再用 Storage.empty 作崩溃恢复的默认兜底。
    # 测试可通过 :storage 直接注入 hot storage，跳过 hydrate（仅测试构造用）。
    case resolve_init_storage(opts, logical_scene_id, chunk_coord, lease) do
      {:ok, storage, hydrate_status, mode} ->
        pending_fence =
          load_persisted_fence(storage.logical_scene_id, storage.chunk_coord, lease)

        simulators = resolve_simulators(opts)
        simulation_tick = SimulationTick.new(simulators)

        state =
          %{
            logical_scene_id: storage.logical_scene_id,
            chunk_coord: storage.chunk_coord,
            storage: storage,
            lease: lease,
            # 阶段3.1：进程授权态。
            # :authorized   —— 持有效 lease 且 hydrate 成功，可模拟/接受授权写。
            # :unauthorized —— 无 lease，等待 World 下发 lease。
            # :degraded     —— hydrate 失败，禁止空跑（保留崩溃前的持久化语义）。
            mode: mode,
            hydrate_status: hydrate_status,
            subscribers: %{},
            subscriber_monitors: %{},
            async_persists: %{},
            persist_waiters: [],
            pending_fence: pending_fence,
            # 阶段4 (4.5 voxel-storage-3) commit durable join：
            # %{persist_ref => commit_ack_meta}。一个 commit 在拿到 async
            # persist_ref 后不立即删 fence / 不立即 reply，而是登记到此处，
            # 等 `:async_snapshot_persist_finished` 成功（且 DB chunk_version
            # 已 >= 本次 commit version）才删 fence + reply {:ok}（durable-ack），
            # 失败 / Task :DOWN 则保留 fence + reply {:error, :persist_failed}。
            pending_commit_acks: %{},
            # 阶段4 (4.5 voxel-storage-3 / world-2pc 跨侧幂等)：本 chunk **最近一次
            # durable 提交**的 `%{transaction_id => commit_version}`。崩溃窗口
            # （scene 已 durable：fence 删、hot swap，但 world 尚未记该 participant
            # 的 durable-ack）下，world 重投递 commit 时 fence 已不在，普通路径会回
            # {:error, :transaction_not_prepared} → world 误判非 durable → 事务永久
            # :committing、reaper 无限重投递、scene 永远 {:error} → 跨侧 liveness 死锁。
            # 记录已 durable 的 (transaction_id, version) 后，对**已提交事务**的 commit
            # 重投递可幂等回 {:ok, durable?: true}，让 world 收到 durable-ack 闭环。
            # 持久化恢复无需带它：fence 已删意味着 DB 快照 chunk_version 已 >= commit
            # version，进程重启后 hydrate 自带最新版本，下面 commit 幂等路径会用 DB
            # 版本兜底确认。
            last_durable_commits: %{},
            # Phase 4 (D7):wired to ObjectRegistry / ChunkDirectory for damage
            # attribution and downstream destroy_part dispatch. Tests inject
            # stubbed names; production wiring uses module-named singletons.
            object_registry:
              Keyword.get(opts, :object_registry, SceneServer.Voxel.ObjectRegistry),
            chunk_directory:
              Keyword.get(opts, :chunk_directory, SceneServer.Voxel.ChunkDirectory),
            # Phase 5.E:per-chunk low-frequency simulation tick scheduler。
            simulation_tick: simulation_tick,
            # Phase 5.E:optional pull-mode邻 chunk 查询函数。默认 nil
            # （未配置时 simulator 拿到的 env.neighbor_lookup = nil）。
            simulation_neighbor_lookup: Keyword.get(opts, :simulation_neighbor_lookup, nil),
            # Phase 6: per-region FieldTickWorker tracking.
            # field_regions:        %{region_id => worker_pid}
            # field_region_monitors: %{monitor_ref => region_id}
            # field_region_sources: %{source_key => region_id}
            # field_region_source_keys: %{region_id => source_key}
            # field_region_cleanup_links: %{source_key => [%{chunk_coord:, region_id:}]}
            field_regions: %{},
            field_region_monitors: %{},
            field_region_sources: %{},
            field_region_source_keys: %{},
            field_region_cleanup_links: %{},
            # Phase 8: authority-owned physical phenomenon instances. Field
            # workers advance phenomena via effects; the chunk keeps lifecycle
            # records beside voxel truth.
            phenomenon_instances: %{},
            auto_circuit_refresh_pending?: false,
            # 阶段2.4 空闲驱逐状态机。
            # last_activity_ms —— 最近一次外部活动时间戳；驱逐静默窗口的基线。
            # tick_armed?      —— 当前是否已有一个 in-flight 模拟 tick timer。
            #                     按需 tick 用它去重，避免重复 send_after 叠加。
            # tick_skip_count  —— tick_skipped 采样聚合计数。
            # evict_requested? —— 已向 facade 发过 request_evict，等复核结果，
            #                     避免重复请求刷 facade mailbox。
            last_activity_ms: now_ms(),
            tick_armed?: false,
            tick_skip_count: 0,
            evict_requested?: false,
            # 阶段2.4：驱逐节拍 / 静默窗口可由 opts 覆盖（测试用短窗口；生产用
            # 默认保守值）。运行期常量，进 state 便于 handle_info 直接取。
            lifecycle_check_interval_ms:
              Keyword.get(opts, :lifecycle_check_interval_ms, @lifecycle_check_interval_ms),
            idle_evict_silence_ms:
              Keyword.get(opts, :idle_evict_silence_ms, @idle_evict_silence_ms),
            # 阶段5.2 (voxel-storage-1)：per-chunk 只读 occupancy 快照表名。chunk
            # 进程是唯一写者，在此建表并随每次授权写发布当前 storage 投影；移动碰撞
            # 读路径经 `ChunkOccupancyTable.read_snapshot/2` 直读这张表，不经本进程
            # mailbox（读写分离，落方块写不再 head-of-line block 碰撞读）。
            occupancy_table:
              ChunkOccupancyTable.ensure_table(storage.logical_scene_id, storage.chunk_coord)
          }

        # 阶段5.2：发布初始 occupancy 快照，使 hydrate 出的 storage 立即可被碰撞读
        # 直读（无需等第一次写）。
        ChunkOccupancyTable.publish(state.occupancy_table, state.storage)

        emit_init_hydrated(state)

        # 阶段2.4：init 不再无条件起 100ms 空转 timer。仅在已授权且“有
        # simulator 且 dirty”时 arm 一次模拟 tick；全新空 chunk / 未授权 /
        # degraded 都进入零 timer 空闲态。
        state = maybe_arm_simulation_tick(state)

        # 阶段4 (2.2)：无条件 schedule prepared fence TTL 周期检查。即便重启后
        # 从 DB reload 回一个 fence（load_persisted_fence），它的 deadline 也能
        # 在 coordinator/driver 死亡时被本兜底路径作废。计时器很轻（无 fence 时
        # 直接跳过），始终开启可避免“授权态切换”窗口里漏检。
        #
        # 阶段2.4：该低频 timer 同时承载 lease 心跳 + 空闲驱逐静默检查
        # （见 handle_info(:check_pending_fence_ttl)），是 chunk 唯一常驻 timer。
        schedule_fence_ttl_check(state)

        {:ok, state}
    end
  end

  # 阶段3.1：决定 init 时的 storage 来源 + 授权态。
  #
  # 1. 显式 `:storage`（仅测试构造）→ 直接采用，授权态由 lease 决定。
  # 2. 携带有效 lease → 从 ChunkSnapshotStore hydrate：
  #    * {:ok, snapshot}            → :loaded
  #    * :snapshot_not_found        → :never_persisted（合法空 storage，全新 chunk）
  #    * 其它错误（DB 不可达/损坏）  → :degraded（保留空 storage 但禁止模拟/写）
  # 3. 无 lease → :unauthorized，空 storage 占位，等 World 下发 lease。
  defp resolve_init_storage(opts, logical_scene_id, chunk_coord, lease) do
    case Keyword.fetch(opts, :storage) do
      {:ok, injected} ->
        storage = Storage.normalize!(injected)
        mode = if is_nil(lease), do: :unauthorized, else: :authorized
        {:ok, storage, :injected, mode}

      :error ->
        hydrate_init_storage(logical_scene_id, chunk_coord, lease)
    end
  end

  defp hydrate_init_storage(logical_scene_id, chunk_coord, nil) do
    # 无 lease：不读权威存储（无 token 也无权 hydrate），进未授权态占位。
    {:ok, Storage.empty(logical_scene_id, chunk_coord), :unauthorized, :unauthorized}
  end

  defp hydrate_init_storage(logical_scene_id, chunk_coord, _lease) do
    case safe_get_snapshot(logical_scene_id, chunk_coord) do
      {:ok, snapshot} ->
        case decode_prewarm_payload(snapshot.data) do
          {:ok, storage} ->
            {:ok, Storage.normalize!(storage), :loaded, :authorized}

          {:error, decode_reason} ->
            # 持久化行存在但 payload 损坏 → degraded，绝不静默用空 storage 服务。
            {:ok, Storage.empty(logical_scene_id, chunk_coord),
             {:degraded, {:snapshot_decode_failed, decode_reason}}, :degraded}
        end

      {:error, :snapshot_not_found} ->
        # 从未持久化过：合法的全新 chunk，空 storage 是正确初值。
        {:ok, Storage.empty(logical_scene_id, chunk_coord), :never_persisted, :authorized}

      {:error, reason} ->
        # DB 不可达等 → degraded，等待恢复后由后续 apply_lease 重新 hydrate。
        {:ok, Storage.empty(logical_scene_id, chunk_coord), {:degraded, reason}, :degraded}
    end
  end

  defp safe_get_snapshot(logical_scene_id, chunk_coord) do
    ChunkSnapshotStore.get_snapshot(logical_scene_id, chunk_coord)
  rescue
    exception -> {:error, {:hydrate_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:hydrate_exit, reason}}
  end

  # 阶段2.4：按需 arm 模拟 tick。仅当 (授权 + 有 simulator + dirty) 且当前没有
  # in-flight tick timer 时，才 send_after 一个 tick 并置 tick_armed?。空闲态
  # （未授权 / 无 simulator / 无 dirty）零 timer。tick_armed? 去重，保证同一
  # 时刻最多只有一个模拟 timer，避免写入路径与 tick handler 重复叠加。
  defp maybe_arm_simulation_tick(%{tick_armed?: true} = state), do: state

  defp maybe_arm_simulation_tick(%{mode: :authorized} = state) do
    if simulation_due?(state) do
      schedule_simulation_tick()
      %{state | tick_armed?: true}
    else
      state
    end
  end

  defp maybe_arm_simulation_tick(state), do: state

  # tick 实际有事可做的判定：有注册 simulator、dirty_bounds 非空、且 lease
  # 未失效。lease 失效时即便 dirty 也不该 arm（tick 只会 skip:lease_stale），
  # 让 lease-stale 的空闲 chunk 能停 timer 并进入可驱逐态，而不是永久空转。
  defp simulation_due?(%{simulation_tick: simulation_tick, storage: storage} = state) do
    SimulationTick.any_simulator?(simulation_tick) and
      not DirtyMacroBounds.empty?(storage.dirty_bounds) and
      not lease_stale?(state.lease)
  end

  defp emit_init_hydrated(state) do
    CliObserve.emit("voxel_chunk_init_hydrated", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        chunk_version: state.storage.chunk_version,
        mode: state.mode,
        hydrate_status: inspect(state.hydrate_status),
        has_lease?: not is_nil(state.lease)
      }
    end)
  end

  # 阶段3.1：apply_lease 后把 chunk 推进到授权态。
  #
  # * 已是 :authorized（init 时即带 lease 成功 hydrate）→ 刷新 lease 并**按需
  #   re-arm 模拟 tick**。
  # * :unauthorized / :degraded → 现在有了 lease，从权威存储重新 hydrate：
  #   - hydrate 成功（:loaded / :never_persisted）→ 转 :authorized 并补 tick；
  #   - 再次失败 → 保持 :degraded，不空跑（等下一次 lease/恢复重试）。
  #
  # 阶段2.4 liveness 修复（MAJOR 2）：已授权 chunk 的 lease 真正失效后
  # （expires_at_ms 过期 → lease_stale? → simulation_due? 停 arm、tick_armed?
  # 归零），World 续发新 lease 时必须 re-arm。否则 dirty+simulator 的 chunk 在
  # lease 续期后模拟永久停滞（simulation_due? 重新为真但没有任何路径把它拉起来），
  # 直到下一次写才恢复。maybe_arm_simulation_tick 由 tick_armed? 去重，故仍在
  # 跑的 chunk 续期是廉价 no-op；只有“停了的 due”会真正补排一个 tick。
  defp authorize_with_lease(%{mode: :authorized} = state, lease) do
    maybe_arm_simulation_tick(%{state | lease: lease})
  end

  defp authorize_with_lease(state, lease) do
    case hydrate_init_storage(state.logical_scene_id, state.chunk_coord, lease) do
      {:ok, storage, hydrate_status, :authorized} ->
        next_state = %{
          state
          | storage: storage,
            lease: lease,
            mode: :authorized,
            hydrate_status: hydrate_status
        }

        CliObserve.emit("voxel_chunk_authorized", fn ->
          %{
            logical_scene_id: next_state.logical_scene_id,
            chunk_coord: next_state.chunk_coord,
            chunk_version: next_state.storage.chunk_version,
            hydrate_status: inspect(hydrate_status),
            previous_mode: state.mode
          }
        end)

        # 阶段2.4：授权后按需 arm 一次模拟 tick（仅当有 simulator 且 dirty）。
        maybe_arm_simulation_tick(next_state)

      {:ok, _storage, hydrate_status, :degraded} ->
        CliObserve.emit("voxel_chunk_still_degraded", fn ->
          %{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            hydrate_status: inspect(hydrate_status),
            previous_mode: state.mode
          }
        end)

        %{state | lease: lease, mode: :degraded, hydrate_status: hydrate_status}
    end
  end

  # 阶段3.1：授权写路径（apply_intent/apply_intents/commit）成功落账即意味着
  # World 授予了权威。把通过直接 ChunkProcess API（绕过 facade.apply_lease）
  # 进来的写也提升为 :authorized，使后续模拟 tick 能跑。degraded 不在此提升
  # （它必须先重新 hydrate 成功，由 apply_lease 路径裁决）。
  defp promote_authorized_on_write(%{mode: :unauthorized} = state) do
    # 未授权进程在此首次拿到授权写：转 :authorized。模拟 tick 的按需 arm 由
    # 写路径末尾的 mark_activity/maybe_arm 统一负责，这里不直接 schedule。
    %{state | mode: :authorized}
  end

  defp promote_authorized_on_write(state), do: state

  defp resolve_simulators(opts) do
    case Keyword.fetch(opts, :simulators) do
      {:ok, simulators} when is_list(simulators) ->
        simulators

      :error ->
        Application.get_env(:scene_server, :voxel_simulators, [])
    end
  end

  defp schedule_simulation_tick do
    Process.send_after(self(), :simulation_tick, @simulation_tick_interval_ms)
  end

  # 阶段4 (2.2) + 阶段2.4：低频生命周期节拍（fence TTL + lease 心跳 + 空闲
  # 驱逐静默检查共用）。这是 chunk 的唯一常驻 timer。间隔可由 state 覆盖（测试
  # 短窗口）；init 首次排程时 state 已就绪，故统一从 state 取。
  defp schedule_fence_ttl_check(state) do
    Process.send_after(self(), :check_pending_fence_ttl, state.lifecycle_check_interval_ms)
    state
  end

  # 阶段2.4：刷新最近活动时间戳，并清掉“已请求驱逐”标记。任何外部触达
  # （订阅 / 授权写 / lease 应用 / 事务 / field region）都视为活动，重置静默
  # 窗口，使刚刚还活跃的 chunk 不会在下一个生命周期节拍被误驱。
  defp mark_activity(state) do
    %{state | last_activity_ms: now_ms(), evict_requested?: false}
  end

  # 阶段2.4：写路径收尾——刷新活动时间戳 + 按需 arm 模拟 tick。任何把 storage
  # 改 dirty 的授权写都应在 reply 前走它，使空闲态新产生的 dirty 能拉起一个
  # tick，而不依赖已被移除的 100ms 空转 timer。
  #
  # 阶段5.2 (voxel-storage-1)：同一收尾点**原子发布** occupancy 快照到 per-chunk
  # ETS 表。所有授权写路径（apply_intent/intents、commit、put_solid_block、field
  # effect、temperature/heat 等）都经本函数，因此 occupancy 读快照与权威 storage
  # 在每次写后即时收敛一致——读路径直读这张表，无需触达本进程 mailbox。
  defp post_write_lifecycle(state) do
    publish_occupancy_snapshot(state)

    state
    |> mark_activity()
    |> maybe_arm_simulation_tick()
  end

  # 阶段5.2：把当前 storage 的 occupancy 投影发布到 per-chunk ETS 表（一次
  # `:ets.insert`，O(1)）。table 缺失（极端：init 未建成 / 已 terminate）时静默跳过
  # ——读路径会回退到经 facade 的 ensure+直达慢路。
  defp publish_occupancy_snapshot(%{occupancy_table: table, storage: storage})
       when not is_nil(table) do
    ChunkOccupancyTable.publish(table, storage)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # occupancy_table 为 nil / 缺失（极端：init 未建成）—— 静默跳过，读路径走 ensure 兜底。
  defp publish_occupancy_snapshot(_state), do: :ok

  defp load_persisted_fence(logical_scene_id, chunk_coord, lease) do
    case ChunkPendingTransactionStore.get_fence(logical_scene_id, chunk_coord) do
      {:ok, persisted} ->
        if lease_matches_persisted?(lease, persisted) do
          # 阶段4 (2.2)：DB fence 行不带 deadline 列（持久化层是对侧文件，不扩
          # schema）。Scene 重启后原 coordinator deadline 已不可知，用
          # `fenced_at_ms + @default_fence_ttl_ms` 保守重建一个兜底 deadline，
          # 让孤儿事务最终能被本地 TTL 作废（主路径仍是 World reaper）。
          %{
            transaction_id: persisted.transaction_id,
            decision_version: persisted.decision_version,
            intents: persisted.intents,
            fenced_at_ms: persisted.fenced_at_ms,
            deadline_ms: persisted.fenced_at_ms + @default_fence_ttl_ms
          }
        else
          # Lease changed (epoch bumped, or chunk transferred to another
          # Scene instance) while a fence was outstanding. The persisted
          # fence is now an orphan; drop it both in memory and in the DB
          # so the chunk does not refuse fresh prepares.
          _ = ChunkPendingTransactionStore.delete_fence(logical_scene_id, chunk_coord)

          CliObserve.emit("voxel_chunk_pending_transaction_orphaned", fn ->
            %{
              logical_scene_id: logical_scene_id,
              chunk_coord: chunk_coord,
              persisted_owner_lease_id: persisted.owner_lease_id,
              persisted_owner_epoch: persisted.owner_epoch,
              current_lease: summarize_lease(lease),
              transaction_id: persisted.transaction_id
            }
          end)

          nil
        end

      {:error, :fence_not_found} ->
        nil

      {:error, reason} ->
        # Postgres unreachable / payload corrupt — start without a fence and
        # let the surrounding transaction replay path handle recovery.
        CliObserve.emit("voxel_chunk_pending_transaction_load_failed", fn ->
          %{
            logical_scene_id: logical_scene_id,
            chunk_coord: chunk_coord,
            reason: inspect(reason)
          }
        end)

        nil
    end
  end

  defp lease_matches_persisted?(nil, _persisted), do: false

  defp lease_matches_persisted?(lease, persisted) do
    lease.region_id == persisted.owner_region_id and
      lease.lease_id == persisted.owner_lease_id and
      lease.owner_scene_instance_ref == persisted.owner_scene_instance_ref and
      lease.owner_epoch == persisted.owner_epoch
  end

  @impl true
  def handle_call({:apply_lease, lease}, _from, state) do
    CliObserve.emit("voxel_chunk_lease_applied", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        previous_mode: state.mode
      }
    end)

    # Phase 6: when the lease token changes, all per-region field workers
    # captured the previous lease — stop them so a fresh leaseholder does
    # not see stale field state from the prior epoch.
    next_state =
      if lease_changed?(state.lease, lease) do
        stop_all_field_workers(state, :lease_revoked)
      else
        state
      end

    # 阶段3.1：World 下发 lease 时，未授权 / degraded 的 chunk 在此完成
    # hydrate 并转入授权态。degraded（hydrate 曾失败）也在拿到 lease 后重试
    # 从权威存储恢复，避免一直空跑。授权后补 schedule 模拟 tick。
    # 阶段2.4：应用 lease 是外部活动，刷新静默窗口；持有效 lease 的 chunk
    # 不应被空闲驱逐误杀。
    # 阶段2.4 liveness（MAJOR 2）：续期是“lease 续期使 simulation_due? 重新为真”
    # 的关键触发点。authorize_with_lease 的各分支已按需 arm；这里在 mark_activity
    # 之后再 maybe_arm 一次兜底，确保无论走 :authorized 续期还是 degraded→authorized
    # 重新 hydrate，dirty+simulator 的 chunk 在续期后都能恢复 tick（tick_armed?
    # 去重，仍在跑的是 no-op）。
    next_state =
      next_state
      |> authorize_with_lease(lease)
      |> mark_activity()
      |> maybe_arm_simulation_tick()

    {:reply, {:ok, lease}, next_state}
  end

  def handle_call({:load_snapshot, attrs}, _from, state) do
    case normalize_load_snapshot(attrs) do
      {:ok, %{storage: storage, lease: lease}} ->
        case validate_loaded_snapshot(state, storage) do
          :ok ->
            changed? = state.storage != storage
            next_state = %{state | storage: storage, lease: lease || state.lease}
            payload = encode_snapshot_payload(next_state.storage, 0)

            CliObserve.emit("voxel_chunk_snapshot_loaded", fn ->
              %{
                logical_scene_id: next_state.logical_scene_id,
                chunk_coord: next_state.chunk_coord,
                chunk_version: next_state.storage.chunk_version,
                changed?: changed?,
                has_lease?: not is_nil(next_state.lease)
              }
            end)

            if changed? do
              push_snapshot_fallbacks(next_state, :load_snapshot)
            end

            {:reply,
             {:ok,
              %{
                logical_scene_id: next_state.logical_scene_id,
                chunk_coord: next_state.chunk_coord,
                chunk_version: next_state.storage.chunk_version,
                changed?: changed?,
                snapshot_payload: payload
              }}, next_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_intent, attrs}, _from, state) do
    case state.pending_fence do
      %{transaction_id: tid} ->
        reason = {:chunk_fenced_by_transaction, tid}
        emit_intent_rejected(state, attrs, reason)
        {:reply, {:error, reason}, state}

      nil ->
        case normalize_apply_intent(attrs) do
          {:ok, intent} ->
            case apply_normalized_intent(state, intent) do
              {:ok, reply, next_state} ->
                next_state =
                  next_state
                  |> maybe_schedule_auto_circuit_refresh(reply.changed?)
                  |> post_write_lifecycle()

                CliObserve.emit("voxel_intent_applied", fn ->
                  %{
                    logical_scene_id: next_state.logical_scene_id,
                    chunk_coord: next_state.chunk_coord,
                    chunk_version: next_state.storage.chunk_version,
                    operation: intent.operation,
                    macro: intent.macro,
                    region_id: intent.lease.region_id,
                    lease_id: intent.lease.lease_id,
                    changed?: reply.changed?,
                    persist_result: reply.persist_result,
                    snapshot_bytes: byte_size(reply.snapshot_payload)
                  }
                end)

                if reply.changed? do
                  push_intent_outcome(
                    state,
                    next_state,
                    intent,
                    :apply_intent,
                    Map.get(reply, :delta_base_version)
                  )
                end

                {:reply, {:ok, reply}, next_state}

              {:error, reason} ->
                emit_intent_rejected(state, attrs, reason)
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            emit_intent_rejected(state, attrs, reason)
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:apply_intents, attrs_list}, _from, state) when is_list(attrs_list) do
    case state.pending_fence do
      %{transaction_id: tid} ->
        reason = {:chunk_fenced_by_transaction, tid}
        emit_intent_rejected(state, %{batch_count: length(attrs_list)}, reason)
        {:reply, {:error, reason}, state}

      nil ->
        case normalize_apply_intents(attrs_list) do
          {:ok, intents} ->
            case apply_normalized_intents(state, intents) do
              {:ok, reply, next_state} ->
                next_state =
                  next_state
                  |> maybe_schedule_auto_circuit_refresh(reply.changed?)
                  |> post_write_lifecycle()

                CliObserve.emit("voxel_intents_applied", fn ->
                  %{
                    logical_scene_id: next_state.logical_scene_id,
                    chunk_coord: next_state.chunk_coord,
                    chunk_version: next_state.storage.chunk_version,
                    intent_count: length(intents),
                    changed_count: reply.changed_count,
                    skipped_count: reply.skipped_count,
                    region_id: Map.get(reply.lease, :region_id, 0),
                    lease_id: Map.get(reply.lease, :lease_id, 0),
                    changed?: reply.changed?,
                    persist_result: reply.persist_result,
                    snapshot_bytes: byte_size(reply.snapshot_payload)
                  }
                end)

                if reply.changed? do
                  push_batch_outcome(state, next_state, intents, :apply_intents)
                end

                {:reply, {:ok, reply}, next_state}

              {:error, reason} ->
                emit_intent_rejected(state, %{batch_count: length(attrs_list)}, reason)
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            emit_intent_rejected(state, %{batch_count: length(attrs_list)}, reason)
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:prepare_transaction, transaction_id, intents, opts}, _from, state) do
    case prepare_transaction_in_state(state, transaction_id, intents, opts) do
      {:ok, summary, next_state} ->
        # 阶段2.4：持有 fence 的 chunk 一定不空闲（驱逐判定也会因 pending_fence
        # 非空直接拒绝），这里刷一次活动时间戳兜底。
        next_state = mark_activity(next_state)

        emit_transaction_event(
          next_state,
          transaction_id,
          "voxel_chunk_transaction_prepared",
          summary
        )

        {:reply, {:ok, summary}, next_state}

      {:error, reason} ->
        emit_transaction_event(state, transaction_id, "voxel_chunk_transaction_prepare_failed", %{
          reason: inspect(reason)
        })

        {:reply, {:error, reason}, state}
    end
  end

  # 阶段4 (4.5 voxel-storage-3) commit durable join。
  #
  # 统一 2PC 契约 #3（commit durable barrier）：participant 收到 commit 后必须
  # **先把快照持久化到 DB、确认 DB chunk_version >= 本次 commit version**，才返回
  # durable-ack 并删 fence；persist 完成前不得删 fence、不得 reply {:ok}。
  #
  # 因此 commit 分两步：
  #   1. 在本 handle_call 里把 intents build 成 candidate storage 并 enqueue
  #      async persist，拿到 persist_ref。**hot storage 此刻不推进**（candidate
  #      只活在 ack 里）；fence **不删**、pending_fence **不清**、from **不 reply**
  #      ——登记进 pending_commit_acks 后 {:noreply}。
  #   2. `:async_snapshot_persist_finished` 成功时（且 DB 版本已 >= commit
  #      version）才 swap hot=candidate + 删 fence + reply {:ok, durable-ack}；
  #      失败 / Task :DOWN 则 hot 保持 commit 前版本 + 保留 fence + reply
  #      {:error, :persist_failed}，由 coordinator 重投递 commit（幂等重建）。
  #
  # 无变更（changed_count == 0）的 commit 没有 persist 需要等待，本身即 durable，
  # 直接同步删 fence + reply。
  def handle_call({:commit_transaction, transaction_id}, from, state) do
    case commit_transaction_in_state(state, transaction_id) do
      {:durable_pending, ack, next_state} ->
        # 候选 storage 已就绪、async persist 已 enqueue；登记 durable-ack 等待，
        # fence / pending_fence 保留，from 暂不 reply。
        # 阶段2.4：in-flight commit 是活动，刷新静默窗口（pending_commit_acks
        # 非空也会在驱逐判定里直接阻止驱逐，这里额外刷时间戳兜底）。
        ack = %{ack | from: from}
        pending_commit_acks = Map.put(next_state.pending_commit_acks, ack.persist_ref, ack)
        next_state = mark_activity(%{next_state | pending_commit_acks: pending_commit_acks})
        {:noreply, next_state}

      {:committed_noop, reply, next_state, intents} ->
        # 无变更 commit：无 persist 需要等待，已 durable。同步释放 fence。
        next_state = finalize_committed_noop(next_state, transaction_id)
        # 记录已 durable 提交,供后续重投递做幂等(no-op commit 的 version 即当前
        # hot chunk_version,DB 已是该版本或为空)。
        next_state =
          record_durable_commit(next_state, transaction_id, next_state.storage.chunk_version)

        next_state =
          next_state
          |> maybe_schedule_auto_circuit_refresh(reply.changed?)
          |> post_write_lifecycle()

        emit_transaction_event(next_state, transaction_id, "voxel_chunk_transaction_committed", %{
          chunk_version: next_state.storage.chunk_version,
          snapshot_bytes: byte_size(reply.snapshot_payload),
          changed?: reply.changed?,
          changed_count: reply.changed_count,
          skipped_count: reply.skipped_count,
          intent_count: length(intents),
          persist_result: reply.persist_result,
          durable?: true
        })

        {:reply, {:ok, Map.put(reply, :durable?, true)}, next_state}

      # 阶段4 / world-2pc 跨侧幂等(B2)：该事务已 durable 提交过(fence 已释放)。
      # world 重投递 commit 时幂等回 {:ok, durable?: true}，闭合 durable-ack，
      # 避免“scene 已 durable but world pending”崩溃窗口里的永久 stranding。
      {:committed_idempotent, commit_version} ->
        emit_transaction_event(
          state,
          transaction_id,
          "voxel_chunk_transaction_commit_idempotent",
          %{
            durable?: true,
            durable_chunk_version: commit_version
          }
        )

        {:reply,
         {:ok,
          %{
            changed?: false,
            changed_count: 0,
            skipped_count: 0,
            chunk_version: commit_version,
            snapshot_payload: <<>>,
            persist_result: :durable,
            durable?: true,
            durable_chunk_version: commit_version,
            idempotent?: true
          }}, state}

      {:error, reason} ->
        emit_transaction_event(state, transaction_id, "voxel_chunk_transaction_commit_failed", %{
          reason: inspect(reason)
        })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:abort_transaction, transaction_id}, _from, state) do
    {released?, next_state} = abort_transaction_in_state(state, transaction_id)

    emit_transaction_event(next_state, transaction_id, "voxel_chunk_transaction_aborted", %{
      released?: released?
    })

    {:reply, :ok, next_state}
  end

  def handle_call({:destroy_part, attrs}, _from, state) do
    case destroy_part_in_state(state, attrs) do
      {:ok, reply, next_state} ->
        emit_destroy_part_event(next_state, attrs, reply)

        if reply.changed? do
          push_snapshot_fallbacks(next_state, :destroy_part)
        end

        {:reply, {:ok, reply}, next_state}

      {:error, reason} ->
        CliObserve.emit("voxel_chunk_destroy_part_failed", fn ->
          %{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            object_id: Map.get(attrs, :object_id),
            part_id: Map.get(attrs, :part_id),
            reason: inspect(reason)
          }
        end)

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cleanup_object_refs, attrs}, _from, state) do
    object_id = Map.fetch!(attrs, :object_id)

    new_object_refs =
      Enum.reject(state.storage.object_refs, fn ref -> ref.object_id == object_id end)

    if new_object_refs == state.storage.object_refs do
      {:reply, :ok, state}
    else
      next_storage = %{state.storage | object_refs: new_object_refs}
      next_state = %{state | storage: next_storage}
      {:reply, :ok, next_state}
    end
  end

  def handle_call({:invalidate_subscribers, reason}, _from, state) do
    payload =
      Codec.encode_chunk_invalidate_payload(%{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        reason: reason
      })

    subscriber_count = map_size(state.subscribers)

    Enum.each(state.subscribers, fn {subscriber, subscriber_state} ->
      push_chunk_invalidate(state, subscriber, subscriber_state, payload, reason)
    end)

    next_state = clear_subscriptions(state)

    CliObserve.emit("voxel_chunk_invalidate_pushed", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        reason: reason,
        reason_name: Codec.invalidate_reason_name(reason),
        subscriber_count: subscriber_count,
        byte_size: byte_size(payload)
      }
    end)

    {:reply, {:ok, %{subscriber_count: subscriber_count, reason: reason}}, next_state}
  end

  def handle_call({:put_solid_block, macro_index_or_coord, block, opts}, _from, state) do
    block = NormalBlockData.normalize!(block)
    cell_hash = Keyword.get_lazy(opts, :cell_hash, fn -> Hash.digest32(inspect(block)) end)
    opts = Keyword.put(opts, :cell_hash, cell_hash)

    storage =
      state.storage
      |> Storage.put_solid_block(macro_index_or_coord, block, opts)
      |> bump_chunk_version()

    CliObserve.emit("voxel_chunk_solid_block_put", fn ->
      %{
        logical_scene_id: storage.logical_scene_id,
        chunk_coord: storage.chunk_coord,
        chunk_version: storage.chunk_version,
        macro: macro_index_or_coord
      }
    end)

    next_state =
      %{state | storage: storage}
      |> maybe_schedule_auto_circuit_refresh(true)
      |> post_write_lifecycle()

    push_snapshot_fallbacks(next_state, :put_solid_block)

    {:reply, {:ok, storage}, next_state}
  end

  def handle_call({:write_temperature_attribute, attrs}, _from, state) do
    case build_temperature_attribute_storage(state.storage, attrs) do
      {:ok, next_storage, summary} ->
        next_state = post_write_lifecycle(%{state | storage: next_storage})

        if summary.changed? do
          push_snapshot_fallbacks(next_state, :temperature_attribute_write)
        end

        CliObserve.emit("voxel_temperature_attribute_written", fn ->
          %{
            logical_scene_id: next_storage.logical_scene_id,
            chunk_coord: next_storage.chunk_coord,
            chunk_version: next_storage.chunk_version,
            macro: summary.macro_index,
            target_temperature: summary.target_temperature,
            effective_temperature: summary.effective_temperature,
            changed?: summary.changed?
          }
        end)

        {:reply, {:ok, summary}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:add_heat_energy_attribute, attrs}, _from, state) do
    case build_heat_energy_attribute_storage(state.storage, attrs) do
      {:ok, next_storage, summary} ->
        next_state = post_write_lifecycle(%{state | storage: next_storage})

        if summary.changed? do
          push_snapshot_fallbacks(next_state, :heat_energy_attribute_write)
        end

        CliObserve.emit("voxel_heat_energy_attribute_written", fn ->
          %{
            logical_scene_id: next_storage.logical_scene_id,
            chunk_coord: next_storage.chunk_coord,
            chunk_version: next_storage.chunk_version,
            macro: summary.macro_index,
            heat_energy_joules: summary.heat_energy_joules,
            previous_temperature: summary.previous_temperature,
            temperature_delta: summary.temperature_delta,
            effective_temperature: summary.effective_temperature,
            changed?: summary.changed?
          }
        end)

        {:reply, {:ok, summary}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_field_effects, effects, context}, _from, state) do
    {results, next_state} =
      Enum.map_reduce(effects, state, fn effect, acc_state ->
        apply_field_effect(acc_state, effect, context)
      end)

    # 阶段2.4：field kernel writeback 可能改 dirty —— 刷活动 + 按需 arm tick。
    next_state = post_write_lifecycle(next_state)

    summary = %{
      applied_count: Enum.count(results, &(&1.status == :applied)),
      rejected_count: Enum.count(results, &(&1.status == :rejected)),
      chunk_version: next_state.storage.chunk_version,
      results: results
    }

    {:reply, {:ok, summary}, next_state}
  end

  def handle_call({:subscribe, subscriber, opts}, _from, state) do
    request_id = Keyword.get(opts, :request_id, 0)
    known_version = Keyword.get(opts, :known_version)
    send_snapshot? = Keyword.get(opts, :send_snapshot?, true)
    delivery_opts = normalize_subscriber_delivery_opts(opts)

    {state, monitor_ref, subscriber_state} =
      put_subscriber(state, subscriber, request_id, delivery_opts)

    # 阶段2.4：新增订阅是活动，刷新静默窗口。有订阅的 chunk 也会在驱逐判定里
    # 因 subscribers 非空被直接保护。
    state =
      state
      |> maybe_schedule_auto_circuit_refresh_for_subscriber()
      |> mark_activity()

    payload = encode_snapshot_payload(state.storage, request_id)
    snapshot_sent? = send_snapshot? and known_version != state.storage.chunk_version

    CliObserve.emit("voxel_chunk_subscribe", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        chunk_version: state.storage.chunk_version,
        subscriber: subscriber,
        monitor_ref: monitor_ref,
        request_id: request_id,
        known_version: known_version,
        delivery_format: subscriber_state.delivery_format,
        tier: subscriber_state.tier,
        snapshot_sent?: snapshot_sent?,
        subscriber_count: map_size(state.subscribers)
      }
    end)

    if snapshot_sent? do
      push_snapshot_fallback(state, subscriber, subscriber_state, payload, :subscribe)
    end

    {:reply, {:ok, payload}, state}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    {state, result} = drop_subscriber(state, subscriber)

    CliObserve.emit("voxel_chunk_unsubscribe", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        subscriber: subscriber,
        result: result,
        subscriber_count: map_size(state.subscribers)
      }
    end)

    {:reply, :ok, state}
  end

  def handle_call({:snapshot, request_id}, _from, state) do
    payload = encode_snapshot_payload(state.storage, request_id)

    case Codec.decode_chunk_snapshot_payload(payload) do
      {:ok, snapshot} -> {:reply, {:ok, snapshot}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:snapshot_payload, request_id}, _from, state) do
    payload = encode_snapshot_payload(state.storage, request_id)

    {:reply, {:ok, payload}, state}
  end

  def handle_call({:collision_query, attrs}, _from, state) do
    case normalize_collision_query(attrs) do
      {:ok, query} ->
        occupied =
          state.storage
          |> collision_query_hits(query.samples)
          |> Enum.sort_by(fn hit -> {hit.macro_index, hit.micro_slot} end)

        {:reply,
         {:ok,
          %{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            chunk_version: state.storage.chunk_version,
            sample_count: length(query.samples),
            occupied_count: length(occupied),
            occupied: occupied
          }}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:persist, _from, %{lease: nil} = state) do
    {:reply, {:error, :missing_lease}, state}
  end

  def handle_call(:persist, _from, state) do
    payload = encode_snapshot_payload(state.storage, 0)

    reply =
      persist_snapshot(
        state.lease,
        state.chunk_coord,
        state.storage,
        payload
      )

    CliObserve.emit("voxel_chunk_persist", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        chunk_version: state.storage.chunk_version,
        result: inspect(reply)
      }
    end)

    {:reply, reply, state}
  end

  def handle_call(:debug_state, _from, state) do
    {:reply,
     %{
       logical_scene_id: state.logical_scene_id,
       chunk_coord: state.chunk_coord,
       chunk_version: state.storage.chunk_version,
       storage: state.storage,
       has_lease?: not is_nil(state.lease),
       lease: state.lease,
       # 阶段3.1：暴露授权态 + hydrate 结果供 CLI/测试断言。
       mode: state.mode,
       hydrate_status: state.hydrate_status,
       pending_async_persist_count: map_size(state.async_persists),
       # 阶段4 (4.5)：暴露 in-flight commit durable-ack 等待数 + 当前 fence 摘要，
       # 供 CLI / 故障注入测试断言 durable join 与 fence TTL 行为。
       pending_commit_ack_count: map_size(state.pending_commit_acks),
       pending_fence: pending_fence_summary(state.pending_fence),
       subscriber_count: map_size(state.subscribers),
       subscribers: Map.keys(state.subscribers),
       field_region_count: map_size(state.field_regions),
       field_source_count: map_size(state.field_region_sources),
       phenomenon_instance_count: map_size(state.phenomenon_instances),
       phenomenon_instances: phenomenon_instance_summaries(state.phenomenon_instances),
       # 阶段2.4：暴露按需 tick / 空闲驱逐状态供 CLI / 故障注入测试断言
       # （“空闲态零 timer” = tick_armed? false 且无 dirty）。
       tick_armed?: state.tick_armed?,
       last_activity_ms: state.last_activity_ms,
       evict_requested?: state.evict_requested?,
       idle_evict_candidate?: idle_evict_candidate?(state)
     }, state}
  end

  # 阶段2.4：facade 复核驱逐。在 chunk 自身 mailbox 里重新评估空闲条件，仍空闲
  # 则先 persist 再回 {:ok, :evicting}（让 facade terminate_child）。复核期间又
  # 活跃（订阅/写/lease 进来刷新了静默窗口或落了 fence）→ {:cancel, reason}。
  def handle_call(:confirm_evict, _from, state) do
    cond do
      not idle_evict_candidate?(state) ->
        # 复核窗口内又活跃了 —— 取消驱逐，进程复用。清掉 evict_requested?
        # 让下一轮重新评估。
        CliObserve.emit("voxel_chunk_evict_cancelled", fn ->
          %{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            reason: :became_active,
            subscriber_count: map_size(state.subscribers),
            field_region_count: map_size(state.field_regions),
            has_pending_fence?: not is_nil(state.pending_fence)
          }
        end)

        {:reply, {:cancel, :became_active}, %{state | evict_requested?: false}}

      true ->
        case persist_before_evict(state) do
          {:ok, persist_kind} ->
            CliObserve.emit("voxel_chunk_evict_confirmed", fn ->
              %{
                logical_scene_id: state.logical_scene_id,
                chunk_coord: state.chunk_coord,
                chunk_version: state.storage.chunk_version,
                persist_kind: persist_kind,
                silence_ms: now_ms() - state.last_activity_ms
              }
            end)

            {:reply, {:ok, :evicting}, state}

          {:error, reason} ->
            # 未落库不丢热状态：取消本次驱逐，下一轮再试。
            CliObserve.emit("voxel_chunk_evict_cancelled", fn ->
              %{
                logical_scene_id: state.logical_scene_id,
                chunk_coord: state.chunk_coord,
                reason: {:persist_failed, reason}
              }
            end)

            {:reply, {:cancel, {:persist_failed, reason}}, %{state | evict_requested?: false}}
        end
    end
  end

  def handle_call(:flush_persistence, from, state) do
    if map_size(state.async_persists) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, %{state | persist_waiters: [from | state.persist_waiters]}}
    end
  end

  # Phase 6: create a new FieldRegion under FieldTickSupervisor.
  def handle_call({:create_field_region, attrs}, _from, state) when is_map(attrs) do
    case start_field_region(state, attrs, nil) do
      # 阶段2.4：持有 field region 的 chunk 永不空闲（驱逐判定亦会因
      # field_regions 非空保护），刷一次活动时间戳兜底。
      {:ok, region_id, next_state} -> {:reply, {:ok, region_id}, mark_activity(next_state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ensure_field_region, attrs}, _from, state) when is_map(attrs) do
    case fetch_optional(attrs, [:source_key]) do
      nil ->
        case fetch_optional(attrs, [:region_id]) do
          nil ->
            {:reply, {:error, :missing_field_source_key}, state}

          region_id ->
            # field_regions 非空已保护此 chunk 不被空闲驱逐；这里沿用既有返回。
            ensure_stable_field_region(state, attrs, region_id)
        end

      source_key ->
        {result, next_state} = ensure_field_source_region_in_state(state, attrs, source_key)
        {:reply, result, mark_activity(next_state)}
    end
  end

  def handle_call({:release_field_region_source, source_key, destroy_reason}, _from, state) do
    {result, next_state} = release_field_region_source_entry(state, source_key, destroy_reason)
    {:reply, {:ok, result}, next_state}
  end

  # Phase 6: destroy a FieldRegion by region_id (explicit caller-initiated).
  def handle_call({:destroy_field_region, region_id}, _from, state)
      when is_integer(region_id) do
    case destroy_field_region_entry(state, region_id, :explicit) do
      {:not_found, _next_state} ->
        {:reply, {:error, :not_found}, state}

      {:ok, next_state} ->
        {:reply, :ok, next_state}
    end
  end

  @impl true
  def handle_cast({:push_object_state_delta_payload, payload}, state) when is_binary(payload) do
    fan_out_object_state_delta_payload(state, payload)
    {:noreply, state}
  end

  # Phase 6: fan out 0x73 FieldRegionSnapshot from FieldTickWorker.
  def handle_cast({:push_field_snapshot_payload, payload}, state) when is_binary(payload) do
    fan_out_field_snapshot_payload(state, payload)
    {:noreply, state}
  end

  # Phase 6: fan out 0x74 FieldRegionDestroyed from FieldTickWorker (expired
  # or chunk crash path inside the worker).
  def handle_cast({:push_field_region_destroyed_payload, payload}, state)
      when is_binary(payload) do
    state = release_field_region_from_destroyed_payload(state, payload)
    fan_out_field_region_destroyed_payload(state, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info({:async_snapshot_persist_finished, ref, result, snapshot_bytes}, state) do
    {persist_meta, async_persists} = Map.pop(state.async_persists, ref)

    if persist_meta do
      Process.demonitor(persist_meta.monitor_ref, [:flush])

      CliObserve.emit("voxel_chunk_async_persist_finished", fn ->
        Map.merge(persist_meta.observe, %{result: inspect(result), snapshot_bytes: snapshot_bytes})
      end)
    end

    # 阶段4 (4.5)②：durable join。若该 ref 是某个 commit 的 durable-ack 等待点，
    # 在此根据 persist result 决定删 fence + reply {:ok}（成功）还是保留 fence
    # + reply {:error, :persist_failed}（失败）。
    state =
      %{state | async_persists: async_persists}
      |> resolve_pending_commit_ack(ref, result)
      |> maybe_reply_persist_waiters()

    {:noreply, state}
  end

  def handle_info(:refresh_auto_circuit_after_mutation, state) do
    state = %{state | auto_circuit_refresh_pending?: false}
    {:noreply, refresh_auto_circuit_after_mutation(state)}
  end

  def handle_info({:DOWN, monitor_ref, :process, subscriber, reason}, state) do
    case async_persist_by_monitor(state, monitor_ref) do
      {ref, persist_meta} ->
        async_persists = Map.delete(state.async_persists, ref)

        CliObserve.emit("voxel_chunk_async_persist_down", fn ->
          Map.merge(persist_meta.observe, %{
            task_pid: inspect(subscriber),
            reason: inspect(reason)
          })
        end)

        # 阶段4 (4.5)③：unlinked persist Task :DOWN —— 持久化未确认完成。若该 ref
        # 是某个 commit 的 durable-ack 等待点，reply {:error, :persist_failed}
        # 并保留 fence（决定权交回 coordinator 重投递），绝不挂起 caller。
        state =
          %{state | async_persists: async_persists}
          |> resolve_pending_commit_ack(ref, {:error, {:persist_task_down, reason}})
          |> maybe_reply_persist_waiters()

        {:noreply, state}

      nil ->
        case Map.get(state.field_region_monitors, monitor_ref) do
          nil ->
            case Map.get(state.subscriber_monitors, monitor_ref) do
              ^subscriber ->
                state = drop_subscriber_by_monitor(state, monitor_ref, subscriber)

                CliObserve.emit("voxel_chunk_unsubscribe", fn ->
                  %{
                    logical_scene_id: state.logical_scene_id,
                    chunk_coord: state.chunk_coord,
                    subscriber: subscriber,
                    reason: inspect(reason),
                    result: :subscriber_down,
                    subscriber_count: map_size(state.subscribers)
                  }
                end)

                {:noreply, state}

              _other ->
                {:noreply, state}
            end

          region_id ->
            CliObserve.emit("voxel_field_region_worker_down", fn ->
              %{
                logical_scene_id: state.logical_scene_id,
                chunk_coord: state.chunk_coord,
                region_id: region_id,
                reason: inspect(reason)
              }
            end)

            source_key = Map.get(state.field_region_source_keys, region_id)
            destroy_reason = worker_down_destroy_reason(reason)

            new_state =
              state
              |> cleanup_linked_field_regions(source_key, destroy_reason)
              |> drop_field_region_monitor(monitor_ref, region_id)
              |> maybe_emit_worker_down_source_lifecycle(region_id, source_key, reason)
              |> maybe_refresh_expired_auto_circuit(source_key, destroy_reason)

            {:noreply, new_state}
        end
    end
  end

  # Phase 5.E + 阶段2.4：按需 simulation tick。本 tick 触发说明上一次 arm 的
  # timer 到点了——先清 tick_armed?（in-flight timer 已消费），跑一次 tick，
  # 再 **按需** 重新 arm：只有跑完后仍 `(有 simulator 且 dirty)` 时才排下一个。
  # 一旦 dirty 清空（execute_simulation_tick 会清 dirty_bounds），就回到零 timer
  # 空闲态，不再 100ms 空转。
  def handle_info(:simulation_tick, state) do
    next_state =
      %{state | tick_armed?: false}
      |> run_simulation_tick()
      |> maybe_arm_simulation_tick()

    {:noreply, next_state}
  end

  # 阶段4 (2.2 world-2pc-6)：prepared fence TTL 兜底。周期检查 in-memory fence
  # 是否已过 deadline。过期且没有 in-flight commit（pending_commit_acks 空表示
  # 该事务还没进入 commit 的 durable 等待）时，主动作废孤儿 fence：删 DB 行 +
  # 清 pending_fence + 报 observe。这是 coordinator/driver 整体死亡的兜底；
  # 主路径仍是 World reaper 显式 abort。
  #
  # 阶段2.4：复用这个低频节拍承载 lease 心跳 + 空闲驱逐静默检查。先作废过期
  # fence（避免 fence 把空闲 chunk 钉住不让驱逐），再判断是否进入可驱逐态并向
  # facade 请求驱逐。两件事都很廉价（空闲态几乎是几次 map_size + 时间比较）。
  def handle_info(:check_pending_fence_ttl, state) do
    next_state =
      state
      |> maybe_void_expired_fence()
      |> maybe_request_eviction()
      |> schedule_fence_ttl_check()

    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    # 阶段3.1：退出时主动清理，让崩溃/下线对外可观测、可重路由。
    #
    # 1. 给所有订阅者推 ChunkInvalidate，使它们 re-subscribe 到重启后的新权威
    #    进程（注册表保证同 key 只会有一个新进程接管），而不是把 delta 推到
    #    已死的旧 pid。
    # 2. 停掉本进程拥有的 field worker（它们捕获了旧 lease）。
    # 3. 上报 observe：facade（ChunkDirectory）monitor 也会收到 :DOWN，这里
    #    额外把退出原因落进 observe，供 World 裁决该 coord 是否不可用。
    #
    # lease 的释放是隐式的：lease 由 World 持有 / epoch 栅栏裁决，进程退出后
    # 对应 storage 不再被本进程写；这里不去主动 DataService 释放（避免把写
    # token 失效误判成数据丢失）。重启后的 init 会用同一 lease 重新 hydrate。
    _ =
      try do
        invalidate_subscribers_on_terminate(state)
      catch
        _kind, _err -> :ok
      end

    _ =
      try do
        stop_all_field_workers(state, :chunk_crash)
      catch
        _kind, _err -> :ok
      end

    # 阶段5.2：删 per-chunk occupancy 表（兜底；`:public` 无 heir 表在进程退出时
    # 也会被 ETS 自动回收）。删表后读路径对该 coord 读到 `:not_published`，回退到
    # 经 facade ensure（重启后新权威进程会重建表并重新发布），不会读到陈旧快照。
    _ =
      try do
        if state[:occupancy_table], do: ChunkOccupancyTable.delete_table(state.occupancy_table)
      catch
        _kind, _err -> :ok
      end

    CliObserve.emit("voxel_chunk_terminated", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        chunk_version: state.storage.chunk_version,
        mode: state.mode,
        subscriber_count: map_size(state.subscribers),
        reason: inspect(reason)
      }
    end)

    :ok
  end

  defp invalidate_subscribers_on_terminate(%{subscribers: subscribers} = state)
       when map_size(subscribers) == 0,
       do: state

  defp invalidate_subscribers_on_terminate(state) do
    # ChunkInvalidate reason 0x00 = generic; 订阅者据此 re-subscribe。
    payload =
      Codec.encode_chunk_invalidate_payload(%{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        reason: 0x00
      })

    Enum.each(state.subscribers, fn {subscriber, subscriber_state} ->
      push_chunk_invalidate(state, subscriber, subscriber_state, payload, 0x00)
    end)

    state
  end

  # ---------------------------------------------------------------------------
  # Phase 5.E:simulation tick dispatch
  # ---------------------------------------------------------------------------

  defp run_simulation_tick(%{simulation_tick: simulation_tick} = state) do
    cond do
      # 阶段3.1：未授权 / degraded 的 chunk 不模拟（degraded 持空 storage，
      # 模拟会把错误的初值往订阅者推）。
      state.mode != :authorized ->
        record_tick_skip(state, simulation_tick, {:not_authorized, state.mode})

      lease_stale?(state.lease) ->
        record_tick_skip(state, simulation_tick, :lease_stale)

      not SimulationTick.any_simulator?(simulation_tick) ->
        record_tick_skip(state, simulation_tick, :no_simulators)

      DirtyMacroBounds.empty?(state.storage.dirty_bounds) ->
        record_tick_skip(state, simulation_tick, :no_dirty)

      true ->
        # 实际执行 tick —— 重置 skip 计数（连续 skip 段结束）。
        state
        |> execute_simulation_tick(simulation_tick)
        |> Map.put(:tick_skip_count, 0)
    end
  end

  defp execute_simulation_tick(state, simulation_tick) do
    started_us = System.monotonic_time(:microsecond)
    dirty_in = state.storage.dirty_bounds
    input_chunk_hash = Codec.chunk_hash(state.storage)
    simulator_ids = SimulationTick.simulator_ids(simulation_tick)

    CliObserve.emit("voxel_simulation_tick_started", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        tick_seq: simulation_tick.tick_seq,
        dirty_min: dirty_in.min_macro,
        dirty_max: dirty_in.max_macro,
        reason_flags: dirty_in.reason_flags,
        simulator_count: length(simulator_ids)
      }
    end)

    env = %{
      chunk_coord: state.chunk_coord,
      logical_scene_id: state.logical_scene_id,
      lease_token: state.lease,
      storage: state.storage,
      neighbor_lookup: state.simulation_neighbor_lookup
    }

    {next_sim, summary} = SimulationTick.run_tick(simulation_tick, dirty_in, env)

    Enum.each(summary.failures, fn {sim_id, reason} ->
      CliObserve.emit("voxel_simulation_simulator_failed", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          tick_seq: simulation_tick.tick_seq,
          simulator_id: sim_id,
          reason: inspect(reason)
        }
      end)
    end)

    # Phase 5.F: 将每个 simulator 返回的 env_delta 编码为 EnvironmentUpdated
    # (opcode 0x72) wire payload 并 fanout 给本 chunk 的 subscribers。Phase 5.F
    # 本 commit 不修改 storage.environment_summaries(避免影响 chunk_hash baseline
    # + 现有 chunk_version 语义);simulator writeback 推到 Phase 5.F.runtime。
    chunk_version = state.storage.chunk_version

    Enum.each(summary.env_deltas, fn {sim_id, env_delta} ->
      maybe_fan_out_environment_updated_payload(
        state,
        sim_id,
        env_delta,
        chunk_version,
        simulation_tick.tick_seq
      )
    end)

    # Phase 5.E 策略:dirty_bounds 在 tick 后无条件清空(失败 simulator
    # 不阻塞 dirty 清理);失败 simulator 的重试机会 = 下个 tick 自然累积。
    # Phase 5.F 真正温湿度 simulator 落地后,可在此根据 summary.failures
    # 决定是否保留 dirty,但本 commit 先采用最简策略。
    output_hash =
      SimulationTick.output_hash(input_chunk_hash, dirty_in, next_sim.tick_seq, simulator_ids)

    next_sim = SimulationTick.put_last_output_hash(next_sim, output_hash)
    next_storage = Storage.clear_dirty_bounds(state.storage)
    duration_us = System.monotonic_time(:microsecond) - started_us

    CliObserve.emit("voxel_simulation_tick_completed", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        tick_seq: next_sim.tick_seq,
        cells_updated: summary.cells_updated,
        duration_us: duration_us,
        output_hash: output_hash,
        failure_count: length(summary.failures)
      }
    end)

    %{state | storage: next_storage, simulation_tick: next_sim}
  end

  # 阶段2.4：tick_skipped 采样降级。按需 tick 落地后，skip 基本只在 arm→fire
  # 之间状态翻转（如刚 degraded / lease 刚过期）的边缘出现，但仍保留兜底计数。
  # 只在每第 N 次 skip 发一条聚合 observe（含累计 skip 计数），避免空转刷日志。
  defp record_tick_skip(state, simulation_tick, reason) do
    skip_count = state.tick_skip_count + 1

    if rem(skip_count, @tick_skip_sample_n) == 1 do
      CliObserve.emit("voxel_simulation_tick_skipped", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          tick_seq: simulation_tick.tick_seq,
          reason: reason,
          skip_count: skip_count,
          sampled_every: @tick_skip_sample_n
        }
      end)
    end

    %{state | tick_skip_count: skip_count}
  end

  defp lease_stale?(nil), do: true

  defp lease_stale?(%{expires_at_ms: expires_at_ms}) when is_integer(expires_at_ms) do
    expires_at_ms <= System.system_time(:millisecond)
  end

  defp lease_stale?(_), do: false

  defp apply_normalized_intent(state, intent) do
    apply_normalized_intent(state, intent, true)
  end

  # ad-hoc 单 intent 直写路径（`apply_intent/2`，非事务）。保持**同步持久化 +
  # durable-on-reply** 语义不变：`apply_intent/2` 的调用方依赖 reply 已落库
  # （`persist_result` 为 `:inserted`/`:updated`）。
  #
  # 阶段4 (4.5) 的“单/批统一 enqueue + 单 join 点”针对的是**事务 commit** 路径
  # （见 `commit_prepared_intents/3`）：commit 不论 1 个还是 N 个 intent，都走
  # `enqueue_snapshot_persist` + `:async_snapshot_persist_finished` 这同一条
  # durable join；本 ad-hoc 直写路径不进 2PC，不改其同步契约。
  defp apply_normalized_intent(state, intent, retry_on_persist_stale?) do
    # Phase 4 (D7):collect damage attribution from owner lookups BEFORE
    # the apply clears the slot (post-apply lookup would see the empty
    # slot).
    damage_attribution = collect_damage_attribution(state.storage, [intent])

    with :ok <- validate_intent_scope(state, intent),
         :ok <- validate_intent_preconditions(state, intent),
         {:ok, raw_storage, changed?} <- build_intent_storage(state.storage, intent) do
      # Phase 4 (D6):rebuild ChunkObjectRef[] from layer truth so
      # single-intent flows (apply_intent/2 direct path) keep object
      # provenance摘要 in sync.
      #
      # 阶段2.5(voxel-storage-6):单格改动用**增量** refresh —— 只重算
      # `dirty_bounds` 圈定的 dirty macro 的 cell.object_refs(单 intent = 1 个
      # macro),不再每次全量重扫 4096 header。`build_intent_storage` 经 Storage
      # 写 API 已 mark dirty,dirty 集覆盖本次唯一变更,与全量 refresh 等价。
      next_storage =
        if changed?,
          do: Storage.refresh_chunk_object_refs_incremental(raw_storage),
          else: raw_storage

      # 阶段2.5:同一 storage 只全量 encode 一次,request_id 头字节拼接出 reply
      # 与 persist 两份载荷(逐字节等价于原双 encode)。
      {snapshot_payload, persist_payload} =
        encode_snapshot_payloads_dual(next_storage, intent.request_id)

      if changed? do
        case persist_snapshot(
               intent.lease,
               state.chunk_coord,
               next_storage,
               persist_payload
             ) do
          {:ok, persist_result} ->
            next_state =
              %{state | storage: next_storage, lease: intent.lease}
              |> promote_authorized_on_write()

            dispatch_damage_async(next_state, damage_attribution)

            {:ok, intent_reply(next_storage, intent, persist_result, snapshot_payload, true),
             next_state}

          {:error, reason} ->
            maybe_recover_stale_persist(
              reason,
              state,
              intent,
              retry_on_persist_stale?
            )
        end
      else
        next_state = %{state | lease: intent.lease} |> promote_authorized_on_write()
        {:ok, intent_reply(next_storage, intent, :unchanged, snapshot_payload, false), next_state}
      end
    end
  end

  defp maybe_recover_stale_persist(:stale_chunk_version, state, intent, true) do
    case recover_canonical_snapshot_after_persist_stale(
           state,
           intent.lease,
           :intent_persist_stale
         ) do
      {:ok, recovered_state} ->
        case apply_normalized_intent(recovered_state, intent, false) do
          {:ok, reply, next_state} ->
            {:ok, Map.put(reply, :delta_base_version, recovered_state.storage.chunk_version),
             next_state}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_recover_stale_persist(reason, _state, _intent, _retry_on_persist_stale?),
    do: {:error, reason}

  defp recover_canonical_snapshot_after_persist_stale(state, lease, reason) do
    case DataService.Voxel.ChunkSnapshotStore.get_snapshot(
           state.logical_scene_id,
           state.chunk_coord
         ) do
      {:ok, snapshot} ->
        with {:ok, storage} <- decode_prewarm_payload(snapshot.data),
             :ok <- validate_loaded_snapshot(state, storage) do
          changed? = state.storage != storage
          next_state = %{state | storage: storage, lease: lease || state.lease}

          CliObserve.emit("voxel_chunk_persist_stale_recovered", fn ->
            %{
              logical_scene_id: next_state.logical_scene_id,
              chunk_coord: next_state.chunk_coord,
              previous_chunk_version: state.storage.chunk_version,
              recovered_chunk_version: next_state.storage.chunk_version,
              changed?: changed?,
              reason: reason
            }
          end)

          if changed? do
            push_snapshot_fallbacks(next_state, reason)
          end

          {:ok, next_state}
        else
          {:error, recover_reason} -> {:error, {:persist_stale_recovery_failed, recover_reason}}
        end

      {:error, recover_reason} ->
        {:error, {:persist_stale_recovery_failed, recover_reason}}
    end
  end

  defp apply_normalized_intents(state, []) do
    payload = encode_snapshot_payload(state.storage, 0)

    {:ok,
     %{
       logical_scene_id: state.logical_scene_id,
       chunk_coord: state.chunk_coord,
       chunk_version: state.storage.chunk_version,
       changed?: false,
       changed_count: 0,
       skipped_count: 0,
       persist_result: :unchanged,
       snapshot_payload: payload,
       lease: state.lease || %{}
     }, state}
  end

  defp apply_normalized_intents(state, intents) do
    # Phase 4 (D7):collect damage attribution before clearing micros.
    damage_attribution = collect_damage_attribution(state.storage, intents)

    with :ok <- validate_batch_scope(state, intents),
         :ok <- validate_batch_preconditions(state, intents),
         :ok <- validate_apply_batch_occupancy(state, intents),
         {:ok, raw_storage, changed_count, skipped_count} <-
           build_intents_storage(state.storage, intents) do
      # Phase 4 (D6):after every apply rebuild per-cell ObjectCoverRef[] and
      # chunk-level ChunkObjectRef[] from the new MicroLayer truth.
      #
      # 阶段2.5(voxel-storage-6):改用**增量** refresh —— 只重算 dirty AABB 内
      # 的 refined cell.object_refs(prefab batch 落在有界 macro 区间),再整体重
      # 聚合 chunk-level refs。`build_intents_storage` 经 Storage 写 API 已把每个
      # 触碰 macro mark 进 dirty_bounds,dirty 集覆盖全部变更,与全量 refresh 等价。
      next_storage = Storage.refresh_chunk_object_refs_incremental(raw_storage)
      request_id = intents |> List.first() |> Map.fetch!(:request_id)
      return_snapshot_payload? = return_snapshot_payload?(intents)

      snapshot_payload =
        maybe_encode_snapshot_payload(next_storage, request_id, return_snapshot_payload?)

      lease = intents |> List.first() |> Map.fetch!(:lease)

      if changed_count > 0 do
        case enqueue_snapshot_persist(
               state,
               lease,
               state.chunk_coord,
               next_storage,
               snapshot_payload_for_persist(snapshot_payload, return_snapshot_payload?)
             ) do
          {:ok, persist_result, persist_ref, state_with_task} ->
            reply =
              batch_intent_reply(
                next_storage,
                lease,
                persist_result,
                snapshot_payload,
                changed_count,
                skipped_count,
                persist_ref
              )

            next_state =
              %{state_with_task | storage: next_storage, lease: lease}
              |> promote_authorized_on_write()

            dispatch_damage_async(next_state, damage_attribution)

            {:ok, reply, next_state}

          {:error, reason} ->
            {:error, reason}
        end
      else
        reply =
          batch_intent_reply(
            next_storage,
            lease,
            :unchanged,
            snapshot_payload,
            changed_count,
            skipped_count,
            nil
          )

        {:ok, reply, %{state | lease: lease} |> promote_authorized_on_write()}
      end
    end
  end

  # Phase 4 (D7):damage attribution helpers. Pre-apply lookup of owner +
  # accumulator + post-apply async dispatch (Task.start to break the
  # ChunkProcess → ObjectRegistry → ChunkDirectory → ChunkProcess.destroy_part
  # synchronous loop).
  defp collect_damage_attribution(storage, intents) when is_list(intents) do
    Enum.reduce(intents, %{}, &accumulate_intent_damage(&1, &2, storage))
  end

  defp accumulate_intent_damage(
         %{operation: :clear_micro_block, macro: macro, micro_slot: slot},
         acc,
         storage
       ) do
    case Storage.lookup_owner_at(storage, macro, slot) do
      {oid, pid} when oid > 0 ->
        Map.update(acc, {oid, pid}, 1, &(&1 + 1))

      _ ->
        acc
    end
  end

  defp accumulate_intent_damage(_intent, acc, _storage), do: acc

  defp collect_structural_damage_attribution(%Storage{object_refs: []}, _macro_index), do: %{}

  defp collect_structural_damage_attribution(storage, macro_index) do
    case Storage.refined_cell_at(storage, macro_index) do
      nil ->
        %{}

      cell ->
        Enum.reduce(cell.layers, %{}, fn layer, acc ->
          oid = layer.owner_object_id
          pid = layer.owner_part_id
          damage = mask_damage_count(layer.mask_words)

          if oid > 0 and damage > 0 do
            Map.update(acc, {oid, pid}, damage, &(&1 + damage))
          else
            acc
          end
        end)
    end
  end

  defp mask_damage_count(mask_words) when is_list(mask_words) do
    Enum.reduce(mask_words, 0, fn word, total -> total + bit_count(word) end)
  end

  defp mask_damage_count(_mask_words), do: 0

  defp bit_count(word) when is_integer(word) and word > 0, do: bit_count(word, 0)
  defp bit_count(_word), do: 0

  defp bit_count(0, count), do: count
  defp bit_count(word, count), do: bit_count(word &&& word - 1, count + 1)

  defp dispatch_damage_async(_state, attribution) when map_size(attribution) == 0, do: :ok

  defp dispatch_damage_async(%{object_registry: nil}, _attribution), do: :ok

  defp dispatch_damage_async(state, attribution) do
    registry = state.object_registry
    chunk_directory = state.chunk_directory
    scene_id = state.logical_scene_id

    Task.start(fn ->
      Enum.each(attribution, fn {{oid, pid}, count} ->
        try do
          SceneServer.Voxel.ObjectRegistry.accumulate_damage(
            registry,
            scene_id,
            oid,
            pid,
            count,
            chunk_directory: chunk_directory
          )
        catch
          # Registry not running (test harness w/o ObjectRegistry, or restart
          # in flight). Damage is best-effort: drop on the floor; the next
          # apply will re-attribute as the registry comes back up.
          :exit, _ -> :ok
        end
      end)
    end)

    :ok
  end

  defp intent_reply(storage, intent, persist_result, snapshot_payload, changed?) do
    %{
      logical_scene_id: storage.logical_scene_id,
      chunk_coord: storage.chunk_coord,
      chunk_version: storage.chunk_version,
      operation: intent.operation,
      macro: intent.macro,
      changed?: changed?,
      persist_result: persist_result,
      snapshot_payload: snapshot_payload
    }
  end

  defp batch_intent_reply(
         storage,
         lease,
         persist_result,
         snapshot_payload,
         changed_count,
         skipped_count,
         persist_ref
       ) do
    %{
      logical_scene_id: storage.logical_scene_id,
      chunk_coord: storage.chunk_coord,
      chunk_version: storage.chunk_version,
      changed?: changed_count > 0,
      changed_count: changed_count,
      skipped_count: skipped_count,
      persist_result: persist_result,
      persist_ref: persist_ref,
      snapshot_payload: snapshot_payload,
      lease: lease
    }
  end

  defp prepare_transaction_in_state(_state, _transaction_id, [], _opts) do
    {:error, :empty_intents}
  end

  defp prepare_transaction_in_state(state, transaction_id, intents, opts)
       when is_list(intents) and is_list(opts) do
    case state.pending_fence do
      %{transaction_id: ^transaction_id} = existing ->
        {:ok, fence_summary(existing), state}

      %{transaction_id: holder} ->
        {:error, {:chunk_already_fenced, holder}}

      nil ->
        decision_version = Keyword.get(opts, :decision_version, 0)

        with {:ok, normalized} <- normalize_apply_intents(intents),
             :ok <- validate_batch_scope(state, normalized),
             :ok <- validate_batch_preconditions(state, normalized),
             :ok <- validate_batch_occupancy(state, normalized),
             {:ok, owner_lease} <- fetch_fence_owner_lease(normalized) do
          fenced_at_ms = now_ms()
          # 阶段4 (2.2)：fence TTL 的 deadline。优先取 coordinator 在 prepare
          # 时下发的绝对 `:fence_deadline_ms`（基于 coordinator deadline）；
          # 未下发时用 `fenced_at_ms + @default_fence_ttl_ms` 兜底。注意：DB
          # fence 行不持久化 deadline（对侧 schema 不扩列），deadline 只活在
          # in-memory pending_fence；Scene 重启后从 fenced_at_ms 保守重建。
          deadline_ms = fence_deadline_ms(opts, fenced_at_ms)

          fence_attrs = %{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            transaction_id: transaction_id,
            decision_version: decision_version,
            owner_region_id: owner_lease.region_id,
            owner_lease_id: owner_lease.lease_id,
            owner_scene_instance_ref: owner_lease.owner_scene_instance_ref,
            owner_epoch: owner_lease.owner_epoch,
            intents: normalized,
            fenced_at_ms: fenced_at_ms
          }

          case ChunkPendingTransactionStore.put_fence(fence_attrs) do
            {:ok, :inserted} ->
              fence = %{
                transaction_id: transaction_id,
                decision_version: decision_version,
                intents: normalized,
                fenced_at_ms: fenced_at_ms,
                deadline_ms: deadline_ms
              }

              {:ok, fence_summary(fence), %{state | pending_fence: fence}}

            {:error, reason} ->
              {:error, persist_fence_reason(reason)}
          end
        end
    end
  end

  # 阶段4 (2.2)：解析 prepare opts 里的 fence deadline。coordinator 传绝对
  # 毫秒时间戳 `:fence_deadline_ms`（与本进程 `System.system_time(:millisecond)`
  # 同一时钟域）；缺省 / 非法值回落到默认 TTL。
  defp fence_deadline_ms(opts, fenced_at_ms) do
    case Keyword.get(opts, :fence_deadline_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> fenced_at_ms + @default_fence_ttl_ms
    end
  end

  defp fetch_fence_owner_lease([%{lease: lease} | _]) when is_map(lease), do: {:ok, lease}
  defp fetch_fence_owner_lease(_intents), do: {:error, :missing_lease}

  defp persist_fence_reason(:fence_already_present), do: :fence_already_present
  defp persist_fence_reason(:invalid_fence_attrs), do: :fence_persist_failed
  defp persist_fence_reason(:fence_persist_failed), do: :fence_persist_failed
  defp persist_fence_reason(reason) when is_atom(reason), do: reason
  defp persist_fence_reason(_other), do: :fence_persist_failed

  defp commit_transaction_in_state(state, transaction_id) do
    case state.pending_fence do
      %{transaction_id: ^transaction_id, intents: intents} ->
        commit_prepared_intents(state, transaction_id, intents)

      %{transaction_id: holder} ->
        # 另一个事务正持有 fence。但若**本** transaction_id 已 durable 提交过
        # （fence 已释放、随后别的事务又 prepare 占住 fence），重投递仍应幂等回
        # durable，而不是误报“被别人占用”。先查已提交记录。
        case already_durably_committed(state, transaction_id) do
          {:ok, commit_version} ->
            {:committed_idempotent, commit_version}

          :error ->
            {:error, {:chunk_fence_owned_by_another_transaction, holder}}
        end

      nil ->
        # 阶段4 / world-2pc 跨侧幂等(B2)：fence 不在了。两种情况：
        #   1. 本事务**已 durable 提交**(scene 端已 fence 删 + hot swap，但 world
        #      可能尚未记下该 participant 的 durable-ack) → world 重投递 commit。
        #      此时必须**幂等回 durable**，让 world 收到 durable-ack 闭环，否则跨侧
        #      liveness 死锁。
        #   2. 从未 prepare 过该事务 → 真正的 :transaction_not_prepared。
        case already_durably_committed(state, transaction_id) do
          {:ok, commit_version} ->
            {:committed_idempotent, commit_version}

          :error ->
            {:error, :transaction_not_prepared}
        end
    end
  end

  # 该 transaction_id 是否已被本 chunk durable 提交过(在 last_durable_commits 里)。
  defp already_durably_committed(state, transaction_id) do
    case Map.fetch(state.last_durable_commits, transaction_id) do
      {:ok, commit_version} -> {:ok, commit_version}
      :error -> :error
    end
  end

  # 记录一笔已 durable 提交的事务,供后续 commit 重投递做幂等 durable-ack。
  defp record_durable_commit(state, transaction_id, commit_version) do
    %{
      state
      | last_durable_commits: Map.put(state.last_durable_commits, transaction_id, commit_version)
    }
  end

  # 阶段4 (4.5)：commit 的 durable barrier 核心。
  #
  # 关键不变式：在 durable-ack 之前**绝不推进 hot `state.storage`**。candidate
  # storage 只活在 pending_commit_ack 里，durable 成功才 swap 进 state。这样：
  #   * persist 失败 → hot 仍是 commit 前版本 → coordinator 重投递 commit 时
  #     重新 build 出同一 candidate（同一目标 version），重新 enqueue persist，
  #     天然幂等且不会出现“hot 已变但 DB 没跟上、重投递又判无变更跳过持久化”
  #     的丢库窗口。
  #   * persist 成功 → swap hot=candidate，删 fence，reply durable-ack。
  defp commit_prepared_intents(state, transaction_id, intents) do
    with :ok <- validate_batch_scope(state, intents),
         :ok <- validate_batch_preconditions(state, intents),
         :ok <- validate_apply_batch_occupancy(state, intents),
         {:ok, raw_storage, changed_count, skipped_count} <-
           build_intents_storage(state.storage, intents) do
      candidate_storage = Storage.refresh_chunk_object_refs(raw_storage)
      request_id = intents |> List.first() |> Map.fetch!(:request_id)
      return_snapshot_payload? = return_snapshot_payload?(intents)

      snapshot_payload =
        maybe_encode_snapshot_payload(candidate_storage, request_id, return_snapshot_payload?)

      lease = intents |> List.first() |> Map.fetch!(:lease)

      if changed_count > 0 do
        # 注意：enqueue 持久化的是 candidate_storage（带新 version），但
        # state.storage 维持不变（仍是 commit 前版本）。
        case enqueue_snapshot_persist(
               state,
               lease,
               state.chunk_coord,
               candidate_storage,
               snapshot_payload_for_persist(snapshot_payload, return_snapshot_payload?)
             ) do
          {:ok, persist_result, persist_ref, state_with_task} ->
            reply =
              batch_intent_reply(
                candidate_storage,
                lease,
                persist_result,
                snapshot_payload,
                changed_count,
                skipped_count,
                persist_ref
              )

            ack = %{
              from: nil,
              persist_ref: persist_ref,
              transaction_id: transaction_id,
              commit_version: candidate_storage.chunk_version,
              # candidate / damage 在 durable 成功时才落地到 hot state。
              candidate_storage: candidate_storage,
              lease: lease,
              damage_attribution: collect_damage_attribution(state.storage, intents),
              reply: reply,
              intents: intents,
              # state_before 仅用于 durable 成功后的 delta 推送基线。
              state_before: state
            }

            {:durable_pending, ack, state_with_task}

          {:error, reason} ->
            {:error, reason}
        end
      else
        # changed_count == 0：无 persist，本身 durable（DB 已是该状态或本就为空）。
        # 交回 handle_call 同步释放 fence，hot storage 不变。
        reply =
          batch_intent_reply(
            candidate_storage,
            lease,
            :unchanged,
            snapshot_payload,
            changed_count,
            skipped_count,
            nil
          )

        {:committed_noop, reply, state, intents}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # 阶段4 (4.5)：无变更 commit 的 fence 释放（同步路径，已 durable）。
  defp finalize_committed_noop(state, transaction_id) do
    delete_persisted_fence(state, transaction_id, :commit)
    %{state | pending_fence: nil}
  end

  # 阶段4 (4.5)②③：durable join 的收口。给定刚完成 / 刚 DOWN 的 persist ref 与
  # 其 result，若该 ref 对应一个等待 durable-ack 的 commit，则按成功/失败分流：
  #
  # * 成功（`{:ok, _}`）：再做契约 #3④ 的屏障校验——确认 DB chunk_version 已
  #   >= 本次 commit version，确认通过才删 fence + reply {:ok, durable-ack}；
  #   屏障校验失败（DB 落后 / 不可达）按失败处理，保留 fence。
  # * 失败（`{:error, _}` / Task :DOWN）：**保留 fence + pending_fence**，
  #   reply {:error, :persist_failed}，决定权交回 coordinator 重投递 commit。
  #
  # 非 commit ack 的普通 ref（如直写 apply_intent 的 async persist）此处无对应
  # 条目，原样返回 state。
  defp resolve_pending_commit_ack(state, ref, result) do
    case Map.pop(state.pending_commit_acks, ref) do
      {nil, _acks} ->
        state

      {ack, remaining_acks} ->
        state = %{state | pending_commit_acks: remaining_acks}

        case commit_persist_durable?(state, result, ack) do
          :ok -> finalize_committed_durable(state, ack)
          {:error, reason} -> finalize_committed_failed(state, ack, reason)
        end
    end
  end

  # 契约 #3④：删 fence 前确认 DB chunk_version >= 本次 commit version。persist
  # 已回 {:ok}（store 内部已用版本围栏拒绝 stale），这里再独立读回一次 DB 版本
  # 做强校验，避免误把“尚未落库”的状态当 durable。
  defp commit_persist_durable?(_state, {:error, reason}, _ack) do
    {:error, {:persist_failed, reason}}
  end

  defp commit_persist_durable?(state, {:ok, _put_result}, ack) do
    case safe_get_snapshot(state.logical_scene_id, state.chunk_coord) do
      {:ok, snapshot} ->
        if snapshot.chunk_version >= ack.commit_version do
          :ok
        else
          {:error,
           {:durable_barrier_unmet,
            %{db_version: snapshot.chunk_version, commit_version: ack.commit_version}}}
        end

      {:error, reason} ->
        {:error, {:durable_barrier_check_failed, reason}}
    end
  end

  # durable 成功：swap hot=candidate + 删 fence + 清 pending_fence + 推 commit
  # delta + emit committed + reply {:ok, durable-ack}。durable-ack 携带
  # `durable?: true` 与 `durable_chunk_version`，供 world 侧做全-participant
  # durable barrier。
  #
  # 关键：hot `state.storage` 在此刻（durable 成功）才推进到 candidate；在此之前
  # hot 一直是 commit 前版本（见 commit_prepared_intents 的不变式说明）。
  defp finalize_committed_durable(state, ack) do
    transaction_id = ack.transaction_id
    state_before = ack.state_before
    reply = ack.reply

    # swap hot=candidate + 刷新 lease（commit 用的是 fence owner lease）。
    state =
      %{state | storage: ack.candidate_storage, lease: ack.lease}
      |> promote_authorized_on_write()

    # damage attribution 推迟到 durable 成功才 dispatch（与写一致落地）。
    dispatch_damage_async(state, ack.damage_attribution)

    state = finalize_committed_noop(state, transaction_id)
    # 记录已 durable 提交,供后续 commit 重投递做幂等 durable-ack(B2 跨侧幂等)。
    state = record_durable_commit(state, transaction_id, ack.commit_version)

    # 阶段2.4：durable swap 后热 storage 可能带新 dirty —— 刷活动 + 按需 arm。
    state =
      state
      |> maybe_schedule_auto_circuit_refresh(reply.changed?)
      |> post_write_lifecycle()

    emit_transaction_event(state, transaction_id, "voxel_chunk_transaction_committed", %{
      chunk_version: state.storage.chunk_version,
      snapshot_bytes: byte_size(reply.snapshot_payload),
      changed?: reply.changed?,
      changed_count: reply.changed_count,
      skipped_count: reply.skipped_count,
      intent_count: length(ack.intents),
      persist_result: reply.persist_result,
      durable?: true,
      durable_chunk_version: ack.commit_version
    })

    if reply.changed? do
      push_batch_outcome(state_before, state, ack.intents, :commit_transaction)
    end

    durable_reply =
      reply
      |> Map.put(:durable?, true)
      |> Map.put(:durable_chunk_version, ack.commit_version)
      |> Map.put(:persist_result, :durable)

    GenServer.reply(ack.from, {:ok, durable_reply})

    state
  end

  # durable 失败：保留 fence（pending_fence 不动）+ hot storage 维持 commit 前
  # 版本（candidate 从未 swap 进 state）+ reply {:error, :persist_failed}。
  # fence 仍在 → 后续除该事务外的 apply 仍被拒；coordinator 重投递 commit 时
  # commit_prepared_intents 会以**未变的 pre-commit storage** 为基重新 build 出
  # 同一 candidate（同一目标 version）+ 重新 enqueue persist，天然幂等；DB 版本
  # 围栏保证不会回退。
  defp finalize_committed_failed(state, ack, reason) do
    emit_transaction_event(
      state,
      ack.transaction_id,
      "voxel_chunk_transaction_commit_not_durable",
      %{
        commit_version: ack.commit_version,
        reason: inspect(reason)
      }
    )

    GenServer.reply(ack.from, {:error, :persist_failed})

    state
  end

  defp abort_transaction_in_state(state, transaction_id) do
    case state.pending_fence do
      %{transaction_id: ^transaction_id} ->
        delete_persisted_fence(state, transaction_id, :abort)
        # abort 释放 fence 后 chunk 可能立即变空闲；abort 本身是 World 触达，
        # 算活动，刷新静默窗口避免“刚 abort 就被同一节拍误驱”。
        {true, mark_activity(%{state | pending_fence: nil})}

      _other ->
        {false, state}
    end
  end

  # ---------------------------------------------------------------------------
  # 阶段2.4：空闲驱逐状态机
  # ---------------------------------------------------------------------------

  # 是否满足“可被空闲驱逐”的全部前置条件。这是 chunk 侧的唯一真相判定，
  # 同时被 maybe_request_eviction（请求侧）与 confirm_evict（facade 复核侧）
  # 复用，保证两侧用同一套条件，避免请求/复核口径漂移。
  #
  # 驱逐前置（全部满足才算空闲）：
  #   1. 无订阅者（subscribers 空）——还有人看就不能回收；
  #   2. 无 field region（field_regions 空）——本地场仍在跑就不能回收；
  #   3. 无 pending fence（未持有事务栅栏）——事务进行中不能回收；
  #   4. 无 in-flight commit durable-ack（pending_commit_acks 空）——commit
  #      还在等持久化确认不能回收；
  #   5. 无在途异步 persist（async_persists 空）——避免把正在落库的状态拖走；
  #   6. 非在跑模拟（not simulation_active?）——有 simulator 且 dirty（tick 已
  #      arm，正持续 tick）属于“活跃 chunk”，不被误驱；
  #   7. lease 失效或未持有（lease_stale?）——仍持有效 lease 说明 World 认为
  #      该 coord 归本节点权威，热着更划算，不主动回收；
  #   8. 静默窗口已过（距 last_activity_ms 超过 idle_evict_silence_ms）。
  #
  # 注意：degraded / unauthorized 态天然满足 1-6（无订阅/无写/不模拟），且
  # lease 失效或未持有，静默后也会被回收——这正是我们想要的（坏 coord 不空占
  # 进程）。
  defp idle_evict_candidate?(state) do
    map_size(state.subscribers) == 0 and
      map_size(state.field_regions) == 0 and
      is_nil(state.pending_fence) and
      map_size(state.pending_commit_acks) == 0 and
      map_size(state.async_persists) == 0 and
      not simulation_active?(state) and
      lease_stale?(state.lease) and
      now_ms() - state.last_activity_ms >= state.idle_evict_silence_ms
  end

  # 是否正在跑模拟：有 in-flight tick（tick_armed?）或仍 (有 simulator 且
  # dirty)。dirty 清空且 tick 停 arm 后回到“可被回收”态——这正是按需 tick 的
  # 收敛点。
  defp simulation_active?(state) do
    state.tick_armed? or simulation_due?(state)
  end

  # 生命周期节拍里判断是否请求驱逐。满足空闲条件且尚未请求过 → cast
  # {:request_evict, key, self()} 给 facade，由 facade 单点串行复核 + 退场。
  # 进程**不自停**：退场所有权归 facade（DynamicSupervisor.terminate_child +
  # 删注册项），避免与监督树/注册表竞争。
  defp maybe_request_eviction(%{evict_requested?: true} = state), do: state

  defp maybe_request_eviction(state) do
    if idle_evict_candidate?(state) do
      request_eviction_from_directory(state)

      CliObserve.emit("voxel_chunk_evict_requested", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          chunk_version: state.storage.chunk_version,
          mode: state.mode,
          silence_ms: now_ms() - state.last_activity_ms
        }
      end)

      %{state | evict_requested?: true}
    else
      state
    end
  end

  defp request_eviction_from_directory(state) do
    key = {state.logical_scene_id, state.chunk_coord}

    # facade 可能正在重启（崩溃窗口）；cast 到死名/死 pid 会抛 —— 吞掉，下一个
    # 生命周期节拍会重试（evict_requested? 仍为 false，因为本次未置位）。
    try do
      GenServer.cast(state.chunk_directory, {:request_evict, key, self()})
    catch
      _kind, _err -> :ok
    end
  end

  # 驱逐前持久化：尽力把当前 storage 落库，确保驱逐不丢热状态。返回：
  #
  #   * `{:ok, :persisted}`       —— 成功落库（token 有效）。
  #   * `{:ok, :no_lease}`        —— 无 lease（unauthorized / 从未授权）：没有
  #     可写 token，也没有需要落库的权威增量，直接放行。
  #   * `{:ok, :authority_lapsed}` —— lease 已失去权威（token 过期 / 区域 token
  #     不在）。这是 stale-lease chunk 被驱逐的正常路径：**权威写路径
  #     （apply_intent/commit）是 durable-on-reply**，所以最后一次有效写早已落库；
  #     此刻热状态相对 DB 没有未落库的**权威**增量（put_solid_block 之类的非
  #     权威 dev/test 直写不算）。授权已交回 World，放行驱逐。
  #   * `{:error, reason}`        —— 其它失败（DB 不可达等瞬时故障）→ 取消驱逐，
  #     下一轮再试，绝不在瞬时故障下丢状态。
  defp persist_before_evict(%{lease: nil}), do: {:ok, :no_lease}

  defp persist_before_evict(state) do
    payload = encode_snapshot_payload(state.storage, 0)

    case persist_snapshot(state.lease, state.chunk_coord, state.storage, payload) do
      {:ok, _result} -> {:ok, :persisted}
      :ok -> {:ok, :persisted}
      {:error, reason} -> classify_evict_persist_error(reason)
      other -> {:error, {:unexpected_persist_result, other}}
    end
  rescue
    exception -> {:error, {:persist_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:persist_exit, reason}}
  end

  # 权威已失效（lease 过期 / 区域 token 不在）→ 视为 authority_lapsed，放行驱逐
  # （最后一次权威写早已 durable）。其余视为瞬时失败 → 取消驱逐重试。
  defp classify_evict_persist_error(reason)
       when reason in [:lease_expired, :unknown_region_token, :missing_lease, :stale_token] do
    {:ok, :authority_lapsed}
  end

  defp classify_evict_persist_error(reason), do: {:error, reason}

  # 阶段4 (2.2)：TTL 兜底——检查并作废过期 prepared fence。
  defp maybe_void_expired_fence(%{pending_fence: nil} = state), do: state

  defp maybe_void_expired_fence(%{pending_fence: fence} = state) do
    cond do
      # 已进入 commit 的 durable 等待（pending_commit_acks 里有该事务的 ref）
      # 不能被 TTL 作废——决定已记录，正在重投递持久化（契约 #2 决定不可逆）。
      commit_in_flight?(state, fence.transaction_id) ->
        state

      not is_integer(Map.get(fence, :deadline_ms)) ->
        # 无 deadline 的旧 fence（理论上不该出现）——跳过，交给 World reaper。
        state

      now_ms() < fence.deadline_ms ->
        state

      true ->
        void_expired_fence(state, fence)
    end
  end

  defp commit_in_flight?(state, transaction_id) do
    Enum.any?(state.pending_commit_acks, fn {_ref, ack} ->
      ack.transaction_id == transaction_id
    end)
  end

  defp void_expired_fence(state, fence) do
    delete_persisted_fence(state, fence.transaction_id, :ttl_expired)

    CliObserve.emit("voxel_chunk_pending_transaction_ttl_expired", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        transaction_id: fence.transaction_id,
        decision_version: Map.get(fence, :decision_version),
        fenced_at_ms: Map.get(fence, :fenced_at_ms),
        deadline_ms: fence.deadline_ms,
        now_ms: now_ms()
      }
    end)

    %{state | pending_fence: nil}
  end

  defp delete_persisted_fence(state, transaction_id, reason) do
    case ChunkPendingTransactionStore.delete_fence(state.logical_scene_id, state.chunk_coord) do
      {:ok, _} ->
        :ok

      {:error, error_reason} ->
        # The persisted row may now linger. The next ChunkProcess.init load
        # will see the orphan, fail the lease check (since we are still the
        # current process), and clean it up — but emit observe so operators
        # can spot the divergence.
        CliObserve.emit("voxel_chunk_pending_transaction_delete_failed", fn ->
          %{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            transaction_id: transaction_id,
            reason: inspect(error_reason),
            release_reason: reason
          }
        end)

        :ok
    end
  end

  defp fence_summary(fence) do
    intents = fence.intents
    chunk_coord = if first = List.first(intents), do: first.chunk_coord, else: nil

    %{
      transaction_id: fence.transaction_id,
      chunk_coord: chunk_coord,
      intent_count: length(intents),
      fenced_at_ms: fence.fenced_at_ms
    }
  end

  # 阶段4：debug_state 用的 fence 摘要（含 deadline_ms，供 TTL 测试断言）。
  defp pending_fence_summary(nil), do: nil

  defp pending_fence_summary(fence) do
    %{
      transaction_id: fence.transaction_id,
      decision_version: Map.get(fence, :decision_version),
      intent_count: length(fence.intents),
      fenced_at_ms: Map.get(fence, :fenced_at_ms),
      deadline_ms: Map.get(fence, :deadline_ms)
    }
  end

  defp emit_transaction_event(state, transaction_id, event, payload) when is_map(payload) do
    CliObserve.emit(event, fn ->
      Map.merge(
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          transaction_id: transaction_id
        },
        payload
      )
    end)
  end

  defp now_ms, do: System.system_time(:millisecond)

  # 阶段4 (4.5)：async persist 的故障注入 seam（仅供故障注入测试）。
  # 读 `:scene_server, :voxel_persist_fault`，默认 nil（生产路径无任何效果）。
  # 取值：`:crash` | `{:result, term()}`。
  defp persist_fault_hook do
    Application.get_env(:scene_server, :voxel_persist_fault)
  end

  defp validate_intent_scope(state, intent) do
    cond do
      intent.logical_scene_id != state.logical_scene_id ->
        {:error, :logical_scene_mismatch}

      intent.chunk_coord != state.chunk_coord ->
        {:error, :chunk_coord_mismatch}

      intent.lease.logical_scene_id != state.logical_scene_id ->
        {:error, :lease_logical_scene_mismatch}

      not chunk_in_lease_bounds?(state.chunk_coord, intent.lease) ->
        {:error, :chunk_out_of_bounds}

      true ->
        :ok
    end
  end

  defp validate_batch_scope(state, intents) do
    Enum.reduce_while(intents, :ok, fn intent, :ok ->
      case validate_intent_scope(state, intent) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Optimistic concurrency check for typed `VoxelEditIntent` (0x70).
  #
  # Each intent may pin a baseline `expected_chunk_version` (full chunk) and/or
  # `expected_cell_hash` (the targeted macro cell). Both are nullable; the
  # caller-side codec resolves the wire sentinels (`0xFF...FF` / `0xFFFF_FFFF`)
  # to `nil` so a "client did not pin" intent passes through unchanged. If the
  # current state diverges from a pinned value the intent is rejected with
  # `:stale_chunk_version` / `:stale_cell_hash`, which the Gate maps to the
  # protocol-level `Stale` (3) `VoxelIntentResult` code.
  defp validate_intent_preconditions(state, intent) do
    with :ok <- validate_expected_chunk_version(state, intent),
         :ok <- validate_expected_cell_hash(state, intent) do
      :ok
    end
  end

  defp validate_expected_chunk_version(_state, %{expected_chunk_version: nil}), do: :ok

  defp validate_expected_chunk_version(state, %{expected_chunk_version: expected})
       when is_integer(expected) do
    if state.storage.chunk_version == expected,
      do: :ok,
      else: {:error, :stale_chunk_version}
  end

  defp validate_expected_chunk_version(_state, _intent), do: :ok

  defp validate_expected_cell_hash(_state, %{expected_cell_hash: nil}), do: :ok

  defp validate_expected_cell_hash(state, %{expected_cell_hash: expected, macro: macro_index})
       when is_integer(expected) do
    header = Storage.macro_header_at(state.storage, macro_index)

    if header.cell_hash == expected,
      do: :ok,
      else: {:error, :stale_cell_hash}
  end

  defp validate_expected_cell_hash(_state, _intent), do: :ok

  defp validate_batch_preconditions(state, intents) do
    Enum.reduce_while(intents, :ok, fn intent, :ok ->
      case validate_intent_preconditions(state, intent) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Phase A1-2:整 batch occupancy precheck。任何一 intent 跟当前 storage
  # 冲突(macro 已是 solid / 目标 micro slot 已占)→ 整个 transaction abort,
  # gate 端 wire 响应 :rejected 给客户端。Phase 3 transaction 语义是"全成功
  # 或全失败",这里把"全失败"判据从 commit 推到 prepare,让 prefab 防覆盖
  # 在 fence 写表前就拒绝,zero-cost cleanup。
  #
  # 同 batch 内的内部冲突(2 个 intent 写同一 micro slot)用一个 in-batch
  # claimed-set 跟踪,后到的 intent 也算 occupied。
  defp validate_batch_occupancy(state, intents) do
    storage = state.storage

    intents
    |> Enum.reduce_while({:ok, %{}}, fn intent, {:ok, claimed} ->
      case validate_intent_occupancy(storage, intent, claimed) do
        {:ok, next_claimed} -> {:cont, {:ok, next_claimed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _claimed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_apply_batch_occupancy(state, intents) do
    if Enum.any?(intents, fn intent -> Keyword.get(intent.opts, :reject_occupied, false) end) do
      validate_batch_occupancy(state, intents)
    else
      :ok
    end
  end

  defp return_snapshot_payload?(intents) do
    Enum.all?(intents, fn intent -> Keyword.get(intent.opts, :return_snapshot_payload, true) end)
  end

  defp maybe_encode_snapshot_payload(storage, request_id, true),
    do: encode_snapshot_payload(storage, request_id)

  defp maybe_encode_snapshot_payload(_storage, _request_id, false), do: <<>>

  defp snapshot_payload_for_persist(_snapshot_payload, _return_snapshot_payload?), do: nil

  defp validate_intent_occupancy(
         storage,
         %{operation: :put_micro_block, macro: macro_index, micro_slot: slot_index},
         claimed
       ) do
    cond do
      solid_cell_fast?(storage, macro_index) ->
        {:error, :cannot_micro_edit_solid_macro}

      micro_slot_occupied_fast?(storage, macro_index, slot_index) ->
        {:error, :micro_slot_already_occupied}

      MapSet.member?(Map.get(claimed, macro_index, MapSet.new()), slot_index) ->
        {:error, :micro_slot_already_occupied}

      true ->
        next_claimed =
          Map.update(
            claimed,
            macro_index,
            MapSet.new([slot_index]),
            &MapSet.put(&1, slot_index)
          )

        {:ok, next_claimed}
    end
  end

  # Other operations(:put_solid_block / :break_block / :clear_micro_block)
  # 暂不 occupancy precheck — Phase A1-2 范围只覆盖 prefab 防覆盖
  # (走 :put_micro_block)。non-micro 路径的 idempotency 行为保持现状,留给
  # 后续 step 收紧。
  defp validate_intent_occupancy(_storage, _intent, claimed), do: {:ok, claimed}

  defp validate_loaded_snapshot(state, storage) do
    cond do
      storage.logical_scene_id != state.logical_scene_id ->
        {:error, :logical_scene_mismatch}

      storage.chunk_coord != state.chunk_coord ->
        {:error, :chunk_coord_mismatch}

      storage.chunk_version < state.storage.chunk_version ->
        {:error, :stale_prewarm_snapshot}

      true ->
        :ok
    end
  end

  defp build_intent_storage(storage, %{operation: :put_solid_block} = intent) do
    block = intent.block
    next_version = storage.chunk_version + 1

    opts =
      intent.opts
      |> Keyword.put_new(:cell_version, next_version)
      |> Keyword.put_new_lazy(:cell_hash, fn -> Hash.digest32(inspect(block)) end)

    if solid_block_matches?(storage, intent.macro, block) do
      {:ok, storage, false}
    else
      storage =
        storage
        |> Storage.put_solid_block(intent.macro, block, opts)
        |> bump_chunk_version()

      {:ok, storage, true}
    end
  rescue
    _exception in ArgumentError -> {:error, :invalid_voxel_intent}
  end

  defp build_intent_storage(storage, %{operation: :break_block} = intent) do
    next_version = storage.chunk_version + 1

    opts =
      intent.opts
      |> Keyword.put_new(:cell_version, next_version)
      |> Keyword.put_new(:cell_hash, 0)

    if empty_cell?(storage, intent.macro) do
      {:ok, storage, false}
    else
      storage =
        storage
        |> Storage.clear_macro_cell(intent.macro, opts)
        |> bump_chunk_version()

      {:ok, storage, true}
    end
  rescue
    _exception in ArgumentError -> {:error, :invalid_voxel_intent}
  end

  defp build_intent_storage(storage, %{operation: :put_micro_block} = intent) do
    next_version = storage.chunk_version + 1

    opts =
      intent.opts
      |> Keyword.put_new(:cell_version, next_version)
      |> Keyword.put_new(:cell_hash, 0)

    cond do
      solid_cell?(storage, intent.macro) ->
        {:error, :cannot_micro_edit_solid_macro}

      micro_slot_occupied?(storage, intent.macro, intent.micro_slot) ->
        {:error, :micro_slot_already_occupied}

      true ->
        storage =
          storage
          |> Storage.put_micro_block(intent.macro, intent.micro_slot, intent.micro_layer, opts)
          |> bump_chunk_version()

        {:ok, storage, true}
    end
  rescue
    _exception in ArgumentError -> {:error, :invalid_voxel_intent}
  end

  defp build_intent_storage(storage, %{operation: :clear_micro_block} = intent) do
    next_version = storage.chunk_version + 1

    opts =
      intent.opts
      |> Keyword.put_new(:cell_version, next_version)
      |> Keyword.put_new(:cell_hash, 0)

    cond do
      solid_cell?(storage, intent.macro) ->
        {:error, :cannot_micro_edit_solid_macro}

      not micro_slot_occupied?(storage, intent.macro, intent.micro_slot) ->
        {:ok, storage, false}

      true ->
        storage =
          storage
          |> Storage.clear_micro_block(intent.macro, intent.micro_slot, opts)
          |> bump_chunk_version()

        {:ok, storage, true}
    end
  rescue
    _exception in ArgumentError -> {:error, :invalid_voxel_intent}
  end

  defp build_intents_storage(storage, intents) do
    next_version = storage.chunk_version + 1

    case detect_solid_block_batch(storage, intents, next_version) do
      {:solid_batch, entries, changed_count, skipped_count} when changed_count > 0 ->
        next_storage =
          storage
          |> Storage.put_solid_blocks(entries)
          |> bump_chunk_version()

        {:ok, next_storage, changed_count, skipped_count}

      {:solid_batch, _entries, 0, skipped_count} ->
        {:ok, storage, 0, skipped_count}

      :mixed ->
        build_mixed_or_micro_intents_storage(storage, intents, next_version)
    end
  rescue
    _exception in ArgumentError -> {:error, :invalid_voxel_intent}
  end

  defp build_mixed_or_micro_intents_storage(storage, intents, next_version) do
    case detect_micro_block_batches(storage, intents) do
      {:micro_batches, groups, changed_count, skipped_count} when changed_count > 0 ->
        # Phase A1-1b fast-path:整 batch 都是 :put_micro_block on same macro
        # (sphere/cylinder/stairs prefab 全套场景)→ 一次 Storage.put_micro_blocks
        # 替代 N 次 put_micro_block,从 O(macro_count × N) 降到 O(macro_count + N)。
        # 实测 sphere 280 slot:1.5s → ~50ms。
        # Boundary-snapped prefabs can touch several macro cells. Groups keep
        # the hot path to one storage normalization per touched macro.
        opts =
          [cell_version: next_version, cell_hash: 0]

        next_storage =
          groups
          |> Enum.reduce(storage, fn {macro, pairs}, acc ->
            Storage.put_micro_blocks(acc, macro, pairs, opts)
          end)
          |> bump_chunk_version()

        {:ok, next_storage, changed_count, skipped_count}

      {:micro_batches, _groups, 0, skipped_count} ->
        {:ok, storage, 0, skipped_count}

      :mixed ->
        {storage, changed_count, skipped_count} =
          Enum.reduce(intents, {storage, 0, 0}, fn intent, {acc_storage, changed, skipped} ->
            {:ok, next_storage, changed?} =
              build_intent_storage_without_chunk_bump(acc_storage, intent, next_version)

            if changed? do
              {next_storage, changed + 1, skipped}
            else
              {next_storage, changed, skipped + 1}
            end
          end)

        storage =
          if changed_count > 0 do
            bump_chunk_version(storage)
          else
            storage
          end

        {:ok, storage, changed_count, skipped_count}
    end
  end

  defp detect_solid_block_batch(storage, intents, next_version) do
    if Enum.all?(intents, fn intent -> intent.operation == :put_solid_block end) do
      Enum.reduce_while(intents, {[], MapSet.new(), 0, 0}, fn intent,
                                                              {entries, seen, changed, skipped} ->
        if MapSet.member?(seen, intent.macro) do
          {:halt, :mixed}
        else
          block = intent.block

          opts =
            intent.opts
            |> Keyword.put_new(:cell_version, next_version)
            |> Keyword.put_new_lazy(:cell_hash, fn -> Hash.digest32(inspect(block)) end)

          seen = MapSet.put(seen, intent.macro)

          if solid_block_matches?(storage, intent.macro, block) do
            {:cont, {entries, seen, changed, skipped + 1}}
          else
            {:cont, {[{intent.macro, block, opts} | entries], seen, changed + 1, skipped}}
          end
        end
      end)
      |> case do
        :mixed ->
          :mixed

        {entries, _seen, changed_count, skipped_count} ->
          {:solid_batch, Enum.reverse(entries), changed_count, skipped_count}
      end
    else
      :mixed
    end
  end

  # Phase A1-1b detector:返回 `{:batch, macro_index, [{slot, layer_attrs}, ...]}`
  # 当且仅当 intents 列表非空,所有 intent 都是 `:put_micro_block`,target 同一个
  # macro。否则 `:mixed`,fallback 到逐 intent path。
  defp detect_micro_block_batches(_storage, []), do: :mixed

  defp detect_micro_block_batches(storage, intents) do
    if Enum.all?(intents, fn intent -> intent.operation == :put_micro_block end) do
      {groups, order, _claimed, changed_count, skipped_count} =
        Enum.reduce(intents, {%{}, [], %{}, 0, 0}, fn
          %{macro: macro_index, micro_slot: slot_index, micro_layer: layer},
          {groups, order, claimed, changed, skipped} ->
            macro_claimed = Map.get(claimed, macro_index, MapSet.new())

            cond do
              micro_slot_occupied_fast?(storage, macro_index, slot_index) ->
                {groups, order, claimed, changed, skipped + 1}

              MapSet.member?(macro_claimed, slot_index) ->
                {groups, order, claimed, changed, skipped + 1}

              true ->
                order =
                  if Map.has_key?(groups, macro_index), do: order, else: order ++ [macro_index]

                groups =
                  Map.update(groups, macro_index, [{slot_index, layer}], fn pairs ->
                    [{slot_index, layer} | pairs]
                  end)

                claimed = Map.put(claimed, macro_index, MapSet.put(macro_claimed, slot_index))

                {groups, order, claimed, changed + 1, skipped}
            end
        end)

      groups =
        Enum.map(order, fn macro_index ->
          {macro_index, groups |> Map.fetch!(macro_index) |> Enum.reverse()}
        end)

      {:micro_batches, groups, changed_count, skipped_count}
    else
      :mixed
    end
  end

  defp build_intent_storage_without_chunk_bump(
         storage,
         %{operation: :put_solid_block} = intent,
         next_version
       ) do
    block = intent.block

    opts =
      intent.opts
      |> Keyword.put_new(:cell_version, next_version)
      |> Keyword.put_new_lazy(:cell_hash, fn -> Hash.digest32(inspect(block)) end)

    if solid_block_matches?(storage, intent.macro, block) do
      {:ok, storage, false}
    else
      {:ok, Storage.put_solid_block(storage, intent.macro, block, opts), true}
    end
  end

  defp build_intent_storage_without_chunk_bump(
         storage,
         %{operation: :break_block} = intent,
         next_version
       ) do
    opts =
      intent.opts
      |> Keyword.put_new(:cell_version, next_version)
      |> Keyword.put_new(:cell_hash, 0)

    if empty_cell?(storage, intent.macro) do
      {:ok, storage, false}
    else
      {:ok, Storage.clear_macro_cell(storage, intent.macro, opts), true}
    end
  end

  defp build_intent_storage_without_chunk_bump(
         storage,
         %{operation: :put_micro_block} = intent,
         next_version
       ) do
    opts =
      intent.opts
      |> Keyword.put_new(:cell_version, next_version)
      |> Keyword.put_new(:cell_hash, 0)

    # Batch path stays idempotent: an already-occupied slot is a skip,
    # not an error (matches `:put_solid_block` batch behaviour). Single-intent
    # callers go through `build_intent_storage/2`, which DOES surface
    # `:micro_slot_already_occupied` as an error.
    if micro_slot_occupied?(storage, intent.macro, intent.micro_slot) do
      {:ok, storage, false}
    else
      {:ok,
       Storage.put_micro_block(
         storage,
         intent.macro,
         intent.micro_slot,
         intent.micro_layer,
         opts
       ), true}
    end
  end

  defp build_intent_storage_without_chunk_bump(
         storage,
         %{operation: :clear_micro_block} = intent,
         next_version
       ) do
    opts =
      intent.opts
      |> Keyword.put_new(:cell_version, next_version)
      |> Keyword.put_new(:cell_hash, 0)

    if not micro_slot_occupied?(storage, intent.macro, intent.micro_slot) do
      {:ok, storage, false}
    else
      {:ok, Storage.clear_micro_block(storage, intent.macro, intent.micro_slot, opts), true}
    end
  end

  # 阶段2.5:热路径随机读统一经 Storage accel(:array / map)做 O(1) 访问。
  # `Storage.fetch_macro_header/2` / `fetch_refined_cell/2` 在 accel 已建时是 O(1),
  # 未建时回退 list Enum.at(O(n))——所以这里要求 storage 已 ensure_accel(apply/
  # commit 路径已建,见 build_intent_storage / commit candidate)。
  defp macro_header_at_fast(%Storage{} = storage, macro_index)
       when is_integer(macro_index) do
    Storage.fetch_macro_header(storage, macro_index)
  end

  defp macro_header_at_fast(storage, macro_index) do
    Storage.macro_header_at(storage, macro_index)
  end

  defp refined_cell_at_fast(%Storage{} = storage, macro_index) do
    refined_mode = MacroCellHeader.cell_mode_refined()

    case macro_header_at_fast(storage, macro_index) do
      %{mode: ^refined_mode, payload_index: payload_index} ->
        Storage.fetch_refined_cell(storage, payload_index)

      _ ->
        nil
    end
  end

  defp refined_cell_at_fast(storage, macro_index) do
    Storage.refined_cell_at(storage, macro_index)
  end

  defp micro_slot_occupied_fast?(storage, macro_index, slot_index) do
    case refined_cell_at_fast(storage, macro_index) do
      nil ->
        false

      %{occupancy_words: words} ->
        word_idx = div(slot_index, 64)
        bit_idx = rem(slot_index, 64)
        word = Enum.at(words, word_idx)
        band(word, bsl(1, bit_idx)) != 0
    end
  end

  defp solid_cell_fast?(storage, macro_index) do
    macro_header_at_fast(storage, macro_index).mode ==
      MacroCellHeader.cell_mode_solid_block()
  end

  defp micro_slot_occupied?(storage, macro_index, slot_index) do
    case Storage.refined_cell_at(storage, macro_index) do
      nil ->
        false

      %{occupancy_words: words} ->
        word_idx = div(slot_index, 64)
        bit_idx = rem(slot_index, 64)
        word = Enum.at(words, word_idx)
        band(word, bsl(1, bit_idx)) != 0
    end
  end

  defp solid_block_matches?(storage, macro_index, block) do
    Storage.normal_block_at(storage, macro_index) == NormalBlockData.normalize!(block)
  end

  defp empty_cell?(storage, macro_index) do
    Storage.macro_header_at(storage, macro_index).mode == MacroCellHeader.cell_mode_empty()
  end

  defp solid_cell?(storage, macro_index) do
    Storage.macro_header_at(storage, macro_index).mode ==
      MacroCellHeader.cell_mode_solid_block()
  end

  defp build_temperature_attribute_storage(%Storage{} = storage, attrs) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_temperature_macro(attrs),
         {:ok, target_temperature} <- normalize_temperature_target(attrs) do
      target_raw = celsius_to_fixed32_raw(target_temperature)
      baseline_raw = celsius_to_fixed32_raw(20.0)
      attribute_delta_raw = target_raw - baseline_raw

      previous_raw =
        Storage.effective_attribute_at(storage, macro_index, @temperature_attribute_name)

      previous_temperature = fixed32_raw_to_celsius(previous_raw)

      density =
        effective_fixed32_float(storage, macro_index, @density_attribute_name, @min_density)

      specific_heat_capacity =
        effective_fixed32_float(
          storage,
          macro_index,
          @specific_heat_capacity_attribute_name,
          @min_specific_heat_capacity
        )

      heat_capacity_j_per_k = density * specific_heat_capacity * @voxel_volume_cubic_meter
      temperature_delta = target_temperature - previous_temperature
      heat_energy_joules = temperature_delta * heat_capacity_j_per_k

      cond do
        not solid_cell?(storage, macro_index) ->
          {:error, :temperature_target_not_solid}

        previous_raw == target_raw ->
          {:ok, storage,
           %{
             storage: storage,
             changed?: false,
             macro_index: macro_index,
             heat_energy_joules: 0.0,
             density: density,
             specific_heat_capacity: specific_heat_capacity,
             heat_capacity_j_per_k: heat_capacity_j_per_k,
             previous_temperature: previous_temperature,
             temperature_delta: 0.0,
             target_temperature: target_temperature,
             target_temperature_raw: target_raw,
             attribute_delta_raw: attribute_delta_raw,
             effective_temperature: target_temperature,
             effective_temperature_raw: target_raw,
             chunk_version: storage.chunk_version
           }}

        true ->
          next_version = storage.chunk_version + 1

          opts = [
            cell_version: next_version,
            cell_hash:
              Hash.digest32(
                inspect({:temperature_attribute, macro_index, attribute_delta_raw, next_version})
              )
          ]

          next_storage =
            storage
            |> Storage.put_attribute_for_cell(
              macro_index,
              @temperature_attribute_name,
              attribute_delta_raw,
              opts
            )
            |> bump_chunk_version()

          effective_raw =
            Storage.effective_attribute_at(next_storage, macro_index, @temperature_attribute_name)

          {:ok, next_storage,
           %{
             storage: next_storage,
             changed?: true,
             macro_index: macro_index,
             heat_energy_joules: heat_energy_joules,
             density: density,
             specific_heat_capacity: specific_heat_capacity,
             heat_capacity_j_per_k: heat_capacity_j_per_k,
             previous_temperature: previous_temperature,
             temperature_delta: temperature_delta,
             target_temperature: target_temperature,
             target_temperature_raw: target_raw,
             attribute_delta_raw: attribute_delta_raw,
             effective_temperature: fixed32_raw_to_celsius(effective_raw),
             effective_temperature_raw: effective_raw,
             chunk_version: next_storage.chunk_version
           }}
      end
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_temperature_attribute}
  end

  defp build_heat_energy_attribute_storage(%Storage{} = storage, attrs) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_temperature_macro(attrs),
         {:ok, heat_energy_joules} <- normalize_heat_energy_joules(attrs) do
      cond do
        not solid_cell?(storage, macro_index) ->
          {:error, :temperature_target_not_solid}

        true ->
          previous_raw =
            Storage.effective_attribute_at(storage, macro_index, @temperature_attribute_name)

          previous_temperature = fixed32_raw_to_celsius(previous_raw)

          density =
            effective_fixed32_float(storage, macro_index, @density_attribute_name, @min_density)

          specific_heat_capacity =
            effective_fixed32_float(
              storage,
              macro_index,
              @specific_heat_capacity_attribute_name,
              @min_specific_heat_capacity
            )

          heat_capacity_j_per_k =
            density * specific_heat_capacity * @voxel_volume_cubic_meter

          temperature_delta = heat_energy_joules / heat_capacity_j_per_k
          target_temperature = previous_temperature + temperature_delta
          target_raw = celsius_to_fixed32_raw(target_temperature)
          baseline_raw = celsius_to_fixed32_raw(20.0)
          attribute_delta_raw = target_raw - baseline_raw

          if target_raw == previous_raw do
            {:ok, storage,
             %{
               storage: storage,
               changed?: false,
               macro_index: macro_index,
               heat_energy_joules: heat_energy_joules,
               density: density,
               specific_heat_capacity: specific_heat_capacity,
               heat_capacity_j_per_k: heat_capacity_j_per_k,
               previous_temperature: previous_temperature,
               temperature_delta: 0.0,
               target_temperature: previous_temperature,
               target_temperature_raw: previous_raw,
               attribute_delta_raw: previous_raw - baseline_raw,
               effective_temperature: previous_temperature,
               effective_temperature_raw: previous_raw,
               chunk_version: storage.chunk_version
             }}
          else
            next_version = storage.chunk_version + 1

            opts = [
              cell_version: next_version,
              cell_hash:
                Hash.digest32(
                  inspect(
                    {:heat_energy, macro_index, heat_energy_joules, target_raw, next_version}
                  )
                )
            ]

            next_storage =
              storage
              |> Storage.put_attribute_for_cell(
                macro_index,
                @temperature_attribute_name,
                attribute_delta_raw,
                opts
              )
              |> bump_chunk_version()

            effective_raw =
              Storage.effective_attribute_at(
                next_storage,
                macro_index,
                @temperature_attribute_name
              )

            {:ok, next_storage,
             %{
               storage: next_storage,
               changed?: true,
               macro_index: macro_index,
               heat_energy_joules: heat_energy_joules,
               density: density,
               specific_heat_capacity: specific_heat_capacity,
               heat_capacity_j_per_k: heat_capacity_j_per_k,
               previous_temperature: previous_temperature,
               temperature_delta: temperature_delta,
               target_temperature: target_temperature,
               target_temperature_raw: target_raw,
               attribute_delta_raw: attribute_delta_raw,
               effective_temperature: fixed32_raw_to_celsius(effective_raw),
               effective_temperature_raw: effective_raw,
               chunk_version: next_storage.chunk_version
             }}
          end
      end
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_heat_energy_attribute}
  end

  defp apply_field_effect(state, effect, context) do
    case normalize_field_effect(effect) do
      {:ok, :write_voxel_attribute, attrs} ->
        apply_write_voxel_attribute_effect(state, attrs, context)

      {:ok, :transform_voxel_material, attrs} ->
        apply_transform_voxel_material_effect(state, attrs, context)

      {:ok, :clear_voxel_cell, attrs} ->
        apply_clear_voxel_cell_effect(state, attrs, context)

      {:ok, :apply_structural_damage, attrs} ->
        apply_structural_damage_effect(state, attrs, context)

      {:ok, :ensure_field_region, attrs} ->
        apply_ensure_field_region_effect(state, attrs, context)

      {:ok, :upsert_phenomenon_instance, attrs} ->
        apply_upsert_phenomenon_instance_effect(state, attrs, context)

      {:ok, :complete_phenomenon_instance, attrs} ->
        apply_complete_phenomenon_instance_effect(state, attrs, context)

      {:ok, action, _attrs} ->
        result = %{
          status: :rejected,
          action: action,
          reason: :unsupported_field_effect_action
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}

      {:error, result} ->
        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp normalize_field_effect({action, attrs}) when is_map(attrs) or is_list(attrs) do
    {:ok, normalize_field_effect_action(action), attrs_map(attrs)}
  end

  defp normalize_field_effect(%{action: action} = attrs) do
    {:ok, normalize_field_effect_action(action), attrs |> Map.delete(:action) |> attrs_map()}
  end

  defp normalize_field_effect(%{"action" => action} = attrs) do
    {:ok, normalize_field_effect_action(action), attrs |> Map.delete("action") |> attrs_map()}
  end

  defp normalize_field_effect(other) do
    {:error,
     %{
       status: :rejected,
       action: :unknown,
       reason: :invalid_field_effect,
       effect: inspect(other)
     }}
  end

  defp normalize_field_effect_action(:write_voxel_attribute), do: :write_voxel_attribute
  defp normalize_field_effect_action("write_voxel_attribute"), do: :write_voxel_attribute
  defp normalize_field_effect_action(:transform_voxel_material), do: :transform_voxel_material
  defp normalize_field_effect_action("transform_voxel_material"), do: :transform_voxel_material
  defp normalize_field_effect_action(:clear_voxel_cell), do: :clear_voxel_cell
  defp normalize_field_effect_action("clear_voxel_cell"), do: :clear_voxel_cell
  defp normalize_field_effect_action(:apply_structural_damage), do: :apply_structural_damage
  defp normalize_field_effect_action("apply_structural_damage"), do: :apply_structural_damage
  defp normalize_field_effect_action(:ensure_field_region), do: :ensure_field_region
  defp normalize_field_effect_action("ensure_field_region"), do: :ensure_field_region
  defp normalize_field_effect_action(:upsert_phenomenon_instance), do: :upsert_phenomenon_instance

  defp normalize_field_effect_action("upsert_phenomenon_instance"),
    do: :upsert_phenomenon_instance

  defp normalize_field_effect_action(:complete_phenomenon_instance),
    do: :complete_phenomenon_instance

  defp normalize_field_effect_action("complete_phenomenon_instance"),
    do: :complete_phenomenon_instance

  defp normalize_field_effect_action(action) when is_atom(action), do: action
  defp normalize_field_effect_action(action) when is_binary(action), do: action
  defp normalize_field_effect_action(_action), do: :unknown

  defp apply_write_voxel_attribute_effect(state, attrs, context) do
    case normalize_field_effect_attribute(fetch_optional(attrs, [:attribute, :attr, :name])) do
      :temperature ->
        attrs =
          attrs
          |> maybe_put_effect_alias(:macro, [:macro_index, :local_macro])

        if fetch_optional(attrs, [:heat_energy_joules, :heat_joules, :energy_joules]) do
          apply_heat_energy_attribute_effect(state, attrs, context)
        else
          attrs = maybe_put_effect_alias(attrs, :target_temperature, [:target_value, :value])
          apply_target_temperature_attribute_effect(state, attrs, context)
        end

      attribute ->
        apply_generic_voxel_attribute_effect(state, attrs, context, attribute)
    end
  end

  defp apply_generic_voxel_attribute_effect(state, _attrs, context, nil) do
    result = %{
      status: :rejected,
      action: :write_voxel_attribute,
      attribute: :unknown,
      reason: :missing_field_effect_attribute
    }

    emit_field_effect_rejected(state, result, context)
    {result, state}
  end

  defp apply_generic_voxel_attribute_effect(state, attrs, context, attribute) do
    case build_voxel_attribute_storage(state.storage, attrs, attribute) do
      {:ok, next_storage, summary} ->
        next_state = %{state | storage: next_storage}

        if summary.changed? do
          push_snapshot_fallbacks(next_state, :field_effect_write)
        end

        result = %{
          status: :applied,
          action: :write_voxel_attribute,
          attribute: summary.attribute,
          macro_index: summary.macro_index,
          target_value_raw: summary.target_value_raw,
          changed?: summary.changed?,
          chunk_version: next_storage.chunk_version
        }

        emit_field_effect_applied(next_state, result, context)
        {result, next_state}

      {:error, reason} ->
        result = %{
          status: :rejected,
          action: :write_voxel_attribute,
          attribute: attribute || :unknown,
          reason: reason
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp apply_transform_voxel_material_effect(state, attrs, context) do
    case build_transform_voxel_material_storage(state.storage, attrs) do
      {:ok, next_storage, summary} ->
        next_state = %{state | storage: next_storage}

        if summary.changed? do
          push_snapshot_fallbacks(next_state, :field_effect_write)
        end

        result = %{
          status: :applied,
          action: :transform_voxel_material,
          macro_index: summary.macro_index,
          previous_material_id: summary.previous_material_id,
          material_id: summary.material_id,
          reason: fetch_optional(attrs, [:reason]),
          changed?: summary.changed?,
          chunk_version: next_storage.chunk_version
        }

        emit_field_effect_applied(next_state, result, context)
        {result, next_state}

      {:error, reason} ->
        result = %{
          status: :rejected,
          action: :transform_voxel_material,
          reason: reason
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp apply_clear_voxel_cell_effect(state, attrs, context) do
    case build_clear_voxel_cell_storage(state.storage, attrs) do
      {:ok, next_storage, summary} ->
        next_state = %{state | storage: next_storage}

        if summary.changed? do
          push_snapshot_fallbacks(next_state, :field_effect_write)
        end

        result = %{
          status: :applied,
          action: :clear_voxel_cell,
          macro_index: summary.macro_index,
          reason: fetch_optional(attrs, [:reason]),
          changed?: summary.changed?,
          chunk_version: next_storage.chunk_version
        }

        emit_field_effect_applied(next_state, result, context)
        {result, next_state}

      {:error, reason} ->
        result = %{
          status: :rejected,
          action: :clear_voxel_cell,
          reason: reason
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp apply_structural_damage_effect(state, attrs, context) do
    case normalize_effect_macro(attrs) do
      {:ok, macro_index} ->
        attribution = collect_structural_damage_attribution(state.storage, macro_index)
        dispatch_damage_async(state, attribution)

        damage_count =
          Enum.reduce(attribution, 0, fn {_owner, count}, total -> total + count end)

        result = %{
          status: :applied,
          action: :apply_structural_damage,
          macro_index: macro_index,
          reason: fetch_optional(attrs, [:reason]),
          damaged_owner_count: map_size(attribution),
          damage_count: damage_count
        }

        emit_field_effect_applied(state, result, context)
        {result, state}

      {:error, reason} ->
        result = %{
          status: :rejected,
          action: :apply_structural_damage,
          reason: reason
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp apply_upsert_phenomenon_instance_effect(state, attrs, context) do
    case normalize_phenomenon_instance_effect_attrs(state, attrs) do
      {:ok, instance_attrs} ->
        existing = Map.get(state.phenomenon_instances, instance_attrs.id)
        instance = PhenomenonInstance.upsert(existing, instance_attrs)

        next_state = %{
          state
          | phenomenon_instances: Map.put(state.phenomenon_instances, instance.id, instance)
        }

        result = %{
          status: :applied,
          action: :upsert_phenomenon_instance,
          instance_id: inspect(instance.id),
          kind: instance.kind,
          macro_index: instance.macro_index,
          material_id: instance.material_id,
          stage: instance.stage,
          changed?: existing != instance,
          active_instance_count: map_size(next_state.phenomenon_instances)
        }

        emit_phenomenon_instance_upserted(next_state, instance, context)
        emit_field_effect_applied(next_state, result, context)
        {result, next_state}

      {:error, reason} ->
        result = %{
          status: :rejected,
          action: :upsert_phenomenon_instance,
          reason: reason
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp apply_complete_phenomenon_instance_effect(state, attrs, context) do
    case normalize_phenomenon_instance_effect_attrs(state, attrs) do
      {:ok, instance_attrs} ->
        existing = Map.get(state.phenomenon_instances, instance_attrs.id)
        completed = PhenomenonInstance.complete(existing, instance_attrs)

        next_state = %{
          state
          | phenomenon_instances: Map.delete(state.phenomenon_instances, completed.id)
        }

        result = %{
          status: :applied,
          action: :complete_phenomenon_instance,
          instance_id: inspect(completed.id),
          kind: completed.kind,
          macro_index: completed.macro_index,
          material_id: completed.material_id,
          stage: completed.stage,
          reason: completed.reason,
          changed?: not is_nil(existing),
          active_instance_count: map_size(next_state.phenomenon_instances)
        }

        if existing do
          emit_phenomenon_instance_completed(next_state, completed, context)
        end

        emit_field_effect_applied(next_state, result, context)
        {result, next_state}

      {:error, reason} ->
        result = %{
          status: :rejected,
          action: :complete_phenomenon_instance,
          reason: reason
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp apply_ensure_field_region_effect(state, attrs, context) do
    case normalize_ensure_field_region_effect_attrs(state, attrs) do
      {:ok, %{target_chunk_coord: target_chunk_coord} = request} ->
        if target_chunk_coord == state.chunk_coord do
          apply_local_field_region_effect(state, request, context)
        else
          queue_remote_field_region_effect(state, request, context)
        end

      {:error, reason} ->
        result = %{
          status: :rejected,
          action: :ensure_field_region,
          reason: reason
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp normalize_ensure_field_region_effect_attrs(state, attrs) do
    attrs = attrs_map(attrs)
    target_chunk_coord_value = fetch_optional(attrs, [:target_chunk_coord, :chunk_coord])
    source_key = fetch_optional(attrs, [:source_key])
    aabb_value = fetch_optional(attrs, [:aabb])
    kernels = fetch_optional(attrs, [:kernels])
    source_points = fetch_optional(attrs, [:source_points])

    cond do
      is_nil(target_chunk_coord_value) ->
        {:error, :missing_target_chunk_coord}

      is_nil(source_key) ->
        {:error, :missing_field_source_key}

      is_nil(aabb_value) ->
        {:error, :missing_field_region_aabb}

      not (is_list(kernels) and kernels != []) ->
        {:error, :missing_field_region_kernels}

      not (is_list(source_points) and source_points != []) ->
        {:error, :missing_field_region_source_points}

      true ->
        with {:ok, target_chunk_coord} <- safe_chunk_coord(target_chunk_coord_value),
             {:ok, aabb} <- normalize_field_region_aabb(aabb_value),
             {:ok, region_id} <-
               normalize_optional_field_region_id(fetch_optional(attrs, [:region_id])) do
          lease_token =
            field_region_effect_lease_token(
              state,
              target_chunk_coord,
              fetch_optional(attrs, [:lease_token])
            )

          region_attrs =
            %{
              chunk_coord: target_chunk_coord,
              aabb: aabb,
              kernels: kernels,
              source_points: source_points,
              max_ticks: fetch_optional(attrs, [:max_ticks]),
              source_points_mode: fetch_optional(attrs, [:source_points_mode]),
              source_key: source_key,
              linked_field_regions: fetch_optional(attrs, [:linked_field_regions])
            }
            |> maybe_put_optional(:lease_token, lease_token)
            |> maybe_put_optional(:region_id, region_id)
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)
            |> Map.new()

          {:ok,
           %{
             target_chunk_coord: target_chunk_coord,
             source_key: source_key,
             reason: fetch_optional(attrs, [:reason]) || :field_region_handoff,
             region_attrs: region_attrs
           }}
        end
    end
  rescue
    _error -> {:error, :invalid_ensure_field_region_effect}
  end

  defp field_region_effect_lease_token(_state, _target_chunk_coord, explicit_lease)
       when not is_nil(explicit_lease) do
    explicit_lease
  end

  defp field_region_effect_lease_token(state, target_chunk_coord, nil)
       when target_chunk_coord == state.chunk_coord do
    state.lease
  end

  defp field_region_effect_lease_token(_state, _target_chunk_coord, nil), do: nil

  defp normalize_field_region_aabb({{min_x, min_y, min_z}, {max_x, max_y, max_z}} = aabb)
       when is_integer(min_x) and is_integer(min_y) and is_integer(min_z) and
              is_integer(max_x) and is_integer(max_y) and is_integer(max_z) do
    cond do
      macro_axis?(min_x) and macro_axis?(min_y) and macro_axis?(min_z) and
        macro_axis?(max_x) and macro_axis?(max_y) and macro_axis?(max_z) and
        min_x <= max_x and min_y <= max_y and min_z <= max_z ->
        {:ok, aabb}

      true ->
        {:error, :invalid_field_region_aabb}
    end
  end

  defp normalize_field_region_aabb(_aabb), do: {:error, :invalid_field_region_aabb}

  defp macro_axis?(value), do: value in 0..15

  defp normalize_optional_field_region_id(nil), do: {:ok, nil}

  defp normalize_optional_field_region_id(region_id)
       when is_integer(region_id) and region_id >= 0,
       do: {:ok, region_id}

  defp normalize_optional_field_region_id(_region_id), do: {:error, :invalid_field_region_id}

  defp maybe_put_optional(map, _key, nil), do: map
  defp maybe_put_optional(map, key, value), do: Map.put(map, key, value)

  defp apply_local_field_region_effect(state, request, context) do
    source_key = request.source_key

    case ensure_field_source_region_in_state(state, request.region_attrs, source_key) do
      {{:ok, field_region}, next_state} ->
        result =
          %{
            status: :applied,
            action: :ensure_field_region,
            dispatch: :local,
            target_chunk_coord: request.target_chunk_coord,
            source_key: source_key,
            reason: request.reason
          }
          |> Map.merge(field_region)

        emit_field_effect_applied(next_state, result, context)
        {result, next_state}

      {{:error, reason}, next_state} ->
        result = %{
          status: :rejected,
          action: :ensure_field_region,
          dispatch: :local,
          target_chunk_coord: request.target_chunk_coord,
          source_key: source_key,
          reason: reason
        }

        emit_field_effect_rejected(next_state, result, context)
        {result, next_state}
    end
  end

  defp queue_remote_field_region_effect(state, request, context) do
    directory = state.chunk_directory
    logical_scene_id = state.logical_scene_id
    source_chunk_coord = state.chunk_coord
    target_chunk_coord = request.target_chunk_coord
    source_key = request.source_key
    reason = request.reason
    region_attrs = request.region_attrs
    observe_context = field_effect_observe_base(state, context)

    result = %{
      status: :applied,
      action: :ensure_field_region,
      dispatch: :queued_remote,
      target_chunk_coord: target_chunk_coord,
      source_key: source_key,
      reason: reason
    }

    emit_field_effect_applied(state, result, context)

    Task.start(fn ->
      dispatch_remote_field_region_effect(
        directory,
        logical_scene_id,
        source_chunk_coord,
        target_chunk_coord,
        region_attrs,
        source_key,
        reason,
        observe_context
      )
    end)

    {result, state}
  end

  defp dispatch_remote_field_region_effect(
         nil,
         logical_scene_id,
         source_chunk_coord,
         target_chunk_coord,
         _region_attrs,
         source_key,
         reason,
         observe_context
       ) do
    emit_field_region_handoff_rejected(observe_context, %{
      logical_scene_id: logical_scene_id,
      source_chunk_coord: source_chunk_coord,
      target_chunk_coord: target_chunk_coord,
      source_key: source_key,
      reason: reason,
      reject_reason: :missing_chunk_directory
    })
  end

  defp dispatch_remote_field_region_effect(
         directory,
         logical_scene_id,
         source_chunk_coord,
         target_chunk_coord,
         region_attrs,
         source_key,
         reason,
         observe_context
       ) do
    result =
      try do
        with {:ok, target_chunk_pid} <-
               SceneServer.Voxel.ChunkDirectory.ensure_chunk(directory, %{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: target_chunk_coord
               }),
             {:ok, field_region} <- __MODULE__.ensure_field_region(target_chunk_pid, region_attrs) do
          {:ok, field_region}
        end
      rescue
        error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
      catch
        kind, caught_reason -> {:error, {kind, caught_reason}}
      end

    case result do
      {:ok, field_region} ->
        emit_field_region_handoff_applied(observe_context, %{
          logical_scene_id: logical_scene_id,
          source_chunk_coord: source_chunk_coord,
          target_chunk_coord: target_chunk_coord,
          source_key: source_key,
          reason: reason,
          region_id: field_region.region_id,
          field_region_created: field_region.created?,
          source_points_action: Map.get(field_region, :source_points_action)
        })

      {:error, handoff_reason} ->
        emit_field_region_handoff_rejected(observe_context, %{
          logical_scene_id: logical_scene_id,
          source_chunk_coord: source_chunk_coord,
          target_chunk_coord: target_chunk_coord,
          source_key: source_key,
          reason: reason,
          reject_reason: handoff_reason
        })
    end
  end

  defp apply_target_temperature_attribute_effect(state, attrs, context) do
    case build_temperature_attribute_storage(state.storage, attrs) do
      {:ok, next_storage, summary} ->
        next_state = %{state | storage: next_storage}

        if summary.changed? do
          push_snapshot_fallbacks(next_state, :field_effect_write)
        end

        result = %{
          status: :applied,
          action: :write_voxel_attribute,
          attribute: :temperature,
          macro_index: summary.macro_index,
          target_value: summary.target_temperature,
          changed?: summary.changed?,
          chunk_version: next_storage.chunk_version
        }

        emit_field_effect_applied(next_state, result, context)
        {result, next_state}

      {:error, reason} ->
        result = %{
          status: :rejected,
          action: :write_voxel_attribute,
          attribute: :temperature,
          reason: reason
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp apply_heat_energy_attribute_effect(state, attrs, context) do
    case build_heat_energy_attribute_storage(state.storage, attrs) do
      {:ok, next_storage, summary} ->
        next_state = %{state | storage: next_storage}

        if summary.changed? do
          push_snapshot_fallbacks(next_state, :field_effect_write)
        end

        result = %{
          status: :applied,
          action: :write_voxel_attribute,
          attribute: :temperature,
          macro_index: summary.macro_index,
          target_value: summary.target_temperature,
          heat_energy_joules: summary.heat_energy_joules,
          temperature_delta: summary.temperature_delta,
          changed?: summary.changed?,
          chunk_version: next_storage.chunk_version
        }

        emit_field_effect_applied(next_state, result, context)
        {result, next_state}

      {:error, reason} ->
        result = %{
          status: :rejected,
          action: :write_voxel_attribute,
          attribute: :temperature,
          reason: reason
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp build_voxel_attribute_storage(%Storage{} = storage, attrs, attribute) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_effect_macro(attrs),
         {:ok, attribute_name, defn} <- normalize_effect_attribute_definition(attribute),
         {:ok, raw_value} <- normalize_field_effect_attribute_value(attrs, defn) do
      cond do
        not solid_cell?(storage, macro_index) ->
          {:error, :attribute_target_not_solid}

        true ->
          previous_raw = Storage.effective_attribute_at(storage, macro_index, attribute_name)

          if previous_raw == raw_value do
            {:ok, storage,
             %{
               storage: storage,
               changed?: false,
               macro_index: macro_index,
               attribute: attribute_name,
               previous_value_raw: previous_raw,
               target_value_raw: raw_value,
               chunk_version: storage.chunk_version
             }}
          else
            next_version = storage.chunk_version + 1

            opts = [
              cell_version: next_version,
              cell_hash:
                Hash.digest32(
                  inspect(
                    {:voxel_attribute, macro_index, attribute_name, raw_value, next_version}
                  )
                )
            ]

            next_storage =
              storage
              |> Storage.put_attribute_for_cell(macro_index, attribute_name, raw_value, opts)
              |> bump_chunk_version()

            {:ok, next_storage,
             %{
               storage: next_storage,
               changed?: true,
               macro_index: macro_index,
               attribute: attribute_name,
               previous_value_raw: previous_raw,
               target_value_raw: raw_value,
               chunk_version: next_storage.chunk_version
             }}
          end
      end
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_voxel_attribute}
  end

  defp build_transform_voxel_material_storage(%Storage{} = storage, attrs) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_effect_macro(attrs),
         {:ok, material_id} <- normalize_effect_material_id(attrs) do
      cond do
        not solid_cell?(storage, macro_index) ->
          {:error, :material_target_not_solid}

        true ->
          previous_block = Storage.normal_block_at(storage, macro_index)

          reset_attributes? =
            fetch_optional(attrs, [:reset_attributes?, :reset_attributes, :clear_attributes]) !=
              false

          if previous_block.material_id == material_id and not reset_attributes? do
            {:ok, storage,
             %{
               storage: storage,
               changed?: false,
               macro_index: macro_index,
               previous_material_id: previous_block.material_id,
               material_id: material_id,
               chunk_version: storage.chunk_version
             }}
          else
            next_version = storage.chunk_version + 1

            updated_block =
              if reset_attributes? do
                NormalBlockData.new(material_id,
                  state_flags: previous_block.state_flags,
                  health: previous_block.health,
                  tag_set_ref: previous_block.tag_set_ref
                )
              else
                %{previous_block | material_id: material_id}
              end

            opts = [
              cell_version: next_version,
              cell_hash:
                Hash.digest32(
                  inspect(
                    {:transform_voxel_material, macro_index, previous_block.material_id,
                     material_id, reset_attributes?, next_version}
                  )
                )
            ]

            next_storage =
              storage
              |> Storage.put_solid_block(macro_index, updated_block, opts)
              |> bump_chunk_version()

            {:ok, next_storage,
             %{
               storage: next_storage,
               changed?: true,
               macro_index: macro_index,
               previous_material_id: previous_block.material_id,
               material_id: material_id,
               chunk_version: next_storage.chunk_version
             }}
          end
      end
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_material_transform}
  end

  defp build_clear_voxel_cell_storage(%Storage{} = storage, attrs) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_effect_macro(attrs) do
      if empty_cell?(storage, macro_index) do
        {:ok, storage,
         %{
           storage: storage,
           changed?: false,
           macro_index: macro_index,
           chunk_version: storage.chunk_version
         }}
      else
        next_version = storage.chunk_version + 1

        opts = [
          cell_version: next_version,
          cell_hash: Hash.digest32(inspect({:clear_voxel_cell, macro_index, next_version}))
        ]

        next_storage =
          storage
          |> Storage.clear_macro_cell(macro_index, opts)
          |> bump_chunk_version()

        {:ok, next_storage,
         %{
           storage: next_storage,
           changed?: true,
           macro_index: macro_index,
           chunk_version: next_storage.chunk_version
         }}
      end
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_clear_voxel_cell}
  end

  defp normalize_field_effect_attribute(:temperature), do: :temperature
  defp normalize_field_effect_attribute("temperature"), do: :temperature

  defp normalize_field_effect_attribute(attribute) when is_atom(attribute),
    do: Atom.to_string(attribute)

  defp normalize_field_effect_attribute(attribute), do: attribute

  defp normalize_effect_macro(attrs) do
    case fetch_optional(attrs, [:macro, :macro_index, :macro_coord, :local_macro]) do
      nil -> {:error, :missing_field_effect_macro}
      value -> safe_macro_index(value)
    end
  end

  defp normalize_effect_attribute_definition(attribute) when is_binary(attribute) do
    case AttributeCatalog.lookup_by_name(attribute) do
      {:ok, _id, defn} -> {:ok, attribute, defn}
      {:error, :not_found} -> {:error, :unknown_voxel_attribute}
    end
  end

  defp normalize_effect_attribute_definition(attribute) when is_atom(attribute) do
    attribute
    |> Atom.to_string()
    |> normalize_effect_attribute_definition()
  end

  defp normalize_effect_attribute_definition(_attribute), do: {:error, :invalid_voxel_attribute}

  defp normalize_field_effect_attribute_value(attrs, defn) do
    value =
      fetch_optional(attrs, [:raw_value, :value_raw, :raw]) ||
        fetch_optional(attrs, [:target_value, :value])

    cond do
      is_nil(value) ->
        {:error, :missing_attribute_value}

      fetch_optional(attrs, [:raw_value, :value_raw, :raw]) != nil ->
        normalize_raw_attribute_value(value, defn)

      defn.value_type == 0x03 ->
        normalize_fixed32_attribute_value(value, defn)

      true ->
        normalize_raw_attribute_value(value, defn)
    end
  end

  defp normalize_fixed32_attribute_value(value, defn) when is_integer(value) do
    normalize_raw_attribute_value(round(value * @fixed32_scale), defn)
  end

  defp normalize_fixed32_attribute_value(value, defn) when is_float(value) do
    normalize_raw_attribute_value(round(value * @fixed32_scale), defn)
  end

  defp normalize_fixed32_attribute_value(value, defn) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> normalize_fixed32_attribute_value(parsed, defn)
      _other -> {:error, :invalid_attribute_value}
    end
  end

  defp normalize_fixed32_attribute_value(_value, _defn), do: {:error, :invalid_attribute_value}

  defp normalize_raw_attribute_value(value, defn) when is_integer(value) do
    if value >= defn.min_value and value <= defn.max_value do
      {:ok, value}
    else
      {:error, :attribute_value_out_of_range}
    end
  end

  defp normalize_raw_attribute_value(value, defn) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_raw_attribute_value(parsed, defn)
      _other -> {:error, :invalid_attribute_value}
    end
  end

  defp normalize_raw_attribute_value(:idle, %{name: "combustion_stage"} = defn),
    do: normalize_raw_attribute_value(0, defn)

  defp normalize_raw_attribute_value(:preheat, %{name: "combustion_stage"} = defn),
    do: normalize_raw_attribute_value(1, defn)

  defp normalize_raw_attribute_value(:burning, %{name: "combustion_stage"} = defn),
    do: normalize_raw_attribute_value(2, defn)

  defp normalize_raw_attribute_value(:smoldering, %{name: "combustion_stage"} = defn),
    do: normalize_raw_attribute_value(3, defn)

  defp normalize_raw_attribute_value(:extinguished, %{name: "combustion_stage"} = defn),
    do: normalize_raw_attribute_value(4, defn)

  defp normalize_raw_attribute_value(:stable, %{name: "phase_state"} = defn),
    do: normalize_raw_attribute_value(0, defn)

  defp normalize_raw_attribute_value(:frozen, %{name: "phase_state"} = defn),
    do: normalize_raw_attribute_value(1, defn)

  defp normalize_raw_attribute_value(:boiling, %{name: "phase_state"} = defn),
    do: normalize_raw_attribute_value(2, defn)

  defp normalize_raw_attribute_value(:vapor, %{name: "phase_state"} = defn),
    do: normalize_raw_attribute_value(3, defn)

  defp normalize_raw_attribute_value(_value, _defn), do: {:error, :invalid_attribute_value}

  defp normalize_effect_material_id(attrs) do
    case fetch_optional(attrs, [:material_id, :target_material_id]) do
      value when is_integer(value) and value > 0 and value <= 0xFFFF -> {:ok, value}
      _other -> {:error, :invalid_material_id}
    end
  end

  defp normalize_phenomenon_instance_effect_attrs(state, attrs) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_effect_macro(attrs),
         {:ok, kind} <- normalize_phenomenon_kind(fetch_optional(attrs, [:kind, :definition_id])),
         {:ok, material_id} <- normalize_optional_phenomenon_material_id(attrs) do
      id =
        PhenomenonInstance.key(
          state.logical_scene_id,
          state.chunk_coord,
          kind,
          macro_index
        )

      {:ok,
       %{
         id: id,
         kind: kind,
         macro_index: macro_index,
         material_id: material_id,
         stage: fetch_optional(attrs, [:stage]),
         previous_stage: fetch_optional(attrs, [:previous_stage]),
         reason: fetch_optional(attrs, [:reason]),
         now_ms: now_ms(),
         chunk_version: state.storage.chunk_version,
         metadata: phenomenon_instance_metadata(state, attrs, id, kind, macro_index)
       }}
    end
  end

  defp normalize_phenomenon_kind(nil), do: {:error, :missing_phenomenon_kind}
  defp normalize_phenomenon_kind(kind) when is_atom(kind), do: {:ok, kind}

  defp normalize_phenomenon_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "" -> {:error, :invalid_phenomenon_kind}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_phenomenon_kind(_kind), do: {:error, :invalid_phenomenon_kind}

  defp normalize_optional_phenomenon_material_id(attrs) do
    case fetch_optional(attrs, [:material_id, :target_material_id]) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 and value <= 0xFFFF -> {:ok, value}
      _other -> {:error, :invalid_material_id}
    end
  end

  defp phenomenon_instance_metadata(state, attrs, id, kind, macro_index) do
    explicit_metadata =
      case fetch_optional(attrs, [:metadata]) do
        metadata when is_map(metadata) -> metadata
        _other -> %{}
      end

    derived_metadata =
      attrs
      |> Map.take([
        :progress_percent,
        :heat_source_celsius,
        :released_heat_energy_joules,
        :source_refs
      ])
      |> maybe_put_default_combustion_source_refs(state, id, kind, macro_index)

    Map.merge(explicit_metadata, derived_metadata)
  end

  defp maybe_put_default_combustion_source_refs(metadata, state, _id, :combustion, macro_index) do
    Map.put_new(metadata, :source_refs, [
      %{
        kind: :field_source,
        source_key: {:combustion_instance, state.logical_scene_id, state.chunk_coord, macro_index}
      }
    ])
  end

  defp maybe_put_default_combustion_source_refs(metadata, state, _id, "combustion", macro_index) do
    Map.put_new(metadata, :source_refs, [
      %{
        kind: :field_source,
        source_key: {:combustion_instance, state.logical_scene_id, state.chunk_coord, macro_index}
      }
    ])
  end

  defp maybe_put_default_combustion_source_refs(metadata, _state, _id, _kind, _macro_index),
    do: metadata

  defp maybe_put_effect_alias(attrs, key, aliases) do
    if Map.has_key?(attrs, key) do
      attrs
    else
      case fetch_optional(attrs, aliases) do
        nil -> attrs
        value -> Map.put(attrs, key, value)
      end
    end
  end

  defp normalize_temperature_macro(attrs) do
    case fetch_optional(attrs, [:macro, :macro_index, :macro_coord, :local_macro]) do
      nil -> {:error, :missing_temperature_macro}
      value -> safe_macro_index(value)
    end
  end

  defp normalize_temperature_target(attrs) do
    attrs
    |> fetch_optional([:target_temperature, :target_temperature_celsius])
    |> case do
      nil -> {:error, :missing_target_temperature}
      value -> normalize_celsius(value)
    end
  end

  defp normalize_celsius(value) when is_integer(value), do: {:ok, value * 1.0}
  defp normalize_celsius(value) when is_float(value), do: {:ok, value}

  defp normalize_celsius(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _other -> {:error, :invalid_target_temperature}
    end
  end

  defp normalize_celsius(_value), do: {:error, :invalid_target_temperature}

  defp normalize_heat_energy_joules(attrs) do
    attrs
    |> fetch_optional([:heat_energy_joules, :heat_joules, :energy_joules])
    |> case do
      nil -> {:error, :missing_heat_energy_joules}
      value -> normalize_non_negative_float(value, :invalid_heat_energy_joules)
    end
  end

  defp normalize_non_negative_float(value, _error) when is_integer(value) and value >= 0,
    do: {:ok, value * 1.0}

  defp normalize_non_negative_float(value, _error) when is_float(value) and value >= 0,
    do: {:ok, value}

  defp normalize_non_negative_float(value, error) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _other -> {:error, error}
    end
  end

  defp normalize_non_negative_float(_value, error), do: {:error, error}

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp celsius_to_fixed32_raw(value), do: round(value * @fixed32_scale)
  defp fixed32_raw_to_celsius(value), do: value / @fixed32_scale

  defp effective_fixed32_float(%Storage{} = storage, macro_index, attribute_name, min_value) do
    storage
    |> Storage.effective_attribute_at(macro_index, attribute_name)
    |> fixed32_raw_to_celsius()
    |> max(min_value)
  end

  # Phase 4 (D8) — destroy_part helper. Server-internal cleanup, never via
  # user lease. Persistence still uses the chunk's current state.lease.
  defp destroy_part_in_state(state, attrs) do
    object_id = Map.fetch!(attrs, :object_id)
    part_id = Map.fetch!(attrs, :part_id)
    storage_before = state.storage

    targets = collect_part_target_slots(storage_before, object_id, part_id)

    cond do
      targets == [] ->
        reply = build_destroy_part_reply(state, object_id, part_id, false, 0, storage_before)
        {:ok, reply, state}

      true ->
        cleared_storage =
          Enum.reduce(targets, storage_before, fn {macro_idx, slot}, acc ->
            Storage.clear_micro_block(acc, macro_idx, slot)
          end)

        refreshed =
          cleared_storage
          |> Storage.refresh_chunk_object_refs()
          |> bump_chunk_version()

        payload = encode_snapshot_payload(refreshed, 0)

        case persist_snapshot(state.lease, state.chunk_coord, refreshed, payload) do
          {:ok, _persist_result} ->
            next_state = %{state | storage: refreshed}

            reply =
              build_destroy_part_reply(
                next_state,
                object_id,
                part_id,
                true,
                length(targets),
                refreshed,
                payload
              )

            {:ok, reply, next_state}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp collect_part_target_slots(storage, object_id, part_id) do
    # 阶段2.5:内层 payload→cell 查找经 accel map O(1)(替代旧 O(n) Enum.at)。
    # 外层仍需单趟扫 headers 定位含该 object/part 的 refined macro。
    storage = Storage.ensure_accel(storage)

    storage.macro_headers
    |> Enum.with_index()
    |> Enum.flat_map(fn {header, macro_idx} ->
      if header.mode == MacroCellHeader.cell_mode_refined() do
        cell = Storage.fetch_refined_cell(storage, header.payload_index)

        cell.layers
        |> Enum.filter(fn layer ->
          layer.owner_object_id == object_id and layer.owner_part_id == part_id
        end)
        |> Enum.flat_map(fn layer ->
          layer.mask_words
          |> slots_in_mask_words()
          |> Enum.map(&{macro_idx, &1})
        end)
      else
        []
      end
    end)
  end

  defp slots_in_mask_words(mask_words) do
    mask_words
    |> Enum.with_index()
    |> Enum.flat_map(fn {word, word_idx} ->
      bits_in_word(word) |> Enum.map(&(word_idx * 64 + &1))
    end)
  end

  defp bits_in_word(word) when is_integer(word) and word >= 0 do
    Enum.reduce(0..63, [], fn i, acc ->
      if band(word, bsl(1, i)) != 0, do: [i | acc], else: acc
    end)
    |> Enum.reverse()
  end

  defp build_destroy_part_reply(
         state,
         object_id,
         part_id,
         changed?,
         cleared_count,
         storage,
         payload \\ nil
       ) do
    payload = payload || encode_snapshot_payload(storage, 0)

    %{
      logical_scene_id: state.logical_scene_id,
      chunk_coord: state.chunk_coord,
      object_id: object_id,
      part_id: part_id,
      changed?: changed?,
      chunk_version: storage.chunk_version,
      snapshot_payload: payload,
      cleared_count: cleared_count
    }
  end

  defp emit_destroy_part_event(state, attrs, reply) do
    CliObserve.emit("voxel_chunk_destroy_part", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        object_id: Map.get(attrs, :object_id),
        part_id: Map.get(attrs, :part_id),
        changed?: reply.changed?,
        cleared_count: reply.cleared_count,
        chunk_version: reply.chunk_version
      }
    end)
  end

  defp persist_snapshot(nil, _chunk_coord, _storage, _payload) do
    {:error, :missing_lease}
  end

  defp persist_snapshot(lease, chunk_coord, storage, payload) do
    lease
    |> build_snapshot_attrs(chunk_coord, storage, payload)
    |> DataService.Voxel.ChunkSnapshotStore.put_snapshot()
  end

  defp enqueue_snapshot_persist(_state, nil, _chunk_coord, _storage, _payload) do
    {:error, :missing_lease}
  end

  defp enqueue_snapshot_persist(state, lease, chunk_coord, storage, payload) do
    with :ok <- validate_snapshot_write_token(lease, chunk_coord) do
      parent = self()
      ref = System.unique_integer([:positive, :monotonic])

      # 阶段4 (4.5)③：unlinked Task + monitor，使 persist 不与 chunk 共命运。
      # persist 内部 DB 异常被 `safe_persist_snapshot_with_retry` 兜住正常 send
      # finished；若 Task 本身意外崩溃（如被 kill），chunk 不会因 link 一起死，
      # 而是收到 :DOWN，在 DOWN 分支把对应 commit ack reply error（保留 fence）。
      persist_fault = persist_fault_hook()

      {:ok, pid} =
        Task.start(fn ->
          payload = payload || encode_snapshot_payload(storage, 0)
          snapshot_bytes = byte_size(payload)

          # 故障注入测试 seam（仅测试态、默认 nil）。生产路径完全不受影响。
          #   :crash —— Task 不发 finished 直接退出（模拟 persist Task :DOWN）。
          #   {:result, r} —— 跳过真实 DB 写，强制 persist 结果（如 {:error, _}）。
          case persist_fault do
            :crash ->
              exit({:injected_persist_crash, ref})

            {:result, forced_result} ->
              send(parent, {:async_snapshot_persist_finished, ref, forced_result, snapshot_bytes})

            _ ->
              attrs = build_snapshot_attrs(lease, chunk_coord, storage, payload)

              # 阶段5.2 (voxel-storage-1)：DB 写经有界 write-behind pool（poolboy）
              # checkout worker 后再写——并发 persist 写数被池大小钳死，对 DB 施背压
              # （高速写在 Task 层排队等 worker，不无界冲击 Postgres 连接池）。池满
              # 超时 / 未启动的降级语义见 ChunkPersistPool.transaction/1。
              result =
                ChunkPersistPool.transaction(fn ->
                  safe_persist_snapshot_with_retry(attrs, 3)
                end)

              send(parent, {:async_snapshot_persist_finished, ref, result, snapshot_bytes})
          end
        end)

      monitor_ref = Process.monitor(pid)

      observe = %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        chunk_version: storage.chunk_version,
        persist_ref: ref,
        task_pid: inspect(pid),
        snapshot_bytes: if(is_binary(payload), do: byte_size(payload), else: :deferred)
      }

      CliObserve.emit("voxel_chunk_async_persist_queued", fn -> observe end)

      next_state = %{
        state
        | async_persists:
            Map.put(state.async_persists, ref, %{
              monitor_ref: monitor_ref,
              observe: observe
            })
      }

      {:ok, :queued, ref, next_state}
    end
  end

  defp validate_snapshot_write_token(lease, chunk_coord) do
    attrs =
      lease
      |> Map.take([
        :logical_scene_id,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch
      ])
      |> Map.put(:chunk_coord, chunk_coord)

    DataService.Voxel.WriteTokenStore.validate_write(attrs)
  catch
    :exit, _reason -> {:error, :write_token_store_unavailable}
  end

  defp safe_persist_snapshot_with_retry(attrs, attempts_left) do
    persist_snapshot_with_retry(attrs, attempts_left)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp persist_snapshot_with_retry(attrs, attempts_left) do
    case DataService.Voxel.ChunkSnapshotStore.put_snapshot(attrs) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error when reason in [:stale_chunk_version, :chunk_version_conflict] ->
        error

      {:error, _reason} = error ->
        if attempts_left > 1 do
          Process.sleep(25)
          persist_snapshot_with_retry(attrs, attempts_left - 1)
        else
          error
        end
    end
  end

  defp build_snapshot_attrs(lease, chunk_coord, storage, payload) do
    chunk_hash = Codec.chunk_hash(storage)

    attrs =
      lease
      |> Map.take([
        :logical_scene_id,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch
      ])
      |> Map.merge(%{
        chunk_coord: chunk_coord,
        schema_version: storage.schema_version,
        chunk_size_in_macro: storage.chunk_size_in_macro,
        micro_resolution: storage.micro_resolution,
        chunk_version: storage.chunk_version,
        chunk_hash: Hash.encode64(chunk_hash),
        data: payload
      })

    attrs
  end

  defp chunk_in_lease_bounds?({cx, cy, cz}, lease) do
    {min_x, min_y, min_z} = lease.bounds_chunk_min
    {max_x, max_y, max_z} = lease.bounds_chunk_max

    cx >= min_x and cx < max_x and cy >= min_y and cy < max_y and cz >= min_z and cz < max_z
  end

  defp emit_intent_rejected(state, attrs, reason) do
    CliObserve.emit("voxel_intent_rejected", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        chunk_version: state.storage.chunk_version,
        reason: reason,
        intent: summarize_intent_attrs(attrs)
      }
    end)
  end

  defp emit_field_effect_applied(state, result, context) do
    CliObserve.emit("voxel_field_effect_applied", fn ->
      field_effect_observe_base(state, context)
      |> Map.merge(result)
    end)
  end

  defp emit_field_effect_rejected(state, result, context) do
    CliObserve.emit("voxel_field_effect_rejected", fn ->
      field_effect_observe_base(state, context)
      |> Map.merge(result)
    end)
  end

  defp emit_phenomenon_instance_upserted(state, %PhenomenonInstance{} = instance, context) do
    CliObserve.emit("voxel_phenomenon_instance_upserted", fn ->
      field_effect_observe_base(state, context)
      |> Map.merge(PhenomenonInstance.summary(instance))
    end)
  end

  defp emit_phenomenon_instance_completed(state, %PhenomenonInstance{} = instance, context) do
    CliObserve.emit("voxel_phenomenon_instance_completed", fn ->
      field_effect_observe_base(state, context)
      |> Map.merge(PhenomenonInstance.summary(instance))
    end)
  end

  defp emit_field_region_handoff_applied(observe_context, result) do
    CliObserve.emit("voxel_field_region_handoff_applied", fn ->
      attrs_map(observe_context)
      |> Map.merge(result)
    end)
  end

  defp emit_field_region_handoff_rejected(observe_context, result) do
    CliObserve.emit("voxel_field_region_handoff_rejected", fn ->
      attrs_map(observe_context)
      |> Map.merge(result)
    end)
  end

  defp field_effect_observe_base(state, context) do
    context = attrs_map(context)

    %{
      logical_scene_id: state.logical_scene_id,
      chunk_coord: state.chunk_coord,
      chunk_version: state.storage.chunk_version,
      region_id: fetch_optional(context, [:region_id]),
      kernel_id: fetch_optional(context, [:kernel_id])
    }
  end

  defp phenomenon_instance_summaries(instances) when is_map(instances) do
    Map.new(instances, fn {id, instance} ->
      {inspect(id), PhenomenonInstance.summary(instance)}
    end)
  end

  defp summarize_intent_attrs(attrs) when is_map(attrs) do
    intent_attrs = fetch_optional(attrs, [:intent]) || attrs
    lease = fetch_optional(intent_attrs, [:lease]) || fetch_optional(attrs, [:lease])

    %{
      request_id: fetch_optional(attrs, [:request_id]),
      operation: fetch_optional(intent_attrs, [:operation, :op, :type]),
      chunk_coord: fetch_optional(intent_attrs, [:chunk_coord, :center_chunk]),
      macro: fetch_optional(intent_attrs, [:macro, :macro_index, :macro_coord]),
      lease: summarize_lease(lease)
    }
  end

  defp summarize_intent_attrs(attrs), do: inspect(attrs)

  defp summarize_lease(nil), do: nil

  defp summarize_lease(%struct{} = lease) when is_atom(struct) do
    lease |> Map.from_struct() |> summarize_lease()
  end

  defp summarize_lease(lease) when is_map(lease) do
    Map.take(lease, [
      :logical_scene_id,
      :region_id,
      :lease_id,
      :owner_scene_instance_ref,
      :owner_epoch,
      :expires_at_ms
    ])
  end

  defp summarize_lease(lease), do: inspect(lease)

  defp bump_chunk_version(%Storage{} = storage) do
    %{storage | chunk_version: storage.chunk_version + 1}
  end

  defp put_subscriber(state, subscriber, request_id, delivery_opts) do
    state =
      case Map.fetch(state.subscribers, subscriber) do
        {:ok, %{monitor_ref: monitor_ref}} ->
          Process.demonitor(monitor_ref, [:flush])

          %{state | subscriber_monitors: Map.delete(state.subscriber_monitors, monitor_ref)}

        :error ->
          state
      end

    monitor_ref = Process.monitor(subscriber)

    subscriber_state =
      %{
        monitor_ref: monitor_ref,
        request_id: request_id,
        delivery_format: delivery_opts.delivery_format,
        tier: delivery_opts.tier
      }

    state = %{
      state
      | subscribers: Map.put(state.subscribers, subscriber, subscriber_state),
        subscriber_monitors: Map.put(state.subscriber_monitors, monitor_ref, subscriber)
    }

    {state, monitor_ref, subscriber_state}
  end

  defp normalize_subscriber_delivery_opts(opts) do
    %{
      delivery_format: normalize_subscriber_delivery_format(opts),
      tier: normalize_subscriber_tier(Keyword.get(opts, :tier))
    }
  end

  defp normalize_subscriber_delivery_format(opts) do
    cond do
      Keyword.get(opts, :delivery_format) in [:raw, :envelope] ->
        Keyword.fetch!(opts, :delivery_format)

      Keyword.get(opts, :delivery_format) == "envelope" or
          Keyword.get(opts, :delivery_envelope?) == true ->
        :envelope

      true ->
        :raw
    end
  end

  defp normalize_subscriber_tier(tier) when tier in [:near, :halo], do: tier
  defp normalize_subscriber_tier("near"), do: :near
  defp normalize_subscriber_tier("halo"), do: :halo
  defp normalize_subscriber_tier(_tier), do: :near

  defp drop_subscriber(state, subscriber) do
    case Map.pop(state.subscribers, subscriber) do
      {nil, subscribers} ->
        {%{state | subscribers: subscribers}, :not_subscribed}

      {%{monitor_ref: monitor_ref}, subscribers} ->
        Process.demonitor(monitor_ref, [:flush])

        state = %{
          state
          | subscribers: subscribers,
            subscriber_monitors: Map.delete(state.subscriber_monitors, monitor_ref)
        }

        {state, :unsubscribed}
    end
  end

  defp drop_subscriber_by_monitor(state, monitor_ref, subscriber) do
    %{
      state
      | subscribers: Map.delete(state.subscribers, subscriber),
        subscriber_monitors: Map.delete(state.subscriber_monitors, monitor_ref)
    }
  end

  defp clear_subscriptions(state) do
    Enum.each(state.subscriber_monitors, fn {monitor_ref, _subscriber} ->
      Process.demonitor(monitor_ref, [:flush])
    end)

    %{state | subscribers: %{}, subscriber_monitors: %{}}
  end

  defp async_persist_by_monitor(state, monitor_ref) do
    Enum.find(state.async_persists, fn {_ref, meta} -> meta.monitor_ref == monitor_ref end)
  end

  defp maybe_reply_persist_waiters(
         %{async_persists: async_persists, persist_waiters: waiters} = state
       ) do
    if map_size(async_persists) == 0 and waiters != [] do
      Enum.each(waiters, &GenServer.reply(&1, :ok))
      %{state | persist_waiters: []}
    else
      state
    end
  end

  defp push_intent_outcome(state_before, state_after, intent, reason, base_version) do
    case build_intent_delta_op(intent, state_after) do
      {:ok, op} ->
        push_chunk_delta(
          state_after,
          base_version || state_before.storage.chunk_version,
          [op],
          reason
        )

      :fallback_to_snapshot ->
        push_snapshot_fallbacks(state_after, reason)
    end
  end

  defp push_batch_outcome(state_before, state_after, intents, reason) do
    case build_batch_delta_ops(intents, state_after) do
      {:ok, ops} when ops != [] ->
        push_chunk_delta(state_after, state_before.storage.chunk_version, ops, reason)

      {:ok, []} ->
        :ok

      :fallback_to_snapshot ->
        push_snapshot_fallbacks(state_after, reason)
    end
  end

  defp build_batch_delta_ops(intents, state_after) do
    intents
    |> Enum.map(& &1.macro)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn macro, {:ok, ops} ->
      case build_macro_delta_op(macro, state_after) do
        {:ok, op} -> {:cont, {:ok, [op | ops]}}
        :fallback_to_snapshot -> {:halt, :fallback_to_snapshot}
      end
    end)
    |> case do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      :fallback_to_snapshot -> :fallback_to_snapshot
    end
  end

  defp build_macro_delta_op(macro, state_after) do
    macro_index = Types.macro_index_or_coord!(macro)
    header = Storage.macro_header_at(state_after.storage, macro_index)

    cond do
      header.mode == MacroCellHeader.cell_mode_empty() ->
        {:ok,
         %{
           delta_kind: 0,
           macro_index: macro_index,
           cell_version: header.cell_version,
           cell_hash: header.cell_hash,
           payload: <<>>
         }}

      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        case Storage.normal_block_at(state_after.storage, macro_index) do
          nil ->
            :fallback_to_snapshot

          block ->
            {:ok,
             %{
               delta_kind: 1,
               macro_index: macro_index,
               cell_version: header.cell_version,
               cell_hash: header.cell_hash,
               payload: Codec.encode_normal_block_data(block)
             }}
        end

      header.mode == MacroCellHeader.cell_mode_refined() ->
        case Storage.refined_cell_at(state_after.storage, macro_index) do
          nil ->
            :fallback_to_snapshot

          cell ->
            {:ok,
             %{
               delta_kind: 2,
               macro_index: macro_index,
               cell_version: header.cell_version,
               cell_hash: header.cell_hash,
               payload: Codec.encode_refined_cell_payload(cell)
             }}
        end

      true ->
        :fallback_to_snapshot
    end
  rescue
    _exception in ArgumentError -> :fallback_to_snapshot
  end

  defp build_intent_delta_op(%{operation: :put_solid_block} = intent, state_after) do
    new_chunk_version = state_after.storage.chunk_version
    cell_version = Keyword.get(intent.opts, :cell_version, new_chunk_version)

    cell_hash =
      Keyword.get_lazy(intent.opts, :cell_hash, fn -> Hash.digest32(inspect(intent.block)) end)

    payload = Codec.encode_normal_block_data(intent.block)

    {:ok,
     %{
       delta_kind: 1,
       macro_index: intent.macro,
       cell_version: cell_version,
       cell_hash: cell_hash,
       payload: payload
     }}
  end

  defp build_intent_delta_op(%{operation: :break_block} = intent, state_after) do
    new_chunk_version = state_after.storage.chunk_version
    cell_version = Keyword.get(intent.opts, :cell_version, new_chunk_version)
    cell_hash = Keyword.get(intent.opts, :cell_hash, 0)

    {:ok,
     %{
       delta_kind: 0,
       macro_index: intent.macro,
       cell_version: cell_version,
       cell_hash: cell_hash,
       payload: <<>>
     }}
  end

  # Phase 1c-3: emit CellRefined (delta_kind = 2) carrying the full
  # post-mutation RefinedCellData. Layer-diff is intentionally deferred
  # (see phase-1c-refined-mutation.md decision 4).
  defp build_intent_delta_op(%{operation: :put_micro_block} = intent, state_after) do
    header = Storage.macro_header_at(state_after.storage, intent.macro)
    cell = Storage.refined_cell_at(state_after.storage, intent.macro)

    {:ok,
     %{
       delta_kind: 2,
       macro_index: intent.macro,
       cell_version: header.cell_version,
       cell_hash: header.cell_hash,
       payload: Codec.encode_refined_cell_payload(cell)
     }}
  end

  defp build_intent_delta_op(%{operation: :clear_micro_block} = intent, state_after) do
    header = Storage.macro_header_at(state_after.storage, intent.macro)

    if header.mode == MacroCellHeader.cell_mode_empty() do
      # Last slot cleared → macro downgraded to :empty → CellEmpty op.
      {:ok,
       %{
         delta_kind: 0,
         macro_index: intent.macro,
         cell_version: header.cell_version,
         cell_hash: header.cell_hash,
         payload: <<>>
       }}
    else
      cell = Storage.refined_cell_at(state_after.storage, intent.macro)

      {:ok,
       %{
         delta_kind: 2,
         macro_index: intent.macro,
         cell_version: header.cell_version,
         cell_hash: header.cell_hash,
         payload: Codec.encode_refined_cell_payload(cell)
       }}
    end
  end

  defp build_intent_delta_op(_intent, _state_after), do: :fallback_to_snapshot

  defp push_chunk_delta(state, base_version, ops, reason) do
    delta_payload =
      Codec.encode_chunk_delta_payload(%{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        base_chunk_version: base_version,
        new_chunk_version: state.storage.chunk_version,
        ops: ops
      })

    Enum.each(state.subscribers, fn {subscriber, subscriber_state} ->
      push_chunk_delta_payload(state, subscriber, subscriber_state, delta_payload, base_version)

      CliObserve.emit("voxel_chunk_delta_push", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          base_chunk_version: base_version,
          new_chunk_version: state.storage.chunk_version,
          op_count: length(ops),
          subscriber: subscriber,
          request_id: subscriber_state.request_id,
          delivery_format: subscriber_state.delivery_format,
          tier: subscriber_state.tier,
          reason: reason,
          byte_size: byte_size(delta_payload)
        }
      end)
    end)
  end

  defp push_snapshot_fallbacks(state, reason) do
    payload = encode_snapshot_payload(state.storage, 0)

    Enum.each(state.subscribers, fn {subscriber, subscriber_state} ->
      push_snapshot_fallback(state, subscriber, subscriber_state, payload, reason)
    end)
  end

  # Phase 5.F: encode and fan out an EnvironmentUpdated (opcode 0x72) wire
  # payload to subscribers when a DiffusionSimulator (or similar) returns a
  # non-empty env_delta with ops. base_chunk_version = new_chunk_version =
  # current storage chunk_version (Phase 5.F simulator does NOT mutate
  # storage.environment_summaries in this commit; writeback to canonical
  # storage推到 Phase 5.F.runtime).
  defp maybe_fan_out_environment_updated_payload(
         state,
         sim_id,
         env_delta,
         chunk_version,
         tick_seq
       ) do
    cond do
      not is_map(env_delta) ->
        :ok

      not Map.has_key?(env_delta, :ops) ->
        :ok

      env_delta.ops == [] ->
        :ok

      map_size(state.subscribers) == 0 ->
        # No subscribers to push to; observe-only counter still emitted below.
        CliObserve.emit("voxel_environment_updated_skipped", fn ->
          %{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            tick_seq: tick_seq,
            simulator_id: sim_id,
            update_count: length(env_delta.ops),
            reason: :no_subscribers
          }
        end)

      true ->
        payload =
          Codec.encode_environment_updated_payload(%{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            base_chunk_version: chunk_version,
            new_chunk_version: chunk_version,
            updates: env_delta.ops
          })

        Enum.each(state.subscribers, fn {subscriber, _opts} ->
          send(subscriber, {:voxel_environment_updated_payload, payload})
        end)

        CliObserve.emit("voxel_environment_updated_push", fn ->
          %{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            tick_seq: tick_seq,
            simulator_id: sim_id,
            update_count: length(env_delta.ops),
            byte_size: byte_size(payload),
            subscriber_count: map_size(state.subscribers)
          }
        end)
    end
  end

  # Phase 4-bis (D1):fan out an already-encoded ObjectStateDelta wire
  # payload to every subscriber of this chunk. ObjectRegistry encodes once
  # and pushes the same binary to every affected ChunkProcess; each
  # ChunkProcess fan-outs to its own subscribers (mirroring push_chunk_delta).
  defp fan_out_object_state_delta_payload(state, payload) do
    Enum.each(state.subscribers, fn {subscriber, %{request_id: request_id}} ->
      send(subscriber, {:voxel_object_state_delta_payload, payload})

      CliObserve.emit("voxel_object_state_delta_push", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          subscriber: subscriber,
          request_id: request_id,
          byte_size: byte_size(payload)
        }
      end)
    end)
  end

  # Phase 6: fan out a 0x73 FieldRegionSnapshot to every subscriber.
  defp fan_out_field_snapshot_payload(state, payload) do
    subscriber_count = map_size(state.subscribers)

    CliObserve.emit("voxel_field_snapshot_fanout", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        subscriber_count: subscriber_count,
        byte_size: byte_size(payload)
      }
    end)

    Enum.each(state.subscribers, fn {subscriber, _opts} ->
      send(subscriber, {:voxel_field_region_snapshot_payload, payload})

      CliObserve.emit("voxel_field_snapshot_push", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          subscriber: subscriber,
          byte_size: byte_size(payload)
        }
      end)
    end)
  end

  # Phase 6: fan out a 0x74 FieldRegionDestroyed to every subscriber.
  defp fan_out_field_region_destroyed_payload(state, payload) do
    subscriber_count = map_size(state.subscribers)

    CliObserve.emit("voxel_field_region_destroyed_fanout", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        subscriber_count: subscriber_count,
        byte_size: byte_size(payload)
      }
    end)

    Enum.each(state.subscribers, fn {subscriber, _opts} ->
      send(subscriber, {:voxel_field_region_destroyed_payload, payload})

      CliObserve.emit("voxel_field_region_destroyed_push", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          subscriber: subscriber,
          byte_size: byte_size(payload)
        }
      end)
    end)
  end

  defp release_field_region_from_destroyed_payload(state, payload) do
    case decode_field_region_destroyed_payload(payload) do
      %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord,
        region_id: region_id,
        destroy_reason: destroy_reason
      }
      when logical_scene_id == state.logical_scene_id and chunk_coord == state.chunk_coord ->
        release_worker_destroyed_field_region(state, region_id, destroy_reason)

      _other ->
        state
    end
  end

  defp decode_field_region_destroyed_payload(payload) do
    FieldCodec.decode_destroyed_payload!(payload)
  rescue
    _error -> nil
  end

  defp release_worker_destroyed_field_region(state, region_id, destroy_reason) do
    source_key = Map.get(state.field_region_source_keys, region_id)

    next_state =
      state
      |> cleanup_linked_field_regions(source_key, destroy_reason)
      |> drop_field_region_id(region_id)

    if source_key do
      result =
        field_source_cleanup_result(
          region_id,
          source_key,
          region_action_for_worker_destroyed(destroy_reason),
          source_action_for_worker_down(destroy_reason),
          destroy_reason
        )

      emit_field_source_lifecycle(next_state, result)
    end

    next_state
  end

  defp region_action_for_worker_destroyed(:expired), do: :expired
  defp region_action_for_worker_destroyed(reason), do: reason

  defp maybe_schedule_auto_circuit_refresh(state, true) do
    if Map.get(state, :auto_circuit_refresh_pending?, false) do
      state
    else
      Process.send_after(
        self(),
        :refresh_auto_circuit_after_mutation,
        @auto_circuit_refresh_debounce_ms
      )

      %{state | auto_circuit_refresh_pending?: true}
    end
  end

  defp maybe_schedule_auto_circuit_refresh(state, _changed?), do: state

  defp maybe_schedule_auto_circuit_refresh_for_subscriber(state) do
    source_key = auto_circuit_source_key(state)

    cond do
      Map.has_key?(state.field_region_sources, source_key) ->
        state

      storage_has_auto_circuit_roles?(state.storage) ->
        maybe_schedule_auto_circuit_refresh(state, true)

      true ->
        state
    end
  end

  defp storage_has_auto_circuit_roles?(%Storage{} = storage) do
    projection = ParticipantProjection.build(storage)
    aabb = auto_circuit_aabb()
    source_points = auto_circuit_source_points(projection, aabb)
    load_count = auto_circuit_role_count(projection, aabb, :load)

    source_points != [] and load_count > 0 and
      auto_circuit_closed_circuit_count(projection, aabb, storage.chunk_coord, source_points) >
        0
  end

  defp storage_has_auto_circuit_roles?(_storage), do: false

  defp refresh_auto_circuit_after_mutation(%{storage: %Storage{} = storage} = state) do
    projection = ParticipantProjection.build(storage)
    aabb = auto_circuit_aabb()
    source_key = auto_circuit_source_key(state)
    source_points = auto_circuit_source_points(projection, aabb)
    load_count = auto_circuit_role_count(projection, aabb, :load)

    closed_circuit_count =
      auto_circuit_closed_circuit_count(projection, aabb, state.chunk_coord, source_points)

    cond do
      source_points == [] ->
        {_result, next_state} =
          release_field_region_source_entry(state, source_key, :explicit)

        emit_auto_circuit_refresh(next_state, :released, %{
          reason: :no_power_source,
          source_count: 0,
          load_count: load_count,
          closed_circuit_count: closed_circuit_count,
          source_key: source_key
        })

        next_state

      load_count == 0 ->
        {_result, next_state} =
          release_field_region_source_entry(state, source_key, :explicit)

        emit_auto_circuit_refresh(next_state, :released, %{
          reason: :no_load,
          source_count: length(source_points),
          load_count: 0,
          closed_circuit_count: closed_circuit_count,
          source_key: source_key
        })

        next_state

      closed_circuit_count == 0 ->
        {_result, next_state} =
          release_field_region_source_entry(state, source_key, :explicit)

        emit_auto_circuit_refresh(next_state, :released, %{
          reason: :no_closed_circuit,
          source_count: length(source_points),
          load_count: load_count,
          closed_circuit_count: closed_circuit_count,
          source_key: source_key
        })

        next_state

      true ->
        attrs = %{
          chunk_coord: state.chunk_coord,
          aabb: aabb,
          kernels: [auto_circuit_kernel_spec()],
          source_points: source_points,
          max_ticks: nil,
          source_points_mode: :replace,
          source_key: source_key
        }

        case ensure_field_source_region_in_state(state, attrs, source_key) do
          {{:ok, result}, next_state} ->
            emit_auto_circuit_refresh(next_state, :active, %{
              source_count: length(source_points),
              load_count: load_count,
              closed_circuit_count: closed_circuit_count,
              source_key: source_key,
              region_id: result.region_id,
              field_region_created: result.created?,
              source_points_action: result.source_points_action
            })

            next_state

          {{:error, reason}, next_state} ->
            emit_auto_circuit_refresh(next_state, :failed, %{
              source_count: length(source_points),
              load_count: load_count,
              closed_circuit_count: closed_circuit_count,
              source_key: source_key,
              reason: inspect(reason)
            })

            next_state
        end
    end
  rescue
    error ->
      emit_auto_circuit_refresh(state, :failed, %{
        reason: Exception.message(error),
        source_key: auto_circuit_source_key(state)
      })

      state
  end

  defp auto_circuit_source_key(state) do
    {:auto_circuit, state.logical_scene_id, state.chunk_coord}
  end

  defp maybe_refresh_expired_auto_circuit(state, source_key, :expired) do
    if source_key == auto_circuit_source_key(state) and
         storage_has_auto_circuit_roles?(state.storage) do
      maybe_schedule_auto_circuit_refresh(state, true)
    else
      state
    end
  end

  defp maybe_refresh_expired_auto_circuit(state, _source_key, _destroy_reason), do: state

  defp auto_circuit_kernel_spec do
    %{
      id: :circuit_current,
      module: CircuitCurrentKernel,
      opts: %{
        current_limit_amps: MaterialCatalog.power_source_defaults().current_limit_amps
      }
    }
  end

  defp auto_circuit_closed_circuit_count(projection, aabb, chunk_coord, source_points) do
    region =
      FieldRegion.new(%{
        region_id: 0,
        chunk_coord: chunk_coord,
        aabb: aabb,
        kernels: [auto_circuit_kernel_spec()],
        source_points: source_points
      })

    region
    |> CircuitComponentAnalysis.active_circuit_components(projection)
    |> length()
  end

  defp auto_circuit_source_points(projection, aabb) do
    voltage = MaterialCatalog.power_source_defaults().voltage

    aabb
    |> auto_circuit_aabb_macro_indices()
    |> Enum.filter(&ParticipantProjection.electric_role?(projection, &1, :source))
    |> Enum.map(fn macro_index ->
      %{
        macro_index: macro_index,
        field_type: :electric_potential,
        source_mode: :persistent,
        value: voltage
      }
    end)
  end

  defp auto_circuit_role_count(projection, aabb, role) do
    aabb
    |> auto_circuit_aabb_macro_indices()
    |> Enum.count(&ParticipantProjection.electric_role?(projection, &1, role))
  end

  defp auto_circuit_aabb, do: {{0, 0, 0}, {15, 15, 15}}

  defp auto_circuit_aabb_macro_indices({{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    for x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z do
      Types.macro_index!({x, y, z})
    end
  end

  defp emit_auto_circuit_refresh(state, action, attrs) do
    CliObserve.emit("voxel_auto_circuit_refreshed", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        chunk_version: state.storage.chunk_version,
        action: action,
        field_region_count: map_size(state.field_regions),
        field_source_count: map_size(state.field_region_sources)
      }
      |> Map.merge(attrs)
    end)
  end

  # Phase 6: closure factory captured by FieldTickWorker. Sends `:debug_state`
  # to the chunk process to retrieve current storage at tick time.
  defp build_storage_fn do
    chunk_pid = self()

    fn ->
      try do
        case GenServer.call(chunk_pid, :debug_state, 200) do
          %{storage: %Storage{} = storage} -> storage
          _ -> nil
        end
      catch
        :exit, _ -> nil
      end
    end
  end

  defp start_field_region(state, attrs, source_key) do
    region_id =
      Map.get_lazy(attrs, :region_id, fn ->
        System.unique_integer([:positive, :monotonic])
      end)

    region_attrs =
      attrs
      |> Map.delete(:source_key)
      |> Map.put(:region_id, region_id)
      |> Map.put_new(:chunk_coord, state.chunk_coord)
      |> Map.put_new(:lease_token, state.lease)

    try do
      region = FieldRegion.new(region_attrs)
      chunk_pid = self()

      worker_opts = [
        region: region,
        chunk_pid: chunk_pid,
        storage_fn: build_storage_fn(),
        initial_storage: state.storage,
        logical_scene_id: state.logical_scene_id
      ]

      case FieldTickSupervisor.start_worker(worker_opts) do
        {:ok, worker_pid} ->
          monitor_ref = Process.monitor(worker_pid)

          next_state =
            state
            |> put_field_worker(region_id, worker_pid, monitor_ref)
            |> put_field_source(region_id, source_key)
            |> put_field_region_cleanup_links(
              source_key,
              Map.get(attrs, :linked_field_regions)
            )

          {:ok, region_id, next_state}

        {:error, reason} ->
          {:error, {:start_worker_failed, reason}}
      end
    rescue
      error -> {:error, {:invalid_field_region, Exception.message(error)}}
    end
  end

  defp ensure_field_source_region_in_state(state, attrs, source_key) do
    case Map.fetch(state.field_region_sources, source_key) do
      {:ok, region_id} ->
        case Map.fetch(state.field_regions, region_id) do
          {:ok, worker_pid} ->
            if Process.alive?(worker_pid) do
              source_points_summary = FieldTickWorker.refresh_region(worker_pid, attrs)

              result =
                field_source_lifecycle_result(
                  region_id,
                  source_key,
                  false,
                  :reused,
                  source_points_summary
                )

              next_state =
                put_field_region_cleanup_links(
                  state,
                  source_key,
                  Map.get(attrs, :linked_field_regions)
                )

              emit_field_source_lifecycle(next_state, result)

              {{:ok, result}, next_state}
            else
              cleaned_state = drop_field_region_id(state, region_id)
              ensure_new_field_source_region(cleaned_state, attrs, source_key)
            end

          :error ->
            cleaned_state = forget_field_source(state, source_key)
            ensure_new_field_source_region(cleaned_state, attrs, source_key)
        end

      :error ->
        ensure_new_field_source_region(state, attrs, source_key)
    end
  end

  defp ensure_new_field_source_region(state, attrs, source_key) do
    case start_field_region(state, attrs, source_key) do
      {:ok, region_id, next_state} ->
        source_points_summary = seed_field_source_points_summary(attrs)

        result =
          field_source_lifecycle_result(
            region_id,
            source_key,
            true,
            :created,
            source_points_summary
          )

        emit_field_source_lifecycle(next_state, result)

        {{:ok, result}, next_state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp ensure_stable_field_region(state, attrs, region_id) do
    case Map.fetch(state.field_regions, region_id) do
      {:ok, worker_pid} ->
        if Process.alive?(worker_pid) do
          source_points_summary = FieldTickWorker.refresh_region(worker_pid, attrs)

          result =
            field_source_lifecycle_result(
              region_id,
              nil,
              false,
              :reused,
              source_points_summary
            )

          emit_field_source_lifecycle(state, result)

          {:reply, {:ok, result}, state}
        else
          cleaned_state = drop_field_region_id(state, region_id)
          ensure_new_stable_field_region(cleaned_state, attrs, region_id)
        end

      :error ->
        ensure_new_stable_field_region(state, attrs, region_id)
    end
  end

  defp ensure_new_stable_field_region(state, attrs, region_id) do
    case start_field_region(state, Map.put(attrs, :region_id, region_id), nil) do
      {:ok, ^region_id, next_state} ->
        source_points_summary = seed_field_source_points_summary(attrs)

        result =
          field_source_lifecycle_result(
            region_id,
            nil,
            true,
            :created,
            source_points_summary
          )

        emit_field_source_lifecycle(next_state, result)

        {:reply, {:ok, result}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp seed_field_source_points_summary(attrs) do
    case Map.fetch(attrs, :source_points) do
      {:ok, source_points} when is_list(source_points) and source_points != [] ->
        %{source_points_action: :seeded, source_points_count: length(source_points)}

      {:ok, []} ->
        %{source_points_action: :none, source_points_count: 0}

      {:ok, _other} ->
        %{source_points_action: :none, source_points_count: 0}

      :error ->
        %{source_points_action: :none, source_points_count: 0}
    end
  end

  defp release_field_region_source_entry(state, source_key, destroy_reason) do
    case Map.fetch(state.field_region_sources, source_key) do
      :error ->
        next_state =
          state
          |> cleanup_linked_field_regions(source_key, destroy_reason)
          |> forget_field_region_cleanup_links(source_key)

        result =
          field_source_cleanup_result(
            nil,
            source_key,
            :noop,
            :missing,
            destroy_reason
          )

        emit_field_source_lifecycle(next_state, result)
        {result, next_state}

      {:ok, region_id} ->
        case Map.fetch(state.field_regions, region_id) do
          :error ->
            next_state =
              state
              |> cleanup_linked_field_regions(source_key, destroy_reason)
              |> forget_field_source(source_key)
              |> forget_field_region_cleanup_links(source_key)

            result =
              field_source_cleanup_result(
                region_id,
                source_key,
                :missing,
                :released,
                destroy_reason
              )

            emit_field_source_lifecycle(next_state, result)
            {result, next_state}

          {:ok, _worker_pid} ->
            case destroy_field_region_entry(state, region_id, destroy_reason) do
              {:ok, next_state} ->
                result =
                  field_source_cleanup_result(
                    region_id,
                    source_key,
                    :destroyed,
                    :released,
                    destroy_reason
                  )

                emit_field_source_lifecycle(next_state, result)
                {result, next_state}

              {:not_found, next_state} ->
                result =
                  field_source_cleanup_result(
                    region_id,
                    source_key,
                    :missing,
                    :released,
                    destroy_reason
                  )

                emit_field_source_lifecycle(next_state, result)
                {result, next_state}
            end
        end
    end
  end

  defp destroy_field_region_entry(state, region_id, destroy_reason) do
    case Map.fetch(state.field_regions, region_id) do
      :error ->
        {:not_found, state}

      {:ok, worker_pid} ->
        destroyed_payload =
          FieldCodec.encode_destroyed_payload(
            region_id,
            state.chunk_coord,
            state.logical_scene_id,
            field_region_wire_destroy_reason(destroy_reason)
          )

        if Process.alive?(worker_pid) do
          # Best-effort stop; the {:DOWN, ...} handler will clean monitor maps.
          try do
            GenServer.stop(worker_pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end

        source_key = Map.get(state.field_region_source_keys, region_id)

        next_state =
          state
          |> cleanup_linked_field_regions(source_key, destroy_reason)
          |> drop_field_region_id(region_id)

        fan_out_field_region_destroyed_payload(state, destroyed_payload)

        CliObserve.emit("voxel_field_region_destroyed", fn ->
          %{
            logical_scene_id: state.logical_scene_id,
            chunk_coord: state.chunk_coord,
            region_id: region_id,
            destroy_reason: destroy_reason
          }
        end)

        {:ok, next_state}
    end
  end

  defp field_source_lifecycle_result(
         region_id,
         source_key,
         created?,
         region_action,
         source_points_summary
       ) do
    source_points_summary =
      source_points_summary
      |> Map.put_new(:source_points_action, :none)
      |> Map.put_new(:source_points_count, 0)

    %{
      region_id: region_id,
      source_key: source_key,
      created?: created?,
      region_action: region_action
    }
    |> Map.merge(source_points_summary)
  end

  defp field_source_cleanup_result(
         region_id,
         source_key,
         region_action,
         source_action,
         destroy_reason
       ) do
    %{
      region_id: region_id,
      source_key: source_key,
      region_action: region_action,
      source_action: source_action,
      destroy_reason: destroy_reason
    }
  end

  defp emit_field_source_lifecycle(state, result) do
    CliObserve.emit("voxel_field_source_lifecycle", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        field_region_count: map_size(state.field_regions),
        field_source_count: map_size(state.field_region_sources)
      }
      |> Map.merge(result)
    end)
  end

  defp maybe_emit_worker_down_source_lifecycle(state, _region_id, nil, _reason), do: state

  defp maybe_emit_worker_down_source_lifecycle(state, region_id, source_key, reason) do
    destroy_reason = worker_down_destroy_reason(reason)

    result =
      field_source_cleanup_result(
        region_id,
        source_key,
        destroy_reason,
        source_action_for_worker_down(destroy_reason),
        destroy_reason
      )

    emit_field_source_lifecycle(state, result)
    state
  end

  defp worker_down_destroy_reason(:normal), do: :expired
  defp worker_down_destroy_reason(_reason), do: :worker_down

  defp source_action_for_worker_down(:expired), do: :expired
  defp source_action_for_worker_down(_reason), do: :released

  defp put_field_worker(state, region_id, worker_pid, monitor_ref) do
    %{
      state
      | field_regions: Map.put(state.field_regions, region_id, worker_pid),
        field_region_monitors: Map.put(state.field_region_monitors, monitor_ref, region_id)
    }
  end

  defp put_field_source(state, _region_id, nil), do: state

  defp put_field_source(state, region_id, source_key) do
    %{
      state
      | field_region_sources: Map.put(state.field_region_sources, source_key, region_id),
        field_region_source_keys: Map.put(state.field_region_source_keys, region_id, source_key)
    }
  end

  defp put_field_region_cleanup_links(state, nil, _links), do: state
  defp put_field_region_cleanup_links(state, _source_key, nil), do: state

  defp put_field_region_cleanup_links(state, source_key, links) do
    cleanup_links = normalize_field_region_cleanup_links(links)

    if cleanup_links == [] do
      state
    else
      %{
        state
        | field_region_cleanup_links:
            Map.put(state.field_region_cleanup_links, source_key, cleanup_links)
      }
    end
  end

  defp normalize_field_region_cleanup_links(links) when is_list(links) do
    links
    |> Enum.flat_map(&normalize_field_region_cleanup_link/1)
    |> Enum.uniq()
  end

  defp normalize_field_region_cleanup_links(link) when is_map(link) do
    normalize_field_region_cleanup_links([link])
  end

  defp normalize_field_region_cleanup_links(_links), do: []

  defp normalize_field_region_cleanup_link(link) when is_map(link) do
    region_id = fetch_optional(link, [:region_id])
    chunk_coord = fetch_optional(link, [:chunk_coord])

    cond do
      is_integer(region_id) and region_id >= 0 and not is_nil(chunk_coord) ->
        [%{chunk_coord: Types.normalize_chunk_coord!(chunk_coord), region_id: region_id}]

      true ->
        []
    end
  rescue
    _error -> []
  end

  defp normalize_field_region_cleanup_link(_link), do: []

  defp cleanup_linked_field_regions(state, nil, _destroy_reason), do: state

  defp cleanup_linked_field_regions(state, source_key, destroy_reason) do
    state.field_region_cleanup_links
    |> Map.get(source_key, [])
    |> Enum.each(fn %{chunk_coord: chunk_coord, region_id: region_id} ->
      cleanup_linked_field_region(state, source_key, chunk_coord, region_id, destroy_reason)
    end)

    state
  end

  defp cleanup_linked_field_region(state, source_key, chunk_coord, region_id, destroy_reason) do
    if chunk_coord == state.chunk_coord or is_nil(state.chunk_directory) do
      :ok
    else
      result =
        try do
          case SceneServer.Voxel.ChunkDirectory.lookup_chunk_pid(
                 state.chunk_directory,
                 state.logical_scene_id,
                 chunk_coord
               ) do
            {:ok, chunk_pid} ->
              __MODULE__.destroy_field_region(chunk_pid, region_id)

            :not_started ->
              :not_started
          end
        catch
          :exit, reason -> {:exit, reason}
        end

      CliObserve.emit("voxel_field_region_cleanup_link", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          source_key: source_key,
          linked_chunk_coord: chunk_coord,
          linked_region_id: region_id,
          destroy_reason: destroy_reason,
          result: inspect(result)
        }
      end)

      :ok
    end
  end

  defp forget_field_region_cleanup_links(state, nil), do: state

  defp forget_field_region_cleanup_links(state, source_key) do
    %{
      state
      | field_region_cleanup_links: Map.delete(state.field_region_cleanup_links, source_key)
    }
  end

  defp forget_field_source(state, source_key) do
    {region_id, sources} = Map.pop(state.field_region_sources, source_key)

    source_keys =
      if is_nil(region_id) do
        state.field_region_source_keys
      else
        Map.delete(state.field_region_source_keys, region_id)
      end

    %{state | field_region_sources: sources, field_region_source_keys: source_keys}
  end

  # Phase 6: removes (region_id → worker_pid) and the corresponding monitor_ref.
  defp drop_field_region_id(state, region_id) do
    {worker_pid, field_regions} = Map.pop(state.field_regions, region_id)

    field_region_monitors =
      if worker_pid do
        state.field_region_monitors
        |> Enum.reject(fn {_ref, rid} -> rid == region_id end)
        |> Map.new()
      else
        state.field_region_monitors
      end

    {source_key, source_keys} = Map.pop(state.field_region_source_keys, region_id)

    sources =
      if is_nil(source_key) do
        state.field_region_sources
      else
        Map.delete(state.field_region_sources, source_key)
      end

    cleanup_links =
      if is_nil(source_key) do
        state.field_region_cleanup_links
      else
        Map.delete(state.field_region_cleanup_links, source_key)
      end

    %{
      state
      | field_regions: field_regions,
        field_region_monitors: field_region_monitors,
        field_region_sources: sources,
        field_region_source_keys: source_keys,
        field_region_cleanup_links: cleanup_links
    }
  end

  # Phase 6: removes by monitor_ref (used in the :DOWN path).
  defp drop_field_region_monitor(state, monitor_ref, region_id) do
    monitors = Map.delete(state.field_region_monitors, monitor_ref)
    regions = Map.delete(state.field_regions, region_id)
    {source_key, source_keys} = Map.pop(state.field_region_source_keys, region_id)

    sources =
      if is_nil(source_key) do
        state.field_region_sources
      else
        Map.delete(state.field_region_sources, source_key)
      end

    cleanup_links =
      if is_nil(source_key) do
        state.field_region_cleanup_links
      else
        Map.delete(state.field_region_cleanup_links, source_key)
      end

    %{
      state
      | field_region_monitors: monitors,
        field_regions: regions,
        field_region_sources: sources,
        field_region_source_keys: source_keys,
        field_region_cleanup_links: cleanup_links
    }
  end

  # Phase 6: compare lease tokens. If region_id / lease_id / owner_scene_instance_ref
  # / owner_epoch differ we consider it a fresh token; nil → nil never changes.
  defp lease_changed?(nil, nil), do: false
  defp lease_changed?(nil, _new), do: true
  defp lease_changed?(_old, nil), do: true

  defp lease_changed?(old, new) when is_map(old) and is_map(new) do
    Map.get(old, :region_id) != Map.get(new, :region_id) or
      Map.get(old, :lease_id) != Map.get(new, :lease_id) or
      Map.get(old, :owner_scene_instance_ref) != Map.get(new, :owner_scene_instance_ref) or
      Map.get(old, :owner_epoch) != Map.get(new, :owner_epoch)
  end

  defp lease_changed?(_old, _new), do: false

  defp field_region_wire_destroy_reason(:expired), do: :expired
  defp field_region_wire_destroy_reason(:lease_revoked), do: :lease_revoked
  defp field_region_wire_destroy_reason(:explicit), do: :explicit
  defp field_region_wire_destroy_reason(:chunk_crash), do: :chunk_crash
  defp field_region_wire_destroy_reason(_other), do: :explicit

  # Phase 6: stop every worker and push 0x74 to subscribers for each region.
  defp stop_all_field_workers(state, reason) do
    cleanup_state =
      state.field_region_sources
      |> Map.keys()
      |> Enum.reduce(state, fn source_key, acc ->
        cleanup_linked_field_regions(acc, source_key, reason)
      end)

    Enum.each(cleanup_state.field_regions, fn {region_id, worker_pid} ->
      if Process.alive?(worker_pid) do
        try do
          GenServer.stop(worker_pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end

      destroyed_payload =
        FieldCodec.encode_destroyed_payload(
          region_id,
          cleanup_state.chunk_coord,
          cleanup_state.logical_scene_id,
          reason
        )

      fan_out_field_region_destroyed_payload(cleanup_state, destroyed_payload)

      CliObserve.emit("voxel_field_region_destroyed", fn ->
        %{
          logical_scene_id: cleanup_state.logical_scene_id,
          chunk_coord: cleanup_state.chunk_coord,
          region_id: region_id,
          destroy_reason: reason
        }
      end)
    end)

    %{
      cleanup_state
      | field_regions: %{},
        field_region_monitors: %{},
        field_region_sources: %{},
        field_region_source_keys: %{},
        field_region_cleanup_links: %{}
    }
  end

  # Temporary ChunkDelta fallback: push the full authoritative snapshot until
  # the scene/gate delta wire contract is available.
  defp push_snapshot_fallback(state, subscriber, subscriber_state, payload, reason) do
    push_chunk_snapshot(state, subscriber, subscriber_state, payload)

    CliObserve.emit("voxel_chunk_snapshot_push", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        chunk_version: state.storage.chunk_version,
        subscriber: subscriber,
        request_id: subscriber_state.request_id,
        delivery_format: subscriber_state.delivery_format,
        tier: subscriber_state.tier,
        reason: reason,
        byte_size: byte_size(payload),
        fallback: :snapshot_until_chunk_delta
      }
    end)
  end

  defp push_chunk_snapshot(state, subscriber, subscriber_state, payload) do
    case delivery_format_for(state, subscriber_state) do
      :envelope ->
        envelope =
          chunk_delivery_envelope(state, subscriber_state, :snapshot, payload, %{
            chunk_version: state.storage.chunk_version
          })

        send(subscriber, {:voxel_delivery_envelope, envelope})

      :raw ->
        send(subscriber, {:voxel_chunk_snapshot_payload, payload})
    end
  end

  defp push_chunk_delta_payload(state, subscriber, subscriber_state, payload, base_version) do
    case delivery_format_for(state, subscriber_state) do
      :envelope ->
        envelope =
          chunk_delivery_envelope(state, subscriber_state, :delta, payload, %{
            base_server_version: base_version,
            base_chunk_version: base_version,
            chunk_version: state.storage.chunk_version
          })

        send(subscriber, {:voxel_delivery_envelope, envelope})

      :raw ->
        send(subscriber, {:voxel_chunk_delta_payload, payload})
    end
  end

  defp push_chunk_invalidate(state, subscriber, subscriber_state, payload, reason) do
    case delivery_format_for(state, subscriber_state) do
      :envelope ->
        envelope =
          chunk_delivery_envelope(state, subscriber_state, :invalidate, payload, %{
            reason: reason,
            reason_name: Codec.invalidate_reason_name(reason)
          })

        send(subscriber, {:voxel_delivery_envelope, envelope})

      :raw ->
        send(subscriber, {:voxel_chunk_invalidate_payload, payload})
    end
  end

  defp delivery_format_for(%{lease: lease}, %{delivery_format: :envelope}) when is_map(lease),
    do: :envelope

  defp delivery_format_for(_state, _subscriber_state), do: :raw

  defp chunk_delivery_envelope(state, subscriber_state, frame_kind, payload, extra) do
    lease = state.lease

    %{
      frame_kind: frame_kind,
      logical_scene_id: state.logical_scene_id,
      chunk_coord: state.chunk_coord,
      tier: subscriber_state.tier,
      stream_class: stream_class_for_frame_kind(frame_kind),
      byte_size: byte_size(payload),
      server_version: state.storage.chunk_version,
      lease_id: lease.lease_id,
      owner_epoch: lease.owner_epoch,
      payload: payload
    }
    |> Map.merge(extra)
    |> maybe_put_region_id(lease)
  end

  defp stream_class_for_frame_kind(:snapshot), do: :voxel_snapshot
  defp stream_class_for_frame_kind(:delta), do: :voxel_delta
  defp stream_class_for_frame_kind(:invalidate), do: :reliable_control

  defp maybe_put_region_id(envelope, %{region_id: region_id}) when not is_nil(region_id),
    do: Map.put(envelope, :region_id, region_id)

  defp maybe_put_region_id(envelope, _lease), do: envelope

  defp encode_snapshot_payload(%Storage{} = storage, request_id) do
    Codec.encode_chunk_snapshot_payload(%{request_id: request_id, storage: storage})
  end

  # 阶段2.5(voxel-storage-6):单意图热路径原本对**同一 storage** 全量 encode
  # 两次(reply payload request_id=intent.request_id;persist payload
  # request_id=0)——body(sections + chunk_hash,占载荷绝大部分)完全相同,只有
  # 头 8 字节 request_id 不同。这里只 encode 一次,再纯字节拼接 request_id 头,
  # 得到两份**逐字节**与原双 encode 一致的载荷,把热路径全量 encode 砍半。
  #
  # 依据 ChunkSnapshot wire layout(Codec.encode_chunk_snapshot_payload):首字段
  # 即 `request_id::unsigned-big-integer-size(64)`,故替换前 8 字节零漂移。
  defp encode_snapshot_payloads_dual(%Storage{} = storage, request_id) do
    persist_payload = encode_snapshot_payload(storage, 0)

    reply_payload =
      if request_id == 0 do
        persist_payload
      else
        <<_old_request_id::unsigned-big-integer-size(64), rest::binary>> = persist_payload
        <<request_id::unsigned-big-integer-size(64), rest::binary>>
      end

    {reply_payload, persist_payload}
  end

  defp normalize_apply_intent(attrs) when is_map(attrs) do
    intent_attrs = fetch_optional(attrs, [:intent]) || attrs

    with {:ok, lease} <- fetch_required([intent_attrs, attrs], [:lease], :missing_lease),
         {:ok, lease} <- safe_normalize_lease(lease),
         {:ok, logical_scene_id} <-
           fetch_required(
             [intent_attrs, attrs],
             [:logical_scene_id],
             :missing_logical_scene_id
           ),
         {:ok, chunk_coord} <-
           fetch_required(
             [intent_attrs, attrs],
             [:chunk_coord, :center_chunk],
             :missing_chunk_coord
           ),
         {:ok, chunk_coord} <- safe_chunk_coord(chunk_coord),
         {:ok, operation} <-
           normalize_operation(
             fetch_optional(intent_attrs, [:operation, :op, :type]) ||
               fetch_optional(attrs, [:operation, :op, :type]) ||
               :put_solid_block
           ),
         {:ok, macro_index} <-
           fetch_required(
             [intent_attrs, attrs],
             [:macro, :macro_index, :macro_coord],
             :missing_macro
           ),
         {:ok, macro_index} <- safe_macro_index(macro_index),
         {:ok, block} <- normalize_intent_block(operation, intent_attrs, attrs),
         {:ok, micro_slot} <- normalize_intent_micro_slot(operation, intent_attrs, attrs),
         {:ok, micro_layer} <- normalize_intent_micro_layer(operation, intent_attrs, attrs),
         {:ok, request_id} <-
           normalize_request_id(
             fetch_optional(intent_attrs, [:request_id]) || fetch_optional(attrs, [:request_id])
           ),
         {:ok, expected_chunk_version} <-
           normalize_expected_chunk_version(
             fetch_optional(intent_attrs, [:expected_chunk_version]) ||
               fetch_optional(attrs, [:expected_chunk_version])
           ),
         {:ok, expected_cell_hash} <-
           normalize_expected_cell_hash(
             fetch_optional(intent_attrs, [:expected_cell_hash]) ||
               fetch_optional(attrs, [:expected_cell_hash])
           ),
         {:ok, opts} <- normalize_intent_opts(attrs, intent_attrs) do
      {:ok,
       %{
         request_id: request_id,
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         lease: lease,
         operation: operation,
         macro: macro_index,
         block: block,
         micro_slot: micro_slot,
         micro_layer: micro_layer,
         expected_chunk_version: expected_chunk_version,
         expected_cell_hash: expected_cell_hash,
         opts: opts
       }}
    end
  end

  defp normalize_apply_intent(_attrs), do: {:error, :invalid_voxel_intent}

  defp normalize_apply_intents([]), do: {:ok, []}

  defp normalize_apply_intents(attrs_list) when is_list(attrs_list) do
    attrs_list
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case normalize_apply_intent(attrs) do
        {:ok, intent} -> {:cont, {:ok, [intent | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, intents} -> {:ok, Enum.reverse(intents)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_apply_intents(_attrs_list), do: {:error, :invalid_voxel_intent}

  # `:break_block` clears a macro cell back to empty mode and never carries
  # block payload on the wire (delta_kind = 0 CellEmpty). Micro operations
  # carry their own MicroLayer attrs in the `micro_layer` intent field, not
  # a NormalBlockData. Every other operation must include a normalized
  # NormalBlockData.
  defp normalize_intent_block(:break_block, _intent_attrs, _attrs), do: {:ok, nil}
  defp normalize_intent_block(:put_micro_block, _intent_attrs, _attrs), do: {:ok, nil}
  defp normalize_intent_block(:clear_micro_block, _intent_attrs, _attrs), do: {:ok, nil}

  defp normalize_intent_block(_operation, intent_attrs, attrs) do
    with {:ok, block} <-
           fetch_required([intent_attrs, attrs], [:block, :normal_block], :missing_block),
         {:ok, block} <- safe_normalize_block(block) do
      {:ok, block}
    end
  end

  # Phase 1c — extract micro_slot for :put_micro_block / :clear_micro_block.
  defp normalize_intent_micro_slot(op, intent_attrs, attrs)
       when op in [:put_micro_block, :clear_micro_block] do
    with {:ok, slot} <-
           fetch_required(
             [intent_attrs, attrs],
             [:micro_slot, :micro_slot_index],
             :missing_micro_slot
           ),
         {:ok, slot} <- safe_micro_slot(slot) do
      {:ok, slot}
    end
  end

  defp normalize_intent_micro_slot(_op, _intent_attrs, _attrs), do: {:ok, nil}

  # Phase 1c — extract micro_layer attrs for :put_micro_block.
  defp normalize_intent_micro_layer(:put_micro_block, intent_attrs, attrs) do
    with {:ok, layer} <-
           fetch_required(
             [intent_attrs, attrs],
             [:micro_layer, :layer],
             :missing_micro_layer
           ),
         {:ok, layer} <- safe_normalize_micro_layer(layer) do
      {:ok, layer}
    end
  end

  defp normalize_intent_micro_layer(_op, _intent_attrs, _attrs), do: {:ok, nil}

  defp safe_micro_slot(value) when is_integer(value) and value >= 0 and value <= 511 do
    {:ok, value}
  end

  defp safe_micro_slot(_), do: {:error, :invalid_micro_slot}

  defp normalize_collision_query(attrs) when is_map(attrs) do
    samples = fetch_optional(attrs, [:samples]) || []

    cond do
      not is_list(samples) ->
        {:error, :invalid_collision_query}

      samples == [] ->
        {:ok, %{samples: []}}

      true ->
        samples
        |> Enum.reduce_while({:ok, []}, fn sample, {:ok, acc} ->
          case normalize_collision_sample(sample) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, normalized} ->
            samples =
              normalized
              |> Enum.reverse()
              |> Enum.uniq_by(fn sample -> {sample.macro_index, sample.micro_slot} end)

            {:ok, %{samples: samples}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp normalize_collision_query(_attrs), do: {:error, :invalid_collision_query}

  defp normalize_collision_sample({macro, micro_slot}) do
    normalize_collision_sample(%{macro: macro, micro_slot: micro_slot})
  end

  defp normalize_collision_sample(%{} = attrs) do
    with macro_value when not is_nil(macro_value) <-
           fetch_optional(attrs, [:macro, :macro_index, :macro_coord]),
         {:ok, macro_index} <- safe_macro_index(macro_value),
         slot when not is_nil(slot) <- fetch_optional(attrs, [:micro_slot, :micro_slot_index]),
         {:ok, micro_slot} <- safe_micro_slot(slot) do
      {:ok,
       %{
         macro_index: macro_index,
         macro: Types.macro_coord!(macro_index),
         micro_slot: micro_slot
       }}
    else
      nil -> {:error, :invalid_collision_sample}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_collision_sample(_sample), do: {:error, :invalid_collision_sample}

  defp collision_query_hits(%Storage{} = storage, samples) do
    index = collision_query_index(storage)

    Enum.flat_map(samples, fn sample ->
      case collision_query_hit(index, sample) do
        nil -> []
        hit -> [hit]
      end
    end)
  end

  # 阶段2.5:碰撞查询不再每次 `List.to_tuple` 重建 O(n) 索引——直接复用 Storage
  # 维护的 accel(:array headers + map refined),`fetch_macro_header/2` /
  # `fetch_refined_cell/2` 均 O(1)。`ensure_accel/1` 幂等,storage 已建则零成本。
  defp collision_query_index(%Storage{} = storage) do
    %{
      storage: Storage.ensure_accel(storage),
      solid_mode: MacroCellHeader.cell_mode_solid_block(),
      refined_mode: MacroCellHeader.cell_mode_refined()
    }
  end

  defp collision_query_hit(index, sample) do
    header = Storage.fetch_macro_header(index.storage, sample.macro_index)

    cond do
      header.mode == index.solid_mode ->
        Map.put(sample, :mode, :solid)

      header.mode == index.refined_mode and
          collision_query_micro_slot_occupied?(index, header.payload_index, sample.micro_slot) ->
        Map.put(sample, :mode, :refined)

      true ->
        nil
    end
  end

  defp collision_query_micro_slot_occupied?(index, payload_index, micro_slot) do
    refined_cell = Storage.fetch_refined_cell(index.storage, payload_index)
    word_idx = div(micro_slot, 64)
    bit_idx = rem(micro_slot, 64)
    word = Enum.at(refined_cell.occupancy_words, word_idx)

    band(word, bsl(1, bit_idx)) != 0
  end

  defp safe_normalize_micro_layer(layer) when is_map(layer) do
    {:ok,
     Map.take(layer, [
       :material_id,
       :state_flags,
       :health,
       :attribute_set_ref,
       :tag_set_ref,
       :owner_object_id,
       :owner_part_id
     ])}
  end

  defp safe_normalize_micro_layer(_), do: {:error, :invalid_micro_layer}

  defp normalize_load_snapshot(attrs) when is_map(attrs) do
    with {:ok, storage} <- load_snapshot_storage(attrs),
         {:ok, lease} <- load_snapshot_lease(attrs) do
      {:ok, %{storage: storage, lease: lease}}
    end
  end

  defp normalize_load_snapshot(_attrs), do: {:error, :invalid_prewarm_snapshot}

  defp load_snapshot_storage(attrs) do
    cond do
      storage = fetch_optional(attrs, [:storage]) ->
        {:ok, Storage.normalize!(storage)}

      snapshot = fetch_optional(attrs, [:snapshot]) ->
        snapshot
        |> fetch_optional([:data])
        |> decode_prewarm_payload()

      payload = fetch_optional(attrs, [:payload, :data]) ->
        decode_prewarm_payload(payload)

      true ->
        {:error, :missing_prewarm_snapshot}
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_prewarm_snapshot}
  end

  defp decode_prewarm_payload(payload) when is_binary(payload) do
    case Codec.decode_chunk_snapshot_payload(payload) do
      {:ok, %{storage: storage}} -> {:ok, storage}
      {:error, _reason} -> {:error, :invalid_prewarm_snapshot}
    end
  end

  defp decode_prewarm_payload(_payload), do: {:error, :invalid_prewarm_snapshot}

  defp load_snapshot_lease(attrs) do
    case fetch_optional(attrs, [:lease]) do
      nil -> {:ok, nil}
      lease -> safe_normalize_lease(lease)
    end
  end

  defp safe_normalize_lease(lease) do
    {:ok, normalize_lease(lease)}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_lease}
  end

  defp safe_chunk_coord(value) do
    {:ok, coord!(value)}
  rescue
    _exception in ArgumentError -> {:error, :invalid_chunk_coord}
  end

  defp safe_macro_index(value) do
    {:ok, Types.macro_index_or_coord!(value)}
  rescue
    _exception in ArgumentError -> {:error, :invalid_macro}
  end

  defp safe_normalize_block(block) do
    {:ok, NormalBlockData.normalize!(block)}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_block}
  end

  defp normalize_operation(:put_solid_block), do: {:ok, :put_solid_block}
  defp normalize_operation("put_solid_block"), do: {:ok, :put_solid_block}
  defp normalize_operation(:solid_block), do: {:ok, :put_solid_block}
  defp normalize_operation("solid_block"), do: {:ok, :put_solid_block}
  defp normalize_operation(:break_block), do: {:ok, :break_block}
  defp normalize_operation("break_block"), do: {:ok, :break_block}
  defp normalize_operation(:break), do: {:ok, :break_block}
  defp normalize_operation("break"), do: {:ok, :break_block}
  defp normalize_operation(:put_micro_block), do: {:ok, :put_micro_block}
  defp normalize_operation("put_micro_block"), do: {:ok, :put_micro_block}
  defp normalize_operation(:clear_micro_block), do: {:ok, :clear_micro_block}
  defp normalize_operation("clear_micro_block"), do: {:ok, :clear_micro_block}
  defp normalize_operation(_operation), do: {:error, :unsupported_voxel_intent}

  defp normalize_request_id(nil), do: {:ok, 0}
  defp normalize_request_id(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_request_id(_value), do: {:error, :invalid_request_id}

  defp normalize_expected_chunk_version(nil), do: {:ok, nil}
  defp normalize_expected_chunk_version(@expected_chunk_version_unspecified), do: {:ok, nil}

  defp normalize_expected_chunk_version(value)
       when is_integer(value) and value >= 0 and value <= @expected_chunk_version_unspecified,
       do: {:ok, value}

  defp normalize_expected_chunk_version(_value), do: {:error, :invalid_expected_chunk_version}

  defp normalize_expected_cell_hash(nil), do: {:ok, nil}
  defp normalize_expected_cell_hash(@expected_cell_hash_unspecified), do: {:ok, nil}

  defp normalize_expected_cell_hash(value)
       when is_integer(value) and value >= 0 and value <= @expected_cell_hash_unspecified,
       do: {:ok, value}

  defp normalize_expected_cell_hash(_value), do: {:error, :invalid_expected_cell_hash}

  defp normalize_intent_opts(attrs, intent_attrs) do
    opts_value = fetch_optional(intent_attrs, [:opts]) || fetch_optional(attrs, [:opts]) || []

    with {:ok, opts} <- normalize_opts_value(opts_value),
         {:ok, direct_opts} <- normalize_direct_opts(attrs, intent_attrs) do
      {:ok, Keyword.merge(opts, direct_opts)}
    end
  end

  defp normalize_opts_value(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, opts}, else: {:error, :invalid_intent_options}
  end

  defp normalize_opts_value(opts) when is_map(opts) do
    {:ok, collect_known_options(opts)}
  end

  defp normalize_opts_value(_opts), do: {:error, :invalid_intent_options}

  defp normalize_direct_opts(attrs, intent_attrs) do
    direct_opts =
      [intent_attrs, attrs]
      |> Enum.flat_map(&collect_known_options/1)
      |> Keyword.take(@intent_option_keys)

    {:ok, direct_opts}
  end

  defp collect_known_options(attrs) when is_map(attrs) do
    Enum.reduce(@intent_option_keys, [], fn key, acc ->
      case fetch_optional_key(attrs, key) do
        {:ok, value} -> Keyword.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp collect_known_options(_attrs), do: []

  defp fetch_required(maps, keys, missing_reason) do
    maps
    |> Enum.reduce_while(:error, fn attrs, _acc ->
      case fetch_optional_key(attrs, keys) do
        {:ok, value} -> {:halt, {:ok, value}}
        :error -> {:cont, :error}
      end
    end)
    |> case do
      :error -> {:error, missing_reason}
      {:ok, value} -> {:ok, value}
    end
  end

  defp fetch_optional(attrs, keys) do
    case fetch_optional_key(attrs, keys) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_optional_key(attrs, keys) when is_list(keys) do
    Enum.reduce_while(keys, :error, fn key, _acc ->
      case fetch_optional_key(attrs, key) do
        {:ok, value} -> {:halt, {:ok, value}}
        :error -> {:cont, :error}
      end
    end)
  end

  defp fetch_optional_key(attrs, key) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, key) ->
        {:ok, Map.fetch!(attrs, key)}

      is_atom(key) and Map.has_key?(attrs, Atom.to_string(key)) ->
        {:ok, Map.fetch!(attrs, Atom.to_string(key))}

      true ->
        :error
    end
  end

  defp fetch_optional_key(_attrs, _key), do: :error

  defp normalize_optional_lease(nil), do: nil
  defp normalize_optional_lease(lease), do: normalize_lease(lease)

  defp normalize_lease(%struct{} = lease) when is_atom(struct) do
    lease |> Map.from_struct() |> normalize_lease()
  end

  defp normalize_lease(attrs) when is_map(attrs) do
    %{
      logical_scene_id: fetch!(attrs, :logical_scene_id),
      region_id: fetch!(attrs, :region_id),
      lease_id: fetch!(attrs, :lease_id),
      owner_scene_instance_ref: fetch!(attrs, :owner_scene_instance_ref),
      owner_epoch: fetch!(attrs, :owner_epoch),
      bounds_chunk_min: coord!(fetch!(attrs, :bounds_chunk_min)),
      bounds_chunk_max: coord!(fetch!(attrs, :bounds_chunk_max)),
      expires_at_ms: fetch!(attrs, :expires_at_ms)
    }
  end

  defp fetch!(attrs, key) do
    Map.fetch!(attrs, key)
  rescue
    KeyError ->
      raise ArgumentError, "missing required #{inspect(key)}"
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end
end
