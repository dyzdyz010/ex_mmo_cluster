defmodule SceneServer.Interface do
  use GenServer

  require Logger

  @beacon :"beacon1@127.0.0.1"
  @resource :scene_server
  # @requirement [:auth_server]
  @requirement []

  # 重试间隔：s
  @retry_rate 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{auth_server: [], server_state: :waiting_requirements}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    send(self(), :establish_links)
    {:noreply, state}
  end

  @impl true
  def handle_info(:establish_links, state) do
    Logger.info("===Starting #{Application.get_application(__MODULE__)} node initialization===", ansi_color: :blue)

    join_beacon()
    register_beacon()
    new_state = get_requirements(state)

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

    IO.inspect(offer)

    case offer do
      {:ok, []} ->
        # Logger.info("Got data_contact node from beacon: #{inspect(data_contact.node)}.",
        #   ansi_color: :blue
        # )

        # DataInit.initialize(data_contact.node, :store)

        Logger.info("Getting requirements(#{inspect(@requirement)}) from beacon complete.",
          ansi_color: :green
        )

        state

      nil ->
        Logger.warn("Not meeting requirements, retrying in #{@retry_rate}s.")
        Process.sleep(@retry_rate * 1000)
        get_requirements(state)
    end
  end

  @impl true
  def handle_call(:auth_server, _from, state) when length(state.auth_server) > 0 do
    {:reply, List.first(state.auth_server), state}
  end
end
