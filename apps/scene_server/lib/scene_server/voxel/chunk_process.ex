defmodule SceneServer.Voxel.ChunkProcess do
  @moduledoc """
  Hot authoritative process for one leased voxel chunk.

  A chunk process owns scene-side chunk truth while its region lease is current.
  It can build snapshot payloads for subscribers and persist snapshots through
  DataService, which re-checks the world-issued write token before accepting the
  write.
  """

  use GenServer

  alias DataService.Voxel.ChunkPendingTransactionStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.Field.FieldCodec
  alias SceneServer.Voxel.Field.FieldProvisioner
  alias SceneServer.Voxel.Field.FieldRegion
  alias SceneServer.Voxel.Field.FieldTickSupervisor
  alias SceneServer.Voxel.Field.FieldTickWorker
  alias SceneServer.Voxel.Field.ParticipantProjection
  alias SceneServer.Voxel.Field.Provisioners.ElectricCircuit
  alias SceneServer.Voxel.Field.Provisioners.Emergence
  alias SceneServer.Voxel.Field.Provisioners.StructuralStress
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.SimulationTick
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.SurfaceElement
  alias SceneServer.Voxel.TagCatalog
  alias SceneServer.Voxel.TagPhysics
  alias SceneServer.Voxel.TagSet
  alias SceneServer.Voxel.Types
  alias SceneServer.Voxel.WorldGen

  import Bitwise

  # Phase 5.E: 10 Hz simulation tick (100ms interval). 见
  # `docs/plans/2026-05-13-phase5e-simulation-tick-infrastructure.md` E-2。
  @simulation_tick_interval_ms 100
  @field_refresh_debounce_ms 50

  # 阶段3 step3.2 idle 驱逐默认值(仅在开启时生效)。每 @default_idle_check_ms 检查一次,
  # 无订阅者 + 无活跃 field region 连续累计达 @default_idle_evict_after_ms 即自停。
  @default_idle_check_ms :timer.seconds(15)
  @default_idle_evict_after_ms :timer.minutes(2)

  # 世界内容驱动场 provisioning:块变更去抖后一次 sweep 遍历这组 provisioner,
  # 各自探测 chunk 内容 → ensure / release 对应 region。electric_circuit 第一个
  # (闭合电路);emergence(光/热/化学);structural_stress(失支撑结构坍塌)。见
  # docs/2026-06-23-world-content-driven-field-provisioning.md、
  # docs/2026-06-23-mechanical-stress-structural-collapse.md。
  @field_provisioners [ElectricCircuit, Emergence, StructuralStress]
  @fixed32_scale 65_536
  @temperature_attribute_name "temperature"
  # 温度属性 catalog 边界(冻结值,见 priv/catalogs/attribute_catalog_v1.exs id 1)。R5d:注热写须 clip 到
  # 此区间,否则越界 put_attribute_for_cell 会 raise 崩 ChunkProcess(燃烧辐射注热可达上界)。
  @temperature_min_raw -17_904_824
  @temperature_max_raw 327_680_000
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

  @doc "Starts one chunk process."
  def start_link(opts) when is_list(opts) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Applies the current region lease used for DataService writes."
  def apply_lease(server, lease) do
    GenServer.call(server, {:apply_lease, normalize_lease(lease)})
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

  @doc """
  Prefab anti-floating predicate. Two clauses:

    * `prefab_floating?(server, intents)` — read-only GenServer call against the
      hot chunk, returns a boolean. Server-authoritative backstop for prefab
      placement (the client already snaps + validates; this is the authority's
      net). Only inspects `state.storage`; never mutates.
    * `prefab_floating?(%Storage{}, intents)` — the pure predicate the call
      delegates to.

  Each intent carries `:macro` (a macro index or local macro coord) and
  `:micro_slot` (`0..511`). Policy (kept deliberately lenient to avoid false
  rejects):

    * `own_cells` = the set of `{macro_index, micro_slot}` the prefab itself
      writes — a neighbor that is one of these is the prefab touching itself and
      never counts as external support.
    * For each cell, walk its 6 face neighbors (±1 on a single chunk-local micro
      axis, each axis `0..127`):
        - a neighbor off the chunk (any axis `< 0` or `> 127`) cannot be resolved
          from this chunk's storage → flag `any_out_of_chunk` and skip it;
        - an in-chunk neighbor that is **not** part of the prefab and is
          `Storage.micro_solid?/3` → flag `any_solid_neighbor`.
    * `floating? = not any_solid_neighbor and not any_out_of_chunk`.

  i.e. the batch is rejected only when **every** neighbor of **every** cell is
  resolvable inside this chunk and none of them is solid. Any cross-chunk
  neighbor makes the batch pass — it is **lenient at chunk boundaries** so legal
  placements that butt up against the next chunk are never wrongly rejected (the
  cross-chunk / same-owner / transaction paths do not run this check — see the
  TODO at the fast-path call site in gate `tcp_connection.ex`).
  """
  @spec prefab_floating?(GenServer.server(), [map()]) :: boolean()
  @spec prefab_floating?(Storage.t(), [map()]) :: boolean()
  def prefab_floating?(server, intents)
      when is_list(intents) and not is_struct(server, Storage) do
    GenServer.call(server, {:prefab_floating?, intents})
  end

  # An empty placement writes nothing — never "floating" (matches the gate /
  # directory empty-batch short-circuits, and keeps a no-op from being rejected).
  def prefab_floating?(%Storage{}, []), do: false

  def prefab_floating?(%Storage{} = storage, intents) when is_list(intents) do
    storage = Storage.normalize!(storage)
    micro = Types.micro_resolution()

    own_cells =
      MapSet.new(intents, fn intent ->
        {Types.macro_index_or_coord!(prefab_intent_macro(intent)),
         prefab_intent_micro_slot(intent)}
      end)

    {any_solid_neighbor, any_out_of_chunk} =
      Enum.reduce(intents, {false, false}, fn intent, {solid_acc, out_acc} ->
        macro_index = Types.macro_index_or_coord!(prefab_intent_macro(intent))
        micro_slot = prefab_intent_micro_slot(intent)

        {lx, ly, lz} = Types.macro_coord!(macro_index)
        {mx, my, mz} = Types.micro_coord!(micro_slot)

        # chunk-local micro coord, each axis 0..127 (16 macros × 8 micros).
        cx = lx * micro + mx
        cy = ly * micro + my
        cz = lz * micro + mz

        Enum.reduce(
          [
            {cx - 1, cy, cz},
            {cx + 1, cy, cz},
            {cx, cy - 1, cz},
            {cx, cy + 1, cz},
            {cx, cy, cz - 1},
            {cx, cy, cz + 1}
          ],
          {solid_acc, out_acc},
          fn neighbor, {solid?, out?} ->
            classify_prefab_neighbor(storage, own_cells, micro, neighbor, solid?, out?)
          end
        )
      end)

    not any_solid_neighbor and not any_out_of_chunk
  end

  # Resolve one face neighbor in chunk-local micro space. Out-of-chunk → flag
  # `out?`; prefab-own → skip; in-chunk + solid → flag `solid?`.
  defp classify_prefab_neighbor(storage, own_cells, micro, {nx, ny, nz}, solid?, out?) do
    chunk_micro_edge = Types.chunk_size_in_macro() * micro - 1

    if nx < 0 or ny < 0 or nz < 0 or nx > chunk_micro_edge or ny > chunk_micro_edge or
         nz > chunk_micro_edge do
      {solid?, true}
    else
      n_macro_index = Types.macro_index!({div(nx, micro), div(ny, micro), div(nz, micro)})
      n_slot = Types.micro_index!({rem(nx, micro), rem(ny, micro), rem(nz, micro)})

      cond do
        MapSet.member?(own_cells, {n_macro_index, n_slot}) ->
          {solid?, out?}

        Storage.micro_solid?(storage, n_macro_index, n_slot) ->
          {true, out?}

        true ->
          {solid?, out?}
      end
    end
  end

  defp prefab_intent_macro(intent) do
    Map.get(intent, :macro) || Map.get(intent, :macro_index) || Map.get(intent, :macro_coord)
  end

  defp prefab_intent_micro_slot(intent) do
    Map.get(intent, :micro_slot) || Map.get(intent, :micro_slot_index)
  end

  @doc "Places a solid normal block and increments the chunk version."
  def put_solid_block(server, macro_index_or_coord, block, opts \\ []) do
    GenServer.call(server, {:put_solid_block, macro_index_or_coord, block, opts})
  end

  @doc """
  Writes a single refined micro block into the macro at `macro_index_or_coord`
  (slot `0..511`, `layer_attrs` a `MicroLayer`-friendly map) and bumps the chunk
  version — the in-memory counterpart to `put_solid_block/4`.

  Internal / test seeding helper (e.g. seeding a solid neighbor so a prefab is
  not floating); the World-authorized client write path goes through
  `apply_intent/2` / `apply_intents/2`.
  """
  def put_micro_block(server, macro_index_or_coord, micro_slot, layer_attrs, opts \\ []) do
    GenServer.call(
      server,
      {:put_micro_block, macro_index_or_coord, micro_slot, layer_attrs, opts}
    )
  end

  @doc """
  形态轨:在某宏格面放置(或覆盖)一个表面元件并 bump chunk_version。

  表面元件零 occupancy(不改宿主邻接/碰撞);`attrs` 须含 `:macro_index`(或 `:macro_coord`)、`:face`、
  `:surface_type_id`,可选 `:attribute_set_ref`/`:tag_set_ref`/`:owner_actor_id`。

  C5.2:若 `attrs` 带 `:lease`(网络放置路径),先同步落库再 commit + 重快照
  (durable-before-ack);无 lease(内部/测试调用)则只改内存 + 重快照,行为同旧版。
  """
  @spec put_surface_element(GenServer.server(), map() | keyword()) :: {:ok, Storage.t()}
  def put_surface_element(server, attrs) when is_map(attrs) or is_list(attrs) do
    GenServer.call(server, {:put_surface_element, Map.new(attrs)})
  end

  @doc """
  形态轨:移除某宏格面的表面元件并 bump chunk_version(处理/清氧化/刮除路径)。无则不 bump。

  `opts[:lease]` 存在时同步落库(durable-before-ack);否则只改内存(内部/测试路径)。
  """
  @spec clear_surface_element(GenServer.server(), integer() | term(), atom(), keyword()) ::
          {:ok, Storage.t()}
  def clear_surface_element(server, macro_index_or_coord, face, opts \\ []) do
    GenServer.call(server, {:clear_surface_element, macro_index_or_coord, face, opts})
  end

  @doc "形态轨:读取某宏格面的表面元件(无则 nil),不改版本。"
  @spec surface_element_at(GenServer.server(), integer() | term(), atom()) ::
          SurfaceElement.t() | nil
  def surface_element_at(server, macro_index_or_coord, face) do
    GenServer.call(server, {:surface_element_at, macro_index_or_coord, face})
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
  payload as `{:voxel_chunk_snapshot_payload, payload}`. This message is a
  temporary snapshot fallback until the scene chunk delta format lands.
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

  @impl true
  def init(opts) do
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    chunk_coord = Keyword.fetch!(opts, :chunk_coord)
    worldgen = resolve_worldgen(opts)

    storage =
      case Keyword.get(opts, :storage) do
        nil ->
          # Start from the DB-persisted snapshot (terrain + chunk_version), not an
          # empty chunk. Otherwise a fresh process after a restart is at version 0
          # while the DB holds a higher persisted version, so its first persist is
          # :stale_chunk_version and the batch self-heal must reload the snapshot
          # per batch — making every write pay an extra DB round-trip. Loading once
          # here keeps the version consistent.
          #
          # 阶段3:DB 无行(从未被编辑的纯净 chunk)时,若开启 WorldGen 则确定性程序化生成
          # 基线地形(version 0,不持久化),否则空 chunk。
          load_persisted_storage_or_generate(logical_scene_id, chunk_coord, worldgen)

        provided ->
          provided
      end
      |> Storage.normalize!()

    lease = normalize_optional_lease(Keyword.get(opts, :lease))

    pending_fence = load_persisted_fence(storage.logical_scene_id, storage.chunk_coord, lease)

    simulators = resolve_simulators(opts)
    simulation_tick = SimulationTick.new(simulators)
    schedule_simulation_tick()

    # 梯队1 step1.1b(TIME-1):从持久化恢复 cell_tick/sim_time_ms,并加 restart gap 保证
    # 跨重启/所有权变更严格单调(逻辑时钟允许跳变,只要不回退)。无持久化行则从 0 起。
    {restored_cell_tick, restored_sim_time_ms} =
      restore_cell_time(storage.logical_scene_id, storage.chunk_coord)

    state =
      %{
        logical_scene_id: storage.logical_scene_id,
        chunk_coord: storage.chunk_coord,
        storage: storage,
        lease: lease,
        cell_tick: restored_cell_tick,
        sim_time_ms: restored_sim_time_ms,
        subscribers: %{},
        subscriber_monitors: %{},
        pending_fence: pending_fence,
        # Phase 4 (D7):wired to ObjectRegistry / ChunkDirectory for damage
        # attribution and downstream destroy_part dispatch. Tests inject
        # stubbed names; production wiring uses module-named singletons.
        object_registry: Keyword.get(opts, :object_registry, SceneServer.Voxel.ObjectRegistry),
        chunk_directory: Keyword.get(opts, :chunk_directory, SceneServer.Voxel.ChunkDirectory),
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
        field_refresh_pending?: false,
        # 世界内容驱动场 provisioning 总开关(默认开)。手动编排 field tick 做确定性
        # kernel→truth 断言的测试可关掉它,独占控制 field(避免 auto region 干扰)。
        auto_field_provisioning?: Keyword.get(opts, :auto_field_provisioning, true),
        # 阶段3 step3.2:idle 驱逐——无订阅者且无活跃 field region 连续 idle 超时则自停,
        # 让万级 chunk 内存有界(ChunkDirectory 的 alive? 检查在再访问时重启,纯净 chunk 由
        # WorldGen 重生成、已编辑 chunk 从 DB 重载)。默认禁用(单测的 chunk 不被收走)。
        idle_eviction: resolve_idle_eviction(opts),
        idle_ticks: 0
      }

    schedule_idle_check(state.idle_eviction)
    {:ok, state}
  end

  # idle 驱逐配置:opt `:idle_eviction`([enabled?:, check_ms:, evict_after_ms:] | false)覆盖
  # `:scene_server, :voxel_chunk_idle_eviction` app env。默认禁用(单测 chunk 不被收)。
  defp resolve_idle_eviction(opts) do
    config =
      case Keyword.fetch(opts, :idle_eviction) do
        {:ok, cfg} -> cfg
        :error -> Application.get_env(:scene_server, :voxel_chunk_idle_eviction, [])
      end

    cfg = if is_list(config), do: config, else: []

    if Keyword.get(cfg, :enabled?, false) do
      %{
        check_ms: Keyword.get(cfg, :check_ms, @default_idle_check_ms),
        evict_after_ms: Keyword.get(cfg, :evict_after_ms, @default_idle_evict_after_ms)
      }
    else
      :disabled
    end
  end

  defp schedule_idle_check(:disabled), do: :ok

  defp schedule_idle_check(%{check_ms: check_ms}) do
    Process.send_after(self(), :idle_check, check_ms)
    :ok
  end

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

  defp load_persisted_fence(logical_scene_id, chunk_coord, lease) do
    case ChunkPendingTransactionStore.get_fence(logical_scene_id, chunk_coord) do
      {:ok, persisted} ->
        if lease_matches_persisted?(lease, persisted) do
          %{
            transaction_id: persisted.transaction_id,
            decision_version: persisted.decision_version,
            intents: persisted.intents,
            fenced_at_ms: persisted.fenced_at_ms
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
        owner_epoch: lease.owner_epoch
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

    {:reply, {:ok, lease}, %{next_state | lease: lease}}
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
                next_state = maybe_schedule_field_refresh(next_state, reply.changed?)

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

  def handle_call({:prefab_floating?, intents}, _from, state) when is_list(intents) do
    {:reply, prefab_floating?(state.storage, intents), state}
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
            # retry_on_persist_stale?: true — a batch (seed / prefab) whose persist
            # races a higher DB version self-heals by re-applying on the canonical
            # snapshot, mirroring the single-intent path.
            case apply_normalized_intents(state, intents, true) do
              {:ok, reply, next_state} ->
                next_state = maybe_schedule_field_refresh(next_state, reply.changed?)

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

  def handle_call({:commit_transaction, transaction_id}, _from, state) do
    case commit_transaction_in_state(state, transaction_id) do
      {:ok, reply, next_state, intents} ->
        next_state = maybe_schedule_field_refresh(next_state, reply.changed?)

        emit_transaction_event(next_state, transaction_id, "voxel_chunk_transaction_committed", %{
          chunk_version: next_state.storage.chunk_version,
          snapshot_bytes: byte_size(reply.snapshot_payload),
          changed?: reply.changed?,
          changed_count: reply.changed_count,
          skipped_count: reply.skipped_count,
          intent_count: length(intents),
          persist_result: reply.persist_result
        })

        if reply.changed? do
          push_batch_outcome(state, next_state, intents, :commit_transaction)
        end

        {:reply, {:ok, reply}, next_state}

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

    Enum.each(state.subscribers, fn {subscriber, _opts} ->
      send(subscriber, {:voxel_chunk_invalidate_payload, payload})
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
      |> maybe_schedule_field_refresh(true)

    push_snapshot_fallbacks(next_state, :put_solid_block)

    {:reply, {:ok, storage}, next_state}
  end

  def handle_call(
        {:put_micro_block, macro_index_or_coord, micro_slot, layer_attrs, opts},
        _from,
        state
      ) do
    storage =
      state.storage
      |> Storage.put_micro_block(macro_index_or_coord, micro_slot, layer_attrs, opts)
      |> bump_chunk_version()

    CliObserve.emit("voxel_chunk_micro_block_put", fn ->
      %{
        logical_scene_id: storage.logical_scene_id,
        chunk_coord: storage.chunk_coord,
        chunk_version: storage.chunk_version,
        macro: macro_index_or_coord,
        micro_slot: micro_slot
      }
    end)

    next_state =
      %{state | storage: storage}
      |> maybe_schedule_field_refresh(true)

    push_snapshot_fallbacks(next_state, :put_micro_block)

    {:reply, {:ok, storage}, next_state}
  end

  # 形态轨:放置/覆盖表面元件(零 occupancy)。bump 版本 +(有 lease 则同步落库)+ 重快照,
  # 让 face truth 下行。
  def handle_call({:put_surface_element, attrs}, _from, state) do
    element = SurfaceElement.normalize!(attrs)
    lease = Map.get(attrs, :lease)

    case commit_surface_element_change(
           state,
           lease,
           :put_surface_element,
           &(&1 |> Storage.put_surface_element(element) |> bump_chunk_version())
         ) do
      {:ok, next_state} ->
        CliObserve.emit("voxel_surface_element_put", fn ->
          %{
            logical_scene_id: next_state.storage.logical_scene_id,
            chunk_coord: next_state.storage.chunk_coord,
            chunk_version: next_state.storage.chunk_version,
            macro_index: element.macro_index,
            face: element.face,
            surface_type_id: element.surface_type_id
          }
        end)

        # 表面元件(如火炬)可为本征热/光源 → 触发场 provisioning sweep(Emergence 扫
        # surface_elements,带 heat_output/light_emission 的 torch 起涌现 region)。
        next_state = maybe_schedule_field_refresh(next_state, true)

        {:reply, {:ok, next_state.storage}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # 形态轨:移除表面元件(处理/清氧化)。仅当确有移除才 bump +(有 lease 则落库)+ 重快照。
  def handle_call({:clear_surface_element, macro_index_or_coord, face, opts}, _from, state) do
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    lease = Keyword.get(opts, :lease)
    present? = Storage.surface_element_at(state.storage, macro_index, face) != nil

    if present? do
      case commit_surface_element_change(
             state,
             lease,
             :clear_surface_element,
             &(&1 |> Storage.clear_surface_element(macro_index, face) |> bump_chunk_version())
           ) do
        {:ok, next_state} ->
          CliObserve.emit("voxel_surface_element_cleared", fn ->
            %{
              logical_scene_id: next_state.storage.logical_scene_id,
              chunk_coord: next_state.storage.chunk_coord,
              chunk_version: next_state.storage.chunk_version,
              macro_index: macro_index,
              face: face
            }
          end)

          # 移除火炬等热/光源后,场 provisioning 须重扫(撤掉对应 region)。
          next_state = maybe_schedule_field_refresh(next_state, true)

          {:reply, {:ok, next_state.storage}, next_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:ok, state.storage}, state}
    end
  end

  def handle_call({:surface_element_at, macro_index_or_coord, face}, _from, state) do
    {:reply, Storage.surface_element_at(state.storage, macro_index_or_coord, face), state}
  end

  def handle_call({:write_temperature_attribute, attrs}, _from, state) do
    case build_temperature_attribute_storage(state.storage, attrs) do
      {:ok, next_storage, summary} ->
        next_state = %{state | storage: next_storage}

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
        next_state = %{state | storage: next_storage}

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
        safe_apply_field_effect(acc_state, effect, context)
      end)

    # 局限②(field-commit 重 sweep):若有 field 效果改了**块拓扑/材料**(毁块/坍块/材料相变),
    # 去抖重跑 provisioning sweep——让各 provisioner 按新 truth 重判。这正是跨系统链的闭合点:
    # 燃烧(化学)把承重梁烧成灰 → 重 sweep → 力学 provisioner 探到上方失支撑 → 起 region 坍塌
    # (烧梁→坍塌)。高频的温度/tag 写不改拓扑/材料,**不**触发,避免常驻场每 tick 空 sweep。
    next_state = maybe_schedule_field_refresh(next_state, structural_dirty?(results))

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
    {state, monitor_ref} = put_subscriber(state, subscriber, request_id)
    state = maybe_schedule_field_refresh_for_subscriber(state)
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
        snapshot_sent?: snapshot_sent?,
        subscriber_count: map_size(state.subscribers)
      }
    end)

    if snapshot_sent? do
      push_snapshot_fallback(state, subscriber, request_id, payload, :subscribe)
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
       subscriber_count: map_size(state.subscribers),
       subscribers: Map.keys(state.subscribers),
       field_region_count: map_size(state.field_regions),
       field_source_count: map_size(state.field_region_sources)
     }, state}
  end

  # D-4 后 persist 已同步落库,无在途异步 persist 需要 drain;flush_persistence 即时返回 :ok。
  # 保留该 call 以兼容既有调用方(测试 / voxel_smoke 在读 DB 前调用)。
  def handle_call(:flush_persistence, _from, state) do
    {:reply, :ok, state}
  end

  # Phase 6: create a new FieldRegion under FieldTickSupervisor.
  def handle_call({:create_field_region, attrs}, _from, state) when is_map(attrs) do
    case start_field_region(state, attrs, nil) do
      {:ok, region_id, next_state} -> {:reply, {:ok, region_id}, next_state}
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
            ensure_stable_field_region(state, attrs, region_id)
        end

      source_key ->
        {result, next_state} = ensure_field_source_region_in_state(state, attrs, source_key)
        {:reply, result, next_state}
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
    fan_out_field_region_destroyed_payload(state, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_fields_after_mutation, state) do
    state = %{state | field_refresh_pending?: false}
    {:noreply, refresh_fields_after_mutation(state)}
  end

  def handle_info({:DOWN, monitor_ref, :process, subscriber, reason}, state) do
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
          |> maybe_refresh_expired_field(source_key, destroy_reason)

        {:noreply, new_state}
    end
  end

  # Phase 5.E:scene low-frequency simulation tick。每个 chunk 进程在 init
  # schedule 一次 100ms 计时器；handle 完成后无条件 schedule 下一次（不论本
  # tick 是否实际跑 simulator）。
  def handle_info(:simulation_tick, state) do
    next_state = run_simulation_tick(state)
    schedule_simulation_tick()
    {:noreply, next_state}
  end

  # 阶段3 step3.2:idle 驱逐。无订阅者 + 无活跃 field region 时累计 idle;连续 idle 达阈值即
  # 自停(:normal),让万级 chunk 内存有界。任一活跃(有订阅者或 field region)则清零。已编辑
  # 的 chunk 在编辑路径同步落库,纯净 chunk 由 WorldGen 重生成,故停止无数据丢失;ChunkDirectory
  # 的 alive? 检查在下次访问时重启。
  def handle_info(:idle_check, %{idle_eviction: :disabled} = state), do: {:noreply, state}

  def handle_info(:idle_check, %{idle_eviction: eviction} = state) do
    schedule_idle_check(eviction)

    if chunk_idle?(state) do
      idle_ticks = state.idle_ticks + 1

      if idle_ticks * eviction.check_ms >= eviction.evict_after_ms do
        CliObserve.emit("voxel_chunk_idle_evicted", fn ->
          %{logical_scene_id: state.logical_scene_id, chunk_coord: state.chunk_coord}
        end)

        {:stop, :normal, state}
      else
        {:noreply, %{state | idle_ticks: idle_ticks}}
      end
    else
      {:noreply, %{state | idle_ticks: 0}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A chunk is idle (evictable) when nobody is subscribed and no field region is
  # actively simulating on it. A pending fence (mid-migration) keeps it alive.
  defp chunk_idle?(state) do
    map_size(state.subscribers) == 0 and map_size(state.field_regions) == 0 and
      is_nil(state.pending_fence)
  end

  # ---------------------------------------------------------------------------
  # Phase 5.E:simulation tick dispatch
  # ---------------------------------------------------------------------------

  defp run_simulation_tick(%{simulation_tick: simulation_tick} = state) do
    # 梯队1 step1.1b(TIME-1):每 sim tick 推进 cell_tick/sim_time_ms(cell 逻辑时钟,
    # 与 simulator 是否实际跑无关);每 @cell_time_persist_every tick 单调落库(未持久化 chunk
    # 为 no-op,不增 I/O)。
    state = advance_cell_time(state)

    cond do
      lease_stale?(state.lease) ->
        emit_tick_skipped(state, simulation_tick, :lease_stale)
        state

      not SimulationTick.any_simulator?(simulation_tick) ->
        emit_tick_skipped(state, simulation_tick, :no_simulators)
        state

      DirtyMacroBounds.empty?(state.storage.dirty_bounds) ->
        emit_tick_skipped(state, simulation_tick, :no_dirty)
        state

      true ->
        execute_simulation_tick(state, simulation_tick)
    end
  end

  # 梯队1 step1.1b(TIME-1):cell 逻辑时钟推进 + 周期单调落库。
  @sim_tick_dt_ms 100
  @cell_time_persist_every 50

  defp advance_cell_time(state) do
    next_cell_tick = state.cell_tick + 1
    next_sim_time_ms = state.sim_time_ms + @sim_tick_dt_ms
    next_state = %{state | cell_tick: next_cell_tick, sim_time_ms: next_sim_time_ms}

    if rem(next_cell_tick, @cell_time_persist_every) == 0 do
      persist_cell_time(next_state)
    end

    next_state
  end

  defp persist_cell_time(state) do
    DataService.Voxel.ChunkSnapshotStore.touch_cell_time(
      state.logical_scene_id,
      state.chunk_coord,
      state.cell_tick,
      state.sim_time_ms
    )
  catch
    :exit, _ -> :ok
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

  defp emit_tick_skipped(state, simulation_tick, reason) do
    CliObserve.emit("voxel_simulation_tick_skipped", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        tick_seq: simulation_tick.tick_seq,
        reason: reason
      }
    end)
  end

  defp lease_stale?(nil), do: true

  defp lease_stale?(%{expires_at_ms: expires_at_ms}) when is_integer(expires_at_ms) do
    expires_at_ms <= System.system_time(:millisecond)
  end

  defp lease_stale?(_), do: false

  defp apply_normalized_intent(state, intent) do
    apply_normalized_intent(state, intent, true)
  end

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
      next_storage =
        if changed?, do: Storage.refresh_chunk_object_refs(raw_storage), else: raw_storage

      snapshot_payload = encode_snapshot_payload(next_storage, intent.request_id)
      persist_payload = encode_snapshot_payload(next_storage, 0)

      if changed? do
        case persist_snapshot(
               intent.lease,
               state.chunk_coord,
               next_storage,
               persist_payload,
               Map.get(intent, :command_id)
             ) do
          {:ok, persist_result} ->
            next_state = %{state | storage: next_storage, lease: intent.lease}
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
        next_state = %{state | lease: intent.lease}
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

  # 形态轨 C5.2:表面元件变更的统一提交。`mutate_fn` 接收基线 storage 返回新 storage
  # (须自行 bump 版本)。
  #   * lease == nil:内部/测试路径——只改内存 + 重快照(不落库,行为同旧版直写 API);
  #   * lease != nil:网络放置路径——先同步落库,成功才 commit + 重快照(durable-before-ack);
  #     persist `:stale_chunk_version` 时恢复 DB-canonical storage 后在其上重做一次。
  defp commit_surface_element_change(state, lease, reason, mutate_fn) do
    commit_surface_element_change(state, lease, reason, mutate_fn, true)
  end

  defp commit_surface_element_change(state, nil, reason, mutate_fn, _retry?) do
    next_state = %{state | storage: mutate_fn.(state.storage)}
    push_snapshot_fallbacks(next_state, reason)
    {:ok, next_state}
  end

  defp commit_surface_element_change(state, lease, reason, mutate_fn, retry?) do
    next_storage = mutate_fn.(state.storage)
    persist_payload = encode_snapshot_payload(next_storage, 0)

    case persist_snapshot(lease, state.chunk_coord, next_storage, persist_payload) do
      {:ok, _persist_result} ->
        next_state = %{state | storage: next_storage, lease: lease}
        push_snapshot_fallbacks(next_state, reason)
        {:ok, next_state}

      {:error, :stale_chunk_version} when retry? ->
        case recover_canonical_snapshot_after_persist_stale(
               state,
               lease,
               :surface_element_persist_stale
             ) do
          {:ok, recovered_state} ->
            commit_surface_element_change(recovered_state, lease, reason, mutate_fn, false)

          {:error, recover_reason} ->
            {:error, recover_reason}
        end

      {:error, persist_reason} ->
        {:error, persist_reason}
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

  # 2-arg form (transaction-commit path): NO persist-stale recovery, to leave
  # transaction semantics unchanged.
  defp apply_normalized_intents(state, intents) do
    apply_normalized_intents(state, intents, false)
  end

  # 3-arg form: when `retry_on_persist_stale?`, a `:stale_chunk_version` persist
  # (the DB-canonical chunk advanced past this process's in-memory version — e.g.
  # a fresh ChunkProcess at version 0 vs a high persisted version after edits +
  # restart) loads the canonical snapshot and re-applies the batch on top, ONCE.
  # This makes the BATCH path self-heal exactly like the single-intent path
  # (`apply_normalized_intent`), so the dev terrain seed (a batch write) no longer
  # fails forever with `:stale_chunk_version` after a session/restart desync.
  defp apply_normalized_intents(state, intents, retry_on_persist_stale?) do
    # Phase 4 (D7):collect damage attribution before clearing micros.
    damage_attribution = collect_damage_attribution(state.storage, intents)

    with :ok <- validate_batch_scope(state, intents),
         :ok <- validate_batch_preconditions(state, intents),
         :ok <- validate_apply_batch_occupancy(state, intents),
         {:ok, raw_storage, changed_count, skipped_count} <-
           build_intents_storage(state.storage, intents) do
      # Phase 4 (D6):after every apply rebuild per-cell ObjectCoverRef[] and
      # chunk-level ChunkObjectRef[] from the new MicroLayer truth. The
      # refresh is idempotent and cheap (4096 macro headers, sparse refined
      # cells), and keeps owner provenance摘要 in sync without touching
      # the hot apply path semantics.
      next_storage = Storage.refresh_chunk_object_refs(raw_storage)
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

            next_state = %{state_with_task | storage: next_storage, lease: lease}
            dispatch_damage_async(next_state, damage_attribution)

            {:ok, reply, next_state}

          {:error, :stale_chunk_version} when retry_on_persist_stale? ->
            recover_and_reapply_intents_after_stale(state, intents, lease)

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

        {:ok, reply, %{state | lease: lease}}
      end
    end
  end

  # Batch sibling of the single-intent `maybe_recover_stale_persist`: load the
  # DB-canonical snapshot (adopting its higher chunk_version) and re-apply the
  # whole batch on top, with recovery disabled so it runs at most once.
  defp recover_and_reapply_intents_after_stale(state, intents, lease) do
    case recover_canonical_snapshot_after_persist_stale(state, lease, :batch_persist_stale) do
      {:ok, recovered_state} ->
        apply_normalized_intents(recovered_state, intents, false)

      {:error, reason} ->
        {:error, reason}
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
                fenced_at_ms: fenced_at_ms
              }

              {:ok, fence_summary(fence), %{state | pending_fence: fence}}

            {:error, reason} ->
              {:error, persist_fence_reason(reason)}
          end
        end
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
        case apply_normalized_intents(state, intents) do
          {:ok, reply, next_state_after_apply} ->
            delete_persisted_fence(state, transaction_id, :commit)
            {:ok, reply, %{next_state_after_apply | pending_fence: nil}, intents}

          {:error, reason} ->
            {:error, reason}
        end

      %{transaction_id: holder} ->
        {:error, {:chunk_fence_owned_by_another_transaction, holder}}

      nil ->
        {:error, :transaction_not_prepared}
    end
  end

  defp abort_transaction_in_state(state, transaction_id) do
    case state.pending_fence do
      %{transaction_id: ^transaction_id} ->
        delete_persisted_fence(state, transaction_id, :abort)
        {true, %{state | pending_fence: nil}}

      _other ->
        {false, state}
    end
  end

  # 删除持久化 fence 行。commit/abort 后调用。瞬时 DB 故障会让 delete 失败:
  # 残留行只有在「同 lease 下进程重启 + 重启前未清理」这一窄窗口才会被 init 当活
  # fence 重载并阻塞新 prepare(lease 轮换时 load 的 orphan 路径会自愈)。故先做有界
  # 重试吃掉瞬断,耗尽仍失败才记 loud observe 并放行(保留在内存清 fence 的活性——
  # 当前进程不被一行残留卡死)。delete_fence 现在不再 raise(见 store 层 rescue),
  # 因此本函数返回 :ok 不会漏接异常。
  @fence_delete_max_attempts 3

  defp delete_persisted_fence(state, transaction_id, reason) do
    delete_persisted_fence(state, transaction_id, reason, @fence_delete_max_attempts)
  end

  defp delete_persisted_fence(state, transaction_id, reason, attempts_left) do
    case ChunkPendingTransactionStore.delete_fence(state.logical_scene_id, state.chunk_coord) do
      {:ok, _} ->
        :ok

      {:error, _error_reason} when attempts_left > 1 ->
        Process.sleep(25)
        delete_persisted_fence(state, transaction_id, reason, attempts_left - 1)

      {:error, error_reason} ->
        # 重试耗尽:持久化行可能残留。emit observe 让运维能发现分叉;在内存里仍清
        # fence 以保活性(残留行在 lease 轮换 / 同 lease 重启的 orphan 检查中自愈)。
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
        # All-`:put_solid_block` batch (terrain seed / large WorldGen / solid
        # prefab) → one O(macro_count + N) `Storage.put_solid_blocks` instead of N
        # individual O(macro_count + N) `put_solid_block` calls (each with two full
        # `normalize!`). This is the cold-seed / bulk-build fix.
        case detect_solid_block_batch(storage, intents, next_version) do
          {:solid_batch, _entries, 0, skipped_count} ->
            {:ok, storage, 0, skipped_count}

          {:solid_batch, entries, changed_count, skipped_count} ->
            next_storage = storage |> Storage.put_solid_blocks(entries) |> bump_chunk_version()
            {:ok, next_storage, changed_count, skipped_count}

          :mixed ->
            build_intents_storage_per_cell(storage, intents, next_version)
        end
    end
  rescue
    _exception in ArgumentError -> {:error, :invalid_voxel_intent}
  end

  defp build_intents_storage_per_cell(storage, intents, next_version) do
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

  # All-`:put_solid_block` detector. Returns `{:solid_batch, entries, changed,
  # skipped}` (entries = `{macro, block, header_opts}` for the cells that actually
  # change — already-matching cells are skipped, matching the per-cell path) or
  # `:mixed` when any intent is not a plain solid-block put.
  defp detect_solid_block_batch(_storage, [], _next_version), do: :mixed

  defp detect_solid_block_batch(storage, intents, next_version) do
    if Enum.all?(intents, fn intent -> intent.operation == :put_solid_block end) do
      {entries_rev, changed, skipped} =
        Enum.reduce(intents, {[], 0, 0}, fn intent, {acc, changed, skipped} ->
          block = intent.block

          if solid_block_matches?(storage, intent.macro, block) do
            {acc, changed, skipped + 1}
          else
            header_opts =
              intent.opts
              |> Keyword.put_new(:cell_version, next_version)
              |> Keyword.put_new_lazy(:cell_hash, fn -> Hash.digest32(inspect(block)) end)

            {[{intent.macro, block, header_opts} | acc], changed + 1, skipped}
          end
        end)

      {:solid_batch, Enum.reverse(entries_rev), changed, skipped}
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

  defp macro_header_at_fast(%Storage{macro_headers: headers}, macro_index)
       when is_integer(macro_index) do
    Enum.at(headers, macro_index)
  end

  defp macro_header_at_fast(storage, macro_index) do
    Storage.macro_header_at(storage, macro_index)
  end

  defp refined_cell_at_fast(%Storage{refined_cells: refined_cells} = storage, macro_index) do
    refined_mode = MacroCellHeader.cell_mode_refined()

    case macro_header_at_fast(storage, macro_index) do
      %{mode: ^refined_mode, payload_index: payload_index} ->
        Enum.at(refined_cells, payload_index)

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
          baseline_raw = celsius_to_fixed32_raw(20.0)

          # R5d:clip target 到温度边界(注热饱和在上界,不越界崩溃);delta 也 clip 保 put 不 raise。
          target_raw =
            clamp_raw(
              celsius_to_fixed32_raw(target_temperature),
              @temperature_min_raw,
              @temperature_max_raw
            )

          attribute_delta_raw =
            clamp_raw(target_raw - baseline_raw, @temperature_min_raw, @temperature_max_raw)

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

  # R5d 防御纵深:单个效果应用崩溃只 reject 该效果(emit observe),不崩整个 ChunkProcess。
  defp safe_apply_field_effect(state, effect, context) do
    apply_field_effect(state, effect, context)
  rescue
    exception ->
      result = %{
        status: :rejected,
        action: :unknown,
        reason: {:effect_apply_crashed, Exception.message(exception)}
      }

      emit_field_effect_rejected(state, result, context)
      {result, state}
  end

  # field 效果是否改了 provisioning 相关的块拓扑/材料(需重 sweep)。毁块/坍块改拓扑;材料相变
  # 改材料身份(可变结构/导电/光热)。health 未归零的减血、温度写、tag 写都不改,排除以免常驻
  # 场(燃烧/电路每 tick 注热)白触发 sweep。
  defp structural_dirty?(results) when is_list(results) do
    Enum.any?(results, &structural_relevant_change?/1)
  end

  defp structural_relevant_change?(%{status: :applied, action: :collapse_block}), do: true

  defp structural_relevant_change?(%{status: :applied, action: :damage_block, destroyed?: true}),
    do: true

  defp structural_relevant_change?(%{status: :applied, action: :transform_material}), do: true
  defp structural_relevant_change?(_result), do: false

  defp apply_field_effect(state, effect, context) do
    case normalize_field_effect(effect) do
      {:ok, :write_voxel_attribute, attrs} ->
        apply_write_voxel_attribute_effect(state, attrs, context)

      # 功能完善 · 反应层 R2:涌现反应的材料转变(冰→水…),经 SystemActor 锁存后落 truth。
      {:ok, :transform_material, attrs} ->
        apply_transform_material_effect(state, attrs, context)

      # 功能完善 · 反应层 R5b:燃烧 tag 增删(:burning)。
      {:ok, :set_tag, attrs} ->
        apply_set_tag_effect(state, attrs, context)

      # 功能完善 · 反应层 R8:放电击穿对方块造成伤害(减 health,归零毁块)。
      {:ok, :damage_block, attrs} ->
        apply_damage_block_effect(state, attrs, context)

      # 力学应力:失支撑实心结构坍塌——直接清掉该 cell(复用归零毁块 → ChunkDelta/debris 路径)。
      {:ok, :collapse_block, attrs} ->
        apply_collapse_block_effect(state, attrs, context)

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
  defp normalize_field_effect_action(:set_tag), do: :set_tag
  defp normalize_field_effect_action("set_tag"), do: :set_tag
  defp normalize_field_effect_action(:damage_block), do: :damage_block
  defp normalize_field_effect_action("damage_block"), do: :damage_block
  defp normalize_field_effect_action(:collapse_block), do: :collapse_block
  defp normalize_field_effect_action("collapse_block"), do: :collapse_block
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

      # 功能完善 · 反应层 R5b:任意已注册动态属性的 delta 累进写(如 burn_progress)。
      attr_name when is_binary(attr_name) and attr_name != "" ->
        apply_dynamic_attribute_delta_effect(state, attr_name, attrs, context)

      unsupported ->
        result = %{
          status: :rejected,
          action: :write_voxel_attribute,
          attribute: unsupported || :unknown,
          reason: :unsupported_field_effect_attribute
        }

        emit_field_effect_rejected(state, result, context)
        {result, state}
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

  # 功能完善 · 反应层 R2:把 `{:transform_material, %{macro_index, from_material_id, to_material_id}}`
  # 落 voxel truth。**from 校验**:现材料须 == from_material_id,否则显式 reject(防过期/竞态转变,不静默)。
  # 保留 cell 动态 attribute_set(温度等随相变物理延续),material_default 自动取新材料 catalog。
  defp apply_transform_material_effect(state, attrs, context) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_transform_macro(attrs),
         {:ok, from_id, to_id} <- normalize_transform_materials(attrs),
         {:ok, block} <- fetch_transformable_block(state.storage, macro_index, from_id) do
      next_version = state.storage.chunk_version + 1

      opts = [
        cell_version: next_version,
        cell_hash: Hash.digest32(inspect({:material_transform, macro_index, to_id, next_version}))
      ]

      next_storage =
        state.storage
        |> Storage.put_solid_block(macro_index, %{block | material_id: to_id}, opts)
        |> bump_chunk_version()

      next_state = %{state | storage: next_storage}
      push_snapshot_fallbacks(next_state, :reaction_material_transform)

      result = %{
        status: :applied,
        action: :transform_material,
        macro_index: macro_index,
        from_material_id: from_id,
        to_material_id: to_id,
        rule_id: Map.get(attrs, :rule_id),
        chunk_version: next_storage.chunk_version
      }

      emit_field_effect_applied(next_state, result, context)
      {result, next_state}
    else
      {:error, reason} ->
        result = %{status: :rejected, action: :transform_material, reason: reason}
        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp normalize_transform_macro(attrs) do
    case fetch_optional(attrs, [:macro_index, :macro, :local_macro]) do
      nil -> {:error, :missing_macro_index}
      value -> {:ok, Types.macro_index_or_coord!(value)}
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_macro_index}
  end

  defp normalize_transform_materials(attrs) do
    from_id = fetch_optional(attrs, [:from_material_id, :from])
    to_id = fetch_optional(attrs, [:to_material_id, :to])

    if is_integer(from_id) and is_integer(to_id) and
         not is_nil(MaterialCatalog.material_name(to_id)) do
      {:ok, from_id, to_id}
    else
      {:error, :invalid_transform_materials}
    end
  end

  defp fetch_transformable_block(storage, macro_index, from_id) do
    case Storage.normal_block_at(storage, macro_index) do
      %NormalBlockData{material_id: ^from_id} = block -> {:ok, block}
      %NormalBlockData{material_id: other} -> {:error, {:from_material_mismatch, other}}
      _other -> {:error, :not_a_normal_block}
    end
  end

  # 功能完善 · 反应层 R5b:动态属性 delta 累进写(read-modify-write,如 burn_progress 每 tick +Δ)。
  # add_delta 属性的 stored 值即"对 baseline 的偏移";写入须读旧 + Δ 后 clip 到 catalog [min,max] 重写。
  defp apply_dynamic_attribute_delta_effect(state, attr_name, attrs, context) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_transform_macro(attrs),
         {:ok, delta} <- fetch_attribute_delta(attrs),
         {:ok, min_raw, max_raw} <- dynamic_attribute_bounds(attr_name),
         true <- solid_cell?(state.storage, macro_index) or {:error, :attribute_target_not_solid} do
      previous_raw = Storage.effective_attribute_at(state.storage, macro_index, attr_name)
      new_raw = clamp_raw(previous_raw + round(delta * @fixed32_scale), min_raw, max_raw)
      next_version = state.storage.chunk_version + 1

      opts = [
        cell_version: next_version,
        cell_hash:
          Hash.digest32(inspect({:attr_delta, attr_name, macro_index, new_raw, next_version}))
      ]

      next_storage =
        state.storage
        |> Storage.put_attribute_for_cell(macro_index, attr_name, new_raw, opts)
        |> bump_chunk_version()

      next_state = %{state | storage: next_storage}
      push_snapshot_fallbacks(next_state, :reaction_attribute_write)

      result = %{
        status: :applied,
        action: :write_voxel_attribute,
        attribute: attr_name,
        delta: delta,
        value_raw: new_raw,
        chunk_version: next_storage.chunk_version
      }

      emit_field_effect_applied(next_state, result, context)
      {result, next_state}
    else
      {:error, reason} -> reject_attribute_write(state, attr_name, reason, context)
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] ->
      reject_attribute_write(state, attr_name, :invalid_dynamic_attribute_write, context)
  end

  defp fetch_attribute_delta(attrs) do
    case fetch_optional(attrs, [:delta]) do
      n when is_number(n) -> {:ok, n}
      _other -> {:error, :missing_attribute_delta}
    end
  end

  defp dynamic_attribute_bounds(attr_name) do
    case AttributeCatalog.lookup_by_name(attr_name) do
      {:ok, _id, defn} -> {:ok, defn.min_value, defn.max_value}
      _other -> {:error, :unknown_dynamic_attribute}
    end
  end

  defp clamp_raw(value, lo, hi), do: value |> max(lo) |> min(hi)

  defp reject_attribute_write(state, attr_name, reason, context) do
    result = %{
      status: :rejected,
      action: :write_voxel_attribute,
      attribute: attr_name,
      reason: reason
    }

    emit_field_effect_rejected(state, result, context)
    {result, state}
  end

  # 功能完善 · 反应层 R5b:set_tag 加/减 per-cell 动态 tag(:burning 等)。tag 名 → id(TagCatalog)
  # → 合并现有 tag_set → intern → 换 tag_set_ref。无变化幂等(不 bump 版本)。
  defp apply_set_tag_effect(state, attrs, context) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_transform_macro(attrs),
         %NormalBlockData{} = block <- normal_block_for_tag(state.storage, macro_index),
         {:ok, add_ids} <- resolve_tag_ids(Map.get(attrs, :add, [])),
         {:ok, remove_ids} <- resolve_tag_ids(Map.get(attrs, :remove, [])) do
      current_ids = current_tag_ids(state.storage, block.tag_set_ref)
      new_ids = ((current_ids ++ add_ids) -- remove_ids) |> Enum.uniq() |> Enum.sort()

      if new_ids == Enum.sort(current_ids) do
        result = %{status: :applied, action: :set_tag, macro_index: macro_index, changed?: false}
        emit_field_effect_applied(state, result, context)
        {result, state}
      else
        # 空集 = 无 tag(canonical ref 0),不 intern 空集(intern 空集会 raise)。
        {interned_storage, ref} =
          case new_ids do
            [] -> {state.storage, 0}
            _non_empty -> Storage.intern_tag_set(state.storage, %TagSet{tag_ids: new_ids})
          end

        next_version = interned_storage.chunk_version + 1

        opts = [
          cell_version: next_version,
          cell_hash: Hash.digest32(inspect({:set_tag, macro_index, new_ids, next_version}))
        ]

        next_storage =
          interned_storage
          |> Storage.put_solid_block(macro_index, %{block | tag_set_ref: ref}, opts)
          |> bump_chunk_version()

        next_state = %{state | storage: next_storage}
        push_snapshot_fallbacks(next_state, :reaction_set_tag)

        result = %{
          status: :applied,
          action: :set_tag,
          macro_index: macro_index,
          add: Map.get(attrs, :add, []),
          remove: Map.get(attrs, :remove, []),
          changed?: true,
          chunk_version: next_storage.chunk_version
        }

        emit_field_effect_applied(next_state, result, context)
        {result, next_state}
      end
    else
      {:error, reason} -> reject_set_tag(state, reason, context)
      _other -> reject_set_tag(state, :set_tag_target_invalid, context)
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] ->
      reject_set_tag(state, :invalid_set_tag, context)
  end

  defp normal_block_for_tag(storage, macro_index) do
    case Storage.normal_block_at(storage, macro_index) do
      %NormalBlockData{} = block -> block
      _other -> {:error, :set_tag_target_not_solid}
    end
  end

  defp resolve_tag_ids(names) when is_list(names) do
    result =
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
        case TagCatalog.lookup_by_name(to_string(name)) do
          {:ok, id, _defn} -> {:cont, {:ok, [id | acc]}}
          _other -> {:halt, {:error, {:unknown_tag, name}}}
        end
      end)

    case result do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp resolve_tag_ids(_other), do: {:ok, []}

  defp current_tag_ids(_storage, ref) when ref in [0, nil], do: []

  defp current_tag_ids(storage, ref) when is_integer(ref) and ref > 0 do
    case Enum.at(storage.tag_sets, ref - 1) do
      %TagSet{tag_ids: ids} -> ids
      _other -> []
    end
  end

  defp current_tag_ids(_storage, _ref), do: []

  defp reject_set_tag(state, reason, context) do
    result = %{status: :rejected, action: :set_tag, reason: reason}
    emit_field_effect_rejected(state, result, context)
    {result, state}
  end

  # 功能完善 · 反应层 R8:放电击穿伤害(减 health,归零毁块)。**权威重校**:目标须实心 macro 块且 health>0
  # (非实心/已毁/无耐久 → 显式 reject,不静默降级);amount 由放电 kernel 沿击穿路径逐 tick 给(连续累损,
  # SystemActor always-commit)。new = health - amount;new<=0 → clear_macro_cell 毁块(destroyed?: true),
  # 否则写回降 health。
  defp apply_damage_block_effect(state, attrs, context) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_transform_macro(attrs),
         {:ok, amount} <- fetch_damage_amount(attrs),
         {:ok, block} <- fetch_damageable_block(state.storage, macro_index) do
      new_health = block.health - amount
      next_version = state.storage.chunk_version + 1
      destroyed? = new_health <= 0

      next_storage =
        damage_block_storage(state.storage, macro_index, block, new_health, next_version)

      next_state = %{state | storage: next_storage}
      push_snapshot_fallbacks(next_state, :reaction_damage_block)

      result = %{
        status: :applied,
        action: :damage_block,
        macro_index: macro_index,
        amount: amount,
        health: max(new_health, 0),
        destroyed?: destroyed?,
        source: Map.get(attrs, :source),
        chunk_version: next_storage.chunk_version
      }

      emit_field_effect_applied(next_state, result, context)
      {result, next_state}
    else
      {:error, reason} ->
        result = %{status: :rejected, action: :damage_block, reason: reason}
        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  # 力学应力:失支撑结构坍塌——无视 health 直接清掉该实心 cell(复用 damage_block 的归零
  # 毁块 storage 路径 → bump version → push_snapshot_fallbacks → ChunkDelta;客户端把 cleared
  # cell 渲成 debris)。仅对实心 cell 生效;非实心(已空/流体)→ reject(no-op,幂等)。
  defp apply_collapse_block_effect(state, attrs, context) do
    attrs = attrs_map(attrs)

    with {:ok, macro_index} <- normalize_transform_macro(attrs),
         %NormalBlockData{} = block <- Storage.normal_block_at(state.storage, macro_index) do
      next_version = state.storage.chunk_version + 1

      next_storage =
        damage_block_storage(state.storage, macro_index, block, 0, next_version)

      next_state = %{state | storage: next_storage}
      push_snapshot_fallbacks(next_state, :structural_collapse_block)

      result = %{
        status: :applied,
        action: :collapse_block,
        macro_index: macro_index,
        destroyed?: true,
        source: Map.get(attrs, :source, :structural_collapse),
        chunk_version: next_storage.chunk_version
      }

      emit_field_effect_applied(next_state, result, context)
      {result, next_state}
    else
      {:error, reason} ->
        result = %{status: :rejected, action: :collapse_block, reason: reason}
        emit_field_effect_rejected(state, result, context)
        {result, state}

      _other ->
        result = %{status: :rejected, action: :collapse_block, reason: :collapse_target_not_solid}
        emit_field_effect_rejected(state, result, context)
        {result, state}
    end
  end

  defp damage_block_storage(storage, macro_index, _block, new_health, next_version)
       when new_health <= 0 do
    opts = [
      cell_version: next_version,
      cell_hash: Hash.digest32(inspect({:damage_block_destroy, macro_index, next_version}))
    ]

    storage
    |> Storage.clear_macro_cell(macro_index, opts)
    |> bump_chunk_version()
  end

  defp damage_block_storage(storage, macro_index, block, new_health, next_version) do
    opts = [
      cell_version: next_version,
      cell_hash: Hash.digest32(inspect({:damage_block, macro_index, new_health, next_version}))
    ]

    storage
    |> Storage.put_solid_block(macro_index, %{block | health: new_health}, opts)
    |> bump_chunk_version()
  end

  defp fetch_damage_amount(attrs) do
    case fetch_optional(attrs, [:amount, :damage]) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :invalid_damage_amount}
    end
  end

  defp fetch_damageable_block(storage, macro_index) do
    case Storage.normal_block_at(storage, macro_index) do
      %NormalBlockData{health: health} = block when health > 0 -> {:ok, block}
      %NormalBlockData{} -> {:error, :damage_target_no_health}
      _other -> {:error, :damage_target_not_solid}
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

  defp normalize_field_effect_attribute(:temperature), do: :temperature
  defp normalize_field_effect_attribute("temperature"), do: :temperature
  defp normalize_field_effect_attribute(attribute), do: attribute

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
    storage.macro_headers
    |> Enum.with_index()
    |> Enum.flat_map(fn {header, macro_idx} ->
      if header.mode == MacroCellHeader.cell_mode_refined() do
        cell = Enum.at(storage.refined_cells, header.payload_index)

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

  defp persist_snapshot(lease, chunk_coord, storage, payload, command_id \\ nil)

  defp persist_snapshot(nil, _chunk_coord, _storage, _payload, _command_id) do
    {:error, :missing_lease}
  end

  defp persist_snapshot(lease, chunk_coord, storage, payload, command_id) do
    lease
    |> build_snapshot_attrs(chunk_coord, storage, payload, command_id)
    |> DataService.Voxel.ChunkSnapshotStore.put_snapshot()
  end

  defp enqueue_snapshot_persist(_state, nil, _chunk_coord, _storage, _payload) do
    {:error, :missing_lease}
  end

  # D-4(AUTH-2 / ANTI-10):durable_authoritative 命令在向客户端确认成功前必须可恢复提交。
  # 批量 / 事务 commit 落库改为**同步**(与单块编辑路径一致):仅在 `ChunkSnapshotStore.put_snapshot`
  # 成功后才返回真实 persist_result,由调用方更新内存 storage(见 apply_normalized_intents 的
  # `{:ok, ...}` 分支);落库失败返回 `{:error, reason}`,内存 storage 不前进——既满足 durable-before-ack,
  # 又消除旧异步路径"内存已改 / DB 未落"的静默背离。
  #
  # 历史异步 persist 子系统(:async_snapshot_persist_finished / async_persists / persist_waiters /
  # maybe_reply_persist_waiters)已随本次重构移除;`flush_persistence` 因 persist 已同步而即时返回
  # `:ok`,所有现有调用方语义不变。
  defp enqueue_snapshot_persist(state, lease, chunk_coord, storage, payload) do
    with :ok <- validate_snapshot_write_token(lease, chunk_coord) do
      ref = System.unique_integer([:positive, :monotonic])
      payload = payload || encode_snapshot_payload(storage, 0)
      snapshot_bytes = byte_size(payload)
      attrs = build_snapshot_attrs(lease, chunk_coord, storage, payload)

      case safe_persist_snapshot_with_retry(attrs, 3) do
        {:ok, persist_result} ->
          CliObserve.emit("voxel_chunk_persist_committed", fn ->
            %{
              logical_scene_id: state.logical_scene_id,
              chunk_coord: state.chunk_coord,
              chunk_version: storage.chunk_version,
              persist_ref: ref,
              persist_result: persist_result,
              snapshot_bytes: snapshot_bytes
            }
          end)

          {:ok, persist_result, ref, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Loads the persisted chunk snapshot into a Storage on process startup, falling
  # back to an empty chunk when there is no persisted row or DataService is
  # unavailable (e.g. `--no-start` tests). Mirrors the decode used by the
  # persist-stale recovery path so a freshly-(re)started chunk is at the
  # DB-canonical version + content.
  defp load_persisted_storage_or_generate(logical_scene_id, chunk_coord, worldgen) do
    case DataService.Voxel.ChunkSnapshotStore.get_snapshot(logical_scene_id, chunk_coord) do
      {:ok, %{data: data}} when is_binary(data) ->
        case decode_prewarm_payload(data) do
          {:ok, storage} -> storage
          _ -> fresh_chunk_storage(logical_scene_id, chunk_coord, worldgen)
        end

      _ ->
        fresh_chunk_storage(logical_scene_id, chunk_coord, worldgen)
    end
  catch
    :exit, _ -> fresh_chunk_storage(logical_scene_id, chunk_coord, worldgen)
  end

  # A never-persisted chunk: procedurally generate its baseline terrain when
  # WorldGen is enabled (阶段3,version 0,not persisted — regenerates identically),
  # otherwise an empty chunk.
  defp fresh_chunk_storage(logical_scene_id, chunk_coord, {:worldgen, seed}) do
    WorldGen.generate_chunk_storage(logical_scene_id, chunk_coord, seed: seed)
  rescue
    _ -> Storage.empty(logical_scene_id, chunk_coord)
  end

  defp fresh_chunk_storage(logical_scene_id, chunk_coord, :disabled) do
    Storage.empty(logical_scene_id, chunk_coord)
  end

  # WorldGen config: opt `:worldgen` (`[enabled?:, seed:]` | false) overrides the
  # `:scene_server, :voxel_worldgen` app env. Default DISABLED so unit tests that
  # start a ChunkProcess keep getting an empty chunk; production config opts in.
  defp resolve_worldgen(opts) do
    config =
      case Keyword.fetch(opts, :worldgen) do
        {:ok, cfg} -> cfg
        :error -> Application.get_env(:scene_server, :voxel_worldgen, [])
      end

    cfg = if is_list(config), do: config, else: []

    if Keyword.get(cfg, :enabled?, false) do
      {:worldgen, Keyword.get(cfg, :seed, WorldGen.default_seed())}
    else
      :disabled
    end
  end

  # 梯队1 step1.1b(TIME-1):从持久化 chunk 行恢复 cell_tick/sim_time_ms。cell_tick 加
  # restart gap 保证跨重启严格单调(逻辑时钟可跳变不可回退)。Repo 不可用时回 {0,0}。
  @cell_tick_restart_gap 1000

  defp restore_cell_time(logical_scene_id, chunk_coord) do
    case DataService.Voxel.ChunkSnapshotStore.get_snapshot(logical_scene_id, chunk_coord) do
      {:ok, snapshot} ->
        cell_tick = Map.get(snapshot, :cell_tick, 0)
        sim_time_ms = Map.get(snapshot, :sim_time_ms, 0)
        restored = if cell_tick > 0, do: cell_tick + @cell_tick_restart_gap, else: 0
        {restored, sim_time_ms}

      _ ->
        {0, 0}
    end
  catch
    :exit, _ -> {0, 0}
  end

  @write_token_validate_max_attempts 3

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

    validate_snapshot_write_token_with_retry(attrs, @write_token_validate_max_attempts)
  end

  # 仅对瞬时基础设施故障(DB 连接抖动 / 池 checkout 超时 → :write_token_store_unavailable)
  # 做有界重试。lease_id_mismatch / owner_epoch_mismatch / unknown_region_token /
  # chunk_out_of_bounds / lease_expired 等都是权威 fencing 裁决,绝不重试/掩盖。
  defp validate_snapshot_write_token_with_retry(attrs, attempts_left) do
    case safe_validate_write_token(attrs) do
      {:error, :write_token_store_unavailable} when attempts_left > 1 ->
        Process.sleep(25)
        validate_snapshot_write_token_with_retry(attrs, attempts_left - 1)

      other ->
        other
    end
  end

  defp safe_validate_write_token(attrs) do
    DataService.Voxel.WriteTokenStore.validate_write(attrs)
  rescue
    # DBConnection.ConnectionError 等连接故障是 raise(不是 exit),旧 `catch :exit`
    # 漏接 → 异常会冒泡崩掉持久化路径。统一收敛成可重试的瞬时不可用。
    _exception -> {:error, :write_token_store_unavailable}
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

  defp build_snapshot_attrs(lease, chunk_coord, storage, payload, command_id \\ nil) do
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

    # AUTH-4(step1.5b-1):仅单方块编辑路径携带 command_id;事务逐 chunk 写传 nil(prefab 幂等
    # 在 gate 边界单独处理,见 step1.5b-2),内部写也为 nil。ChunkSnapshotStore.do_put 仅在
    # command_id 非 nil 时同事务 record_once。
    if is_binary(command_id) do
      Map.put(attrs, :command_id, command_id)
    else
      attrs
    end
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

  defp put_subscriber(state, subscriber, request_id) do
    state =
      case Map.fetch(state.subscribers, subscriber) do
        {:ok, %{monitor_ref: monitor_ref}} ->
          Process.demonitor(monitor_ref, [:flush])

          %{state | subscriber_monitors: Map.delete(state.subscriber_monitors, monitor_ref)}

        :error ->
          state
      end

    monitor_ref = Process.monitor(subscriber)
    subscriber_state = %{monitor_ref: monitor_ref, request_id: request_id}

    state = %{
      state
      | subscribers: Map.put(state.subscribers, subscriber, subscriber_state),
        subscriber_monitors: Map.put(state.subscriber_monitors, monitor_ref, subscriber)
    }

    {state, monitor_ref}
  end

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

    # 梯队3 step3.9(AUTH-9/10):commit(durable persist 已在 commit 阶段完成)后、fanout 前,
    # 把 committed delta 追加 durable outbox,供可靠重投 + visibility_watermark。
    append_replication_outbox(state, base_version, delta_payload)

    Enum.each(state.subscribers, fn {subscriber, %{request_id: request_id}} ->
      send(subscriber, {:voxel_chunk_delta_payload, delta_payload})

      CliObserve.emit("voxel_chunk_delta_push", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          base_chunk_version: base_version,
          new_chunk_version: state.storage.chunk_version,
          op_count: length(ops),
          subscriber: subscriber,
          request_id: request_id,
          reason: reason,
          byte_size: byte_size(delta_payload)
        }
      end)
    end)
  end

  # 梯队3 step3.9:committed delta → durable outbox。失败显式 emit(不静默),但不崩热路径
  # (chunk truth 已 durable persist;outbox 是次级重投日志,失败仅降级重投能力,不损正确性)。
  defp append_replication_outbox(state, base_version, delta_payload) do
    DataService.Voxel.Outbox.append(%{
      logical_scene_id: state.logical_scene_id,
      chunk_coord: state.chunk_coord,
      base_chunk_version: base_version,
      new_chunk_version: state.storage.chunk_version,
      payload: delta_payload
    })

    :ok
  rescue
    error ->
      CliObserve.emit("voxel_outbox_append_failed", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          new_chunk_version: state.storage.chunk_version,
          error: Exception.message(error)
        }
      end)

      :ok
  end

  defp push_snapshot_fallbacks(state, reason) do
    payload = encode_snapshot_payload(state.storage, 0)

    Enum.each(state.subscribers, fn {subscriber, %{request_id: request_id}} ->
      push_snapshot_fallback(state, subscriber, request_id, payload, reason)
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

  defp maybe_schedule_field_refresh(%{auto_field_provisioning?: false} = state, _changed?),
    do: state

  defp maybe_schedule_field_refresh(state, true) do
    if Map.get(state, :field_refresh_pending?, false) do
      state
    else
      Process.send_after(
        self(),
        :refresh_fields_after_mutation,
        @field_refresh_debounce_ms
      )

      %{state | field_refresh_pending?: true}
    end
  end

  defp maybe_schedule_field_refresh(state, _changed?), do: state

  # 订阅时机:chunk 可能加载了内容却从未 mutate(没触发过 sweep)。若有任一 provisioner
  # 当前 active 且尚未起 source,补一次 sweep,让新订阅者看到本该存在的场 region。
  defp maybe_schedule_field_refresh_for_subscriber(%{auto_field_provisioning?: false} = state),
    do: state

  defp maybe_schedule_field_refresh_for_subscriber(%{storage: %Storage{}} = state) do
    context = build_field_context(state)

    needs_refresh? =
      Enum.any?(@field_provisioners, fn provisioner ->
        not Map.has_key?(state.field_region_sources, provisioner.source_key(context)) and
          FieldProvisioner.active?(provisioner, context)
      end)

    if needs_refresh?, do: maybe_schedule_field_refresh(state, true), else: state
  end

  defp maybe_schedule_field_refresh_for_subscriber(state), do: state

  defp build_field_context(%{storage: %Storage{} = storage} = state) do
    %{
      storage: storage,
      projection: ParticipantProjection.build(storage),
      chunk_coord: state.chunk_coord,
      logical_scene_id: state.logical_scene_id
    }
  end

  # 世界内容驱动场 provisioning 的统一 sweep:一次构建只读 context,遍历每个
  # provisioner → active 则 ensure 对应 region,inactive 则 release。各 provisioner
  # 独立 rescue(单个失败不波及其他);context 构建失败整体兜底。
  defp refresh_fields_after_mutation(%{storage: %Storage{}} = state) do
    context = build_field_context(state)

    Enum.reduce(@field_provisioners, state, fn provisioner, acc ->
      apply_field_provisioner(acc, provisioner, context)
    end)
  rescue
    error ->
      CliObserve.emit("voxel_field_refresh_failed", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          reason: Exception.message(error)
        }
      end)

      state
  end

  defp refresh_fields_after_mutation(state), do: state

  defp apply_field_provisioner(state, provisioner, context) do
    source_key = provisioner.source_key(context)

    case provisioner.detect(context) do
      {:active, region_attrs, detail} ->
        attrs = Map.put(region_attrs, :source_key, source_key)

        case ensure_field_source_region_in_state(state, attrs, source_key) do
          {{:ok, result}, next_state} ->
            emit_field_provision(
              next_state,
              provisioner.telemetry_event(),
              :active,
              Map.merge(detail, %{
                source_key: source_key,
                region_id: result.region_id,
                field_region_created: result.created?,
                source_points_action: result.source_points_action
              })
            )

            next_state

          {{:error, reason}, next_state} ->
            emit_field_provision(
              next_state,
              provisioner.telemetry_event(),
              :failed,
              Map.merge(detail, %{source_key: source_key, reason: inspect(reason)})
            )

            next_state
        end

      {:inactive, reason, detail} ->
        {_result, next_state} = release_field_region_source_entry(state, source_key, :explicit)

        emit_field_provision(
          next_state,
          provisioner.telemetry_event(),
          :released,
          Map.merge(detail, %{reason: reason, source_key: source_key})
        )

        next_state
    end
  rescue
    error ->
      emit_field_provision(state, provisioner.telemetry_event(), :failed, %{
        reason: Exception.message(error),
        source_key: safe_provisioner_source_key(provisioner, context)
      })

      state
  end

  defp safe_provisioner_source_key(provisioner, context) do
    provisioner.source_key(context)
  rescue
    _ -> nil
  end

  # worker 到期/崩溃后:若该 source_key 属于某仍 active 的 provisioner,补一次 sweep
  # 重起(同原 auto_circuit 到期重刷,泛化到任意 provisioner)。
  defp maybe_refresh_expired_field(%{auto_field_provisioning?: false} = state, _sk, _r), do: state

  defp maybe_refresh_expired_field(%{storage: %Storage{}} = state, source_key, :expired) do
    context = build_field_context(state)

    expired_active? =
      Enum.any?(@field_provisioners, fn provisioner ->
        provisioner.source_key(context) == source_key and
          FieldProvisioner.active?(provisioner, context)
      end)

    if expired_active?, do: maybe_schedule_field_refresh(state, true), else: state
  end

  defp maybe_refresh_expired_field(state, _source_key, _destroy_reason), do: state

  defp emit_field_provision(state, event, action, attrs) do
    CliObserve.emit(event, fn ->
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
  defp push_snapshot_fallback(state, subscriber, request_id, payload, reason) do
    send(subscriber, {:voxel_chunk_snapshot_payload, payload})

    CliObserve.emit("voxel_chunk_snapshot_push", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        chunk_version: state.storage.chunk_version,
        subscriber: subscriber,
        request_id: request_id,
        reason: reason,
        byte_size: byte_size(payload),
        fallback: :snapshot_until_chunk_delta
      }
    end)
  end

  defp encode_snapshot_payload(%Storage{} = storage, request_id) do
    Codec.encode_chunk_snapshot_payload(%{request_id: request_id, storage: storage})
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
         # AUTH-4(step1.5b-1):客户端命令幂等键,gate 派生(nil=非客户端单方块命令)。
         command_id:
           normalize_command_id(
             fetch_optional(intent_attrs, [:command_id]) || fetch_optional(attrs, [:command_id])
           ),
         opts: opts
       }}
    end
  end

  defp normalize_apply_intent(_attrs), do: {:error, :invalid_voxel_intent}

  defp normalize_command_id(value) when is_binary(value) and byte_size(value) > 0, do: value
  defp normalize_command_id(_value), do: nil

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
    Enum.flat_map(samples, fn sample ->
      case collision_query_hit(storage, sample) do
        nil -> []
        hit -> [hit]
      end
    end)
  end

  defp collision_query_hit(%Storage{} = storage, sample) do
    header = Storage.macro_header_at(storage, sample.macro_index)

    cond do
      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        # S3 Part A:实心格带「可通行」物理属性的 tag(TagPhysics,如通电门已开的 :open)→ 视为可通行,
        # 不计碰撞命中。具体哪些 tag 可通行由 TagPhysics 数据表声明,碰撞代码不写死任何 tag。
        if passable_cell?(storage, sample.macro_index) do
          nil
        else
          Map.put(sample, :mode, :solid)
        end

      header.mode == MacroCellHeader.cell_mode_refined() and
          Storage.micro_slot_occupied?(storage, sample.macro_index, sample.micro_slot) ->
        Map.put(sample, :mode, :refined)

      true ->
        nil
    end
  end

  # S3 Part A:实心格是否带「可通行」物理属性的 tag(经 TagPhysics 声明式判定)。无 tag 的格
  # (绝大多数)走 ref=0 快路径,不做解析;仅带 tag 的格(门等)才解析 tag id 交 TagPhysics 判定。
  # tag_set_ref → ids 的解析归属仍在本进程(Storage tag 表),TagPhysics 只负责 tag→物理属性映射。
  defp passable_cell?(%Storage{} = storage, macro_index) do
    block = Storage.normal_block_at(storage, macro_index)

    storage
    |> current_tag_ids(block.tag_set_ref)
    |> TagPhysics.passable?()
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
