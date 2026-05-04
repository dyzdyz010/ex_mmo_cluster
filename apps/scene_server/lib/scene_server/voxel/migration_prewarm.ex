defmodule SceneServer.Voxel.MigrationPrewarm do
  @moduledoc """
  Scene-side migration prewarm adapter.

  The adapter consumes a World handoff payload, prewarms each planned slice
  through `ChunkDirectory`, and returns ACK maps that a caller can submit back to
  World with `WorldServer.Voxel.MapLedger.mark_slice_prewarmed/3`.

  It does not own migration state. World remains the migration state-machine
  owner; Scene only prepares hot chunks and reports what it loaded.
  """

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.ChunkDirectory

  @doc "Prewarms every planned slice in a World migration handoff and returns ACK payloads."
  def prewarm_slices(handoff, opts \\ [])

  def prewarm_slices(handoff, opts) when is_map(handoff) do
    chunk_directory = Keyword.get(opts, :chunk_directory, ChunkDirectory)
    planned_slices = Map.get(handoff, :planned_slices, [])

    if planned_slices == [] do
      {:error, :migration_handoff_has_no_slices}
    else
      Enum.reduce_while(planned_slices, {:ok, []}, fn slice, {:ok, acc} ->
        case prewarm_slice(chunk_directory, handoff, slice, opts) do
          {:ok, ack} -> {:cont, {:ok, [ack | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acks} -> {:ok, %{migration_id: handoff.migration_id, acks: Enum.reverse(acks)}}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_migration_handoff}
  end

  def prewarm_slices(_handoff, _opts), do: {:error, :invalid_migration_handoff}

  @doc """
  Persists source chunks and reloads target chunks for final catch-up.

  This function is intended to run after World has marked the migration
  prewarmed and before World cutover. It drains the source directory's latest hot
  chunk state into DataService, then reuses the target prewarm path so the target
  directory sees the freshest persisted snapshot.
  """
  def final_catchup_slices(handoff, opts \\ [])

  def final_catchup_slices(handoff, opts) when is_map(handoff) do
    source_chunk_directory = Keyword.get(opts, :source_chunk_directory, ChunkDirectory)

    target_chunk_directory =
      Keyword.get(
        opts,
        :target_chunk_directory,
        Keyword.get(opts, :chunk_directory, ChunkDirectory)
      )

    planned_slices = Map.get(handoff, :planned_slices, [])

    if planned_slices == [] do
      {:error, :migration_handoff_has_no_slices}
    else
      Enum.reduce_while(planned_slices, {:ok, []}, fn slice, {:ok, acc} ->
        case final_catchup_slice(
               source_chunk_directory,
               target_chunk_directory,
               handoff,
               slice,
               opts
             ) do
          {:ok, ack} -> {:cont, {:ok, [ack | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acks} -> {:ok, %{migration_id: handoff.migration_id, acks: Enum.reverse(acks)}}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_migration_handoff}
  end

  def final_catchup_slices(_handoff, _opts), do: {:error, :invalid_migration_handoff}

  defp prewarm_slice(chunk_directory, handoff, slice, opts) do
    slice_id = Map.fetch!(slice, :slice_id)
    single_slice_handoff = %{handoff | planned_slices: [slice]}

    CliObserve.emit("voxel_migration_slice_prewarm_started", %{
      migration_id: handoff.migration_id,
      logical_scene_id: handoff.logical_scene_id,
      region_id: handoff.region_id,
      target_scene_instance_ref: handoff.target_scene_instance_ref,
      slice: slice_summary(slice)
    })

    case ChunkDirectory.prewarm_handoff(chunk_directory, single_slice_handoff,
           timeout: Keyword.get(opts, :timeout, 30_000)
         ) do
      {:ok, summary} ->
        ack = %{
          slice_id: slice_id,
          scene_ref: handoff.target_scene_instance_ref,
          loaded_count: summary.loaded_count,
          empty_count: summary.empty_count,
          max_chunk_version: max_chunk_version(summary.chunks)
        }

        CliObserve.emit("voxel_migration_slice_prewarm_completed", %{
          migration_id: handoff.migration_id,
          logical_scene_id: handoff.logical_scene_id,
          region_id: handoff.region_id,
          target_scene_instance_ref: handoff.target_scene_instance_ref,
          slice_id: slice_id,
          loaded_count: ack.loaded_count,
          empty_count: ack.empty_count,
          max_chunk_version: ack.max_chunk_version
        })

        {:ok, ack}

      {:error, reason} ->
        CliObserve.emit("voxel_migration_slice_prewarm_failed", %{
          migration_id: handoff.migration_id,
          logical_scene_id: handoff.logical_scene_id,
          region_id: handoff.region_id,
          target_scene_instance_ref: handoff.target_scene_instance_ref,
          slice_id: slice_id,
          reason: reason
        })

        {:error, reason}
    end
  end

  defp final_catchup_slice(source_chunk_directory, target_chunk_directory, handoff, slice, opts) do
    slice_id = Map.fetch!(slice, :slice_id)
    single_slice_handoff = %{handoff | planned_slices: [slice]}
    timeout = Keyword.get(opts, :timeout, 30_000)

    CliObserve.emit("voxel_migration_slice_final_catchup_started", %{
      migration_id: handoff.migration_id,
      logical_scene_id: handoff.logical_scene_id,
      region_id: handoff.region_id,
      source_scene_instance_ref: handoff.source_scene_instance_ref,
      target_scene_instance_ref: handoff.target_scene_instance_ref,
      slice: slice_summary(slice)
    })

    with {:ok, source_summary} <-
           ChunkDirectory.persist_handoff_slice(source_chunk_directory, handoff, slice,
             timeout: timeout
           ),
         {:ok, target_summary} <-
           ChunkDirectory.prewarm_handoff(target_chunk_directory, single_slice_handoff,
             timeout: timeout
           ) do
      ack = %{
        slice_id: slice_id,
        scene_ref: handoff.target_scene_instance_ref,
        loaded_count: target_summary.loaded_count,
        empty_count: target_summary.empty_count,
        max_chunk_version: max_chunk_version(target_summary.chunks),
        source_persisted_count: source_summary.persisted_count,
        source_missing_count: source_summary.not_hot_count,
        source_error_count: source_summary.error_count
      }

      CliObserve.emit("voxel_migration_slice_final_catchup_completed", %{
        migration_id: handoff.migration_id,
        logical_scene_id: handoff.logical_scene_id,
        region_id: handoff.region_id,
        target_scene_instance_ref: handoff.target_scene_instance_ref,
        slice_id: slice_id,
        loaded_count: ack.loaded_count,
        empty_count: ack.empty_count,
        max_chunk_version: ack.max_chunk_version,
        source_persisted_count: ack.source_persisted_count,
        source_missing_count: ack.source_missing_count,
        source_error_count: ack.source_error_count
      })

      {:ok, ack}
    else
      {:error, reason} ->
        CliObserve.emit("voxel_migration_slice_final_catchup_failed", %{
          migration_id: handoff.migration_id,
          logical_scene_id: handoff.logical_scene_id,
          region_id: handoff.region_id,
          target_scene_instance_ref: handoff.target_scene_instance_ref,
          slice_id: slice_id,
          reason: reason
        })

        {:error, reason}
    end
  end

  defp max_chunk_version(chunks) do
    chunks
    |> Enum.map(&Map.get(&1, :chunk_version, 0))
    |> Enum.max(fn -> 0 end)
  end

  defp slice_summary(slice) do
    %{
      slice_id: Map.fetch!(slice, :slice_id),
      index: Map.fetch!(slice, :index),
      bounds_chunk_min: tuple_to_list(Map.fetch!(slice, :bounds_chunk_min)),
      bounds_chunk_max: tuple_to_list(Map.fetch!(slice, :bounds_chunk_max))
    }
  end

  defp tuple_to_list({x, y, z}), do: [x, y, z]
end
