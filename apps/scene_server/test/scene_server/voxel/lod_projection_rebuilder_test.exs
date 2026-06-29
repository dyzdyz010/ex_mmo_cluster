defmodule SceneServer.Voxel.LodProjectionRebuilderTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.LodHeightmapStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.LodProjection.Rebuilder
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    LodHeightmapStore.reset()
    WriteTokenStore.reset()
    :ok
  end

  test "rebuild_scene backfills projection rows from canonical chunk snapshots" do
    lease = start_snapshot_store()

    storage =
      1
      |> Storage.empty({0, 0, 0})
      |> Storage.put_solid_block({0, 2, 0}, NormalBlockData.new(1))

    assert {:ok, :inserted} = put_snapshot_without_projection(lease, storage)

    assert {:error, {:missing_lod_heightmap_cells, _meta}} =
             LodHeightmapStore.heightmap_region(1, 0, 0, 16, 1, 1)

    assert {:ok, %{chunk_count: 1, cell_count: 1, batch_count: 1}} =
             Rebuilder.rebuild_scene(1, strides: [16], batch_size: 1)

    assert {:ok, %{heights: <<3::unsigned-big-integer-size(16)>>}} =
             LodHeightmapStore.heightmap_region(1, 0, 0, 16, 1, 1)
  end

  test "rebuild_scene coalesces vertical snapshots by X/Z column" do
    lease = start_snapshot_store()

    lower =
      1
      |> Storage.empty({0, 0, 0})
      |> Storage.put_solid_block({0, 2, 0}, NormalBlockData.new(1))

    upper_empty = Storage.empty(1, {0, 1, 0})

    assert {:ok, :inserted} = put_snapshot_without_projection(lease, lower)
    assert {:ok, :inserted} = put_snapshot_without_projection(lease, upper_empty)

    assert {:ok, %{chunk_count: 1, cell_count: 1, batch_count: 1}} =
             Rebuilder.rebuild_scene(1, strides: [16], batch_size: 10)

    assert {:ok, %{heights: <<3::unsigned-big-integer-size(16)>>}} =
             LodHeightmapStore.heightmap_region(1, 0, 0, 16, 1, 1)
  end

  test "rebuild_scene reports invalid snapshots explicitly" do
    assert {:ok, _} =
             Repo.insert(%VoxelChunkSnapshot{
               logical_scene_id: 1,
               coord_x: 0,
               coord_y: 0,
               coord_z: 0,
               schema_version: 1,
               chunk_size_in_macro: 16,
               micro_resolution: 8,
               region_id: 10,
               lease_id: 100,
               owner_scene_instance_ref: 1_000,
               owner_epoch: 1,
               chunk_version: 1,
               chunk_hash: <<0::64>>,
               data: <<1, 2, 3>>
             })

    assert {:error, {:invalid_authoritative_snapshot, _reason}} = Rebuilder.rebuild_scene(1)
  end

  defp put_snapshot_without_projection(lease, %Storage{} = storage) do
    payload = Codec.encode_chunk_snapshot_payload(%{request_id: 0, storage: storage})

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
        chunk_coord: storage.chunk_coord,
        schema_version: storage.schema_version,
        chunk_size_in_macro: storage.chunk_size_in_macro,
        micro_resolution: storage.micro_resolution,
        chunk_version: storage.chunk_version,
        chunk_hash: Hash.encode64(Codec.chunk_hash(storage)),
        data: payload
      })

    ChunkSnapshotStore.put_snapshot(attrs)
  end

  defp start_snapshot_store do
    token = %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000,
      token_version: 1
    }

    assert {:ok, _} = WriteTokenStore.upsert_token(token)
    token
  end
end
