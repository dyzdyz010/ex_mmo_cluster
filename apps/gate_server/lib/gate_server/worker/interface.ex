defmodule GateServer.Interface do
  use GenServer

  require Logger

  @beacon :"beacon1@127.0.0.1"
  @resource :gate_server
  @requirement [:auth_server]

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
    :ok =
      GenServer.call(
        {BeaconServer.Beacon, @beacon},
        {:register, {node(), __MODULE__, @resource, @requirement}}
      )

    send(self(), :get_requirements)

    {:noreply, state}
  end

  @impl true
  def handle_info(:get_requirements, state) do
    offer =
      GenServer.call(
        {BeaconServer.Beacon, @beacon},
        {:get_requirements, node()}
      )

    IO.inspect(offer)

    case offer do
      {:ok, auth_server} ->
        Logger.debug("Requirements accuired, server ready.")
        {:noreply, %{state | auth_server: auth_server, server_state: :ready}}

      nil ->
        Logger.debug("Not meeting requirements, retrying in #{@retry_rate}s.")
        # :timer.send_after(@retry_rate * 1000, :get_requirements)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:auth_server, _from, state) when length(state.auth_server) > 0 do
    {:reply, List.first(state.auth_server), state}
  end
end
