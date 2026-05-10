defmodule SceneServer.Interface do
  @moduledoc """
  Scene service registration entrypoint.

  This process is intentionally small: it joins the service-discovery
  cluster, registers the scene node so gate/auth/demo tooling can
  locate it, and announces itself to `WorldServer.Voxel.SceneNodeRegistry`
  so World can route region transactions / damage to this node
  (Phase A4-bis-cluster step 4 segment 2b).

  ## Production startup

  Production `release` boot sequence:

  1. `BeaconServer.Client.join_cluster/0` — Erlang distribution + Horde
     membership.
  2. `BeaconServer.Client.register(:scene_server)` — gate/auth lookup
     entrypoint (atom key, single-entry; multi-`scene_node` deployments
     announce themselves to World *separately* via the RPC below).
  3. `BeaconServer.Client.await(:world_server, ...)` — wait for World
     to be reachable. Production deploys generally start World first;
     if order is racy this blocks up to `@world_await_timeout_ms`.
  4. `:rpc.call(world_node, SceneNodeRegistry, :register_scene_node, [node()])`
     — announce to World we exist as a candidate scene_node for
     region assignment (D8.B join-order round-robin).

  Step 3/4 failures (World unavailable / RPC timeout) only `Logger.warning`
  — they do *not* block scene_server startup. A scene_node is still
  useful for legacy single-region paths even without participating in
  multi-`scene_node` region routing; partial degradation beats
  refusing to boot.
  """

  use GenServer
  require Logger

  @resource :scene_server
  @world_resource :world_server

  # Architecture invariant: `scene_server` does NOT depend on
  # `world_server` in mix.exs (World knows Scene; not the other way
  # round). We therefore reference `WorldServer.Voxel.SceneNodeRegistry`
  # by atom literal so the compiler doesn't complain about an unknown
  # module — `:rpc.call/5` accepts a bare atom for the module
  # parameter and resolves it on the remote node at call time.
  @scene_node_registry_module :"Elixir.WorldServer.Voxel.SceneNodeRegistry"

  # 30s is enough for a typical release boot order with small clock
  # skew between nodes; longer than that suggests World is genuinely
  # missing and degraded mode is the right answer.
  @world_await_timeout_ms 30_000
  @rpc_timeout_ms 5_000

  @doc "Starts the scene service interface process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{server_state: :waiting_requirements}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting scene_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    announce_to_world()

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | server_state: :ready}}
  end

  @doc """
  Phase A4-bis-4 段 2b: tell the World node we exist so it can
  round-robin region assignments to us. Soft-fail — partial degradation
  over hard refusal to boot.

  Public for testability — `handle_continue/2` calls it with defaults.
  Tests can override:

  * `:world_resource` — BeaconServer key World registers under (default `:world_server`)
  * `:registry_module` — module name to invoke on the World node via
    `:rpc.call/5` (default `:"Elixir.WorldServer.Voxel.SceneNodeRegistry"`).
  * `:registry_name` — first argument to `register_scene_node/2` — the
    GenServer name on the World side. In production this is the same
    atom as `:registry_module` (WorldSup starts the registry with
    `name: WorldServer.Voxel.SceneNodeRegistry`); tests can pass a
    custom GenServer name to isolate state.
  * `:await_timeout_ms` — `BeaconServer.Client.await/2` timeout (default 30s)
  * `:rpc_timeout_ms` — RPC call timeout (default 5s)
  """
  @spec announce_to_world(keyword()) :: :ok
  def announce_to_world(opts \\ []) do
    world_resource = Keyword.get(opts, :world_resource, @world_resource)
    registry_module = Keyword.get(opts, :registry_module, @scene_node_registry_module)
    registry_name = Keyword.get(opts, :registry_name, registry_module)
    await_timeout_ms = Keyword.get(opts, :await_timeout_ms, @world_await_timeout_ms)
    rpc_timeout_ms = Keyword.get(opts, :rpc_timeout_ms, @rpc_timeout_ms)

    case BeaconServer.Client.await(world_resource, timeout: await_timeout_ms) do
      {:ok, world_node} ->
        # Note: `:rpc.call(node(), Mod, fun, args)` short-circuits to a
        # local apply when `node() == self_node`, so single-BEAM dev /
        # mix test runs work without a special same-node branch.
        announce_via_rpc(world_node, registry_module, registry_name, rpc_timeout_ms)

      :timeout ->
        Logger.warning(
          "scene_server: World unavailable within #{await_timeout_ms}ms; " <>
            "skipping SceneNodeRegistry announcement (degraded: this scene_node " <>
            "won't be picked for new region assignments until restart)"
        )

        :ok
    end
  end

  defp announce_via_rpc(world_node, registry_module, registry_name, rpc_timeout_ms) do
    case :rpc.call(
           world_node,
           registry_module,
           :register_scene_node,
           [registry_name, node()],
           rpc_timeout_ms
         ) do
      :ok ->
        Logger.info(
          "scene_server: announced #{inspect(node())} to World SceneNodeRegistry on #{inspect(world_node)}"
        )

        :ok

      {:badrpc, reason} ->
        Logger.warning(
          "scene_server: RPC announce to #{inspect(world_node)} SceneNodeRegistry failed: " <>
            "#{inspect(reason)} (degraded: this scene_node won't be picked for new " <>
            "region assignments until restart)"
        )

        :ok

      other ->
        Logger.warning(
          "scene_server: unexpected reply from World SceneNodeRegistry RPC: #{inspect(other)}"
        )

        :ok
    end
  end
end
