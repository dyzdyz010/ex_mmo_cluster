defmodule DataContact.NodeManager do
  @moduledoc """
  Mnesia node manager.

  ## `state` format:

  ```
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
  ```
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
    result = Map.keys(:maps.filter(fn _, v -> v == :online end, state.service_nodes)) ++ Map.keys(:maps.filter(fn _, v -> v == :online end, state.store_nodes))
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_node, _from, state) do
    Logger.debug("Nodes: #{inspect(state, pretty: true)}")
    free_node = select_free_node(state.service_nodes)
    case free_node do
      nil ->
        {:reply, {:err, nil}, state}
      _ ->
        {:reply, {:ok, free_node}, state}
    end
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
  def handle_info({:nodedown, node}, state) do
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

  # Select a service node with lowest pressure.
  @spec select_free_node(map()) :: atom()
  defp select_free_node(service_nodes) do
    Logger.debug("current service nodes: #{inspect(service_nodes)}")
    if service_nodes == %{} do
      nil
    else
      Map.keys(Map.filter(service_nodes, fn {_, v} -> v == :online end))
      |> Enum.min()
    end
    # [n, _] = for x <- service_nodes, do: x
    # n
  end
end
