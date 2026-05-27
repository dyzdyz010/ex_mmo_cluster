defmodule GateServer.Interface do
  @moduledoc """
  Gate service registration and downstream service lookup process.

  Gate connection workers query this process to find the current
  `scene_server`, `world_server`, `auth_server`, and `chat_server` nodes. The process caches
  successful lookups but stays small so supervision and service-discovery
  concerns remain separate from connection logic.
  """

  use GenServer
  require Logger

  @resource :gate_server

  @doc "Starts the gate service interface process."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       scene_server: nil,
       world_server: nil,
       auth_server: nil,
       chat_server: nil,
       server_state: :waiting_requirements
     }, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting gate_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    {:ok, scene_node} = BeaconServer.Client.await(:scene_server)
    Logger.info("Found scene_server at #{inspect(scene_node)}", ansi_color: :green)

    # world_server and auth_server are optional at startup -- look up on demand.
    world_node =
      case BeaconServer.Client.lookup(:world_server) do
        {:ok, node} -> node
        :error -> nil
      end

    auth_node =
      case BeaconServer.Client.lookup(:auth_server) do
        {:ok, node} -> node
        :error -> nil
      end

    chat_node =
      case BeaconServer.Client.lookup(:chat_server) do
        {:ok, node} -> node
        :error -> nil
      end

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)

    {:noreply,
     %{
       state
       | scene_server: scene_node,
         world_server: world_node,
         auth_server: auth_node,
         chat_server: chat_node,
         server_state: :ready
     }}
  end

  # -- Service lookup for connection workers --

  @impl true
  def handle_call(:scene_server, _from, %{scene_server: scene} = state) do
    {:reply, scene, state}
  end

  @impl true
  def handle_call(:world_server, _from, %{world_server: nil} = state) do
    case BeaconServer.Client.lookup(:world_server) do
      {:ok, node} ->
        {:reply, node, %{state | world_server: node}}

      :error ->
        {:reply, nil, state}
    end
  end

  @impl true
  def handle_call(:world_server, _from, %{world_server: world} = state) do
    {:reply, world, state}
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

  @impl true
  def handle_call(:chat_server, _from, %{chat_server: nil} = state) do
    case BeaconServer.Client.lookup(:chat_server) do
      {:ok, node} ->
        {:reply, node, %{state | chat_server: node}}

      :error ->
        {:reply, nil, state}
    end
  end

  @impl true
  def handle_call(:chat_server, _from, %{chat_server: chat} = state) do
    {:reply, chat, state}
  end
end
