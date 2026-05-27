defmodule Mix.Tasks.SceneServerAoiPartitionObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SceneServer.CliObserve

  test "prints and logs a partition-derived AOI interest plan" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "scene-aoi-partition-observe-#{System.unique_integer([:positive])}.log"
      )

    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    try do
      File.rm(observe_log)

      output =
        capture_io(fn ->
          Mix.Tasks.SceneServer.AoiPartitionObserve.run([
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

      assert output =~ "scene_aoi_partition_interest=ok"
      assert output =~ "logical_scene_id=7"
      assert output =~ "cid=42"
      assert output =~ "center=0,0,0"
      assert output =~ "near_queries=1"
      assert output =~ "halo_queries=1"
      assert output =~ "skipped=2"
      assert output =~ "missing=1"
      assert output =~ "unleased=1"
      assert output =~ "remote_mirror_requests=1"
      assert output =~ "observe_log=#{observe_log}"

      CliObserve.flush_path(observe_log)
      log = File.read!(observe_log)
      assert log =~ ~s(event="scene_aoi_partition_interest_planned")
      assert log =~ "near_query_count: 1"
      assert log =~ "halo_query_count: 1"
      assert log =~ "skipped_count: 2"
      assert log =~ "missing_count: 1"
      assert log =~ "unleased_count: 1"
      assert log =~ "remote_mirror_request_count: 1"
      assert log =~ "remote_mirror_requests:"
      assert log =~ "requester_scene_node: :\"scene-a@local\""
      assert log =~ "owner_scene_node: :\"scene-b@local\""
      assert log =~ "request_mode: :ghost"
      assert log =~ "status: :planned"
      assert log =~ "reason: :remote_halo_route"
      assert log =~ "region_query_summaries:"
      assert log =~ "assigned_scene_node: :\"scene-a@local\""
      assert log =~ "near_count: 1"
      assert log =~ "halo_count: 1"
    after
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end
  end
end
