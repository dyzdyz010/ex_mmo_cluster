defmodule WorldServer.Interface do
  use GenServer
  require Logger

  @resource :world_server

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{scene_server: nil, data_service: nil, server_state: :waiting_requirements}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting world_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    {:ok, scene_node} = BeaconServer.Client.await(:scene_server)
    {:ok, data_node} = BeaconServer.Client.await(:data_service)
    Logger.info("Found scene_server=#{inspect(scene_node)}, data_service=#{inspect(data_node)}", ansi_color: :green)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | scene_server: scene_node, data_service: data_node, server_state: :ready}}
  end
end
