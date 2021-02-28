defmodule ServiceDiscovery do
  @moduledoc """
  Documentation for `ServiceDiscovery`.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, _resource}, _from, state) do
    _beacon_node_name = :"beacon1@localhost"

    {:reply, :ok, state}
  end
end
