defmodule SceneServer.Aoi.PriorityTest do
  use ExUnit.Case, async: true

  alias SceneServer.Aoi.Priority
  alias SceneServer.Movement.RemoteSnapshot

  test "build_targets classifies observers by distance and sorts nearest first" do
    targets =
      [
        %{cid: 3, aoi_pid: self(), location: {450.0, 0.0, 0.0}},
        %{cid: 1, aoi_pid: self(), location: {50.0, 0.0, 0.0}},
        %{cid: 2, aoi_pid: self(), location: {250.0, 0.0, 0.0}}
      ]
      |> Priority.build_targets({0.0, 0.0, 0.0}, 500)

    assert Enum.map(targets, & &1.cid) == [1, 2, 3]
    assert Enum.map(targets, & &1.priority_band) == [:high, :medium, :low]
    assert Enum.map(targets, & &1.delivery_interval) == [1, 2, 5]
  end

  test "due? throttles low priority snapshots but always sends stop snapshots" do
    low_target = %{
      cid: 2,
      aoi_pid: self(),
      location: {450.0, 0.0, 0.0},
      distance: 450.0,
      priority_band: :low,
      priority_score: 0.1,
      delivery_interval: 5
    }

    moving = snapshot(1, {10.0, 0.0, 0.0})
    stopped = snapshot(1, {0.0, 0.0, 0.0})

    refute Priority.due?(moving, low_target)
    assert Priority.due?(%{moving | server_tick: 5}, low_target)
    assert Priority.due?(stopped, low_target)
  end

  test "decorate_snapshot attaches observer-specific AOI metadata" do
    target = %{
      cid: 2,
      aoi_pid: self(),
      location: {100.0, 0.0, 0.0},
      distance: 100.0,
      priority_band: :high,
      priority_score: 0.8,
      delivery_interval: 1
    }

    decorated = Priority.decorate_snapshot(snapshot(7, {1.0, 0.0, 0.0}), target)

    assert decorated.priority_band == :high
    assert decorated.priority_score == 0.8
    assert decorated.observer_distance == 100.0
    assert decorated.delivery_interval == 1
  end

  defp snapshot(tick, velocity) do
    %RemoteSnapshot{
      cid: 1,
      server_tick: tick,
      position: {0.0, 0.0, 0.0},
      velocity: velocity,
      acceleration: {0.0, 0.0, 0.0},
      movement_mode: :grounded
    }
  end
end
