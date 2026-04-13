defmodule SceneServer.Npc.Actor do
  use GenServer, restart: :temporary

  alias SceneServer.Npc.{Brain, Facts, Profile, State}

  def start_link({profile, opts}, genserver_opts \\ []) do
    GenServer.start_link(__MODULE__, {profile, opts}, genserver_opts)
  end

  @impl true
  def init({%Profile{} = profile, opts}) do
    registry = Keyword.get(opts, :player_registry, SceneServer.PlayerManager)

    state = %{
      profile: profile,
      npc_state: State.idle(profile),
      player_registry: registry,
      brain_timer: nil
    }

    {:ok, state, {:continue, :start_brain}}
  end

  @impl true
  def handle_continue(:start_brain, %{profile: profile} = state) do
    {:noreply, %{state | brain_timer: schedule_brain_tick(profile.brain_tick_ms)}}
  end

  @impl true
  def handle_call(:await_ready, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call(:get_state_summary, _from, %{npc_state: npc_state} = state) do
    {:reply, {:ok, npc_state}, state}
  end

  @impl true
  def handle_call({:set_alive, alive}, _from, %{npc_state: npc_state} = state) do
    {:reply, :ok, %{state | npc_state: %{npc_state | alive: alive}}}
  end

  @impl true
  def handle_info(
        :brain_tick,
        %{profile: profile, player_registry: registry, npc_state: npc_state} = state
      ) do
    facts = gather_facts(npc_state, profile, registry)
    {intent, target_cid} = Brain.decide(facts, profile)

    updated_state = %{
      npc_state
      | intent: intent,
        current_target_cid: target_cid,
        last_decision_at_ms: System.monotonic_time(:millisecond)
    }

    {:noreply,
     %{state | npc_state: updated_state, brain_timer: schedule_brain_tick(profile.brain_tick_ms)}}
  end

  @impl true
  def terminate(_reason, %{brain_timer: brain_timer}) do
    if brain_timer != nil, do: Process.cancel_timer(brain_timer)
    :ok
  end

  defp gather_facts(%State{} = npc_state, %Profile{} = profile, registry) do
    {target_cid, target_distance} = nearest_player(npc_state.position, registry)

    %Facts{
      alive: npc_state.alive,
      position: npc_state.position,
      spawn_position: profile.spawn_position,
      target_cid: target_cid,
      target_distance: target_distance,
      distance_from_spawn: distance(npc_state.position, profile.spawn_position)
    }
  end

  defp nearest_player(origin, registry) do
    with {:ok, players} <- fetch_players(registry) do
      players
      |> Enum.map(fn {_cid, pid} ->
        case safe_player_summary(pid) do
          {:ok, %{cid: cid, position: position, alive: true}} ->
            {cid, distance(origin, position)}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn {_cid, distance} -> distance end)
      |> List.first()
      |> case do
        {cid, dist} -> {cid, dist}
        nil -> {nil, nil}
      end
    else
      _ -> {nil, nil}
    end
  end

  defp fetch_players(registry) do
    try do
      case GenServer.call(registry, :get_all_players) do
        {:ok, players} -> {:ok, players}
        other -> {:error, other}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp safe_player_summary(pid) do
    try do
      case GenServer.call(pid, :get_state_summary) do
        {:ok, summary} -> {:ok, summary}
        other -> {:error, other}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp distance({ax, ay, az}, {bx, by, bz}) do
    dx = ax - bx
    dy = ay - by
    dz = az - bz
    :math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  defp schedule_brain_tick(interval_ms) do
    Process.send_after(self(), :brain_tick, interval_ms)
  end
end
