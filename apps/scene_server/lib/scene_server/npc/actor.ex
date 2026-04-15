defmodule SceneServer.Npc.Actor do
  @moduledoc """
  Authoritative runtime process for one active NPC.

  An `Npc.Actor` combines four responsibilities that must stay in sync for one
  NPC instance:

  - AI intent state (`Npc.State`)
  - authoritative movement state (`Movement.State`)
  - authoritative combat state (`Combat.State`)
  - AOI registration and broadcasts

  The actor itself is the orchestration boundary; decision rules remain in
  `Npc.Brain`, movement input shaping in `Npc.Navigation`, and attack tuning in
  `Npc.Attack`.
  """

  use GenServer, restart: :temporary

  alias SceneServer.AoiManager
  alias SceneServer.Combat.CastRequest
  alias SceneServer.Combat.Executor, as: CombatExecutor
  alias SceneServer.Combat.Profile, as: CombatProfile
  alias SceneServer.Combat.Skill
  alias SceneServer.Combat.State, as: CombatState
  alias SceneServer.Combat.Targeting
  alias SceneServer.Movement.InputFrame
  alias SceneServer.Movement.{Engine, RemoteSnapshot}
  alias SceneServer.Movement.Profile, as: MovementProfile
  alias SceneServer.Movement.State, as: MovementState
  alias SceneServer.Npc.{Attack, Brain, Facts, Navigation}
  alias SceneServer.Npc.Profile, as: NpcProfile
  alias SceneServer.Npc.State, as: NpcState

  @stopped_speed_epsilon 1.0

  @doc """
  Starts one active NPC actor from a concrete NPC profile.
  """
  def start_link({profile, opts}, genserver_opts \\ []) do
    GenServer.start_link(__MODULE__, {profile, opts}, genserver_opts)
  end

  @impl true
  def init({%NpcProfile{} = profile, _opts}) do
    combat_profile = %CombatProfile{max_hp: profile.max_hp, respawn_ms: profile.respawn_ms}

    state = %{
      profile: profile,
      npc_state: NpcState.idle(profile),
      combat_profile: combat_profile,
      combat_state: CombatState.new(combat_profile),
      movement_profile: MovementProfile.default(),
      movement_state: MovementState.idle(profile.spawn_position),
      next_input_seq: 1,
      skill_casts: %{},
      aoi_ref: nil,
      brain_timer: nil,
      movement_timer: nil,
      respawn_timer: nil
    }

    {:ok, state, {:continue, :spawn_aoi}}
  end

  @impl true
  def handle_continue(
        :spawn_aoi,
        %{profile: profile, combat_state: combat_state} = state
      ) do
    {:ok, aoi_ref} =
      AoiManager.add_aoi_item(
        profile.npc_id,
        System.system_time(:millisecond),
        profile.spawn_position,
        self(),
        self(),
        %{kind: :npc, name: profile.name}
      )

    GenServer.cast(
      aoi_ref,
      {:player_state, profile.npc_id, combat_state.hp, combat_state.max_hp, combat_state.alive}
    )

    {:noreply,
     %{
       state
       | aoi_ref: aoi_ref,
         brain_timer: schedule_brain_tick(profile.brain_tick_ms),
         movement_timer: schedule_movement_tick(profile.movement_tick_ms)
     }}
  end

  @impl true
  def handle_call(:await_ready, _from, %{aoi_ref: aoi_ref} = state) when not is_nil(aoi_ref),
    do: {:reply, :ok, state}

  def handle_call(:await_ready, _from, state), do: {:reply, {:error, :not_ready}, state}

  @impl true
  def handle_call(
        :get_state_summary,
        _from,
        %{profile: profile, npc_state: npc_state, movement_state: movement_state, combat_state: combat_state} =
          state
      ) do
    {:reply,
     {:ok,
      %{
        kind: :npc,
        npc_id: npc_state.npc_id,
        cid: npc_state.npc_id,
        name: profile.name,
        position: movement_state.position,
        hp: combat_state.hp,
        max_hp: combat_state.max_hp,
        alive: combat_state.alive,
        deaths: combat_state.deaths,
        intent: npc_state.intent,
        target_cid: npc_state.current_target_cid
      }}, state}
  end

  @impl true
  def handle_call(
        {:apply_damage_effect, source_cid, skill_id, damage, _impact_location},
        _from,
        %{
          profile: profile,
          movement_state: movement_state,
          combat_state: combat_state,
          aoi_ref: aoi_ref,
          respawn_timer: respawn_timer,
          npc_state: npc_state
        } = state
      ) do
    with :ok <- ensure_alive(combat_state),
         true <- source_cid != profile.npc_id do
      case CombatState.apply_damage(combat_state, damage) do
        {:ignored, next_combat_state} ->
          {:reply, {:ok, next_combat_state.hp}, %{state | combat_state: next_combat_state}}

        {result, next_combat_state, dealt_damage} ->
          GenServer.cast(
            aoi_ref,
            {:combat_resolved, source_cid, profile.npc_id, skill_id, dealt_damage,
             next_combat_state.hp, movement_state.position}
          )

          GenServer.cast(
            aoi_ref,
            {:health_update, profile.npc_id, next_combat_state.hp, next_combat_state.max_hp,
             next_combat_state.alive}
          )

          {next_state, next_movement_state, next_npc_state, next_respawn_timer} =
            case result do
              :killed ->
                if respawn_timer != nil, do: Process.cancel_timer(respawn_timer)

                {
                  state,
                  stopped_movement_state(movement_state),
                  %{npc_state | intent: :dead, current_target_cid: nil},
                  Process.send_after(self(), :respawn, state.combat_profile.respawn_ms)
                }

              :damaged ->
                {state, movement_state, npc_state, respawn_timer}
            end

          {:reply, {:ok, next_combat_state.hp},
           %{
             next_state
             | combat_state: next_combat_state,
               movement_state: next_movement_state,
               npc_state: next_npc_state,
               respawn_timer: next_respawn_timer
           }}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:player_enter, _cid, _location}, state), do: {:noreply, state}
  def handle_cast({:player_leave, _cid}, state), do: {:noreply, state}
  def handle_cast({:player_move, _snapshot}, state), do: {:noreply, state}
  def handle_cast({:actor_identity, _cid, _kind, _name}, state), do: {:noreply, state}
  def handle_cast({:chat_message, _cid, _username, _text}, state), do: {:noreply, state}
  def handle_cast({:skill_event, _cid, _skill_id, _location}, state), do: {:noreply, state}
  def handle_cast({:effect_event, _effect_event}, state), do: {:noreply, state}
  def handle_cast({:player_state, _cid, _hp, _max_hp, _alive}, state), do: {:noreply, state}

  def handle_cast(
        {:combat_hit, _source_cid, _target_cid, _skill_id, _damage, _hp_after, _location},
        state
      ),
      do: {:noreply, state}

  @impl true
  def handle_info(
        :brain_tick,
        %{profile: profile, npc_state: npc_state, combat_state: combat_state} = state
      ) do
    facts = gather_facts(state)
    {intent, target_cid} = Brain.decide(facts, profile)
    now = System.system_time(:millisecond)

    next_npc_state = %{
      npc_state
      | intent: intent,
        current_target_cid: target_cid,
        last_decision_at_ms: now
    }

    updated_state =
      case {combat_state.alive, intent, target_cid} do
        {true, :attack, _target_cid} ->
          skill = Attack.skill(profile)
          maybe_cast_skill(state, next_npc_state, skill, now)

        _ ->
          %{state | npc_state: next_npc_state}
      end

    {:noreply, %{updated_state | brain_timer: schedule_brain_tick(profile.brain_tick_ms)}}
  end

  @impl true
  def handle_info(
        {:resolve_skill_cast, cast},
        %{aoi_ref: aoi_ref} = state
      ) do
    resolution = CombatExecutor.resolve_cast(cast)
    broadcast_effect_events(aoi_ref, resolution.cues)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        :movement_tick,
        %{
          profile: profile,
          movement_profile: movement_profile,
          movement_state: movement_state,
          npc_state: npc_state,
          combat_state: combat_state,
          next_input_seq: next_input_seq,
          aoi_ref: aoi_ref
        } = state
      ) do
    movement_timer = schedule_movement_tick(profile.movement_tick_ms)

    input_frame =
      Navigation.build_input_frame(
        npc_state,
        movement_state,
        movement_profile,
        profile,
        target_position(npc_state, profile),
        next_input_seq
      )

    if should_advance_movement?(movement_state, input_frame, combat_state) do
      {next_movement_state, _ack} =
        Engine.step(profile.npc_id, movement_state, input_frame, movement_profile)

      GenServer.cast(aoi_ref, {:self_move, RemoteSnapshot.from_state(profile.npc_id, next_movement_state)})

      {:noreply,
       %{
         state
         | movement_state: next_movement_state,
           movement_timer: movement_timer,
           next_input_seq: next_input_seq + 1
       }}
    else
      {:noreply,
       %{
         state
         | movement_timer: movement_timer,
           next_input_seq: next_input_seq + 1
       }}
    end
  end

  @impl true
  def handle_info(
        :respawn,
        %{profile: profile, combat_state: combat_state, movement_state: movement_state, aoi_ref: aoi_ref} =
          state
      ) do
    if combat_state.alive do
      {:noreply, %{state | respawn_timer: nil}}
    else
      respawned_combat_state = CombatState.respawn(combat_state)

      respawned_movement_state = %{
        movement_state
        | position: profile.spawn_position,
          velocity: {0.0, 0.0, 0.0},
          acceleration: {0.0, 0.0, 0.0}
      }

      respawned_npc_state = NpcState.idle(profile)

      GenServer.cast(
        aoi_ref,
        {:self_move, RemoteSnapshot.from_state(profile.npc_id, respawned_movement_state)}
      )

      GenServer.cast(
        aoi_ref,
        {:health_update, profile.npc_id, respawned_combat_state.hp, respawned_combat_state.max_hp,
         respawned_combat_state.alive}
      )

      {:noreply,
       %{
         state
         | combat_state: respawned_combat_state,
           movement_state: respawned_movement_state,
           npc_state: respawned_npc_state,
           skill_casts: %{},
           respawn_timer: nil
       }}
    end
  end

  @impl true
  def terminate(_reason, %{brain_timer: brain_timer, movement_timer: movement_timer, respawn_timer: respawn_timer, aoi_ref: aoi_ref}) do
    if brain_timer != nil, do: Process.cancel_timer(brain_timer)
    if movement_timer != nil, do: Process.cancel_timer(movement_timer)
    if respawn_timer != nil, do: Process.cancel_timer(respawn_timer)
    if is_pid(aoi_ref) and Process.alive?(aoi_ref), do: GenServer.call(aoi_ref, :exit)
    :ok
  end

  defp gather_facts(%{profile: profile, movement_state: movement_state, combat_state: combat_state}) do
    {target_cid, target_distance} = nearest_player(movement_state.position, profile.aggro_radius)

    %Facts{
      alive: combat_state.alive,
      position: movement_state.position,
      spawn_position: profile.spawn_position,
      target_cid: target_cid,
      target_distance: target_distance,
      distance_from_spawn: distance(movement_state.position, profile.spawn_position)
    }
  end

  defp nearest_player(origin, radius) do
    0
    |> Targeting.nearby_combatant_pids(origin, radius)
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

  defp maybe_cast_skill(
         %{aoi_ref: aoi_ref, movement_state: movement_state, profile: profile, skill_casts: skill_casts} =
           state,
         %NpcState{} = next_npc_state,
         %Skill{} = skill,
         now
       ) do
    case cooldown_ready?(skill_casts, skill, now) do
      :ok ->
        case CombatExecutor.prepare_cast(
               %{cid: profile.npc_id, position: movement_state.position},
               CastRequest.auto(skill.id),
               skill
             ) do
          {:ok, execution} ->
            GenServer.cast(aoi_ref, {:skill_cast, profile.npc_id, skill.id, movement_state.position})
            broadcast_effect_events(aoi_ref, execution.initial_cues)
            schedule_skill_resolution(execution.delayed_cast)
            %{state | npc_state: next_npc_state, skill_casts: Map.put(skill_casts, skill.id, now)}

          {:error, _reason} ->
            %{state | npc_state: next_npc_state}
        end

      _ ->
        %{state | npc_state: next_npc_state}
    end
  end

  defp target_position(%NpcState{intent: :chase, current_target_cid: target_cid}, _profile)
       when is_integer(target_cid) do
    case Targeting.safe_summary_by_cid(target_cid) do
      {:ok, %{position: position, alive: true}} -> position
      _ -> nil
    end
  end

  defp target_position(%NpcState{intent: :return_home}, %NpcProfile{spawn_position: spawn_position}) do
    spawn_position
  end

  defp target_position(_npc_state, _profile), do: nil

  defp should_advance_movement?(_movement_state, _input_frame, %CombatState{alive: false}), do: false

  defp should_advance_movement?(%MovementState{} = movement_state, %InputFrame{} = input_frame, _combat_state) do
    movement_active?(movement_state) or input_active?(input_frame)
  end

  defp movement_active?(%MovementState{velocity: velocity}) do
    vector_magnitude(velocity) > @stopped_speed_epsilon
  end

  defp input_active?(%InputFrame{input_dir: {x, y}}) do
    abs(x) > 1.0e-6 or abs(y) > 1.0e-6
  end

  defp vector_magnitude({x, y, z}) do
    :math.sqrt(x * x + y * y + z * z)
  end

  defp stopped_movement_state(%MovementState{} = movement_state) do
    %{movement_state | velocity: {0.0, 0.0, 0.0}, acceleration: {0.0, 0.0, 0.0}}
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

  defp distance({ax, ay, az}, {bx, by, bz}) do
    dx = ax - bx
    dy = ay - by
    dz = az - bz
    :math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  defp schedule_skill_resolution(%{travel_ms: 0} = cast) do
    send(self(), {:resolve_skill_cast, cast})
  end

  defp schedule_skill_resolution(%{travel_ms: travel_ms} = cast) when travel_ms > 0 do
    Process.send_after(self(), {:resolve_skill_cast, cast}, travel_ms)
  end

  defp broadcast_effect_events(aoi_ref, effect_events) when is_list(effect_events) do
    Enum.each(effect_events, fn effect_event ->
      GenServer.cast(aoi_ref, {:effect_event, effect_event})
    end)
  end

  defp schedule_brain_tick(interval_ms) do
    Process.send_after(self(), :brain_tick, interval_ms)
  end

  defp schedule_movement_tick(interval_ms) do
    Process.send_after(self(), :movement_tick, interval_ms)
  end
end
