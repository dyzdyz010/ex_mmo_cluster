defmodule WorldServer.Voxel.MapLedgerTest do
  use ExUnit.Case, async: true

  alias DataService.Voxel.WriteTokenStore
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.TransactionParticipant

  test "rejects active region bounds overlap in the same logical scene" do
    ledger = start_supervised!(MapLedger)

    put_region!(ledger, 10, {0, 0, 0}, {4, 4, 4}, 1_000)

    assert {:error, :region_bounds_overlap} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 20,
               bounds_chunk_min: {3, 0, 0},
               bounds_chunk_max: {5, 2, 2},
               owner_scene_instance_ref: 2_000,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    snapshot = MapLedger.snapshot(ledger)
    assert Map.has_key?(snapshot.assignments, 10)
    refute Map.has_key?(snapshot.assignments, 20)
  end

  test "allows same region id to update its own bounds" do
    ledger = start_supervised!(MapLedger)

    put_region!(ledger, 10, {0, 0, 0}, {2, 2, 2}, 1_000)

    assert {:ok, updated_assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 10,
               bounds_chunk_min: {1, 0, 0},
               bounds_chunk_max: {3, 2, 2},
               owner_scene_instance_ref: 1_000,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    assert updated_assignment.bounds_chunk_min == {1, 0, 0}
    assert {:error, :unassigned_chunk} = MapLedger.route_chunk(ledger, 1, {0, 0, 0})
    assert {:ok, routed_assignment} = MapLedger.route_chunk(ledger, 1, {2, 0, 0})
    assert routed_assignment.region_id == 10

    assert %{
             strategy: :scene_bucket_grid_v1,
             scene_count: 1,
             region_count: 1,
             scenes: [%{logical_scene_id: 1, region_ids: [10]}]
           } = MapLedger.route_index_stats(ledger)
  end

  test "allows overlapping active bounds across logical scenes" do
    ledger = start_supervised!(MapLedger)

    put_region!(ledger, 1, 10, {0, 0, 0}, {4, 4, 4}, 1_000)
    put_region!(ledger, 2, 20, {0, 0, 0}, {4, 4, 4}, 2_000)

    assert {:ok, scene_one_assignment} = MapLedger.route_chunk(ledger, 1, {1, 0, 0})
    assert {:ok, scene_two_assignment} = MapLedger.route_chunk(ledger, 2, {1, 0, 0})
    assert scene_one_assignment.region_id == 10
    assert scene_two_assignment.region_id == 20
  end

  test "bulk routes chunks with current leases for prefab planning" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000

    put_region!(ledger, 10, {0, 0, 0}, {2, 1, 1}, 1_000)
    put_region!(ledger, 20, {2, 0, 0}, {4, 1, 1}, 2_000)

    assert {:ok, lease_a} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, lease_b} =
             MapLedger.issue_lease(ledger, 20, 2_000,
               lease_id: 200,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, routes} =
             MapLedger.route_chunks_with_leases(ledger, 1, [
               {0, 0, 0},
               {1, 0, 0},
               {2, 0, 0}
             ])

    assert Map.keys(routes) |> Enum.sort() == [{0, 0, 0}, {1, 0, 0}, {2, 0, 0}]
    assert routes[{0, 0, 0}].assignment.region_id == 10
    assert routes[{1, 0, 0}].lease.lease_id == lease_a.lease_id
    assert routes[{2, 0, 0}].assignment.region_id == 20
    assert routes[{2, 0, 0}].lease.lease_id == lease_b.lease_id
  end

  test "bulk route fails fast with the unrouted chunk" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000

    put_region!(ledger, 10, {0, 0, 0}, {1, 1, 1}, 1_000)

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:error, {{1, 0, 0}, :unassigned_chunk}} =
             MapLedger.route_chunks_with_leases(ledger, 1, [{0, 0, 0}, {1, 0, 0}])
  end

  test "builds a read-only partition window across adjacent routed regions" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000

    put_region!(ledger, 10, {0, 0, 0}, {2, 1, 1}, 1_000)
    put_region!(ledger, 20, {2, 0, 0}, {4, 1, 1}, 2_000)

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 20, 2_000,
               lease_id: 200,
               owner_epoch: 1,
               expires_at_ms: future_ms
             )

    snapshot_before = MapLedger.snapshot(ledger)

    window =
      MapLedger.partition_window(ledger, 1, {1, 0, 0},
        near_radius: 0,
        halo_radius: 1
      )

    snapshot_after = MapLedger.snapshot(ledger)

    assert snapshot_after == snapshot_before
    assert window.logical_scene_id == 1
    assert window.center_chunk == {1, 0, 0}
    assert window.near_chunks == [{1, 0, 0}]
    assert {2, 0, 0} in window.halo_chunks
    assert length(window.route_entries) == 27
    assert length(window.missing_chunks) == 24

    assert [
             %{
               chunk_coord: {1, 0, 0},
               tier: :near,
               status: :assigned,
               region_id: 10,
               lease_id: 100,
               assigned_scene_node: assigned_scene_node
             }
           ] = Enum.filter(window.route_entries, &(&1.chunk_coord == {1, 0, 0}))

    assert is_atom(assigned_scene_node)

    assert [
             %{
               chunk_coord: {2, 0, 0},
               tier: :halo,
               status: :assigned,
               region_id: 20,
               lease_id: 200
             }
           ] = Enum.filter(window.route_entries, &(&1.chunk_coord == {2, 0, 0}))

    assert window.region_summaries == [
             %{
               region_id: 10,
               near_count: 1,
               halo_count: 1,
               lease_id: 100,
               assigned_scene_node: node()
             },
             %{
               region_id: 20,
               near_count: 0,
               halo_count: 1,
               lease_id: 200,
               assigned_scene_node: node()
             }
           ]
  end

  test "builds vertically clipped partition windows for open-world interest" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000

    put_region!(ledger, 10, {0, -1, 0}, {2, 2, 1}, 1_000)
    put_region!(ledger, 20, {2, -1, 0}, {3, 2, 1}, 2_000)

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 20, 2_000,
               lease_id: 200,
               owner_epoch: 1,
               expires_at_ms: future_ms
             )

    window =
      MapLedger.partition_window(ledger, 1, {1, 0, 0},
        near_radius: 0,
        halo_radius: 1,
        near_vertical_radius: 0,
        halo_vertical_radius: 0
      )

    assert window.near_chunks == [{1, 0, 0}]
    assert length(window.halo_chunks) == 8
    assert length(window.route_entries) == 9
    assert window.missing_chunks == []

    assert Enum.all?(window.route_entries, fn entry ->
             {_x, _y, z} = entry.chunk_coord
             z == 0 and entry.status == :assigned
           end)

    assert {2, 1, 0} in window.halo_chunks
    refute {1, 0, 1} in window.near_chunks
    refute {1, 0, 1} in window.halo_chunks
  end

  test "builds a best-effort live route window with lease tokens" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000

    put_region!(ledger, 10, {0, 0, 0}, {1, 1, 1}, 1_000)
    put_region!(ledger, 20, {-1, 0, 0}, {0, 1, 1}, 2_000)

    assert {:ok, lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms
             )

    snapshot_before = MapLedger.snapshot(ledger)

    window =
      MapLedger.route_window_with_leases(ledger, 1, {0, 0, 0},
        near_radius: 0,
        halo_radius: 1
      )

    assert MapLedger.snapshot(ledger) == snapshot_before

    assert [
             %{
               chunk_coord: {0, 0, 0},
               tier: :near,
               status: :assigned,
               region_id: 10,
               lease_id: 100,
               lease: ^lease,
               assigned_scene_node: assigned_scene_node
             }
           ] = Enum.filter(window.route_entries, &(&1.chunk_coord == {0, 0, 0}))

    assert is_atom(assigned_scene_node)

    assert [
             %{
               chunk_coord: {-1, 0, 0},
               tier: :halo,
               status: :region_without_lease,
               region_id: 20,
               lease_id: nil,
               lease: nil,
               assigned_scene_node: unleased_scene_node
             }
           ] = Enum.filter(window.route_entries, &(&1.chunk_coord == {-1, 0, 0}))

    assert is_atom(unleased_scene_node)
  end

  test "refreshes the route index when a region moves to new bounds" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000

    put_region!(ledger, 10, {0, 0, 0}, {2, 1, 1}, 1_000)

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms
             )

    assert {:ok, %{assignment: before_assignment, lease: before_lease}} =
             MapLedger.route_chunk_with_lease(ledger, 1, {1, 0, 0})

    assert before_assignment.region_id == 10
    assert before_lease.lease_id == 100

    assert {:ok, _updated_assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 10,
               bounds_chunk_min: {4, 0, 0},
               bounds_chunk_max: {6, 1, 1},
               owner_scene_instance_ref: 1_000,
               owner_epoch: 1,
               lease_id: 100,
               assigned_scene_node: node()
             })

    assert {:error, :unassigned_chunk} = MapLedger.route_chunk(ledger, 1, {1, 0, 0})

    assert {:ok, %{assignment: moved_assignment, lease: moved_lease}} =
             MapLedger.route_chunk_with_lease(ledger, 1, {4, 0, 0})

    assert moved_assignment.region_id == 10
    assert moved_assignment.bounds_chunk_min == {4, 0, 0}
    assert moved_lease.lease_id == 100
  end

  test "returns missing and unleased chunks without mutating ledger state" do
    ledger = start_supervised!(MapLedger)

    put_region!(ledger, 10, {0, 0, 0}, {1, 1, 1}, 1_000)
    snapshot_before = MapLedger.snapshot(ledger)

    window =
      MapLedger.partition_window(ledger, 1, {0, 0, 0},
        near_radius: 0,
        halo_radius: 1
      )

    snapshot_after = MapLedger.snapshot(ledger)

    assert snapshot_after == snapshot_before
    assert length(window.missing_chunks) == 26

    assert [
             %{
               chunk_coord: {0, 0, 0},
               tier: :near,
               status: :region_without_lease,
               region_id: 10,
               lease_id: nil,
               assigned_scene_node: assigned_scene_node
             }
           ] = Enum.filter(window.route_entries, &(&1.chunk_coord == {0, 0, 0}))

    assert is_atom(assigned_scene_node)

    assert window.region_summaries == [
             %{
               region_id: 10,
               near_count: 1,
               halo_count: 0,
               lease_id: nil,
               assigned_scene_node: node()
             }
           ]
  end

  test "publishes lease write tokens and fences stale writes after migration" do
    token_store = start_supervised!(WriteTokenStore)
    ledger = start_supervised!({MapLedger, write_token_store: token_store})
    future_ms = System.system_time(:millisecond) + 60_000

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 10,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 4, 4},
               owner_scene_instance_ref: 1_000,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    assert {:ok, lease_v1} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert :ok =
             MapLedger.validate_write(ledger, %{
               logical_scene_id: 1,
               chunk_coord: {1, 0, 0},
               lease_id: lease_v1.lease_id,
               owner_scene_instance_ref: lease_v1.owner_scene_instance_ref,
               owner_epoch: lease_v1.owner_epoch
             })

    assert :ok =
             WriteTokenStore.validate_write(token_store, %{
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {1, 0, 0},
               lease_id: lease_v1.lease_id,
               owner_scene_instance_ref: lease_v1.owner_scene_instance_ref,
               owner_epoch: lease_v1.owner_epoch
             })

    assert {:ok, lease_v2} =
             MapLedger.migrate_region(ledger, 10, 2_000,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2
             )

    assert {:error, :lease_id_mismatch} =
             MapLedger.validate_write(ledger, %{
               logical_scene_id: 1,
               chunk_coord: {1, 0, 0},
               lease_id: lease_v1.lease_id,
               owner_scene_instance_ref: lease_v1.owner_scene_instance_ref,
               owner_epoch: lease_v1.owner_epoch
             })

    assert {:error, :lease_id_mismatch} =
             WriteTokenStore.validate_write(token_store, %{
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {1, 0, 0},
               lease_id: lease_v1.lease_id,
               owner_scene_instance_ref: lease_v1.owner_scene_instance_ref,
               owner_epoch: lease_v1.owner_epoch
             })

    assert :ok =
             MapLedger.validate_write(ledger, %{
               logical_scene_id: 1,
               chunk_coord: {1, 0, 0},
               lease_id: lease_v2.lease_id,
               owner_scene_instance_ref: lease_v2.owner_scene_instance_ref,
               owner_epoch: lease_v2.owner_epoch
             })
  end

  test "stages migration handoff and cuts over route lease after prewarm" do
    token_store = start_supervised!(WriteTokenStore)
    ledger = start_supervised!({MapLedger, write_token_store: token_store})
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-10"

    put_region!(ledger, 10, {0, 0, 0}, {4, 4, 4}, 1_000)

    assert {:ok, lease_v1} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2,
               slice_width: 2
             )

    assert plan.state == :prewarming
    assert plan.source_scene_instance_ref == 1_000
    assert plan.target_scene_instance_ref == 2_000
    assert plan.old_lease.lease_id == lease_v1.lease_id
    assert plan.new_lease.lease_id == 101
    assert plan.affected_chunk_min == {0, 0, 0}
    assert plan.affected_chunk_max == {4, 4, 4}

    assert {:ok, %{lease: routed_before}} =
             MapLedger.route_chunk_with_lease(ledger, 1, {1, 0, 0})

    assert routed_before.lease_id == lease_v1.lease_id
    assert :ok = MapLedger.validate_write(ledger, write_attrs(lease_v1, {1, 0, 0}))

    assert {:ok, slice_0} = MapLedger.plan_next_migration_slice(ledger, migration_id)
    assert slice_0.bounds_chunk_min == {0, 0, 0}
    assert slice_0.bounds_chunk_max == {2, 4, 4}

    assert {:error, :migration_prewarm_incomplete} =
             MapLedger.mark_prewarmed(ledger, migration_id)

    assert {:ok, slice_1} = MapLedger.plan_next_migration_slice(ledger, migration_id)
    assert slice_1.bounds_chunk_min == {2, 0, 0}
    assert slice_1.bounds_chunk_max == {4, 4, 4}

    assert {:ok, handoff} = MapLedger.migration_handoff(ledger, migration_id)
    assert handoff.old_lease.lease_id == lease_v1.lease_id
    assert handoff.new_lease.lease_id == 101
    assert handoff.planned_slices == [slice_0, slice_1]

    assert {:error, :migration_prewarm_ack_incomplete} =
             MapLedger.mark_prewarmed(ledger, migration_id)

    assert {:ok, acked_plan_0, acked_slice_0} =
             MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
               slice_id: slice_0.slice_id,
               scene_ref: 2_000,
               loaded_count: 8,
               empty_count: 0,
               max_chunk_version: 4
             })

    assert acked_slice_0.state == :prewarmed
    assert acked_plan_0.prewarm_acks[slice_0.slice_id].loaded_count == 8

    assert {:error, :migration_prewarm_ack_incomplete} =
             MapLedger.mark_prewarmed(ledger, migration_id)

    assert {:ok, _acked_plan_1, acked_slice_1} =
             MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
               slice_id: slice_1.slice_id,
               scene_ref: 2_000,
               loaded_count: 8,
               empty_count: 0,
               max_chunk_version: 4
             })

    assert acked_slice_1.state == :prewarmed

    assert {:ok, prewarmed_plan} = MapLedger.mark_prewarmed(ledger, migration_id)
    assert prewarmed_plan.state == :prewarmed
    assert map_size(prewarmed_plan.prewarm_acks) == 2

    assert {:ok, snapshot_before_cutover} = MapLedger.migration_snapshot(ledger, migration_id)
    assert snapshot_before_cutover.state == :prewarmed

    assert {:error, :migration_final_catchup_ack_incomplete} =
             MapLedger.cutover_migration(ledger, migration_id)

    assert {:ok, _caught_up_plan_0, caught_up_slice_0} =
             MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
               slice_id: slice_0.slice_id,
               scene_ref: 2_000,
               loaded_count: 8,
               empty_count: 0,
               max_chunk_version: 5,
               source_persisted_count: 8,
               source_missing_count: 0,
               source_error_count: 0
             })

    assert caught_up_slice_0.final_catchup_ack.max_chunk_version == 5

    assert {:error, :migration_final_catchup_ack_incomplete} =
             MapLedger.cutover_migration(ledger, migration_id)

    assert {:ok, caught_up_plan_1, caught_up_slice_1} =
             MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
               slice_id: slice_1.slice_id,
               scene_ref: 2_000,
               loaded_count: 8,
               empty_count: 0,
               max_chunk_version: 5,
               source_persisted_count: 8,
               source_missing_count: 0,
               source_error_count: 0
             })

    assert caught_up_slice_1.final_catchup_ack.max_chunk_version == 5
    assert map_size(caught_up_plan_1.final_catchup_acks) == 2

    assert {:ok, cutover_plan} = MapLedger.cutover_migration(ledger, migration_id)
    assert cutover_plan.state == :cutover

    assert {:error, :lease_id_mismatch} =
             MapLedger.validate_write(ledger, write_attrs(lease_v1, {1, 0, 0}))

    assert {:error, :lease_id_mismatch} =
             WriteTokenStore.validate_write(token_store, write_attrs(lease_v1, {1, 0, 0}))

    assert {:ok, %{assignment: assignment_after, lease: routed_after}} =
             MapLedger.route_chunk_with_lease(ledger, 1, {1, 0, 0})

    assert assignment_after.owner_scene_instance_ref == 2_000
    assert assignment_after.lease_id == 101
    assert routed_after.lease_id == 101
    assert routed_after.owner_scene_instance_ref == 2_000

    cutover_window =
      MapLedger.route_window_with_leases(ledger, 1, {1, 0, 0},
        near_radius: 0,
        halo_radius: 0
      )

    assert [
             %{
               chunk_coord: {1, 0, 0},
               status: :assigned,
               region_id: 10,
               lease_id: 101,
               lease: ^routed_after
             }
           ] = cutover_window.route_entries

    assert :ok = MapLedger.validate_write(ledger, write_attrs(routed_after, {1, 0, 0}))

    assert {:ok, completed_plan} = MapLedger.complete_migration(ledger, migration_id)
    assert completed_plan.state == :completed

    snapshot = MapLedger.snapshot(ledger)
    assert snapshot.migrations[migration_id].state == :completed
  end

  test "cutover switches the route lease and assigned scene node as one identity" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-cross-node-cutover"

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 10,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 1_000,
               owner_epoch: 0,
               assigned_scene_node: :scene_a@local
             })

    assert {:ok, source_lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2,
               target_scene_node: :scene_b@local
             )

    assert plan.target_scene_node == :scene_b@local

    assert {:ok, %{assignment: before_assignment, lease: before_lease}} =
             MapLedger.route_chunk_with_lease(ledger, 1, {0, 0, 0})

    assert before_assignment.assigned_scene_node == :scene_a@local
    assert before_lease.lease_id == source_lease.lease_id

    assert {:ok, handoff} = MapLedger.migration_handoff(ledger, migration_id)
    assert handoff.target_scene_node == :scene_b@local

    assert {:ok, slice} = MapLedger.plan_next_migration_slice(ledger, migration_id)

    assert {:ok, _plan, _acked_slice} =
             MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, _prewarmed_plan} = MapLedger.mark_prewarmed(ledger, migration_id)

    assert {:ok, _final_plan, _final_slice} =
             MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, cutover_plan} = MapLedger.cutover_migration(ledger, migration_id)
    assert cutover_plan.target_scene_node == :scene_b@local

    assert {:ok, %{assignment: after_assignment, lease: after_lease}} =
             MapLedger.route_chunk_with_lease(ledger, 1, {0, 0, 0})

    assert after_assignment.assigned_scene_node == :scene_b@local
    assert after_assignment.owner_scene_instance_ref == 2_000
    assert after_assignment.owner_epoch == 2
    assert after_assignment.lease_id == 101
    assert after_lease.owner_scene_instance_ref == 2_000
    assert after_lease.owner_epoch == 2
    assert after_lease.lease_id == 101

    window =
      MapLedger.route_window_with_leases(ledger, 1, {0, 0, 0},
        near_radius: 0,
        halo_radius: 0
      )

    assert [%{assigned_scene_node: :scene_b@local, lease_id: 101}] = window.route_entries
  end

  test "cutover rejects source lease drift without invalidating subscribers" do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    invalidator = fn attrs ->
      Agent.update(recorder, fn calls -> [attrs | calls] end)
      :ok
    end

    ledger = start_supervised!({MapLedger, scene_invalidator: invalidator})
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-source-drift"

    put_region!(ledger, 10, {0, 0, 0}, {1, 1, 1}, 1_000)

    assert {:ok, _source_lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, _plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2,
               target_scene_node: :scene_b@local
             )

    assert {:ok, slice} = MapLedger.plan_next_migration_slice(ledger, migration_id)

    assert {:ok, _plan, _acked_slice} =
             MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, _prewarmed_plan} = MapLedger.mark_prewarmed(ledger, migration_id)

    assert {:ok, _plan, _final_slice} =
             MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, _drift_lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 150,
               owner_epoch: 3,
               expires_at_ms: future_ms,
               token_version: 3
             )

    assert {:error, :migration_source_lease_changed} =
             MapLedger.cutover_migration(ledger, migration_id)

    assert Agent.get(recorder, & &1) == []

    assert {:ok, %{assignment: assignment_after, lease: lease_after}} =
             MapLedger.route_chunk_with_lease(ledger, 1, {0, 0, 0})

    assert assignment_after.owner_scene_instance_ref == 1_000
    assert assignment_after.assigned_scene_node == node()
    assert lease_after.lease_id == 150
    assert lease_after.owner_scene_instance_ref == 1_000
  end

  test "cutover rejects source scene-node drift without invalidating subscribers" do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    invalidator = fn attrs ->
      Agent.update(recorder, fn calls -> [attrs | calls] end)
      :ok
    end

    ledger = start_supervised!({MapLedger, scene_invalidator: invalidator})
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-source-node-drift"

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 10,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 1_000,
               owner_epoch: 0,
               assigned_scene_node: :scene_a@local
             })

    assert {:ok, _source_lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, _plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2,
               target_scene_node: :scene_b@local
             )

    assert {:ok, slice} = MapLedger.plan_next_migration_slice(ledger, migration_id)

    assert {:ok, _plan, _acked_slice} =
             MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, _prewarmed_plan} = MapLedger.mark_prewarmed(ledger, migration_id)

    assert {:ok, _plan, _final_slice} =
             MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, _drift_assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 10,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 1_000,
               owner_epoch: 1,
               lease_id: 100,
               assigned_scene_node: :scene_c@local
             })

    assert {:error, :migration_source_scene_node_changed} =
             MapLedger.cutover_migration(ledger, migration_id)

    assert Agent.get(recorder, & &1) == []

    assert {:ok, %{assignment: assignment_after, lease: lease_after}} =
             MapLedger.route_chunk_with_lease(ledger, 1, {0, 0, 0})

    assert assignment_after.owner_scene_instance_ref == 1_000
    assert assignment_after.assigned_scene_node == :scene_c@local
    assert lease_after.lease_id == 100
    assert lease_after.owner_scene_instance_ref == 1_000
  end

  test "cutover rejects source owner drift without invalidating subscribers" do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    invalidator = fn attrs ->
      Agent.update(recorder, fn calls -> [attrs | calls] end)
      :ok
    end

    ledger = start_supervised!({MapLedger, scene_invalidator: invalidator})
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-source-owner-drift"

    put_region!(ledger, 10, {0, 0, 0}, {1, 1, 1}, 1_000)

    assert {:ok, _source_lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, _plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2,
               target_scene_node: :scene_b@local
             )

    assert {:ok, slice} = MapLedger.plan_next_migration_slice(ledger, migration_id)

    assert {:ok, _plan, _acked_slice} =
             MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, _prewarmed_plan} = MapLedger.mark_prewarmed(ledger, migration_id)

    assert {:ok, _plan, _final_slice} =
             MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, _drift_assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 10,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 1_500,
               owner_epoch: 1,
               lease_id: 100,
               assigned_scene_node: node()
             })

    assert {:error, :migration_source_owner_changed} =
             MapLedger.cutover_migration(ledger, migration_id)

    assert Agent.get(recorder, & &1) == []

    assert {:ok, %{assignment: assignment_after, lease: lease_after}} =
             MapLedger.route_chunk_with_lease(ledger, 1, {0, 0, 0})

    assert assignment_after.owner_scene_instance_ref == 1_500
    assert lease_after.lease_id == 100
    assert lease_after.owner_scene_instance_ref == 1_000
  end

  test "rejects final catch-up ack before migration is prewarmed" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-catchup-too-early"

    put_region!(ledger, 10, {0, 0, 0}, {2, 2, 2}, 1_000)

    assert {:ok, _lease_v1} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, _plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2
             )

    assert {:ok, slice} = MapLedger.plan_next_migration_slice(ledger, migration_id)

    assert {:error, :migration_not_prewarmed} =
             MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 2_000
             })
  end

  test "rejects slice prewarm ack from the wrong target scene" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-wrong-target"

    put_region!(ledger, 10, {0, 0, 0}, {2, 2, 2}, 1_000)

    assert {:ok, _lease_v1} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, _plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2
             )

    assert {:ok, slice} = MapLedger.plan_next_migration_slice(ledger, migration_id)

    assert {:error, :migration_slice_ack_scene_mismatch} =
             MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 3_000
             })

    assert {:error, :migration_prewarm_incomplete} =
             MapLedger.mark_prewarmed(ledger, migration_id)
  end

  test "builds deterministic Scene-owner transaction participants with chunk owners" do
    ledger = start_supervised!(MapLedger)
    future_ms = System.system_time(:millisecond) + 60_000

    put_region!(ledger, 10, {0, 0, 0}, {2, 2, 2}, 1_000)
    put_region!(ledger, 20, {2, 0, 0}, {4, 2, 2}, 1_000)

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 20, 1_000,
               lease_id: 200,
               owner_epoch: 1,
               expires_at_ms: future_ms
             )

    assert {:ok, [participant]} =
             MapLedger.transaction_participants(ledger, 1, [
               {3, 0, 0},
               {0, 0, 0},
               {2, 0, 0},
               {0, 0, 0}
             ])

    assert %TransactionParticipant{
             participant_key: {:scene_owner, scene_node},
             assigned_scene_node: scene_node,
             region_id: 10,
             lease_id: 100,
             affected_chunks: [{0, 0, 0}, {2, 0, 0}, {3, 0, 0}],
             chunk_owners: %{
               {0, 0, 0} => {10, 100},
               {2, 0, 0} => {20, 200},
               {3, 0, 0} => {20, 200}
             }
           } = participant
  end

  test "invokes scene invalidator for every chunk in affected bounds on cutover" do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    invalidator = fn attrs ->
      Agent.update(recorder, fn calls -> [attrs | calls] end)
      {:ok, %{subscriber_count: 0, reason: attrs.reason}}
    end

    ledger = start_supervised!({MapLedger, scene_invalidator: invalidator})
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-cutover-invalidate"

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 10,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {2, 1, 1},
               owner_scene_instance_ref: 1_000,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    assert {:ok, _lease_v1} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, _plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2,
               slice_width: 2
             )

    assert {:ok, slice_0} = MapLedger.plan_next_migration_slice(ledger, migration_id)

    assert {:error, :migration_slices_exhausted} =
             MapLedger.plan_next_migration_slice(ledger, migration_id)

    assert {:ok, _plan, _acked_slice_0} =
             MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
               slice_id: slice_0.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, _prewarmed_plan} = MapLedger.mark_prewarmed(ledger, migration_id)

    assert {:ok, _final_plan, _final_slice_0} =
             MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
               slice_id: slice_0.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, cutover_plan} = MapLedger.cutover_migration(ledger, migration_id)
    assert cutover_plan.state == :cutover

    calls = Agent.get(recorder, fn calls -> Enum.reverse(calls) end)
    assert length(calls) == 2
    assert Enum.all?(calls, &(&1.logical_scene_id == 1))
    assert Enum.all?(calls, &(&1.reason == 0x01))

    chunk_coords = calls |> Enum.map(& &1.chunk_coord) |> Enum.sort()
    assert chunk_coords == [{0, 0, 0}, {1, 0, 0}]
  end

  test "does not invoke scene invalidator when cutover fails" do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    invalidator = fn attrs ->
      Agent.update(recorder, fn calls -> [attrs | calls] end)
      :ok
    end

    ledger = start_supervised!({MapLedger, scene_invalidator: invalidator})
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-cutover-fails"

    put_region!(ledger, 10, {0, 0, 0}, {2, 1, 1}, 1_000)

    assert {:ok, _lease_v1} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, _plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2
             )

    # Cutover before plan is prewarmed must fail.
    assert {:error, :migration_not_prewarmed} =
             MapLedger.cutover_migration(ledger, migration_id)

    assert Agent.get(recorder, & &1) == []
  end

  test "tolerates a raising scene invalidator without breaking cutover" do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    invalidator = fn attrs ->
      Agent.update(recorder, fn calls -> [attrs | calls] end)
      raise "scene exploded"
    end

    ledger = start_supervised!({MapLedger, scene_invalidator: invalidator})
    future_ms = System.system_time(:millisecond) + 60_000
    migration_id = "migration-cutover-invalidate-error"

    put_region!(ledger, 10, {0, 0, 0}, {2, 1, 1}, 1_000)

    assert {:ok, _lease_v1} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms,
               token_version: 1
             )

    assert {:ok, _plan} =
             MapLedger.begin_migration(ledger, 10, 2_000,
               migration_id: migration_id,
               lease_id: 101,
               owner_epoch: 2,
               expires_at_ms: future_ms,
               token_version: 2,
               slice_width: 2
             )

    assert {:ok, slice_0} = MapLedger.plan_next_migration_slice(ledger, migration_id)

    assert {:ok, _plan, _acked} =
             MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
               slice_id: slice_0.slice_id,
               scene_ref: 2_000
             })

    assert {:ok, _prewarmed_plan} = MapLedger.mark_prewarmed(ledger, migration_id)

    assert {:ok, _final, _final_slice} =
             MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
               slice_id: slice_0.slice_id,
               scene_ref: 2_000
             })

    # Cutover succeeds even if every invalidator call raises.
    assert {:ok, cutover_plan} = MapLedger.cutover_migration(ledger, migration_id)
    assert cutover_plan.state == :cutover

    # Recorder still saw both attempted calls.
    calls = Agent.get(recorder, fn calls -> Enum.reverse(calls) end)
    assert length(calls) == 2
  end

  defp put_region!(ledger, region_id, min, max, owner_ref) do
    put_region!(ledger, 1, region_id, min, max, owner_ref)
  end

  defp put_region!(ledger, logical_scene_id, region_id, min, max, owner_ref) do
    assert {:ok, _assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: logical_scene_id,
               region_id: region_id,
               bounds_chunk_min: min,
               bounds_chunk_max: max,
               owner_scene_instance_ref: owner_ref,
               owner_epoch: 0,
               assigned_scene_node: node()
             })
  end

  defp write_attrs(lease, chunk_coord) do
    %{
      logical_scene_id: lease.logical_scene_id,
      region_id: lease.region_id,
      chunk_coord: chunk_coord,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch
    }
  end
end
