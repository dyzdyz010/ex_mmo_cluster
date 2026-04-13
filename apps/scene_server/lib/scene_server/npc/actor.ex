defmodule SceneServer.Npc.Actor do
  use GenServer, restart: :temporary

  require Logger

  alias SceneServer.AoiManager
  alias SceneServer.Combat.Profile, as: CombatProfile
  alias SceneServer.Combat.Skill
  alias SceneServer.Combat.State, as: CombatState
  alias SceneServer.Combat.Targeting
  alias SceneServer.Npc.{Brain, Facts, Profile, State}

  def start_link({profile, opts}, genserver_opts \\ []) do
    GenServer.start_link(__MODULE__, {profile, opts}, genserver_opts)
  end

  @impl true
  def init({%Profile{} = profile, opts}) do
    state = %{
      profile: profile,
      npc_state: State.idle(profile),
      combat_profile: CombatProfile.default(),
      combat_state: CombatState.new(CombatProfile.default()),
      skill_casts: %{},
      aoi_ref: nil,
      brain_timer: nil,
      respawn_timer: nil
    }

    {:ok, state, {:continue, {:spawn_aoi, opts}}}
  end

  @impl true
  def handle_continue(
        {:spawn_aoi, _opts},
        %{profile: profile, combat_state: combat_state} = state
      ) do
    {:ok, aoi_ref} =
      AoiManager.add_aoi_item(
        profile.npc_id,
        System.system_time(:millisecond),
        profile.spawn_position,
        self(),
        self()
      )

    GenServer.cast(
      aoi_ref,
      {:player_state, profile.npc_id, combat_state.hp, combat_state.max_hp, combat_state.alive}
    )

    {:noreply,
     %{state | aoi_ref: aoi_ref, brain_timer: schedule_brain_tick(profile.brain_tick_ms)}}
  end

  @impl true
  def handle_call(:await_ready, _from, %{aoi_ref: aoi_ref} = state) when not is_nil(aoi_ref),
    do: {:reply, :ok, state}

  def handle_call(:await_ready, _from, state), do: {:reply, {:error, :not_ready}, state}

  @impl true
  def handle_call(
        :get_state_summary,
        _from,
        %{npc_state: npc_state, combat_state: combat_state} = state
      ) do
    {:reply,
     {:ok,
      %{
        kind: :npc,
        npc_id: npc_state.npc_id,
        cid: npc_state.npc_id,
        position: npc_state.position,
        hp: combat_state.hp,
        max_hp: combat_state.max_hp,
        alive: combat_state.alive,
        deaths: combat_state.deaths,
        intent: npc_state.intent
      }}, state}
  end

  @impl true
  def handle_call(
        {:apply_skill_hit, source_cid, %Skill{} = skill, impact_location},
        _from,
        %{
          npc_state: npc_state,
          combat_state: combat_state,
          aoi_ref: aoi_ref,
          respawn_timer: respawn_timer
        } = state
      ) do
    with :ok <- ensure_alive(combat_state),
         true <- source_cid != npc_state.npc_id,
         true <- within_skill_radius?(impact_location, npc_state.position, skill.radius) do
      case CombatState.apply_damage(combat_state, skill.damage) do
        {:ignored, next_combat_state} ->
          {:reply, {:ok, next_combat_state.hp}, %{state | combat_state: next_combat_state}}

        {result, next_combat_state, dealt_damage} ->
          GenServer.cast(
            aoi_ref,
            {:combat_resolved, source_cid, npc_state.npc_id, skill.id, dealt_damage,
             next_combat_state.hp, npc_state.position}
          )

          GenServer.cast(
            aoi_ref,
            {:health_update, npc_state.npc_id, next_combat_state.hp, next_combat_state.max_hp,
             next_combat_state.alive}
          )

          next_state =
            case result do
              :killed ->
                if respawn_timer != nil, do: Process.cancel_timer(respawn_timer)

                %{
                  state
                  | respawn_timer:
                      Process.send_after(self(), :respawn, state.combat_profile.respawn_ms)
                }

              :damaged ->
                state
            end

          {:reply, {:ok, next_combat_state.hp}, %{next_state | combat_state: next_combat_state}}
      end
    else
      false -> {:reply, {:error, :out_of_range}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:player_enter, _cid, _location}, state), do: {:noreply, state}
  def handle_cast({:player_leave, _cid}, state), do: {:noreply, state}
  def handle_cast({:player_move, _snapshot}, state), do: {:noreply, state}
  def handle_cast({:chat_message, _cid, _username, _text}, state), do: {:noreply, state}
  def handle_cast({:skill_event, _cid, _skill_id, _location}, state), do: {:noreply, state}
  def handle_cast({:player_state, _cid, _hp, _max_hp, _alive}, state), do: {:noreply, state}

  def handle_cast(
        {:combat_hit, _source_cid, _target_cid, _skill_id, _damage, _hp_after, _location},
        state
      ),
      do: {:noreply, state}

  @impl true
  def handle_info(
        :brain_tick,
        %{
          profile: profile,
          npc_state: npc_state,
          combat_state: combat_state,
          skill_casts: skill_casts,
          aoi_ref: aoi_ref
        } = state
      ) do
    facts = gather_facts(npc_state, combat_state, profile)
    {intent, target_cid} = Brain.decide(facts, profile)
    now = System.system_time(:millisecond)

    next_state = %{
      state
      | npc_state: %{
          npc_state
          | intent: intent,
            current_target_cid: target_cid,
            last_decision_at_ms: now
        }
    }

    updated_state =
      case {intent, target_cid, Skill.fetch(1)} do
        {:attack, _target_cid, {:ok, skill}} ->
          case cooldown_ready?(skill_casts, skill, now) do
            :ok ->
              GenServer.cast(
                aoi_ref,
                {:skill_cast, npc_state.npc_id, skill.id, npc_state.position}
              )

              apply_skill_hits(npc_state.npc_id, skill, npc_state.position)
              %{next_state | skill_casts: Map.put(skill_casts, skill.id, now)}

            _ ->
              next_state
          end

        _ ->
          next_state
      end

    {:noreply, %{updated_state | brain_timer: schedule_brain_tick(profile.brain_tick_ms)}}
  end

  @impl true
  def handle_info(
        :respawn,
        %{profile: profile, combat_state: combat_state, aoi_ref: aoi_ref, npc_state: npc_state} =
          state
      ) do
    if combat_state.alive do
      {:noreply, %{state | respawn_timer: nil}}
    else
      respawned = CombatState.respawn(combat_state)

      respawned_npc_state = %{
        npc_state
        | position: profile.spawn_position,
          intent: :idle,
          current_target_cid: nil,
          alive: true
      }

      GenServer.cast(
        aoi_ref,
        {:health_update, profile.npc_id, respawned.hp, respawned.max_hp, respawned.alive}
      )

      {:noreply,
       %{
         state
         | combat_state: respawned,
           npc_state: respawned_npc_state,
           skill_casts: %{},
           respawn_timer: nil
       }}
    end
  end

  @impl true
  def terminate(_reason, %{
        brain_timer: brain_timer,
        respawn_timer: respawn_timer,
        aoi_ref: aoi_ref
      }) do
    if brain_timer != nil, do: Process.cancel_timer(brain_timer)
    if respawn_timer != nil, do: Process.cancel_timer(respawn_timer)
    if is_pid(aoi_ref) and Process.alive?(aoi_ref), do: GenServer.call(aoi_ref, :exit)
    :ok
  end

  defp gather_facts(%State{} = npc_state, %CombatState{} = combat_state, %Profile{} = profile) do
    {target_cid, target_distance} = nearest_player(npc_state.position)

    %Facts{
      alive: combat_state.alive,
      position: npc_state.position,
      spawn_position: profile.spawn_position,
      target_cid: target_cid,
      target_distance: target_distance,
      distance_from_spawn: distance(npc_state.position, profile.spawn_position)
    }
  end

  defp nearest_player(origin) do
    0
    |> Targeting.nearby_combatant_pids(origin, 180.0)
    |> Enum.map(fn pid ->
      case Targeting.safe_summary(pid) do
        {:ok, %{kind: :player, cid: cid, position: position, alive: true}} ->
          {cid, distance(origin, position)}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_cid, dist} -> dist end)
    |> List.first()
    |> case do
      {cid, dist} -> {cid, dist}
      nil -> {nil, nil}
    end
  end

  defp ensure_alive(%CombatState{alive: true}), do: :ok
  defp ensure_alive(%CombatState{}), do: {:error, :dead}

  defp cooldown_ready?(skill_casts, %Skill{id: skill_id, cooldown_ms: cooldown_ms}, now) do
    case Map.get(skill_casts, skill_id) do
      nil -> :ok
      last_cast when now - last_cast >= cooldown_ms -> :ok
      _ -> {:error, :skill_cooldown}
    end
  end

  defp apply_skill_hits(source_cid, %Skill{} = skill, location) do
    source_cid
    |> Targeting.nearby_combatant_pids(location, skill.radius)
    |> Enum.each(fn pid ->
      _ = safe_actor_call(pid, {:apply_skill_hit, source_cid, skill, location})
    end)
  end

  defp safe_actor_call(pid, message) do
    try do
      GenServer.call(pid, message)
    catch
      :exit, _reason -> :error
    end
  end

  defp within_skill_radius?(source, target, radius) do
    distance(source, target) <= radius
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
