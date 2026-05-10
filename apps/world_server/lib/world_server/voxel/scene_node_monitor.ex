defmodule WorldServer.Voxel.SceneNodeMonitor do
  @moduledoc """
  Watches the Erlang cluster for scene_node disconnects and forwards
  them to `SceneNodeRegistry.unregister_scene_node/2` (Phase
  A4-bis-cluster step 4 segment 2a).

  ## Why a separate process

  `SceneNodeRegistry` is intentionally pure state — register / lookup
  / round-robin only. Cluster lifecycle (`:net_kernel.monitor_nodes`)
  is a side concern that doesn't belong in the registry's GenServer
  loop, especially because it has to survive `SceneNodeRegistry`
  restarts under `:one_for_one` supervision.

  ## Why no `:nodeup` handling

  An incoming `:nodeup` only tells us "some Erlang node joined the
  cluster". That node could be an `auth_server` BEAM, a `data_service`
  BEAM, an `iex` debug shell, or anything else — *not* necessarily a
  `scene_server` BEAM. We don't want false positives polluting the
  registry's `join_order`.

  Scene_nodes therefore *announce themselves* explicitly via RPC from
  `SceneServer.Interface` (segment 2b). `:nodedown` is the symmetric
  signal: when a scene_node we previously registered disconnects, the
  Erlang VM is the authoritative source — we don't need a second-hand
  RPC to tell us. `SceneNodeRegistry.unregister_scene_node/2` is
  idempotent for unknown nodes, so unregistering a non-scene node
  that happened to disconnect is a no-op.
  """

  use GenServer
  require Logger

  alias WorldServer.Voxel.SceneNodeRegistry

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, SceneNodeRegistry)

    # `:net_kernel.monitor_nodes/1` returns `:ignored` (not an error)
    # when the BEAM is not distributed (`:nonode@nohost`). In that
    # case we just sit quietly — we'll never receive `:nodedown`,
    # which is fine for single-BEAM dev / test runs. When the BEAM
    # later goes distributed (e.g. tests calling `:net_kernel.start`)
    # the registration is *not* retroactively applied; for now we
    # accept that single-BEAM stays single-BEAM for the process's
    # whole lifetime.
    case :net_kernel.monitor_nodes(true) do
      :ok ->
        :ok

      :ignored ->
        Logger.info(
          "SceneNodeMonitor: BEAM is not distributed; nodedown sweeping disabled until restart"
        )

      other ->
        Logger.warning(
          "SceneNodeMonitor: :net_kernel.monitor_nodes/1 returned unexpected #{inspect(other)}"
        )
    end

    {:ok, %{registry: registry}}
  end

  @impl true
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  def handle_info({:nodedown, node}, state) do
    Logger.info("SceneNodeMonitor: cluster node down, sweeping registry: #{inspect(node)}")
    SceneNodeRegistry.unregister_scene_node(state.registry, node)
    {:noreply, state}
  end

  # Some Erlang versions deliver `{:nodedown, node, info}` (3-tuple)
  # depending on `monitor_nodes` options.
  def handle_info({:nodedown, node, _info}, state) do
    Logger.info("SceneNodeMonitor: cluster node down, sweeping registry: #{inspect(node)}")
    SceneNodeRegistry.unregister_scene_node(state.registry, node)
    {:noreply, state}
  end

  def handle_info({:nodeup, _node, _info}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}
end
