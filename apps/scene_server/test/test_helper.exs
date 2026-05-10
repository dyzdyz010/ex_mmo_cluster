# Voxel chunk persistence (`DataService.Voxel.ChunkSnapshotStore`) writes to
# PostgreSQL via Ecto since Phase 1d. Boot the same Repo + migration setup
# the data_service test suite uses so scene tests that exercise persist
# paths can hit a real `voxel_chunks` row.
Application.ensure_all_started(:jason)
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)

repo_config = DataService.Repo.config()

case Ecto.Adapters.Postgres.storage_up(repo_config) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

case DataService.Repo.start_link() do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

migrations_path =
  Path.expand("../../data_service/priv/repo/migrations", __DIR__)

{:ok, _, _} =
  Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
    Ecto.Migrator.run(repo, migrations_path, :up, all: true)
  end)

# Phase A4-bis: scene-side region routing tests (`RegionRouting`,
# `RegionRuntime` Phase A4-bis-3 e2e) call `BeaconServer.Client.register`
# / `lookup`, which require a Horde registry. Boot it once here so the
# CRDT keys ETS table has time to settle before any test touches it
# (per-test `start_link` from a `setup` block races with Horde init).
case Horde.Registry.start_link(
       name: BeaconServer.DistributedRegistry,
       keys: :unique,
       members: :auto
     ) do
  {:ok, _} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Phase 1d: voxel chunk persistence is real PostgreSQL via Ecto. Bump the
# default `assert_receive` window so tests waiting on apply→persist→delta
# round trips don't flake on a real DB INSERT.
ExUnit.start(exclude: [:smoke], assert_receive_timeout: 1_000)
