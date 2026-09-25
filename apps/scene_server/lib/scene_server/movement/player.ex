defmodule SceneServer.Movement.Player do
  @moduledoc "每个已鉴权 identity 的唯一输入与物理 owner；只消费 Scene 已发布的连续时间线。"
  use GenServer, restart: :temporary
  require Logger
  alias MmoContracts.{Session, Movement, Voxel}
  alias SceneServer.Movement.{InputSlots, CollisionUpdates, Replication, Clock}
  alias VoxelRegion.CollisionStream
  alias SceneServer.Body

  @doc "由 Scene 的 DynamicSupervisor 创建；断线不从派生状态重启。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @doc "Gate 直接转发已鉴权输入，额度只取公共已发布 tick。"
  def input(player, identity, batch), do: GenServer.cast(player, {:input, identity, batch})
  @doc "确认该会话自己的 bootstrap N/R。"
  def ready(player, identity, seq, revision),
    do: GenServer.cast(player, {:ready, identity, seq, revision})

  @doc "沿入场冻结的单调时钟映射回复。"
  def time_probe(player, identity, probe),
    do: GenServer.cast(player, {:time_probe, identity, probe})

  @doc "单个 owner 的即时事实；常态全场观测使用 Scene 的低频缓存。"
  def observe(player), do: GenServer.call(player, :observe)
  def tool_context(player, identity), do: GenServer.call(player, {:tool_context, identity})
  def seal(player, identity), do: GenServer.call(player, {:seal, identity})
  def activate(player, identity), do: GenServer.call(player, {:activate, identity})

  @impl true
  def init(opts) do
    state =
      Map.new(opts)
      |> Map.merge(%{
        state: nil,
        baseline: nil,
        ready: false,
        clock_ready: false,
        slots: nil,
        origin: nil,
        simulation_tick: 0,
        simulation_revision: 0,
        tick: 0,
        physics_steps: 0,
        step_us: 0,
        rejected_inputs: 0,
        old_identity: 0,
        substitutions: 0,
        failure: nil,
        transfer: nil,
        deferred: [],
        private_timeline: false,
        queued_seq: 0,
        resume_pending: false,
        stream: nil,
        stream_cursor: 0,
        window_domains: [],
        requested_window: nil,
        window_pending: false,
        # 魔法增量 4：身体真值（Docs/Magic.md §6），会话内存，不持久化（重登 / 冷重启即新身体，已知缺口）。
        # body_heat = 自上次 1 Hz 推进以来 World 回传的接触热累计；body_exchange_j = 本端收到的接触热总和（与 World 账同值）。
        body: Body.new(),
        body_heat: %{q_j: 0.0, tissue_j: 0.0, max_contact_k: nil, sole_k: nil, immersed: 0.0},
        body_exchange_j: 0.0,
        body_sent: nil,
        # 热环境（全局 ambient_kelvin + 可选气候区），来自 World 快照的 property_context；身体按所在格取空气温度。
        climate: nil
      })

    state =
      case Keyword.get(opts, :import) do
        nil ->
          state

        cut ->
          Map.merge(state, %{
            state: cut.state,
            baseline: {cut.transaction_seq, cut.simulation_revision},
            ready: true,
            clock_ready: true,
            slots: %{cut.slots | identity: state.identity},
            origin: cut.origin,
            simulation_tick: cut.simulation_tick,
            simulation_revision: cut.simulation_revision,
            tick: cut.published_tick,
            transfer: :prepared,
            private_timeline: true,
            queued_seq: cut.transaction_seq,
            resume_pending: true
          })
          |> Map.merge(Map.take(cut, [:body, :body_exchange_j, :climate]))
          |> tap(fn _ -> schedule_body() end)
          |> enqueue_tail(Keyword.fetch!(opts, :tail))
      end

    state =
      case Keyword.get(opts, :import) do
        %{stream: stream} = cut when stream != nil ->
          state =
            Map.merge(
              state,
              Map.take(cut, [
                :stream,
                :stream_cursor,
                :window_domains,
                :requested_window,
                :window_pending,
                :queued_seq
              ])
            )

          Process.monitor(stream)
          :ok = CollisionStream.attach(stream, self(), cut.stream_cursor)
          state

        nil ->
          if state.config.streaming_radius > 0 do
            box =
              CollisionStream.box(state.probe, state.config.streaming_radius)

            {:ok, stream} =
              CollisionStream.start(Keyword.fetch!(opts, :authority_ref), state.gate, self(), box)

            Process.monitor(stream)

            %{
              state
              | stream: stream,
                private_timeline: true,
                requested_window: box,
                window_pending: true,
                tick: Keyword.get(opts, :initial_tick, 0)
            }
          else
            state
          end

        _ ->
          state |> private_ticks(Keyword.fetch!(opts, :tick))
      end

    # 只读验收证据：在真实创建/移交完成处绑定来源与已鉴权角色。
    if state.stream do
      Logger.info(
        Jason.encode!(%{
          event: "liquid_stream_identity",
          stream_pid: inspect(state.stream),
          character: state.id,
          session_epoch: state.identity.session_epoch
        })
      )
    end

    Process.monitor(state.scene)
    Process.monitor(state.gate)
    {:ok, state}
  end

  @impl true
  def handle_call(
        {:tool_context, identity},
        _,
        %{
          identity: identity,
          ready: true,
          transfer: nil,
          failure: nil,
          state: %{position: {x, y, z}}
        } = state
      ) do
    {:reply,
     {:ok,
      %{
        player: self(),
        gate: state.gate,
        cid: state.id,
        identity: identity,
        eye: {x, y + 0.6, z},
        position: {x, y, z},
        # 魔法增量 1：施法留热落脚下宏格；position 是胶囊中心，脚 = 中心下移 profile 半高。
        feet: {x, y - state.config.profile.half_height, z},
        tick_us: Clock.deadline(state, 1) - Clock.deadline(state, 0),
        refresh: &__MODULE__.tool_context/2
      }}, state}
  end

  def handle_call({:tool_context, _}, _, state), do: {:reply, {:error, :invalid_state}, state}
  def handle_call(:observe, _, state), do: {:reply, observation(state), state}

  def handle_call({:seal, identity}, _, %{identity: identity, transfer: :requested} = state) do
    fence(state)

    checkpoint =
      if state.stream,
        do: CollisionUpdates.export_stream_checkpoint(state.updates, state.simulation_tick),
        else: CollisionUpdates.export_checkpoint(state.updates, state.simulation_tick)

    cut =
      Map.take(state, [
        :id,
        :epoch,
        :kind,
        :identity,
        :state,
        :slots,
        :origin,
        :simulation_tick,
        :simulation_revision,
        :config,
        :content_version,
        :stream,
        :stream_cursor,
        :window_domains,
        :requested_window,
        :window_pending,
        :queued_seq,
        :body,
        :body_exchange_j,
        :climate
      ])
      |> Map.merge(%{
        transaction_seq: state.updates.transaction_seq,
        published_tick: state.tick,
        collision_checkpoint: checkpoint
      })

    character_event(state, state, :transfer_sealed, %{
      cut_tick: state.simulation_tick,
      checkpoint_bytes: :erlang.external_size(checkpoint),
      retained_versions: length(checkpoint.revisions)
    })

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
    if state.baseline == {seq, revision},
      do: {:noreply, %{state | ready: true}},
      else: finish(fail(state, 8))
  end

  def handle_cast(
        {:time_probe, identity, %Session.TimeProbe{} = probe},
        %{identity: identity} = state
      ) do
    received = server_time(state)
    {sent, tick} = Clock.sample(state)

    reliable(state, :control, %Session.TimeReply{
      request_id: probe.request_id,
      client_send_us: probe.client_send_us,
      server_receive_us: received,
      server_send_us: sent,
      server_tick: tick
    })

    {:noreply, %{state | clock_ready: true}}
  end

  def handle_cast(
        {:input, identity, %Movement.InputBatch{identity: identity} = batch},
        %{identity: identity} = state
      ) do
    arrived = now(state)

    state =
      if state.slots == nil do
        input_arrivals(state, identity, state, batch.frames, :not_started, arrived)
        %{state | rejected_inputs: state.rejected_inputs + 1}
      else
        {slots, result, decisions} = InputSlots.receive_batch_observed(state.slots, batch)

        for {frame, disposition} <- decisions,
            do: input_arrivals(state, identity, state, [frame], disposition, arrived)

        %{
          state
          | slots: slots,
            rejected_inputs: state.rejected_inputs + if(result == :accepted, do: 0, else: 1)
        }
        |> advance()
      end

    finish(state)
  end

  def handle_cast(:stop, state), do: {:stop, :normal, state}
  def handle_cast(_, state), do: {:noreply, %{state | old_identity: state.old_identity + 1}}

  @impl true
  def handle_info({:clock_origin, origin}, state), do: {:noreply, %{state | mono_origin: origin}}

  def handle_info({:collision_stream, _, _, _}, %{transfer: :sealed} = state),
    do: {:noreply, state}

  def handle_info({:collision_stream, stream, cursor, event}, %{stream: stream} = state) do
    CollisionStream.acknowledge(stream, cursor)
    state = %{state | stream_cursor: cursor}

    case event do
      {:window, snapshot} when state.baseline == nil ->
        domain = window_domain(snapshot)
        updates = CollisionUpdates.initialize_stream(state.updates, snapshot)

        state = %{
          state
          | queued_seq: snapshot.transaction_seq,
            window_pending: false,
            window_domains: [{0, domain}],
            config: %{
              state.config
              | bounds: domain.bounds,
                travel: domain.travel,
                spawn_min_y: max(state.config.spawn_min_y, elem(elem(domain.travel, 0), 1))
            }
        }

        handle_info({:anchor, state.tick, updates, snapshot.content_version, snapshot}, state)

      {:window, snapshot} ->
        character_event(state, state, :collision_window_received, %{
          stream: inspect(stream),
          cursor: cursor,
          l0_min: Tuple.to_list(snapshot.l0_min),
          l0_max: Tuple.to_list(snapshot.l0_max_exclusive),
          at_us: System.system_time(:microsecond)
        })

        {:noreply,
         %{
           state
           | updates:
               CollisionUpdates.enqueue(
                 state.updates,
                 {:marker, :stream_window, snapshot},
                 now(state)
               )
         }}

      %Voxel.CanonicalDelta{} = delta ->
        {:noreply, enqueue_tail(state, [delta])}
    end
  end

  def handle_info({:anchor, tick, updates, content_version, snapshot}, state) do
    state = %{state | tick: tick, updates: updates, content_version: content_version}
    probe = state.probe

    state =
      case find_spawn(state, probe) do
        :outside ->
          fail(state, 4)

        :not_found ->
          fail(state, 10)

        {:ok, native_state} ->
          spawned = from_pod(native_state, 0)

          if query_allowed?(state, spawned) do
            state = %{
              state
              | state: spawned,
                simulation_tick: tick,
                simulation_revision: updates.revision,
                baseline: {snapshot.transaction_seq, updates.revision}
            }

            reliable(state, :control, %Session.SessionStart{
              identity: state.identity,
              entity_id: state.id,
              entity_epoch: state.epoch,
              server_tick: tick,
              server_time_us: server_time(state),
              content_version: content_version,
              collision_revision: updates.revision,
              baseline_transaction_seq: snapshot.transaction_seq,
              state: spawned,
              profile: state.config.profile
            })

            reliable(state, :voxel, %Voxel.CanonicalBootstrap{
              identity: state.identity,
              content_version: content_version,
              collision_revision: updates.revision,
              transaction_seq: snapshot.transaction_seq,
              l0_min: snapshot.l0_min,
              l0_max_exclusive: snapshot.l0_max_exclusive,
              travel_min_m: elem(state.config.travel, 0),
              travel_max_exclusive_m: elem(state.config.travel, 1),
              regions: snapshot.regions
            })

            property_batch(state, snapshot, true, {snapshot.l0_min, snapshot.l0_max_exclusive})
            fence(state)
            character_event(state, state, :session_start, %{content_version: content_version})
            schedule_body()

            state =
              case Map.get(snapshot, :property_context) do
                %{thermal_enabled: true, ambient_kelvin: ambient} = context ->
                  %{state | climate: %{"ambient_kelvin" => ambient, "climate_zones" => Map.get(context, :climate_zones, [])}}
                _ -> state
              end

            publish(state)
          else
            fail(state, 4)
          end
      end

    finish(state)
  end

  def handle_info({:timeline, _, _, _, _, _}, %{transfer: :sealed} = state), do: {:noreply, state}

  def handle_info({:timeline, tick, seq, revision, versions, events}, state) do
    state =
      cond do
        state.stream != nil and state.baseline == nil ->
          %{state | tick: tick}

        state.stream != nil ->
          private_ticks(state, tick)

        state.private_timeline ->
          state |> enqueue_tail(Enum.map(events, &elem(&1, 4))) |> private_ticks(tick)

        true ->
          updates =
            CollisionUpdates.ingest_publication(
              state.updates,
              tick,
              seq,
              revision,
              versions,
              events
            )

          %{state | tick: tick, updates: updates} |> deliver_transactions(tick, events)
      end

    state = advance(state) |> input_start()

    state =
      if tick == state.tick and rem(tick, 3) == 0 and state.failure == nil and
           state.transfer != :prepared do
        if active?(state) do
          fence(state)

          state.sink.datagram(state.gate, state.identity, %Movement.OwnerAck{
            identity: state.identity,
            server_tick: state.tick,
            processed_input_seq: state.slots.processed_input_seq,
            collision_revision: state.simulation_revision,
            simulation_tick: state.simulation_tick,
            state: state.state,
            substituted_through_seq: state.slots.substituted_through_seq
          })
        end

        publish(state)
      else
        state
      end

    finish(state)
  end

  # 魔法增量 4：World 每段热演化回传的接触热（J）、鞋底格温度、裸接触最高温度与浸没比例；下一次 1 Hz 推进时一并吃进 Body。
  def handle_info({:body_heat, %{q_j: q, max_contact_k: max_k, sole_k: sole_k, immersed: immersed} = step}, state) do
    heat = state.body_heat

    heat = %{heat | q_j: heat.q_j + q, tissue_j: heat.tissue_j + step.tissue_j, immersed: immersed,
      max_contact_k: highest(heat.max_contact_k, max_k), sole_k: highest(heat.sole_k, sole_k)}

    character_event(state, state, :body_heat, Map.merge(step, %{world_seq: step.seq, body_exchange_j: state.body_exchange_j + q}))

    {:noreply, %{state | body_heat: heat, body_exchange_j: state.body_exchange_j + q}}
  end

  def handle_info(:body_tick, %{transfer: transfer} = state) when transfer in [:requested, :sealed],
    do: {:noreply, state}

  def handle_info(:body_tick, state) do
    schedule_body()
    {:noreply, body_tick(state)}
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}

  # 1 Hz：Body 推进 1 s（吃进累计接触热；无接触时接触温度 = 空气）→ 把身体几何与新皮肤温度报给 World 算下一秒接触
  # → 推导视图有变化才下发 BodyState。无热环境的世界不推进身体。死亡由系统重建身体（复活后虚弱待做）。
  # 空气（温度、风速）= 身体所在格的气候（VoxelRegion.Climate，与 World 热内核同一入口、同一份区表）。
  # 报告里带局部接触组织块温度、热容与组织块-皮肤导热（面积 × 本步组织块导热 `Thermo.contact_tissue_w_per_m2_k/1`），World 用它们接内部边。
  defp body_tick(%{climate: nil} = state), do: state
  defp body_tick(%{state: nil} = state), do: state

  defp body_tick(state) do
    heat = state.body_heat
    before = state.body.status
    {px, py, pz} = state.state.position
    %{air_k: air_k, wind_mps: wind} = VoxelRegion.Climate.at(state.climate, {floor(px), floor(py), floor(pz)})

    {body, account} =
      Body.Thermo.step(state.body, 1.0, %{q_j: heat.q_j, tissue_j: heat.tissue_j, air_k: air_k, wind_mps: wind,
        immersed: heat.immersed})

    if body.status != before,
      do: character_event(state, state, :body_status, %{from: before, to: body.status, life: Body.life(body)})

    body = if body.status == :dead, do: Body.new(), else: body
    {x, y, z} = state.state.position
    profile = state.config.profile

    if authority = Map.get(state, :authority_ref),
      do: send(authority, {:body_contact, state.id, self(), %{
        feet: {x, y - profile.half_height, z}, height: 2 * profile.half_height, radius: profile.radius,
        skin_k: body.skin_k, capacity: Body.skin_capacity_j_per_k(), area: Body.params().area_m2,
        tissue_k: body.tissue_k, tissue_capacity: Body.tissue_capacity_j_per_k(),
        tissue_g: Body.params().contact_tissue_m2 * Body.Thermo.contact_tissue_w_per_m2_k(body)}})

    report = Body.report(body)

    if report.key != state.body_sent do
      reliable(state, :control, %MmoContracts.Session.BodyState{
        identity: state.identity, life: report.life, status: report.status, core_k: report.core_k,
        skin_k: report.skin_k,
        injuries: for({tag, n} <- report.injuries, do: %MmoContracts.Session.BodyInjury{tag: tag, severity: n})})
    end

    character_event(state, state, :body_state, %{life: report.life, status: body.status, core_k: body.core_k,
      skin_k: body.skin_k, injuries: Map.new(report.injuries), q_j: heat.q_j, max_contact_k: heat.max_contact_k,
      sole_k: heat.sole_k, immersed: heat.immersed, stored_j: account.stored_j, body_exchange_j: state.body_exchange_j,
      air_k: air_k, wind_mps: wind, frost_dose_k_s: body.frost_dose_k_s, reserve_j: body.reserve_j, shiver_j: account.shiver_j,
      fat_reserve_j: body.fat_reserve_j, shiver_glycogen_j: account.shiver_glycogen_j, shiver_fat_j: account.shiver_fat_j,
      tissue_k: body.tissue_k, burn_dose_s: body.burn_dose_s, wetness: body.wetness, drying_j: account.drying_j,
      heat_content_j: Body.heat_content_j(body),
      sent: report.key != state.body_sent})

    %{state | body: body, body_heat: %{q_j: 0.0, tissue_j: 0.0, max_contact_k: nil, sole_k: nil, immersed: 0.0}, body_sent: report.key}
  end

  defp highest(nil, k), do: k
  defp highest(k, nil), do: k
  defp highest(a, b), do: max(a, b)

  defp schedule_body, do: Process.send_after(self(), :body_tick, 1_000)

  defp input_start(
         %{state: value, ready: true, clock_ready: true, origin: nil, failure: nil} = state
       )
       when value != nil do
    # Hello13 固定 origin=anchor+30；旧碰撞水位先正常追上，不能签发已过期的接纳窗口。
    {_, clock_tick} = Clock.sample(state)
    origin = state.simulation_tick + 30
    lead_ticks = 8

    if origin > clock_tick + lead_ticks do
      reliable(state, :control, %Session.InputStart{
        identity: state.identity,
        anchor_tick: state.simulation_tick,
        transaction_seq: state.updates.transaction_seq,
        collision_revision: state.simulation_revision,
        state: state.state,
        origin_tick: origin,
        first_input_seq: 1,
        prediction_lead_ticks: lead_ticks
      })

      fence(state)

      character_event(state, state, :input_start, %{
        origin_tick: origin,
        clock_tick: clock_tick,
        content_version: state.content_version
      })

      publish(%{state | origin: origin, slots: InputSlots.new(state.identity, origin)})
    else
      state
    end
  end

  defp input_start(state), do: state

  defp advance(%{failure: reason} = state) when reason != nil, do: state
  defp advance(%{transfer: transfer} = state) when transfer != nil, do: state

  defp advance(state) do
    cond do
      state.state == nil or state.simulation_tick >= state.tick ->
        state

      not query_allowed?(state, state.state) ->
        fail(state, 4)

      true ->
        tick = state.simulation_tick + 1

        {slots, frame, selection} =
          if state.origin != nil and tick >= state.origin,
            do: InputSlots.take_observed(state.slots, state.tick),
            else: {state.slots, :joining_zero, :joining_zero}

        if frame == :waiting do
          state
        else
          {input, yaw} =
            if frame == :joining_zero do
              {{0.0, 0.0, 0}, state.state.yaw}
            else
              {x, z} = Movement.Codec.axes(frame)
              {{x, z, frame.jump_pressed}, frame.yaw}
            end

          {world, revision} = CollisionUpdates.at_tick(state.updates, tick)
          {x, z, jump} = input

          character_event(state, state, :input_selected, %{
            input_seq: if(frame == :joining_zero, do: nil, else: frame.input_seq),
            due_tick: tick,
            simulation_tick: tick,
            collision_revision: revision,
            axis_x: if(frame == :joining_zero, do: 0, else: frame.axis_x),
            axis_z: if(frame == :joining_zero, do: 0, else: frame.axis_z),
            yaw: yaw,
            jump_pressed: jump,
            native_axis_x: x,
            native_axis_z: z,
            selection: selection,
            lag_ticks: state.tick - tick
          })

          {us, [{_, result}]} =
            :timer.tc(fn ->
              state.updates.native.step_characters(world, state.config.profile_tuple, [
                {state.id, pod(state.state), input}
              ])
            end)

          if state.resume_pending do
            character_event(state, state, :transfer_resumed, %{
              simulation_tick: tick,
              processed_input_seq: slots.processed_input_seq,
              collision_revision: revision
            })
          end

          state = %{state | resume_pending: false}

          next =
            from_pod(
              state.updates.native.constrain_travel(
                pod(state.state),
                result,
                domain_at(state, tick).travel
              ),
              yaw
            )

          state = %{state | step_us: state.step_us + us, physics_steps: state.physics_steps + 1}

          %{
            state
            | state: next,
              slots: slots,
              simulation_tick: tick,
              simulation_revision: revision,
              updates: CollisionUpdates.retire_before(state.updates, tick)
          }
          |> stream_window()
          |> boundary()
          |> advance()
        end
    end
  end

  defp fail(state, reason), do: %{state | failure: reason}
  defp finish(%{failure: nil} = state), do: {:noreply, state}

  defp finish(state) do
    send(state.scene, {:player_failed, state.identity, self(), state.failure})
    {:stop, :normal, state}
  end

  defp active?(state),
    do: state.transfer != :prepared and state.origin != nil and state.tick >= state.origin

  defp boundary(state) do
    target =
      if state.origin != nil and not inside?(state.state.position, state.config.authority),
        do: Enum.find(state.config.neighbours, &inside?(state.state.position, &1.authority))

    if target do
      send(state.gate, {:mmo_transfer_request, state.identity, self(), target.scene_id})

      character_event(state, state, :transfer_cut, %{
        target_scene_id: target.scene_id,
        cut_tick: state.simulation_tick,
        processed_input_seq: state.slots.processed_input_seq
      })

      %{state | transfer: :requested} |> publish()
    else
      state
    end
  end

  defp emit_transactions(state, tick, events) do
    for event <- events do
      case event do
        {:window, snapshot, revision} ->
          domain = window_domain(snapshot)

          reliable(state, :voxel, %Voxel.CollisionWindow{
            identity: state.identity,
            apply_tick: tick,
            content_version: state.content_version,
            collision_revision: revision,
            transaction_seq: snapshot.transaction_seq,
            l0_min: snapshot.l0_min,
            l0_max_exclusive: snapshot.l0_max_exclusive,
            travel_min_m: elem(domain.travel, 0),
            travel_max_exclusive_m: elem(domain.travel, 1),
            regions: snapshot.regions
          })

          property_batch(state, snapshot, true, {snapshot.l0_min, snapshot.l0_max_exclusive})

        {payload, n, r, chunks, delta} ->
          reliable(state, :voxel, {:voxel_log_transaction_payload, payload})
          property_batch(state, delta.transaction, false, property_box(state, tick))

          if chunks != [],
            do:
              reliable(state, :voxel, %Voxel.CollisionApplied{
                identity: state.identity,
                collision_revision: r,
                transaction_seq: n,
                apply_tick: tick,
                changed_chunks: Enum.map(chunks, & &1.coord)
              })
      end
    end
  end

  # 全局系统功能：同一 Player 顺序发送窗口和属性；属性不改变碰撞。
  defp property_box(state, tick) do
    domain = domain_at(state, tick)
    extent = Voxel.Payload.extent() - 2
    {low, high} = domain.bounds

    {low |> Tuple.to_list() |> Enum.map(&floor(&1 / extent)) |> List.to_tuple(),
     high |> Tuple.to_list() |> Enum.map(&floor(&1 / extent)) |> List.to_tuple()}
  end

  defp property_batch(state, value, complete, {low, high}) do
    case Map.fetch(value, :property_context) do
      :error ->
        :ok

      {:ok, context} ->
        rows = Map.get(value, :property_states, [])

        epochs =
          for {{x, y, z}, epoch} <- Enum.sort(Map.get(value, :epochs, %{})),
              into: <<>>,
              do: <<x::signed-32, y::signed-32, z::signed-32, epoch::64>>

        states =
          Enum.map(rows, fn row ->
            {:ok, bytes} = Voxel.Codec.encode({:voxel_property_state, row})
            IO.iodata_to_binary(bytes)
          end)

        message = %Voxel.PropertyBatch{
          identity: state.identity,
          transaction_seq: Map.get(value, :transaction_seq, Map.get(value, :seq)),
          l0_min: low,
          l0_max_exclusive: high,
          complete: if(complete, do: 1, else: 0),
          hp_enabled: if(context.hp_enabled, do: 1, else: 0),
          digest: context.digest,
          thermal_enabled: if(context.thermal_enabled, do: 1, else: 0),
          ambient_kelvin: context.ambient_kelvin,
          epochs: epochs,
          states: states,
          protection: Voxel.Codec.encode_protection(Map.get(value, :protection, %{})),
          semblances: Voxel.Codec.encode_semblances(Map.get(value, :semblances, %{})),
          casts: Voxel.Codec.encode_casts(Map.get(value, :casts, %{}))
        }

        reliable(state, :voxel, message)

        Logger.info(
          "voxel_property_batch seq=#{message.transaction_seq} complete=#{complete} states=#{length(rows)} epochs=#{div(byte_size(epochs), 20)} body_bytes=#{byte_size(epochs) + Enum.sum(Enum.map(states, &byte_size/1))} box=#{inspect({low, high})}"
        )
    end
  end

  defp enqueue_tail(state, deltas) do
    Enum.reduce(deltas, state, fn delta, s ->
      if delta.transaction_seq <= s.queued_seq do
        s
      else
        true = delta.transaction_seq == s.queued_seq + 1

        %{
          s
          | queued_seq: delta.transaction_seq,
            updates: CollisionUpdates.enqueue(s.updates, delta, now(s))
        }
      end
    end)
  end

  defp private_ticks(state, tick) when tick <= state.tick, do: state

  defp private_ticks(state, tick) do
    next = state.tick + 1
    {updates, events} = CollisionUpdates.consume(state.updates, now(state))
    updates = CollisionUpdates.record_tick(updates, next, events)

    {state, transactions} =
      Enum.reduce(events, {%{state | updates: updates}, []}, fn
        {:delta, delta, revision, _}, {s, output} ->
          {s,
           output ++
             [
               {Voxel.Codec.encode_transaction(delta.transaction) |> IO.iodata_to_binary(),
                delta.transaction_seq, revision, delta.chunks, delta}
             ]}

        {:marker, :stream_window, snapshot}, {s, output} ->
          started = System.monotonic_time(:microsecond)
          at = System.system_time(:microsecond)
          updates = CollisionUpdates.replace_window(s.updates, snapshot, next)
          installed = System.monotonic_time(:microsecond)
          native_build_us = updates.build_us - s.updates.build_us

          s = %{
            s
            | updates: updates,
              window_pending: false,
              window_domains: [{next, window_domain(snapshot)} | s.window_domains]
          }

          character_event(s, s, :collision_window, %{
            apply_tick: next,
            l0_min: Tuple.to_list(snapshot.l0_min),
            l0_max: Tuple.to_list(snapshot.l0_max_exclusive),
            regions: length(snapshot.regions),
            chunks: length(snapshot.chunks),
            install_start_us: at,
            install_us: installed - started,
            native_build_us: native_build_us
          })

          {s, output ++ [{:window, snapshot, updates.revision}]}
      end)

    %{state | tick: next}
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

    %{
      identity: state.identity,
      entity_id: state.id,
      entity_epoch: state.epoch,
      kind: state.kind,
      player_pid: self(),
      gate_pid: state.gate,
      state: state.state,
      origin_tick: state.origin,
      simulation_tick: state.simulation_tick,
      collision_revision: state.simulation_revision,
      pending_inputs: if(state.slots, do: map_size(state.slots.pending), else: 0),
      processed_input_seq: if(state.slots, do: state.slots.processed_input_seq, else: 0),
      active: active?(state),
      published_tick: state.tick,
      physics_steps: state.physics_steps,
      step_us: state.step_us,
      rejected_inputs: state.rejected_inputs,
      old_identity: state.old_identity,
      substitutions: state.substitutions,
      mailbox: mailbox,
      retained_versions: length(state.updates.revisions)
    }
  end

  defp publish(state) do
    result = observation(state)
    send(state.scene, {:player_observation, result})
    Replication.result(state.replication, result)
    state
  end

  defp reliable(state, purpose, event),
    do: state.sink.reliable(state.gate, state.identity, purpose, event)

  defp fence(state),
    do:
      reliable(state, :voxel, %Voxel.TimelineFence{
        identity: state.identity,
        server_tick: state.tick,
        transaction_seq: state.updates.transaction_seq,
        collision_revision: state.updates.revision
      })

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
    level =
      if event in [:input_arrival, :input_selected, :input_wait] or
           (event == :region_tick and rem(state.tick, 60) != 0),
         do: :debug,
         else: :info

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
    domain = domain_at(state, state.simulation_tick + 1)
    {min, max} = domain.bounds

    inside?(value.position, domain.travel) and
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

  defp inside?(point, domain), do: SceneServer.Movement.Authority.contains?(point, domain)

  defp domain_at(%{stream: nil} = state, _), do: state.config

  defp domain_at(state, tick),
    do: state.window_domains |> Enum.find(fn {t, _} -> t <= tick end) |> elem(1)

  defp window_domain(snapshot) do
    extent = Voxel.Payload.extent() - 2
    min = snapshot.l0_min |> Tuple.to_list() |> Enum.map(&(&1 * extent / 1)) |> List.to_tuple()

    max =
      snapshot.l0_max_exclusive
      |> Tuple.to_list()
      |> Enum.map(&(&1 * extent / 1))
      |> List.to_tuple()

    %{
      bounds: {min, max},
      travel: {
        min |> Tuple.to_list() |> Enum.map(&(&1 + extent / 4)) |> List.to_tuple(),
        max |> Tuple.to_list() |> Enum.map(&(&1 - extent / 4)) |> List.to_tuple()
      }
    }
  end

  defp stream_window(%{stream: nil} = state), do: state

  defp stream_window(state) do
    {newer, older} =
      Enum.split_while(state.window_domains, fn {tick, _} -> tick > state.simulation_tick end)

    state = %{state | window_domains: newer ++ Enum.take(older, 1)}
    box = CollisionStream.box(state.state.position, state.config.streaming_radius)

    if not state.window_pending and box != state.requested_window do
      character_event(state, state, :collision_window_request, %{
        l0_min: Tuple.to_list(elem(box, 0)),
        l0_max_exclusive: Tuple.to_list(elem(box, 1)),
        server_time_us: System.system_time(:microsecond)
      })

      CollisionStream.window(state.stream, box)
      %{state | requested_window: box, window_pending: true}
    else
      state
    end
  end

  defp pod(state), do: {state.position, state.velocity, state.grounded}

  defp from_pod({position, velocity, grounded}, yaw),
    do: %Session.State{position: position, velocity: velocity, grounded: grounded, yaw: yaw}
end
