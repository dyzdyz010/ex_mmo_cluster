defmodule DataInit do
  @moduledoc """
  Documentation for `DataInit`.
  """
  alias DataInit.TableDef
  require Logger

  @doc """
  Create database.

  **Only called by the first node of database.**
  """
  @spec create_database() :: :ok
  def create_database() do
    Memento.stop()
    :ok = Memento.Schema.create([node()])
    Memento.start()
    create_tables()
    Memento.stop()
  end

  # 梯队4:旧多节点 Mnesia 集群复制助手 copy_database/2 + copy_tables/1 已随 data_contact /
  # data_store app 删除而移除(原依赖已删的 DataContact.NodeManager)。data_init 仅余 PostgreSQL
  # 迁移所需的一次性 Mnesia bootstrap(create_database)。主持久化路径见 DataService(Ecto/PG)。

  defp create_tables() do
    Logger.info("Creating tables...", ansi_color: :yellow)
    table_defs = TableDef.tables()
    Logger.info("Tables to be created: #{inspect(table_defs, pretty: true)}")

    Enum.map(
      table_defs,
      fn t ->
        :ok = Memento.Table.create(t, disc_only_copies: [node()])
      end
    )

    Memento.wait(table_defs)
    Logger.info("Creating tables complete.", ansi_color: :green)
    :ok
  end
end
