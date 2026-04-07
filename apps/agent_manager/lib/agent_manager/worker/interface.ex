defmodule AgentManager.Interface do
  use GenServer
  require Logger

  @resource :agent_manager

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{server_state: :waiting_requirements}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting agent_manager node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | server_state: :ready}}
  end
end
