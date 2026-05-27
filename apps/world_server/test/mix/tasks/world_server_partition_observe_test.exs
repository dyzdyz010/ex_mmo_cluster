defmodule Mix.Tasks.WorldServer.PartitionObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    previous = Application.fetch_env(:world_server, :cli_observe_log)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:world_server, :cli_observe_log, value)
        :error -> Application.delete_env(:world_server, :cli_observe_log)
      end
    end)

    :ok
  end

  test "prints and logs a world partition routing window" do
    observe_log = observe_log_path("partition-observe")

    output =
      capture_io(fn ->
        Mix.Tasks.WorldServer.PartitionObserve.run([
          "--logical-scene-id",
          "91",
          "--center",
          "1,0,0",
          "--near-radius",
          "0",
          "--halo-radius",
          "1",
          "--near-vertical-radius",
          "0",
          "--halo-vertical-radius",
          "0",
          "--observe-log",
          observe_log
        ])
      end)

    assert output =~ "world_partition_window=ok"
    assert output =~ "logical_scene_id=91"
    assert output =~ "center=1,0,0"
    assert output =~ "near_radius=0"
    assert output =~ "halo_radius=1"
    assert output =~ "near=1"
    assert output =~ "halo=8"
    assert output =~ "near_vertical_radius=0"
    assert output =~ "halo_vertical_radius=0"
    assert output =~ "regions=2"
    assert output =~ "route_index_source=map_ledger"
    assert output =~ "route_index_strategy=scene_bucket_grid_v1"
    assert output =~ "route_index_scenes=1"
    assert output =~ "route_index_regions=2"
    assert output =~ "observe_log=#{observe_log}"

    assert File.exists?(observe_log)

    lines = File.read!(observe_log) |> String.split("\n", trim: true)
    assert Enum.any?(lines, &String.contains?(&1, ~s(event="world_partition_window")))
    assert Enum.any?(lines, &String.contains?(&1, "logical_scene_id: 91"))
    assert Enum.any?(lines, &String.contains?(&1, "near_count: 1"))
    assert Enum.any?(lines, &String.contains?(&1, "halo_count: 8"))
    assert Enum.any?(lines, &String.contains?(&1, "region_count: 2"))
    assert Enum.any?(lines, &String.contains?(&1, "missing_count: 3"))
    assert Enum.any?(lines, &String.contains?(&1, "near_vertical_radius: 0"))
    assert Enum.any?(lines, &String.contains?(&1, "halo_vertical_radius: 0"))
    assert Enum.any?(lines, &String.contains?(&1, "route_index_stats:"))
    assert Enum.any?(lines, &String.contains?(&1, "strategy: :scene_bucket_grid_v1"))
    assert Enum.any?(lines, &String.contains?(&1, "route_index_source: :map_ledger"))

    partition_line = Enum.find(lines, &String.contains?(&1, ~s(event="world_partition_window")))

    assert partition_line =~ "route_entries:"
    assert partition_line =~ "chunk_coord: [1, 0, 0]"
    assert partition_line =~ "tier: :near"
    assert partition_line =~ "status: :assigned"
    assert partition_line =~ "region_id: 20"
    assert partition_line =~ "chunk_coord: [2, 0, 0]"
    assert partition_line =~ "status: :missing"
  end

  test "defaults old partition observe CLI invocations to cube semantics" do
    observe_log = observe_log_path("partition-observe-cube-default")

    output =
      capture_io(fn ->
        Mix.Tasks.WorldServer.PartitionObserve.run([
          "--logical-scene-id",
          "93",
          "--center",
          "1,0,0",
          "--near-radius",
          "0",
          "--halo-radius",
          "1",
          "--observe-log",
          observe_log
        ])
      end)

    assert output =~ "near_radius=0"
    assert output =~ "halo_radius=1"
    assert output =~ "near_vertical_radius=0"
    assert output =~ "halo_vertical_radius=1"
    assert output =~ "near=1"
    assert output =~ "halo=26"
    assert output =~ "missing=9"

    lines = File.read!(observe_log) |> String.split("\n", trim: true)
    assert Enum.any?(lines, &String.contains?(&1, "halo_vertical_radius: 1"))
    assert Enum.any?(lines, &String.contains?(&1, "halo_count: 26"))
  end

  test "restores previous observe log when the smoke run fails" do
    previous_log = observe_log_path("previous-observe-log")
    observe_log = observe_log_path("partition-observe-failure")
    Application.put_env(:world_server, :cli_observe_log, previous_log)

    assert_raise Mix.Error, ~r/near_radius/, fn ->
      Mix.Tasks.WorldServer.PartitionObserve.run([
        "--logical-scene-id",
        "91",
        "--near-radius",
        "-1",
        "--observe-log",
        observe_log
      ])
    end

    assert Application.fetch_env(:world_server, :cli_observe_log) == {:ok, previous_log}
  end

  defp observe_log_path(name) do
    dir = Path.join(System.tmp_dir!(), "world_server_partition_observe_test")
    File.mkdir_p!(dir)

    path = Path.join(dir, "#{name}-#{System.unique_integer([:positive])}.log")
    File.rm(path)
    path
  end
end
