defmodule DataInit do
  @moduledoc """
  Documentation for `DataInit`.
  """
  alias DataInit.TableDef
  require Logger

  def initialize(contact, role) do
    # db_list = :rpc.call(contact, DataContact.Interface, :db_list, [])
    db_list = GenServer.call({DataContact.NodeManager, contact}, :db_list)

    case db_list do
      [] ->
        create_database(db_list, role)

      _ ->
        copy_database(db_list, role)
    end
  end

  def create_database(_store_list, role) do
    Logger.info("Creating database...")
    Memento.stop()
    Memento.Schema.create([node()])
    Memento.start()
    # :mnesia.create_schema([node()])
    # :mnesia.start()
    create_tables(role)
  end

  def copy_database(store_list, role) do
    :mnesia.start()
    result1 = :mnesia.change_config(:extra_db_nodes, store_list)
    IO.inspect(result1)
    result2 = :mnesia.change_table_copy_type(:schema, node(), :disc_copies)
    IO.inspect(result2)

    Enum.map(TableDef.user_table_list(), fn t ->
      :mnesia.add_table_copy(
        t,
        node(),
        case role do
          :service -> :ram_copies
          :store -> :disc_only_copies
        end
      )
    end)
  end

  def create_tables(role) do
    Logger.info("Creating tables...")
    table_defs = TableDef.tables()
    IO.inspect(table_defs)

    Enum.map(
      table_defs,
      fn t ->
        case role do
          :service -> Memento.Table.create(t, ram_copies: [node()])
          :store -> Memento.Table.create(t, disc_only_copies: [node()])
        end
        # :mnesia.create_table(t, [
        #   {:attributes, t.attributes},
        #   case role do
        #     :service -> {:ram_copies, [node()]}
        #     :store -> {:disc_only_copies, [node()]}
        #   end
        # ])
      end
    )
    |> IO.inspect()
    # Memento.Table.create(DataInit.TableDef.User.Account)
  end
end
