defmodule WorldServer.Voxel.SceneNodeMonitor do
  @moduledoc """
  Watches the Erlang cluster for scene_node disconnects and forwards
  them to `SceneNodeRegistry.unregister_scene_node/2` (Phase
  A4-bis-cluster step 4 segment 2a).

  ## Why a separate process

  `SceneNodeRegistry` is intentionally pure registry/round-robin state plus a
  Postgres-backed cache. Cluster lifecycle (`:net_kernel.monitor_nodes`) is a
  side concern that doesn't belong in the registry's GenServer loop, especially
  because it has to survive `SceneNodeRegistry` restarts under `:one_for_one`
  supervision.

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

  ## Establish-then-reconcile (fixes the announce/monitor timing race)

  There is an unavoidable gap between the registry holding a scene_node (either
  freshly announced via RPC, or hydrated from Postgres on restart) and this
  monitor establishing `:net_kernel.monitor_nodes`. A scene_node that
  disconnects inside that gap never produces a `:nodedown` we can see, leaking a
  stale `join_order` entry. We close the race in two ordered steps:

  1. **Establish monitoring first** (`monitor_nodes(true)` in `init/1`). Erlang
     queues any `:nodedown` from this point into our mailbox, so nothing that
     happens *after* this call is lost — it is merely processed once we enter
     the receive loop.
  2. **Reconcile against the live node set after** (`handle_continue/2`). We ask
     the registry to drop any registered scene_node that is *not* in the current
     `Node.list/0`. This sweeps nodes that died *before* monitoring was
     established — the exact entries a `:nodedown` could not retroactively
     cover, including stale rows hydrated from Postgres after a World restart.

  Doing (1) strictly before reading the live set in (2) means any node that
  goes down *between* the two steps is caught by the queued `:nodedown` rather
  than slipping through reconcile — no missed monitor, and `unregister` /
  `reconcile` are both idempotent so there is no double-unregister.
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

    # Step 1: establish monitoring BEFORE we snapshot the live node set in
    # handle_continue, so any `:nodedown` racing the reconcile is queued in our
    # mailbox instead of being lost.
    #
    # 单机判定不能依赖 `:net_kernel.monitor_nodes/1` 的返回值:OTP 28 起,即使 BEAM
    # 未分布式(`:nonode@nohost`),`monitor_nodes(true)` 也返回 `:ok`(旧版本才返回
    # `:ignored`)。若据此判 distributed?=true,则在单机(`Node.list/0` 恒为 `[]`)上
    # reconcile 会把所有已水合的 scene_node 误判成 stale 全部 sweep 掉——正是
    # "重启从权威 hydrate" 想避免的脑裂式覆盖。因此用 `Node.alive?/0` 作为权威的
    # 分布式判定,monitor_nodes 仅用于在真分布式下登记 :nodedown 投递。
    monitor_result = :net_kernel.monitor_nodes(true)
    distributed? = Node.alive?()

    case {distributed?, monitor_result} do
      {false, _} ->
        Logger.info(
          "SceneNodeMonitor: BEAM is not distributed; nodedown sweeping disabled until restart"
        )

      {true, :ok} ->
        :ok

      {true, other} ->
        Logger.warning(
          "SceneNodeMonitor: :net_kernel.monitor_nodes/1 returned unexpected #{inspect(other)} on a distributed node"
        )
    end

    {:ok, %{registry: registry, distributed?: distributed?}, {:continue, :reconcile_live_nodes}}
  end

  @impl true
  def handle_continue(:reconcile_live_nodes, %{distributed?: false} = state) do
    # Single-BEAM: no remote nodes can have disconnected, so there is nothing to
    # reconcile. Leaving hydrated entries in place is correct for same-node
    # dev/test where the scene_node *is* this node.
    {:noreply, state}
  end

  def handle_continue(:reconcile_live_nodes, %{registry: registry} = state) do
    # Step 2: drop any registered scene_node not currently connected. This is
    # the retroactive sweep for nodes that died before monitoring was
    # established (including stale rows hydrated from Postgres after a restart).
    live_nodes = Node.list()

    case SceneNodeRegistry.reconcile_live_nodes(registry, live_nodes) do
      {:ok, []} ->
        :ok

      {:ok, swept} ->
        Logger.info(
          "SceneNodeMonitor: reconciled registry against live nodes, swept stale: #{inspect(swept)}"
        )
    end

    {:noreply, state}
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
