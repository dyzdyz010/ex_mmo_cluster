defmodule SceneServer.Movement.Scene do
  @moduledoc "公共60Hz碰撞时间线与成员 owner；物理输入归属独立 Player。"
  use GenServer
  require Logger
  alias MmoContracts.{Session, Voxel}
  alias SceneServer.Movement.{Player, CollisionUpdates, Replication, Clock}

  @doc "从明确的 route 和资产导出启动唯一 writer。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  @doc "入队；输出经 Gate sink 异步发送。角色已由 Gate 完成归属鉴权。"
  def join(scene, identity, authorized_character, gate_pid),
    do: GenServer.call(scene, {:join, identity, authorized_character, gate_pid})

  @doc "结束此 identity；旧 epoch 不影响重连。"
  def leave(scene, identity, reason \\ 1), do: GenServer.cast(scene, {:leave, identity, reason})
  @doc "只读标量统计与角色状态，不暴露可变 NIF resource。"
  def observe(scene), do: GenServer.call(scene, :observe)
  @doc "公共水位与20Hz玩家事实缓存；不调用玩家或扫描AOI关系。"
  def metrics(scene), do: observe(scene)

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
    true = Enum.all?(0..2, &(is_integer(elem(lo, &1)) and is_integer(elem(hi, &1)) and elem(hi, &1) > elem(lo, &1)))
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
    true = probes != [] and Enum.all?(probes, &inside?(&1, travel))
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

    {:ok, players} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, replication} = Replication.start_link(sink: Keyword.get(opts, :sink, GateServer.Session.Sink))
    state = %{
      players: players,
      replication: replication,
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
  def terminate(_, state) do
    if Process.alive?(state.players), do: Supervisor.stop(state.players)
    if Process.alive?(state.replication), do: GenServer.stop(state.replication)
    :ok
  end

  @impl true
  def handle_call({:join, identity, %{id: cid}, gate}, _, state) do
    cond do
      identity.scene_id != state.scene_id or identity.scene_epoch != state.scene_epoch ->
        close_sink(state, gate, identity, 11)
        {:reply, {:error, :closed}, state}

      state.failure != nil ->
        close_sink(state, gate, identity, state.failure)
        {:reply, {:error, :closed}, state}

      Map.has_key?(state.characters, identity) ->
        {:reply, {:ok, state.characters[identity].player}, state}

      Enum.any?(state.characters, fn {_, c} -> c.id == cid end) ->
        close_sink(state, gate, identity, 2)
        {:reply, {:error, :closed}, state}

      map_size(state.characters) == length(state.config.probes) ->
        close_sink(state, gate, identity, 10)
        {:reply, {:error, :closed}, state}

      true ->
        occupied = Enum.map(state.characters, fn {_, c} -> c.slot end)
        slot = Enum.find(0..(length(state.config.probes) - 1), &(&1 not in occupied))
        request = make_ref()

        opts = [scene: self(), replication: state.replication, gate: gate,
          identity: identity, id: cid, epoch: state.next_entity_epoch, slot: slot,
          config: state.config, clock: state.clock, time_origin: state.time_origin,
          time_mono_origin: state.time_mono_origin, mono_origin: if(state.initialized, do: state.mono_origin, else: nil), sink: state.sink,
          updates: %{state.updates | queue: :queue.new()}, content_version: state.content_version,
          scene_id: state.scene_id, scene_epoch: state.scene_epoch]
        {:ok, player} = DynamicSupervisor.start_child(state.players, {Player, opts})
        character = %{id: cid, identity: identity, epoch: state.next_entity_epoch,
          slot: slot, gate: gate, player: player, monitor: Process.monitor(player), observation: nil}
        Replication.join(state.replication, identity, cid, character.epoch, player, gate)

        state = %{
          state
          | characters: Map.put(state.characters, identity, character),
            requests: Map.put(state.requests, request, identity),
            next_entity_epoch: state.next_entity_epoch + 1
        }

        {:reply, {:ok, player}, if(state.initialized, do: request_snapshot(state, request), else: state)}
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
        replication_pid: state.replication,
        player_supervisor_pid: state.players,
        mailbox: mailbox,
        queue_length: :queue.len(state.updates.queue),
        collision_revision: state.updates.revision,
        transaction_seq: state.updates.transaction_seq,
        build_us: state.updates.build_us,
        queue_wait_us: state.updates.queue_wait_us,
        characters:
          Enum.map(state.characters, fn {identity, c} ->
            c.observation || %{identity: identity, entity_id: c.id, entity_epoch: c.epoch,
              player_pid: c.player, gate_pid: c.gate, state: nil, origin_tick: nil, simulation_tick: 0,
              pending_inputs: 0, active: false, processed_input_seq: 0, collision_revision: 0,
              physics_steps: 0, step_us: 0, published_tick: 0}
          end)
          |> Enum.sort_by(& &1.entity_id)
      })

    {:reply, info, state}
  end

  @impl true
  def handle_cast({:leave, identity, reason}, state),
    do: {:noreply, drop(state, identity, reason)}

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

    for {_, c} <- state.characters, do: send(c.player, {:clock_origin, state.mono_origin})
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

  def handle_info({:player_observation, result}, state) do
    case state.characters[result.identity] do
      %{player: pid} = c when pid == result.player_pid ->
        previous = c.observation
        state = Enum.reduce([:physics_steps, :step_us, :rejected_inputs, :old_identity, :substitutions], state,
          fn key, s -> Map.update!(s, key, &(&1 + result[key] - if(previous, do: previous[key], else: 0))) end)
        {:noreply, %{state | characters: Map.put(state.characters, result.identity, %{c | observation: result})}}
      _ -> {:noreply, state}
    end
  end
  def handle_info({:player_failed, identity, pid, reason}, state) do
    case state.characters[identity] do
      %{player: ^pid} -> {:noreply, drop(state, identity, reason)}
      _ -> {:noreply, state}
    end
  end

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
    due = Clock.due_tick(state, started)

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
    updates = CollisionUpdates.record_tick(updates, state.tick, events)
    versions = Enum.take_while(updates.revisions, fn {tick, _, _} -> tick == state.tick end)
    transactions = for {:delta, delta, revision, _} <- events do
      {Voxel.Codec.encode_transaction(delta.transaction) |> IO.iodata_to_binary(),
       delta.transaction_seq, revision, Enum.map(delta.chunks, & &1.coord)}
    end
    for {_, c} <- state.characters do
      send(c.player, {:timeline, state.tick, updates.transaction_seq, updates.revision, versions, transactions})
    end
    # 发布消息与各 Player 自有历史引用保留旧版本；Scene 无需等待最慢玩家退休。
    state = %{state | updates: CollisionUpdates.retire_before(updates, state.tick)}
    state = Enum.reduce(events, state, fn
      {:marker, ref, snapshot}, s -> anchor_join(s, ref, snapshot)
      _, s -> s
    end)
    if rem(state.tick, 3) == 0, do: Replication.publish(state.replication, state.tick)
    state
  end

  defp anchor_join(state, ref, snapshot) do
    {identity, requests} = Map.pop(state.requests, ref)
    state = %{state | requests: requests}
    case state.characters[identity] do
      nil -> state
      c ->
        true = snapshot.transaction_seq == state.updates.transaction_seq
        if snapshot.content_version != state.content_version do
          drop(state, identity, 9)
        else
          send(c.player, {:anchor, state.tick, %{state.updates | queue: :queue.new()}, state.content_version, snapshot})
          state
        end
    end
  end

  defp request_snapshot(state, request) do
    scene = self()
    world_api = state.world_api
    world_ref = state.world_ref
    l0 = state.config.l0
    include_chunks = request == state.initial_ref

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          world_api.canonical_snapshot_and_subscribe(
            world_ref,
            l0,
            scene,
            request,
            include_chunks
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
        runtime_event(state, :session_end, %{session_epoch: identity.session_epoch,
          entity_id: c.id, entity_epoch: c.epoch, reason: reason,
          content_version: state.content_version})
        Process.demonitor(c.monitor, [:flush])
        GenServer.cast(c.player, :stop)
        close_sink(state, c.gate, identity, reason)
        Replication.leave(state.replication, identity, c.id, c.epoch, state.tick)
        %{state | characters: characters}
    end
  end

  defp close_sink(state, gate, identity, reason), do: state.sink.close(gate, identity, reason)

  defp now(state), do: Clock.monotonic(state)

  defp schedule(state) do
    delay = max(0, div(deadline(state, state.tick + 1) - now(state) + 999, 1000))

    if delay == 0 do
      send(self(), :tick)
    else
      {module, ref} = state.clock
      module.schedule(ref, self(), delay)
    end
  end

  defp deadline(state, tick), do: Clock.deadline(state, tick)

  defp runtime_event(state, event, facts) do
    level = if event in [:input_arrival, :input_selected, :input_wait] or
      (event == :region_tick and rem(state.tick, 60) != 0), do: :debug, else: :info
    Logger.log(level, fn ->
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

  defp inside?(point, {min, max}),
    do: Enum.all?(0..2, &(elem(point, &1) >= elem(min, &1) and elem(point, &1) < elem(max, &1)))

  defp float_tuple(values), do: values |> Enum.map(&(&1 / 1)) |> List.to_tuple()
  defp map_tuple(tuple, fun), do: tuple |> Tuple.to_list() |> Enum.map(fun) |> List.to_tuple()
end
