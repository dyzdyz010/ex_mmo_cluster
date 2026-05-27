defmodule GateServer.PartitionContextTest do
  use ExUnit.Case, async: true

  alias GateServer.PartitionContext
  alias WorldServer.Voxel.PartitionWindow

  test "returns no changes when authoritative movement stays inside the same chunk" do
    previous_context = %{
      logical_scene_id: 1,
      chunk_coord: {0, 0, 0},
      region_id: 10
    }

    assert {:ok, result} =
             PartitionContext.resolve(%{
               cid: 42,
               logical_scene_id: 1,
               authoritative_location: {1_200.0, 100.0, 50.0},
               previous_context: previous_context
             })

    assert result.boundary_kind == :none
    assert result.chunk_coord == {0, 0, 0}
    assert result.region_id == 10
    assert result.subscription_plan == nil

    assert result.subscription_diff == %{
             subscribe_chunks: [],
             unsubscribe_chunks: [],
             retained_chunks: []
           }

    assert result.chat_presence == nil
  end

  test "plans subscription diff and chat chunk refresh when crossing chunks inside one region" do
    lease = lease(10, 100)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(10, lease),
        {0, 0, 0} => assigned_route(10, lease)
      })

    assert {:ok, result} =
             PartitionContext.resolve(%{
               cid: 42,
               request_id: 77,
               logical_scene_id: 1,
               authoritative_location: {1_650.0, 100.0, 50.0},
               previous_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
               partition_window: window,
               current_subscriptions: %{{1, {0, 0, 0}} => %{chunk_coord: {0, 0, 0}}}
             })

    assert result.boundary_kind == :chunk
    assert result.chunk_coord == {1, 0, 0}
    assert result.region_id == 10

    assert result.chat_presence == %{
             logical_scene_id: 1,
             region_id: 10,
             chunk_coord: {1, 0, 0},
             location: {1_650.0, 100.0, 50.0}
           }

    assert result.subscription_diff.retained_chunks == [{0, 0, 0}]
    assert {1, 0, 0} in result.subscription_diff.subscribe_chunks
    assert result.summary.subscribe_count == 1
    assert result.summary.retained_count == 1
  end

  test "ignores current subscriptions from other logical scenes when diffing movement refresh" do
    lease = lease(10, 100)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(10, lease)
      })

    assert {:ok, result} =
             PartitionContext.resolve(%{
               cid: 42,
               request_id: 77,
               logical_scene_id: 1,
               authoritative_location: {1_650.0, 100.0, 50.0},
               previous_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
               partition_window: window,
               current_subscriptions: %{
                 {2, {1, 0, 0}} => %{logical_scene_id: 2, chunk_coord: {1, 0, 0}},
                 {1, {0, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {0, 0, 0}}
               }
             })

    assert result.subscription_diff.subscribe_chunks == [{1, 0, 0}]
    assert result.subscription_diff.retained_chunks == []
    assert result.subscription_diff.unsubscribe_chunks == [{0, 0, 0}]
  end

  test "keeps near chunk authoritative while degrading over-budget halo to ghost prewarm" do
    lease = lease(10, 100)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(10, lease),
        {0, 0, 0} => assigned_route(10, lease)
      })

    assert {:ok, result} =
             PartitionContext.resolve(%{
               cid: 42,
               request_id: 77,
               logical_scene_id: 1,
               authoritative_location: {1_650.0, 100.0, 50.0},
               previous_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
               partition_window: window,
               current_subscriptions: %{},
               snapshot_estimate_bytes: 128,
               stream_caps: %{
                 reliable_control: 128,
                 voxel_snapshot: 128,
                 voxel_delta: 0,
                 field_state: 0,
                 recovery: 0
               }
             })

    near = Enum.find(result.subscription_plan.subscribe_entries, &(&1.chunk_coord == {1, 0, 0}))
    halo = Enum.find(result.subscription_plan.subscribe_entries, &(&1.chunk_coord == {0, 0, 0}))

    assert near.initial_delivery_mode == :authoritative_snapshot
    assert near.send_snapshot? == true
    assert halo.initial_delivery_mode == :halo_ghost
    assert halo.send_snapshot? == false
    assert halo.snapshot_defer_reason == :snapshot_budget_exhausted
    assert result.subscription_plan.summary.initial_snapshot_count == 1
    assert result.subscription_plan.summary.ghost_subscription_count == 1
  end

  test "marks region boundary and refreshes chat region from the World center route" do
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {2, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {2, 0, 0} => assigned_route(20, lease)
      })

    assert {:ok, result} =
             PartitionContext.resolve(%{
               cid: 42,
               logical_scene_id: 1,
               authoritative_location: {3_250.0, 100.0, 50.0},
               previous_context: %{logical_scene_id: 1, chunk_coord: {1, 0, 0}, region_id: 10},
               partition_window: window
             })

    assert result.boundary_kind == :region
    assert result.previous_region_id == 10
    assert result.region_id == 20
    assert result.chat_presence.region_id == 20
    assert result.chat_presence.chunk_coord == {2, 0, 0}
  end

  test "fails closed when the new center chunk is not assigned" do
    previous_context = %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10}
    window = PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)

    assert {:error, :unroutable_center, result} =
             PartitionContext.resolve(%{
               cid: 42,
               logical_scene_id: 1,
               authoritative_location: {1_650.0, 100.0, 50.0},
               previous_context: previous_context,
               partition_window: window
             })

    assert result.boundary_kind == :unroutable
    assert result.previous_context == previous_context

    assert result.subscription_diff == %{
             subscribe_chunks: [],
             unsubscribe_chunks: [],
             retained_chunks: []
           }

    assert result.chat_presence == nil
  end

  defp assigned_route(region_id, lease) do
    %{
      region_id: region_id,
      lease_id: lease.lease_id,
      lease: lease,
      assigned_scene_node: :"scene-a@local"
    }
  end

  defp lease(region_id, lease_id) do
    %{
      logical_scene_id: 1,
      region_id: region_id,
      lease_id: lease_id,
      owner_scene_instance_ref: region_id * 100,
      owner_epoch: 1,
      expires_at_ms: 9_999
    }
  end
end
