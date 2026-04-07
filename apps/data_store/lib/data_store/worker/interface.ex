defmodule DataStore.Interface do
  use GenServer
  require Logger

  @resource :data_store

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{data_contact: nil, server_state: :waiting_requirements}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting data_store node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    {:ok, data_contact_node} = BeaconServer.Client.await(:data_contact)
    Logger.info("Found data_contact at #{inspect(data_contact_node)}", ansi_color: :green)

    join_data_contact(data_contact_node)
    setup_database(data_contact_node)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | data_contact: data_contact_node, server_state: :ready}}
  end

  defp join_data_contact(data_contact_node) do
    result =
      GenServer.call(
        {DataContact.NodeManager, data_contact_node},
        {:register, node(), :store}
      )

    if result != :ok do
      Logger.emergency("Join data_contact node failed: #{inspect(result)}")
      Application.stop(:data_store)
    end

    Logger.info("Joining data_contact complete.", ansi_color: :green)
  end

  defp setup_database(data_contact_node) do
    store_role = Application.get_env(:data_store, :store_role, :slave)
    Logger.info("This is a #{store_role} store database.")

    if store_role == :slave do
      DataInit.copy_database(data_contact_node, :store)
    end
  end
end
