defmodule AgentServer.Interface do
  @moduledoc """
  Agent service registration and `agent_manager` discovery process.

  ## State ownership

  This process is the **authority** for the agent node's view of its upstream
  `agent_manager` location. It is an adapter over `BeaconServer`'s registry: it
  caches the last-known manager node and exposes lifecycle state, but does not
  own cluster membership.

  ## Dependency resolution and the degraded state (cluster-discovery-3)

  `agent_manager` is the agent node's only hard startup dependency. The setup
  path used to hard-match `BeaconServer.Client.await(:agent_manager)`; a missing
  manager made the match fail, crashed the GenServer, and let the supervisor
  restart it roughly every 30s forever — an unbounded crash-loop with no
  backoff and no signal.

  A missing dependency is now a *first-class, handled* condition:

  - resolution runs as bounded, non-blocking lookups driven by self-scheduled
    messages with **exponential backoff**;
  - exhausting the attempt budget moves the process into a controlled
    `:degraded` state (alive, emits a structured observe log, answers queries)
    instead of crashing;
  - `retry_dependencies/1` re-triggers resolution, so recovery is an explicit
    action rather than a supervisor restart.
  """

  use GenServer
  require Logger

  @resource :agent_server
  @required_dependency :agent_manager

  @default_max_attempts 6
  @default_base_backoff_ms 250
  @default_max_backoff_ms 5_000

  @doc "Starts the agent service interface process."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Returns the current lifecycle state: `:waiting_requirements`, `:ready`, or
  `:degraded`. Exposed for CLI observability and tests.
  """
  @spec server_state(GenServer.server()) :: :waiting_requirements | :ready | :degraded
  def server_state(server \\ __MODULE__) do
    GenServer.call(server, :server_state)
  end

  @doc """
  Re-triggers dependency resolution. Returns the resulting lifecycle state.
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
       agent_manager: nil,
       server_state: :waiting_requirements,
       dependency_attempts: 0,
       config: config
     }, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting agent_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    {:noreply, resolve_dependency(%{state | dependency_attempts: 0})}
  end

  @impl true
  def handle_info(:resolve_dependency, state) do
    {:noreply, resolve_dependency(state)}
  end

  # -- Dependency resolution (bounded retry + exponential backoff) --

  defp resolve_dependency(state) do
    case BeaconServer.Client.lookup(@required_dependency) do
      {:ok, manager_node} ->
        Logger.info("Found agent_manager at #{inspect(manager_node)}", ansi_color: :green)
        Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
        %{state | agent_manager: manager_node, server_state: :ready}

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
        "agent_manager not yet discoverable (attempt #{next_attempts}/#{config.max_attempts}); " <>
          "retrying in #{delay}ms",
        ansi_color: :yellow
      )

      Process.send_after(self(), :resolve_dependency, delay)
      %{state | dependency_attempts: next_attempts, server_state: :waiting_requirements}
    end
  end

  defp backoff_delay(attempt, config) do
    raw = config.base_backoff_ms * Integer.pow(2, attempt - 1)
    min(raw, config.max_backoff_ms)
  end

  defp enter_degraded(%{config: config} = state) do
    Logger.error(
      "event=agent_interface_degraded resource=#{@resource} " <>
        "dependency=#{@required_dependency} attempts=#{config.max_attempts} node=#{node()}",
      ansi_color: :red
    )

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

  @impl true
  def handle_call(:agent_manager, _from, %{agent_manager: manager} = state) do
    {:reply, manager, state}
  end
end
