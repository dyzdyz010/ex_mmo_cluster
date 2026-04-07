defmodule DataService.Interface do
  use GenServer
  require Logger

  @resource :data_service

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{data_contact: nil, server_state: :waiting_requirements}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting data_service node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    {:ok, data_contact_node} = BeaconServer.Client.await(:data_contact)
    Logger.info("Found data_contact at #{inspect(data_contact_node)}", ansi_color: :green)

    DataInit.copy_database(data_contact_node, :service)

    :ok =
      GenServer.call(
        {DataContact.NodeManager, data_contact_node},
        {:register, node(), :service}
      )

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | data_contact: data_contact_node, server_state: :ready}}
  end
end
