defmodule DataStore.Interface do
  use GenServer

  require Logger

  @beacon :"beacon1@127.0.0.1"
  @resource :data_store
  @requirement [:data_contact]

  # 重试间隔：s
  @retry_rate 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{data_contact: nil, server_state: :waiting_requirements}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    establish_links()
    {:noreply, state}
  end

  # Connect to beacon and data_contact node, set up database
  defp establish_links() do
    connect_beacon()
    register_to_beacon()
    contact_node = get_requirements()
  end

  defp connect_beacon() do
    if !Node.connect(beacon) do
      Logger.emergency("Beacon node not up, exiting...")
      Application.stop(:data_store)
    end
  end

  defp register_to_beacon() do
    result =
      GenServer.call(
        {BeaconServer.Worker, @beacon},
        {:register, {node(), __MODULE__, @resource, @requirement}}
      )
    if result != :ok do
      Logger.emergency("Register to beacon node failed: #{inspect(result)}\nExiting...")
      Application.stop(:data_store)
    end
  end

  defp get_requirements() do
    offer =
      GenServer.call(
        {BeaconServer.Worker, @beacon},
        {:get_requirements, node()}
      )
    case offer do
      {:ok, [data_contact | _]} ->
        data_contact

    end
  end

  @impl true
  def handle_info({:join, beacon}, state) do
    case Node.connect(beacon) do
      true ->
        send(self(), :register)

      false ->
        Logger.emergency("Beacon node not up, exiting...")
        Application.stop(:data_service)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:register, state) do
    :ok =
      GenServer.call(
        {BeaconServer.Worker, @beacon},
        {:register, {node(), __MODULE__, @resource, @requirement}}
      )

    send(self(), :get_requirements)

    {:noreply, state}
  end

  @impl true
  def handle_info(:get_requirements, state) do
    offer =
      GenServer.call(
        {BeaconServer.Worker, @beacon},
        {:get_requirements, node()}
      )

    # IO.inspect(offer)

    case offer do
      {:ok, [data_contact | _]} ->
        DataInit.initialize(data_contact.node, :service)

        :ok =
          GenServer.call(
            {DataContact.NodeManager, data_contact.node},
            {:register, node(), :service}
          )

        Logger.debug("Requirements accuired, server ready.")
        {:noreply, %{state | data_contact: data_contact.node, server_state: :ready}}

      nil ->
        Logger.debug("Not meeting requirements, retrying in #{@retry_rate}s.")
        :timer.send_after(@retry_rate * 1000, :get_requirements)
        {:noreply, state}
    end
  end
end
