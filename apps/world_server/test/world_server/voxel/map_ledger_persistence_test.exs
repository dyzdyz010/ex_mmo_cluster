defmodule WorldServer.Voxel.MapLedgerPersistenceTest do
  use ExUnit.Case, async: false

  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.MigrationPlan
  alias WorldServer.Voxel.RegionAssignment
  alias WorldServer.CliObserve

  setup do
    tmp_dir = System.tmp_dir!()
    name = "voxel_map_ledger_#{System.unique_integer([:positive, :monotonic])}.bin"
    path = Path.join(tmp_dir, name)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "round-trips region assignments + leases through file persistence", %{path: path} do
    ledger = start_supervised!({MapLedger, persistence_path: path}, id: :first_ledger)

    assert {:ok, %RegionAssignment{}} =
             MapLedger.put_region(ledger,
               logical_scene_id: 7,
               region_id: 70,
               owner_scene_instance_ref: 700,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 4, 4},
               assigned_scene_node: node(),
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 70, 700,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert File.exists?(path)
    payload = File.read!(path)
    assert byte_size(payload) > 0

    snapshot = MapLedger.snapshot(ledger)
    assert Map.has_key?(snapshot.assignments, 70)
    assert Map.has_key?(snapshot.leases, 70)

    stop_supervised!(:first_ledger)

    revived = start_supervised!({MapLedger, persistence_path: path}, id: :revived_ledger)

    revived_snapshot = MapLedger.snapshot(revived)
    assert Map.has_key?(revived_snapshot.assignments, 70)
    assert Map.has_key?(revived_snapshot.leases, 70)
    assert revived_snapshot.assignments[70].owner_scene_instance_ref == 700
  end

  test "rebuilds route index from persisted active assignments", %{path: path} do
    ledger = start_supervised!({MapLedger, persistence_path: path}, id: :indexed_ledger)

    assert {:ok, %RegionAssignment{}} =
             MapLedger.put_region(ledger,
               logical_scene_id: 7,
               region_id: 71,
               owner_scene_instance_ref: 710,
               owner_epoch: 1,
               bounds_chunk_min: {-32, 0, 0},
               bounds_chunk_max: {-16, 1, 1},
               assigned_scene_node: node()
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 71, 710,
               lease_id: 701,
               owner_epoch: 2,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    stop_supervised!(:indexed_ledger)

    revived = start_supervised!({MapLedger, persistence_path: path}, id: :revived_indexed_ledger)

    assert %{
             strategy: :scene_bucket_grid_v1,
             scene_count: 1,
             region_count: 1,
             scenes: [%{logical_scene_id: 7, region_ids: [71]}]
           } = MapLedger.route_index_stats(revived)

    assert {:ok, %{assignment: assignment, lease: lease}} =
             MapLedger.route_chunk_with_lease(revived, 7, {-17, 0, 0})

    assert assignment.region_id == 71
    assert lease.lease_id == 701

    window =
      MapLedger.route_window_with_leases(revived, 7, {-17, 0, 0},
        near_radius: 0,
        halo_radius: 0
      )

    assert [
             %{
               chunk_coord: {-17, 0, 0},
               status: :assigned,
               region_id: 71,
               lease_id: 701
             }
           ] = window.route_entries
  end

  test "init survives an empty/missing persistence file", %{path: path} do
    refute File.exists?(path)
    ledger = start_supervised!({MapLedger, persistence_path: path}, id: :empty_ledger)

    snapshot = MapLedger.snapshot(ledger)
    assert snapshot.assignments == %{}
    assert snapshot.leases == %{}
    assert snapshot.migrations == %{}
  end

  test "migration plans round-trip through file persistence", %{path: path} do
    ledger = start_supervised!({MapLedger, persistence_path: path}, id: :migration_ledger)

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger,
               logical_scene_id: 8,
               region_id: 80,
               owner_scene_instance_ref: 800,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 1, 1},
               assigned_scene_node: node(),
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 80, 800,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert {:ok, plan} = MapLedger.begin_migration(ledger, 80, 900, owner_epoch: 2)
    migration_id = plan.migration_id

    stop_supervised!(:migration_ledger)

    revived = start_supervised!({MapLedger, persistence_path: path}, id: :revived_migration)
    snapshot = MapLedger.snapshot(revived)
    assert Map.has_key?(snapshot.migrations, migration_id)

    revived_plan = snapshot.migrations[migration_id]
    assert revived_plan.target_scene_instance_ref == 900
    assert revived_plan.target_scene_node == node()
    assert revived_plan.state == :prewarming
  end

  test "upgrades legacy migration plans without source scene node from file persistence", %{
    path: path
  } do
    ledger = start_supervised!({MapLedger, persistence_path: path}, id: :legacy_migration_ledger)

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger,
               logical_scene_id: 8,
               region_id: 81,
               owner_scene_instance_ref: 810,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 1, 1},
               assigned_scene_node: :legacy_source@local,
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 81, 810,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert {:ok, plan} =
             MapLedger.begin_migration(ledger, 81, 910,
               owner_epoch: 2,
               target_scene_node: :legacy_target@local
             )

    snapshot = MapLedger.snapshot(ledger)
    legacy_plan = legacy_plan_without_source_scene_node(snapshot.migrations[plan.migration_id])

    payload =
      snapshot
      |> Map.take([:assignments, :leases, :chunk_summaries, :migrations])
      |> put_in([:migrations, plan.migration_id], legacy_plan)

    File.write!(path, :erlang.term_to_binary(payload))
    stop_supervised!(:legacy_migration_ledger)

    revived =
      start_supervised!({MapLedger, persistence_path: path}, id: :revived_legacy_migration)

    assert {:ok, handoff} = MapLedger.migration_handoff(revived, plan.migration_id)
    assert handoff.source_scene_node == :legacy_source@local
    assert handoff.target_scene_node == :legacy_target@local
  end

  test "restores completed legacy migration plans without source scene node from file persistence",
       %{
         path: path
       } do
    ledger =
      start_supervised!({MapLedger, persistence_path: path}, id: :completed_legacy_migration)

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger,
               logical_scene_id: 8,
               region_id: 82,
               owner_scene_instance_ref: 820,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: :completed_source@local,
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 82, 820,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert {:ok, plan} =
             MapLedger.begin_migration(ledger, 82, 920,
               owner_epoch: 2,
               target_scene_node: :completed_target@local
             )

    assert {:ok, slice} = MapLedger.plan_next_migration_slice(ledger, plan.migration_id)

    assert {:ok, _plan, _slice} =
             MapLedger.mark_slice_prewarmed(ledger, plan.migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 920
             })

    assert {:ok, _plan} = MapLedger.mark_prewarmed(ledger, plan.migration_id)

    assert {:ok, _plan, _slice} =
             MapLedger.mark_slice_final_caught_up(ledger, plan.migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 920
             })

    assert {:ok, _plan} = MapLedger.cutover_migration(ledger, plan.migration_id)
    assert {:ok, _plan} = MapLedger.complete_migration(ledger, plan.migration_id)

    snapshot = MapLedger.snapshot(ledger)
    legacy_plan = legacy_plan_without_source_scene_node(snapshot.migrations[plan.migration_id])

    payload =
      snapshot
      |> Map.take([:assignments, :leases, :chunk_summaries, :migrations])
      |> put_in([:migrations, plan.migration_id], legacy_plan)

    File.write!(path, :erlang.term_to_binary(payload))
    stop_supervised!(:completed_legacy_migration)

    revived =
      start_supervised!({MapLedger, persistence_path: path}, id: :revived_completed_legacy)

    assert {:ok, handoff} = MapLedger.migration_handoff(revived, plan.migration_id)
    assert handoff.state == :completed
    assert handoff.source_scene_node == :legacy_source_scene_node_unavailable
    assert handoff.target_scene_node == :completed_target@local
  end

  test "rejects unsafe active legacy migration plans from file persistence with observe reason",
       %{
         path: path
       } do
    observe_log =
      Path.join(System.tmp_dir!(), "world-map-ledger-legacy-reject-#{unique_id()}.log")

    previous_observe_log = Application.fetch_env(:world_server, :cli_observe_log)
    Application.put_env(:world_server, :cli_observe_log, observe_log)
    on_exit(fn -> restore_env(:world_server, previous_observe_log) end)

    ledger = start_supervised!({MapLedger, persistence_path: path}, id: :unsafe_legacy_ledger)

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger,
               logical_scene_id: 8,
               region_id: 83,
               owner_scene_instance_ref: 830,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 1, 1},
               assigned_scene_node: :unsafe_source@local,
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 83, 830,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert {:ok, plan} =
             MapLedger.begin_migration(ledger, 83, 930,
               owner_epoch: 2,
               target_scene_node: :unsafe_target@local
             )

    snapshot = MapLedger.snapshot(ledger)
    legacy_plan = legacy_plan_without_source_scene_node(snapshot.migrations[plan.migration_id])
    drifted_assignment = %{snapshot.assignments[83] | owner_scene_instance_ref: 999}

    payload =
      snapshot
      |> Map.take([:assignments, :leases, :chunk_summaries, :migrations])
      |> put_in([:assignments, 83], drifted_assignment)
      |> put_in([:migrations, plan.migration_id], legacy_plan)

    File.write!(path, :erlang.term_to_binary(payload))
    stop_supervised!(:unsafe_legacy_ledger)

    revived = start_supervised!({MapLedger, persistence_path: path}, id: :revived_unsafe_legacy)
    CliObserve.flush()

    snapshot_after = MapLedger.snapshot(revived)
    assert snapshot_after.assignments == %{}
    assert snapshot_after.migrations == %{}

    log = File.read!(observe_log)
    assert log =~ ~s(event="voxel_map_ledger_persist_load_failed")
    assert log =~ "legacy_migration_source_scene_node_unavailable"
  end

  defp legacy_plan_without_source_scene_node(%MigrationPlan{} = plan) do
    plan
    |> Map.from_struct()
    |> Map.delete(:source_scene_node)
    |> Map.put(:__struct__, MigrationPlan)
  end

  defp unique_id, do: System.unique_integer([:positive, :monotonic])

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)
end
