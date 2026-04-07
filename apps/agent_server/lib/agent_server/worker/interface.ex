defmodule AgentServer.Interface do
  use GenServer
  require Logger

  @resource :agent_server

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{agent_manager: nil, server_state: :waiting_requirements}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting agent_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    {:ok, manager_node} = BeaconServer.Client.await(:agent_manager)
    Logger.info("Found agent_manager at #{inspect(manager_node)}", ansi_color: :green)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | agent_manager: manager_node, server_state: :ready}}
  end
end
