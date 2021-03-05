defmodule GameServerManager.Interface do
  use GenServer

  require Logger

  @beacon :"beacon1@127.0.0.1"
  @resource :game_server_manager
  @requirement :game_server

  # 重试间隔：s
  @retry_rate 1

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{game_server: [], server_state: :waiting_requirements}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    send(self(), {:join, @beacon})
    {:noreply, state}
  end

  @impl true
  def handle_info({:join, beacon}, state) do
    true = Node.connect(beacon)
    send(self(), :register)
    #   :pong ->
    #     register()
    #   _ ->
    #     Logger.warning("Beacon #{@beacon} not reachable, retrying in 1s.")
    #     :timer.send_after(500, {:join, beacon})
    #     []
    # end

    {:noreply, state}
  end

  @impl true
  def handle_info(:register, state) do
    offer =
      GenServer.call(
        {BeaconServer.Worker, @beacon},
        {:register, {node(), __MODULE__, @resource, @requirement}}
      )

    Logger.debug("Recieve offer: #{offer}")

    case offer do
      {:ok, game_server_list} ->
        {:noreply, %{state | game_server: game_server_list, server_state: :ready}}

      nil ->
        Logger.debug("Not meeting requirements, retrying in #{@retry_rate}s.")
        # :timer.send_after(@retry_rate * 1000, :register)
        {:noreply, state}
    end
  end
end
