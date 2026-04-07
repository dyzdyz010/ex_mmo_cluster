defmodule AgentManager.Interface do
  use GenServer

  require Logger

  @resource :agent_manager
  @requirement []

  # 重试间隔：s
  @retry_rate 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{server_state: :waiting_requirements}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    send(self(), :join)
    {:noreply, state}
  end

  @impl true
  def handle_info(:join, state) do
    case BeaconServer.Client.join_cluster() do
      :ok -> send(self(), :register)
      :error -> Logger.emergency("Beacon node not up, exiting...")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:register, state) do
    :ok = BeaconServer.Client.register(node(), __MODULE__, @resource, @requirement)

    send(self(), :get_requirements)

    {:noreply, state}
  end

  @impl true
  def handle_info(:get_requirements, state) do
    offer = BeaconServer.Client.get_requirements(node())

    IO.inspect(offer)

    case offer do
      {:ok, dao_server_manager} ->
        Logger.debug("Requirements accuired, server ready.")
        {:noreply, %{state | dao_server_manager: dao_server_manager, server_state: :ready}}

      nil ->
        Logger.debug("Not meeting requirements, retrying in #{@retry_rate}s.")
        :timer.send_after(@retry_rate * 1000, :get_requirements)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:auth_server, _from, state) when length(state.auth_server)>0 do
    {:reply, List.first(state.auth_server), state}
  end
end
