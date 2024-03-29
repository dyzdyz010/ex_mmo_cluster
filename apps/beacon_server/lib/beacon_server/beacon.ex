defmodule BeaconServer.Beacon do
  @moduledoc """
  Beacon server for the whole cluster.

  It accepts all other nodes' connection and monitors them.

  ## `state` format:

  ```
  %{
    nodes: [
      %{
        node: :"node1@host",
        status: :online,
        resource: :gate_server
      }
    ]
  }
  %{
    nodes: %{
      "node1@host": :online,
      "node2@host": :offline
    },
    requirements: [
      %{
        module: Module.Interface,
        name: [:requirement_name],
        node: :"node@host"
      }
    ],
    resources: [
      %{
        module: Module.Interface,
        name: :resoutce_name,
        node: :"node@host"
      }
    ]
  }
  ```
  """

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
  # Register node with resource and requirement.
  def handle_call(
        {:register, credentials},
        _from,
        state
      ) do
    Logger.info("New register from #{inspect(credentials, pretty: true)}.")

    {:ok, new_state} = register(credentials, state)

    Logger.info("Register #{inspect(credentials, pretty: true)} complete.", ansi_color: :green)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(
        {:get_requirements, node},
        _from,
        state = %{nodes: _, resources: resources, requirements: requirements}
      ) do
    Logger.debug("Getting requirements for #{inspect(node)}")

    # req = find_requirements(node, requirements)
    # offer = find_resources(req, resources)
    # offer = get_requirements(node, requirements, resources)

    offer =
      case get_requirements(node, requirements, resources) do
        {:ok, result} ->
          Logger.info("Requirements retrieved: #{inspect(result, pretty: true)}",
            ansi_color: :green
          )

          {:ok, result}

        {:err, nil} ->
          {:err, nil}
      end

    {:reply, offer, state}
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

  @spec register({node(), module(), atom(), [atom()]}, map()) :: {:ok, map()}
  defp register(
         {node, module, resource, requirement},
         state = %{nodes: connected_nodes, resources: resources, requirements: requirements}
       ) do
    Logger.debug("Register: #{node} | #{resource} | #{inspect(requirement)}")

    {:ok,
     %{
       state
       | nodes: add_node(node, connected_nodes),
         resources: add_resource(node, module, resource, resources),
         requirements:
           if requirement != [] do
             add_requirement(node, module, requirement, requirements)
           else
             requirements
           end
     }}
  end

  @spec get_requirements(node(), list(map()), list(map())) :: {:ok, list(map())} | {:err, nil}
  defp get_requirements(node, requirements, resources) do
    req = find_requirements(node, requirements)
    Logger.debug("Find requirements: #{inspect(req, pretty: true)}")
    case req do
      [] ->
        {:ok, []}

      _ ->
        case find_resources(req, resources) do
          [] -> {:err, nil}
          offer -> {:ok, offer}
        end
    end
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
      true -> r.name
      false -> find_requirements(node, requirements)
    end
  end

  defp find_resources([], _) do
    []
  end

  @spec find_resources(list(map()), list(map())) :: list(map())
  defp find_resources(requirement, resources) do
    Logger.debug("Find resources with requirement: #{inspect(requirement, pretty: true)}")

    for req <- requirement, res <- resources, req == res.name do
      res
    end
  end
end
