defmodule DataContact.Interface do
  @behaviour GenServer

  require Logger

  @beacon :"beacon1@127.0.0.1"
  @resource :data_contact
  @requirement []

  # 重试间隔：s
  @retry_rate 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    {:ok, %{service_nodes: [], store_nodes: [], server_state: :waiting_node}, 0}
  end

  def handle_info(:timeout, state) do
    send(self(), {:join, @beacon})
    {:noreply, state}
  end

  def handle_info({:join, beacon}, state) do
    true = Node.connect(beacon)
    send(self(), :register)

    {:noreply, state}
  end

  def handle_info(:register, state) do
    :ok = GenServer.call(
      {BeaconServer.Worker, @beacon},
      {:register, {node(), __MODULE__, @resource, @requirement}}
    )

    {:noreply, state}
  end

  def handle_call(:db_list, _from, state) do
    {:reply, state.store_nodes ++ state.service_nodes, state}
  end

  def handle_call({:add_node, node, role}, _from, state) do

    {:reply, :ok, add_node(state, node, role)}
  end

  defp add_node(state, node, :service) do
    %{state | service_nodes: [node | state.service_nodes]}
  end

  defp add_node(state, node, :store) do
    %{state | store_nodes: [node | state.store_nodes]}
  end
end
