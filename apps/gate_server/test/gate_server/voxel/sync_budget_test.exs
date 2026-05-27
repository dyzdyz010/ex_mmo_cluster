defmodule GateServer.Voxel.SyncBudgetTest do
  use ExUnit.Case, async: true

  alias GateServer.Voxel.SyncBudget
  alias WorldServer.Voxel.PartitionWindow

  test "assigns near before halo and never allocates to missing chunks" do
    window =
      PartitionWindow.build(1, {0, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {0, 0, 0} => %{region_id: 10, lease_id: 101, assigned_scene_node: :"scene-a@local"},
        {1, 0, 0} => %{region_id: 20, lease_id: 202, assigned_scene_node: :"scene-b@local"},
        {-1, 0, 0} => %{
          region_id: 30,
          assigned_scene_node: :"scene-c@local",
          status: :region_without_lease
        }
      })

    plan =
      SyncBudget.plan(
        cid: "cid-1",
        partition_window: window,
        stream_caps: %{
          reliable_control: 64,
          voxel_snapshot: 80,
          voxel_delta: 40,
          field_state: 20,
          recovery: 16
        },
        chunk_backlogs: %{
          {0, 0, 0} => %{snapshot_bytes: 60, field_bytes: 10, known_version: 0, server_version: 2},
          {1, 0, 0} => %{snapshot_bytes: 60, field_bytes: 10, known_version: 0, server_version: 2},
          {0, 1, 0} => %{
            snapshot_bytes: 999,
            field_bytes: 999,
            known_version: 0,
            server_version: 9
          }
        }
      )

    assert plan.cid == "cid-1"
    assert plan.pressure == :congested
    assert plan.window_summary.assigned_chunk_count == 2
    assert plan.window_summary.unleased_chunk_count == 1
    assert plan.window_summary.missing_chunk_count == 24
    assert Enum.take(Enum.map(plan.chunk_plans, & &1.tier), 1) == [:near]
    assert Enum.all?(Enum.drop(plan.chunk_plans, 1), &(&1.tier == :halo))

    near_plan = find_chunk_plan(plan, {0, 0, 0})
    halo_plan = find_chunk_plan(plan, {1, 0, 0})
    missing_plan = find_chunk_plan(plan, {0, 1, 0})
    unleased_plan = find_chunk_plan(plan, {-1, 0, 0})

    assert near_plan.budget_bytes.voxel_snapshot == 60
    assert near_plan.budget_bytes.field_state == 10
    assert near_plan.priority == :critical
    assert halo_plan.budget_bytes.voxel_snapshot == 20
    assert halo_plan.budget_bytes.field_state == 10
    assert halo_plan.priority == :opportunistic
    assert missing_plan.reason == :missing_route
    assert missing_plan.priority == :none
    assert missing_plan.requested_bytes == zero_budget_bytes()
    assert missing_plan.budget_bytes == zero_budget_bytes()
    assert unleased_plan.reason == :missing_lease
    assert unleased_plan.priority == :none
    assert unleased_plan.requested_bytes == zero_budget_bytes()
    assert unleased_plan.budget_bytes == zero_budget_bytes()
    assert plan.budget_usage.voxel_snapshot.allocated_bytes == 80
  end

  test "enters recovery pressure and allocates recovery budget when seq gap exists" do
    window =
      PartitionWindow.build(1, {0, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {0, 0, 0} => %{region_id: 10, lease_id: 101, assigned_scene_node: :"scene-a@local"},
        {1, 0, 0} => %{region_id: 20, lease_id: 202, assigned_scene_node: :"scene-b@local"}
      })

    plan =
      SyncBudget.plan(%{
        cid: "cid-2",
        partition_window: window,
        last_server_seq: 12,
        last_client_ack_seq: 8,
        recovery_request_count: 1,
        stream_caps: %{
          reliable_control: 64,
          voxel_snapshot: 32,
          voxel_delta: 16,
          field_state: 16,
          recovery: 48
        },
        chunk_backlogs: %{
          {0, 0, 0} => %{
            recovery_bytes: 40,
            snapshot_bytes: 20,
            known_version: 0,
            server_version: 5
          },
          {1, 0, 0} => %{
            recovery_bytes: 40,
            snapshot_bytes: 20,
            known_version: 0,
            server_version: 5
          }
        }
      })

    near_plan = find_chunk_plan(plan, {0, 0, 0})
    halo_plan = find_chunk_plan(plan, {1, 0, 0})

    assert plan.pressure == :recovery
    assert plan.counters.seq_gap == 4
    assert near_plan.budget_bytes.recovery == 40
    assert halo_plan.budget_bytes.recovery == 8
    assert plan.budget_usage.recovery.allocated_bytes == 48
    assert plan.budget_usage.recovery.remaining_bytes == 0
  end

  test "returns deterministic output ordering regardless of backlog input order" do
    window =
      PartitionWindow.build(1, {0, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => %{region_id: 20, lease_id: 202, assigned_scene_node: :"scene-b@local"},
        {-1, 0, 0} => %{region_id: 10, lease_id: 101, assigned_scene_node: :"scene-a@local"},
        {0, 0, 0} => %{region_id: 30, lease_id: 303, assigned_scene_node: :"scene-c@local"}
      })

    attrs = fn backlogs ->
      %{
        cid: "cid-3",
        partition_window: window,
        stream_caps: %{voxel_snapshot: 64, voxel_delta: 16, field_state: 8, recovery: 8},
        chunk_backlogs: backlogs
      }
    end

    plan_a =
      SyncBudget.plan(
        attrs.([
          %{chunk_coord: {1, 0, 0}, snapshot_bytes: 10, known_version: 0, server_version: 1},
          %{chunk_coord: {0, 0, 0}, snapshot_bytes: 20, known_version: 0, server_version: 1},
          %{chunk_coord: {-1, 0, 0}, snapshot_bytes: 30, known_version: 0, server_version: 1}
        ])
      )

    plan_b =
      SyncBudget.plan(
        attrs.([
          %{chunk_coord: {-1, 0, 0}, snapshot_bytes: 30, known_version: 0, server_version: 1},
          %{chunk_coord: {1, 0, 0}, snapshot_bytes: 10, known_version: 0, server_version: 1},
          %{chunk_coord: {0, 0, 0}, snapshot_bytes: 20, known_version: 0, server_version: 1}
        ])
      )

    assert plan_a == plan_b

    assert Enum.take(Enum.map(plan_a.chunk_plans, & &1.chunk_coord), 4) == [
             {0, 0, 0},
             {-1, -1, -1},
             {-1, -1, 0},
             {-1, -1, 1}
           ]
  end

  test "rejects invalid caps and counters" do
    window = PartitionWindow.build(1, {0, 0, 0}, near_radius: 0, halo_radius: 0)

    assert_raise ArgumentError, ~r/voxel_snapshot/, fn ->
      SyncBudget.plan(
        cid: "cid-4",
        partition_window: window,
        stream_caps: %{voxel_snapshot: -1}
      )
    end

    assert_raise ArgumentError, ~r/fast_lane_pending_bytes/, fn ->
      SyncBudget.plan(
        cid: "cid-4",
        partition_window: window,
        fast_lane_pending_bytes: -10
      )
    end
  end

  test "rejects duplicate chunk backlog entries" do
    window = PartitionWindow.build(1, {0, 0, 0}, near_radius: 0, halo_radius: 0)

    assert_raise ArgumentError, ~r/duplicate chunk backlog/, fn ->
      SyncBudget.plan(
        cid: "cid-5",
        partition_window: window,
        chunk_backlogs: [
          %{chunk_coord: {0, 0, 0}, snapshot_bytes: 10},
          %{chunk_coord: {0, 0, 0}, snapshot_bytes: 20}
        ]
      )
    end
  end

  defp find_chunk_plan(plan, chunk_coord) do
    Enum.find(plan.chunk_plans, &(&1.chunk_coord == chunk_coord))
  end

  defp zero_budget_bytes do
    %{
      recovery: 0,
      voxel_snapshot: 0,
      voxel_delta: 0,
      field_state: 0
    }
  end
end
