defmodule BeaconServer.Worker do
  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    :net_kernel.monitor_nodes(true)

    {:ok,
     %{
       nodes: %{},
       resources: [],
       requirements: []
     }}
  end

  @impl true
  @doc """
  Register node with resource.
  """
  def handle_call(
        {:register, {node, module, resource, requirement}},
        _from,
        state = %{nodes: nodes, resources: resources, requirements: requirements}
      ) do
    Logger.debug("Register: #{node} | #{resource} | #{requirement}")

    offer =
      for res = %{name: res_name} <- resources, res_name == requirement do
        res
      end
    Logger.debug(offer)

    {:reply,
     case length(offer) do
       0 -> nil
       _ -> {:ok, offer}
     end,
     %{
       state
       | nodes: add_node(node, nodes),
         resources: add_resource(node, module, resource, resources),
         requirements: add_requirement(node, module, requirement, requirements)
     }}
  end

  # ========== Node monitoring ==========

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.debug("Node connected: #{node}")

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state = %{nodes: node_list}) do
    Logger.debug("Node disconnected: #{node}")

    {:noreply, %{state | nodes: %{node_list | node => :offline}}}
  end

  # -------------------------------------

  defp add_node(node, node_list) do
    Logger.debug("Add node: #{node}")
    node_list |> Map.put(node,  :online)
  end

  defp add_resource(node, module, resource, resource_list) do
    case resource_list
    |> Enum.map(&(&1[:node]))
    |> Enum.member?(node) do
      true -> resource_list
      false -> [%{node: node, module: module, name: resource} | resource_list]
    end
  end

  defp add_requirement(node, module, requirement, requirement_list) do
    case requirement_list
    |> Enum.map(&(&1[:node]))
    |> Enum.member?(node) do
      true -> requirement_list
      false -> [%{node: node, module: module, name: requirement} | requirement_list]
    end
  end
end
