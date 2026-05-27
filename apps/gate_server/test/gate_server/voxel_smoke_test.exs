defmodule GateServer.VoxelSmokeTest do
  use ExUnit.Case, async: false

  test "runs CLI-observable voxel E2E smoke and writes stdio logs" do
    logical_scene_id = 880_000 + System.unique_integer([:positive, :monotonic])

    observe_dir =
      Path.expand("../../../../.demo/observe/voxel-smoke-test-#{logical_scene_id}", __DIR__)

    File.rm_rf!(observe_dir)
    on_exit(fn -> File.rm_rf(observe_dir) end)

    assert {:ok, summary} =
             GateServer.VoxelSmoke.run(
               logical_scene_id: logical_scene_id,
               observe_dir: observe_dir
             )

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

    assert gate_log =~ ~s(event="ws_voxel_chunk_subscribe_received")
    assert gate_log =~ ~s(event="voxel_subscription_window_planned")
    assert gate_log =~ "subscribe_count: 1"
    assert gate_log =~ "pressure: :normal"
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
end
