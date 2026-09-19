defmodule GateServer.VoxelSmokeTest do
  @moduledoc "只测试：真实 Gate 鉴权/角色授权及旧 voxel 协议组件集成；Scene 接纳使用显式替身。"
  use ExUnit.Case, async: false

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  test "runs authenticated voxel smoke without resetting unrelated world state" do
    GateServer.TestSupport.VoxelSession.setup()

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims(source: "test")
      |> AuthServer.AuthWorker.issue_token()

    other_scene = 980_000 + System.unique_integer([:positive, :monotonic])
    other_epoch = DataService.Voxel.RegionEpochStore.allocate_next(other_scene, other_scene)
    logical_scene_id = 880_000 + System.unique_integer([:positive, :monotonic])

    observe_dir =
      Path.expand("../../../../.demo/observe/voxel-smoke-test-#{logical_scene_id}", __DIR__)

    File.rm_rf!(observe_dir)
    on_exit(fn -> File.rm_rf(observe_dir) end)

    assert {:ok, summary} =
             GateServer.VoxelSmoke.run(
               username: "tester",
               token: token,
               cid: 42,
               logical_scene_id: logical_scene_id,
               observe_dir: observe_dir
             )

    assert DataService.Voxel.RegionEpochStore.current(other_scene, other_scene) == other_epoch
    assert summary.status == :ok
    assert summary.protocol.initial_snapshot_version == 0
    assert summary.protocol.updated_frame_type == :delta
    assert summary.protocol.updated_chunk_version == 1
    assert summary.protocol.updated_snapshot_version == 1
    assert summary.protocol.stored_snapshot_version == 2
    assert summary.protocol.unsubscribe_stopped_push? == true

    gate_log = File.read!(summary.logs.gate_observe_log)
    scene_log = File.read!(summary.logs.scene_observe_log)
    world_log = File.read!(summary.logs.world_observe_log)
    stdio_log = File.read!(summary.logs.stdio_log)
    summary_log = File.read!(summary.logs.summary_path)

    assert gate_log =~ ~s(event="ws_enter_scene_ok")
    assert gate_log =~ ~s(event="ws_voxel_chunk_subscribe_received")
    assert gate_log =~ ~s(event="ws_voxel_impact_intent_applied")
    assert scene_log =~ ~s(event="voxel_chunk_snapshot_push")
    assert scene_log =~ ~s(event="voxel_chunk_delta_push")
    assert world_log =~ ~s(event="voxel_region_put")
    assert stdio_log =~ ~s(server_stdio event="voxel")
    assert stdio_log =~ "ws_connections"
    assert summary_log =~ "updated_frame_type: :delta"
    assert summary_log =~ "unsubscribe_stopped_push?: true"

    :ok
  end

  test "rejects an invalid session before creating a world region" do
    GateServer.TestSupport.VoxelSession.setup()

    observe_dir =
      Path.join(System.tmp_dir!(), "voxel-smoke-auth-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(observe_dir) end)

    assert {:error, %{reason: reason}} =
             GateServer.VoxelSmoke.run(
               username: "tester",
               token: "invalid",
               cid: 42,
               observe_dir: observe_dir,
               logical_scene_id: 998_000,
               region_id: 998_001
             )

    assert reason =~ "authentication_rejected"
    assert DataService.Voxel.RegionEpochStore.current(998_000, 998_001) == 0
  end

  test "missing credentials fail without logging supplied tokens" do
    observe_dir =
      Path.join(System.tmp_dir!(), "voxel-smoke-missing-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(observe_dir) end)

    assert {:error, failure} =
             GateServer.VoxelSmoke.run(token: "private-test-token", observe_dir: observe_dir)

    assert failure.reason == "missing smoke username"
    refute inspect(failure) =~ "private-test-token"
  end
end
