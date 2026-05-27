defmodule Mix.Tasks.GateServer.SyncBudgetObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    previous_gate = Application.fetch_env(:gate_server, :cli_observe_log)
    previous_world = Application.fetch_env(:world_server, :cli_observe_log)

    on_exit(fn ->
      restore_env(:gate_server, previous_gate)
      restore_env(:world_server, previous_world)
    end)

    :ok
  end

  test "prints and logs a gate sync budget window" do
    gate_observe_log = observe_log_path("gate-sync-budget")
    world_observe_log = observe_log_path("world-sync-budget")

    output =
      capture_io(fn ->
        Mix.Tasks.GateServer.SyncBudgetObserve.run([
          "--logical-scene-id",
          "92",
          "--cid",
          "77",
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
          "--gate-observe-log",
          gate_observe_log,
          "--world-observe-log",
          world_observe_log
        ])
      end)

    assert output =~ "gate_sync_budget=ok"
    assert output =~ "logical_scene_id=92"
    assert output =~ "cid=77"
    assert output =~ "pressure=recovery"
    assert output =~ "near_radius=0"
    assert output =~ "halo_radius=1"
    assert output =~ "near=1"
    assert output =~ "halo=8"
    assert output =~ "near_vertical_radius=0"
    assert output =~ "halo_vertical_radius=0"
    assert output =~ "assigned=6"
    assert output =~ "unleased=0"
    assert output =~ "missing=3"
    assert output =~ "gate_observe_log=#{gate_observe_log}"

    assert File.exists?(gate_observe_log)

    lines = File.read!(gate_observe_log) |> String.split("\n", trim: true)
    budget_line = Enum.find(lines, &String.contains?(&1, ~s(event="gate_sync_budget_window")))

    assert budget_line =~ "seq_gap: 8"
    assert budget_line =~ "recovery_request_count: 1"
    assert budget_line =~ "assigned_chunk_count: 6"
    assert budget_line =~ "unleased_chunk_count: 0"
    assert budget_line =~ "halo_radius: 1"
    assert budget_line =~ "near_vertical_radius: 0"
    assert budget_line =~ "halo_vertical_radius: 0"
    assert budget_line =~ "chunk_plans:"
    assert budget_line =~ "chunk_coord: [1, 0, 0]"
    assert budget_line =~ "tier: :near"
    assert budget_line =~ "priority: :critical"
    assert budget_line =~ "recovery_budget_bytes:"
    assert budget_line =~ "reason: :missing_route"
  end

  test "defaults old sync budget observe CLI invocations to cube semantics" do
    gate_observe_log = observe_log_path("gate-sync-budget-cube-default")
    world_observe_log = observe_log_path("world-sync-budget-cube-default")

    output =
      capture_io(fn ->
        Mix.Tasks.GateServer.SyncBudgetObserve.run([
          "--logical-scene-id",
          "94",
          "--cid",
          "78",
          "--center",
          "1,0,0",
          "--near-radius",
          "0",
          "--halo-radius",
          "1",
          "--gate-observe-log",
          gate_observe_log,
          "--world-observe-log",
          world_observe_log
        ])
      end)

    assert output =~ "near_radius=0"
    assert output =~ "halo_radius=1"
    assert output =~ "near_vertical_radius=0"
    assert output =~ "halo_vertical_radius=1"
    assert output =~ "near=1"
    assert output =~ "halo=26"
    assert output =~ "assigned=18"
    assert output =~ "missing=9"

    lines = File.read!(gate_observe_log) |> String.split("\n", trim: true)
    budget_line = Enum.find(lines, &String.contains?(&1, ~s(event="gate_sync_budget_window")))

    assert budget_line =~ "halo_vertical_radius: 1"
    assert budget_line =~ "halo_chunk_count: 26"
    assert budget_line =~ "assigned_chunk_count: 18"
  end

  test "restores observe log env after invalid CLI options" do
    previous_gate_log = observe_log_path("previous-gate")
    previous_world_log = observe_log_path("previous-world")
    gate_observe_log = observe_log_path("gate-sync-budget-failure")

    Application.put_env(:gate_server, :cli_observe_log, previous_gate_log)
    Application.put_env(:world_server, :cli_observe_log, previous_world_log)

    assert_raise Mix.Error, ~r/near_radius/, fn ->
      Mix.Tasks.GateServer.SyncBudgetObserve.run([
        "--near-radius",
        "-1",
        "--gate-observe-log",
        gate_observe_log
      ])
    end

    assert Application.fetch_env(:gate_server, :cli_observe_log) == {:ok, previous_gate_log}
    assert Application.fetch_env(:world_server, :cli_observe_log) == {:ok, previous_world_log}
  end

  defp observe_log_path(name) do
    dir = Path.join(System.tmp_dir!(), "gate_server_sync_budget_observe_test")
    File.mkdir_p!(dir)

    path = Path.join(dir, "#{name}-#{System.unique_integer([:positive])}.log")
    File.rm(path)
    path
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)
end
