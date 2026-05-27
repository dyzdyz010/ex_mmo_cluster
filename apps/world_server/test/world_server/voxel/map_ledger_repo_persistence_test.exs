defmodule WorldServer.Voxel.MapLedgerRepoPersistenceTest do
  @moduledoc """
  End-to-end test for MapLedger persisted through DataService.Repo.

  This test brings up the data_service repo locally because the umbrella's
  default world_server test_helper does not start it. Tests are tagged with
  `:postgres` so a developer who does not have a Postgres server can opt out
  via `mix test --exclude postgres`.
  """

  use ExUnit.Case, async: false

  @moduletag :postgres

  alias DataService.Repo
  alias DataService.Voxel.MapLedgerStore
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.MigrationPlan
  alias WorldServer.Voxel.RegionAssignment
  alias WorldServer.CliObserve

  setup_all do
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)

    case Ecto.Adapters.Postgres.storage_up(Repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    migrations_path =
      Application.app_dir(:data_service, "priv/repo/migrations")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    :ok
  end

  setup do
    Repo.query!("TRUNCATE TABLE voxel_map_ledger_snapshots", [])
    :ok
  end

  test "MapLedger restores assignments + leases from Postgres after restart" do
    persist = MapLedgerStore.persist_fn(Repo)
    load = MapLedgerStore.load_fn(Repo)

    ledger =
      start_supervised!({MapLedger, [persist_fn: persist, load_fn: load]}, id: :first_repo_ledger)

    assert {:ok, %RegionAssignment{}} =
             MapLedger.put_region(ledger,
               logical_scene_id: 9,
               region_id: 90,
               owner_scene_instance_ref: 900,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 4, 4},
               assigned_scene_node: node(),
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 90, 900,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    snapshot = MapLedger.snapshot(ledger)
    assert Map.has_key?(snapshot.assignments, 90)
    assert Map.has_key?(snapshot.leases, 90)

    stop_supervised!(:first_repo_ledger)

    revived =
      start_supervised!(
        {MapLedger, [persist_fn: persist, load_fn: load]},
        id: :revived_repo_ledger
      )

    revived_snapshot = MapLedger.snapshot(revived)
    assert Map.has_key?(revived_snapshot.assignments, 90)
    assert Map.has_key?(revived_snapshot.leases, 90)
    assert revived_snapshot.assignments[90].owner_scene_instance_ref == 900
  end

  test "MapLedger restores in-flight migration plans from Postgres after restart" do
    persist = MapLedgerStore.persist_fn(Repo)
    load = MapLedgerStore.load_fn(Repo)

    ledger =
      start_supervised!({MapLedger, [persist_fn: persist, load_fn: load]},
        id: :first_repo_migration
      )

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger,
               logical_scene_id: 11,
               region_id: 110,
               owner_scene_instance_ref: 1100,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 1, 1},
               assigned_scene_node: node(),
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 110, 1100,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert {:ok, plan} = MapLedger.begin_migration(ledger, 110, 1200, owner_epoch: 2)

    stop_supervised!(:first_repo_migration)

    revived =
      start_supervised!(
        {MapLedger, [persist_fn: persist, load_fn: load]},
        id: :revived_repo_migration
      )

    revived_snapshot = MapLedger.snapshot(revived)
    revived_plan = revived_snapshot.migrations[plan.migration_id]
    assert revived_plan.target_scene_instance_ref == 1200
    assert revived_plan.target_scene_node == node()
    assert revived_plan.state == :prewarming
  end

  test "MapLedger upgrades legacy migration plans without source scene node from Postgres" do
    persist = MapLedgerStore.persist_fn(Repo)
    load = MapLedgerStore.load_fn(Repo)

    ledger =
      start_supervised!({MapLedger, [persist_fn: persist, load_fn: load]},
        id: :first_repo_legacy_migration
      )

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger,
               logical_scene_id: 12,
               region_id: 120,
               owner_scene_instance_ref: 1200,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 1, 1},
               assigned_scene_node: :repo_legacy_source@local,
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 120, 1200,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert {:ok, plan} =
             MapLedger.begin_migration(ledger, 120, 1300,
               owner_epoch: 2,
               target_scene_node: :repo_legacy_target@local
             )

    snapshot = MapLedger.snapshot(ledger)
    legacy_plan = legacy_plan_without_source_scene_node(snapshot.migrations[plan.migration_id])

    payload =
      snapshot
      |> Map.take([:assignments, :leases, :chunk_summaries, :migrations])
      |> put_in([:migrations, plan.migration_id], legacy_plan)

    assert :ok = MapLedgerStore.save_state(Repo, payload)
    stop_supervised!(:first_repo_legacy_migration)

    revived =
      start_supervised!(
        {MapLedger, [persist_fn: persist, load_fn: load]},
        id: :revived_repo_legacy_migration
      )

    assert {:ok, handoff} = MapLedger.migration_handoff(revived, plan.migration_id)
    assert handoff.source_scene_node == :repo_legacy_source@local
    assert handoff.target_scene_node == :repo_legacy_target@local
  end

  test "MapLedger restores completed legacy migration plans without source scene node from Postgres" do
    persist = MapLedgerStore.persist_fn(Repo)
    load = MapLedgerStore.load_fn(Repo)

    ledger =
      start_supervised!({MapLedger, [persist_fn: persist, load_fn: load]},
        id: :first_repo_completed_legacy
      )

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger,
               logical_scene_id: 12,
               region_id: 121,
               owner_scene_instance_ref: 1210,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: :repo_completed_source@local,
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 121, 1210,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert {:ok, plan} =
             MapLedger.begin_migration(ledger, 121, 1310,
               owner_epoch: 2,
               target_scene_node: :repo_completed_target@local
             )

    assert {:ok, slice} = MapLedger.plan_next_migration_slice(ledger, plan.migration_id)

    assert {:ok, _plan, _slice} =
             MapLedger.mark_slice_prewarmed(ledger, plan.migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 1310
             })

    assert {:ok, _plan} = MapLedger.mark_prewarmed(ledger, plan.migration_id)

    assert {:ok, _plan, _slice} =
             MapLedger.mark_slice_final_caught_up(ledger, plan.migration_id, %{
               slice_id: slice.slice_id,
               scene_ref: 1310
             })

    assert {:ok, _plan} = MapLedger.cutover_migration(ledger, plan.migration_id)
    assert {:ok, _plan} = MapLedger.complete_migration(ledger, plan.migration_id)

    snapshot = MapLedger.snapshot(ledger)
    legacy_plan = legacy_plan_without_source_scene_node(snapshot.migrations[plan.migration_id])

    payload =
      snapshot
      |> Map.take([:assignments, :leases, :chunk_summaries, :migrations])
      |> put_in([:migrations, plan.migration_id], legacy_plan)

    assert :ok = MapLedgerStore.save_state(Repo, payload)
    stop_supervised!(:first_repo_completed_legacy)

    revived =
      start_supervised!(
        {MapLedger, [persist_fn: persist, load_fn: load]},
        id: :revived_repo_completed_legacy
      )

    assert {:ok, handoff} = MapLedger.migration_handoff(revived, plan.migration_id)
    assert handoff.state == :completed
    assert handoff.source_scene_node == :legacy_source_scene_node_unavailable
    assert handoff.target_scene_node == :repo_completed_target@local
  end

  test "MapLedger rejects unsafe active legacy migration plans from Postgres with observe reason" do
    persist = MapLedgerStore.persist_fn(Repo)
    load = MapLedgerStore.load_fn(Repo)

    observe_log =
      Path.join(System.tmp_dir!(), "world-map-ledger-repo-legacy-reject-#{unique_id()}.log")

    previous_observe_log = Application.fetch_env(:world_server, :cli_observe_log)
    Application.put_env(:world_server, :cli_observe_log, observe_log)
    on_exit(fn -> restore_env(:world_server, previous_observe_log) end)

    ledger =
      start_supervised!({MapLedger, [persist_fn: persist, load_fn: load]},
        id: :first_repo_unsafe_legacy
      )

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger,
               logical_scene_id: 12,
               region_id: 122,
               owner_scene_instance_ref: 1220,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 1, 1},
               assigned_scene_node: :repo_unsafe_source@local,
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 122, 1220,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert {:ok, plan} =
             MapLedger.begin_migration(ledger, 122, 1320,
               owner_epoch: 2,
               target_scene_node: :repo_unsafe_target@local
             )

    snapshot = MapLedger.snapshot(ledger)
    legacy_plan = legacy_plan_without_source_scene_node(snapshot.migrations[plan.migration_id])
    drifted_assignment = %{snapshot.assignments[122] | owner_scene_instance_ref: 999}

    payload =
      snapshot
      |> Map.take([:assignments, :leases, :chunk_summaries, :migrations])
      |> put_in([:assignments, 122], drifted_assignment)
      |> put_in([:migrations, plan.migration_id], legacy_plan)

    assert :ok = MapLedgerStore.save_state(Repo, payload)
    stop_supervised!(:first_repo_unsafe_legacy)

    revived =
      start_supervised!(
        {MapLedger, [persist_fn: persist, load_fn: load]},
        id: :revived_repo_unsafe_legacy
      )

    CliObserve.flush()

    snapshot_after = MapLedger.snapshot(revived)
    assert snapshot_after.assignments == %{}
    assert snapshot_after.migrations == %{}

    log = File.read!(observe_log)
    assert log =~ ~s(event="voxel_map_ledger_persist_load_failed")
    assert log =~ "legacy_migration_source_scene_node_unavailable"
  end

  test "missing snapshot row leaves the ledger empty without raising" do
    persist = MapLedgerStore.persist_fn(Repo)
    load = MapLedgerStore.load_fn(Repo)

    Repo.query!("TRUNCATE TABLE voxel_map_ledger_snapshots", [])

    ledger =
      start_supervised!({MapLedger, [persist_fn: persist, load_fn: load]}, id: :empty_repo_ledger)

    snapshot = MapLedger.snapshot(ledger)
    assert snapshot.assignments == %{}
    assert snapshot.leases == %{}
    assert snapshot.migrations == %{}
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
