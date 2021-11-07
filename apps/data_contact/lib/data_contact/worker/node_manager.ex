defmodule DataContact.NodeManager do
  @moduledoc """
  Mnesia node manager.

  ## state format:

  %{
    service_nodes: %{
      node1@host: :online,
      node2@host: :offline
    },
    store_nodes: %{
      node3@host: :online,
      node4@host: :offline
    }
  }
  """

  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    {:ok,
     %{
       service_nodes: %{},
       store_nodes: %{}
     }}
  end

  @impl true
  def handle_call({:register, node, role}, _from, state) do
    new_state = add_node(state, node, role)
    Node.monitor(node, true)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:db_list, _from, state) do
    {:reply, state.store_nodes ++ state.service_nodes, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.debug("Node connected: #{node}")
    new_state = case Map.get(state.service_nodes, node) do
      nil ->
        %{state | store_nodes: %{state.store_nodes | node => :online}}
      _ ->
        %{state | service_nodes: %{state.service_nodes | node => :online}}
    end


    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodedown, node}, state = %{nodes: node_list}) do
    Logger.critical("Node disconnected: #{node}")

    new_state = case Map.get(state.service_nodes, node) do
      nil ->
        %{state | store_nodes: %{state.store_nodes | node => :offline}}
      _ ->
        %{state | service_nodes: %{state.service_nodes | node => :offline}}
    end

    {:noreply, new_state}
  end

  defp add_node(state = %{service_nodes: service_nodes}, node, :service) do
    %{state | service_nodes: Map.put(service_nodes, node, :online)}
  end

  defp add_node(state = %{store_nodes: store_nodes}, node, :store) do
    %{state | store_nodes: Map.put(store_nodes, node, :online)}
  end
end
