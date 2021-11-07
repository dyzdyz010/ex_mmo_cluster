defmodule DataContact.Interface do
  use GenServer

  require Logger

  @beacon :"beacon1@127.0.0.1"
  @resource :data_contact
  @requirement []

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{server_state: :waiting_node}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    send(self(), {:join, @beacon})
    {:noreply, state}
  end

  @impl true
  def handle_info({:join, beacon}, state) do
    true = Node.connect(beacon)
    send(self(), :register)

    {:noreply, state}
  end

  @impl true
  def handle_info(:register, state) do
    :ok = GenServer.call(
      {BeaconServer.Worker, @beacon},
      {:register, {node(), __MODULE__, @resource, @requirement}}
    )

    {:noreply, state}
  end
end
