defmodule SceneServer.Movement.Scene do
  @moduledoc "M1 单 Scene 60Hz writer；固定源、出生、连续 ACK 与碰撞时间线。"
  use GenServer
  require Logger
  alias MmoContracts.{Session, Movement, Voxel}
  alias SceneServer.Movement.{InputSlots, CollisionUpdates, AOI}

  defmodule Clock do
    @moduledoc false
    def now(_), do: System.monotonic_time(:microsecond)
    def schedule(_, pid, delay), do: Process.send_after(pid, :tick, delay)
  end

  @doc "从明确的 route 和资产导出启动唯一 writer。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  @doc "入队；输出经 Gate sink 异步发送。角色已由 Gate 完成归属鉴权。"
  def join(scene, identity, authorized_character, gate_pid),
    do: GenServer.call(scene, {:join, identity, authorized_character, gate_pid})

  @doc "只确认本 identity 的初始 N/R，不追最新编辑。"
  def ready(scene, identity, seq, revision),
    do: GenServer.cast(scene, {:ready, identity, seq, revision})

  @doc "接收已解码 C1 batch，绝不因消息数量推进时间。"
  def input(scene, identity, batch), do: GenServer.cast(scene, {:input, identity, batch})
  @doc "结束此 identity；旧 epoch 不影响重连。"
  def leave(scene, identity, reason \\ 1), do: GenServer.cast(scene, {:leave, identity, reason})
  @doc "Scene 单调时间映射与步后 tick；回复经同一控制流。"
  def time_probe(scene, identity, probe),
    do: GenServer.cast(scene, {:time_probe, identity, probe})

  @doc "只读标量统计与角色状态，不暴露可变 NIF resource。"
  def observe(scene), do: GenServer.call(scene, :observe)

  @doc "读取 D1 的显式 JSON 导出；无生产默认 profile 或范围。"
  def load_config!(path), do: path |> File.read!() |> Jason.decode!() |> config!()

  defp config!(%{"schema" => "voxim-m1-demo-v1"} = raw) do
    # 冷启动先加载字段 owner；JSON key 只转换为该模块已有 atom。
    Code.ensure_loaded!(Session.Profile)
    profile =
      struct!(
        Session.Profile,
        Map.new(raw["profile"], fn {key, value} ->
          {String.to_existing_atom(key), if(key == "fixed_hz", do: value, else: value / 1)}
        end)
      )

    <<bytes::binary-size(120), 60::16>> = Session.Codec.encode_profile(profile)
    profile_tuple = for(<<value::float-64 <- bytes>>, do: value) |> List.to_tuple()

    l0 =
      {List.to_tuple(Map.fetch!(raw, "l0_min")),
       List.to_tuple(Map.fetch!(raw, "l0_max_exclusive"))}

    {lo, hi} = l0
    true = Enum.all?(0..2, &(is_integer(elem(lo, &1)) and elem(hi, &1) - elem(lo, &1) == 2))
    extent = Voxel.Payload.extent() - 2
    bounds = {map_tuple(lo, &(&1 * extent / 1)), map_tuple(hi, &(&1 * extent / 1))}

    travel =
      {float_tuple(Map.fetch!(raw, "travel_min_m")),
       float_tuple(Map.fetch!(raw, "travel_max_exclusive_m"))}

    true =
      Enum.all?(0..2, fn axis ->
        elem(elem(bounds, 0), axis) < elem(elem(travel, 0), axis) and
          elem(elem(travel, 0), axis) < elem(elem(travel, 1), axis) and
          elem(elem(travel, 1), axis) < elem(elem(bounds, 1), axis)
      end)

    probes = Enum.map(Map.fetch!(raw, "spawn_probes_m"), &float_tuple/1)
    true = length(probes) == 2 and Enum.all?(probes, &inside?(&1, travel))
    min_y = Map.fetch!(raw, "spawn_min_y_m") / 1
    true = min_y >= elem(elem(travel, 0), 1) and Enum.all?(probes, &(min_y < elem(&1, 1)))

    %{
      profile: profile,
      profile_tuple: profile_tuple,
      l0: l0,
      bounds: bounds,
      travel: travel,
      probes: probes,
      spawn_min_y: min_y
    }
  end

  @impl true
  def init(opts) do
    config =
      case Keyword.fetch(opts, :config) do
        {:ok, fixture} -> config!(fixture)
        :error -> load_config!(Keyword.fetch!(opts, :config_path))
      end

    clock = Keyword.get(opts, :clock, {Clock, nil})
    {clock_module, clock_ref} = clock
    monotonic = clock_module.now(clock_ref)
    initial_ref = make_ref()

    state = %{
      scene_id: Keyword.fetch!(opts, :scene_id),
      scene_epoch: Keyword.fetch!(opts, :scene_epoch),
      world_ref: Keyword.fetch!(opts, :world_ref),
      world_api: Keyword.get(opts, :world_api, VoxelRegion.World),
      sink: Keyword.get(opts, :sink, GateServer.Session.Sink),
      clock: clock,
      config: config,
      updates: CollisionUpdates.new(Keyword.get(opts, :native, SceneServer.Native.VoximMovement)),
      initial_ref: initial_ref,
      initialized: false,
      failure: nil,
      content_version: nil,
      characters: %{},
      aoi: AOI.new(),
      requests: %{},
      workers: %{},
      next_entity_epoch: 1,
      tick: 0,
      mono_origin: monotonic,
      time_mono_origin: monotonic,
      time_origin: System.system_time(:microsecond),
      world_monitor: Process.monitor(Keyword.fetch!(opts, :world_ref)),
      physics_steps: 0,
      step_us: 0,
      tick_us: 0,
      max_tick_us: 0,
      overdue_ticks: 0,
      mailbox_peak: 0,
      old_identity: 0,
      rejected_inputs: 0,
      substitutions: 0
    }

    {:ok, request_snapshot(state, initial_ref)}
  end

  @impl true
  def code_change(_old, %{characters: characters} = state, {:input_contract, snapshot})
      when map_size(characters) == 0 do
    # 本次无客户端的在线升级保留 Scene、世界时钟、N/R 和既有 native world。
    # snapshot 来自 World 的公开 canonical 接口，只补齐旧版本尚未持有的派生历史。
    true = snapshot.transaction_seq == state.updates.transaction_seq
    chunks = Map.new(snapshot.chunks, &{&1.coord, &1})
    updates = struct(CollisionUpdates, Map.from_struct(state.updates))
    {:ok, %{state | updates: %{updates |
      revisions: [{state.tick, updates.revision, chunks}],
      native_revision: updates.revision, native_chunks: chunks}}}
  end

  @impl true
  def handle_call({:join, identity, %{id: cid}, gate}, _, state) do
    cond do
      identity.scene_id != state.scene_id or identity.scene_epoch != state.scene_epoch ->
        close_sink(state, gate, identity, 11)
        {:reply, :ok, state}

      state.failure != nil ->
        close_sink(state, gate, identity, state.failure)
        {:reply, :ok, state}

      Map.has_key?(state.characters, identity) ->
        {:reply, :ok, state}

      Enum.any?(state.characters, fn {_, c} -> c.id == cid end) ->
        close_sink(state, gate, identity, 2)
        {:reply, :ok, state}

      map_size(state.characters) == length(state.config.probes) ->
        close_sink(state, gate, identity, 10)
        {:reply, :ok, state}

      true ->
        occupied = Enum.map(state.characters, fn {_, c} -> c.slot end)
        slot = Enum.find(0..(length(state.config.probes) - 1), &(&1 not in occupied))
        request = make_ref()

        character = %{
          id: cid,
          identity: identity,
          epoch: state.next_entity_epoch,
          slot: slot,
          gate: gate,
          monitor: Process.monitor(gate),
          state: nil,
          baseline: nil,
          ready: false,
          clock_ready: false,
          slots: nil,
          origin: nil,
          simulation_tick: 0,
          simulation_revision: 0
        }

        state = %{
          state
          | characters: Map.put(state.characters, identity, character),
            requests: Map.put(state.requests, request, identity),
            next_entity_epoch: state.next_entity_epoch + 1
        }

        {:reply, :ok, if(state.initialized, do: request_snapshot(state, request), else: state)}
    end
  end

  def handle_call(:observe, _, state) do
    {:message_queue_len, mailbox} = Process.info(self(), :message_queue_len)

    info =
      Map.take(state, [
        :initialized,
        :failure,
        :tick,
        :physics_steps,
        :step_us,
        :tick_us,
        :max_tick_us,
        :overdue_ticks,
        :mailbox_peak,
        :old_identity,
        :rejected_inputs,
        :substitutions
      ])

    info =
      Map.merge(info, %{
        character_count: map_size(state.characters),
        aoi: AOI.observe(state.aoi),
        mailbox: mailbox,
        queue_length: :queue.len(state.updates.queue),
        collision_revision: state.updates.revision,
        transaction_seq: state.updates.transaction_seq,
        build_us: state.updates.build_us,
        queue_wait_us: state.updates.queue_wait_us,
        characters:
          Enum.map(state.characters, fn {identity, c} ->
            %{
              identity: identity,
              entity_id: c.id,
              entity_epoch: c.epoch,
              state: c.state,
              origin_tick: c.origin,
              simulation_tick: c.simulation_tick,
              pending_inputs: if(c.slots, do: map_size(c.slots.pending), else: 0),
              active: active?(state, c),
              processed_input_seq: if(c.slots, do: c.slots.processed_input_seq, else: 0)
            }
          end)
          |> Enum.sort_by(& &1.entity_id)
      })

    {:reply, info, state}
  end

  @impl true
  def handle_cast({:leave, identity, reason}, state),
    do: {:noreply, drop(state, identity, reason)}

  def handle_cast({:ready, identity, seq, revision}, state) do
    case Map.fetch(state.characters, identity) do
      :error ->
        {:noreply, stale(state)}

      {:ok, %{baseline: {^seq, ^revision}} = c} ->
        {:noreply, put_character(state, %{c | ready: true})}

      {:ok, _} ->
        {:noreply, drop(state, identity, 8)}
    end
  end

  def handle_cast({:time_probe, identity, %Session.TimeProbe{} = probe}, state) do
    case Map.fetch(state.characters, identity) do
      :error ->
        {:noreply, stale(state)}

      {:ok, c} ->
        received = server_time(state)

        reliable(state, c, :control, %Session.TimeReply{
          request_id: probe.request_id,
          client_send_us: probe.client_send_us,
          server_receive_us: received,
          server_send_us: server_time(state),
          server_tick: state.tick
        })

        {:noreply, put_character(state, %{c | clock_ready: true})}
    end
  end

  def handle_cast({:input, identity, %Movement.InputBatch{identity: identity} = batch}, state) do
    arrived = now(state)

    case Map.fetch(state.characters, identity) do
      :error ->
        input_arrivals(state, identity, nil, batch.frames, :unknown_identity, arrived)
        {:noreply, stale(state)}

      {:ok, %{slots: nil} = c} ->
        input_arrivals(state, identity, c, batch.frames, :not_started, arrived)
        {:noreply, %{state | rejected_inputs: state.rejected_inputs + 1}}

      {:ok, c} ->
        {slots, result, decisions} = InputSlots.receive_batch_observed(c.slots, batch)

        for {frame, disposition} <- decisions do
          input_arrivals(state, identity, c, [frame], disposition, arrived)
        end

        state = put_character(state, %{c | slots: slots})

        {:noreply,
         if(result == :accepted,
           do: state,
           else: %{state | rejected_inputs: state.rejected_inputs + 1}
         )}
    end
  end

  def handle_cast({:input, _, _}, state), do: {:noreply, stale(state)}

  @impl true
  def handle_info({:canonical_snapshot, _, _}, %{failure: reason} = state) when reason != nil,
    do: {:noreply, state}

  def handle_info({:canonical_delta, _}, %{failure: reason} = state) when reason != nil,
    do: {:noreply, state}

  def handle_info(
        {:canonical_snapshot, ref, snapshot},
        %{initial_ref: ref, initialized: false} = state
      ) do
    received = now(state)
    updates = CollisionUpdates.initialize(state.updates, snapshot)

    state = %{
      state
      | updates: updates,
        initialized: true,
        content_version: snapshot.content_version,
        mono_origin: now(state)
    }

    state = Enum.reduce(Map.keys(state.requests), state, &request_snapshot(&2, &1))

    {native_colliders, native_compounds, native_compound_children} =
      updates.native.world_stats(updates.world)

    runtime_event(state, :bootstrap_resident, %{
      native_colliders: native_colliders,
      native_compounds: native_compounds,
      native_compound_children: native_compound_children,
      content_version: state.content_version,
      prepare_start_us: state.time_mono_origin,
      snapshot_received_us: received,
      installed_us: state.mono_origin,
      build_us: updates.build_us,
      region_count: length(snapshot.regions),
      core_count: length(snapshot.chunks),
      region_payload_bytes:
        Enum.reduce(snapshot.regions, 0, fn {_, bytes}, sum -> sum + byte_size(bytes) end),
      occupancy_bytes: Enum.reduce(snapshot.chunks, 0, fn c, sum -> sum + byte_size(c.cells) end)
    })

    schedule(state)
    {:noreply, state}
  end

  def handle_info({:canonical_snapshot, ref, snapshot}, state) do
    {:noreply,
     %{
       state
       | updates: CollisionUpdates.enqueue(state.updates, {:marker, ref, snapshot}, now(state))
     }}
  end

  def handle_info({:canonical_delta, %Voxel.CanonicalDelta{} = delta}, state) do
    {:noreply, %{state | updates: CollisionUpdates.enqueue(state.updates, delta, now(state))}}
  end

  def handle_info({:snapshot_result, _ref, :ok}, state), do: {:noreply, state}

  def handle_info({:snapshot_result, _ref, {:error, :canonical_incomplete}}, state),
    do: {:noreply, fail_source(state)}

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    cond do
      ref == state.world_monitor ->
        {:noreply, fail_source(state)}

      Map.has_key?(state.workers, ref) ->
        state = %{state | workers: Map.delete(state.workers, ref)}
        {:noreply, if(reason == :normal, do: state, else: fail_source(state))}

      true ->
        identity =
          Enum.find_value(state.characters, fn {id, c} -> if c.monitor == ref, do: id end)

        {:noreply, if(identity, do: drop(state, identity, 3), else: state)}
    end
  end

  def handle_info(:tick, %{initialized: true, failure: nil} = state) do
    started = now(state)
    due = div((started - state.mono_origin) * 60, 1_000_000)

    state =
      if due > state.tick do
        {:message_queue_len, mailbox} = Process.info(self(), :message_queue_len)
        before = state

        oldest_age =
          case :queue.peek(state.updates.queue) do
            :empty -> nil
            {:value, {_, received}} -> started - received
          end

        state = %{
          state
          | tick: state.tick + 1,
            overdue_ticks: max(state.overdue_ticks, due - state.tick - 1),
            mailbox_peak: max(state.mailbox_peak, mailbox)
        }

        {us, state} = :timer.tc(fn -> tick(state) end)
        ended = now(state)

        runtime_event(state, :region_tick, %{
          due_us: deadline(state, state.tick),
          start_us: started,
          end_us: ended,
          overdue_ticks: due - state.tick,
          tick_us: us,
          nif_us: state.step_us - before.step_us,
          build_us: state.updates.build_us - before.updates.build_us,
          elapsed_time_domain: :beam_monotonic_elapsed_us,
          stepped_count: state.physics_steps - before.physics_steps,
          mailbox_at_start: mailbox,
          queue_before: :queue.len(before.updates.queue),
          queue_after: :queue.len(state.updates.queue),
          queue_oldest_age_us: oldest_age
        })

        %{state | tick_us: state.tick_us + us, max_tick_us: max(state.max_tick_us, us)}
      else
        state
      end

    schedule(state)
    {:noreply, state}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  defp tick(state) do
    {updates, events} = CollisionUpdates.consume(state.updates, now(state))
    state = %{state | updates: CollisionUpdates.record_tick(updates, state.tick, events)}

    Enum.each(events, fn
      {:delta, delta, revision, _} ->
        payload = Voxel.Codec.encode_transaction(delta.transaction) |> IO.iodata_to_binary()

        for {_, c} <- state.characters, c.baseline != nil do
          reliable(state, c, :voxel, {:voxel_log_transaction_payload, payload})

          if delta.chunks != [] do
            reliable(state, c, :voxel, %Voxel.CollisionApplied{
              identity: c.identity,
              collision_revision: revision,
              transaction_seq: delta.transaction_seq,
              apply_tick: state.tick,
              changed_chunks: Enum.map(delta.chunks, & &1.coord)
            })
          end
        end

      {:marker, _, _} ->
        :ok
    end)

    state = step_characters(state)

    state =
      Enum.reduce(events, state, fn
        {:marker, ref, snapshot}, s -> anchor_join(s, ref, snapshot)
        _, s -> s
      end)

    state =
      Enum.reduce(state.characters, state, fn {_, c}, s ->
        if c.state != nil and c.ready and c.clock_ready and c.origin == nil do
          origin = s.tick + 30

          reliable(s, c, :control, %Session.InputStart{
            identity: c.identity,
            anchor_tick: s.tick,
            transaction_seq: s.updates.transaction_seq,
            collision_revision: s.updates.revision,
            state: c.state,
            origin_tick: origin,
            first_input_seq: 1,
            prediction_lead_ticks: 8
          })

          fence(s, c)

          character_event(s, c, :input_start, %{
            origin_tick: origin,
            content_version: s.content_version
          })

          put_character(s, %{c | origin: origin, slots: InputSlots.new(c.identity, origin)})
        else
          s
        end
      end)

    state =
      if rem(state.tick, 3) == 0 do
        for {_, c} <- state.characters, active?(state, c) do
          fence(state, c)

          state.sink.datagram(c.gate, c.identity, %Movement.OwnerAck{
            identity: c.identity,
            server_tick: state.tick,
            processed_input_seq: c.slots.processed_input_seq,
            collision_revision: c.simulation_revision,
            simulation_tick: c.simulation_tick,
            state: c.state,
            substituted_through_seq: c.slots.substituted_through_seq
          })
        end

        publish_aoi(state)
      else
        state
      end

    Logger.debug(fn ->
      inspect(%{
        event: :voxim_scene_tick,
        scene_id: state.scene_id,
        tick: state.tick,
        transaction_seq: state.updates.transaction_seq,
        collision_revision: state.updates.revision,
        characters:
          Enum.map(state.characters, fn {_, c} ->
            %{
              entity_id: c.id,
              state: c.state,
              input_seq: if(c.slots, do: c.slots.processed_input_seq, else: 0),
              substituted:
                c.slots != nil and c.slots.processed_input_seq > 0 and
                  c.slots.substituted_through_seq == c.slots.processed_input_seq
            }
          end)
          |> Enum.sort_by(& &1.entity_id)
      })
    end)

    state
  end

  defp step_characters(state) do
    state = state.characters |> Enum.sort_by(fn {_, c} -> c.id end)
      |> Enum.reduce(state, fn {identity, _}, s -> advance_character(s, identity) end)
    # Restore the current collider artifact after historical character replay.
    {updates, _} = CollisionUpdates.at_tick(state.updates, state.tick)
    earliest = Enum.reduce(state.characters, state.tick, fn {_, c}, t ->
      if c.state, do: min(t, c.simulation_tick), else: t
    end)
    %{state | updates: CollisionUpdates.retire_before(updates, earliest)}
  end

  defp advance_character(state, identity) do
    c = Map.fetch!(state.characters, identity)
    cond do
      c.state == nil or c.simulation_tick >= state.tick -> state
      not query_allowed?(state, c.state) -> drop(state, identity, 4)
      true ->
        tick = c.simulation_tick + 1
        {slots, frame, selection} =
          if c.origin != nil and tick >= c.origin do
            InputSlots.take_observed(c.slots, state.tick)
          else
            {c.slots, :joining_zero, :joining_zero}
          end
        if frame == :waiting do
          character_event(state, c, :input_wait, %{
            simulation_tick: c.simulation_tick, processed_input_seq: c.slots.processed_input_seq,
            pending_inputs: map_size(c.slots.pending), lag_ticks: state.tick - c.simulation_tick})
          state
        else
          {input, yaw} = if frame == :joining_zero do
            {{0.0, 0.0, 0}, c.state.yaw}
          else
            {x, z} = Movement.Codec.axes(frame)
            {{x, z, frame.jump_pressed}, frame.yaw}
          end
          {updates, revision} = CollisionUpdates.at_tick(state.updates, tick)
          state = %{state | updates: updates}
          {x, z, jump} = input
          character_event(state, c, :input_selected, %{
            input_seq: if(frame == :joining_zero, do: nil, else: frame.input_seq),
            due_tick: tick, simulation_tick: tick, collision_revision: revision,
            axis_x: if(frame == :joining_zero, do: 0, else: frame.axis_x),
            axis_z: if(frame == :joining_zero, do: 0, else: frame.axis_z),
            yaw: yaw, jump_pressed: jump, native_axis_x: x, native_axis_z: z,
            selection: selection, lag_ticks: state.tick - tick})
          {us, [{_, native_state}]} = :timer.tc(fn ->
            updates.native.step_characters(updates.world, state.config.profile_tuple,
              [{c.id, pod(c.state), input}])
          end)
          next = from_pod(native_state, yaw)
          state = %{state | step_us: state.step_us + us, physics_steps: state.physics_steps + 1}
          if inside?(next.position, state.config.travel) do
            state = put_character(state, %{c | state: next, slots: slots,
              simulation_tick: tick, simulation_revision: revision})
            advance_character(state, identity)
          else
            drop(state, identity, 4)
          end
        end
    end
  end

  defp anchor_join(state, ref, snapshot) do
    {identity, requests} = Map.pop(state.requests, ref)
    state = %{state | requests: requests}

    case Map.fetch(state.characters, identity) do
      :error ->
        state

      {:ok, c} ->
        true = snapshot.transaction_seq == state.updates.transaction_seq

        if snapshot.content_version != state.content_version do
          drop(state, identity, 9)
        else
          probe = Enum.at(state.config.probes, c.slot)

          case find_spawn(state, probe) do
            :outside ->
              drop(state, identity, 4)

            :not_found ->
              drop(state, identity, 10)

            {:ok, native_state} ->
              spawned = from_pod(native_state, 0)

              if query_allowed?(state, spawned) do
                c = %{
                  c
                  | state: spawned,
                    simulation_tick: state.tick,
                    simulation_revision: state.updates.revision,
                    baseline: {snapshot.transaction_seq, state.updates.revision}
                }

                reliable(state, c, :control, %Session.SessionStart{
                  identity: identity,
                  entity_id: c.id,
                  entity_epoch: c.epoch,
                  server_tick: state.tick,
                  server_time_us: server_time(state),
                  content_version: state.content_version,
                  collision_revision: state.updates.revision,
                  baseline_transaction_seq: snapshot.transaction_seq,
                  state: spawned,
                  profile: state.config.profile
                })

                reliable(state, c, :voxel, %Voxel.CanonicalBootstrap{
                  identity: identity,
                  content_version: snapshot.content_version,
                  collision_revision: state.updates.revision,
                  transaction_seq: snapshot.transaction_seq,
                  l0_min: snapshot.l0_min,
                  l0_max_exclusive: snapshot.l0_max_exclusive,
                  travel_min_m: elem(state.config.travel, 0),
                  travel_max_exclusive_m: elem(state.config.travel, 1),
                  regions: snapshot.regions
                })

                fence(state, c)

                character_event(state, c, :session_start, %{
                  content_version: state.content_version
                })

                put_character(state, c)
              else
                drop(state, identity, 4)
              end
          end
        end
    end
  end

  defp request_snapshot(state, request) do
    scene = self()
    world_api = state.world_api
    world_ref = state.world_ref
    l0 = state.config.l0

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          world_api.canonical_snapshot_and_subscribe(
            world_ref,
            l0,
            scene,
            request
          )

        send(scene, {:snapshot_result, request, result})
      end)

    %{state | workers: Map.put(state.workers, monitor, pid)}
  end

  defp fail_source(state) do
    Logger.error("voxim_scene canonical_incomplete scene_id=#{state.scene_id} tick=#{state.tick}")
    state = Enum.reduce(Map.keys(state.characters), state, &drop(&2, &1, 5))

    %{
      state
      | failure: 5,
        initialized: false,
        requests: %{},
        updates: %{state.updates | queue: :queue.new()}
    }
  end

  defp drop(state, identity, reason) do
    case Map.pop(state.characters, identity) do
      {nil, _} ->
        state

      {c, characters} ->
        character_event(state, c, :session_end, %{
          reason: reason,
          content_version: state.content_version
        })

        Process.demonitor(c.monitor, [:flush])
        close_sink(state, c.gate, identity, reason)
        {aoi, lifecycle} = AOI.remove(state.aoi, identity, c.id, c.epoch, state.tick)
        state = %{state | characters: characters, aoi: aoi}
        emit_lifecycle(state, lifecycle)
        state
    end
  end

  defp publish_aoi(state) do
    entities =
      for {_, c} <- state.characters,
          active?(state, c),
          do: %{identity: c.identity, entity_id: c.id, entity_epoch: c.epoch, state: c.state}

    {aoi, lifecycle, snapshots} =
      AOI.update(state.aoi, entities, state.tick, state.updates.revision)

    emit_lifecycle(state, lifecycle)

    for snapshot <- snapshots do
      c = Map.fetch!(state.characters, snapshot.identity)
      state.sink.datagram(c.gate, c.identity, snapshot)
    end

    %{state | aoi: aoi}
  end

  defp emit_lifecycle(state, lifecycle) do
    for event <- lifecycle do
      c = Map.fetch!(state.characters, event.identity)
      reliable(state, c, :control, event)
      Logger.debug(fn -> inspect(%{event: :voxim_aoi_lifecycle, message: event}) end)
    end
  end

  defp active?(state, c), do: c.origin != nil and state.tick >= c.origin

  defp close_sink(state, gate, identity, reason), do: state.sink.close(gate, identity, reason)

  defp reliable(state, c, purpose, event),
    do: state.sink.reliable(c.gate, c.identity, purpose, event)

  defp fence(state, c),
    do:
      reliable(state, c, :voxel, %Voxel.TimelineFence{
        identity: c.identity,
        server_tick: state.tick,
        transaction_seq: state.updates.transaction_seq,
        collision_revision: state.updates.revision
      })

  defp put_character(state, c),
    do: %{state | characters: Map.put(state.characters, c.identity, c)}

  defp stale(state), do: %{state | old_identity: state.old_identity + 1}
  defp now(%{clock: {module, ref}}), do: module.now(ref)
  defp server_time(state), do: state.time_origin + now(state) - state.time_mono_origin

  defp schedule(state) do
    delay = max(0, div(deadline(state, state.tick + 1) - now(state) + 999, 1000))

    if delay == 0 do
      send(self(), :tick)
    else
      {module, ref} = state.clock
      module.schedule(ref, self(), delay)
    end
  end

  defp deadline(state, tick), do: state.mono_origin + div(tick * 1_000_000 + 59, 60)

  # 字段只投影当前 owner 的确定事实；日志不重新接纳输入或推进时间。
  defp input_arrivals(state, identity, c, frames, disposition, arrived) do
    for frame <- frames do
      runtime_event(state, :input_arrival, %{
        monotonic_us: arrived,
        session_epoch: identity.session_epoch,
        entity_id: if(c, do: c.id, else: nil),
        entity_epoch: if(c, do: c.epoch, else: nil),
        input_seq: frame.input_seq,
        due_tick: if(c && c.origin, do: c.origin + frame.input_seq - 1, else: nil),
        axis_x: frame.axis_x,
        axis_z: frame.axis_z,
        yaw: frame.yaw,
        jump_pressed: frame.jump_pressed,
        disposition: disposition
      })
    end
  end

  defp character_event(state, c, event, facts) do
    runtime_event(
      state,
      event,
      Map.merge(facts, %{
        session_epoch: c.identity.session_epoch,
        entity_id: c.id,
        entity_epoch: c.epoch
      })
    )
  end

  defp runtime_event(state, event, facts) do
    Logger.info(fn ->
      Jason.encode!(
        Map.merge(
          %{
            schema: "voxim-scene-v1",
            event: event,
            node: Atom.to_string(node()),
            process: inspect(self()),
            scene_id: state.scene_id,
            scene_epoch: state.scene_epoch,
            server_tick: state.tick,
            monotonic_us: now(state),
            time_domain: :scene_clock_monotonic_us,
            transaction_seq: state.updates.transaction_seq,
            collision_revision: state.updates.revision
          },
          facts
        )
      )
    end)
  end

  defp query_allowed?(state, value) do
    {lo, hi} = state.updates.native.query_bounds(state.config.profile_tuple, pod(value))
    {min, max} = state.config.bounds

    inside?(value.position, state.config.travel) and
      Enum.all?(0..2, &(elem(lo, &1) >= elem(min, &1) and elem(hi, &1) < elem(max, &1)))
  end

  defp find_spawn(state, probe) do
    start = from_pod({probe, {0.0, 0.0, 0.0}, 0}, 0)
    finish = %{start | position: put_elem(probe, 1, state.config.spawn_min_y)}

    if query_allowed?(state, start) and query_allowed?(state, finish) do
      state.updates.native.find_spawn(
        state.updates.world,
        state.config.profile_tuple,
        probe,
        state.config.spawn_min_y
      )
    else
      :outside
    end
  end

  defp inside?(point, {min, max}),
    do: Enum.all?(0..2, &(elem(point, &1) >= elem(min, &1) and elem(point, &1) < elem(max, &1)))

  defp pod(state), do: {state.position, state.velocity, state.grounded}

  defp from_pod({position, velocity, grounded}, yaw),
    do: %Session.State{position: position, velocity: velocity, grounded: grounded, yaw: yaw}

  defp float_tuple(values), do: values |> Enum.map(&(&1 / 1)) |> List.to_tuple()
  defp map_tuple(tuple, fun), do: tuple |> Tuple.to_list() |> Enum.map(fun) |> List.to_tuple()
end
