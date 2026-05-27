defmodule SceneServer.Worker.Aoi.RemoteMirrorRunnerTest do
  use ExUnit.Case, async: false

  alias SceneServer.Aoi.RemoteMirrorLedger
  alias SceneServer.CliObserve
  alias SceneServer.Worker.Aoi.RemoteMirrorRunner

  setup do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end)

    :ok
  end

  test "fetches each remote request group once and preserves grouped demand" do
    parent = self()
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    request_a = remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})
    request_b = remote_request(43, {:"scene-b@local", 200, {1, 0, 0}})
    RemoteMirrorLedger.replace_requests(42, [request_a], name)
    RemoteMirrorLedger.replace_requests(43, [request_b], name)

    assert %{
             status: :ok,
             group_count: 1,
             mirrored_group_count: 1,
             prewarmed_group_count: 0,
             failed_group_count: 0,
             ghost_group_count: 1,
             prewarm_group_count: 0,
             live_fanout_count: 0,
             demand_cid_count: 2,
             payload_bytes: 96,
             groups: [
               %{
                 status: :mirrored,
                 owner_scene_node: :"scene-b@local",
                 lease_id: 200,
                 chunk_coord: {1, 0, 0},
                 request_mode: :ghost,
                 request_cids: [42, 43],
                 cid_count: 2,
                 payload: %{
                   payload_bytes: 96,
                   actor_summary_count: 2,
                   field_summary_count: 1,
                   voxel_summary_version: 7
                 }
               }
             ]
           } =
             RemoteMirrorRunner.run_once(name,
               fetch_fun: fn group ->
                 send(parent, {:fetch_group, group.request_key, group.request_cids})

                 {:ok,
                  %{
                    payload_bytes: 96,
                    actor_summary_count: 2,
                    field_summary_count: 1,
                    voxel_summary_version: 7
                  }}
               end
             )

    assert_receive {:fetch_group, {:"scene-b@local", 200, {1, 0, 0}}, [42, 43]}
    refute_received {:fetch_group, _, _}

    assert %{total_request_count: 2, request_groups: [%{request_cids: [42, 43]}]} =
             RemoteMirrorLedger.snapshot(name)
  end

  test "dispatches prewarm request groups through the prewarm function" do
    parent = self()
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    request = remote_request(42, {:"scene-b@local", 200, {1, 0, 0}}, request_mode: :prewarm)
    RemoteMirrorLedger.replace_requests(42, [request], name)

    assert %{
             status: :ok,
             group_count: 1,
             ghost_group_count: 0,
             prewarm_group_count: 1,
             mirrored_group_count: 0,
             prewarmed_group_count: 1,
             failed_group_count: 0,
             live_fanout_count: 0,
             groups: [%{status: :prewarmed, request_mode: :prewarm}]
           } =
             RemoteMirrorRunner.run_once(name,
               fetch_fun: fn _group -> flunk("prewarm groups must not use fetch_fun") end,
               prewarm_fun: fn group ->
                 send(parent, {:prewarm_group, group.request_key, group.request_cids})
                 {:ok, %{payload_bytes: 64, actor_summary_count: 1}}
               end
             )

    assert_receive {:prewarm_group, {:"scene-b@local", 200, {1, 0, 0}}, [42]}
  end

  test "reports failed groups without clearing active remote mirror demand" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    request = remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})
    RemoteMirrorLedger.replace_requests(42, [request], name)

    assert %{
             status: :degraded,
             group_count: 1,
             mirrored_group_count: 0,
             prewarmed_group_count: 0,
             failed_group_count: 1,
             live_fanout_count: 0,
             demand_cid_count: 1,
             groups: [
               %{
                 status: :failed,
                 reason: :owner_unavailable,
                 request_cids: [42]
               }
             ]
           } =
             RemoteMirrorRunner.run_once(name,
               fetch_fun: fn _group -> {:error, :owner_unavailable} end
             )

    assert %{total_request_count: 1, request_groups: [%{request_cids: [42]}]} =
             RemoteMirrorLedger.snapshot(name)
  end

  test "continues later groups when one remote group fails" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    RemoteMirrorLedger.replace_requests(
      42,
      [remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})],
      name
    )

    RemoteMirrorLedger.replace_requests(
      43,
      [remote_request(43, {:"scene-c@local", 300, {2, 0, 0}})],
      name
    )

    assert %{
             status: :degraded,
             group_count: 2,
             mirrored_group_count: 1,
             failed_group_count: 1,
             demand_cid_count: 2,
             live_fanout_count: 0,
             groups: [
               %{status: :failed, owner_scene_node: :"scene-b@local", request_cids: [42]},
               %{status: :mirrored, owner_scene_node: :"scene-c@local", request_cids: [43]}
             ]
           } =
             RemoteMirrorRunner.run_once(name,
               fetch_fun: fn
                 %{owner_scene_node: :"scene-b@local"} -> {:error, :owner_unavailable}
                 %{owner_scene_node: :"scene-c@local"} -> {:ok, %{payload_bytes: 32}}
               end
             )

    assert %{total_request_count: 2, group_count: 2} = RemoteMirrorLedger.snapshot(name)
  end

  test "turns invalid adapter returns into observable group failures" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    RemoteMirrorLedger.replace_requests(
      42,
      [remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})],
      name
    )

    assert %{
             status: :degraded,
             mirrored_group_count: 0,
             failed_group_count: 1,
             groups: [
               %{
                 status: :failed,
                 reason: {:invalid_return, :unexpected_payload}
               }
             ]
           } =
             RemoteMirrorRunner.run_once(name,
               fetch_fun: fn _group -> :unexpected_payload end
             )
  end

  test "turns malformed successful payloads into observable group failures" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    RemoteMirrorLedger.replace_requests(
      42,
      [remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})],
      name
    )

    assert %{
             status: :degraded,
             mirrored_group_count: 0,
             failed_group_count: 1,
             payload_bytes: 0,
             groups: [
               %{
                 status: :failed,
                 reason: {:invalid_payload, :bad_payload}
               }
             ]
           } =
             RemoteMirrorRunner.run_once(name,
               fetch_fun: fn _group -> {:ok, :bad_payload} end
             )

    assert %{
             status: :degraded,
             mirrored_group_count: 0,
             failed_group_count: 1,
             groups: [
               %{
                 status: :failed,
                 reason: {:invalid_payload_field, :payload_bytes, "expected non-negative integer"}
               }
             ]
           } =
             RemoteMirrorRunner.run_once(name,
               fetch_fun: fn _group -> {:ok, %{payload_bytes: "128"}} end
             )
  end

  test "emits group and summary observe events for headless diagnostics" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "scene-remote-mirror-runner-#{System.unique_integer([:positive])}.log"
      )

    Application.put_env(:scene_server, :cli_observe_log, observe_log)
    File.rm(observe_log)

    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    RemoteMirrorLedger.replace_requests(
      42,
      [remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})],
      name
    )

    RemoteMirrorRunner.run_once(name,
      fetch_fun: fn _group -> {:ok, %{payload_bytes: 128, actor_summary_count: 3}} end
    )

    CliObserve.flush_path(observe_log)
    log = File.read!(observe_log)

    assert log =~ ~s(event="scene_remote_mirror_runner_started")
    assert log =~ ~s(event="scene_remote_mirror_group_completed")
    assert log =~ ~s(event="scene_remote_mirror_runner_completed")
    assert log =~ "status: :mirrored"
    assert log =~ "request_mode: :ghost"
    assert log =~ "owner_scene_node: :\"scene-b@local\""
    assert log =~ "request_cids: [%{cid: 42}]"
    assert log =~ "payload_bytes: 128"
    assert log =~ "mirrored_group_count: 1"
    assert log =~ "live_fanout_count: 0"
  end

  test "returns an idle summary for an empty ledger snapshot" do
    assert %{
             status: :idle,
             group_count: 0,
             mirrored_group_count: 0,
             prewarmed_group_count: 0,
             failed_group_count: 0,
             live_fanout_count: 0,
             demand_cid_count: 0,
             payload_bytes: 0,
             groups: []
           } =
             RemoteMirrorRunner.run_once(%{request_groups: []},
               fetch_fun: fn _group -> flunk("empty snapshots must not fetch") end
             )
  end

  defp remote_request(cid, request_key, opts \\ []) do
    {owner_scene_node, lease_id, chunk_coord} = request_key

    %{
      cid: cid,
      logical_scene_id: 7,
      center_chunk: {0, 0, 0},
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
      request_mode: Keyword.get(opts, :request_mode, :ghost),
      request_key: request_key,
      status: :planned,
      reason: :remote_halo_route
    }
  end

  defp unique_name do
    :"remote_mirror_ledger_#{System.unique_integer([:positive])}"
  end
end
