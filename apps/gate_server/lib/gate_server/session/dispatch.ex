defmodule GateServer.Session.Dispatch do
  @moduledoc """
  Gate 会话上行消息的**唯一**状态机与分发入口。

  `GateServer.TcpConnection` 与 `GateServer.WsConnection` 只负责各自的传输细节
  （accept / 读帧 / 关闭语义 / WS 出口预算），解码后的消息一律交给本模块；两条链路
  因此共享同一份鉴权、进场、移动、聊天、技能与体素意图语义，不再靠人工同步两份拷贝。

  ## 会话状态机

  ```mermaid
  stateDiagram-v2
      [*] --> waiting_auth
      waiting_auth --> authenticated: auth_request 校验通过
      authenticated --> in_scene: enter_scene 成功
      in_scene --> [*]: 连接关闭
  ```

  状态不匹配的消息一律回显式错误帧（`:invalid_state`），不排队、不静默丢弃。

  ## state 契约

  调用方的 state 必须是含以下键的 map：

  - `:sink` —— 出站传输契约（`GateServer.Session.Sink`），本模块唯一的下行出口
  - `:status` / `:cid` / `:scene_ref` / `:agent` / `:token`
  - `:auth_claims` / `:auth_username` / `:auth_session_id`
  - `:voxel_worker` —— per-connection 订阅 worker
  - `:fast_lane` —— `:enabled`（原生 TCP 客户端可走 UDP 快车道）或 `:unsupported`
    （浏览器 WS 无 UDP）。启用侧还需带 `:udp_ticket`。

  本模块只读写上述键，不碰传输私有字段（socket / owner_pid / egress 等）。

  ## observe 事件名

  事件名经 sink 加传输前缀：TCP 无前缀、WS 加 `ws_`，与拆分前逐字一致。移动相关
  三个事件历史上两侧都带自己的传输名，改走 `emit_transport_tagged/3`
  （`tcp_movement_received` / `ws_movement_received`）。
  """

  require Logger

  alias GateServer.Session.{Auth, Call, DebugProbe, Observe, Scene, Sink}
  alias GateServer.Voxel.{IntentPipeline, PrefabPlacement, ResultFrame, SubscribeIntent}
  alias GateServer.Voxel.SubscriptionWorker
  alias SceneServer.Combat.CastRequest

  @type state :: map()

  @doc """
  处理一条已解码的上行消息，返回更新后的 state。

  未知消息回通用 `:unknown_message` 错误帧并记日志——协议层只追加不破坏，收到不认识的
  消息说明对端版本更新或编解码漂移，必须可诊断。
  """
  @spec handle(term(), state()) :: {:ok, state()}
  def handle(message, state)

  # ── 鉴权 ──

  def handle({:auth_request, username, code, request_id}, %{status: :waiting_auth} = state) do
    emit(state, "auth_received", %{
      connection_pid: self(),
      username: username,
      request_id: request_id
    })

    with {:ok, claims} <- Auth.verify_token(code),
         :ok <- Auth.validate_username(claims, username) do
      auth_context = Auth.build_context(username, code, claims)

      emit(state, "auth_ok", %{
        connection_pid: self(),
        username: username,
        request_id: request_id
      })

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
        emit(state, "auth_error", %{
          connection_pid: self(),
          username: username,
          request_id: request_id,
          reason: reason
        })

        result_error(state, reason, request_id)
        {:ok, state}
    end
  end

  def handle({:auth_request, _username, _code, request_id}, state) do
    result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  # ── 进场 ──

  def handle({:enter_scene, cid, request_id}, %{status: :authenticated} = state) do
    timestamp = :os.system_time(:millisecond)

    emit(state, "enter_scene_received", %{
      connection_pid: self(),
      cid: cid,
      request_id: request_id
    })

    with :ok <- Auth.authorize_cid(state.auth_claims, cid),
         {:ok, character} <- Auth.fetch_authorized_character(state.auth_claims, cid),
         {:ok, scene_node} <- Scene.scene_node(),
         {:ok, ppid} <-
           Scene.add_player(scene_node, cid, self(), timestamp, Auth.character_profile(character)),
         {:ok, {x, y, z}} <- Scene.player_location(ppid),
         {:ok, expected_seq} <- Scene.next_input_seq(ppid) do
      emit(state, "enter_scene_ok", %{
        connection_pid: self(),
        cid: cid,
        request_id: request_id,
        scene_ref: ppid,
        location: {x, y, z},
        expected_seq: expected_seq
      })

      send_encoded(state, {:enter_scene_result, :ok, request_id, {x, y, z}, expected_seq})

      {:ok,
       %{
         state
         | scene_ref: ppid,
           cid: cid,
           status: :in_scene,
           agent: Auth.with_active_cid(state.agent, cid)
       }}
    else
      {:error, reason} ->
        emit(state, "enter_scene_error", %{
          connection_pid: self(),
          cid: cid,
          request_id: request_id,
          reason: reason
        })

        enter_scene_error(state, reason, request_id)
        {:ok, state}
    end
  end

  def handle({:enter_scene, _cid, request_id}, state) do
    enter_scene_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  # ── 时间同步 / 心跳 / 快车道 ──

  def handle({:time_sync, request_id, client_send_ts}, %{status: status} = state)
      when status in [:authenticated, :in_scene] do
    server_recv_ts = :os.system_time(:millisecond)
    server_send_ts = :os.system_time(:millisecond)

    send_encoded(
      state,
      {:time_sync_reply, request_id, client_send_ts, server_recv_ts, server_send_ts}
    )

    {:ok, state}
  end

  def handle({:time_sync, request_id, _client_send_ts}, state) do
    result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  def handle({:heartbeat, _timestamp}, state) do
    send_encoded(state, {:heartbeat_reply, :os.system_time(:millisecond)})
    {:ok, state}
  end

  def handle(
        {:fast_lane_request, request_id},
        %{fast_lane: :enabled, status: status} = state
      )
      when status in [:authenticated, :in_scene] do
    emit(state, "fast_lane_request_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      status: status
    })

    session_context = %{
      auth_claims: state.auth_claims,
      auth_username: state.auth_username,
      auth_session_id: state.auth_session_id,
      cid: state.cid,
      status: status
    }

    case GateServer.FastLaneRegistry.issue_ticket(self(), session_context) do
      {:ok, ticket} ->
        emit(state, "fast_lane_ticket_sent", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request_id
        })

        send_encoded(
          state,
          {:fast_lane_result, :ok, request_id, GateServer.UdpAcceptor.port(), ticket}
        )

        {:ok, %{state | udp_ticket: ticket}}

      {:error, reason} ->
        Logger.warning("Fast-lane ticket issuance failed: #{inspect(reason)}")

        emit(state, "fast_lane_ticket_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request_id,
          reason: reason
        })

        send_encoded(state, {:fast_lane_result, :error, request_id})
        {:ok, state}
    end
  end

  # 未启用快车道（浏览器 WS）或状态不对：显式回错误结果，客户端据此继续走可靠通道。
  def handle({:fast_lane_request, request_id}, state) do
    send_encoded(state, {:fast_lane_result, :error, request_id})
    {:ok, state}
  end

  # ── 移动 ──

  def handle({:movement_input, frame_params}, %{status: :in_scene, scene_ref: spid} = state) do
    frame = Scene.build_input_frame(frame_params)

    emit_transport_tagged(state, "movement_received", fn ->
      %{
        connection_pid: self(),
        seq: frame.seq,
        client_tick: frame.client_tick,
        input_dir: frame.input_dir
      }
    end)

    case Scene.accept_movement_input(spid, frame) do
      {:ok, ack} ->
        GenServer.cast(self(), {:movement_ack, ack})

      :accepted ->
        emit_transport_tagged(state, "movement_accepted", fn ->
          %{connection_pid: self(), seq: frame.seq, client_tick: frame.client_tick}
        end)

      {:error, reason} ->
        emit_transport_tagged(state, "movement_error", fn ->
          %{connection_pid: self(), seq: frame.seq, reason: reason}
        end)

        result_error(state, reason, frame.seq)
    end

    {:ok, state}
  end

  def handle({:movement_input, frame_params}, state) do
    frame = Scene.build_input_frame(frame_params)
    result_error(state, :invalid_state, frame.seq)
    {:ok, state}
  end

  # ── 聊天 / 技能 ──

  def handle({:chat_say, text, request_id}, %{status: :in_scene, scene_ref: spid} = state) do
    emit(state, "chat_received", %{
      connection_pid: self(),
      cid: state.cid,
      username: state.auth_username,
      request_id: request_id,
      text: text
    })

    case Call.safe(spid, {:chat_say, state.cid, state.auth_username || "anonymous", text}) do
      {:ok, {:ok, _}} -> send_encoded(state, {:result, :ok, request_id})
      {:ok, _} -> result_error(state, :server_error, request_id)
      {:error, reason} -> result_error(state, reason, request_id)
    end

    {:ok, state}
  end

  def handle({:chat_say, _text, request_id}, state) do
    result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  def handle(
        {:skill_cast,
         %{
           skill_id: skill_id,
           request_id: request_id,
           target_kind: target_kind,
           target_cid: target_cid,
           target_position: target_position
         }},
        %{status: :in_scene, scene_ref: spid} = state
      ) do
    emit(state, "skill_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      skill_id: skill_id
    })

    cast_request =
      case target_kind do
        :actor when is_integer(target_cid) -> CastRequest.actor(skill_id, target_cid)
        :point -> CastRequest.point(skill_id, target_position)
        _ -> CastRequest.auto(skill_id)
      end

    case Call.safe(spid, {:cast_skill, cast_request}) do
      {:ok, {:ok, _location}} -> send_encoded(state, {:result, :ok, request_id})
      {:ok, {:error, reason}} -> result_error(state, reason, request_id)
      {:ok, _} -> result_error(state, :server_error, request_id)
      {:error, reason} -> result_error(state, reason, request_id)
    end

    {:ok, state}
  end

  def handle({:skill_cast, %{request_id: request_id}}, state) do
    result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  # ── 体素订阅 ──

  def handle({:voxel_chunk_subscribe, request}, %{status: :in_scene} = state) do
    emit(state, "voxel_chunk_subscribe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk,
      radius: request.radius_l_inf,
      known_count: request |> Map.get(:known, []) |> length(),
      known_sample: SubscribeIntent.known_sample(request)
    })

    case SubscribeIntent.validate_radius(request.radius_l_inf) do
      :ok ->
        :ok = SubscribeIntent.reconcile(state.voxel_worker, request, voxel_ctx(state))
        {:ok, state}

      {:error, reason} ->
        emit(state, "voxel_chunk_subscribe_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          reason: reason
        })

        send_encoded(state, ResultFrame.error(request, reason))
        {:ok, state}
    end
  end

  def handle({:voxel_chunk_subscribe, request}, state) do
    send_encoded(state, ResultFrame.error(request, :invalid_state))
    {:ok, state}
  end

  def handle({:voxel_chunk_unsubscribe, request}, %{status: :in_scene} = state) do
    SubscriptionWorker.unsubscribe(state.voxel_worker, request.logical_scene_id, request.chunks)

    emit(state, "voxel_chunk_unsubscribe_ok", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      requested_count: length(request.chunks)
    })

    send_encoded(state, {:result, :ok, request.request_id})
    {:ok, state}
  end

  def handle({:voxel_chunk_unsubscribe, request}, state) do
    result_error(state, :invalid_state, request.request_id)
    {:ok, state}
  end

  # 0x6A/0x6B 仅保留线协议追加兼容；XZ heightmap 已归档，在线链路必须明确拒绝。
  def handle({:voxel_heightmap_request, request}, state) do
    emit(state, "voxel_heightmap_request_rejected", %{
      connection_pid: self(),
      cid: state.cid,
      status: state.status,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      origin: {request.origin_x, request.origin_z},
      stride: request.stride,
      count: {request.count_x, request.count_z},
      contract: :archived_xz_heightmap,
      reason: :unsupported_legacy_contract
    })

    result_error(state, :unsupported_legacy_contract, request.request_id)
    {:ok, state}
  end

  # ── 体素意图 ──

  # DEPRECATED for client-side direct edit; protocol §13.6 / §13.6.1.
  # 客户端定向编辑一律走 VoxelEditIntent (0x70)；本通道保留给技能 / 工具系统。
  def handle({:voxel_impact_intent, request}, %{status: :in_scene} = state) do
    emit(state, "voxel_impact_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      source_skill_id: request.source_skill_id,
      target_world_micro: request.target_world_micro,
      impact_kind: request.impact_kind
    })

    case IntentPipeline.apply_impact(request, voxel_ctx(state)) do
      {:ok, result} ->
        emit(state, "voxel_impact_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: result.chunk_coord,
          chunk_version: result.chunk_version,
          macro: result.macro
        })

        send_encoded(state, ResultFrame.impact_ok(request, result))

      {:error, reason} ->
        emit(state, "voxel_impact_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(state, ResultFrame.error(request, reason))
    end

    {:ok, state}
  end

  def handle({:voxel_impact_intent, request}, state) do
    send_encoded(state, ResultFrame.error(request, :invalid_state))
    {:ok, state}
  end

  # VoxelEditIntent (0x70) —— 客户端定向编辑通道；协议 §13.6.1。
  # ── Voxim R6：overlay 订阅与 Voxim 会话的编辑意图（VoxelRegion.World；决策稿 §5） ──
  # 发过 0x76 的连接是 Voxim 会话：之后的 0x70 走 region 真值（文件 ⊕ 日志），不走 Scene 的 ChunkProcess；
  # 回执 result_ref = 提交的日志 seq（D-12），authoritative 为空（只有日志条目改世界）。
  def handle({:voxel_overlay_subscribe, sub}, %{status: :in_scene} = state) do
    :ok = VoxelRegion.World.subscribe(self(), sub.have_seq, sub.box, sub.coarse_min_level)

    emit(state, "voxel_overlay_subscribed", %{
      connection_pid: self(),
      cid: state.cid,
      have_seq: sub.have_seq,
      box: sub.box,
      coarse_min_level: sub.coarse_min_level
    })

    {:ok, Map.put(state, :voxim_overlay, true)}
  end

  def handle({:voxel_overlay_subscribe, _sub}, state) do
    result_error(state, :invalid_state, 0)
    {:ok, state}
  end

  def handle({:voxel_edit_intent, request}, %{status: :in_scene, voxim_overlay: true} = state) do
    {wx, wy, wz} = request.target_world_micro
    coord = {Integer.floor_div(wx, 8), Integer.floor_div(wy, 8), Integer.floor_div(wz, 8)}

    case VoxelRegion.World.apply_edit(coord, request.material_id) do
      {:ok, seq} ->
        send_encoded(
          state,
          {:voxel_intent_result,
           %{
             request_id: request.request_id,
             client_intent_seq: request.client_intent_seq,
             logical_scene_id: request.logical_scene_id,
             result_code: :accepted,
             result_ref: seq,
             authoritative: [],
             reason: "ok"
           }}
        )

      {:error, reason} ->
        send_encoded(state, ResultFrame.error(request, reason))
    end

    {:ok, state}
  end

  def handle({:voxel_edit_intent, request}, %{status: :in_scene} = state) do
    IntentPipeline.emit_edit_received(request, voxel_ctx(state))

    case IntentPipeline.apply_edit(request, voxel_ctx(state)) do
      {:ok, result} ->
        emit(state, "voxel_edit_intent_applied", %{
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

        send_encoded(state, ResultFrame.edit_ok(request, result))

      {:error, reason} ->
        emit(state, "voxel_edit_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(state, ResultFrame.edit_error(request, reason))
    end

    {:ok, state}
  end

  def handle({:voxel_edit_intent, request}, state) do
    emit(state, "voxel_edit_intent_dropped_invalid_state", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      status: state.status
    })

    send_encoded(state, ResultFrame.edit_error(request, :invalid_state))
    {:ok, state}
  end

  def handle({:voxel_build_reservation_intent, request}, %{status: :in_scene} = state) do
    emit(state, "voxel_build_reservation_intent_received", fn ->
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

    send_encoded(state, ResultFrame.stub_accepted(request))
    {:ok, state}
  end

  def handle({:voxel_build_reservation_intent, request}, state) do
    send_encoded(state, ResultFrame.error(request, :invalid_state))
    {:ok, state}
  end

  def handle({:voxel_prefab_place_intent, request}, %{status: :in_scene} = state) do
    emit(state, "voxel_prefab_place_intent_received", fn ->
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

    case PrefabPlacement.place(request, voxel_ctx(state)) do
      {:ok, summary} ->
        emit(state, "voxel_prefab_place_intent_applied", %{
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

        send_encoded(state, ResultFrame.prefab_ok(request, summary))

      {:error, %{reason: reason} = failure} ->
        emit(state, "voxel_prefab_place_intent_error", %{
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

        send_encoded(state, ResultFrame.error(request, reason))
    end

    {:ok, state}
  end

  def handle({:voxel_prefab_place_intent, request}, state) do
    send_encoded(state, ResultFrame.error(request, :invalid_state))
    {:ok, state}
  end

  # 形态轨 C5.2:VoxelSurfaceElementIntent (0x66) —— 表面元件（火炬 / 拉杆）放置 / 清除，
  # 路由与 0x70 相同，复用 VoxelIntentResult (0x68) 回执。
  def handle({:voxel_surface_element_intent, request}, %{status: :in_scene} = state) do
    emit(state, "voxel_surface_element_intent_received", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        client_intent_seq: request.client_intent_seq,
        logical_scene_id: request.logical_scene_id,
        action: request.action,
        face: request.face,
        surface_type_id: request.surface_type_id
      }
    end)

    case IntentPipeline.apply_surface_element(request, voxel_ctx(state)) do
      {:ok, result} ->
        emit(state, "voxel_surface_element_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: result.chunk_coord,
          chunk_version: result.chunk_version,
          macro: result.macro
        })

        send_encoded(state, ResultFrame.edit_ok(request, result))

      {:error, reason} ->
        emit(state, "voxel_surface_element_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(state, ResultFrame.edit_error(request, reason))
    end

    {:ok, state}
  end

  def handle({:voxel_surface_element_intent, request}, state) do
    send_encoded(state, ResultFrame.edit_error(request, :invalid_state))
    {:ok, state}
  end

  # 场域导通轨:VoxelFieldConductIntent (0x75) —— 电 / 热导通路径建立。
  def handle({:voxel_field_conduct_intent, request}, %{status: :in_scene} = state) do
    emit(state, "voxel_field_conduct_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      source_world_macro: request.source_world_macro,
      target_world_macro: request.target_world_macro,
      conduction_mode: request.conduction_mode
    })

    case IntentPipeline.apply_field_conduct(request, voxel_ctx(state)) do
      {:ok, summary} ->
        emit(state, "voxel_field_conduct_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          region_id: Map.get(summary, :region_id),
          field_region_created: Map.get(summary, :field_region_created),
          conduction_mode: Map.get(summary, :conduction_mode, request.conduction_mode)
        })

        send_encoded(state, ResultFrame.field_conduct_ok(request, summary))

      {:error, reason} ->
        emit(state, "voxel_field_conduct_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: inspect(reason)
        })

        send_encoded(state, ResultFrame.error(request, reason))
    end

    {:ok, state}
  end

  def handle({:voxel_field_conduct_intent, request}, state) do
    emit(state, "voxel_field_conduct_intent_dropped_invalid_state", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      status: state.status
    })

    send_encoded(state, ResultFrame.error(request, :invalid_state))
    {:ok, state}
  end

  # ── 调试探针 ──

  def handle({:voxel_debug_probe, %{request_id: request_id, command: command}}, state) do
    emit(state, "voxel_debug_probe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      command: command,
      status: state.status
    })

    {result, next_state} = DebugProbe.run(command, state)

    send_encoded(next_state, {:voxel_debug_probe, %{request_id: request_id, result: result}})

    {:ok, next_state}
  end

  def handle(message, state) do
    Logger.warning("Unhandled message: #{inspect(Observe.message_summary(message))}")
    result_error(state, :unknown_message, 0)
    {:ok, state}
  end

  # ── 内部辅助 ──

  # 交给共享体素管线的最小上下文：业务侧只需要发起者身份 + 出站 sink。
  defp voxel_ctx(state), do: %{cid: state.cid, sink: state.sink}

  defp send_encoded(state, message), do: Sink.send_encoded(state.sink, message)

  defp emit(state, event, fields), do: Sink.emit(state.sink, event, fields)

  defp emit_transport_tagged(state, event, fields),
    do: Sink.emit_transport_tagged(state.sink, event, fields)

  @doc """
  通用 `Result(error)` 回执。

  除 dispatch 自身外，连接进程在**进入状态机之前**的失败点（如 codec 解码拒绝）也用它，
  保证任何被拒的上行都有一帧可诊断回执，不让客户端悬等。
  """
  @spec result_error(state(), term(), non_neg_integer()) :: :ok
  def result_error(state, reason, request_id) do
    Logger.debug("Sending generic result error: #{inspect(reason)}")

    emit(state, "send_result_error", %{
      connection_pid: self(),
      request_id: request_id,
      reason: reason
    })

    send_encoded(state, {:result, :error, request_id})
  end

  defp enter_scene_error(state, reason, request_id) do
    Logger.debug("Sending enter-scene error: #{inspect(reason)}")

    emit(state, "send_enter_scene_error", %{
      connection_pid: self(),
      request_id: request_id,
      reason: reason
    })

    send_encoded(state, {:enter_scene_result, :error, request_id})
  end
end
