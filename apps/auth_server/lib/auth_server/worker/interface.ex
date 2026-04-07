defmodule AuthServer.Interface do
  use GenServer
  require Logger

  @resource :auth_server
  @retry_rate 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{data_contact: nil, data_service: nil, server_state: :waiting_requirements},
     {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting auth_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    {:ok, data_contact_node} = BeaconServer.Client.await(:data_contact)
    Logger.info("Found data_contact at #{inspect(data_contact_node)}", ansi_color: :green)

    data_service_node = get_data_service(data_contact_node)
    Logger.info("Found data_service at #{inspect(data_service_node)}", ansi_color: :green)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)

    {:noreply,
     %{
       state
       | data_contact: data_contact_node,
         data_service: data_service_node,
         server_state: :ready
     }}
  end

  defp get_data_service(data_contact_node) do
    case GenServer.call({DataContact.NodeManager, data_contact_node}, :get_node) do
      {:ok, node} ->
        node

      {:err, _err} ->
        Logger.warning("data_service not yet available, retrying in #{@retry_rate}s.")
        Process.sleep(@retry_rate * 1000)
        get_data_service(data_contact_node)
    end
  end

  @impl true
  def handle_call(:data_service, _from, state) do
    {:reply, state.data_service, state}
  end
end
