# Phase 1d: voxel chunk persistence is real PostgreSQL via
# `DataService.Voxel.ChunkSnapshotStore`. Prepare storage and migrations while
# letting `DataService.Application` own `DataService.Repo` startup; gate tests
# may start auth_server/data_service later and must not race a manual Repo boot.
Application.ensure_all_started(:jason)
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)

repo_config = DataService.Repo.config()

case Ecto.Adapters.Postgres.storage_up(repo_config) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

migrations_path =
  Path.expand("../../data_service/priv/repo/migrations", __DIR__)

{:ok, _, _} =
  Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
    Ecto.Migrator.run(repo, migrations_path, :up, all: true)
  end)

# Gate tests assert exact CLI observe logs while running after other umbrella
# apps. Reset process-independent observe routing and fallback env so events
# from a previous app/test cannot steal scene/world/gate breadcrumbs.
{:ok, _} = Application.ensure_all_started(:beacon_server)
:ok = BeaconServer.CliObserveRoutes.clear_all()

Enum.each([:chat_server, :gate_server, :scene_server, :world_server], fn app ->
  Application.delete_env(app, :cli_observe_log)
end)

# Many protocol unit tests place the connection directly in `:in_scene`
# instead of going through the real enter-scene handshake that seeds
# `partition_context`. Production keeps the fail-closed default.
Application.put_env(:gate_server, :allow_legacy_voxel_target_without_partition_context, true)

# Phase 1d: voxel chunk persistence is real PostgreSQL via Ecto, so apply
# paths take O(10ms) per write instead of microseconds for the old in-memory
# map. Bump the default `assert_receive` window so existing 100ms tests
# don't flake while waiting for `persist_snapshot` to commit.
ExUnit.start(assert_receive_timeout: 1_000)
