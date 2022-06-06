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
  Register node with resource and requirement.
  """
  def handle_call(
        {:register, credentials},
        _from,
        state
      ) do
    new_state = register(credentials, state)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(
        {:get_requirements, node},
        _from,
        state = %{nodes: _, resources: resources, requirements: requirements}
      ) do
    Logger.debug("#{inspect(state, pretty: true)}")

    req = find_requirements(node, requirements)
    offer = find_resources(req, resources)

    {:reply,
     case length(offer) do
       0 -> nil
       _ -> {:ok, offer}
     end, state}
  end

  # ========== Node monitoring ==========

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.debug("Node connected: #{node}")

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state = %{nodes: node_list}) do
    Logger.critical("Node disconnected: #{node}")

    {:noreply, %{state | nodes: %{node_list | node => :offline}}}
  end

  # -------------------------------------

  @spec register({node(), module(), atom(), [atom()]}, %{}) :: {:ok, %{}}
  defp register(
         {node, module, resource, requirement},
         state = %{nodes: nodes, resources: resources, requirements: requirements}
       ) do
    Logger.debug("Register: #{node} | #{resource} | #{inspect(requirement)}")

    {:ok,
     %{
       state
       | nodes: add_node(node, nodes),
         resources: add_resource(node, module, resource, resources),
         requirements:
           if requirement != [] do
             add_requirement(node, module, requirement, requirements)
           else
             requirements
           end
     }}
  end

  defp add_node(node, node_list) do
    Logger.debug("Add node: #{node}")
    node_list |> Map.put(node, :online)
  end

  defp add_resource(node, module, resource, resource_list) do
    case resource_list
         |> Enum.map(& &1[:node])
         |> Enum.member?(node) do
      true -> resource_list
      false -> [%{node: node, module: module, name: resource} | resource_list]
    end
  end

  defp add_requirement(node, module, requirement, requirement_list) do
    case requirement_list
         |> Enum.map(& &1[:node])
         |> Enum.member?(node) do
      true -> requirement_list
      false -> [%{node: node, module: module, name: requirement} | requirement_list]
    end
  end

  defp find_requirements(_, []) do
    []
  end

  defp find_requirements(node, [r | requirements]) do
    case node == r.node do
      true -> r
      false -> find_requirements(node, requirements)
    end
  end

  defp find_resources([], _) do
    []
  end

  defp find_resources(requirement, resources) do
    IO.inspect(requirement)

    for req <- requirement.name, res <- resources, req == res.name do
      res
    end
  end
end
