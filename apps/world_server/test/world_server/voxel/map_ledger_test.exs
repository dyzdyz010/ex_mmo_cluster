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
               owner_epoch: 0
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
               owner_epoch: 0
             })

    assert updated_assignment.bounds_chunk_min == {1, 0, 0}
    assert {:error, :unassigned_chunk} = MapLedger.route_chunk(ledger, 1, {0, 0, 0})
    assert {:ok, routed_assignment} = MapLedger.route_chunk(ledger, 1, {2, 0, 0})
    assert routed_assignment.region_id == 10
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
               owner_epoch: 0
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
    assert :ok = MapLedger.validate_write(ledger, write_attrs(routed_after, {1, 0, 0}))

    assert {:ok, completed_plan} = MapLedger.complete_migration(ledger, migration_id)
    assert completed_plan.state == :completed

    snapshot = MapLedger.snapshot(ledger)
    assert snapshot.migrations[migration_id].state == :completed
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

  test "builds deterministic lease-scoped transaction participants" do
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

    assert {:ok,
            [
              %TransactionParticipant{
                region_id: 10,
                lease_id: 100,
                affected_chunks: [{0, 0, 0}]
              },
              %TransactionParticipant{
                region_id: 20,
                lease_id: 200,
                affected_chunks: [{2, 0, 0}, {3, 0, 0}]
              }
            ]} =
             MapLedger.transaction_participants(ledger, 1, [
               {3, 0, 0},
               {0, 0, 0},
               {2, 0, 0},
               {0, 0, 0}
             ])
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
               owner_epoch: 0
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
               owner_epoch: 0
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
