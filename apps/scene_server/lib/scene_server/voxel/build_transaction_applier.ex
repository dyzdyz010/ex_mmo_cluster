defmodule SceneServer.Voxel.BuildTransactionApplier do
  @moduledoc """
  Scene-side participant for World-coordinated voxel build transactions.

  The applier turns a `WorldServer.Voxel.TransactionParticipant` plus a per-chunk
  intent batch (`%{chunk_coord => [intent_attrs, ...]}`) into the three
  coordinator phases that World drives:

  - `prepare/3` reserves a transaction fence on every affected chunk and stages
    the per-chunk intent batch. On any failure the already-fenced chunks are
    rolled back so a participant either ends up fully prepared or fully
    unprepared.
  - `commit/3` applies the staged intent batch on each chunk and releases the
    fence (chunk-local atomic: any single intent's apply failure rolls back
    the whole chunk's batch).
  - `abort/3` releases every chunk fence held by the transaction without
    applying. Idempotent against missing or already-released fences.

  The applier itself is stateless. The fence and staged intent live in the
  individual `SceneServer.Voxel.ChunkProcess` so chunk migration / Scene
  hand-off keeps the transaction reasoning local to the chunk owner.
  """

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ObjectOwnerLookup
  alias SceneServer.Voxel.ObjectRegistry

  @type intent_attrs :: map()
  @type intents_by_chunk :: %{
          optional(coord :: {integer(), integer(), integer()}) => [intent_attrs(), ...]
        }
  @type participant :: %{
          required(:region_id) => non_neg_integer(),
          required(:lease_id) => non_neg_integer(),
          required(:owner_scene_instance_ref) => non_neg_integer(),
          required(:owner_epoch) => non_neg_integer(),
          required(:affected_chunks) => [{integer(), integer(), integer()}]
        }

  @doc """
  Reserves a fence on every chunk in `participant.affected_chunks`.

  Required `opts`:

  - `:logical_scene_id` — the transaction's logical scene id; participants are
    lease-scoped and do not carry it on the struct.

  Optional `opts`:

  - `:chunk_directory` — override the default directory module/pid for tests.
  - `:decision_version` — coordinator's `decision_version`, propagated into
    the persisted fence row for diagnostics. Defaults to 0.

  Returns `{:ok, summaries}` when every chunk fence was acquired (or already
  held by the same `transaction_id`). On the first per-chunk failure, all
  chunks reserved earlier in this call are aborted before returning the error.
  """
  def prepare(participant, transaction_id, intents_by_chunk, opts)
      when is_binary(transaction_id) and is_map(intents_by_chunk) and is_list(opts) do
    chunk_directory = Keyword.get(opts, :chunk_directory, ChunkDirectory)
    logical_scene_id = fetch_logical_scene_id!(opts)
    decision_version = fetch_decision_version(opts)

    case validate_intents_cover_chunks(participant, intents_by_chunk) do
      :ok ->
        emit_event(
          "voxel_transaction_participant_prepare_started",
          participant,
          transaction_id,
          %{
            chunk_count: length(participant.affected_chunks)
          }
        )

        prepare_chunks(
          chunk_directory,
          participant,
          transaction_id,
          intents_by_chunk,
          logical_scene_id,
          decision_version
        )

      {:error, reason} = error ->
        emit_event("voxel_transaction_participant_prepare_failed", participant, transaction_id, %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Commits the staged intent on every prepared chunk and releases the fence.

  Required `opts`:

  - `:logical_scene_id` — the transaction's logical scene id.

  Optional `opts`:

  - `:chunk_directory` — override the default directory module/pid for tests.
  """
  def commit(participant, transaction_id, opts)
      when is_binary(transaction_id) and is_list(opts) do
    chunk_directory = Keyword.get(opts, :chunk_directory, ChunkDirectory)
    logical_scene_id = fetch_logical_scene_id!(opts)

    {results, error} =
      Enum.reduce(participant.affected_chunks, {[], nil}, fn chunk_coord, {acc, err} ->
        case err do
          nil ->
            attrs = %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}

            case ChunkDirectory.commit_transaction(chunk_directory, transaction_id, attrs) do
              {:ok, summary} ->
                {[{chunk_coord, summary} | acc], nil}

              {:error, reason} ->
                {acc, {chunk_coord, reason}}
            end

          _ ->
            {acc, err}
        end
      end)

    case error do
      nil ->
        emit_event("voxel_transaction_participant_committed", participant, transaction_id, %{
          chunk_count: length(results)
        })

        {:ok, %{committed_chunks: Enum.reverse(results)}}

      {chunk_coord, reason} ->
        emit_event("voxel_transaction_participant_commit_failed", participant, transaction_id, %{
          chunk_coord: chunk_coord,
          reason: inspect(reason)
        })

        {:error, {:commit_failed, chunk_coord, reason}}
    end
  end

  @doc """
  Releases the fence on every affected chunk for this transaction.

  Required `opts`:

  - `:logical_scene_id` — the transaction's logical scene id.

  Idempotent: chunks that do not hold the transaction fence are skipped. The
  caller is allowed to call `abort/3` even if `prepare/3` partially failed.
  """
  def abort(participant, transaction_id, opts)
      when is_binary(transaction_id) and is_list(opts) do
    chunk_directory = Keyword.get(opts, :chunk_directory, ChunkDirectory)
    logical_scene_id = fetch_logical_scene_id!(opts)

    Enum.each(participant.affected_chunks, fn chunk_coord ->
      ChunkDirectory.abort_transaction(chunk_directory, transaction_id, %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord
      })
    end)

    emit_event("voxel_transaction_participant_aborted", participant, transaction_id, %{
      chunk_count: length(participant.affected_chunks)
    })

    :ok
  end

  @doc """
  Phase 4 (D5):upserts the per-transaction `scene_objects` (allocated by
  the coordinator at `begin_transaction`) into the per-scene
  `SceneServer.Voxel.ObjectRegistry`,which in turn syncs them to
  `voxel_scene_objects` via `DataService.Voxel.SceneObjectStore`.

  Called by `WorldServer.Voxel.TransactionExecutor.run_commit/7` once after
  `commit_decision` succeeds — i.e. exactly once per transaction, after
  every chunk has applied its intents and refreshed its
  `ChunkObjectRef[]`. Called with an empty list it's a cheap no-op for
  transactions that did not allocate any objects (e.g. break-only
  transactions in Phase 5+).

  Optional `opts`:

    * `:object_registry` — overrides the default registry module (test only)
    * `:owner_lookup` / `:owner_lookup_server` — `ObjectOwnerLookup` module
      and named server (Phase A4-4 D7;default `ObjectOwnerLookup`)。Each
      scene_object's `:covered_chunks_by_region` (added by
      `WorldServer.Voxel.TransactionExecutor` from the transaction's
      participants) is forwarded into the lookup cache so subsequent
      cross-region damage / 0x6C broadcasts route correctly without
      hitting Postgres on the hot path.

  Failures during upsert do not block the executor;they are emitted
  as `voxel_scene_object_register_failed` observe events and otherwise
  swallowed (the transaction is already committed, the registry can pick
  up missing rows on next reload from `SceneObjectStore`)。Failures during
  the owner-lookup write are emitted as
  `voxel_scene_object_owner_lookup_register_failed` and similarly do not
  block(`ObjectOwnerLookup.fetch_owner` will lazily reload from
  `SceneObjectStore` on next miss)。
  """
  @spec register_scene_objects([map()], keyword()) :: :ok
  def register_scene_objects(scene_objects, opts \\ [])

  def register_scene_objects([], _opts), do: :ok

  def register_scene_objects(scene_objects, opts) when is_list(scene_objects) and is_list(opts) do
    registry = Keyword.get(opts, :object_registry, ObjectRegistry)
    owner_lookup = Keyword.get(opts, :owner_lookup, ObjectOwnerLookup)
    owner_lookup_server = Keyword.get(opts, :owner_lookup_server, ObjectOwnerLookup)

    Enum.each(scene_objects, fn obj ->
      case ObjectRegistry.upsert_object(registry, obj) do
        :ok ->
          register_owner_lookup(owner_lookup, owner_lookup_server, obj)

        {:error, reason} ->
          CliObserve.emit("voxel_scene_object_register_failed", fn ->
            %{
              object_id: Map.get(obj, :object_id),
              logical_scene_id: Map.get(obj, :logical_scene_id),
              reason: inspect(reason)
            }
          end)

          :ok
      end
    end)

    :ok
  end

  # Phase A4-4 D7:write the per-region split into the scene-local
  # `ObjectOwnerLookup` so cross-region damage / 0x6C broadcasts can pull
  # owner metadata without round-tripping to Postgres on every hit.
  defp register_owner_lookup(owner_lookup, owner_lookup_server, obj) do
    covered = Map.get(obj, :covered_chunks_by_region, %{}) || %{}
    owner_lookup.register(owner_lookup_server, obj, covered)
  rescue
    error ->
      emit_owner_lookup_register_failed(obj, {:error, error})
  catch
    :exit, reason ->
      emit_owner_lookup_register_failed(obj, {:exit, reason})
  end

  defp emit_owner_lookup_register_failed(obj, reason) do
    CliObserve.emit("voxel_scene_object_owner_lookup_register_failed", fn ->
      %{
        object_id: Map.get(obj, :object_id),
        logical_scene_id: Map.get(obj, :logical_scene_id),
        reason: inspect(reason)
      }
    end)

    :ok
  end

  defp prepare_chunks(
         chunk_directory,
         participant,
         transaction_id,
         intents_by_chunk,
         logical_scene_id,
         decision_version
       ) do
    {summaries, error} =
      Enum.reduce_while(
        participant.affected_chunks,
        {[], nil},
        fn chunk_coord, {acc, _err} ->
          intents = Map.fetch!(intents_by_chunk, chunk_coord)

          intents =
            Enum.map(intents, fn intent ->
              intent
              |> Map.put_new(:logical_scene_id, logical_scene_id)
              |> Map.put_new(:chunk_coord, chunk_coord)
            end)

          attrs = %{
            logical_scene_id: logical_scene_id,
            chunk_coord: chunk_coord,
            intents: intents,
            decision_version: decision_version
          }

          case ChunkDirectory.prepare_transaction(chunk_directory, transaction_id, attrs) do
            {:ok, summary} ->
              {:cont, {[{chunk_coord, summary} | acc], nil}}

            {:error, reason} ->
              {:halt, {acc, {chunk_coord, reason}}}
          end
        end
      )

    case error do
      nil ->
        emit_event("voxel_transaction_participant_prepared", participant, transaction_id, %{
          chunk_count: length(summaries)
        })

        {:ok, %{prepared_chunks: Enum.reverse(summaries)}}

      {failed_chunk, reason} ->
        rollback_prepared(
          chunk_directory,
          participant,
          transaction_id,
          summaries,
          logical_scene_id
        )

        emit_event("voxel_transaction_participant_prepare_failed", participant, transaction_id, %{
          chunk_coord: failed_chunk,
          reason: inspect(reason),
          rolled_back_chunks: length(summaries)
        })

        {:error, {:prepare_failed, failed_chunk, reason}}
    end
  end

  defp rollback_prepared(
         chunk_directory,
         _participant,
         transaction_id,
         prepared,
         logical_scene_id
       ) do
    Enum.each(prepared, fn {chunk_coord, _summary} ->
      ChunkDirectory.abort_transaction(chunk_directory, transaction_id, %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord
      })
    end)
  end

  defp validate_intents_cover_chunks(participant, intents) do
    chunks = Map.fetch!(participant, :affected_chunks)

    missing =
      Enum.reject(chunks, fn chunk_coord -> Map.has_key?(intents, chunk_coord) end)

    case missing do
      [] -> :ok
      [first | _] -> {:error, {:missing_intent_for_chunk, first}}
    end
  end

  defp fetch_logical_scene_id!(opts) do
    case Keyword.fetch(opts, :logical_scene_id) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "expected :logical_scene_id to be a non-negative integer, got: #{inspect(other)}"

      :error ->
        raise ArgumentError, "missing required :logical_scene_id"
    end
  end

  defp fetch_decision_version(opts) do
    case Keyword.get(opts, :decision_version, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp emit_event(event, participant, transaction_id, payload) do
    CliObserve.emit(event, fn ->
      Map.merge(
        %{
          transaction_id: transaction_id,
          region_id: participant.region_id,
          lease_id: participant.lease_id,
          owner_scene_instance_ref: participant.owner_scene_instance_ref,
          owner_epoch: participant.owner_epoch
        },
        payload
      )
    end)
  end
end
