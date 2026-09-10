defmodule SceneServer.Movement.Player do
  @moduledoc "每个已鉴权 identity 的唯一输入与物理 owner；只消费 Scene 已发布的连续时间线。"
  use GenServer, restart: :temporary
  require Logger
  alias MmoContracts.{Session, Movement, Voxel}
  alias SceneServer.Movement.{InputSlots, CollisionUpdates, Replication, Clock}

  @doc "由 Scene 的 DynamicSupervisor 创建；断线不从派生状态重启。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @doc "Gate 直接转发已鉴权输入，额度只取公共已发布 tick。"
  def input(player, identity, batch), do: GenServer.cast(player, {:input, identity, batch})
  @doc "确认该会话自己的 bootstrap N/R。"
  def ready(player, identity, seq, revision), do: GenServer.cast(player, {:ready, identity, seq, revision})
  @doc "沿入场冻结的单调时钟映射回复。"
  def time_probe(player, identity, probe), do: GenServer.cast(player, {:time_probe, identity, probe})
  @doc "单个 owner 的即时事实；常态全场观测使用 Scene 的低频缓存。"
  def observe(player), do: GenServer.call(player, :observe)
  def seal(player, identity), do: GenServer.call(player, {:seal, identity})
  def activate(player, identity), do: GenServer.call(player, {:activate, identity})

  @impl true
  def init(opts) do
    state = Map.new(opts) |> Map.merge(%{state: nil, baseline: nil, ready: false,
      clock_ready: false, slots: nil, origin: nil, simulation_tick: 0,
      simulation_revision: 0, tick: 0, physics_steps: 0, step_us: 0,
      rejected_inputs: 0, old_identity: 0, substitutions: 0, failure: nil,
      transfer: nil, deferred: [], private_timeline: false, queued_seq: 0, resume_pending: false})
    state = case Keyword.get(opts, :import) do
      nil -> state
      cut -> Map.merge(state, %{state: cut.state, baseline: {cut.transaction_seq, cut.simulation_revision},
        ready: true, clock_ready: true, slots: %{cut.slots | identity: state.identity},
        origin: cut.origin, simulation_tick: cut.simulation_tick,
        simulation_revision: cut.simulation_revision, tick: cut.published_tick, transfer: :prepared,
        private_timeline: true, queued_seq: cut.transaction_seq, resume_pending: true})
        |> enqueue_tail(Keyword.fetch!(opts, :tail))
        |> private_ticks(Keyword.fetch!(opts, :tick))
    end
    Process.monitor(state.scene)
    Process.monitor(state.gate)
    {:ok, state}
  end

  @impl true
  def handle_call(:observe, _, state), do: {:reply, observation(state), state}
  def handle_call({:seal, identity}, _, %{identity: identity, transfer: :requested} = state) do
    fence(state)
    checkpoint = CollisionUpdates.export_checkpoint(state.updates, state.simulation_tick)
    cut = Map.take(state, [:id, :epoch, :identity, :state, :slots, :origin,
      :simulation_tick, :simulation_revision, :config, :content_version])
      |> Map.merge(%{transaction_seq: state.updates.transaction_seq,
        published_tick: state.tick, collision_checkpoint: checkpoint})
    character_event(state, state, :transfer_sealed, %{cut_tick: state.simulation_tick,
      checkpoint_bytes: :erlang.external_size(checkpoint),
      retained_versions: length(checkpoint.revisions)})
    {:reply, {:ok, cut}, %{state | transfer: :sealed}}
  end
  def handle_call({:activate, identity}, _, %{identity: identity, transfer: :prepared} = state) do
    for {tick, events} <- Enum.reverse(state.deferred), do: emit_transactions(state, tick, events)
    state = %{state | transfer: nil, deferred: []} |> advance() |> publish()
    fence(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:input, _, _}, %{transfer: :sealed} = state),
    do: {:noreply, %{state | old_identity: state.old_identity + 1}}
  def handle_cast({:ready, identity, seq, revision}, %{identity: identity} = state) do
    if state.baseline == {seq, revision}, do: {:noreply, %{state | ready: true}},
      else: finish(fail(state, 8))
  end
  def handle_cast({:time_probe, identity, %Session.TimeProbe{} = probe}, %{identity: identity} = state) do
    received = server_time(state)
    {sent, tick} = Clock.sample(state)
    reliable(state, :control, %Session.TimeReply{request_id: probe.request_id,
      client_send_us: probe.client_send_us, server_receive_us: received,
      server_send_us: sent, server_tick: tick})
    {:noreply, %{state | clock_ready: true}}
  end
  def handle_cast({:input, identity, %Movement.InputBatch{identity: identity} = batch}, %{identity: identity} = state) do
    arrived = now(state)
    state = if state.slots == nil do
      input_arrivals(state, identity, state, batch.frames, :not_started, arrived)
      %{state | rejected_inputs: state.rejected_inputs + 1}
    else
      {slots, result, decisions} = InputSlots.receive_batch_observed(state.slots, batch)
      for {frame, disposition} <- decisions,
        do: input_arrivals(state, identity, state, [frame], disposition, arrived)
      %{state | slots: slots, rejected_inputs: state.rejected_inputs + if(result == :accepted, do: 0, else: 1)}
      |> advance()
    end
    finish(state)
  end
  def handle_cast(:stop, state), do: {:stop, :normal, state}
  def handle_cast(_, state), do: {:noreply, %{state | old_identity: state.old_identity + 1}}

  @impl true
  def handle_info({:clock_origin, origin}, state), do: {:noreply, %{state | mono_origin: origin}}
  def handle_info({:anchor, tick, updates, content_version, snapshot}, state) do
    state = %{state | tick: tick, updates: updates, content_version: content_version}
    probe = Enum.at(state.config.probes, state.slot)
    state = case find_spawn(state, probe) do
      :outside -> fail(state, 4)
      :not_found -> fail(state, 10)
      {:ok, native_state} ->
        spawned = from_pod(native_state, 0)
        if query_allowed?(state, spawned) do
          state = %{state | state: spawned, simulation_tick: tick,
            simulation_revision: updates.revision, baseline: {snapshot.transaction_seq, updates.revision}}
          reliable(state, :control, %Session.SessionStart{identity: state.identity,
            entity_id: state.id, entity_epoch: state.epoch, server_tick: tick,
            server_time_us: server_time(state), content_version: content_version,
            collision_revision: updates.revision, baseline_transaction_seq: snapshot.transaction_seq,
            state: spawned, profile: state.config.profile})
          reliable(state, :voxel, %Voxel.CanonicalBootstrap{identity: state.identity,
            content_version: content_version, collision_revision: updates.revision,
            transaction_seq: snapshot.transaction_seq, l0_min: snapshot.l0_min,
            l0_max_exclusive: snapshot.l0_max_exclusive, travel_min_m: elem(state.config.travel, 0),
            travel_max_exclusive_m: elem(state.config.travel, 1), regions: snapshot.regions})
          fence(state)
          character_event(state, state, :session_start, %{content_version: content_version})
          publish(state)
        else
          fail(state, 4)
        end
    end
    finish(state)
  end

  def handle_info({:timeline, _, _, _, _, _}, %{transfer: :sealed} = state), do: {:noreply, state}
  def handle_info({:timeline, tick, seq, revision, versions, events}, state) do
    state = if state.private_timeline do
      state |> enqueue_tail(Enum.map(events, &elem(&1, 4))) |> private_ticks(tick)
    else
      updates = CollisionUpdates.ingest_publication(state.updates, tick, seq, revision, versions, events)
      %{state | tick: tick, updates: updates} |> deliver_transactions(tick, events)
    end
    state = advance(state) |> input_start()
    state = if tick == state.tick and rem(tick, 3) == 0 and state.failure == nil and state.transfer != :prepared do
      if active?(state) do
        fence(state)
        state.sink.datagram(state.gate, state.identity, %Movement.OwnerAck{
          identity: state.identity, server_tick: state.tick, processed_input_seq: state.slots.processed_input_seq,
          collision_revision: state.simulation_revision, simulation_tick: state.simulation_tick,
          state: state.state, substituted_through_seq: state.slots.substituted_through_seq})
      end
      publish(state)
    else
      state
    end
    finish(state)
  end
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}

  defp input_start(%{state: value, ready: true, clock_ready: true, origin: nil, failure: nil} = state) when value != nil do
    origin = state.tick + 30
    reliable(state, :control, %Session.InputStart{identity: state.identity,
      anchor_tick: state.simulation_tick, transaction_seq: state.updates.transaction_seq,
      collision_revision: state.simulation_revision, state: state.state, origin_tick: origin,
      first_input_seq: 1, prediction_lead_ticks: 8})
    fence(state)
    character_event(state, state, :input_start, %{origin_tick: origin, content_version: state.content_version})
    publish(%{state | origin: origin, slots: InputSlots.new(state.identity, origin)})
  end
  defp input_start(state), do: state

  defp advance(%{failure: reason} = state) when reason != nil, do: state
  defp advance(%{transfer: transfer} = state) when transfer != nil, do: state
  defp advance(state) do
    cond do
      state.state == nil or state.simulation_tick >= state.tick -> state
      not query_allowed?(state, state.state) -> fail(state, 4)
      true ->
        tick = state.simulation_tick + 1
        {slots, frame, selection} = if state.origin != nil and tick >= state.origin,
          do: InputSlots.take_observed(state.slots, state.tick),
          else: {state.slots, :joining_zero, :joining_zero}
        if frame == :waiting do
          state
        else
          {input, yaw} = if frame == :joining_zero do
            {{0.0, 0.0, 0}, state.state.yaw}
          else
            {x, z} = Movement.Codec.axes(frame)
            {{x, z, frame.jump_pressed}, frame.yaw}
          end
          {world, revision} = CollisionUpdates.at_tick(state.updates, tick)
          {x, z, jump} = input
          character_event(state, state, :input_selected, %{
            input_seq: if(frame == :joining_zero, do: nil, else: frame.input_seq),
            due_tick: tick, simulation_tick: tick, collision_revision: revision,
            axis_x: if(frame == :joining_zero, do: 0, else: frame.axis_x),
            axis_z: if(frame == :joining_zero, do: 0, else: frame.axis_z),
            yaw: yaw, jump_pressed: jump, native_axis_x: x, native_axis_z: z,
            selection: selection, lag_ticks: state.tick - tick})
          {us, [{_, result}]} = :timer.tc(fn -> state.updates.native.step_characters(world,
            state.config.profile_tuple, [{state.id, pod(state.state), input}]) end)
          if state.resume_pending do
            character_event(state, state, :transfer_resumed, %{simulation_tick: tick,
              processed_input_seq: slots.processed_input_seq, collision_revision: revision})
          end
          state = %{state | resume_pending: false}
          next = from_pod(result, yaw)
          state = %{state | step_us: state.step_us + us, physics_steps: state.physics_steps + 1}
          if inside?(next.position, state.config.travel) do
            %{state | state: next, slots: slots, simulation_tick: tick,
              simulation_revision: revision, updates: CollisionUpdates.retire_before(state.updates, tick)}
            |> boundary()
            |> advance()
          else
            fail(state, 4)
          end
        end
    end
  end

  defp fail(state, reason), do: %{state | failure: reason}
  defp finish(%{failure: nil} = state), do: {:noreply, state}
  defp finish(state) do
    send(state.scene, {:player_failed, state.identity, self(), state.failure})
    {:stop, :normal, state}
  end
  defp active?(state), do: state.transfer != :prepared and state.origin != nil and state.tick >= state.origin
  defp boundary(state) do
    target = if state.origin != nil and not inside?(state.state.position, state.config.authority),
      do: Enum.find(state.config.neighbours, &inside?(state.state.position, &1.authority))
    if target do
      send(state.gate, {:mmo_transfer_request, state.identity, self(), target.scene_id})
      character_event(state, state, :transfer_cut, %{target_scene_id: target.scene_id,
        cut_tick: state.simulation_tick, processed_input_seq: state.slots.processed_input_seq})
      %{state | transfer: :requested} |> publish()
    else
      state
    end
  end
  defp emit_transactions(state, tick, events) do
    for {payload, n, r, chunks, _delta} <- events do
      reliable(state, :voxel, {:voxel_log_transaction_payload, payload})
      if chunks != [], do: reliable(state, :voxel, %Voxel.CollisionApplied{
        identity: state.identity, collision_revision: r, transaction_seq: n,
        apply_tick: tick, changed_chunks: Enum.map(chunks, & &1.coord)})
    end
  end
  defp enqueue_tail(state, deltas) do
    Enum.reduce(deltas, state, fn delta, s ->
      if delta.transaction_seq <= s.queued_seq do
        s
      else
        true = delta.transaction_seq == s.queued_seq + 1
        %{s | queued_seq: delta.transaction_seq,
          updates: CollisionUpdates.enqueue(s.updates, delta, now(s))}
      end
    end)
  end

  defp private_ticks(state, tick) when tick <= state.tick, do: state
  defp private_ticks(state, tick) do
    next = state.tick + 1
    {updates, events} = CollisionUpdates.consume(state.updates, now(state))
    updates = CollisionUpdates.record_tick(updates, next, events)
    transactions = for {:delta, delta, revision, _} <- events do
      {Voxel.Codec.encode_transaction(delta.transaction) |> IO.iodata_to_binary(),
        delta.transaction_seq, revision, delta.chunks, delta}
    end
    %{state | tick: next, updates: updates}
    |> deliver_transactions(next, transactions)
    |> advance()
    |> private_ticks(tick)
  end

  defp deliver_transactions(state, tick, events) do
    if state.transfer == :prepared do
      if events == [], do: state, else: %{state | deferred: [{tick, events} | state.deferred]}
    else
      if state.baseline != nil, do: emit_transactions(state, tick, events)
      state
    end
  end

  defp observation(state) do
    {:message_queue_len, mailbox} = Process.info(self(), :message_queue_len)
    %{identity: state.identity, entity_id: state.id, entity_epoch: state.epoch,
      player_pid: self(), gate_pid: state.gate, state: state.state, origin_tick: state.origin,
      simulation_tick: state.simulation_tick, collision_revision: state.simulation_revision,
      pending_inputs: if(state.slots, do: map_size(state.slots.pending), else: 0),
      processed_input_seq: if(state.slots, do: state.slots.processed_input_seq, else: 0),
      active: active?(state), published_tick: state.tick, physics_steps: state.physics_steps,
      step_us: state.step_us, rejected_inputs: state.rejected_inputs, old_identity: state.old_identity,
      substitutions: state.substitutions, mailbox: mailbox,
      retained_versions: length(state.updates.revisions)}
  end
  defp publish(state) do
    result = observation(state)
    send(state.scene, {:player_observation, result})
    Replication.result(state.replication, result)
    state
  end
  defp reliable(state, purpose, event), do: state.sink.reliable(state.gate, state.identity, purpose, event)
  defp fence(state), do: reliable(state, :voxel, %Voxel.TimelineFence{
    identity: state.identity, server_tick: state.tick, transaction_seq: state.updates.transaction_seq,
    collision_revision: state.updates.revision})
  defp now(state), do: Clock.monotonic(state)
  defp server_time(state), do: state |> Clock.sample() |> elem(0)

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
            server_time_us: server_time(state),
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

end
