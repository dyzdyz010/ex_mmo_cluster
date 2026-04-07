defmodule GateServer.Interface do
  use GenServer
  require Logger

  @resource :gate_server

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{scene_server: nil, auth_server: nil, server_state: :waiting_requirements},
     {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting gate_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    {:ok, scene_node} = BeaconServer.Client.await(:scene_server)
    Logger.info("Found scene_server at #{inspect(scene_node)}", ansi_color: :green)

    # auth_server is optional at startup — look up on demand
    auth_node =
      case BeaconServer.Client.lookup(:auth_server) do
        {:ok, node} -> node
        :error -> nil
      end

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | scene_server: scene_node, auth_server: auth_node, server_state: :ready}}
  end

  # ── Service lookup for TcpConnection ──

  @impl true
  def handle_call(:scene_server, _from, %{scene_server: scene} = state) do
    {:reply, scene, state}
  end

  @impl true
  def handle_call(:auth_server, _from, %{auth_server: nil} = state) do
    # Lazy lookup if not resolved at startup
    case BeaconServer.Client.lookup(:auth_server) do
      {:ok, node} ->
        {:reply, node, %{state | auth_server: node}}

      :error ->
        {:reply, nil, state}
    end
  end

  @impl true
  def handle_call(:auth_server, _from, %{auth_server: auth} = state) do
    {:reply, auth, state}
  end
end
