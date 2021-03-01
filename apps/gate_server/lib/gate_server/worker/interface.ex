defmodule GateServer.Interface do
  use GenServer

  @beacon :"beacon1@127.0.0.1"
  @resource :gate_server
  @requirement :game_server_manager

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    send(self(), {:join, @beacon})
    {:noreply, state}
  end

  def handle_info({:join, beacon}, state) do
    case Node.ping(beacon) do
      :pong -> register()
      _ -> :timer.send_after(1000, {:join, beacon})
    end

    {:noreply, state}
  end

  defp register() do
    IO.inspect(Node.list())
    offer = GenServer.call({BeaconServer.Worker, @beacon}, {:register, {node(), @resource, @requirement}})
    IO.inspect(offer)
  end
end
