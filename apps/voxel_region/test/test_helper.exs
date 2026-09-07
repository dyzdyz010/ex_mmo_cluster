# World 测试走 DataService 表后端：起 Repo（umbrella test 配置 → mmo_test；本机 docker 要 MMO_DB_PORT=5433）并迁移。
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)

case Ecto.Adapters.Postgres.storage_up(DataService.Repo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

{:ok, _} = DataService.Repo.start_link()

{:ok, _, _} =
  Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
    Ecto.Migrator.run(repo, Path.expand("../../data_service/priv/repo/migrations", __DIR__), :up, all: true)
  end)

ExUnit.start(exclude: [:oracle])
