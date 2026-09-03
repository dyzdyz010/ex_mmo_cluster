defmodule GateServer.WsConnection do
  @moduledoc """
  Per-client GenServer for one browser WebSocket session.

  会话状态机（`waiting_auth -> authenticated -> in_scene`）与体素业务管线由共享的
  `GateServer.Session.Dispatch` 提供，与 TCP 链路是同一份实现；本模块只负责 WebSocket
  特有的部分：owner 进程收发、关闭语义归一、以及 per-observer 出口预算
  （`GateServer.Replication.Egress`）——后者是浏览器链路独有的，TCP 侧不存在。

  下行统一经 `GateServer.Session.Sink`（WS 变体把编码结果转交 owner 进程）。
  """

  use GenServer, restart: :temporary
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  alias GateServer.Replication.Egress
  alias GateServer.Session.{Dispatch, Observe, Scene, Sink}
  alias GateServer.Voxel.{ResultFrame, SubscribeIntent, SubscriptionWorker}
  alias SceneServer.Combat.EffectEvent

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
       # 出站唯一出口：共享会话层只认 sink，不认 owner 进程。
       sink: Sink.ws(owner_pid),
       # 浏览器链路没有 UDP 快车道，快车道请求显式回错误而不是伪装成功。
       fast_lane: :unsupported,
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
          %{connection_pid: self(), message: Observe.message_summary(msg)}
        end)

        {:ok, new_state} = Dispatch.handle(msg, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.debug("WS codec decode rejected payload: #{inspect(reason)}")
        Dispatch.result_error(state, reason, 0)
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
    Sink.send_encoded(state.sink, {:player_enter, cid, location})
    {:noreply, state}
  end

  def handle_cast({:player_leave, cid}, state) do
    Sink.send_encoded(state.sink, {:player_leave, cid})
    {:noreply, state}
  end

  def handle_cast({:actor_identity, cid, actor_kind, actor_name}, state) do
    Sink.send_encoded(state.sink, {:actor_identity, cid, actor_kind, actor_name})
    {:noreply, state}
  end

  def handle_cast({:player_move, snapshot}, state) do
    snapshot = Scene.normalize_remote_snapshot(snapshot)

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

    Sink.send_encoded(state.sink, Scene.player_move_message(snapshot))

    {:noreply, state}
  end

  def handle_cast({:movement_ack, ack}, state) do
    Sink.send_encoded(
      state.sink,
      {:movement_ack, ack.ack_seq, ack.auth_tick, ack.cid, ack.position, ack.velocity,
       ack.acceleration, ack.movement_mode, ack.correction_flags, ack.fixed_dt_ms, ack.ground_z}
    )

    {:noreply, state}
  end

  def handle_cast({:chat_message, cid, username, text}, state) do
    Sink.send_encoded(state.sink, {:chat_message, cid, username, text})
    {:noreply, state}
  end

  def handle_cast({:skill_event, cid, skill_id, location}, state) do
    Sink.send_encoded(state.sink, {:skill_event, cid, skill_id, location})
    {:noreply, state}
  end

  def handle_cast({:player_state, cid, hp, max_hp, alive}, state) do
    Sink.send_encoded(state.sink, {:player_state, cid, hp, max_hp, alive})
    {:noreply, state}
  end

  def handle_cast(
        {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location},
        state
      ) do
    Sink.send_encoded(
      state.sink,
      {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
    )

    {:noreply, state}
  end

  def handle_cast({:effect_event, %EffectEvent{} = effect_event}, state) do
    Sink.send_encoded(
      state.sink,
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
        Observe.chunk_snapshot_fields(payload)
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
        Observe.chunk_delta_fields(payload)
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
    SubscribeIntent.invalidate(state.voxel_worker, payload)
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

    Sink.send_encoded(state.sink, ResultFrame.error(ctx, reason))
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
  def handle_info({:voxel_log_entry_payload, payload}, state) when is_binary(payload) do
    Sink.send_encoded(state.sink, {:voxel_log_entry_payload, payload})
    {:noreply, state}
  end

  def handle_info({:voxel_object_state_delta_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_object_state_delta_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload)
    })

    Sink.send_encoded(state.sink, {:voxel_object_state_delta_payload, payload})
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

    Sink.send_raw(state.sink, payload)
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

    Sink.send_raw(state.sink, payload)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # 阶段4:voxel 订阅集在 worker(随本连接退出而停;Scene 侧 subscriber=本连接 pid,
    # ChunkProcess monitor 本连接 down 即自动摘除)——无需在此显式退订。
    Scene.cleanup(state.scene_ref)
    :ok
  end

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
    Sink.send_raw(state.sink, binary)
  end

  defp dispatch_replicated(state, tag, binary) do
    Sink.send_encoded(state.sink, {tag, binary})
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

  defp normalize_close_reason(:remote), do: :normal
  defp normalize_close_reason(:timeout), do: :normal
  defp normalize_close_reason({:error, _reason}), do: :normal
  defp normalize_close_reason(reason), do: reason
end
