defmodule GateServer.WsConnection do
  @moduledoc """
  Per-client GenServer for one browser WebSocket session.

  This mirrors the TCP connection state machine (`waiting_auth -> authenticated -> in_scene`)
  but emits encoded payloads back to the WebSocket owner process instead of writing to a TCP socket.
  """

  use GenServer, restart: :temporary
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  alias GateServer.Replication.Egress
  alias GateServer.Voxel.{PrefabLocalTransaction, Routing, SubscriptionWorker}
  alias SceneServer.Combat.{EffectEvent, Skill}
  alias SceneServer.Movement.{InputFrame, RemoteSnapshot}
  alias SceneServer.Voxel.Field.FieldRuntime
  alias SceneServer.Voxel.{NormalBlockData, PrefabRaster, Types}

  @scene_call_timeout 15_000
  @max_voxel_subscribe_radius 4
  @prefab_owner_part_id 1
  @max_prefab_owner_object_id 0x7FFF_FFFF_FFFF_FFFF

  # 梯队3 step3.10b:per-observer 出口预算(REPL-2 / LOAD-5)。默认 256KB / 100ms 窗
  # (≈2.5MB/s/观察者)——正常对局远不饱和,Replicator 仅在病态突发下生效(D3.10-6 0 回归不变量)。
  @egress_capacity_bytes 262_144
  @egress_window_ms 100
  @egress_flush_delay_ms 20

  @doc "Starts a browser WebSocket-backed gate session."
  def start_link(owner_pid, opts \\ []) do
    GenServer.start_link(__MODULE__, owner_pid, opts)
  end

  @doc "Forward one binary frame received from the browser WebSocket."
  def receive_frame(connection_pid, payload) when is_pid(connection_pid) and is_binary(payload) do
    GenServer.cast(connection_pid, {:ws_frame, payload})
  end

  @doc "Notify the gate session that the browser WebSocket closed."
  def close(connection_pid, reason \\ :normal) when is_pid(connection_pid) do
    GenServer.cast(connection_pid, {:ws_closed, reason})
  end

  @doc "Re-routes existing voxel subscriptions after a World migration cutover."
  def rebind_voxel_subscriptions(
        connection_pid,
        logical_scene_id,
        region_selector \\ :all,
        reason \\ :manual
      )
      when is_pid(connection_pid) do
    GenServer.cast(
      connection_pid,
      {:voxel_rebind_subscriptions, logical_scene_id, region_selector, reason}
    )
  end

  @impl true
  def init(owner_pid) when is_pid(owner_pid) do
    ensure_pg_scope_started()
    :pg.join(@scope, @topic, self())

    GateServer.CliObserve.emit("ws_connection_init", %{
      connection_pid: self(),
      owner_pid: owner_pid
    })

    {:ok, voxel_worker} = SubscriptionWorker.start_link(self())

    {:ok,
     %{
       owner_pid: owner_pid,
       cid: -1,
       agent: nil,
       auth_claims: nil,
       auth_username: nil,
       auth_session_id: nil,
       scene_ref: nil,
       token: nil,
       status: :waiting_auth,
       # 阶段4 step4.3 非阻塞:per-connection 订阅 worker(体素订阅集唯一所有者 + Scene 订阅/退订
       # 唯一发起者;见 tcp_connection 同名说明)。连接不再持订阅 map。
       voxel_worker: voxel_worker,
       # 梯队3 step3.10b:per-observer 统一 Replicator 出口控制器(嵌连接 state)。
       # 预算/窗可经 app env 调(运维旋钮 + 测试注入小预算);缺省见模块属性。
       egress:
         Egress.new(
           observer_id: self(),
           capacity_bytes:
             Application.get_env(:gate_server, :egress_capacity_bytes, @egress_capacity_bytes),
           window_ms: Application.get_env(:gate_server, :egress_window_ms, @egress_window_ms)
         ),
       egress_seq: 0,
       egress_flush_scheduled: false
     }}
  end

  defp ensure_pg_scope_started do
    case :pg.start_link(@scope) do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  @impl true
  def handle_cast({:ws_frame, data}, state) do
    GateServer.CliObserve.emit("ws_receive", fn ->
      %{connection_pid: self(), bytes: byte_size(data), status: state.status}
    end)

    case GateServer.Codec.decode(data) do
      {:ok, msg} ->
        GateServer.CliObserve.emit("ws_decoded", fn ->
          %{connection_pid: self(), message: observe_message_summary(msg)}
        end)

        {:ok, new_state} = dispatch(msg, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.debug("WS codec decode rejected payload: #{inspect(reason)}")
        send_result_error(state, reason, 0)
        {:noreply, state}
    end
  end

  def handle_cast({:ws_closed, reason}, state) do
    stop_reason = normalize_close_reason(reason)

    GateServer.CliObserve.emit("ws_closed", %{
      connection_pid: self(),
      cid: state.cid,
      reason: stop_reason
    })

    {:stop, stop_reason, state}
  end

  def handle_cast({:voxel_rebind_subscriptions, logical_scene_id, region_selector, reason}, state) do
    # 阶段4:rebind(迁移 cutover,罕见)在 worker 同步执行——worker 是订阅集所有者 + Scene 操作
    # 发起者,且在 do_rebind 内自清 route 缓存(评审复审 F4)。
    result =
      SubscriptionWorker.rebind(state.voxel_worker, logical_scene_id, region_selector, reason)

    GateServer.CliObserve.emit("voxel_subscription_rebind_completed", %{
      connection_pid: self(),
      cid: state.cid,
      logical_scene_id: logical_scene_id,
      region_selector: region_selector,
      reason: reason,
      rebound_count: result.rebound_count,
      skipped_count: result.skipped_count,
      error_count: result.error_count,
      subscription_count: result.subscription_count
    })

    {:noreply, state}
  end

  def handle_cast({:player_enter, cid, location}, state) do
    send_encoded(state, {:player_enter, cid, location})
    {:noreply, state}
  end

  def handle_cast({:player_leave, cid}, state) do
    send_encoded(state, {:player_leave, cid})
    {:noreply, state}
  end

  def handle_cast({:actor_identity, cid, actor_kind, actor_name}, state) do
    send_encoded(state, {:actor_identity, cid, actor_kind, actor_name})
    {:noreply, state}
  end

  def handle_cast({:player_move, snapshot}, state) do
    snapshot = normalize_remote_snapshot(snapshot)

    GateServer.CliObserve.emit("ws_player_move_push", fn ->
      %{
        cid: snapshot.cid,
        server_tick: snapshot.server_tick,
        priority_band: snapshot.priority_band,
        priority_score: snapshot.priority_score,
        observer_distance: snapshot.observer_distance,
        delivery_interval: snapshot.delivery_interval
      }
    end)

    send_encoded(state, player_move_message(snapshot))

    {:noreply, state}
  end

  def handle_cast({:movement_ack, ack}, state) do
    send_encoded(
      state,
      {:movement_ack, ack.ack_seq, ack.auth_tick, ack.cid, ack.position, ack.velocity,
       ack.acceleration, ack.movement_mode, ack.correction_flags, ack.fixed_dt_ms, ack.ground_z}
    )

    {:noreply, state}
  end

  def handle_cast({:chat_message, cid, username, text}, state) do
    send_encoded(state, {:chat_message, cid, username, text})
    {:noreply, state}
  end

  def handle_cast({:skill_event, cid, skill_id, location}, state) do
    send_encoded(state, {:skill_event, cid, skill_id, location})
    {:noreply, state}
  end

  def handle_cast({:player_state, cid, hp, max_hp, alive}, state) do
    send_encoded(state, {:player_state, cid, hp, max_hp, alive})
    {:noreply, state}
  end

  def handle_cast(
        {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location},
        state
      ) do
    send_encoded(
      state,
      {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
    )

    {:noreply, state}
  end

  def handle_cast({:effect_event, %EffectEvent{} = effect_event}, state) do
    send_encoded(
      state,
      {:effect_event, effect_event.source_cid, effect_event.skill_id, effect_event.cue_kind,
       effect_event.origin, effect_event.target_cid, effect_event.target_position,
       effect_event.radius, effect_event.duration_ms}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:voxel_chunk_snapshot_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit(
      "ws_voxel_chunk_snapshot_forwarded",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload)
        },
        voxel_snapshot_observe_fields(payload)
      )
    )

    {:noreply, replicate(state, :voxel_chunk_snapshot_payload, payload)}
  end

  def handle_info({:voxel_chunk_delta_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit(
      "ws_voxel_chunk_delta_forwarded",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload)
        },
        voxel_delta_observe_fields(payload)
      )
    )

    {:noreply, replicate(state, :voxel_chunk_delta_payload, payload)}
  end

  def handle_info({:voxel_chunk_invalidate_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_chunk_invalidate_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload)
    })

    # 阶段4 评审 F5:把受影响 chunk 从 worker 订阅集移除(见 tcp_connection 同名),使客户端重订
    # 能重建 scene 侧订阅;无法解码退化为清空整张 route 缓存。
    invalidate_voxel_subscription(state.voxel_worker, payload)
    {:noreply, replicate(state, :voxel_chunk_invalidate_payload, payload)}
  end

  # 阶段4 step4.3:订阅 worker 路由/订阅失败回报(首失败一帧 0x68)。成功路径无回报——快照即 ACK,
  # 经 fan-out 直达本连接;订阅集只存在于 worker(单一所有者)。
  def handle_info({:voxel_subscribe_failed, ctx, reason}, state) do
    GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_error", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: ctx.request_id,
      chunk_coord: Map.get(ctx, :chunk_coord),
      reason: reason
    })

    send_encoded(state, voxel_result_error(ctx, reason))
    {:noreply, state}
  end

  # 梯队3 step3.10b:Replicator 自限定 backlog flush——仅在出口压力憋帧后激活(正常负载不调度)。
  def handle_info(:replicator_flush, state) do
    {:noreply, drain_egress(%{state | egress_flush_scheduled: false})}
  end

  # Phase 4-bis (D7):forward 0x6C ObjectStateDelta from ChunkProcess fan-out
  # to the WebSocket frame stream. ObjectRegistry encoded the binary once;
  # ChunkProcess cast it into our mailbox via `send/2`;we just prefix the
  # opcode (Codec) and ship a binary frame.
  def handle_info({:voxel_object_state_delta_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_object_state_delta_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload)
    })

    send_encoded(state, {:voxel_object_state_delta_payload, payload})
    {:noreply, state}
  end

  # Phase 6: forward 0x73 FieldRegionSnapshot from ChunkProcess fan-out.
  # Payload already contains the opcode byte — send raw, do NOT go through Codec.
  def handle_info({:voxel_field_region_snapshot_payload, payload}, state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_field_region_snapshot_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload)
    })

    send(state.owner_pid, {:gate_ws_send, payload})
    {:noreply, state}
  end

  # Phase 6: forward 0x74 FieldRegionDestroyed from ChunkProcess fan-out.
  # Payload already contains the opcode byte — send raw, do NOT go through Codec.
  def handle_info({:voxel_field_region_destroyed_payload, payload}, state)
      when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_field_region_destroyed_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload)
    })

    send(state.owner_pid, {:gate_ws_send, payload})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # 阶段4:voxel 订阅集在 worker(随本连接退出而停;Scene 侧 subscriber=本连接 pid,
    # ChunkProcess monitor 本连接 down 即自动摘除)——无需在此显式退订。
    cleanup_scene(state.scene_ref)
    :ok
  end

  defp dispatch(
         {:movement_input, frame_params},
         %{status: :in_scene, scene_ref: spid} = state
       ) do
    frame = build_input_frame(frame_params)

    case accept_movement_input(spid, frame) do
      {:ok, ack} -> GenServer.cast(self(), {:movement_ack, ack})
      :accepted -> :ok
      {:error, reason} -> send_result_error(state, reason, frame.seq)
    end

    {:ok, state}
  end

  defp dispatch({:movement_input, frame_params}, state) do
    frame = build_input_frame(frame_params)
    send_result_error(state, :invalid_state, frame.seq)
    {:ok, state}
  end

  defp dispatch(
         {:enter_scene, cid, request_id},
         %{status: :authenticated, auth_claims: claims} = state
       ) do
    timestamp = :os.system_time(:millisecond)

    with :ok <- authorize_cid(claims, cid),
         {:ok, character} <- fetch_authorized_character(claims, cid),
         {:ok, scene_node} <- fetch_scene_node(),
         {:ok, ppid} <- add_player(scene_node, cid, timestamp, build_character_profile(character)),
         {:ok, {x, y, z}} <- fetch_player_location(ppid),
         {:ok, expected_seq} <- fetch_next_input_seq(ppid) do
      send_encoded(state, {:enter_scene_result, :ok, request_id, {x, y, z}, expected_seq})

      {:ok,
       %{
         state
         | scene_ref: ppid,
           cid: cid,
           status: :in_scene,
           agent: with_active_cid(state.agent, cid)
       }}
    else
      {:error, reason} ->
        send_enter_scene_error(state, reason, request_id)
        {:ok, state}
    end
  end

  defp dispatch({:enter_scene, _cid, request_id}, state) do
    send_enter_scene_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(
         {:time_sync, request_id, client_send_ts},
         %{status: status} = state
       )
       when status in [:authenticated, :in_scene] do
    server_recv_ts = :os.system_time(:millisecond)
    server_send_ts = :os.system_time(:millisecond)

    send_encoded(
      state,
      {:time_sync_reply, request_id, client_send_ts, server_recv_ts, server_send_ts}
    )

    {:ok, state}
  end

  defp dispatch({:time_sync, request_id, _client_send_ts}, state) do
    send_result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch({:fast_lane_request, request_id}, state) do
    send_encoded(state, {:fast_lane_result, :error, request_id})
    {:ok, state}
  end

  defp dispatch({:heartbeat, _timestamp}, state) do
    send_encoded(state, {:heartbeat_reply, :os.system_time(:millisecond)})
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_subscribe, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk,
      radius: request.radius_l_inf,
      known_count: request |> Map.get(:known, []) |> length(),
      known_sample: voxel_known_sample(request)
    })

    case validate_voxel_subscribe_radius(request.radius_l_inf) do
      :ok ->
        {:ok, dispatch_voxel_subscribe(request, state)}

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          reason: reason
        })

        send_encoded(state, voxel_result_error(request, reason))
        {:ok, state}
    end
  end

  defp dispatch({:voxel_chunk_subscribe, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_unsubscribe, request}, %{status: :in_scene} = state) do
    SubscriptionWorker.unsubscribe(state.voxel_worker, request.logical_scene_id, request.chunks)

    GateServer.CliObserve.emit("ws_voxel_chunk_unsubscribe_ok", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      requested_count: length(request.chunks)
    })

    send_encoded(state, {:result, :ok, request.request_id})
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_unsubscribe, request}, state) do
    send_result_error(state, :invalid_state, request.request_id)
    {:ok, state}
  end

  # DEPRECATED for client-side direct edit; protocol §13.6 / §13.6.1.
  # Use VoxelEditIntent (0x70) for typed client edits. This handler stays for
  # the skill/tool-system flow (and existing client-side wiring) until 1c
  # removes it.
  defp dispatch({:voxel_impact_intent, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_impact_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      source_skill_id: request.source_skill_id,
      target_world_micro: request.target_world_micro,
      impact_kind: request.impact_kind
    })

    case apply_voxel_impact_intent(request, state) do
      {:ok, result} ->
        GateServer.CliObserve.emit("ws_voxel_impact_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: result.chunk_coord,
          chunk_version: result.chunk_version,
          macro: result.macro
        })

        send_encoded(state, voxel_result_ok(request, result))

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_impact_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(state, voxel_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_impact_intent, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  # VoxelEditIntent (0x70) — typed client edit channel; protocol §13.6.1.
  # Phase 1c routing: dispatch the typed request to ChunkDirectory.apply_intent
  # via the standard World map-ledger lease path, then reply with the
  # `VoxelIntentResult` (0x68) frame.
  defp dispatch({:voxel_edit_intent, request}, %{status: :in_scene} = state) do
    emit_voxel_edit_intent_received(request, state)

    case apply_voxel_edit_intent(request, state) do
      {:ok, result} ->
        GateServer.CliObserve.emit("ws_voxel_edit_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: result.chunk_coord,
          chunk_version: result.chunk_version,
          macro: result.macro,
          operation: result.operation
        })

        send_encoded(state, voxel_edit_intent_result_ok(request, result))

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_edit_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(state, voxel_edit_intent_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_edit_intent, request}, state) do
    GateServer.CliObserve.emit("ws_voxel_edit_intent_dropped_invalid_state", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      status: state.status
    })

    send_encoded(state, voxel_edit_intent_result_error(request, :invalid_state))

    {:ok, state}
  end

  defp dispatch({:voxel_field_conduct_intent, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_field_conduct_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      source_world_macro: request.source_world_macro,
      target_world_macro: request.target_world_macro,
      conduction_mode: request.conduction_mode
    })

    case apply_voxel_field_conduct_intent(request, state) do
      {:ok, summary} ->
        GateServer.CliObserve.emit("ws_voxel_field_conduct_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          region_id: Map.get(summary, :region_id),
          field_region_created: Map.get(summary, :field_region_created),
          conduction_mode: Map.get(summary, :conduction_mode, request.conduction_mode)
        })

        send_encoded(state, voxel_field_conduct_result_ok(request, summary))

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_field_conduct_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: inspect(reason)
        })

        send_encoded(state, voxel_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_field_conduct_intent, request}, state) do
    GateServer.CliObserve.emit("ws_voxel_field_conduct_intent_dropped_invalid_state", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      status: state.status
    })

    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_build_reservation_intent, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_build_reservation_intent_received", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        client_intent_seq: request.client_intent_seq,
        logical_scene_id: request.logical_scene_id,
        parcel_id: request.parcel_id,
        ttl_ms: request.ttl_ms
      }
    end)

    send_encoded(state, voxel_intent_stub_accepted(request))
    {:ok, state}
  end

  defp dispatch({:voxel_build_reservation_intent, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  # Real `0x67 PrefabPlaceIntent` dispatch.
  #
  # The handler resolves `blueprint_id` + anchor through
  # `SceneServer.Voxel.PrefabRaster`, then loops the produced macro-cell list
  # cell-by-cell through `WorldServer.Voxel.MapLedger.route_chunk_with_lease/3`
  # and `SceneServer.Voxel.ChunkDirectory.apply_intent/2`, the exact same path
  # as `0x64 VoxelImpactIntent`. Each successful apply already pushes a
  # `ChunkDelta` to existing subscribers via `ChunkProcess`, so the
  # block-by-block reveal happens automatically.
  #
  # v1 deliberately does not provide cross-chunk atomicity: if the first cell
  # is accepted and a later cell is rejected (lease lost mid-prefab, world
  # routing flaps, etc.) the partial writes already persisted are NOT rolled
  # back. The dispatch records the partial-write summary in observe events
  # and returns `:rejected` to the client. v2 will replace this with a
  # `BuildTransactionApplier`-style two-phase commit.
  defp dispatch({:voxel_prefab_place_intent, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_prefab_place_intent_received", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        client_intent_seq: request.client_intent_seq,
        logical_scene_id: request.logical_scene_id,
        parcel_id: request.parcel_id,
        blueprint_id: request.blueprint_id,
        blueprint_version: request.blueprint_version,
        rotation: request.rotation
      }
    end)

    case apply_voxel_prefab_place_intent(request, state) do
      {:ok, summary} ->
        GateServer.CliObserve.emit("ws_voxel_prefab_place_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          blueprint_id: request.blueprint_id,
          cell_count: summary.cell_count,
          chunk_count: summary.chunk_count,
          max_chunk_version: summary.max_chunk_version
        })

        send_encoded(state, voxel_prefab_result_ok(request, summary))

      {:error, %{reason: reason} = failure} ->
        GateServer.CliObserve.emit("ws_voxel_prefab_place_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          blueprint_id: request.blueprint_id,
          reason: reason,
          applied_cell_count: failure.applied_cell_count,
          total_cell_count: failure.total_cell_count
        })

        send_encoded(state, voxel_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_prefab_place_intent, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_debug_probe, %{request_id: request_id, command: command}}, state) do
    GateServer.CliObserve.emit("ws_voxel_debug_probe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      command: command,
      status: state.status
    })

    {result, next_state} = handle_voxel_debug_command(command, state)

    send_encoded(state, {:voxel_debug_probe, %{request_id: request_id, result: result}})

    {:ok, next_state}
  end

  defp dispatch(
         {:auth_request, username, code, request_id},
         %{status: :waiting_auth} = state
       ) do
    with {:ok, claims} <- verify_token(code),
         :ok <- validate_username_claim(claims, username) do
      auth_context = build_auth_context(username, code, claims)
      send_encoded(state, {:result, :ok, request_id})

      {:ok,
       %{
         state
         | agent: auth_context,
           auth_claims: claims,
           auth_username: username,
           auth_session_id: Map.get(auth_context, "session_id"),
           token: code,
           status: :authenticated
       }}
    else
      {:error, reason} ->
        send_result_error(state, reason, request_id)
        {:ok, state}
    end
  end

  defp dispatch({:auth_request, _username, _code, request_id}, state) do
    send_result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(_msg, state) do
    send_result_error(state, :unknown_message, 0)
    {:ok, state}
  end

  defp send_encoded(state, message) do
    # 防 MatchError 崩连接进程(同 tcp_connection):encode 命中 unknown_message catchall 时
    # 只记日志 + 丢弃,不 raise。
    case GateServer.Codec.encode(message) do
      {:ok, iodata} ->
        send(state.owner_pid, {:gate_ws_send, IO.iodata_to_binary(iodata)})

      {:error, reason} ->
        Logger.warning("gate(ws): dropped unencodable outbound message: #{inspect(reason)}")

        GateServer.CliObserve.emit("gate_outbound_encode_failed", %{
          transport: :ws,
          reason: reason
        })

        :ok
    end
  end

  # 梯队3 step3.10b:把一帧客户端可见状态交给 per-observer 统一 Replicator(REPL-2),
  # 立即排空到出口预算上限;若仍有憋帧则调度自限定 flush。cell_id 用连接级单调 frame seq
  # (非 nil、唯一 → live FIFO 无合并;per-cell 聚合待 scene 填 cell_id,3.10c)。
  defp replicate(state, forward_tag, payload) do
    seq = state.egress_seq + 1

    egress =
      Egress.enqueue_payload(state.egress, forward_tag, {:seq, seq}, payload, snapshot_seq: seq)

    drain_egress(%{state | egress: egress, egress_seq: seq})
  end

  defp drain_egress(state) do
    {outbound, egress} = Egress.flush(state.egress, System.monotonic_time(:millisecond))
    Enum.each(outbound, fn {tag, binary} -> dispatch_replicated(state, tag, binary) end)

    state
    |> Map.put(:egress, egress)
    |> report_replicator_resync()
    |> maybe_schedule_egress_flush()
  end

  # 控制/状态/bulk 帧的实际传输:chunk 类经 Codec 包 opcode;field 类二进制已含 opcode 裸发。
  defp dispatch_replicated(state, tag, binary)
       when tag in [:voxel_field_region_snapshot_payload, :voxel_field_region_destroyed_payload] do
    send(state.owner_pid, {:gate_ws_send, binary})
  end

  defp dispatch_replicated(state, tag, binary) do
    send_encoded(state, {tag, binary})
  end

  # delta 链因出口溢出被截断时显式上报(非静默);客户端据 base 不匹配重取快照。
  defp report_replicator_resync(state) do
    cells = Egress.resync_cells(state.egress)

    if MapSet.size(cells) > 0 do
      GateServer.CliObserve.emit("ws_replicator_resync_needed", %{
        connection_pid: self(),
        cid: state.cid,
        resync_count: MapSet.size(cells)
      })

      %{state | egress: Egress.clear_resync_cells(state.egress)}
    else
      state
    end
  end

  defp maybe_schedule_egress_flush(%{egress_flush_scheduled: true} = state), do: state

  defp maybe_schedule_egress_flush(state) do
    if Egress.pending?(state.egress) do
      Process.send_after(self(), :replicator_flush, @egress_flush_delay_ms)
      %{state | egress_flush_scheduled: true}
    else
      state
    end
  end

  defp verify_token(token) do
    case fetch_auth_node() do
      {:error, _reason} = error ->
        error

      {:ok, auth_node} ->
        case :rpc.call(auth_node, AuthServer.AuthWorker, :verify_token, [token]) do
          {:ok, claims} when is_map(claims) -> {:ok, claims}
          {:error, :mismatch} -> {:error, :mismatch}
          {:badrpc, _reason} -> {:error, :auth_unavailable}
          _ -> {:error, :server_error}
        end
    end
  end

  defp fetch_auth_node do
    case safe_call(GateServer.Interface, :auth_server) do
      {:ok, nil} -> {:error, :auth_unavailable}
      {:ok, auth_node} -> {:ok, auth_node}
      {:error, _reason} -> {:error, :auth_unavailable}
    end
  end

  defp fetch_scene_node do
    case safe_call(GateServer.Interface, :scene_server) do
      {:ok, nil} -> {:error, :scene_unavailable}
      {:ok, scene_node} -> {:ok, scene_node}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp fetch_world_node do
    case safe_call(GateServer.Interface, :world_server) do
      {:ok, nil} -> {:error, :world_unavailable}
      {:ok, world_node} -> {:ok, world_node}
      {:error, _reason} -> {:error, :world_unavailable}
    end
  end

  defp add_player(scene_node, cid, timestamp, character_profile) do
    case safe_call(
           {SceneServer.PlayerManager, scene_node},
           {:add_player, cid, self(), timestamp, character_profile},
           @scene_call_timeout
         ) do
      {:ok, {:ok, ppid}} -> {:ok, ppid}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp fetch_player_location(player_pid) do
    case safe_call(player_pid, :get_location, @scene_call_timeout) do
      {:ok, {:ok, location}} -> {:ok, location}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  # See tcp_connection.fetch_next_input_seq for the audit B-S1 / B-SRV1
  # rationale.
  defp fetch_next_input_seq(player_pid) do
    case safe_call(player_pid, :get_next_input_seq, @scene_call_timeout) do
      {:ok, {:ok, seq}} -> {:ok, seq}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp cleanup_scene(nil), do: :ok
  defp cleanup_scene(scene_ref), do: safe_call(scene_ref, :exit)

  defp authorize_cid(nil, _cid), do: {:error, :invalid_state}

  defp authorize_cid(claims, cid) do
    case apply(AuthServer.AuthWorker, :validate_cid, [claims, cid]) do
      :ok -> :ok
      {:error, :cid_mismatch} -> {:error, :cid_mismatch}
      {:error, _reason} -> {:error, :server_error}
    end
  end

  defp fetch_authorized_character(claims, cid) do
    with {:ok, auth_node} <- fetch_auth_node() do
      case :rpc.call(auth_node, AuthServer.AuthWorker, :fetch_authorized_character, [claims, cid]) do
        {:ok, character} when is_map(character) -> {:ok, character}
        {:error, :account_not_found} -> {:error, :cid_mismatch}
        {:error, :cid_mismatch} -> {:error, :cid_mismatch}
        {:error, :data_service_unavailable} -> {:error, :auth_unavailable}
        {:badrpc, _reason} -> {:error, :auth_unavailable}
        _ -> {:error, :server_error}
      end
    end
  end

  defp build_character_profile(character) when is_map(character) do
    %{
      cid: Map.get(character, :id) || Map.get(character, "id"),
      name:
        Map.get(character, :name) || Map.get(character, "name") ||
          "character-#{Map.get(character, :id) || Map.get(character, "id")}",
      position:
        normalize_position(Map.get(character, :position) || Map.get(character, "position"))
    }
  end

  defp build_character_profile(_character),
    do: %{name: "unknown", position: {750.0, 750.0, 185.0}}

  # Default spawn over the DevSeed 16×16 stone platform on chunk (0,0,0).
  # Movement world coords use server Z as vertical. The browser maps this spawn
  # to x=750,y=100,z=750, above DevSeed's voxel y=0 platform centered at x/z =
  # 750 in renderer units.
  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], 750.0)
    y = map_float(position, ["y", :y], 750.0)
    z = map_float(position, ["z", :z], 185.0)
    {x, y, z}
  end

  defp normalize_position(_position), do: {750.0, 750.0, 185.0}

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

  defp validate_username_claim(claims, username) do
    apply(AuthServer.AuthWorker, :validate_username, [claims, username])
  end

  defp safe_call(server, message, timeout \\ @scene_call_timeout)
  defp safe_call(nil, _message, _timeout), do: {:error, :unavailable}

  defp safe_call(server, message, timeout) do
    try do
      {:ok, GenServer.call(server, message, timeout)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp send_result_error(state, _reason, request_id) do
    send_encoded(state, {:result, :error, request_id})
  end

  defp send_enter_scene_error(state, _reason, request_id) do
    send_encoded(state, {:enter_scene_result, :error, request_id})
  end

  defp build_auth_context(username, token, claims) do
    %{
      "username" => username,
      "token" => token,
      "session_id" => Map.get(claims, "session_id") || Map.get(claims, :session_id),
      "source" => Map.get(claims, "source") || Map.get(claims, :source),
      "claims" => claims
    }
  end

  defp with_active_cid(auth_context, cid) when is_map(auth_context) do
    Map.put(auth_context, "active_cid", cid)
  end

  defp with_active_cid(auth_context, _cid), do: auth_context

  defp accept_movement_input(spid, frame) do
    case safe_call(spid, {:movement_input, frame}) do
      {:ok, {:ok, :accepted}} -> :accepted
      {:ok, {:ok, ack}} -> {:ok, ack}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      {:ok, _other} -> {:error, :scene_unavailable}
    end
  end

  # 阶段4 step4.1:路由实现移入共享 `GateServer.Voxel.Routing`(tcp/ws 去镜像)。订阅路径走
  # worker 的 cache-first 路由;此处保留给编辑 / 撞击 / 表面元件 / 场 / rebind 等非订阅热路径。
  defp route_voxel_chunk(logical_scene_id, chunk_coord),
    do: Routing.route_chunk(logical_scene_id, chunk_coord)

  defp route_voxel_chunks(logical_scene_id, chunk_coords),
    do: Routing.route_chunks(logical_scene_id, chunk_coords)

  defp apply_voxel_impact_intent(request, state) do
    with :ok <- authorize_voxel_impact_intent(request, state),
         {:ok, target} <- voxel_impact_target(request),
         {:ok, route} <- route_voxel_chunk(request.logical_scene_id, target.chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      GateServer.CliObserve.emit("voxel_impact_intent_routed", %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: target.chunk_coord,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        scene_node: scene_node
      })

      attrs =
        %{
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: target.chunk_coord,
          lease: lease,
          macro: target.local_macro
        }
        |> Map.merge(voxel_impact_op_attrs(request))

      case safe_call(
             {SceneServer.Voxel.ChunkDirectory, scene_node},
             {:apply_intent, attrs},
             @scene_call_timeout
           ) do
        {:ok, {:ok, reply}} ->
          {:ok, Map.merge(reply, %{macro: target.local_macro})}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, _other} ->
          {:error, :scene_unavailable}

        {:error, _reason} ->
          {:error, :scene_unavailable}
      end
    end
  end

  defp fetch_scene_node_for_route(route), do: Routing.scene_node_for_route(route)

  defp authorize_voxel_impact_intent(request, state) do
    cond do
      not is_integer(state.cid) or state.cid <= 0 ->
        {:error, :cid_mismatch}

      true ->
        case Skill.fetch(request.source_skill_id) do
          {:ok, _skill} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp voxel_impact_target(%{target_world_micro: {wx, wy, wz}}) do
    micro_resolution = Types.micro_resolution()

    world_macro = {
      Types.floor_div(wx, micro_resolution),
      Types.floor_div(wy, micro_resolution),
      Types.floor_div(wz, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    {:ok, %{chunk_coord: chunk_coord, local_macro: local_macro}}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_target_world_micro}
  end

  defp voxel_impact_block(request) do
    NormalBlockData.new(request.impact_kind,
      health: 100,
      state_flags: request.source_skill_id
    )
  end

  # Wire convention: `impact_kind == 0` is the break sentinel — the cell
  # gets cleared back to empty mode (delta_kind 0 CellEmpty on the wire).
  # Any non-zero `impact_kind` is treated as a `material_id` for a put-solid
  # write (delta_kind 1 CellSolid).
  defp voxel_impact_op_attrs(%{impact_kind: 0}), do: %{operation: :break_block}

  defp voxel_impact_op_attrs(request) do
    %{operation: :put_solid_block, block: voxel_impact_block(request)}
  end

  defp emit_voxel_edit_intent_received(request, state) do
    GateServer.CliObserve.emit("ws_voxel_edit_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      action: request.action,
      target_granularity: request.target_granularity,
      target_world_micro: request.target_world_micro,
      face_normal: request.face_normal,
      material_id: request.material_id,
      blueprint_ref: request.blueprint_ref,
      object_ref: request.object_ref,
      part_ref: request.part_ref,
      attribute_patch_ref: request.attribute_patch_ref,
      expected_chunk_version: request.expected_chunk_version,
      expected_cell_hash: request.expected_cell_hash,
      client_hint_hash: request.client_hint_hash
    })
  end

  defp apply_voxel_edit_intent(request, state) do
    with :ok <- authorize_voxel_edit_intent(state),
         {:ok, op} <- voxel_edit_intent_op(request),
         {:ok, target} <- voxel_edit_intent_target(request, op),
         {:ok, route} <- route_voxel_chunk(request.logical_scene_id, target.chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      GateServer.CliObserve.emit("voxel_edit_intent_routed", %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        action: request.action,
        target_granularity: request.target_granularity,
        operation: op.operation,
        chunk_coord: target.chunk_coord,
        local_macro: target.local_macro,
        adjusted_world_micro: target.adjusted_world_micro,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        scene_node: scene_node
      })

      command_id =
        GateServer.VoxelCommandId.edit(
          request.logical_scene_id,
          state.cid,
          request.client_intent_seq
        )

      attrs = build_voxel_edit_intent_attrs(request, op, target, lease, command_id)

      case safe_call(
             {SceneServer.Voxel.ChunkDirectory, scene_node},
             {:apply_intent, attrs},
             @scene_call_timeout
           ) do
        {:ok, {:ok, reply}} ->
          {:ok, Map.merge(reply, %{macro: target.local_macro, operation: op.operation})}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, _other} ->
          {:error, :scene_unavailable}

        {:error, _reason} ->
          {:error, :scene_unavailable}
      end
    end
  end

  defp authorize_voxel_edit_intent(state) do
    if is_integer(state.cid) and state.cid > 0 do
      :ok
    else
      {:error, :cid_mismatch}
    end
  end

  defp apply_voxel_field_conduct_intent(request, state) do
    with :ok <- authorize_voxel_edit_intent(state),
         {:ok, source_chunk_coord} <- field_conduct_source_chunk(request),
         {:ok, route} <- route_voxel_chunk(request.logical_scene_id, source_chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      attrs =
        request
        |> Map.take([
          :logical_scene_id,
          :source_world_macro,
          :target_world_macro,
          :source_potential,
          :max_ticks,
          :conduction_mode,
          :output_mode,
          :voltage,
          :current_limit_amps,
          :frequency_hz,
          :load_current_amps,
          :energy_budget_joules
        ])
        |> Map.put(:owner_ref, {:ws_field_conduct, state.cid, request.client_intent_seq})

      case :rpc.call(
             scene_node,
             FieldRuntime,
             :ensure_conduction_path,
             [attrs],
             @scene_call_timeout
           ) do
        {:ok, summary} -> {:ok, summary}
        {:error, reason} -> {:error, reason}
        {:badrpc, reason} -> {:error, {:scene_unavailable, reason}}
        other -> {:error, {:unexpected_field_conduct_result, other}}
      end
    end
  end

  defp field_conduct_source_chunk(%{source_world_macro: world_macro}) do
    {chunk_coord, _local_macro} = Types.chunk_and_local_macro!(world_macro)
    {:ok, chunk_coord}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_source_world_macro}
  end

  # Decision 3 / Phase 1c: action × target_granularity → Scene operation.
  # ObjectPart granularity is rejected for the supported actions; Damage /
  # Replace / AttributePatch are rejected wholesale until the Phase 5 attribute
  # catalog work lands.
  defp voxel_edit_intent_op(%{action: action}) when action in [2, 3, 4] do
    {:error, :action_not_implemented}
  end

  defp voxel_edit_intent_op(%{action: action, target_granularity: 2}) when action in [0, 1] do
    {:error, :granularity_object_part_not_implemented}
  end

  defp voxel_edit_intent_op(%{action: 0, target_granularity: 0} = request) do
    {:ok, %{operation: :put_solid_block, block: voxel_edit_intent_block(request)}}
  end

  defp voxel_edit_intent_op(%{action: 0, target_granularity: 1} = request) do
    case voxel_edit_intent_micro_layer(request) do
      {:ok, micro_layer} ->
        {:ok, %{operation: :put_micro_block, micro_layer: micro_layer}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp voxel_edit_intent_op(%{action: 1, target_granularity: 0}) do
    {:ok, %{operation: :break_block}}
  end

  defp voxel_edit_intent_op(%{action: 1, target_granularity: 1}) do
    {:ok, %{operation: :clear_micro_block}}
  end

  defp voxel_edit_intent_op(_request), do: {:error, :invalid_voxel_edit_intent}

  defp voxel_edit_intent_block(request) do
    NormalBlockData.new(request.material_id,
      attribute_set_ref: request.attribute_patch_ref,
      state_flags: voxel_orientation_state_flags(request.material_id, request.face_normal)
    )
  end

  # C4b:二极管/三极管放置时由玩家瞄准的 face_normal 推出 per-cell 导通轴写进 state_flags
  # bits[0..2](二极管=anode→cathode 轴;三极管=collector-emitter 主轴,base 面默认取首个非主轴面)。
  # 其它材料 → 0(无朝向)。MVP:无 0x70 wire 变体,服务端由 face_normal 推断(决策 ④)。
  defp voxel_orientation_state_flags(material_id, face_normal) do
    if SceneServer.Voxel.MaterialCatalog.diode_material?(material_id) or
         SceneServer.Voxel.MaterialCatalog.transistor_material?(material_id) do
      axis_code_from_face_normal(face_normal)
    else
      0
    end
  end

  defp axis_code_from_face_normal({fnx, fny, fnz}) do
    cond do
      fnx > 0 -> 1
      fnx < 0 -> 2
      fny > 0 -> 3
      fny < 0 -> 4
      fnz > 0 -> 5
      fnz < 0 -> 6
      # 退化法向 → +x 默认(惰性安全)。
      true -> 1
    end
  end

  defp voxel_edit_intent_micro_layer(request) do
    with {:ok, owner_object_id} <- voxel_edit_owner_object_id(request.object_ref) do
      {:ok,
       %{
         material_id: request.material_id,
         attribute_set_ref: request.attribute_patch_ref,
         owner_object_id: owner_object_id,
         owner_part_id: request.part_ref
       }}
    end
  end

  # owner_object_id is a u63 (`MicroLayer.@type`); the wire field is u64. The
  # high bit is reserved for future use, so reject values that don't fit.
  defp voxel_edit_owner_object_id(value)
       when is_integer(value) and value >= 0 and value <= 0x7FFF_FFFF_FFFF_FFFF,
       do: {:ok, value}

  defp voxel_edit_owner_object_id(_value), do: {:error, :invalid_object_ref}

  # Decision 6 / Phase 1c: Place actions consume `face_normal` here at the Gate
  # by offsetting `target_world_micro` by one micro slot in the direction of
  # the hit face. Break actions ignore `face_normal` — the resolved cell is
  # the one the client clicked.
  defp voxel_edit_intent_target(request, %{operation: operation}) do
    {wx, wy, wz} = request.target_world_micro
    {fnx, fny, fnz} = request.face_normal

    {ax, ay, az} =
      case operation do
        :put_solid_block -> {wx + fnx, wy + fny, wz + fnz}
        :put_micro_block -> {wx + fnx, wy + fny, wz + fnz}
        _other -> {wx, wy, wz}
      end

    micro_resolution = Types.micro_resolution()

    world_macro = {
      Types.floor_div(ax, micro_resolution),
      Types.floor_div(ay, micro_resolution),
      Types.floor_div(az, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    local_micro = {
      Types.floor_mod(ax, micro_resolution),
      Types.floor_mod(ay, micro_resolution),
      Types.floor_mod(az, micro_resolution)
    }

    {:ok,
     %{
       chunk_coord: chunk_coord,
       local_macro: local_macro,
       local_micro: local_micro,
       adjusted_world_micro: {ax, ay, az}
     }}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_target_world_micro}
  end

  defp build_voxel_edit_intent_attrs(request, op, target, lease, command_id) do
    base = %{
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      chunk_coord: target.chunk_coord,
      lease: lease,
      operation: op.operation,
      macro: target.local_macro,
      expected_chunk_version: request.expected_chunk_version,
      expected_cell_hash: request.expected_cell_hash,
      # AUTH-4(step1.5b-1):客户端命令幂等键,scene/store 同事务 record_once。
      command_id: command_id
    }

    base
    |> maybe_put(:block, Map.get(op, :block))
    |> maybe_put(:micro_layer, Map.get(op, :micro_layer))
    |> maybe_put_micro_slot(op, target)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_micro_slot(map, %{operation: op}, target)
       when op in [:put_micro_block, :clear_micro_block] do
    Map.put(map, :micro_slot, Types.micro_index!(target.local_micro))
  end

  defp maybe_put_micro_slot(map, _op, _target), do: map

  # `:stale_chunk_version` and `:stale_cell_hash` come back from
  # `ChunkProcess.validate_intent_preconditions/2` and map to the protocol
  # `Stale` (3) `VoxelIntentResult` code. Everything else is a generic
  # `Rejected` (2). Successful applies use `:accepted` (0).
  defp voxel_edit_intent_result_code(:stale_chunk_version), do: :stale
  defp voxel_edit_intent_result_code(:stale_cell_hash), do: :stale
  defp voxel_edit_intent_result_code(_reason), do: :rejected

  defp voxel_edit_intent_result_error(request, reason) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: voxel_edit_intent_result_code(reason),
       result_ref: 0,
       authoritative: [],
       reason: inspect(reason)
     }}
  end

  defp voxel_edit_intent_result_ok(request, result) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: result.chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  # AUTH-4(step1.5b-2):prefab 是多步 / 跨节点命令(分配 object_id 序列 + 跨 chunk 事务),
  # 无单一事务可包裹,故用 CommandLog idempotency-key:claim(派生稳定 command_id,在分配
  # object_id 前认领)→ 工作 → 成功 confirm(缓存结果摘要)/ 失败 release(放行重试)。重复命令
  # 直接返回缓存摘要,**不重新分配 object_id、不重复产生 durable 资产**。
  defp apply_voxel_prefab_place_intent(request, state) do
    case authorize_voxel_prefab_place_intent(state) do
      :ok ->
        command_id =
          GateServer.VoxelCommandId.prefab(
            request.logical_scene_id,
            state.cid,
            request.client_intent_seq
          )

        apply_prefab_with_idempotency(command_id, request, state)

      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: 0}}
    end
  end

  defp apply_prefab_with_idempotency(command_id, request, state) do
    case DataService.Voxel.CommandLog.claim(command_id, request.logical_scene_id) do
      :fresh ->
        case do_apply_voxel_prefab_place_intent(request, state) do
          {:ok, summary} ->
            DataService.Voxel.CommandLog.confirm(
              command_id,
              GateServer.VoxelCommandId.encode_prefab_summary(summary)
            )

            {:ok, summary}

          {:error, _reason} = error ->
            DataService.Voxel.CommandLog.release(command_id)
            error
        end

      {:duplicate, result} ->
        GateServer.CliObserve.emit("ws_voxel_prefab_place_intent_duplicate", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          command_id: command_id
        })

        {:ok, GateServer.VoxelCommandId.decode_prefab_summary(result)}

      :in_flight ->
        {:error, %{reason: :command_in_flight, applied_cell_count: 0, total_cell_count: 0}}
    end
  end

  defp do_apply_voxel_prefab_place_intent(request, state) do
    with {:ok, owner_object_id} <- allocate_prefab_owner_object_id(),
         {:ok, cells} <-
           PrefabRaster.rasterize(
             request.blueprint_id,
             request.blueprint_version,
             request.anchor_world_micro,
             request.rotation,
             owner_object_id: owner_object_id,
             owner_part_id: @prefab_owner_part_id
           ) do
      run_prefab_transaction(cells, request, state, owner_object_id)
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: 0}}
    end
  end

  defp authorize_voxel_prefab_place_intent(state) do
    if is_integer(state.cid) and state.cid > 0 do
      :ok
    else
      {:error, :cid_mismatch}
    end
  end

  defp allocate_prefab_owner_object_id do
    case DataService.Voxel.SceneObjectStore.next_object_id() do
      {:ok, object_id}
      when is_integer(object_id) and object_id > 0 and object_id <= @max_prefab_owner_object_id ->
        {:ok, object_id}

      {:ok, _object_id} ->
        {:error, :invalid_allocated_object_id}

      {:error, _reason} ->
        {:error, :object_id_unavailable}
    end
  rescue
    _exception -> {:error, :object_id_unavailable}
  catch
    :exit, _reason -> {:error, :object_id_unavailable}
  end

  # Single-chunk prefabs stay on the Scene hot path and call
  # ChunkDirectory.apply_intents/2 directly. Multi-chunk prefabs that still
  # resolve to one concrete Scene chunk-directory owner use a local
  # prepare/commit/abort runner. Split-owner prefabs still go through World's
  # TransactionCoordinator + TransactionExecutor so the whole prefab commits
  # atomically across every participant.
  defp run_prefab_transaction([], _request, _state, _owner_object_id) do
    {:ok, %{cell_count: 0, chunk_count: 0, max_chunk_version: 0}}
  end

  defp run_prefab_transaction(cells, request, state, owner_object_id) do
    total = length(cells)

    with {:ok, plan} <- build_prefab_plan(cells, request, state, owner_object_id) do
      case single_chunk_prefab_plan(plan) do
        {:ok, participant, chunk_coord, intents} ->
          apply_single_chunk_prefab_fast_path(
            participant,
            plan,
            chunk_coord,
            intents,
            request,
            state,
            total
          )

        :error ->
          case same_owner_prefab_plan(plan) do
            {:ok, participants} ->
              apply_same_owner_prefab_fast_path(participants, plan, request, state, total)

            :error ->
              with {:ok, coordinator_ref} <- locate_voxel_transaction_coordinator(),
                   {:ok, transaction} <-
                     coordinator_begin_transaction(coordinator_ref, plan, request),
                   {:ok, executor_result} <-
                     executor_execute(coordinator_ref, transaction, plan) do
                finalize_prefab_outcome(executor_result, plan, total)
              end
          end
      end
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  # Bulk route chunks through World, then group by concrete Scene owner
  # `{chunk_directory, assigned_scene_node}`. Each participant still carries
  # `chunk_owners` so the real `{region_id, lease_id}` owner of every chunk is
  # preserved for object-owner metadata.
  defp build_prefab_plan(cells, request, state, owner_object_id) do
    cells_by_chunk = Enum.group_by(cells, & &1.chunk_coord)
    chunk_coords = Map.keys(cells_by_chunk)

    case chunk_coords do
      [] ->
        {:error, :empty_prefab}

      coords ->
        with {:ok, routes_by_chunk} <- route_all_chunks(request.logical_scene_id, coords),
             {:ok, participants} <-
               build_prefab_participants(routes_by_chunk, cells_by_chunk, request),
             {:ok, scene_object} <-
               build_prefab_scene_object(
                 request,
                 state,
                 owner_object_id,
                 coords,
                 cells,
                 participants
               ) do
          emit_prefab_routed_observe(request, state, participants, length(cells))

          {:ok,
           %{
             participants: participants,
             chunk_coords: Enum.sort(coords),
             scene_object: scene_object,
             scene_objects: [scene_object]
           }}
        end
    end
  end

  defp build_prefab_scene_object(
         request,
         state,
         owner_object_id,
         chunk_coords,
         cells,
         participants
       ) do
    covered_chunks = Enum.sort(chunk_coords)

    with {:ok, owner} <- prefab_scene_object_owner(covered_chunks, participants),
         {:ok, covered_by_region} <- prefab_covered_chunks_by_region(covered_chunks, participants) do
      {:ok,
       %{
         object_id: owner_object_id,
         logical_scene_id: request.logical_scene_id,
         parcel_id: Map.get(request, :parcel_id, 0),
         blueprint_id: request.blueprint_id,
         blueprint_version: request.blueprint_version,
         anchor_world_micro: request.anchor_world_micro,
         rotation: request.rotation,
         owner_actor_id: state.cid,
         state_flags: 0,
         object_attribute_ref: 0,
         object_tag_set_ref: 0,
         covered_chunks: covered_chunks,
         covered_chunks_by_region: covered_by_region,
         part_states: [
           %{part_id: @prefab_owner_part_id, health: length(cells), state_flags: 0}
         ],
         object_version: 1,
         owner_region_id: owner.region_id,
         owner_lease_id: owner.lease_id
       }}
    end
  end

  defp prefab_scene_object_owner([], _participants), do: {:error, :invalid_covered_chunks}

  defp prefab_scene_object_owner(covered_chunks, participants) do
    first_chunk = covered_chunks |> Enum.sort() |> List.first()

    case Enum.find(participants, fn participant -> first_chunk in participant.chunk_coords end) do
      nil ->
        {:error, :scene_object_owner_undeterminable}

      participant ->
        case Map.fetch(participant.chunk_owners, first_chunk) do
          {:ok, {region_id, lease_id}} -> {:ok, %{region_id: region_id, lease_id: lease_id}}
          :error -> {:error, {:missing_chunk_owner, first_chunk}}
        end
    end
  end

  defp prefab_covered_chunks_by_region(covered_chunks, participants) do
    chunk_to_owner =
      participants
      |> Enum.flat_map(fn participant ->
        Enum.map(participant.chunk_coords, fn coord ->
          {coord, Map.fetch!(participant.chunk_owners, coord)}
        end)
      end)
      |> Map.new()

    covered_chunks
    |> Enum.reduce_while({:ok, []}, fn coord, {:ok, acc} ->
      case Map.fetch(chunk_to_owner, coord) do
        {:ok, owner} -> {:cont, {:ok, [{coord, owner} | acc]}}
        :error -> {:halt, {:error, {:missing_chunk_owner, coord}}}
      end
    end)
    |> case do
      {:ok, pairs} ->
        {:ok,
         pairs
         |> Enum.reverse()
         |> Enum.group_by(fn {_coord, owner} -> owner end, fn {coord, _owner} -> coord end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_all_chunks(logical_scene_id, chunk_coords) do
    route_voxel_chunks(logical_scene_id, chunk_coords)
  end

  defp build_prefab_participants(routes_by_chunk, cells_by_chunk, request) do
    routed_chunks =
      Enum.reduce_while(routes_by_chunk, {:ok, []}, fn {coord, route}, {:ok, acc} ->
        case fetch_scene_node_for_route(route) do
          {:ok, scene_node} ->
            lease = Map.fetch!(route, :lease)
            directory = voxel_chunk_directory_module_for({lease.region_id, lease.lease_id})
            {:cont, {:ok, [{coord, route, scene_node, directory} | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    with {:ok, routed_chunks} <- routed_chunks do
      chunks_by_owner =
        Enum.group_by(
          routed_chunks,
          fn {_coord, _route, scene_node, directory} -> {directory, scene_node} end,
          fn {coord, route, _scene_node, _directory} -> {coord, route} end
        )

      chunks_by_owner
      |> Enum.reduce_while({:ok, []}, fn {{directory, scene_node}, entries}, {:ok, acc} ->
        chunks = entries |> Enum.map(fn {coord, _route} -> coord end) |> Enum.sort()

        first_route =
          entries
          |> Enum.sort_by(fn {coord, _route} -> coord end)
          |> List.first()
          |> elem(1)

        case build_prefab_participant(
               {directory, scene_node},
               chunks,
               first_route,
               routes_by_chunk,
               cells_by_chunk,
               request
             ) do
          {:ok, participant} -> {:cont, {:ok, [participant | acc]}}
        end
      end)
      |> case do
        {:ok, participants} -> {:ok, Enum.reverse(participants)}
        {:error, _} = err -> err
      end
    end
  end

  defp build_prefab_participant(
         {directory, scene_node},
         chunks,
         first_route,
         routes_by_chunk,
         cells_by_chunk,
         request
       ) do
    lease = Map.fetch!(first_route, :lease)
    chunks_sorted = Enum.sort(chunks)

    chunk_owners =
      Map.new(chunks_sorted, fn chunk_coord ->
        chunk_lease = routes_by_chunk |> Map.fetch!(chunk_coord) |> Map.fetch!(:lease)
        {chunk_coord, {chunk_lease.region_id, chunk_lease.lease_id}}
      end)

    intents_by_chunk =
      chunks_sorted
      |> Enum.map(fn chunk_coord ->
        cells_in_chunk = Map.fetch!(cells_by_chunk, chunk_coord)
        chunk_lease = routes_by_chunk |> Map.fetch!(chunk_coord) |> Map.fetch!(:lease)

        {chunk_coord, prefab_intents_for_chunk(cells_in_chunk, request, chunk_coord, chunk_lease)}
      end)
      |> Map.new()

    participant = %{
      participant_key: {:scene_owner, directory, scene_node},
      lease: lease,
      scene_node: scene_node,
      assigned_scene_node: scene_node,
      chunk_directory_module: directory,
      chunk_coords: chunks_sorted,
      chunk_owners: chunk_owners,
      intents_by_chunk: intents_by_chunk
    }

    {:ok, participant}
  end

  defp prefab_intents_for_chunk(cells_in_chunk, request, chunk_coord, lease) do
    Enum.map(cells_in_chunk, fn cell ->
      %{
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: chunk_coord,
        lease: lease,
        operation: :put_micro_block,
        macro: cell.local_macro,
        micro_slot: cell.micro_slot,
        micro_layer: cell.layer_attrs,
        opts: [reject_occupied: true, return_snapshot_payload: false]
      }
    end)
  end

  defp single_chunk_prefab_plan(%{participants: [participant], chunk_coords: [chunk_coord]}) do
    case Map.fetch(participant.intents_by_chunk, chunk_coord) do
      {:ok, intents} -> {:ok, participant, chunk_coord, intents}
      :error -> :error
    end
  end

  defp single_chunk_prefab_plan(_plan), do: :error

  defp same_owner_prefab_plan(%{participants: [_ | _] = participants, chunk_coords: chunk_coords})
       when length(chunk_coords) > 1 do
    case participants |> Enum.map(&prefab_chunk_directory_ref/1) |> Enum.uniq() do
      [_single_owner] -> {:ok, participants}
      _multiple_owners -> :error
    end
  end

  defp same_owner_prefab_plan(_plan), do: :error

  defp apply_single_chunk_prefab_fast_path(
         participant,
         plan,
         chunk_coord,
         intents,
         request,
         state,
         total
       ) do
    started_at = System.monotonic_time(:millisecond)
    chunk_directory = single_chunk_prefab_directory(participant)

    GateServer.CliObserve.emit("ws_voxel_prefab_single_chunk_fast_path_started", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_coord: chunk_coord,
        cell_count: total,
        region_id: participant.lease.region_id,
        lease_id: participant.lease.lease_id,
        scene_node: participant.scene_node
      }
    end)

    # 服务端权威反悬空兜底:放置前只读邻接校验(客户端已 snap+校验,这是兜底)。
    # 仅覆盖单 chunk fast path —— builtins 都是单 macro、宏格对齐时落单 chunk。
    # TODO(多 chunk):same-owner fast path / 跨 region transaction 路径暂不接此校验;
    # 跨 chunk 邻居本就放行(宽松),但多 chunk prefab 的整体悬空判定要在那些路径单独补。
    if prefab_intents_floating?(chunk_directory, intents) do
      GateServer.CliObserve.emit("ws_voxel_prefab_floating_rejected", fn ->
        %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          blueprint_id: request.blueprint_id,
          chunk_coord: chunk_coord,
          cell_count: total,
          region_id: participant.lease.region_id,
          lease_id: participant.lease.lease_id
        }
      end)

      {:error, %{reason: :prefab_floating, applied_cell_count: 0, total_cell_count: total}}
    else
      apply_single_chunk_prefab_after_check(
        participant,
        plan,
        chunk_coord,
        intents,
        request,
        state,
        total,
        chunk_directory,
        started_at
      )
    end
  end

  # 邻接校验失败(chunk 解析失败 / intents 非法)按"非悬空"放行 —— 不让校验本身的
  # 错误阻断合法放置;真正的下游错误仍由后续 apply_intents 返回。返回 true 仅当
  # ChunkDirectory 明确判定悬空。
  defp prefab_intents_floating?(chunk_directory, intents) do
    case SceneServer.Voxel.ChunkDirectory.prefab_floating?(chunk_directory, intents) do
      {:ok, floating?} -> floating?
      {:error, _reason} -> false
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  defp apply_single_chunk_prefab_after_check(
         participant,
         plan,
         chunk_coord,
         intents,
         request,
         state,
         total,
         chunk_directory,
         started_at
       ) do
    case SceneServer.Voxel.ChunkDirectory.apply_intents(chunk_directory, intents) do
      {:ok, summary} ->
        register_prefab_scene_object(plan, participant)

        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        GateServer.CliObserve.emit("ws_voxel_prefab_single_chunk_fast_path_applied", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_coord: chunk_coord,
            cell_count: total,
            changed_count: Map.get(summary, :changed_count, 0),
            skipped_count: Map.get(summary, :skipped_count, 0),
            chunk_version: Map.get(summary, :chunk_version, 0),
            persist_result: Map.get(summary, :persist_result),
            elapsed_ms: elapsed_ms
          }
        end)

        {:ok,
         %{
           cell_count: total,
           chunk_count: 1,
           max_chunk_version: Map.get(summary, :chunk_version, 0)
         }}

      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        GateServer.CliObserve.emit("ws_voxel_prefab_single_chunk_fast_path_failed", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_coord: chunk_coord,
            cell_count: total,
            reason: inspect(reason),
            elapsed_ms: elapsed_ms
          }
        end)

        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  defp single_chunk_prefab_directory(participant) do
    prefab_chunk_directory_ref(participant)
  end

  defp apply_same_owner_prefab_fast_path(participants, plan, request, state, total) do
    started_at = System.monotonic_time(:millisecond)
    transaction_id = unique_prefab_transaction_id(request)
    chunk_directory = prefab_chunk_directory_ref(List.first(participants))

    GateServer.CliObserve.emit("ws_voxel_prefab_same_owner_fast_path_started", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_count: length(plan.chunk_coords),
        participant_count: length(participants),
        cell_count: total,
        chunk_directory: inspect(chunk_directory)
      }
    end)

    case PrefabLocalTransaction.execute(
           participants,
           transaction_id,
           request.logical_scene_id,
           &prefab_chunk_directory_ref/1
         ) do
      {:ok, %{participant_results: participant_results}} ->
        register_prefab_scene_object(plan, List.first(participants))

        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        max_version = max_chunk_version_from_results(participant_results)

        GateServer.CliObserve.emit("ws_voxel_prefab_same_owner_fast_path_applied", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_count: length(plan.chunk_coords),
            participant_count: length(participants),
            cell_count: total,
            max_chunk_version: max_version,
            elapsed_ms: elapsed_ms
          }
        end)

        {:ok,
         %{
           cell_count: total,
           chunk_count: length(plan.chunk_coords),
           max_chunk_version: max_version
         }}

      {:error, %{reason: raw_reason} = error} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        reason = unwrap_prepare_reason(raw_reason)

        GateServer.CliObserve.emit("ws_voxel_prefab_same_owner_fast_path_failed", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_count: length(plan.chunk_coords),
            participant_count: length(participants),
            cell_count: total,
            reason: inspect(reason),
            elapsed_ms: elapsed_ms
          }
        end)

        {:error,
         %{
           reason: reason || Map.get(error, :reason, :prefab_same_owner_fast_path_failed),
           applied_cell_count: 0,
           total_cell_count: total
         }}
    end
  end

  defp register_prefab_scene_object(%{scene_object: scene_object}, %{scene_node: scene_node}) do
    case :rpc.call(
           scene_node,
           SceneServer.Voxel.BuildTransactionApplier,
           :register_scene_objects,
           [[scene_object], []],
           5_000
         ) do
      :ok ->
        :ok

      other ->
        GateServer.CliObserve.emit("ws_voxel_prefab_scene_object_register_failed", fn ->
          %{
            object_id: Map.get(scene_object, :object_id),
            logical_scene_id: Map.get(scene_object, :logical_scene_id),
            reason: inspect(other)
          }
        end)

        :ok
    end
  end

  defp register_prefab_scene_object(_plan, _participant), do: :ok

  defp prefab_chunk_directory_ref(%{chunk_directory_module: module, scene_node: scene_node}) do
    {module, scene_node}
  end

  defp prefab_chunk_directory_ref(%{participant_key: participant_key, scene_node: scene_node}) do
    module = voxel_chunk_directory_module_for(participant_key)
    {module, scene_node}
  end

  defp emit_prefab_routed_observe(request, state, participants, cell_count) do
    GateServer.CliObserve.emit("ws_voxel_prefab_routed", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_count: Enum.reduce(participants, 0, fn p, acc -> acc + length(p.chunk_coords) end),
        cell_count: cell_count,
        participant_count: length(participants),
        participants:
          Enum.map(participants, fn p ->
            %{
              participant_key: inspect(p.participant_key),
              region_id: p.lease.region_id,
              lease_id: p.lease.lease_id,
              owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
              owner_epoch: p.lease.owner_epoch,
              scene_node: p.scene_node,
              chunk_owner_count: map_size(p.chunk_owners),
              chunk_count: length(p.chunk_coords)
            }
          end)
      }
    end)
  end

  # Phase 3 D5 calls for `BeaconServer.Client.lookup(:voxel_transaction_coordinator)`
  # directly, but Gate's existing service discovery already routes through
  # `GateServer.Interface` (whose internals are BeaconServer-backed), and the
  # gate test fixtures intercept that entry point via `FakeInterface`. Going
  # through `fetch_world_node/0` keeps the test mock surface stable while
  # preserving the same lookup semantics (single coordinator per world node,
  # 1:1 with `:world_server` resource). Recorded as a deliberate refinement
  # in the Phase 3 progress log.
  defp locate_voxel_transaction_coordinator do
    case fetch_world_node() do
      {:ok, world_node} ->
        {:ok, {WorldServer.Voxel.TransactionCoordinator, world_node}}

      {:error, _reason} ->
        {:error, :voxel_transaction_coordinator_unavailable}
    end
  end

  defp coordinator_begin_transaction(coordinator_ref, plan, request) do
    transaction_id = unique_prefab_transaction_id(request)

    attrs = %{
      logical_scene_id: request.logical_scene_id,
      parcel_id: Map.get(request, :parcel_id, 0),
      reservation_id: prefab_reservation_id(request),
      decision_version: 1,
      participants:
        Enum.map(plan.participants, fn p ->
          %{
            participant_key: p.participant_key,
            region_id: p.lease.region_id,
            lease_id: p.lease.lease_id,
            owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
            owner_epoch: p.lease.owner_epoch,
            assigned_scene_node: p.assigned_scene_node,
            chunk_owners: p.chunk_owners,
            affected_chunks: p.chunk_coords
          }
        end),
      scene_objects: Map.get(plan, :scene_objects, [])
    }

    try do
      case WorldServer.Voxel.TransactionCoordinator.begin_transaction(
             coordinator_ref,
             transaction_id,
             attrs
           ) do
        {:ok, transaction} -> {:ok, transaction}
        {:error, reason} -> {:error, {:coordinator_begin_failed, reason}}
      end
    catch
      :exit, _reason -> {:error, :coordinator_unavailable}
    end
  end

  # plan.participants 已经按 Scene owner 分组,这里直接把每个 participant 的
  # intents_by_chunk + scene_node 摊成 by-participant 两份 map 喂给 executor。
  # 单 Scene-owner participant 可以包含多个 region/lease;chunk_owners 保留
  # 真实 owner。
  defp executor_execute(coordinator_ref, transaction, plan) do
    intents_by_participant =
      plan.participants
      |> Enum.map(fn p -> {p.participant_key, p.intents_by_chunk} end)
      |> Map.new()

    scene_opts_by_participant =
      plan.participants
      |> Enum.map(fn p ->
        {p.participant_key, [chunk_directory: prefab_chunk_directory_ref(p)]}
      end)
      |> Map.new()

    try do
      WorldServer.Voxel.TransactionExecutor.execute(
        coordinator_ref,
        transaction,
        intents_by_participant,
        scene_opts_by_participant: scene_opts_by_participant
      )
    catch
      :exit, _reason -> {:error, :executor_crashed}
    end
  end

  # Phase A4-5:per-participant chunk_directory module 解析。生产 default
  # `SceneServer.Voxel.ChunkDirectory`(单 module 跨所有 region);test 注入
  # `:voxel_chunk_directory_resolver` env fn 让不同 participant 路由到不同
  # named instance(`ChunkDirectory.RegionA` / `ChunkDirectory.RegionB`),
  # 在单 BEAM 内模拟多 scene_node 部署。A4-bis-cluster 落地后 default 改为
  # 走 `RegionRouting.resolve_chunk_directory/1`。
  defp voxel_chunk_directory_module_for(participant_key) do
    case Application.get_env(:gate_server, :voxel_chunk_directory_resolver) do
      nil -> SceneServer.Voxel.ChunkDirectory
      fun when is_function(fun, 1) -> fun.(participant_key)
    end
  end

  defp finalize_prefab_outcome(executor_result, plan, total) do
    case executor_result do
      %{decision: :commit, participant_results: results} ->
        max_version = max_chunk_version_from_results(results)

        {:ok,
         %{
           cell_count: total,
           chunk_count: length(plan.chunk_coords),
           max_chunk_version: max_version
         }}

      %{decision: :abort, prepare_results: prepare_results} ->
        reason = first_prepare_failure_reason(prepare_results) || :prefab_transaction_aborted

        {:error,
         %{
           reason: reason,
           applied_cell_count: 0,
           total_cell_count: total
         }}
    end
  end

  defp max_chunk_version_from_results(results) do
    Enum.reduce(results, 0, fn
      {_participant, {:ok, summary}}, acc ->
        committed = Map.get(summary, :committed_chunks, [])

        Enum.reduce(committed, acc, fn {_chunk, chunk_summary}, inner ->
          max(inner, Map.get(chunk_summary, :chunk_version, 0))
        end)

      _, acc ->
        acc
    end)
  end

  defp first_prepare_failure_reason(prepare_results) do
    prepare_results
    |> Enum.find_value(fn
      {_participant, {:error, reason}} -> reason
      _ -> nil
    end)
    |> unwrap_prepare_reason()
  end

  # Phase A1-2:`BuildTransactionApplier.prepare_chunks` 把 chunk 级 prepare
  # 失败 wrap 成 `{:prepare_failed, chunk_coord, inner_reason}`。Gate wire
  # 透传给 client 时,wrapped tuple 在 :reason 字段会变成
  # `"{:prepare_failed, {0, 0, 0}, :micro_slot_already_occupied}"` 这种串,
  # client UI 难以识别业务级 reject。这里 unwrap 成 inner atom 让 wire reason
  # 跟 single-intent path(0x70 voxel_edit_intent → :stale_chunk_version 之类)
  # 风格一致。其他 wrap 形式(:commit_failed 等)保持原样。
  defp unwrap_prepare_reason({:prepare_failed, _chunk_coord, inner_reason}), do: inner_reason
  defp unwrap_prepare_reason(other), do: other

  defp unique_prefab_transaction_id(request) do
    unique = System.unique_integer([:positive, :monotonic])
    "prefab-#{request.request_id}-#{unique}"
  end

  defp prefab_reservation_id(request) do
    "prefab-reservation-#{request.request_id}"
  end

  defp voxel_result_error(request, reason) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: :rejected,
       result_ref: 0,
       authoritative: [],
       reason: inspect(reason)
     }}
  end

  defp voxel_result_ok(request, result) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: result.chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  defp voxel_field_conduct_result_ok(request, summary) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: Map.get(summary, :region_id) || 0,
       authoritative: [],
       reason: "field_conduct_ok"
     }}
  end

  defp voxel_prefab_result_ok(request, summary) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: summary.max_chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  # Stub accept used by build-reservation / prefab-place intents until the
  # real reservation and rasterisation pipeline lands. The wire shape matches
  # the eventual spec so clients can round-trip the result frame today.
  defp voxel_intent_stub_accepted(request) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: 0,
       authoritative: [],
       reason: ""
     }}
  end

  # 阶段4 step4.2+4.3:整框订阅意图投给订阅 worker(唯一所有者,自身权威集做差集)。见
  # tcp_connection 同名函数。
  defp dispatch_voxel_subscribe(request, state) do
    known_versions = voxel_known_versions(Map.get(request, :known, []))

    SubscriptionWorker.reconcile(state.voxel_worker, %{
      request_id: request.request_id,
      client_intent_seq: Map.get(request, :client_intent_seq, 0),
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk,
      radius: request.radius_l_inf,
      want_snapshot: request.want_snapshot,
      known: known_versions
    })

    GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_dispatched", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk,
      radius: request.radius_l_inf,
      want_snapshot: request.want_snapshot,
      known_count: map_size(known_versions),
      known_sample:
        known_versions
        |> Enum.take(8)
        |> Enum.map(fn {coord, version} ->
          %{chunk_coord: coord, chunk_version: version}
        end)
    })

    state
  end

  # 阶段4 评审 F5:见 tcp_connection 同名函数。
  defp invalidate_voxel_subscription(worker, payload) do
    case SceneServer.Voxel.Codec.decode_chunk_invalidate_payload(payload) do
      {:ok, %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}} ->
        SubscriptionWorker.invalidate_chunk(worker, logical_scene_id, chunk_coord)

      _other ->
        SubscriptionWorker.invalidate_route_cache(worker)
    end
  end

  defp validate_voxel_subscribe_radius(radius)
       when is_integer(radius) and radius >= 0 and radius <= @max_voxel_subscribe_radius,
       do: :ok

  defp validate_voxel_subscribe_radius(_radius), do: {:error, :voxel_subscribe_radius_too_large}

  defp voxel_known_versions(known) do
    Map.new(known, fn %{chunk_coord: chunk_coord, chunk_version: chunk_version} ->
      {chunk_coord, chunk_version}
    end)
  end

  defp voxel_known_sample(request) do
    request
    |> Map.get(:known, [])
    |> Enum.take(8)
    |> Enum.map(fn %{chunk_coord: chunk_coord, chunk_version: chunk_version} ->
      %{chunk_coord: chunk_coord, chunk_version: chunk_version}
    end)
  end

  defp voxel_snapshot_observe_fields(payload) do
    case SceneServer.Voxel.Codec.decode_chunk_snapshot_payload(payload) do
      {:ok, %{request_id: request_id, storage: storage}} ->
        %{
          request_id: request_id,
          logical_scene_id: storage.logical_scene_id,
          chunk_coord: storage.chunk_coord,
          chunk_version: storage.chunk_version,
          normal_blocks: length(storage.normal_blocks),
          refined_cells: length(storage.refined_cells)
        }

      {:error, reason} ->
        %{decode_error: reason}
    end
  end

  defp voxel_delta_observe_fields(payload) do
    case SceneServer.Voxel.Codec.decode_chunk_delta_payload(payload) do
      {:ok, delta} ->
        %{
          logical_scene_id: delta.logical_scene_id,
          chunk_coord: delta.chunk_coord,
          base_chunk_version: delta.base_chunk_version,
          new_chunk_version: delta.new_chunk_version,
          op_count: length(delta.ops),
          ops_sample: Enum.take(delta.ops, 4) |> Enum.map(&voxel_delta_op_summary/1)
        }

      {:error, reason} ->
        %{decode_error: reason}
    end
  end

  defp voxel_delta_op_summary(op) do
    %{
      delta_kind: Map.get(op, :delta_kind),
      macro_index: Map.get(op, :macro_index),
      cell_version: Map.get(op, :cell_version),
      cell_hash: Map.get(op, :cell_hash),
      payload_bytes: byte_size_or_zero(Map.get(op, :payload))
    }
  end

  defp byte_size_or_zero(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_zero(_value), do: 0

  defp observe_message_summary({:auth_request, username, _token, request_id}) do
    %{type: :auth_request, username: username, request_id: request_id, token_redacted?: true}
  end

  defp observe_message_summary({:movement_input, frame}) do
    %{type: :movement_input, seq: frame.seq, client_tick: frame.client_tick}
  end

  defp observe_message_summary({:voxel_debug_probe, %{request_id: request_id, command: command}}) do
    %{type: :voxel_debug_probe, request_id: request_id, command: command}
  end

  defp observe_message_summary({:voxel_impact_intent, request}) do
    %{
      type: :voxel_impact_intent,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      impact_kind: request.impact_kind
    }
  end

  defp observe_message_summary(message), do: message

  defp handle_voxel_debug_command("voxel_rebind" <> _rest = command, state) do
    case parse_voxel_rebind_command(command) do
      {:ok, logical_scene_id, region_selector} ->
        result =
          SubscriptionWorker.rebind(
            state.voxel_worker,
            logical_scene_id,
            region_selector,
            :debug_probe
          )

        text =
          [
            "voxel_rebind=ok",
            "logical_scene_id=#{logical_scene_id}",
            "region_selector=#{region_selector}",
            "rebound_count=#{result.rebound_count}",
            "skipped_count=#{result.skipped_count}",
            "error_count=#{result.error_count}",
            voxel_debug_result("voxel_transport", state)
          ]
          |> Enum.join("\n")

        {text, state}

      {:error, reason} ->
        {"voxel_rebind=error\nreason=#{reason}", state}
    end
  end

  defp handle_voxel_debug_command(command, state), do: {voxel_debug_result(command, state), state}

  defp parse_voxel_rebind_command(command) do
    case String.split(command, ~r/\s+/, trim: true) do
      ["voxel_rebind", logical_scene_id] ->
        with {:ok, logical_scene_id} <- parse_non_negative_integer(logical_scene_id) do
          {:ok, logical_scene_id, :all}
        end

      ["voxel_rebind", logical_scene_id, "all"] ->
        with {:ok, logical_scene_id} <- parse_non_negative_integer(logical_scene_id) do
          {:ok, logical_scene_id, :all}
        end

      ["voxel_rebind", logical_scene_id, region_id] ->
        with {:ok, logical_scene_id} <- parse_non_negative_integer(logical_scene_id),
             {:ok, region_id} <- parse_non_negative_integer(region_id) do
          {:ok, logical_scene_id, region_id}
        end

      _other ->
        {:error, :usage_voxel_rebind_logical_scene_id_region_id_or_all}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _other -> {:error, :invalid_integer}
    end
  end

  defp voxel_debug_result("voxel_transport", state) do
    subscriptions = SubscriptionWorker.subscriptions(state.voxel_worker)

    [
      "voxel_sync=server-authoritative",
      "voxel_truth_source=server",
      "connection_status=#{state.status}",
      "cid=#{state.cid}",
      "scene_attached=#{not is_nil(state.scene_ref)}",
      "voxel_subscription_count=#{map_size(subscriptions)}",
      "voxel_subscriptions=#{inspect(subscriptions |> Map.keys() |> Enum.take(16))}",
      "voxel_subscription_routes=#{inspect(voxel_subscription_debug(subscriptions))}",
      "confirmed_chunk_versions={}",
      "inflight_intent_count=0",
      "voxel_codec_endian=big",
      "micro_resolution=8"
    ]
    |> Enum.join("\n")
  end

  defp voxel_debug_result(command, state) do
    [
      "command=#{command}",
      "connection_status=#{state.status}",
      "voxel_debug=unknown_command"
    ]
    |> Enum.join("\n")
  end

  defp voxel_subscription_debug(subscriptions) do
    subscriptions
    |> Map.values()
    |> Enum.take(16)
    |> Enum.map(fn subscription ->
      Map.take(subscription, [
        :logical_scene_id,
        :chunk_coord,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch,
        :scene_node
      ])
    end)
  end

  defp build_input_frame(%{} = frame) do
    if Map.get(frame, :__struct__) == InputFrame do
      frame
    else
      struct(InputFrame, %{
        seq: Map.fetch!(frame, :seq),
        client_tick: Map.fetch!(frame, :client_tick),
        dt_ms: Map.fetch!(frame, :dt_ms),
        input_dir: Map.fetch!(frame, :input_dir),
        speed_scale: Map.fetch!(frame, :speed_scale),
        movement_flags: Map.fetch!(frame, :movement_flags)
      })
    end
  end

  defp normalize_remote_snapshot(%{} = snapshot) do
    if Map.get(snapshot, :__struct__) == RemoteSnapshot do
      snapshot
    else
      raise ArgumentError, "expected remote snapshot map, got: #{inspect(snapshot)}"
    end
  end

  # 评审复审 F3:浏览器/客户端断线是正常的会话结束(对齐 TCP 的 {:tcp_closed}/{:tcp_error}→:normal),
  # 不应记为 crash。Bandit/WebSock 的对端关闭(:remote)、空闲超时(:timeout)、传输断(:error,_)
  # 全部归一为 :normal 退出——避免误报 crash 噪声,也使「worker 靠 monitor DOWN 自停」的清理通道
  # 始终生效(:normal 退出不穿 start_link 的 link,故 worker 必须靠 monitor 而非 link 信号收尾)。
  defp normalize_close_reason(:remote), do: :normal
  defp normalize_close_reason(:timeout), do: :normal
  defp normalize_close_reason({:error, _reason}), do: :normal
  defp normalize_close_reason(reason), do: reason

  defp player_move_message(
         %RemoteSnapshot{
           priority_band: nil,
           priority_score: nil,
           observer_distance: nil,
           delivery_interval: nil
         } = snapshot
       ) do
    {:player_move, snapshot.cid, snapshot.server_tick, snapshot.position, snapshot.velocity,
     snapshot.acceleration, snapshot.movement_mode}
  end

  defp player_move_message(%RemoteSnapshot{} = snapshot) do
    {:player_move, snapshot.cid, snapshot.server_tick, snapshot.position, snapshot.velocity,
     snapshot.acceleration, snapshot.movement_mode, snapshot.priority_band,
     snapshot.priority_score, snapshot.observer_distance, snapshot.delivery_interval}
  end
end
