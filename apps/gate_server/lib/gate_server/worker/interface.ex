defmodule GateServer.Interface do
  @moduledoc """
  Gate service registration and downstream service lookup process.

  Gate connection workers query this process to find the current
  `scene_server`, `world_server`, `auth_server`, and `chat_server` nodes. The process caches
  successful lookups but stays small so supervision and service-discovery
  concerns remain separate from connection logic.

  ## State ownership

  This process is the **authority** for the gate's view of downstream service
  locations. Connection workers only *read* from it via `handle_call/3`; they
  never mutate discovery state. Cluster membership and the underlying registry
  are owned by `BeaconServer`; this module is only an adapter that caches the
  last-known node for each downstream resource.

  ## Dependency resolution and the degraded state (cluster-discovery-3)

  The gate's only *hard* startup dependency is `scene_server`. Historically the
  setup path hard-matched `BeaconServer.Client.await(:scene_server)`; when the
  dependency was missing the match failed, the GenServer crashed, and the
  supervisor restarted it roughly every 30s forever — a crash-loop masquerading
  as a retry, with no backoff, no ceiling, and no signal.

  Instead, a missing dependency is now a *first-class, handled* condition:

  - resolution runs as a bounded sequence of non-blocking lookups driven by
    self-scheduled messages, with **exponential backoff** between attempts;
  - exhausting the attempt budget moves the process into a controlled
    `:degraded` state (it stays alive, emits an observe event, and answers
    queries) rather than crashing;
  - callers can re-trigger resolution explicitly via `retry_dependencies/1`,
    so recovery is an action, not a restart.
  """

  use GenServer
  require Logger

  @resource :gate_server

  # The single hard dependency the gate cannot serve traffic without.
  @required_dependency :scene_server

  # Bounded exponential backoff for dependency resolution. After
  # @max_attempts unsuccessful attempts the process enters :degraded instead
  # of crashing. Defaults are overridable via opts (mainly for tests).
  @default_max_attempts 6
  @default_base_backoff_ms 250
  @default_max_backoff_ms 5_000

  @doc "Starts the gate service interface process."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Returns the current lifecycle state of the interface.

  One of `:waiting_requirements`, `:ready`, or `:degraded`. Exposed so CLI
  observability and tests can assert the process survives a missing dependency
  in a controlled `:degraded` state rather than crash-looping.
  """
  @spec server_state(GenServer.server()) :: :waiting_requirements | :ready | :degraded
  def server_state(server \\ __MODULE__) do
    GenServer.call(server, :server_state)
  end

  @doc """
  Re-triggers dependency resolution from a `:degraded` (or any) state.

  This makes recovery an explicit, observable action rather than relying on a
  supervisor restart. No-op effect on the wire format; returns the resulting
  lifecycle state.
  """
  @spec retry_dependencies(GenServer.server()) ::
          :waiting_requirements | :ready | :degraded
  def retry_dependencies(server \\ __MODULE__) do
    GenServer.call(server, :retry_dependencies)
  end

  @impl true
  def init(opts) do
    config = %{
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
    }

    {:ok,
     %{
       scene_server: nil,
       world_server: nil,
       auth_server: nil,
       chat_server: nil,
       server_state: :waiting_requirements,
       dependency_attempts: 0,
       config: config
     }, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting gate_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    # Resolve the hard dependency without blocking the process or crashing on
    # absence: kick off the first bounded resolution attempt immediately.
    {:noreply, resolve_dependency(%{state | dependency_attempts: 0})}
  end

  @impl true
  def handle_info(:resolve_dependency, state) do
    {:noreply, resolve_dependency(state)}
  end

  # -- Dependency resolution (bounded retry + exponential backoff) --

  defp resolve_dependency(state) do
    case BeaconServer.Client.lookup(@required_dependency) do
      {:ok, scene_node} ->
        Logger.info("Found scene_server at #{inspect(scene_node)}", ansi_color: :green)
        promote_to_ready(%{state | scene_server: scene_node})

      :error ->
        schedule_or_degrade(state)
    end
  end

  defp schedule_or_degrade(%{dependency_attempts: attempts, config: config} = state) do
    next_attempts = attempts + 1

    if next_attempts >= config.max_attempts do
      enter_degraded(%{state | dependency_attempts: next_attempts})
    else
      delay = backoff_delay(next_attempts, config)

      Logger.warning(
        "scene_server not yet discoverable (attempt #{next_attempts}/#{config.max_attempts}); " <>
          "retrying in #{delay}ms",
        ansi_color: :yellow
      )

      Process.send_after(self(), :resolve_dependency, delay)
      %{state | dependency_attempts: next_attempts, server_state: :waiting_requirements}
    end
  end

  # Exponential backoff with a ceiling: base * 2^(attempt-1), capped.
  defp backoff_delay(attempt, config) do
    raw = config.base_backoff_ms * Integer.pow(2, attempt - 1)
    min(raw, config.max_backoff_ms)
  end

  defp promote_to_ready(state) do
    # world_server, auth_server and chat_server are optional at startup --
    # look them up opportunistically, falling back to lazy on-demand resolution.
    next_state =
      state
      |> Map.put(:world_server, optional_lookup(:world_server))
      |> Map.put(:auth_server, optional_lookup(:auth_server))
      |> Map.put(:chat_server, optional_lookup(:chat_server))
      |> Map.put(:server_state, :ready)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    next_state
  end

  defp optional_lookup(resource) do
    case BeaconServer.Client.lookup(resource) do
      {:ok, node} -> node
      :error -> nil
    end
  end

  # Controlled degraded state: the process stays alive and answers queries
  # instead of crash-looping. Recovery is driven by `retry_dependencies/1`.
  defp enter_degraded(%{config: config} = state) do
    Logger.error(
      "gate_server interface entering :degraded state -- #{@required_dependency} " <>
        "not discoverable after #{config.max_attempts} attempts",
      ansi_color: :red
    )

    GateServer.CliObserve.emit("gate_interface_degraded", fn ->
      %{
        resource: @resource,
        dependency: @required_dependency,
        attempts: config.max_attempts,
        node: node()
      }
    end)

    %{state | server_state: :degraded}
  end

  # -- Lifecycle introspection --

  @impl true
  def handle_call(:server_state, _from, %{server_state: server_state} = state) do
    {:reply, server_state, state}
  end

  @impl true
  def handle_call(:retry_dependencies, _from, state) do
    next_state = resolve_dependency(%{state | dependency_attempts: 0})
    {:reply, next_state.server_state, next_state}
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
