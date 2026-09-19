# 只测试：先建库迁移，再由 DataService.Application 在整套测试期间持有 Repo。
# Repo 不能链接到单个测试进程，否则下一测试可能复用正在退出的 Repo。
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

# 套件启动前清理共享 mmo_dev 库可能残留的陈旧事务快照(session-handoff 既有 backlog)。
# gate test_helper 不常驻 Repo,故用 with_repo 临时起一个执行 TRUNCATE。
{:ok, _, _} =
  Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
    for table <- ["voxel_transaction_coordinator_snapshots", "voxel_chunk_pending_transactions"] do
      Ecto.Adapters.SQL.query!(repo, "TRUNCATE #{table}", [])
    end
  end)

# 迁移用的临时 Repo 已退出；正式应用统一拥有后续测试共享的持久化进程。
{:ok, _} = Application.ensure_all_started(:data_service)

# Phase 1d: voxel chunk persistence is real PostgreSQL via Ecto, so apply
# paths take O(10ms) per write instead of microseconds for the old in-memory
# map. Bump the default `assert_receive` window so existing 100ms tests
# don't flake while waiting for `persist_snapshot` to commit.
ExUnit.start(assert_receive_timeout: 1_000)
