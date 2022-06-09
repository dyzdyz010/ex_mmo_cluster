defmodule DataInit do
  @moduledoc """
  Documentation for `DataInit`.
  """
  alias DataInit.TableDef
  require Logger

  @spec initialize(node(), atom()) :: list()
  def initialize(contact, role) do
    # db_list = :rpc.call(contact, DataContact.Interface, :db_list, [])
    data_store_list = GenServer.call({DataContact.NodeManager, contact}, :db_list)

    case data_store_list do
      [] ->
        case role do
          :service ->
            {:err,
             {:no_data_store,
              "There's no data_store node running, start it before data_service node."}}

          :store ->
            create_database(data_store_list, :store)
        end

      _ ->
        copy_database(data_store_list, role)
    end
  end

  @spec create_database([node()], atom()) :: list()
  def create_database(_store_list, role) do
    Logger.info("Creating database...", ansi_color: :yellow)
    Memento.stop()
    Memento.Schema.create([node()])
    Memento.start()

    create_tables(role)
  end

  @spec copy_database([node()], atom()) :: list()
  def copy_database(store_list, role) do
    Memento.start()
    {:ok, _} = Memento.add_nodes(store_list)
    Memento.Table.set_storage_type(:schema, node(), :disc_copies)

    copy_tables(role)
  end

  defp create_tables(role) do
    Logger.info("Creating tables...", ansi_color: :yellow)
    table_defs = TableDef.tables()
    Logger.info("Tables to be created: #{inspect(table_defs, pretty: true)}")

    Enum.map(
      table_defs,
      fn t ->
        case role do
          :service -> Memento.Table.create(t, ram_copies: [node()])
          :store -> Memento.Table.create(t, disc_only_copies: [node()])
        end
      end
    )
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
  end
end
