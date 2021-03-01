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
    {:ok, %{game_server_manager: []}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    send(self(), {:join, @beacon})
    {:noreply, state}
  end

  def handle_info({:join, beacon}, state) do
    game_server_manager_list = case Node.ping(beacon) do
      :pong ->
        register()
      _ ->
        :timer.send_after(1000, {:join, beacon})
        []
    end

    {:noreply, %{state | game_server_manager: game_server_manager_list}}
  end

  defp register() do
    IO.inspect(Node.list())

    offer =
      GenServer.call(
        {BeaconServer.Worker, @beacon},
        {:register, {node(), __MODULE__, @resource, @requirement}}
      )

    case offer do
      {:ok, game_server_manager_list} -> game_server_manager_list
      nil -> []
    end
  end
end
