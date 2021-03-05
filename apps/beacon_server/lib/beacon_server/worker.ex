defmodule BeaconServer.Worker do
  use GenServer

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
    IO.inspect("Register: #{node} | #{resource} | #{requirement}")
    offer =
      for res = [name: res_name] <- resources, res_name == requirement do
        res
      end

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
    IO.inspect(node, label: "Node connected: ")

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    IO.inspect(node, label: "Node disconnected: ")

    {:noreply, state}
  end

  # -------------------------------------

  defp add_node(node, node_list) do
    %{node_list | node => :online}
  end

  defp add_resource(node, module, resource, resource_list) do
    [[node: node, module: module, name: resource] | resource_list]
  end

  defp add_requirement(node, module, requirement, requirement_list) do
    [[node: node, module: module, name: requirement] | requirement_list]
  end
end
