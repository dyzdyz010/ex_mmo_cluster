defmodule BeaconServer.Worker do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
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
        {:register, {node, resource, requirement}},
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
       | resources: [[node: node, name: resource] | resources],
         requirements: [[node: node, name: requirement] | requirements]
     }}
  end
end
