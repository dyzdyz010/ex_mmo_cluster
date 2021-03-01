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
        state = %{resources: resources, requirements: requirements}
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
       | resources: [[node: node, module: module, name: resource] | resources],
         requirements: [[node: node, module: module, name: requirement] | requirements]
     }}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    IO.inspect(node, label: "Node connected: ")

    {:noreply, state}
  end
end
