defmodule SceneServer.PlayerCharacter do
  @moduledoc """
  Authoritative runtime process for one active player character.

  `PlayerCharacter` is the player-side aggregate root. It owns:

  - authoritative movement state and fixed-tick input consumption
  - authoritative combat state and skill cooldowns
  - AOI registration/broadcast integration
  - respawn lifecycle

  Compared with `SceneServer.Npc.Actor`, this module also mediates network-origin
  input and time sync concerns because player actors are driven by a remote
  client. Network ingress writes movement frames into an ETS input buffer through
  `submit_movement_input/2`; the actor drains that buffer only from its
  authoritative fixed tick so high-frequency client input cannot starve the tick
  in the GenServer mailbox.
  """

  use GenServer, restart: :temporary

  require Logger

  alias SceneServer.AoiManager
  alias SceneServer.Aoi.AoiItem
  alias SceneServer.Combat.CastRequest
  alias SceneServer.Combat.Executor, as: CombatExecutor
  alias SceneServer.Combat.Profile, as: CombatProfile
  alias SceneServer.Combat.Skill
  alias SceneServer.Combat.State, as: CombatState
  alias SceneServer.Combat.VoxelDamageRouter

  alias SceneServer.Movement.{
    Ack,
    CorrectionFlags,
    Engine,
    InputFrame,
    Profile,
    RemoteSnapshot,
    State,
    VoxelCollision
  }

  @default_dev_attrs %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20}
  # Default spawn over the DevSeed 16×16 stone platform on chunk (0,0,0).
  #
  # Movement world coords use server Z as vertical. The browser maps this
  # spawn to x=750,y=185,z=750, above DevSeed's voxel y=0 platform centered at
  # x/z = 750 in renderer units.
  # Movement positions are avatar centers. DevSeed's y=0 platform tops out at
  # z=100 cm, so the 170 cm avatar starts at 100 + half-height.
  @default_location {750.0, 750.0, 185.0}
  @legacy_dev_seed_center_location {750.0, 750.0, 100.0}

  @lock_retry_attempts 5
  @lock_retry_sleep_ms 5
  # Hold the last direction for a short local-jitter window before assuming the client
  # really wants to stop. The client sends an explicit stop frame on key release
  # (web client idle coalescing still sends a brake frame), so the only reason
  # to zero-direction here is a connection that quietly dropped.
  @input_hold_timeout_multiplier 20
  @stopped_speed_epsilon 1.0
  # Cap on how many client input frames we replay in one wall-clock tick. In
  # normal play the client sends one frame per fixed tick; browser scheduling
  # can still batch a few frames, so the queue allows a small jitter burst
  # without replaying an unbounded backlog.
  @max_input_queue 8
  @max_buffered_movement_inputs 64
  # Wide enough for browser idle coalescing and local-only fixed ticks; still
  # rejects impossible far-future sequence poisoning.
  @max_forward_input_seq_gap 4_096
  @idle_remote_snapshot_interval_ms 500
  @movement_collision_query_timeout_ms 50
  @movement_input_buffer_table Module.concat(__MODULE__, MovementInputBuffer)

  @doc """
  Starts one authoritative player character process.
  """
  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @doc """
  Buffers a network-origin movement frame outside the player actor mailbox.

  The authoritative actor still validates and simulates the frame on its fixed
  movement tick. This function is intentionally non-blocking so Gate workers can
  ingest 60Hz input without turning the player actor mailbox into the input
  queue.
  """
  def submit_movement_input(player_character, %InputFrame{} = frame)
      when is_pid(player_character) do
    cond do
      node(player_character) != node() ->
        :rpc.cast(node(player_character), __MODULE__, :submit_movement_input, [
          player_character,
          frame
        ])

        :accepted

      Process.alive?(player_character) ->
        table = ensure_movement_input_buffer_table()
        received_at_ms = System.monotonic_time(:millisecond)
        :ets.insert(table, {{player_character, frame.seq}, frame, received_at_ms})
        prune_buffered_movement_inputs(player_character)
        :accepted

      true ->
        {:error, :invalid_player}
    end
  catch
    :error, reason -> {:error, reason}
  end

  def submit_movement_input(_player_character, %InputFrame{}), do: {:error, :invalid_player}

  @doc false
  def pending_movement_input_count(player_character) when is_pid(player_character) do
    player_character
    |> buffered_movement_input_entries()
    |> length()
  end

  def pending_movement_input_count(_player_character), do: 0

  @doc """
  Updates the player authority with the latest server-authoritative partition window.

  `PlayerCharacter` keeps the DTO so a rebuilt AOI adapter can receive the same
  partition context before it resumes live subscription refreshes.
  """
  def update_partition_window(player_character, partition_window) when is_pid(player_character) do
    GenServer.cast(player_character, {:partition_window, partition_window})
  end

  @doc false
  def connection_monitor_ref(connection_pid, node_fun \\ &:erlang.node/1)

  def connection_monitor_ref(connection_pid, node_fun) when is_pid(connection_pid) do
    if node_fun.(connection_pid) == node() do
      if Process.alive?(connection_pid), do: Process.monitor(connection_pid), else: nil
    else
      Process.monitor(connection_pid)
    end
  end

  def connection_monitor_ref(_connection_pid, _node_fun), do: nil

  @impl true
  def init({cid, connection_pid, client_timestamp, character_profile}) do
    # :pg.start_link(@scope)
    # :pg.join(@scope, @topic, self())
    Logger.debug("New player created.")

    SceneServer.CliObserve.emit("player_init", %{
      cid: cid,
      connection_pid: connection_pid,
      client_timestamp: client_timestamp,
      profile: character_profile
    })

    # Phase A4-bis follow-up: monitor the gate connection_pid so we
    # tear down promptly when the player disconnects (browser refresh,
    # tab close, ws drop). Without this the PlayerCharacter outlives
    # the connection, keeps occupying its AoiManager entry, and shows
    # up to other players as a stationary "ghost" stuck at spawn —
    # which is exactly the "remote cube doesn't follow you, then
    # appears to follow because you walked back" optical illusion.
    connection_monitor_ref = connection_monitor_ref(connection_pid)
    movement_ack_pid = movement_ack_pid_from_profile(character_profile, connection_pid)
    character_profile = normalize_character_profile(cid, character_profile)
    movement_profile = Profile.default()
    movement_epoch_ms = :os.system_time(:millisecond)

    movement_state =
      character_profile.position
      |> State.idle()
      |> stamp_movement_state(movement_epoch_ms, movement_profile.fixed_dt_ms)

    {:ok,
     %{
       cid: cid,
       character_profile: character_profile,
       connection_pid: connection_pid,
       movement_ack_pid: movement_ack_pid,
       connection_monitor_ref: connection_monitor_ref,
       last_location: character_profile.position,
       physys_ref: nil,
       aoi_ref: nil,
       character_data_ref: nil,
       spawn_location: character_profile.position,
       movement_state: movement_state,
       movement_profile: movement_profile,
       movement_epoch_ms: movement_epoch_ms,
       combat_profile: CombatProfile.default(),
       combat_state: CombatState.new(CombatProfile.default()),
       latched_input: idle_input_frame(Profile.default().fixed_dt_ms),
       input_queue: [],
       last_input_seq: 0,
       last_ack_seq: 0,
       last_client_tick: 0,
       last_input_received_at_ms: System.monotonic_time(:millisecond),
       movement_input_dropped_count: 0,
       status: :in_scene,
       old_timestamp: nil,
       net_delay: 0,
       skill_casts: %{},
       partition_window_dto: nil,
       partition_updated_at_ms: nil,
       movement_timer: nil,
       last_remote_snapshot_sent_at_ms: System.monotonic_time(:millisecond),
       aoi_monitor_ref: nil,
       respawn_timer: nil,
       # Phase A1-5:scene_id 用于把 skill cast 的 target_position lookup
       # 进 ChunkSnapshotStore → ObjectRegistry.accumulate_damage(voxel
       # damage 路由)。Demo 阶段 default 1;follow-up:从 enter_scene
       # wire 或 character_profile 读真实 logical_scene_id。
       logical_scene_id: 1
     }, {:continue, {:load, client_timestamp}}}
  end

  @impl true
  def handle_continue(
        {:load, client_timestamp},
        %{cid: cid, connection_pid: connection_pid, character_profile: character_profile} = state
      ) do
    %{name: name, position: location} = character_profile
    movement_profile = state.movement_profile

    with {:ok, physys_ref} <- SceneServer.PhysicsManager.get_physics_system_ref(),
         {:ok, cd_ref} <-
           new_character_data_with_retry(cid, name, location, @default_dev_attrs, physys_ref),
         {:ok, aoi_ref} <-
           enter_scene(cid, client_timestamp, location, connection_pid, character_profile.name) do
      movement_timer = make_movement_timer(movement_profile.fixed_dt_ms)
      aoi_monitor_ref = Process.monitor(aoi_ref)
      combat_state = state.combat_state

      GenServer.cast(
        aoi_ref,
        {:player_state, cid, combat_state.hp, combat_state.max_hp, combat_state.alive}
      )

      {:noreply,
       %{
         state
         | physys_ref: physys_ref,
           aoi_ref: aoi_ref,
           aoi_monitor_ref: aoi_monitor_ref,
           character_data_ref: cd_ref,
           movement_timer: movement_timer
       }}
    else
      {:error, reason} ->
        SceneServer.CliObserve.emit("player_load_error", %{cid: cid, reason: reason})
        {:stop, {:load_failed, reason}, state}
    end
  end

  @impl true
  def handle_call(:exit, _from, state) do
    {:stop, :normal, {:ok, ""}, state}
  end

  @impl true
  def handle_call(:await_ready, _from, state) do
    if state.character_data_ref != nil and state.physys_ref != nil and state.aoi_ref != nil do
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_ready}, state}
    end
  end

  @impl true
  def handle_call(:get_next_input_seq, _from, state) do
    # Audit B-S1 / B-SRV1: report the seq the server is going to expect for
    # the *next* movement input. Initial state has last_input_seq = 0, so a
    # fresh PlayerCharacter (every reconnect — PlayerManager rebuilds the
    # process) yields next = 1, matching the client's reset_to_seq(1) on
    # cold start. If sessions ever start being recycled, this handler is
    # the single point where the contract is upheld.
    {:reply, {:ok, state.last_input_seq + 1}, state}
  end

  @impl true
  def handle_call(:get_state_summary, _from, state) do
    summary = %{
      kind: :player,
      cid: state.cid,
      name: state.character_profile.name,
      position: state.last_location,
      hp: state.combat_state.hp,
      max_hp: state.combat_state.max_hp,
      alive: state.combat_state.alive,
      deaths: state.combat_state.deaths
    }

    {:reply, {:ok, summary}, state}
  end

  @impl true
  def handle_call(
        :get_location,
        _from,
        %{character_data_ref: nil, last_location: last_location} = state
      ) do
    {:reply, {:ok, last_location}, state}
  end

  @impl true
  def handle_call(
        :get_location,
        _from,
        %{character_data_ref: cd_ref, physys_ref: physys_ref, last_location: last_location} =
          state
      ) do
    case get_character_location_with_retry(cd_ref, physys_ref, last_location) do
      {:ok, location} ->
        {:reply, {:ok, location}, %{state | last_location: location}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        :time_sync,
        _from,
        %{old_timestamp: old_timestamp, net_delay: old_delay} = state
      ) do
    new_timestamp = :os.system_time(:millisecond)

    case old_timestamp do
      nil ->
        {true, %{state | old_timestamp: new_timestamp}}
        {:reply, {:ok, new_timestamp}, %{state | old_timestamp: new_timestamp}}

      _ ->
        Logger.debug("CS延迟: #{div(new_timestamp - old_timestamp, 2)}")

        temp_delay = div(new_timestamp - old_timestamp, 2)

        new_delay =
          if old_delay != 0 do
            div(temp_delay + old_delay, 2)
            # ((new_timestamp - old_timestamp) / 2 + old_delay) / 2
          else
            temp_delay
          end

        {false, %{state | old_timestamp: nil, net_delay: new_delay}}

        {:reply, {:ok, :end}, %{state | old_timestamp: nil, net_delay: new_delay}}
    end
  end

  @impl true
  def handle_call(
        {:movement_input, %InputFrame{} = frame},
        _from,
        state
      ) do
    case accept_movement_input_frame(frame, state) do
      {:ok, next_state} ->
        {:reply, {:ok, :accepted}, next_state}

      {:error, reason, next_state} ->
        emit_movement_input_error(next_state, reason)
        {:reply, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_call({:chat_say, cid, username, text}, _from, state) do
    SceneServer.CliObserve.emit("player_chat_legacy_rejected", %{
      cid: cid,
      username: username,
      text: text,
      reason: :chat_runtime_required
    })

    {:reply, {:error, :chat_runtime_required}, state}
  end

  @impl true
  def handle_call(
        {:cast_skill, skill_id},
        from,
        state
      )
      when is_integer(skill_id) do
    handle_call({:cast_skill, CastRequest.auto(skill_id)}, from, state)
  end

  @impl true
  def handle_call(
        {:cast_skill, %CastRequest{} = cast_request},
        _from,
        %{
          cid: cid,
          aoi_ref: aoi_ref,
          skill_casts: skill_casts,
          combat_state: combat_state,
          character_data_ref: cd_ref,
          physys_ref: physys_ref,
          last_location: last_location
        } = state
      ) do
    now = :os.system_time(:millisecond)

    with :ok <- ensure_alive(combat_state),
         {:ok, skill} <- Skill.fetch(cast_request.skill_id),
         :ok <- cooldown_ready?(skill_casts, skill, now),
         {:ok, location} <- get_character_location_with_retry(cd_ref, physys_ref, last_location),
         {:ok, execution} <-
           CombatExecutor.prepare_cast(%{cid: cid, position: location}, cast_request, skill) do
      SceneServer.CliObserve.emit("player_skill", %{
        cid: cid,
        skill_id: cast_request.skill_id,
        location: location
      })

      GenServer.cast(aoi_ref, {:skill_cast, cid, cast_request.skill_id, location})
      broadcast_effect_events(aoi_ref, execution.initial_cues)
      schedule_skill_resolution(execution.delayed_cast)

      {:reply, {:ok, location},
       %{
         state
         | skill_casts: Map.put(skill_casts, cast_request.skill_id, now),
           last_location: location
       }}
    else
      {:error, reason} ->
        SceneServer.CliObserve.emit("player_skill_error", %{
          cid: cid,
          skill_id: Map.get(cast_request, :skill_id),
          reason: reason
        })

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:apply_damage_effect, source_cid, skill_id, damage, _impact_location},
        _from,
        %{
          cid: cid,
          aoi_ref: aoi_ref,
          combat_state: combat_state,
          respawn_timer: respawn_timer,
          movement_profile: movement_profile,
          movement_state: movement_state,
          character_data_ref: cd_ref,
          physys_ref: physys_ref,
          last_location: last_location
        } = state
      ) do
    with :ok <- ensure_alive(combat_state),
         true <- source_cid != cid,
         {:ok, location} <- get_character_location_with_retry(cd_ref, physys_ref, last_location) do
      case CombatState.apply_damage(combat_state, damage) do
        {:ignored, next_combat_state} ->
          {:reply, {:ok, next_combat_state.hp},
           %{state | combat_state: next_combat_state, last_location: location}}

        {result, next_combat_state, dealt_damage} ->
          GenServer.cast(
            aoi_ref,
            {:combat_resolved, source_cid, cid, skill_id, dealt_damage, next_combat_state.hp,
             location}
          )

          GenServer.cast(
            aoi_ref,
            {:health_update, cid, next_combat_state.hp, next_combat_state.max_hp,
             next_combat_state.alive}
          )

          {next_state, next_respawn_timer} =
            case result do
              :killed ->
                if respawn_timer != nil, do: Process.cancel_timer(respawn_timer)

                reset_movement_after_death(
                  cd_ref,
                  physys_ref,
                  movement_profile,
                  movement_state,
                  state
                )

              :damaged ->
                {state, respawn_timer}
            end

          {:reply, {:ok, next_combat_state.hp},
           %{
             next_state
             | combat_state: next_combat_state,
               respawn_timer: next_respawn_timer,
               last_location: location
           }}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:movement_input, %InputFrame{} = frame}, state) do
    case accept_movement_input_frame(frame, state) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, reason, next_state} ->
        emit_movement_input_error(next_state, reason)
        {:noreply, next_state}
    end
  end

  @impl true
  def handle_cast({:partition_window, nil}, %{cid: cid} = state) do
    SceneServer.CliObserve.emit("player_partition_window_preserved", %{
      cid: cid,
      reason: :nil_partition_window,
      had_partition_window: not is_nil(state.partition_window_dto)
    })

    {:noreply, state}
  end

  @impl true
  def handle_cast({:partition_window, partition_window}, %{cid: cid, aoi_ref: aoi_ref} = state) do
    updated_at_ms = System.monotonic_time(:millisecond)
    apply_partition_window_to_aoi(aoi_ref, partition_window)

    SceneServer.CliObserve.emit("player_partition_window_updated", fn ->
      Map.merge(
        %{cid: cid, updated_at_ms: updated_at_ms},
        partition_window_summary(partition_window)
      )
    end)

    {:noreply,
     %{
       state
       | partition_window_dto: partition_window,
         partition_updated_at_ms: updated_at_ms
     }}
  end

  @impl true
  def handle_info(
        {:resolve_skill_cast, cast},
        %{aoi_ref: aoi_ref, logical_scene_id: scene_id} = state
      ) do
    resolution = CombatExecutor.resolve_cast(cast)
    broadcast_effect_events(aoi_ref, resolution.cues)
    # Phase A1-5:并行尝试 voxel damage(actor damage 已经 fan-out 走
    # CombatExecutor.resolve_cast)。target_position 单位是 world cm;
    # 1 macro = 100 cm = 8 micro,所以 cm × 8 / 100 = micro_unit_index。
    try_voxel_damage(scene_id, cast)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, conn_pid, reason},
        %{connection_monitor_ref: monitor_ref, connection_pid: conn_pid} = state
      ) do
    SceneServer.CliObserve.emit("player_connection_down", %{
      cid: state.cid,
      connection_pid: conn_pid,
      reason: inspect(reason)
    })

    # Stop normally so terminate/2 runs the AOI / PlayerManager cleanup
    # path. Returning :normal keeps DynamicSupervisor from logging this
    # as a crash — disconnect is the expected end-of-session signal.
    {:stop, :normal, %{state | connection_monitor_ref: nil}}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, aoi_ref, reason},
        %{aoi_monitor_ref: monitor_ref, aoi_ref: aoi_ref} = state
      ) do
    case recover_aoi_adapter(state, reason) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, recover_reason} ->
        SceneServer.CliObserve.emit("player_aoi_recover_error", %{
          cid: state.cid,
          down_reason: reason,
          recover_reason: recover_reason
        })

        Process.send_after(self(), :recover_aoi, 250)
        {:noreply, %{state | aoi_monitor_ref: nil}}
    end
  end

  @impl true
  def handle_info({:DOWN, _monitor_ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info(:recover_aoi, state) do
    case ensure_aoi_runtime(state) do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(:movement_tick, state) do
    state =
      case ensure_aoi_runtime(state) do
        {:ok, next_state} -> next_state
        {:error, _reason} -> state
      end

    state = drain_buffered_movement_inputs(state)

    %{
      cid: cid,
      connection_pid: connection_pid,
      aoi_ref: aoi_ref,
      character_data_ref: cd_ref,
      physys_ref: physys_ref,
      combat_state: combat_state,
      movement_state: movement_state,
      movement_profile: movement_profile,
      latched_input: latched_input,
      input_queue: input_queue,
      last_ack_seq: last_ack_seq,
      last_input_received_at_ms: last_input_received_at_ms
    } = state

    movement_timer = make_movement_timer(movement_profile.fixed_dt_ms)
    now_ms = System.monotonic_time(:millisecond)

    case input_queue do
      [_ | _] = queued ->
        replay_queued_inputs(
          queued,
          %{state | movement_timer: movement_timer, input_queue: []},
          cid,
          connection_pid,
          aoi_ref,
          cd_ref,
          physys_ref,
          movement_state,
          movement_profile,
          now_ms - last_input_received_at_ms
        )

      [] ->
        effective_input =
          effective_input_frame(
            latched_input,
            movement_state,
            movement_profile,
            now_ms - last_input_received_at_ms,
            combat_state
          )

        cond do
          should_advance_movement?(movement_state, effective_input) ->
            step_and_broadcast(
              effective_input,
              %{state | movement_timer: movement_timer},
              cid,
              connection_pid,
              aoi_ref,
              cd_ref,
              physys_ref,
              movement_state,
              movement_profile,
              now_ms - last_input_received_at_ms
            )

          effective_input.seq > last_ack_seq ->
            authoritative_state = stamp_movement_state(movement_state, state)

            diagnostics =
              movement_tick_diagnostics(
                0,
                0,
                now_ms - last_input_received_at_ms,
                authoritative_state,
                0
              )

            ack =
              Engine.build_ack(
                cid,
                authoritative_state,
                effective_input.seq,
                movement_profile.fixed_dt_ms
              )
              |> enrich_ack_diagnostics(diagnostics)

            SceneServer.CliObserve.emit("player_movement_idle_ack", %{
              cid: cid,
              input_seq: effective_input.seq,
              input_tick: effective_input.client_tick,
              input_dir: effective_input.input_dir,
              input_age_ms: now_ms - last_input_received_at_ms,
              authoritative_tick: movement_state.tick,
              authoritative_position: movement_state.position,
              authoritative_velocity: movement_state.velocity,
              scene_ack_ms: ack.scene_ack_ms,
              scene_queue_len: ack.scene_queue_len,
              scene_replay_count: ack.scene_replay_count,
              scene_dropped_input_count: ack.scene_dropped_input_count,
              scene_mailbox_len: ack.scene_mailbox_len,
              scene_tick_drift_ms: ack.scene_tick_drift_ms
            })

            GenServer.cast(movement_ack_pid(state, connection_pid), {:movement_ack, ack})

            {:noreply,
             %{
               state
               | last_ack_seq: effective_input.seq,
                 movement_timer: movement_timer,
                 latched_input: effective_input,
                 movement_input_dropped_count: 0
             }}

          true ->
            flush_stop_snapshot_if_needed(
              aoi_ref,
              cd_ref,
              physys_ref,
              cid,
              movement_state,
              %{state | movement_timer: movement_timer}
            )
        end
    end
  end

  @impl true
  def handle_info(:respawn, %{combat_state: combat_state} = state) do
    if combat_state.alive do
      {:noreply, %{state | respawn_timer: nil}}
    else
      handle_respawn(state)
    end
  end

  defp step_and_broadcast(
         %InputFrame{} = effective_input,
         state,
         cid,
         connection_pid,
         aoi_ref,
         cd_ref,
         physys_ref,
         movement_state,
         movement_profile,
         input_age_ms
       ) do
    {next_state, _ack} = Engine.step(cid, movement_state, effective_input, movement_profile)

    {next_state, correction_flags, collision_summary} =
      resolve_voxel_collision(movement_state, next_state, state)

    finalize_and_broadcast(
      next_state,
      effective_input.seq,
      state,
      cid,
      connection_pid,
      aoi_ref,
      cd_ref,
      physys_ref,
      effective_input,
      input_age_ms,
      :single,
      1,
      1,
      movement_profile,
      correction_flags,
      collision_summary
    )
  end

  defp replay_queued_inputs(
         queued,
         state,
         cid,
         connection_pid,
         aoi_ref,
         cd_ref,
         physys_ref,
         movement_state,
         movement_profile,
         input_age_ms
       ) do
    renumbered = renumber_input_frames(queued, movement_state.tick, movement_profile.fixed_dt_ms)

    {next_state, correction_flags, collision_summaries} =
      replay_queued_inputs_with_collision(
        movement_state,
        renumbered,
        movement_profile,
        state,
        cid
      )

    last_frame = List.last(renumbered)

    finalize_and_broadcast(
      next_state,
      last_frame.seq,
      state,
      cid,
      connection_pid,
      aoi_ref,
      cd_ref,
      physys_ref,
      last_frame,
      input_age_ms,
      {:replayed, length(renumbered)},
      length(queued),
      length(renumbered),
      movement_profile,
      correction_flags,
      summarize_replay_collision(collision_summaries)
    )
  end

  defp finalize_and_broadcast(
         next_state,
         ack_seq,
         state,
         cid,
         connection_pid,
         aoi_ref,
         cd_ref,
         physys_ref,
         last_frame,
         input_age_ms,
         mode,
         queue_len,
         replay_count,
         movement_profile,
         correction_flags,
         collision_summary
       ) do
    with :ok <-
           update_character_movement_with_retry(
             cd_ref,
             next_state.position,
             next_state.velocity,
             next_state.acceleration,
             physys_ref
           ),
         {:ok, authoritative_location} <-
           get_character_location_with_retry(cd_ref, physys_ref, next_state.position) do
      authoritative_state =
        next_state
        |> Map.put(:position, authoritative_location)
        |> refresh_ground_z()
        |> stamp_movement_state(state)

      ack =
        Engine.build_ack_with_intent(
          cid,
          authoritative_state,
          last_frame,
          correction_flags,
          movement_profile.fixed_dt_ms
        )
        |> enrich_ack_diagnostics(
          movement_tick_diagnostics(
            queue_len,
            replay_count,
            input_age_ms,
            authoritative_state,
            Map.get(state, :movement_input_dropped_count, 0)
          )
        )

      snapshot = RemoteSnapshot.from_state(cid, authoritative_state)

      SceneServer.CliObserve.emit("player_movement_tick", %{
        cid: cid,
        mode: mode,
        input_seq: ack_seq,
        input_tick: last_frame.client_tick,
        input_dir: last_frame.input_dir,
        input_age_ms: input_age_ms,
        authoritative_tick: authoritative_state.tick,
        authoritative_position: authoritative_state.position,
        authoritative_velocity: authoritative_state.velocity,
        authoritative_acceleration: authoritative_state.acceleration,
        movement_mode: authoritative_state.movement_mode,
        correction_flags: ack.correction_flags,
        scene_ack_ms: ack.scene_ack_ms,
        scene_input_age_ms: ack.scene_input_age_ms,
        scene_queue_len: ack.scene_queue_len,
        scene_replay_count: ack.scene_replay_count,
        scene_dropped_input_count: ack.scene_dropped_input_count,
        scene_mailbox_len: ack.scene_mailbox_len,
        scene_tick_drift_ms: ack.scene_tick_drift_ms,
        collision_status: Map.get(collision_summary, :status),
        collision_blocked_axes: Map.get(collision_summary, :blocked_axes, []),
        collision_occupied_count: Map.get(collision_summary, :occupied_count, 0)
      })

      emit_collision_observe(cid, state.logical_scene_id, authoritative_state, collision_summary)

      GenServer.cast(aoi_ref, {:self_move, snapshot})
      GenServer.cast(movement_ack_pid(state, connection_pid), {:movement_ack, ack})

      last_snapshot_sent_at_ms = System.monotonic_time(:millisecond)

      {:noreply,
       %{
         state
         | movement_state: authoritative_state,
           last_location: authoritative_location,
           last_ack_seq: ack_seq,
           latched_input: clear_one_shot_flags(last_frame),
           movement_input_dropped_count: 0
       }
       |> Map.put(:last_remote_snapshot_sent_at_ms, last_snapshot_sent_at_ms)}
    else
      {:error, reason} ->
        SceneServer.CliObserve.emit("player_movement_error", %{
          cid: cid,
          mode: mode,
          reason: reason
        })

        {:noreply, state}
    end
  end

  defp movement_tick_diagnostics(
         queue_len,
         replay_count,
         input_age_ms,
         authoritative_state,
         dropped_input_count
       ) do
    scene_ack_ms = :os.system_time(:millisecond)

    %{
      scene_ack_ms: scene_ack_ms,
      scene_input_age_ms: non_negative_int(input_age_ms),
      scene_queue_len: non_negative_int(queue_len),
      scene_replay_count: non_negative_int(replay_count),
      scene_dropped_input_count: non_negative_int(dropped_input_count),
      scene_mailbox_len: movement_mailbox_len(),
      scene_tick_drift_ms:
        scene_ack_ms - Map.get(authoritative_state, :server_state_ms, scene_ack_ms)
    }
  end

  defp enrich_ack_diagnostics(%Ack{} = ack, diagnostics) when is_map(diagnostics) do
    struct(ack, diagnostics)
  end

  defp movement_mailbox_len do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} when is_integer(len) and len >= 0 -> len
      _ -> 0
    end
  end

  defp non_negative_int(value) when is_integer(value), do: max(value, 0)
  defp non_negative_int(value) when is_float(value), do: value |> round() |> max(0)
  defp non_negative_int(_value), do: 0

  defp movement_ack_pid_from_profile(%{} = character_profile, fallback_pid) do
    case Map.get(character_profile, :movement_ack_pid) ||
           Map.get(character_profile, "movement_ack_pid") do
      pid when is_pid(pid) -> pid
      _ -> fallback_pid
    end
  end

  defp movement_ack_pid_from_profile(_character_profile, fallback_pid), do: fallback_pid

  defp movement_ack_pid(%{movement_ack_pid: pid}, _connection_pid) when is_pid(pid), do: pid
  defp movement_ack_pid(_state, connection_pid), do: connection_pid

  defp replay_queued_inputs_with_collision(
         anchor_state,
         frames,
         movement_profile,
         player_state,
         cid
       ) do
    {resolved_state, flags, summaries} =
      Enum.reduce(frames, {anchor_state, CorrectionFlags.none(), []}, fn %InputFrame{} = frame,
                                                                         {current_state, flags,
                                                                          summaries} ->
        {proposed_state, _ack} = Engine.step(cid, current_state, frame, movement_profile)

        {resolved_state, step_flags, summary} =
          resolve_voxel_collision(current_state, proposed_state, player_state)

        {resolved_state, CorrectionFlags.combine([flags, step_flags]),
         [Map.put(summary, :replay_count, 1) | summaries]}
      end)

    {resolved_state, flags, Enum.reverse(summaries)}
  end

  defp resolve_voxel_collision(
         %State{position: position} = previous_state,
         %State{position: position} = proposed_state,
         state
       ) do
    {proposed_state, CorrectionFlags.none(),
     stationary_collision_summary(
       previous_state,
       proposed_state,
       Map.get(state, :logical_scene_id, 1)
     )}
  end

  defp resolve_voxel_collision(%State{} = previous_state, %State{} = proposed_state, state) do
    opts =
      state
      |> Map.get(:voxel_collision_opts, [])
      |> Keyword.put_new(:query_timeout_ms, @movement_collision_query_timeout_ms)
      |> Keyword.put(:logical_scene_id, Map.get(state, :logical_scene_id, 1))

    VoxelCollision.resolve(previous_state, proposed_state, opts)
  end

  defp stationary_collision_summary(previous_state, proposed_state, logical_scene_id) do
    %{
      enabled?: true,
      status: :skipped,
      reason: :stationary,
      logical_scene_id: logical_scene_id,
      tick: proposed_state.tick,
      previous_position: previous_state.position,
      proposed_position: proposed_state.position,
      resolved_position: proposed_state.position,
      queried_chunks: [],
      sample_count: 0,
      occupied_count: 0,
      blocked_axes: [],
      correction_flags: CorrectionFlags.none()
    }
  end

  defp summarize_replay_collision(summaries) do
    last_summary = List.last(summaries)

    blocked_axes =
      summaries
      |> Enum.flat_map(&Map.get(&1, :blocked_axes, []))
      |> Enum.uniq()

    status =
      cond do
        Enum.any?(summaries, &(Map.get(&1, :status) == :resolved)) -> :resolved
        Enum.any?(summaries, &(Map.get(&1, :status) == :unavailable)) -> :unavailable
        true -> Map.get(last_summary, :status, :clear)
      end

    replay_count =
      summaries
      |> Enum.map(&Map.get(&1, :replay_count, 1))
      |> Enum.sum()

    last_summary
    |> Map.put(:status, status)
    |> Map.put(:blocked_axes, blocked_axes)
    |> Map.put(:occupied_count, Enum.sum(Enum.map(summaries, &Map.get(&1, :occupied_count, 0))))
    |> Map.put(:sample_count, Enum.sum(Enum.map(summaries, &Map.get(&1, :sample_count, 0))))
    |> Map.put(
      :correction_flags,
      Enum.reduce(summaries, 0, fn summary, acc ->
        Bitwise.bor(acc, Map.get(summary, :correction_flags, 0))
      end)
    )
    |> Map.put(:replay_count, replay_count)
  end

  defp emit_collision_observe(_cid, _logical_scene_id, _state, %{status: :clear}), do: :ok
  defp emit_collision_observe(_cid, _logical_scene_id, _state, %{status: :skipped}), do: :ok

  defp emit_collision_observe(cid, logical_scene_id, authoritative_state, summary) do
    SceneServer.CliObserve.emit("player_movement_collision", %{
      cid: cid,
      logical_scene_id: logical_scene_id,
      authoritative_tick: authoritative_state.tick,
      authoritative_position: authoritative_state.position,
      status: Map.get(summary, :status),
      reason: Map.get(summary, :reason),
      previous_position: Map.get(summary, :previous_position),
      proposed_position: Map.get(summary, :proposed_position),
      resolved_position: Map.get(summary, :resolved_position),
      blocked_axes: Map.get(summary, :blocked_axes, []),
      queried_chunks: Map.get(summary, :queried_chunks, []),
      sample_count: Map.get(summary, :sample_count, 0),
      occupied_count: Map.get(summary, :occupied_count, 0),
      correction_flags: Map.get(summary, :correction_flags, 0),
      replay_count: Map.get(summary, :replay_count, 1)
    })
  end

  defp renumber_input_frames(frames, base_tick, fixed_dt_ms) do
    frames
    |> Enum.with_index(1)
    |> Enum.map(fn {%InputFrame{} = frame, idx} ->
      %InputFrame{frame | client_tick: base_tick + idx, dt_ms: fixed_dt_ms}
    end)
  end

  defp clear_one_shot_flags(%InputFrame{} = frame) do
    %InputFrame{
      frame
      | movement_flags: Bitwise.band(frame.movement_flags, Bitwise.bnot(InputFrame.jump_flag()))
    }
  end

  defp ensure_aoi_runtime(%{aoi_ref: aoi_ref} = state) when is_pid(aoi_ref) do
    if Process.alive?(aoi_ref) do
      {:ok, state}
    else
      recover_aoi_adapter(state, :dead_aoi_ref)
    end
  end

  defp ensure_aoi_runtime(state), do: recover_aoi_adapter(state, :missing_aoi_ref)

  defp recover_aoi_adapter(state, reason) do
    if is_reference(Map.get(state, :aoi_monitor_ref)) do
      Process.demonitor(state.aoi_monitor_ref, [:flush])
    end

    location = Map.get(state, :last_location) || state.movement_state.position

    SceneServer.CliObserve.emit("player_aoi_recover", %{
      cid: state.cid,
      reason: reason,
      location: location
    })

    case enter_scene(
           state.cid,
           :os.system_time(:millisecond),
           location,
           state.connection_pid,
           character_name(state)
         ) do
      {:ok, aoi_ref} ->
        monitor_ref = Process.monitor(aoi_ref)
        broadcast_current_aoi_state(aoi_ref, state)
        {:ok, %{state | aoi_ref: aoi_ref, aoi_monitor_ref: monitor_ref}}

      {:error, recover_reason} ->
        {:error, recover_reason}
    end
  end

  defp broadcast_current_aoi_state(aoi_ref, state) do
    replay_partition_window(aoi_ref, state)

    GenServer.cast(
      aoi_ref,
      {:player_state, state.cid, state.combat_state.hp, state.combat_state.max_hp,
       state.combat_state.alive}
    )

    GenServer.cast(
      aoi_ref,
      {:self_move, RemoteSnapshot.from_state(state.cid, state.movement_state)}
    )
  end

  defp replay_partition_window(aoi_ref, %{partition_window_dto: partition_window})
       when not is_nil(partition_window) do
    apply_partition_window_to_aoi(aoi_ref, partition_window)
  end

  defp replay_partition_window(_aoi_ref, _state), do: :ok

  defp apply_partition_window_to_aoi(aoi_ref, partition_window) when is_pid(aoi_ref) do
    AoiItem.update_partition_window(aoi_ref, partition_window)
  end

  defp apply_partition_window_to_aoi(_aoi_ref, _partition_window), do: :ok

  defp partition_window_summary(nil) do
    %{
      logical_scene_id: nil,
      center_chunk: nil,
      route_count: 0
    }
  end

  defp partition_window_summary(partition_window) when is_map(partition_window) do
    %{
      logical_scene_id: Map.get(partition_window, :logical_scene_id),
      center_chunk: Map.get(partition_window, :center_chunk),
      route_count: length(Map.get(partition_window, :route_entries, []))
    }
  end

  defp character_name(%{character_profile: %{name: name}}) when is_binary(name), do: name
  defp character_name(%{character_profile: %{"name" => name}}) when is_binary(name), do: name
  defp character_name(%{cid: cid}), do: "player-#{cid}"

  defp drain_buffered_movement_inputs(state) do
    entries = take_buffered_movement_inputs(self())
    initial_queue_len = length(Map.get(state, :input_queue, []))

    {next_state, accepted_count} =
      Enum.reduce(entries, {state, 0}, fn {%InputFrame{} = frame, received_at_ms},
                                          {next_state, accepted_count} ->
        case accept_movement_input_frame(frame, next_state, received_at_ms) do
          {:ok, accepted_state} ->
            {accepted_state, accepted_count + 1}

          {:error, reason, rejected_state} ->
            emit_movement_input_error(rejected_state, reason)
            {rejected_state, accepted_count}
        end
      end)

    final_queue_len = length(Map.get(next_state, :input_queue, []))
    dropped_count = max(initial_queue_len + accepted_count - final_queue_len, 0)

    Map.put(next_state, :movement_input_dropped_count, dropped_count)
  end

  defp take_buffered_movement_inputs(player_character) when is_pid(player_character) do
    entries = buffered_movement_input_entries(player_character)
    table = ensure_movement_input_buffer_table()

    Enum.each(entries, fn {seq, _frame, _received_at_ms} ->
      :ets.delete(table, {player_character, seq})
    end)

    Enum.map(entries, fn {_seq, frame, received_at_ms} -> {frame, received_at_ms} end)
  end

  defp take_buffered_movement_inputs(_player_character), do: []

  defp buffered_movement_input_entries(player_character) when is_pid(player_character) do
    table = ensure_movement_input_buffer_table()

    table
    |> :ets.select([{{{player_character, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.sort_by(fn {seq, _frame, _received_at_ms} -> seq end)
  end

  defp buffered_movement_input_entries(_player_character), do: []

  defp prune_buffered_movement_inputs(player_character) when is_pid(player_character) do
    entries = buffered_movement_input_entries(player_character)
    overflow_count = length(entries) - @max_buffered_movement_inputs

    if overflow_count > 0 do
      table = ensure_movement_input_buffer_table()

      entries
      |> Enum.take(overflow_count)
      |> Enum.each(fn {seq, _frame, _received_at_ms} ->
        :ets.delete(table, {player_character, seq})
      end)
    end
  end

  defp prune_buffered_movement_inputs(_player_character), do: :ok

  defp clear_movement_input_buffer(player_character) when is_pid(player_character) do
    player_character
    |> buffered_movement_input_entries()
    |> Enum.each(fn {seq, _frame, _received_at_ms} ->
      :ets.delete(@movement_input_buffer_table, {player_character, seq})
    end)
  end

  defp clear_movement_input_buffer(_player_character), do: :ok

  defp ensure_movement_input_buffer_table do
    case :ets.whereis(@movement_input_buffer_table) do
      :undefined ->
        :ets.new(@movement_input_buffer_table, [
          :named_table,
          :ordered_set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      table ->
        table
    end
  catch
    :error, :badarg -> @movement_input_buffer_table
  end

  defp accept_movement_input_frame(
         %InputFrame{} = frame,
         state
       ),
       do: accept_movement_input_frame(frame, state, System.monotonic_time(:millisecond))

  defp accept_movement_input_frame(
         %InputFrame{} = frame,
         %{
           combat_state: combat_state,
           movement_profile: movement_profile,
           latched_input: latched_input,
           input_queue: input_queue,
           last_input_seq: last_input_seq,
           last_client_tick: last_client_tick,
           last_input_received_at_ms: last_input_received_at_ms
         } = state,
         received_at_ms
       ) do
    with :ok <- ensure_alive(combat_state),
         {:ok, sanitized_frame, now_ms} <-
           sanitize_input_frame(
             frame,
             movement_profile,
             last_input_seq,
             last_client_tick,
             last_input_received_at_ms,
             received_at_ms
           ) do
      {:ok,
       %{
         state
         | latched_input: merge_latched_input(latched_input, sanitized_frame, movement_profile),
           input_queue: enqueue_input(input_queue, sanitized_frame),
           last_input_seq: sanitized_frame.seq,
           last_client_tick: sanitized_frame.client_tick,
           last_input_received_at_ms: now_ms
       }}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp emit_movement_input_error(%{cid: cid}, reason) do
    SceneServer.CliObserve.emit("player_movement_error", %{cid: cid, reason: reason})
  end

  defp enqueue_input(queue, %InputFrame{} = frame) do
    case queue ++ [frame] do
      list when length(list) > @max_input_queue ->
        Enum.take(list, -@max_input_queue)

      list ->
        list
    end
  end

  @impl true
  def terminate(reason, state) do
    %{
      aoi_ref: aoi_item,
      cid: cid,
      movement_timer: movement_timer,
      aoi_monitor_ref: aoi_monitor_ref,
      respawn_timer: respawn_timer
    } = state

    connection_monitor_ref = Map.get(state, :connection_monitor_ref)

    SceneServer.CliObserve.emit("player_terminate", %{cid: cid, reason: reason})

    if movement_timer != nil do
      Process.cancel_timer(movement_timer)
    end

    clear_movement_input_buffer(self())

    if respawn_timer != nil do
      Process.cancel_timer(respawn_timer)
    end

    if is_reference(connection_monitor_ref) do
      Process.demonitor(connection_monitor_ref, [:flush])
    end

    if is_reference(aoi_monitor_ref) do
      Process.demonitor(aoi_monitor_ref, [:flush])
    end

    if is_pid(aoi_item) and Process.alive?(aoi_item) do
      {:ok, _} = GenServer.call(aoi_item, :exit)
      Logger.debug("AOI item removed.")
    end

    if Process.whereis(SceneServer.PlayerManager) do
      GenServer.cast(SceneServer.PlayerManager, {:remove_player_index, cid, self()})
      Logger.debug("Player index removed.")
    end

    Logger.warning(
      "PlayerCharacter process #{inspect(self(), pretty: true)} exited successfully. Reason: #{inspect(reason, pretty: true)}",
      ansi_color: :green
    )
  end

  defp enter_scene(cid, client_timestamp, location, connection_pid, character_name) do
    case AoiManager.add_aoi_item(
           cid,
           client_timestamp,
           location,
           connection_pid,
           self(),
           %{kind: :player, name: character_name}
         ) do
      {:ok, aoi_ref} ->
        Logger.debug("Character added to Coordinate System: #{inspect(aoi_ref, pretty: true)}")
        {:ok, aoi_ref}

      {:err, reason} ->
        {:error, reason}
    end
  end

  defp make_movement_timer(fixed_dt_ms) do
    Process.send_after(self(), :movement_tick, fixed_dt_ms)
  end

  defp idle_input_frame(fixed_dt_ms) do
    %InputFrame{
      seq: 0,
      client_tick: 0,
      dt_ms: fixed_dt_ms,
      input_dir: {0.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0b10
    }
  end

  defp merge_latched_input(_previous, %InputFrame{} = frame, %Profile{} = profile) do
    %InputFrame{frame | dt_ms: profile.fixed_dt_ms}
  end

  defp effective_input_frame(
         %InputFrame{} = latched_input,
         %State{} = movement_state,
         %Profile{} = profile,
         input_age_ms,
         %CombatState{} = combat_state
       ) do
    timeout_ms = profile.fixed_dt_ms * @input_hold_timeout_multiplier
    next_tick = movement_state.tick + 1

    base_input =
      cond do
        not combat_state.alive ->
          %InputFrame{
            latched_input
            | input_dir: {0.0, 0.0},
              speed_scale: 1.0,
              movement_flags: 0b10
          }

        input_age_ms > timeout_ms ->
          %InputFrame{
            latched_input
            | input_dir: {0.0, 0.0},
              speed_scale: 1.0,
              movement_flags: 0b10
          }

        true ->
          latched_input
      end

    %InputFrame{base_input | client_tick: next_tick, dt_ms: profile.fixed_dt_ms}
  end

  defp should_advance_movement?(%State{} = movement_state, %InputFrame{} = frame) do
    movement_active?(movement_state) or input_active?(frame)
  end

  defp flush_stop_snapshot_if_needed(
         aoi_ref,
         cd_ref,
         physys_ref,
         cid,
         %State{velocity: {vx, vy, vz}, acceleration: {ax, ay, az}} = movement_state,
         state
       )
       when vx != 0.0 or vy != 0.0 or vz != 0.0 or ax != 0.0 or ay != 0.0 or az != 0.0 do
    zeroed_state =
      %State{
        movement_state
        | velocity: {0.0, 0.0, 0.0},
          acceleration: {0.0, 0.0, 0.0},
          ground_z: elem(movement_state.position, 2)
      }
      |> stamp_movement_state(state)

    _ =
      update_character_movement_with_retry(
        cd_ref,
        zeroed_state.position,
        zeroed_state.velocity,
        zeroed_state.acceleration,
        physys_ref
      )

    snapshot = RemoteSnapshot.from_state(cid, zeroed_state)
    GenServer.cast(aoi_ref, {:self_move, snapshot})

    {:noreply,
     state
     |> Map.put(:movement_state, zeroed_state)
     |> Map.put(:last_location, zeroed_state.position)
     |> Map.put(:last_remote_snapshot_sent_at_ms, System.monotonic_time(:millisecond))}
  end

  defp flush_stop_snapshot_if_needed(aoi_ref, _cd_ref, _physys_ref, cid, movement_state, state) do
    maybe_broadcast_idle_snapshot(aoi_ref, cid, movement_state, state)
  end

  defp maybe_broadcast_idle_snapshot(aoi_ref, cid, %State{} = movement_state, state) do
    now_ms = System.monotonic_time(:millisecond)
    last_sent_at_ms = Map.get(state, :last_remote_snapshot_sent_at_ms, 0)

    if idle_remote_snapshot_due?(last_sent_at_ms, now_ms) do
      heartbeat_state =
        movement_state
        |> advance_idle_movement_time(state)
        |> refresh_ground_z()

      snapshot = RemoteSnapshot.from_state(cid, heartbeat_state)

      SceneServer.CliObserve.emit("player_movement_idle_snapshot", %{
        cid: cid,
        server_tick: heartbeat_state.tick,
        server_state_ms: heartbeat_state.server_state_ms,
        position: heartbeat_state.position,
        movement_mode: heartbeat_state.movement_mode
      })

      GenServer.cast(aoi_ref, {:self_move, snapshot})

      {:noreply,
       state
       |> Map.put(:movement_state, heartbeat_state)
       |> Map.put(:last_location, heartbeat_state.position)
       |> Map.put(:last_remote_snapshot_sent_at_ms, now_ms)}
    else
      {:noreply, state}
    end
  end

  defp idle_remote_snapshot_due?(last_sent_at_ms, _now_ms) when not is_integer(last_sent_at_ms),
    do: true

  defp idle_remote_snapshot_due?(last_sent_at_ms, now_ms) do
    now_ms - last_sent_at_ms >= @idle_remote_snapshot_interval_ms
  end

  defp advance_idle_movement_time(
         %State{} = movement_state,
         %{movement_profile: %{fixed_dt_ms: fixed_dt_ms}} = actor_state
       )
       when is_integer(fixed_dt_ms) and fixed_dt_ms > 0 do
    epoch_ms = movement_epoch_ms(movement_state, actor_state, fixed_dt_ms)
    elapsed_ticks = max(0, div(max(0, :os.system_time(:millisecond) - epoch_ms), fixed_dt_ms))
    next_tick = max(movement_state.tick + 1, elapsed_ticks)

    movement_state
    |> Map.put(:tick, next_tick)
    |> stamp_movement_state(epoch_ms, fixed_dt_ms)
  end

  defp movement_active?(%State{velocity: velocity}) do
    vector_magnitude(velocity) > @stopped_speed_epsilon
  end

  defp input_active?(%InputFrame{input_dir: {x, y}} = frame) do
    abs(x) > 1.0e-6 or abs(y) > 1.0e-6 or InputFrame.jumping?(frame)
  end

  defp vector_magnitude({x, y, z}) do
    :math.sqrt(x * x + y * y + z * z)
  end

  defp ensure_alive(%CombatState{alive: true}), do: :ok
  defp ensure_alive(%CombatState{}), do: {:error, :dead}

  defp cooldown_ready?(skill_casts, %Skill{id: skill_id, cooldown_ms: cooldown_ms}, now) do
    case Map.get(skill_casts, skill_id) do
      nil -> :ok
      last_cast when now - last_cast >= cooldown_ms -> :ok
      _last_cast -> {:error, :skill_cooldown}
    end
  end

  defp schedule_skill_resolution(%{travel_ms: 0} = cast) do
    send(self(), {:resolve_skill_cast, cast})
  end

  defp schedule_skill_resolution(%{travel_ms: travel_ms} = cast) when travel_ms > 0 do
    Process.send_after(self(), {:resolve_skill_cast, cast}, travel_ms)
  end

  # Phase A1-5:把 cast.target_position(cm)转 world micro index 并调
  # VoxelDamageRouter。:cascade / :applied / :no_voxel / :error 全部 emit
  # observe(让 CLI 调试可见命中链路),但**不**短路 actor damage 路径
  # (那条已经在 resolve_cast → broadcast_effect_events 走完)。
  defp try_voxel_damage(scene_id, %{target_position: target_position, skill: skill}) do
    damage = primary_damage_from_skill(skill)

    cond do
      damage <= 0 ->
        :ok

      not is_tuple(target_position) ->
        :ok

      true ->
        world_micro = world_cm_to_micro(target_position)

        outcome = VoxelDamageRouter.try_apply_damage(scene_id, world_micro, damage)

        SceneServer.CliObserve.emit("voxel_skill_damage_attempt", fn ->
          %{
            logical_scene_id: scene_id,
            skill_id: skill.id,
            target_position: inspect(target_position),
            world_micro: inspect(world_micro),
            damage: damage,
            outcome: inspect(outcome, limit: 4)
          }
        end)

        :ok
    end
  end

  defp world_cm_to_micro({wx, wy, wz}) do
    {floor_to_int(wx * 8.0 / 100.0), floor_to_int(wy * 8.0 / 100.0),
     floor_to_int(wz * 8.0 / 100.0)}
  end

  defp floor_to_int(value) when is_float(value), do: :erlang.floor(value)
  defp floor_to_int(value) when is_integer(value), do: value

  # Picks the first effect's damage as the canonical "skill damage" for voxel
  # path。Multi-effect skills(circle / chain)在 actor 路径仍按 effects 列表
  # 走;voxel 路径只取首个 effect 的 damage 让 demo 形为可控。
  defp primary_damage_from_skill(%Skill{effects: [%{damage: damage} | _]}) when damage > 0,
    do: damage

  defp primary_damage_from_skill(_skill), do: 0

  defp broadcast_effect_events(aoi_ref, effect_events) when is_list(effect_events) do
    Enum.each(effect_events, fn effect_event ->
      GenServer.cast(aoi_ref, {:effect_event, effect_event})
    end)
  end

  defp reset_movement_after_death(cd_ref, physys_ref, movement_profile, movement_state, state) do
    zero_state = %{
      movement_state
      | velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0},
        movement_mode: :grounded,
        ground_z: elem(movement_state.position, 2)
    }

    :ok =
      update_character_movement_with_retry(
        cd_ref,
        zero_state.position,
        zero_state.velocity,
        zero_state.acceleration,
        physys_ref
      )

    timer = Process.send_after(self(), :respawn, state.combat_profile.respawn_ms)

    {state
     |> Map.put(:movement_state, zero_state)
     |> Map.put(:latched_input, idle_input_frame(movement_profile.fixed_dt_ms)), timer}
  end

  defp handle_respawn(
         %{
           cid: cid,
           aoi_ref: aoi_ref,
           spawn_location: spawn_location,
           movement_profile: movement_profile,
           movement_state: movement_state,
           combat_state: combat_state,
           character_data_ref: cd_ref,
           physys_ref: physys_ref
         } = state
       ) do
    respawned_combat_state = CombatState.respawn(combat_state)

    respawned_movement_state =
      %{
        movement_state
        | position: spawn_location,
          velocity: {0.0, 0.0, 0.0},
          acceleration: {0.0, 0.0, 0.0},
          movement_mode: :grounded,
          ground_z: elem(spawn_location, 2)
      }
      |> stamp_movement_state(state)

    :ok =
      update_character_movement_with_retry(
        cd_ref,
        spawn_location,
        respawned_movement_state.velocity,
        respawned_movement_state.acceleration,
        physys_ref
      )

    snapshot = RemoteSnapshot.from_state(cid, respawned_movement_state)
    GenServer.cast(aoi_ref, {:self_move, snapshot})
    last_snapshot_sent_at_ms = System.monotonic_time(:millisecond)

    GenServer.cast(
      aoi_ref,
      {:health_update, cid, respawned_combat_state.hp, respawned_combat_state.max_hp,
       respawned_combat_state.alive}
    )

    next_state =
      %{
        state
        | combat_state: respawned_combat_state,
          movement_state: respawned_movement_state,
          latched_input: idle_input_frame(movement_profile.fixed_dt_ms),
          last_location: spawn_location,
          skill_casts: %{},
          respawn_timer: nil
      }
      |> Map.put(:last_remote_snapshot_sent_at_ms, last_snapshot_sent_at_ms)

    {:noreply, next_state}
  end

  defp stamp_movement_state(
         %State{} = movement_state,
         %{movement_epoch_ms: epoch_ms, movement_profile: %{fixed_dt_ms: fixed_dt_ms}}
       ) do
    stamp_movement_state(movement_state, epoch_ms, fixed_dt_ms)
  end

  defp stamp_movement_state(
         %State{} = movement_state,
         %{movement_profile: %{fixed_dt_ms: fixed_dt_ms}} = actor_state
       ) do
    epoch_ms = movement_epoch_ms(movement_state, actor_state, fixed_dt_ms)

    stamp_movement_state(movement_state, epoch_ms, fixed_dt_ms)
  end

  defp movement_epoch_ms(%State{} = movement_state, actor_state, fixed_dt_ms) do
    previous_state_ms = Map.get(movement_state, :server_state_ms, 0)

    cond do
      is_integer(previous_state_ms) and previous_state_ms > 0 ->
        previous_state_ms - movement_state.tick * fixed_dt_ms

      match?(%State{}, Map.get(actor_state, :movement_state)) and
        is_integer(Map.get(actor_state.movement_state, :server_state_ms, 0)) and
          Map.get(actor_state.movement_state, :server_state_ms, 0) > 0 ->
        actor_state.movement_state.server_state_ms -
          actor_state.movement_state.tick * fixed_dt_ms

      true ->
        :os.system_time(:millisecond) - movement_state.tick * fixed_dt_ms
    end
  end

  defp stamp_movement_state(%State{} = movement_state, epoch_ms, fixed_dt_ms)
       when is_integer(epoch_ms) and is_integer(fixed_dt_ms) and fixed_dt_ms > 0 do
    Map.put(movement_state, :server_state_ms, epoch_ms + movement_state.tick * fixed_dt_ms)
  end

  defp refresh_ground_z(%State{movement_mode: :grounded, position: position} = movement_state) do
    %{movement_state | ground_z: elem(position, 2)}
  end

  defp refresh_ground_z(%State{} = movement_state), do: movement_state

  defp normalize_character_profile(cid, %{} = profile) do
    %{
      cid: cid,
      name:
        Map.get(profile, :name) || Map.get(profile, "name") ||
          "character-#{cid}",
      position: normalize_position(Map.get(profile, :position) || Map.get(profile, "position"))
    }
  end

  defp normalize_character_profile(cid, _profile) do
    %{cid: cid, name: "character-#{cid}", position: @default_location}
  end

  defp normalize_position({x, y, z})
       when (is_integer(x) or is_float(x)) and (is_integer(y) or is_float(y)) and
              (is_integer(z) or is_float(z)) do
    {x * 1.0, y * 1.0, z * 1.0}
    |> maybe_migrate_legacy_dev_seed_location()
  end

  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], elem(@default_location, 0))
    y = map_float(position, ["y", :y], elem(@default_location, 1))
    z = map_float(position, ["z", :z], elem(@default_location, 2))

    {x, y, z}
    |> maybe_migrate_legacy_dev_seed_location()
  end

  defp normalize_position(_position), do: @default_location

  defp maybe_migrate_legacy_dev_seed_location(@legacy_dev_seed_center_location) do
    SceneServer.CliObserve.emit("player_spawn_position_migrated", %{
      from: inspect(@legacy_dev_seed_center_location),
      to: inspect(@default_location),
      reason: :center_anchor_height
    })

    @default_location
  end

  defp maybe_migrate_legacy_dev_seed_location(position), do: position

  defp map_float(map, keys, default) do
    keys
    |> Enum.find_value(fn key -> Map.get(map, key) end)
    |> case do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp sanitize_input_frame(
         %InputFrame{} = frame,
         %Profile{} = profile,
         last_input_seq,
         last_client_tick,
         _last_input_received_at_ms,
         received_at_ms
       ) do
    cond do
      frame.seq <= last_input_seq ->
        {:error, :stale_input_seq}

      frame.client_tick <= last_client_tick ->
        {:error, :stale_client_tick}

      frame.seq > last_input_seq + @max_forward_input_seq_gap ->
        {:error, :input_seq_too_far}

      true ->
        now_ms = movement_input_received_at_ms(received_at_ms)

        sanitized_frame = %InputFrame{
          frame
          | dt_ms: profile.fixed_dt_ms,
            speed_scale: clamp_speed_scale(frame.speed_scale, profile.max_speed_scale)
        }

        {:ok, sanitized_frame, now_ms}
    end
  end

  defp movement_input_received_at_ms(received_at_ms)
       when is_integer(received_at_ms) and received_at_ms > 0,
       do: received_at_ms

  defp movement_input_received_at_ms(_received_at_ms), do: System.monotonic_time(:millisecond)

  defp clamp_speed_scale(scale, _max_scale) when scale < 0.0, do: 0.0
  defp clamp_speed_scale(scale, max_scale) when scale > max_scale, do: max_scale
  defp clamp_speed_scale(scale, _max_scale), do: scale

  defp new_character_data_with_retry(
         cid,
         name,
         location,
         dev_attrs,
         physys_ref,
         attempts \\ @lock_retry_attempts
       )

  defp new_character_data_with_retry(
         _cid,
         _name,
         _location,
         _dev_attrs,
         _physys_ref,
         0
       ),
       do: {:error, :lock_fail}

  defp new_character_data_with_retry(cid, name, location, dev_attrs, physys_ref, attempts) do
    case new_character_data_once(cid, name, location, dev_attrs, physys_ref) do
      {:ok, cd_ref} ->
        {:ok, cd_ref}

      {:error, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        new_character_data_with_retry(cid, name, location, dev_attrs, physys_ref, attempts - 1)

      {:err, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        new_character_data_with_retry(cid, name, location, dev_attrs, physys_ref, attempts - 1)

      {:error, :native_badarg} ->
        SceneServer.CliObserve.emit("player_native_physics_reset", %{cid: cid, reason: :badarg})

        with {:ok, refreshed_physys_ref} <- reset_physics_system_ref() do
          new_character_data_with_retry(
            cid,
            name,
            location,
            dev_attrs,
            refreshed_physys_ref,
            attempts - 1
          )
        end

      {:error, reason} ->
        {:error, reason}

      {:err, reason} ->
        {:error, reason}
    end
  end

  defp new_character_data_once(cid, name, location, dev_attrs, physys_ref) do
    try do
      SceneServer.Native.SceneOps.new_character_data(
        cid,
        name,
        location,
        dev_attrs,
        physys_ref
      )
    catch
      :error, :badarg -> {:error, :native_badarg}
    end
  end

  defp reset_physics_system_ref do
    if Process.whereis(SceneServer.PhysicsManager) do
      SceneServer.PhysicsManager.reset_physics_system_ref()
    else
      SceneServer.Native.SceneOps.new_physics_system()
    end
  end

  defp get_character_location_with_retry(
         cd_ref,
         physys_ref,
         fallback_location,
         attempts \\ @lock_retry_attempts
       )

  defp get_character_location_with_retry(_cd_ref, _physys_ref, fallback_location, 0) do
    Logger.debug("location fetch exhausted retries, using cached location")
    {:ok, fallback_location}
  end

  defp get_character_location_with_retry(cd_ref, physys_ref, fallback_location, attempts) do
    case SceneServer.Native.SceneOps.get_character_location(cd_ref, physys_ref) do
      {:ok, location} ->
        {:ok, location}

      {:error, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        get_character_location_with_retry(cd_ref, physys_ref, fallback_location, attempts - 1)

      {:err, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)
        get_character_location_with_retry(cd_ref, physys_ref, fallback_location, attempts - 1)

      {:error, reason} ->
        {:error, reason}

      {:err, reason} ->
        {:error, reason}
    end
  end

  defp update_character_movement_with_retry(
         cd_ref,
         location,
         velocity,
         acceleration,
         physys_ref,
         attempts \\ @lock_retry_attempts
       )

  defp update_character_movement_with_retry(
         _cd_ref,
         _location,
         _velocity,
         _acceleration,
         _physys_ref,
         0
       ),
       do: {:error, :lock_fail}

  defp update_character_movement_with_retry(
         cd_ref,
         location,
         velocity,
         acceleration,
         physys_ref,
         attempts
       ) do
    case SceneServer.Native.SceneOps.update_character_movement(
           cd_ref,
           location,
           velocity,
           acceleration,
           physys_ref
         ) do
      {:ok, _} ->
        :ok

      {:error, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)

        update_character_movement_with_retry(
          cd_ref,
          location,
          velocity,
          acceleration,
          physys_ref,
          attempts - 1
        )

      {:err, :lock_fail} ->
        Process.sleep(@lock_retry_sleep_ms)

        update_character_movement_with_retry(
          cd_ref,
          location,
          velocity,
          acceleration,
          physys_ref,
          attempts - 1
        )

      {:error, reason} ->
        {:error, reason}

      {:err, reason} ->
        {:error, reason}
    end
  end
end
