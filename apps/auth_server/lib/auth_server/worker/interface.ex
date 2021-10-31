defmodule AuthServer.Interface do
  use GenServer

  require Logger

  @beacon :"beacon1@127.0.0.1"
  @resource :auth_server
  @requirement [:agent_manager]

  # 重试间隔：s
  @retry_rate 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{agent_manager: [], server_state: :waiting_requirements}, 0}
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

    {:noreply, state}
  end

  @impl true
  def handle_info(:register, state) do
    :ok = GenServer.call(
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

    IO.inspect(offer)

    case offer do
      {:ok, game_server_manager_list} ->
        Logger.debug("Requirements accuired, server ready.")
        {:noreply, %{state | game_server_manager: game_server_manager_list, server_state: :ready}}

      nil ->
        Logger.debug("Not meeting requirements, retrying in #{@retry_rate}s.")
        # :timer.send_after(@retry_rate * 1000, :get_requirements)
        {:noreply, state}
    end
  end
end
