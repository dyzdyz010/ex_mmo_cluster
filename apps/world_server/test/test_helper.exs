# Phase 3: TransactionCoordinator persists through Postgres
# (DataService.Voxel.TransactionCoordinatorStore). Boot the same Repo +
# migration setup the data_service test suite uses so coordinator
# persistence tests can hit a real `voxel_transaction_coordinator_snapshots`
# row.
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

# 套件启动前清理共享 mmo_dev 库可能残留的陈旧事务快照,避免 TransactionRecoveryWatcher
# 启动时因 stale `:prepared` 快照崩溃(session-handoff 既有 backlog)。
for table <- ["voxel_transaction_coordinator_snapshots", "voxel_chunk_pending_transactions"] do
  Ecto.Adapters.SQL.query!(DataService.Repo, "TRUNCATE #{table}", [])
end

ExUnit.start(assert_receive_timeout: 1_000)
