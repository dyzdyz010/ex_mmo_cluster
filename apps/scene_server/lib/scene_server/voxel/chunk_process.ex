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
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  import Bitwise

  @intent_option_keys [:cell_hash, :cell_version, :environment_index, :flags]

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

    {:ok,
     %{
       logical_scene_id: storage.logical_scene_id,
       chunk_coord: storage.chunk_coord,
       storage: storage,
       lease: lease,
       subscribers: %{},
       subscriber_monitors: %{},
       pending_fence: pending_fence
     }}
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

    {:reply, {:ok, lease}, %{state | lease: lease}}
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
                  push_intent_outcome(state, next_state, intent, :apply_intent)
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
                  push_snapshot_fallbacks(next_state, :apply_intents)
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
          push_snapshot_fallbacks(next_state, :commit_transaction)
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
       subscriber_count: map_size(state.subscribers),
       subscribers: Map.keys(state.subscribers)
     }, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, subscriber, reason}, state) do
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
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_normalized_intent(state, intent) do
    with :ok <- validate_intent_scope(state, intent),
         :ok <- validate_intent_preconditions(state, intent),
         {:ok, raw_storage, changed?} <- build_intent_storage(state.storage, intent) do
      # Phase 4 (D6):mirror the apply_normalized_intents/2 batch path —
      # rebuild ChunkObjectRef[] from layer truth so single-intent flows
      # (apply_intent/2 direct path) keep object provenance摘要 in sync.
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

            {:ok, intent_reply(next_storage, intent, persist_result, snapshot_payload, true),
             next_state}

          {:error, reason} ->
            {:error, reason}
        end
      else
        next_state = %{state | lease: intent.lease}
        {:ok, intent_reply(next_storage, intent, :unchanged, snapshot_payload, false), next_state}
      end
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
    with :ok <- validate_batch_scope(state, intents),
         :ok <- validate_batch_preconditions(state, intents),
         {:ok, raw_storage, changed_count, skipped_count} <-
           build_intents_storage(state.storage, intents) do
      # Phase 4 (D6):after every apply rebuild per-cell ObjectCoverRef[] and
      # chunk-level ChunkObjectRef[] from the new MicroLayer truth. The
      # refresh is idempotent and cheap (4096 macro headers, sparse refined
      # cells), and keeps owner provenance摘要 in sync without touching
      # the hot apply path semantics.
      next_storage = Storage.refresh_chunk_object_refs(raw_storage)
      request_id = intents |> List.first() |> Map.fetch!(:request_id)
      snapshot_payload = encode_snapshot_payload(next_storage, request_id)
      persist_payload = encode_snapshot_payload(next_storage, 0)
      lease = intents |> List.first() |> Map.fetch!(:lease)

      if changed_count > 0 do
        case persist_snapshot(
               lease,
               state.chunk_coord,
               next_storage,
               persist_payload
             ) do
          {:ok, persist_result} ->
            reply =
              batch_intent_reply(
                next_storage,
                lease,
                persist_result,
                snapshot_payload,
                changed_count,
                skipped_count
              )

            {:ok, reply, %{state | storage: next_storage, lease: lease}}

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
            skipped_count
          )

        {:ok, reply, %{state | lease: lease}}
      end
    end
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
         skipped_count
       ) do
    %{
      logical_scene_id: storage.logical_scene_id,
      chunk_coord: storage.chunk_coord,
      chunk_version: storage.chunk_version,
      changed?: changed_count > 0,
      changed_count: changed_count,
      skipped_count: skipped_count,
      persist_result: persist_result,
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
  rescue
    _exception in ArgumentError -> {:error, :invalid_voxel_intent}
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

  defp persist_snapshot(nil, _chunk_coord, _storage, _payload) do
    {:error, :missing_lease}
  end

  defp persist_snapshot(lease, chunk_coord, storage, payload) do
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

    DataService.Voxel.ChunkSnapshotStore.put_snapshot(attrs)
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

  defp push_intent_outcome(state_before, state_after, intent, reason) do
    case build_intent_delta_op(intent, state_after) do
      {:ok, op} ->
        push_chunk_delta(
          state_after,
          state_before.storage.chunk_version,
          [op],
          reason
        )

      :fallback_to_snapshot ->
        push_snapshot_fallbacks(state_after, reason)
    end
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
    Enum.each(state.subscribers, fn {subscriber, %{request_id: request_id}} ->
      payload = encode_snapshot_payload(state.storage, request_id)
      push_snapshot_fallback(state, subscriber, request_id, payload, reason)
    end)
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
