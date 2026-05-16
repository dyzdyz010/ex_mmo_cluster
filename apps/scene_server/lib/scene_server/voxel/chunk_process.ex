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
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.Field.FieldCodec
  alias SceneServer.Voxel.Field.FieldRegion
  alias SceneServer.Voxel.Field.FieldTickSupervisor
  alias SceneServer.Voxel.Field.FieldTickWorker
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.SimulationTick
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  import Bitwise

  # Phase 5.E: 10 Hz simulation tick (100ms interval). 见
  # `docs/plans/2026-05-13-phase5e-simulation-tick-infrastructure.md` E-2。
  @simulation_tick_interval_ms 100
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

    storage =
      opts
      |> Keyword.get(:storage, Storage.empty(logical_scene_id, chunk_coord))
      |> Storage.normalize!()

    lease = normalize_optional_lease(Keyword.get(opts, :lease))

    pending_fence = load_persisted_fence(storage.logical_scene_id, storage.chunk_coord, lease)

    simulators = resolve_simulators(opts)
    simulation_tick = SimulationTick.new(simulators)
    schedule_simulation_tick()

    {:ok,
     %{
       logical_scene_id: storage.logical_scene_id,
       chunk_coord: storage.chunk_coord,
       storage: storage,
       lease: lease,
       subscribers: %{},
       subscriber_monitors: %{},
       async_persists: %{},
       persist_waiters: [],
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
       field_regions: %{},
       field_region_monitors: %{},
       field_region_sources: %{},
       field_region_source_keys: %{}
     }}
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

    next_state = %{state | storage: storage}
    push_snapshot_fallbacks(next_state, :put_solid_block)

    {:reply, {:ok, storage}, next_state}
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

  def handle_call({:subscribe, subscriber, opts}, _from, state) do
    request_id = Keyword.get(opts, :request_id, 0)
    known_version = Keyword.get(opts, :known_version)
    send_snapshot? = Keyword.get(opts, :send_snapshot?, true)
    {state, monitor_ref} = put_subscriber(state, subscriber, request_id)
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
       pending_async_persist_count: map_size(state.async_persists),
       subscriber_count: map_size(state.subscribers),
       subscribers: Map.keys(state.subscribers),
       field_region_count: map_size(state.field_regions),
       field_source_count: map_size(state.field_region_sources)
     }, state}
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
      {:ok, region_id, next_state} -> {:reply, {:ok, region_id}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ensure_field_region, attrs}, _from, state) when is_map(attrs) do
    case fetch_optional(attrs, [:source_key]) do
      nil ->
        {:reply, {:error, :missing_field_source_key}, state}

      source_key ->
        case Map.fetch(state.field_region_sources, source_key) do
          {:ok, region_id} ->
            case Map.fetch(state.field_regions, region_id) do
              {:ok, worker_pid} ->
                if Process.alive?(worker_pid) do
                  maybe_add_field_source_points(worker_pid, attrs)

                  {:reply,
                   {:ok,
                    %{
                      region_id: region_id,
                      created?: false,
                      source_key: source_key
                    }}, state}
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
  end

  # Phase 6: destroy a FieldRegion by region_id (explicit caller-initiated).
  def handle_call({:destroy_field_region, region_id}, _from, state)
      when is_integer(region_id) do
    case Map.fetch(state.field_regions, region_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, worker_pid} ->
        destroyed_payload =
          FieldCodec.encode_destroyed_payload(
            region_id,
            state.chunk_coord,
            state.logical_scene_id,
            :explicit
          )

        if Process.alive?(worker_pid) do
          # Best-effort stop; the {:DOWN, ...} handler will clean monitor maps.
          try do
            GenServer.stop(worker_pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end

        new_state =
          state
          |> drop_field_region_id(region_id)
          |> tap(fn _ ->
            fan_out_field_region_destroyed_payload(state, destroyed_payload)
          end)

        {:reply, :ok, new_state}
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
  def handle_info({:async_snapshot_persist_finished, ref, result, snapshot_bytes}, state) do
    {persist_meta, async_persists} = Map.pop(state.async_persists, ref)

    if persist_meta do
      Process.demonitor(persist_meta.monitor_ref, [:flush])

      CliObserve.emit("voxel_chunk_async_persist_finished", fn ->
        Map.merge(persist_meta.observe, %{result: inspect(result), snapshot_bytes: snapshot_bytes})
      end)
    end

    state =
      %{state | async_persists: async_persists}
      |> maybe_reply_persist_waiters()

    {:noreply, state}
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

        state =
          %{state | async_persists: async_persists}
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

            new_state =
              state
              |> drop_field_region_monitor(monitor_ref, region_id)

            {:noreply, new_state}
        end
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

  def handle_info(_message, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Phase 5.E:simulation tick dispatch
  # ---------------------------------------------------------------------------

  defp run_simulation_tick(%{simulation_tick: simulation_tick} = state) do
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
               persist_payload
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
  rescue
    _exception in ArgumentError -> {:error, :invalid_voxel_intent}
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

      {:ok, pid} =
        Task.start_link(fn ->
          payload = payload || encode_snapshot_payload(storage, 0)
          snapshot_bytes = byte_size(payload)

          result =
            lease
            |> build_snapshot_attrs(chunk_coord, storage, payload)
            |> safe_persist_snapshot_with_retry(3)

          send(parent, {:async_snapshot_persist_finished, ref, result, snapshot_bytes})
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

          {:ok, region_id, next_state}

        {:error, reason} ->
          {:error, {:start_worker_failed, reason}}
      end
    rescue
      error -> {:error, {:invalid_field_region, Exception.message(error)}}
    end
  end

  defp ensure_new_field_source_region(state, attrs, source_key) do
    case start_field_region(state, attrs, source_key) do
      {:ok, region_id, next_state} ->
        {:reply,
         {:ok,
          %{
            region_id: region_id,
            created?: true,
            source_key: source_key
          }}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp maybe_add_field_source_points(worker_pid, attrs) do
    case fetch_optional(attrs, [:source_points]) do
      source_points when is_list(source_points) and source_points != [] ->
        FieldTickWorker.add_source_points(worker_pid, source_points)

      _other ->
        :ok
    end
  end

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

    %{
      state
      | field_regions: field_regions,
        field_region_monitors: field_region_monitors,
        field_region_sources: sources,
        field_region_source_keys: source_keys
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

    %{
      state
      | field_region_monitors: monitors,
        field_regions: regions,
        field_region_sources: sources,
        field_region_source_keys: source_keys
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

  # Phase 6: stop every worker and push 0x74 to subscribers for each region.
  defp stop_all_field_workers(state, reason) do
    Enum.each(state.field_regions, fn {region_id, worker_pid} ->
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
          state.chunk_coord,
          state.logical_scene_id,
          reason
        )

      fan_out_field_region_destroyed_payload(state, destroyed_payload)

      CliObserve.emit("voxel_field_region_destroyed", fn ->
        %{
          logical_scene_id: state.logical_scene_id,
          chunk_coord: state.chunk_coord,
          region_id: region_id,
          destroy_reason: reason
        }
      end)
    end)

    %{
      state
      | field_regions: %{},
        field_region_monitors: %{},
        field_region_sources: %{},
        field_region_source_keys: %{}
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
