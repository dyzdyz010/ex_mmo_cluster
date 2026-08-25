defmodule SceneServer.Voxel.WorldGenMaterializerTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.LodHeightmapStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.WorldGen
  alias SceneServer.Voxel.WorldGenMaterializer

  setup do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    observe_path = observe_path()
    File.rm(observe_path)
    Application.put_env(:scene_server, :cli_observe_log, observe_path)

    Repo.delete_all(VoxelChunkSnapshot)
    LodHeightmapStore.reset()
    WriteTokenStore.reset()

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end)

    %{observe_path: observe_path}
  end

  test "写入 canonical v2 洞穴 chunk 并输出同源结构化 observation", %{
    observe_path: observe_path
  } do
    scene_id = unique_scene_id()
    lease = lease(scene_id)
    assert {:ok, _} = WriteTokenStore.upsert_token(lease)

    assert {:ok, :inserted} =
             WorldGenMaterializer.put_snapshot(scene_id, {-2, -3, -8}, lease,
               expected_algorithm_version: WorldGen.algorithm_version(),
               lod_projection?: false
             )

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(scene_id, {-2, -3, -8})
    assert snapshot.logical_scene_id == scene_id
    assert snapshot.chunk_coord == {-2, -3, -8}
    assert byte_size(snapshot.data) > 1_000

    assert {:ok, %{status: :empty, total_cell_count: 0}} =
             LodHeightmapStore.summary(scene_id, stride: 16)

    CliObserve.flush()
    log = File.read!(observe_path)
    assert log =~ ~s(event="voxel_worldgen_materialized")
    assert log =~ ~s(algorithm_version: "worldgen_density_v2@1")
    assert log =~ ~s(chunk_coord: "{-2, -3, -8}")
    assert log =~ "solid_cells: 4072"
    assert log =~ "cave_air_cells: 24"
    assert log =~ "surface_cells: 0"
    assert log =~ "subsurface_cells: 4072"
  end

  test "算法版本不匹配时在 snapshot 写入前硬失败并输出原因", %{
    observe_path: observe_path
  } do
    scene_id = unique_scene_id()
    lease = lease(scene_id)
    assert {:ok, _} = WriteTokenStore.upsert_token(lease)

    assert {:error,
            {:worldgen_algorithm_version_mismatch, "worldgen_density_v2@999",
             "worldgen_density_v2@1"}} =
             WorldGenMaterializer.put_snapshot(scene_id, {-2, -3, -8}, lease,
               expected_algorithm_version: "worldgen_density_v2@999"
             )

    assert {:error, :snapshot_not_found} =
             ChunkSnapshotStore.get_snapshot(scene_id, {-2, -3, -8})

    CliObserve.flush()
    log = File.read!(observe_path)
    assert log =~ ~s(event="voxel_worldgen_materialization_failed")
    assert log =~ ~s(algorithm_version: "worldgen_density_v2@1")
    assert log =~ "worldgen_algorithm_version_mismatch"
    assert log =~ "worldgen_density_v2@999"
  end

  test "非法 materializer 选项显式失败且不写入", %{observe_path: observe_path} do
    scene_id = unique_scene_id()
    lease = lease(scene_id)
    assert {:ok, _} = WriteTokenStore.upsert_token(lease)

    assert {:error, :invalid_expected_worldgen_algorithm_version} =
             WorldGenMaterializer.put_snapshot(scene_id, {0, 0, 0}, lease,
               expected_algorithm_version: :invalid
             )

    assert {:error, :snapshot_not_found} =
             ChunkSnapshotStore.get_snapshot(scene_id, {0, 0, 0})

    CliObserve.flush()
    log = File.read!(observe_path)
    assert log =~ ~s(event="voxel_worldgen_materialization_failed")
    assert log =~ "invalid_expected_worldgen_algorithm_version"
  end

  test "默认写入不生成归档 XZ projection" do
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
      bounds_chunk_min: {-4, -4, -9},
      bounds_chunk_max: {2, 2, 2},
      expires_at_ms: System.system_time(:millisecond) + 60_000,
      token_version: 1
    }
  end

  defp observe_path do
    Path.expand(
      "../../../../../.demo/observe/worldgen-materializer-#{System.unique_integer([:positive])}.log",
      __DIR__
    )
  end
end
