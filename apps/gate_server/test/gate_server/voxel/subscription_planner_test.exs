defmodule GateServer.Voxel.SubscriptionPlannerTest do
  use ExUnit.Case, async: true

  alias GateServer.Voxel.SubscriptionPlanner
  alias WorldServer.Voxel.PartitionWindow

  test "plans assigned near and halo subscriptions while exposing skipped routes" do
    lease = %{
      logical_scene_id: 11,
      region_id: 10,
      lease_id: 101,
      owner_scene_instance_ref: 1_001,
      owner_epoch: 2,
      expires_at_ms: 9_999,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {2, 1, 1}
    }

    window =
      PartitionWindow.build(11, {0, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {0, 0, 0} => %{
          region_id: 10,
          lease_id: 101,
          lease: lease,
          assigned_scene_node: :"scene-a@local"
        },
        {1, 0, 0} => %{
          region_id: 10,
          lease_id: 101,
          lease: lease,
          assigned_scene_node: :"scene-a@local"
        },
        {-1, 0, 0} => %{
          region_id: 20,
          assigned_scene_node: :"scene-b@local",
          status: :region_without_lease
        }
      })

    plan =
      SubscriptionPlanner.plan(%{
        cid: 42,
        request_id: 99,
        partition_window: window,
        known_versions: %{{1, 0, 0} => 7},
        stream_caps: %{
          reliable_control: 128,
          voxel_snapshot: 512,
          voxel_delta: 128,
          field_state: 128,
          recovery: 128
        }
      })

    assert plan.summary.cid == 42
    assert plan.summary.request_id == 99
    assert plan.summary.logical_scene_id == 11
    assert plan.summary.center_chunk == {0, 0, 0}
    assert plan.summary.near_radius == 0
    assert plan.summary.halo_radius == 1
    assert plan.summary.pressure == :normal
    assert plan.summary.requested_chunk_count == 27
    assert plan.summary.assigned_chunk_count == 2
    assert plan.summary.unleased_chunk_count == 1
    assert plan.summary.missing_chunk_count == 24
    assert plan.summary.subscribe_count == 2
    assert plan.summary.skipped_count == 25

    assert [
             %{
               chunk_coord: {0, 0, 0},
               tier: :near,
               priority: :critical,
               lease: ^lease,
               known_version: 0,
               send_snapshot?: true
             },
             %{
               chunk_coord: {1, 0, 0},
               tier: :halo,
               priority: :opportunistic,
               lease: ^lease,
               known_version: 7,
               send_snapshot?: false
             }
           ] = plan.subscribe_entries

    assert Enum.any?(
             plan.skipped_entries,
             &match?(%{chunk_coord: {-1, 0, 0}, reason: :missing_lease}, &1)
           )

    assert Enum.any?(plan.skipped_entries, &(&1.reason == :missing_route))
    assert plan.sync_budget.window_summary.assigned_chunk_count == 2
  end

  test "preserves clipped interest shape in planner and sync-budget summaries" do
    lease = %{
      logical_scene_id: 12,
      region_id: 10,
      lease_id: 101,
      owner_scene_instance_ref: 1_001,
      owner_epoch: 2,
      expires_at_ms: 9_999,
      bounds_chunk_min: {-2, -2, -1},
      bounds_chunk_max: {2, 2, 1}
    }

    window =
      PartitionWindow.build(12, {0, 0, 0},
        near_radius: 1,
        halo_radius: 2,
        near_vertical_radius: 0,
        halo_vertical_radius: 1
      )
      |> PartitionWindow.attach_routes(%{
        {0, 0, 0} => %{
          region_id: 10,
          lease_id: 101,
          lease: lease,
          assigned_scene_node: :"scene-a@local"
        },
        {2, 0, 0} => %{
          region_id: 10,
          lease_id: 101,
          lease: lease,
          assigned_scene_node: :"scene-a@local"
        }
      })

    plan =
      SubscriptionPlanner.plan(%{
        cid: 43,
        request_id: 100,
        partition_window: window,
        stream_caps: %{
          reliable_control: 128,
          voxel_snapshot: 512,
          voxel_delta: 128,
          field_state: 128,
          recovery: 128
        }
      })

    assert plan.summary.near_radius == 1
    assert plan.summary.halo_radius == 2
    assert plan.summary.near_vertical_radius == 0
    assert plan.summary.halo_vertical_radius == 1
    assert plan.summary.requested_chunk_count == 75
    assert length(plan.partition_window.near_chunks) == 9
    assert length(plan.partition_window.halo_chunks) == 66

    assert plan.sync_budget.window_summary.near_radius == 1
    assert plan.sync_budget.window_summary.halo_radius == 2
    assert plan.sync_budget.window_summary.near_vertical_radius == 0
    assert plan.sync_budget.window_summary.halo_vertical_radius == 1
    assert plan.sync_budget.window_summary.near_chunk_count == 9
    assert plan.sync_budget.window_summary.halo_chunk_count == 66
  end

  test "degrades halo subscriptions to ghost when full initial snapshot budget is unavailable" do
    lease = %{
      logical_scene_id: 13,
      region_id: 10,
      lease_id: 101,
      owner_scene_instance_ref: 1_001,
      owner_epoch: 2,
      expires_at_ms: 9_999,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {2, 1, 1}
    }

    window =
      PartitionWindow.build(13, {0, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {0, 0, 0} => %{
          region_id: 10,
          lease_id: 101,
          lease: lease,
          assigned_scene_node: :"scene-a@local"
        },
        {1, 0, 0} => %{
          region_id: 10,
          lease_id: 101,
          lease: lease,
          assigned_scene_node: :"scene-a@local"
        }
      })

    plan =
      SubscriptionPlanner.plan(%{
        cid: 42,
        request_id: 99,
        partition_window: window,
        snapshot_estimate_bytes: 128,
        stream_caps: %{
          reliable_control: 128,
          voxel_snapshot: 128,
          voxel_delta: 0,
          field_state: 0,
          recovery: 0
        }
      })

    near = Enum.find(plan.subscribe_entries, &(&1.chunk_coord == {0, 0, 0}))
    halo = Enum.find(plan.subscribe_entries, &(&1.chunk_coord == {1, 0, 0}))

    assert near.send_snapshot? == true
    assert near.initial_delivery_mode == :authoritative_snapshot
    assert near.snapshot_defer_reason == nil

    assert halo.send_snapshot? == false
    assert halo.initial_delivery_mode == :halo_ghost
    assert halo.snapshot_defer_reason == :snapshot_budget_exhausted
    assert halo.requested_bytes.voxel_snapshot == 128
    assert halo.budget_bytes.voxel_snapshot == 0

    assert plan.summary.initial_snapshot_count == 1
    assert plan.summary.ghost_subscription_count == 1
  end

  test "rejects an assigned route without a lease token" do
    window =
      PartitionWindow.build(12, {0, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {0, 0, 0} => %{
          status: :assigned,
          region_id: 10,
          lease_id: 101,
          assigned_scene_node: :"scene-a@local"
        }
      })

    assert_raise ArgumentError, ~r/lease/, fn ->
      SubscriptionPlanner.plan(%{
        cid: 42,
        request_id: 99,
        partition_window: window
      })
    end
  end
end
