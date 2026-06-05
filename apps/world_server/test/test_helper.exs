# TransactionCoordinator persists through Postgres
# (DataService.Voxel.TransactionCoordinatorStore). Boot the same Repo +
# migration setup the data_service test suite uses so coordinator
# persistence tests can hit real `voxel_transaction_coordinator_rows` rows
# (阶段4 / world-2pc-4 行级增量持久化,取代旧的单行 snapshot 表)。
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

ExUnit.start(assert_receive_timeout: 1_000)
