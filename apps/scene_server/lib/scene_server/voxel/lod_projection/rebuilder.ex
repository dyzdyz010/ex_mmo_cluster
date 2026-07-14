defmodule SceneServer.Voxel.LodProjection.Rebuilder do
  @moduledoc """
  从 canonical snapshots 重建已归档的 XZ heightmap projection rows。

  这是显式离线迁移/backfill 工具，不属于 world-pack canonical 写入、在线近场窗口或
  远景壳链路；运行时不得把它当 fallback。产物只供历史数据审计、迁移与清理。
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.LodHeightmapStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.LodProjection
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.Storage

  @default_batch_size 5_000

  @doc """
  Rebuilds all projection rows for one logical scene.

  Options:

    * `:snapshot_store` - module exposing `snapshot/1`.
    * `:lod_store` - module exposing `upsert_cells/2`.
    * `:strides` - forwarded to `LodProjection.cells_for_storage/2`.
    * `:batch_size` - projection rows per DB upsert batch.
    * `:repo` - forwarded to data-service stores.
  """
  @spec rebuild_scene(non_neg_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild_scene(logical_scene_id, opts \\ [])

  def rebuild_scene(logical_scene_id, opts)
      when is_integer(logical_scene_id) and logical_scene_id >= 0 and is_list(opts) do
    started_at = System.monotonic_time(:millisecond)

    strides =
      Keyword.get(
        opts,
        :strides,
        Application.get_env(:scene_server, :voxel_lod_projection_strides)
      )

    CliObserve.emit("voxel_lod_projection_rebuild_started", %{
      logical_scene_id: logical_scene_id,
      strides: strides,
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size)
    })

    result = do_rebuild_scene(logical_scene_id, opts)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, summary} ->
        CliObserve.emit(
          "voxel_lod_projection_rebuild_completed",
          Map.put(summary, :elapsed_ms, elapsed_ms)
        )

      {:error, reason} ->
        CliObserve.emit("voxel_lod_projection_rebuild_failed", %{
          logical_scene_id: logical_scene_id,
          elapsed_ms: elapsed_ms,
          reason: reason
        })
    end

    result
  end

  def rebuild_scene(_logical_scene_id, _opts), do: {:error, :invalid_logical_scene_id}

  defp do_rebuild_scene(logical_scene_id, opts) do
    with {:ok, batch_size} <- batch_size(opts),
         {:ok, snapshot_index} <- load_scene_snapshot_index(logical_scene_id, opts),
         {:ok, storages} <- decode_scene_storages(snapshot_index) do
      projection_sources = coalesce_projection_sources(storages)
      rebuild_storages(logical_scene_id, projection_sources, snapshot_index, batch_size, opts)
    end
  end

  defp rebuild_storages(logical_scene_id, storages, snapshot_index, batch_size, opts) do
    initial = %{
      pending_cells: [],
      pending_count: 0,
      chunk_count: 0,
      cell_count: 0,
      batch_count: 0
    }

    case Enum.reduce_while(storages, {:ok, initial}, fn storage, {:ok, acc} ->
           projection_opts =
             opts
             |> Keyword.take([:strides])
             |> Keyword.put(:snapshot_index, snapshot_index)

           case LodProjection.cells_for_storage(storage, projection_opts) do
             {:ok, cells} ->
               acc =
                 acc
                 |> Map.update!(:chunk_count, &(&1 + 1))
                 |> Map.update!(:cell_count, &(&1 + length(cells)))

               case append_and_flush(cells, acc, batch_size, opts) do
                 {:ok, next_acc} -> {:cont, {:ok, next_acc}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end

             {:error, reason} ->
               {:halt, {:error, {:lod_projection_rebuild_failed, storage.chunk_coord, reason}}}
           end
         end) do
      {:ok, acc} ->
        with {:ok, flushed} <- flush_pending(acc, opts) do
          {:ok,
           %{
             logical_scene_id: logical_scene_id,
             chunk_count: flushed.chunk_count,
             cell_count: flushed.cell_count,
             batch_count: flushed.batch_count
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_and_flush(cells, acc, batch_size, opts) do
    pending = acc.pending_cells ++ cells
    pending_count = acc.pending_count + length(cells)
    acc = %{acc | pending_cells: pending, pending_count: pending_count}

    if pending_count >= batch_size do
      flush_pending(acc, opts)
    else
      {:ok, acc}
    end
  end

  defp flush_pending(%{pending_count: 0} = acc, _opts), do: {:ok, acc}

  defp flush_pending(acc, opts) do
    lod_store = Keyword.get(opts, :lod_store, LodHeightmapStore)
    store_opts = Keyword.take(opts, [:repo])

    case lod_store.upsert_cells(acc.pending_cells, store_opts) do
      :ok ->
        {:ok, %{acc | pending_cells: [], pending_count: 0, batch_count: acc.batch_count + 1}}

      {:error, reason} ->
        {:error, {:lod_projection_upsert_failed, reason}}
    end
  end

  defp load_scene_snapshot_index(logical_scene_id, opts) do
    snapshot_store = Keyword.get(opts, :snapshot_store, ChunkSnapshotStore)
    store_opts = Keyword.take(opts, [:repo])

    try do
      snapshot_store.snapshot(store_opts)
      |> Enum.filter(fn
        {{^logical_scene_id, _chunk_coord}, _snapshot} -> true
        _other -> false
      end)
      |> Map.new()
      |> then(&{:ok, &1})
    catch
      :exit, reason -> {:error, {:snapshot_store_unavailable, reason}}
    end
  end

  defp decode_scene_storages(snapshot_index) do
    snapshot_index
    |> Enum.reduce_while({:ok, []}, fn {_key, snapshot}, {:ok, acc} ->
      case decode_storage(snapshot) do
        {:ok, storage} -> {:cont, {:ok, [storage | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_authoritative_snapshot, reason}}}
      end
    end)
    |> case do
      {:ok, storages} -> {:ok, Enum.sort_by(storages, & &1.chunk_coord)}
      error -> error
    end
  end

  defp decode_storage(%Storage{} = storage), do: {:ok, Storage.normalize!(storage)}
  defp decode_storage(%{storage: %Storage{} = storage}), do: {:ok, Storage.normalize!(storage)}
  defp decode_storage(%{data: data}) when is_binary(data), do: decode_storage(data)

  defp decode_storage(data) when is_binary(data) do
    case Codec.decode_chunk_snapshot_payload(data) do
      {:ok, %{storage: %Storage{} = storage}} -> {:ok, storage}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_storage(other), do: {:error, {:unsupported_snapshot_value, other}}

  defp coalesce_projection_sources(storages) do
    storages
    |> Enum.group_by(fn %Storage{chunk_coord: {cx, _cy, cz}} -> {cx, cz} end)
    |> Enum.map(fn {_column, column_storages} -> representative_storage(column_storages) end)
    |> Enum.sort_by(& &1.chunk_coord)
  end

  defp representative_storage(column_storages) do
    sorted =
      Enum.sort_by(column_storages, fn %Storage{chunk_coord: {_cx, cy, _cz}} -> cy end, :desc)

    Enum.find(sorted, &lod_occupied_storage?/1) || hd(sorted)
  end

  defp lod_occupied_storage?(%Storage{macro_headers: headers}) do
    solid_mode = MacroCellHeader.cell_mode_solid_block()
    refined_mode = MacroCellHeader.cell_mode_refined()

    Enum.any?(headers, fn
      %MacroCellHeader{mode: mode} ->
        mode == solid_mode or mode == refined_mode

      _other ->
        false
    end)
  end

  defp batch_size(opts) do
    value = Keyword.get(opts, :batch_size, @default_batch_size)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, :invalid_lod_projection_batch_size}
    end
  end
end
