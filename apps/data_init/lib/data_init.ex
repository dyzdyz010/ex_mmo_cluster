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

  @doc """
  Copy database from other mnesia nodes.

  ## Parameters

  `data_contact` - The contact node

  `role` - The role of the node, either `:service` or `:store`
  """
  @spec copy_database(node(), :service | :store) :: :ok
  def copy_database(data_contact, role) do
    data_store_list = GenServer.call({DataContact.NodeManager, data_contact}, :db_list)
    Memento.start()
    {:ok, _} = Memento.add_nodes(data_store_list)
    Memento.Table.set_storage_type(:schema, node(), :disc_copies)

    copy_tables(role)
  end

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

  defp copy_tables(role) do
    Logger.info("Copying tables...", ansi_color: :yellow)
    table_defs = TableDef.tables()
    Logger.info("Tables to be copied: #{inspect(table_defs, pretty: true)}")

    Enum.map(
      table_defs,
      fn t ->
        case role do
          :service -> Memento.Table.create_copy(t, node(), :ram_copies)
          :store -> Memento.Table.create_copy(t, node(), :disc_only_copies)
        end
      end
    )

    Memento.wait(table_defs)
    Logger.info("Copying tables complete.", ansi_color: :green)
  end

  :ok
end
