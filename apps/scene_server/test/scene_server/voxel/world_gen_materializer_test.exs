defmodule SceneServer.Voxel.WorldGenMaterializerTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.LodHeightmapStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.WorldGenMaterializer

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    LodHeightmapStore.reset()
    WriteTokenStore.reset()
    :ok
  end

  test "persists canonical WorldGen chunks independently of the legacy projection option" do
    scene_id = unique_scene_id()
    lease = lease(scene_id)
    assert {:ok, _} = WriteTokenStore.upsert_token(lease)

    assert {:ok, :inserted} =
             WorldGenMaterializer.put_snapshot(scene_id, {0, 0, 0}, lease, lod_projection?: false)

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(scene_id, {0, 0, 0})
    assert snapshot.logical_scene_id == scene_id
    assert byte_size(snapshot.data) > 1_000

    assert {:ok, %{status: :empty, total_cell_count: 0}} =
             LodHeightmapStore.summary(scene_id, stride: 16)
  end

  test "does not inline the archived XZ projection by default" do
    scene_id = unique_scene_id()
    lease = lease(scene_id)
    assert {:ok, _} = WriteTokenStore.upsert_token(lease)

    assert {:ok, :inserted} =
             WorldGenMaterializer.put_snapshot(scene_id, {0, 0, 0}, lease)

    assert {:ok, %{status: :empty, total_cell_count: 0}} =
             LodHeightmapStore.summary(scene_id, stride: 16)
  end

  defp unique_scene_id do
    930_000 + System.unique_integer([:positive])
  end

  defp lease(scene_id) do
    %{
      logical_scene_id: scene_id,
      region_id: scene_id + 10,
      lease_id: scene_id + 100,
      owner_scene_instance_ref: scene_id + 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {-1, -1, -1},
      bounds_chunk_max: {2, 2, 2},
      expires_at_ms: System.system_time(:millisecond) + 60_000,
      token_version: 1
    }
  end
end
