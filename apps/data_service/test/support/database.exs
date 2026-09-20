defmodule MmoTest.Database do
  @moduledoc "只测试：按需启动本次测试 VM 独占的数据库；纯测试不调用。"

  @doc "首次使用时建库迁移，随后由 DataService 应用持有 Repo。"
  def start! do
    :global.trans({__MODULE__, self()}, fn ->
      unless Application.get_env(:data_service, :test_database_started, false) do
        {:ok, _} = Application.ensure_all_started(:postgrex)
        {:ok, _} = Application.ensure_all_started(:ecto_sql)
        config = DataService.Repo.config()

        case Ecto.Adapters.Postgres.storage_up(config) do
          :ok -> :ok
          {:error, :already_up} -> :ok
        end

        {:ok, _, _} =
          Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
            Ecto.Migrator.run(repo, Path.expand("../../priv/repo/migrations", __DIR__), :up,
              all: true
            )
          end)

        {:ok, _} = Application.ensure_all_started(:data_service)
        Application.put_env(:data_service, :test_database_started, true)

        # 显式共享名称用于跨节点测试，由调用方管理生命周期；默认库只属于本 VM。
        unless System.get_env("MMO_TEST_DB_NAME") do
          ExUnit.after_suite(fn _ ->
            Application.stop(:data_service)
            :ok = Ecto.Adapters.Postgres.storage_down(config)
          end)
        end
      end
    end)
  end
end
