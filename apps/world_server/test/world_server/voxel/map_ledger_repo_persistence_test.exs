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
  alias WorldServer.Voxel.RegionAssignment

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
    assert revived_plan.state == :prewarming
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
end
