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
    send(self(), :establish_links)
    {:noreply, state}
  end

  @impl true
  def handle_info(:establish_links, state) do
    Logger.info("===Starting data_store node initialization===", ansi_color: :blue)

    join_beacon()
    register_beacon()
    new_state = get_requirements(state)
    join_data_contact(new_state)
    setup_database(new_state)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{new_state | server_state: :ready}}
  end

  defp join_beacon() do
    Logger.info("Joining beacon...")

    if !Node.connect(@beacon) do
      Logger.emergency("Beacon node not up, exiting...")
      Application.stop(:data_store)
    end

    Logger.info("Joining beacon complete.", ansi_color: :green)
  end

  defp register_beacon() do
    Logger.info("Registering to beacon...")

    result =
      GenServer.call(
        {BeaconServer.Beacon, @beacon},
        {:register, {node(), __MODULE__, @resource, @requirement}}
      )

    if result != :ok do
      Logger.emergency("Register to beacon node failed: #{inspect(result)}\nExiting...")
      Application.stop(:data_store)
    end

    Logger.info("Registering to beacon complete", ansi_color: :green)
  end

  defp get_requirements(state) do
    Logger.info("Getting requirements(#{inspect(@requirement)}) from beacon...")

    offer =
      GenServer.call(
        {BeaconServer.Beacon, @beacon},
        {:get_requirements, node()}
      )

    # IO.inspect(offer)

    case offer do
      {:ok, [data_contact | _]} ->
        Logger.info("Got data_contact node from beacon: #{inspect(data_contact.node)}.",
          ansi_color: :blue
        )

        # DataInit.initialize(data_contact.node, :store)

        Logger.info("Getting requirements(#{inspect(@requirement)}) from beacon complete.",
          ansi_color: :green
        )

        %{state | data_contact: data_contact.node}

      nil ->
        Logger.warn("Not meeting requirements, retrying in #{@retry_rate}s.")
        Process.sleep(@retry_rate * 1000)
        get_requirements(state)
    end
  end

  defp join_data_contact(%{data_contact: data_contact}) do
    Logger.info("Joining data_contact...")

    result =
      GenServer.call(
        {DataContact.NodeManager, data_contact},
        {:register, node(), :store}
      )

    if result != :ok do
      Logger.emergency("Join data_contact node failed: \n #{inspect(result)}\nExiting...")
      Application.stop(:data_store)
    end

    Logger.info("Joining data_contact complete.", ansi_color: :green)
  end

  defp setup_database(%{data_contact: data_contact}) do
    store_role = Application.get_env(:data_store, :store_role, :slave)
    Logger.info("This is a #{store_role} store database.")
    if store_role == :slave do
      DataInit.copy_database(data_contact, :store)
    end
  end
end
