defmodule WorldServer.Voxel.MapLedgerTest do
  # 梯队1 step1.2:WriteTokenStore DB 化后共享 voxel_write_tokens 表,改 async:false + 每测试清表。
  use ExUnit.Case, async: false

  alias DataService.Voxel.RegionDirectoryStore
  alias DataService.Voxel.WriteTokenStore
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.MigrationPlan
  alias WorldServer.Voxel.RegionAssignment
  alias WorldServer.Voxel.RegionGrid
  alias WorldServer.Voxel.SceneNodeRegistry
  alias WorldServer.Voxel.TransactionParticipant

  setup do
    WriteTokenStore.reset()

    # 梯队1 step1.3:owner_epoch 经 DB 线性化分配器,清表保证跨测试/跨运行 epoch 确定。
    DataService.Voxel.RegionEpochStore.reset()
    # 阶段2:per-region durable 目录共享表,清表隔离。
    RegionDirectoryStore.reset()
    :ok
  end

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

  test "issue_lease with an explicit owner_epoch below the DB floor uses the monotonic epoch (not the stale value)" do
    # Regression: allocate_owner_epoch must return set_floor's result (GREATEST(db, explicit)),
    # NOT the raw explicit. A prior session/migration advanced this region's DB epoch to 5; a
    # new issue_lease that pins owner_epoch: 1 must still get epoch 5 (monotonic). Returning the
    # stale 1 broke owner_epoch/token_version monotonicity → publish_write_token CAS :stale_token
    # → lease never stored / region_without_lease (the DevSeed + voxel_smoke class — root fix).
    ledger = start_supervised!({MapLedger, write_token_store: WriteTokenStore})
    future_ms = System.system_time(:millisecond) + 60_000

    # Simulate the region's DB epoch already advanced past the pinned value.
    assert 5 = DataService.Voxel.RegionEpochStore.set_floor(1, 10, 5)

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: 10,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 1_000,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    # Pin owner_epoch: 1 (below the DB floor 5), no explicit token_version (defaults to the
    # allocated epoch). With the fix this succeeds and the lease uses epoch 5, not 1.
    assert {:ok, lease} =
             MapLedger.issue_lease(ledger, 10, 1_000,
               lease_id: 100,
               owner_epoch: 1,
               expires_at_ms: future_ms
             )

    assert lease.owner_epoch == 5, "lease must use the monotonic DB epoch, not the stale pin"

    # The published write token validates (it was published at the monotonic version, not stale).
    assert :ok =
             WriteTokenStore.validate_write(%{
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {0, 0, 0},
               lease_id: lease.lease_id,
               owner_scene_instance_ref: lease.owner_scene_instance_ref,
               owner_epoch: lease.owner_epoch
             })
  end

  test "publishes lease write tokens and fences stale writes after migration" do
    token_store = WriteTokenStore
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
             WriteTokenStore.validate_write(%{
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
             WriteTokenStore.validate_write(%{
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
    token_store = WriteTokenStore
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
             WriteTokenStore.validate_write(write_attrs(lease_v1, {1, 0, 0}))

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

  # batch 1 (#2):跨版本 stale 快照可能把 migrations 子表里的 plan 反序列化成 plain map。
  # LOAD 时必须丢弃非 %MigrationPlan{},否则后续 MigrationPlan.* 对非 struct 崩。
  test "loading a persisted payload drops migrations that are not %MigrationPlan{} structs" do
    valid_plan = build_migration_plan("mig-ok")

    payload = %{
      migrations: %{
        "mig-ok" => valid_plan,
        # plain map(旧 schema / 跨版本反序列化残留),非 struct → 必须被丢弃。
        "mig-stale" => %{state: :prewarming, migration_id: "mig-stale"}
      }
    }

    ledger = start_supervised!({MapLedger, load_fn: fn -> {:ok, payload} end})
    snapshot = MapLedger.snapshot(ledger)

    assert Map.has_key?(snapshot.migrations, "mig-ok")
    refute Map.has_key?(snapshot.migrations, "mig-stale")
  end

  # batch 1 (#18):注入的 load_fn 抛异常时,init 必须不跟着崩(否则拖垮 WorldSup → boot 崩)。
  test "a load_fn that raises does not crash init (ledger boots with empty state)" do
    ledger = start_supervised!({MapLedger, load_fn: fn -> raise "boom in load" end})
    snapshot = MapLedger.snapshot(ledger)

    assert snapshot.migrations == %{}
    assert snapshot.assignments == %{}
  end

  describe "lazy materialization (route_*_ensuring — 阶段1 隐式分区, 世界无界)" do
    setup do
      registry = start_supervised!(SceneNodeRegistry)
      :ok = SceneNodeRegistry.register_scene_node(registry, node())

      ledger =
        start_supervised!(
          {MapLedger, write_token_store: WriteTokenStore, scene_node_registry: registry}
        )

      %{ledger: ledger}
    end

    test "materializes a grid-aligned region on a route miss and returns assignment + lease", %{
      ledger: ledger
    } do
      assert {:ok, %{assignment: assignment, lease: lease}} =
               MapLedger.route_chunk_with_lease_ensuring(ledger, 1, {0, 0, 0})

      # Bounds are derived from the default grid (Sx=Sz=8, Sy=64), half-open.
      assert assignment.bounds_chunk_min == {0, 0, 0}
      assert assignment.bounds_chunk_max == {8, 64, 8}
      assert assignment.assigned_scene_node == node()
      assert assignment.region_id == RegionGrid.region_id(1, {0, 0, 0})
      assert assignment.state == :active
      assert lease.region_id == assignment.region_id
      assert lease.owner_epoch >= 1

      # The materialized region is now a normal routable assignment for any chunk
      # in its bounds (the pure, non-materializing route finds it).
      assert {:ok, routed} = MapLedger.route_chunk(ledger, 1, {7, 63, 7})
      assert routed.region_id == assignment.region_id
    end

    test "a far-flung chunk well outside any explicit box still materializes (unbounded world)",
         %{ledger: ledger} do
      far = {10_000, 5, -7_777}

      assert {:ok, %{assignment: assignment}} =
               MapLedger.route_chunk_with_lease_ensuring(ledger, 1, far)

      assert RegionAssignment.contains_chunk?(assignment, far)
      assert {:ok, _} = MapLedger.route_chunk(ledger, 1, far)
    end

    test "re-routing chunks in the same grid cell reuses the region (idempotent, no churn)", %{
      ledger: ledger
    } do
      assert {:ok, %{assignment: a1, lease: l1}} =
               MapLedger.route_chunk_with_lease_ensuring(ledger, 1, {1, 0, 1})

      assert {:ok, %{assignment: a2, lease: l2}} =
               MapLedger.route_chunk_with_lease_ensuring(ledger, 1, {2, 0, 2})

      assert a1.region_id == a2.region_id
      assert l1.lease_id == l2.lease_id
      assert map_size(MapLedger.snapshot(ledger).assignments) == 1
    end

    test "neighboring chunks across a grid boundary materialize distinct regions", %{
      ledger: ledger
    } do
      assert {:ok, %{assignment: a}} =
               MapLedger.route_chunk_with_lease_ensuring(ledger, 1, {7, 0, 0})

      assert {:ok, %{assignment: b}} =
               MapLedger.route_chunk_with_lease_ensuring(ledger, 1, {8, 0, 0})

      refute a.region_id == b.region_id
      assert map_size(MapLedger.snapshot(ledger).assignments) == 2
    end

    test "batch ensuring materializes every touched region in one call", %{ledger: ledger} do
      coords = [{0, 0, 0}, {8, 0, 0}, {0, 0, 8}]

      assert {:ok, routes} = MapLedger.route_chunks_with_leases_ensuring(ledger, 1, coords)
      assert routes |> Map.keys() |> Enum.sort() == Enum.sort(coords)

      region_ids =
        routes |> Map.values() |> Enum.map(& &1.assignment.region_id) |> Enum.uniq()

      assert length(region_ids) == 3
    end
  end

  # 阶段1 keystone review F1:O(1) grid 快路径必须与扫描逐位等价。若某显式 put_region 的
  # region_id 恰好撞上"另一个 scene 的 grid region_id",而其 logical_scene_id 字段不一致,
  # 快路径不得跨 scene 命中(否则把别的 scene 的 region 路给了本 scene)。
  test "grid fast path does not route cross-scene when an explicit region_id collides with another scene's grid id" do
    ledger = start_supervised!(MapLedger)

    # region_id encodes scene 2's grid cell {0,0,0}, but we store it under scene 1.
    colliding_region_id = RegionGrid.region_id(2, {0, 0, 0})

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 1,
               region_id: colliding_region_id,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 1_000,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    # Querying scene 1 still finds it (its real scene).
    assert {:ok, routed} = MapLedger.route_chunk(ledger, 1, {0, 0, 0})
    assert routed.region_id == colliding_region_id

    # Querying scene 2 for the same chunk computes the SAME grid region_id, but the
    # stored assignment belongs to scene 1 — the fast path must reject it (guard),
    # and the scan (filtered by logical_scene_id) also rejects → :unassigned_chunk.
    assert {:error, :unassigned_chunk} = MapLedger.route_chunk(ledger, 2, {0, 0, 0})
  end

  test "ensuring route fails cleanly (and stores nothing) when no Scene node is registered" do
    registry = start_supervised!(SceneNodeRegistry)

    ledger =
      start_supervised!(
        {MapLedger, write_token_store: WriteTokenStore, scene_node_registry: registry}
      )

    assert {:error, :scene_node_unassigned} =
             MapLedger.route_chunk_with_lease_ensuring(ledger, 1, {0, 0, 0})

    assert MapLedger.snapshot(ledger).assignments == %{}
  end

  describe "durable region directory (阶段2 — 重启自愈, scale-first per-region 持久化)" do
    setup do
      registry = start_supervised!(SceneNodeRegistry)
      :ok = SceneNodeRegistry.register_scene_node(registry, node())
      %{registry: registry}
    end

    test "a lazily-materialized region survives a ledger restart via the durable directory", %{
      registry: registry
    } do
      opts = [
        write_token_store: WriteTokenStore,
        scene_node_registry: registry,
        region_directory: RegionDirectoryStore
      ]

      ledger1 = start_supervised!({MapLedger, [name: :dur_ledger_a] ++ opts})

      assert {:ok, %{assignment: assignment, lease: lease}} =
               MapLedger.route_chunk_with_lease_ensuring(ledger1, 1, {3, 0, 3})

      region_id = assignment.region_id

      # The directory row was written (atomically with the write token).
      assert {:ok, row} = RegionDirectoryStore.get_region(region_id)
      assert row.lease_id == lease.lease_id
      assert row.assigned_scene_node == Atom.to_string(node())

      :ok = stop_supervised(MapLedger)

      # A fresh ledger process rebuilds assignments + leases from the directory on
      # boot — the region is routable WITHOUT re-materialization.
      ledger2 = start_supervised!({MapLedger, [name: :dur_ledger_b] ++ opts})

      assert {:ok, routed} = MapLedger.route_chunk(ledger2, 1, {3, 0, 3})
      assert routed.region_id == region_id
      assert routed.assigned_scene_node == node()
      assert routed.owner_epoch == assignment.owner_epoch

      assert {:ok, %{lease: restored_lease}} =
               MapLedger.route_chunk_with_lease(ledger2, 1, {3, 0, 3})

      assert restored_lease.lease_id == lease.lease_id
      assert restored_lease.expires_at_ms == lease.expires_at_ms
    end

    test "materialization writes exactly one directory row per region (O(1), not a whole-state blob)",
         %{registry: registry} do
      ledger =
        start_supervised!(
          {MapLedger,
           name: :dur_ledger_c,
           write_token_store: WriteTokenStore,
           scene_node_registry: registry,
           region_directory: RegionDirectoryStore}
        )

      # Two chunks in the same grid region → one region → one row.
      assert {:ok, _} = MapLedger.route_chunk_with_lease_ensuring(ledger, 1, {0, 0, 0})
      assert {:ok, _} = MapLedger.route_chunk_with_lease_ensuring(ledger, 1, {1, 0, 1})
      assert length(RegionDirectoryStore.load_all()) == 1

      # A chunk in a different grid region → a second row.
      assert {:ok, _} = MapLedger.route_chunk_with_lease_ensuring(ledger, 1, {8, 0, 0})
      assert length(RegionDirectoryStore.load_all()) == 2
    end
  end

  defp build_migration_plan(migration_id) do
    now_ms = System.system_time(:millisecond)

    %MigrationPlan{
      migration_id: migration_id,
      logical_scene_id: 1,
      region_id: 10,
      source_scene_instance_ref: 1_000,
      target_scene_instance_ref: 2_000,
      new_lease: %{lease_id: 101, owner_epoch: 2},
      affected_chunk_min: {0, 0, 0},
      affected_chunk_max: {2, 2, 2},
      token_version: 2,
      inserted_at_ms: now_ms,
      updated_at_ms: now_ms
    }
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
