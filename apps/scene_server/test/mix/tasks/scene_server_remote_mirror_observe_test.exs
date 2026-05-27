defmodule Mix.Tasks.SceneServerRemoteMirrorObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SceneServer.Aoi.RemoteMirrorLedger
  alias SceneServer.CliObserve

  test "prints and logs the remote mirror ledger state" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "scene-remote-mirror-observe-#{System.unique_integer([:positive])}.log"
      )

    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    try do
      {:ok, _apps} = Application.ensure_all_started(:scene_server)
      :ok = RemoteMirrorLedger.reset()
      sentinel_request = remote_request(9001, {:"live-scene@local", 900, {9, 0, 0}})
      RemoteMirrorLedger.replace_requests(9001, [sentinel_request])

      File.rm(observe_log)

      output =
        capture_io(fn ->
          Mix.Tasks.SceneServer.RemoteMirrorObserve.run([
            "--observe-log",
            observe_log,
            "--logical-scene-id",
            "7",
            "--cid",
            "42",
            "--center",
            "0,0,0"
          ])
        end)

      assert output =~ "scene_remote_mirror_ledger=ok"
      assert output =~ "scene_remote_mirror_runner=ok"
      assert output =~ "logical_scene_id=7"
      assert output =~ "cid=42"
      assert output =~ "active_requests=2"
      assert output =~ "ghost_groups=1"
      assert output =~ "prewarm_groups=0"
      assert output =~ "mirrored_groups=1"
      assert output =~ "prewarmed_groups=0"
      assert output =~ "failed_groups=0"
      assert output =~ "live_fanout=0"
      assert output =~ "mirror_payload_bytes=128"
      assert output =~ "owners=1"
      assert output =~ "groups=1"
      assert output =~ "cids=2"
      assert output =~ "observe_log=#{observe_log}"

      CliObserve.flush_path(observe_log)
      log = File.read!(observe_log)
      assert log =~ ~s(event="scene_remote_mirror_ledger_updated")
      assert log =~ ~s(event="scene_remote_mirror_ledger_snapshot")
      assert log =~ ~s(event="scene_remote_mirror_runner_started")
      assert log =~ ~s(event="scene_remote_mirror_group_completed")
      assert log =~ ~s(event="scene_remote_mirror_runner_completed")
      assert log =~ "logical_scene_id: 7"
      assert log =~ "total_request_count: 2"
      assert log =~ "ghost_group_count: 1"
      assert log =~ "prewarm_group_count: 0"
      assert log =~ "mirrored_group_count: 1"
      assert log =~ "prewarmed_group_count: 0"
      assert log =~ "failed_group_count: 0"
      assert log =~ "live_fanout_count: 0"
      assert log =~ "payload_bytes: 128"
      assert log =~ "owner_scene_count: 1"
      assert log =~ "group_count: 1"
      assert log =~ "request_cids: [%{cid: 42}, %{cid: 43}]"
      assert log =~ "request_mode: :ghost"
      assert log =~ "owner_scene_node: :\"scene-b@local\""
      assert log =~ "request_key:"

      assert %{
               total_request_count: 1,
               request_groups: [
                 %{owner_scene_node: :"live-scene@local", request_cids: [9001]}
               ]
             } = RemoteMirrorLedger.snapshot()
    after
      RemoteMirrorLedger.reset()
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end
  end

  defp remote_request(cid, request_key) do
    {owner_scene_node, lease_id, chunk_coord} = request_key

    %{
      cid: cid,
      logical_scene_id: 99,
      center_chunk: {9, 0, 0},
      requester_scene_node: :"scene-a@local",
      owner_scene_node: owner_scene_node,
      chunk_coord: chunk_coord,
      tier: :halo,
      region_id: lease_id,
      lease_id: lease_id,
      assigned_scene_node: owner_scene_node,
      query_scope: :halo_ghost,
      priority_band: :low,
      delivery_interval: 5,
      request_mode: :ghost,
      request_key: request_key,
      status: :planned,
      reason: :remote_halo_route
    }
  end
end
