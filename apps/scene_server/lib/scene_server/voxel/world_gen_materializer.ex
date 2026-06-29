defmodule SceneServer.Voxel.WorldGenMaterializer do
  @moduledoc """
  Explicit WorldGen-to-authoritative-store materialization.

  This module is not a runtime fallback. It is an import/migration helper used
  before scene entry or by controlled repair tools: generate deterministic
  `WorldGen` storage for a chunk, encode it as the canonical snapshot, and write
  it through `DataService.Voxel.ChunkSnapshotStore` with the caller's lease fence.
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.LodProjection
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.WorldGen

  @doc """
  Generates one chunk from WorldGen and persists it as authoritative truth.

  `lease` must be the current World-issued region lease for `chunk_coord`.
  Missing or stale tokens are returned as explicit DataService errors.

  Options:

    * `:seed` - deterministic WorldGen seed.
    * `:lod_projection?` - when false, persist only the authoritative chunk
      snapshot. Bulk world-pack importers use this and rebuild derived LOD
      rows explicitly after the authoritative range is complete.
    * `:lod_projection_opts` - forwarded to `LodProjection.cells_for_storage/2`
      when inline projection is enabled.
  """
  @spec put_snapshot(non_neg_integer(), {integer(), integer(), integer()}, map(), keyword()) ::
          {:ok, :inserted | :updated | :unchanged} | {:error, term()}
  def put_snapshot(logical_scene_id, chunk_coord, lease, opts \\ [])

  def put_snapshot(logical_scene_id, chunk_coord, lease, opts)
      when is_integer(logical_scene_id) and logical_scene_id >= 0 and is_tuple(chunk_coord) and
             tuple_size(chunk_coord) == 3 and is_map(lease) and is_list(opts) do
    seed = Keyword.get(opts, :seed, WorldGen.default_seed())

    storage =
      logical_scene_id
      |> WorldGen.generate_chunk_storage(chunk_coord, seed: seed)
      |> Storage.normalize!()

    payload = Codec.encode_chunk_snapshot_payload(%{request_id: 0, storage: storage})
    chunk_hash = Hash.encode64(Codec.chunk_hash(storage))

    with {:ok, lod_projection_cells, lod_projection?} <- lod_projection_cells(storage, opts),
         attrs <-
           snapshot_attrs(lease, chunk_coord, storage, payload, chunk_hash, lod_projection_cells),
         {:ok, result} <- ChunkSnapshotStore.put_snapshot(attrs) do
      CliObserve.emit("voxel_worldgen_materialized", fn ->
        %{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord,
          seed: seed,
          chunk_version: storage.chunk_version,
          result: result,
          snapshot_bytes: byte_size(payload),
          lod_projection?: lod_projection?,
          lod_projection_cells: length(lod_projection_cells)
        }
      end)

      {:ok, result}
    else
      {:error, reason} ->
        CliObserve.emit("voxel_worldgen_materialization_failed", fn ->
          %{
            logical_scene_id: logical_scene_id,
            chunk_coord: chunk_coord,
            seed: seed,
            reason: inspect(reason)
          }
        end)

        {:error, reason}
    end
  rescue
    exception -> {:error, {:worldgen_materializer_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:worldgen_materializer_exit, reason}}
    kind, reason -> {:error, {:worldgen_materializer_catch, kind, reason}}
  end

  def put_snapshot(_logical_scene_id, _chunk_coord, _lease, _opts),
    do: {:error, :invalid_worldgen_materialization_request}

  defp lod_projection_cells(storage, opts) do
    case Keyword.get(opts, :lod_projection?, true) do
      false ->
        {:ok, [], false}

      true ->
        projection_opts = Keyword.get(opts, :lod_projection_opts, [])

        if is_list(projection_opts) do
          with {:ok, cells} <- LodProjection.cells_for_storage(storage, projection_opts) do
            {:ok, cells, true}
          end
        else
          {:error, :invalid_lod_projection_opts}
        end

      _other ->
        {:error, :invalid_lod_projection_flag}
    end
  end

  defp snapshot_attrs(lease, chunk_coord, %Storage{} = storage, payload, chunk_hash, cells) do
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
      chunk_hash: chunk_hash,
      data: payload,
      lod_projection_cells: cells
    })
  end
end
