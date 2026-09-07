defmodule GateServer.Codec do
  @moduledoc "仍有活调用方的旧移动、聊天、NPC/战斗与 Scene 体素 wire；现行 Session/Voxel 字节由 MmoContracts 拥有。"

  # ── Client → Server message types ──
  import MmoContracts.Voxel.Fields

  @msg_movement 0x01
  @msg_time_sync 0x03
  @msg_fast_lane_request 0x06
  @msg_fast_lane_attach 0x07
  @msg_chat_say 0x08
  @msg_skill_cast 0x09
  @msg_voxel_chunk_subscribe 0x60
  @msg_voxel_chunk_unsubscribe 0x61
  @msg_voxel_chunk_snapshot 0x62
  @msg_voxel_chunk_delta 0x63
  # DEPRECATED for client-side direct edit; use MmoContracts.Voxel.Codec (0x70).
  # Kept for skill/tool-system flow per protocol §13.6.
  @msg_voxel_impact_intent 0x64
  @msg_voxel_build_reservation_intent 0x65
  # 形态轨 C5.2:表面元件(火炬/拉杆)放置/清除——绑宿主宏格一面,零 occupancy。
  @msg_voxel_surface_element_intent 0x66
  @msg_voxel_prefab_place_intent 0x67
  @msg_voxel_chunk_invalidate 0x69
  @msg_voxel_object_state_delta 0x6C
  @msg_voxel_debug_probe 0x6F
  # 旧 XZ heightmap 线协议编号只做 append-only codec 兼容；在线链路不再生产该数据。
  @msg_voxel_heightmap_request 0x6A
  @msg_voxel_heightmap_region 0x6B
  @heightmap_section_materials_u16 0x01
  @msg_voxel_field_conduct_intent 0x75

  # ── Server → Client message types ──
  @msg_player_enter 0x81
  @msg_player_leave 0x82
  @msg_player_move 0x83
  @msg_time_sync_reply 0x85
  @msg_fast_lane_result 0x87
  @msg_fast_lane_attached 0x88
  @msg_chat_message 0x89
  @msg_skill_event 0x8A
  @msg_movement_ack 0x8B
  @msg_player_state 0x8C
  @msg_combat_hit 0x8D
  @msg_actor_identity 0x8E
  @msg_effect_event 0x8F

  # ── Status codes ──
  @status_ok 0x00
  @status_error 0x01

  # ── DoS 护栏:可变长字段上限 ──
  # 每个 16-bit 长度字段本就 ≤65535,但仍可被滥用(64KB 聊天、1.3MB known-chunks 订阅帧、
  # 海量递归解析)。给主解码子句加 guard:超限的帧不匹配主子句 → 落到 fallthrough → {:error,_},
  # 不进一步处理。配合 acceptor 的 packet_size 8MB 总帧上限,客户端→服务端不可逼爆内存。
  # 上限取「远大于任何合法输入、远小于 64KB u16 上界」:auth code / ticket 可能承载 JWT
  # (常见 ~1-2KB,带 claims 更长),故给 4KB 余量,避免误拒真实凭据。
  @max_ticket_bytes 4096
  @max_chat_text_bytes 2048
  @max_known_chunks 9_261

  # ═══════════════════════════════════════════════════════════
  # Decode: binary → structured tuple
  # ═══════════════════════════════════════════════════════════

  @doc """
  Decode one payload frame into a protocol tuple.

  `decode/1` expects the binary after the 4-byte packet prefix has already been
  removed. When the frame is valid, it returns a tuple that the connection
  worker can dispatch immediately.

  ## Examples

      iex> MmoContracts.Session.Codec.decode(<<0x04, 123::64-big>>)
      {:ok, {:heartbeat, 123}}

      iex> GateServer.Codec.decode(<<0x7F, 1, 2, 3>>)
      {:error, {:unknown_message_type, 127}}
  """
  @spec decode(binary()) :: {:ok, tuple()} | {:error, atom()}

  # MovementInput: 1 + 4 + 4 + 2 + 4 + 4 + 4 + 2 = 25 bytes
  def decode(
        <<@msg_movement, seq::32-big, client_tick::32-big, dt_ms::16-big,
          input_dir_x::float-32-big, input_dir_y::float-32-big, speed_scale::float-32-big,
          movement_flags::16-big>>
      ) do
    {:ok,
     {:movement_input,
      %{
        seq: seq,
        client_tick: client_tick,
        dt_ms: dt_ms,
        input_dir: {input_dir_x * 1.0, input_dir_y * 1.0},
        speed_scale: speed_scale * 1.0,
        movement_flags: movement_flags
      }}}
  end

  def decode(<<@msg_movement, _rest::binary>>), do: {:error, :invalid_message}

  # TimeSync: 1 + 8 + 8 = 17 bytes
  def decode(<<@msg_time_sync, request_id::64-big, client_send_ts::64-big>>) do
    {:ok, {:time_sync, request_id, client_send_ts}}
  end

  def decode(<<@msg_time_sync, _rest::binary>>), do: {:error, :invalid_message}

  # Fast-lane bootstrap request: 1 + 8
  def decode(<<@msg_fast_lane_request, request_id::64-big>>) do
    {:ok, {:fast_lane_request, request_id}}
  end

  # Fast-lane UDP attach request: 1 + 8 + 2 + ticket
  def decode(
        <<@msg_fast_lane_attach, request_id::64-big, tlen::16-big, ticket::binary-size(tlen)>>
      )
      when tlen <= @max_ticket_bytes do
    {:ok, {:fast_lane_attach, request_id, ticket}}
  end

  def decode(<<@msg_fast_lane_attach, _rest::binary>>), do: {:error, :invalid_message}

  # ChatSay: 1 + 8 + 2 + text
  def decode(<<@msg_chat_say, request_id::64-big, tlen::16-big, text::binary-size(tlen)>>)
      when tlen <= @max_chat_text_bytes do
    {:ok, {:chat_say, text, request_id}}
  end

  def decode(<<@msg_chat_say, _rest::binary>>), do: {:error, :invalid_message}

  # SkillCast: 1 + 8 + 2 + 1 + 8 + 24
  def decode(
        <<@msg_skill_cast, request_id::64-big, skill_id::16-big, target_kind::8,
          target_cid::64-big-signed, tx::float-64-big, ty::float-64-big, tz::float-64-big>>
      ) do
    {:ok,
     {:skill_cast,
      %{
        skill_id: skill_id,
        request_id: request_id,
        target_kind: decode_skill_target_kind(target_kind),
        target_cid: decode_target_cid(target_cid),
        target_position: {tx, ty, tz}
      }}}
  end

  def decode(<<@msg_skill_cast, _rest::binary>>), do: {:error, :invalid_message}

  # Voxel ChunkSubscribe:
  # 1 + request_id:u64 + logical_scene_id:u64 + center_chunk:i32x3 +
  # radius_l_inf:u8 + want_snapshot:u8 + known_count:u16 + known[]
  def decode(
        <<@msg_voxel_chunk_subscribe, request_id::64-big, logical_scene_id::64-big,
          cx::32-big-signed, cy::32-big-signed, cz::32-big-signed, radius_l_inf::8,
          want_snapshot::8, known_count::16-big, rest::binary>>
      )
      when known_count <= @max_known_chunks do
    with {:ok, known, <<>>} <- decode_voxel_known_chunks(rest, known_count, []) do
      {:ok,
       {:voxel_chunk_subscribe,
        %{
          request_id: request_id,
          logical_scene_id: logical_scene_id,
          center_chunk: {cx, cy, cz},
          radius_l_inf: radius_l_inf,
          want_snapshot: decode_bool(want_snapshot),
          known: known
        }}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_message}
    end
  end

  def decode(<<@msg_voxel_chunk_subscribe, _rest::binary>>), do: {:error, :invalid_message}

  # Voxel ChunkUnsubscribe:
  # 1 + request_id:u64 + logical_scene_id:u64 + chunk_count:u16 + ChunkCoord[]
  def decode(
        <<@msg_voxel_chunk_unsubscribe, request_id::64-big, logical_scene_id::64-big,
          chunk_count::16-big, rest::binary>>
      ) do
    with {:ok, chunks, <<>>} <- decode_voxel_chunk_coords(rest, chunk_count, []) do
      {:ok,
       {:voxel_chunk_unsubscribe,
        %{
          request_id: request_id,
          logical_scene_id: logical_scene_id,
          chunks: chunks
        }}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_message}
    end
  end

  def decode(<<@msg_voxel_chunk_unsubscribe, _rest::binary>>), do: {:error, :invalid_message}

  # 旧 VoxelHeightmapRequest (0x6A)，仅保留解码兼容：
  # 1 + request_id:u64 + logical_scene_id:u64 + origin_macro_x:i32 +
  # origin_macro_z:i32 + stride:u16 + count_x:u16 + count_z:u16
  def decode(
        <<@msg_voxel_heightmap_request, request_id::64-big, logical_scene_id::64-big,
          origin_x::32-big-signed, origin_z::32-big-signed, stride::16-big, count_x::16-big,
          count_z::16-big>>
      ) do
    {:ok,
     {:voxel_heightmap_request,
      %{
        request_id: request_id,
        logical_scene_id: logical_scene_id,
        origin_x: origin_x,
        origin_z: origin_z,
        stride: stride,
        count_x: count_x,
        count_z: count_z
      }}}
  end

  def decode(<<@msg_voxel_heightmap_request, _rest::binary>>), do: {:error, :invalid_message}

  # VoxelImpactIntent:
  # 1 + request_id:u64 + client_intent_seq:u32 + logical_scene_id:u64 +
  # source_skill_id:u32 + target_world_micro:i64x3 + impact_kind:u16 +
  # client_hint_hash:u64
  def decode(
        <<@msg_voxel_impact_intent, request_id::64-big, client_intent_seq::32-big,
          logical_scene_id::64-big, source_skill_id::32-big, wx::64-big-signed, wy::64-big-signed,
          wz::64-big-signed, impact_kind::16-big, client_hint_hash::64-big>>
      ) do
    {:ok,
     {:voxel_impact_intent,
      %{
        request_id: request_id,
        client_intent_seq: client_intent_seq,
        logical_scene_id: logical_scene_id,
        source_skill_id: source_skill_id,
        target_world_micro: {wx, wy, wz},
        impact_kind: impact_kind,
        client_hint_hash: client_hint_hash
      }}}
  end

  def decode(<<@msg_voxel_impact_intent, _rest::binary>>), do: {:error, :invalid_message}

  # VoxelBuildReservationIntent (0x65). Canonical decode lives in
  # `SceneServer.Voxel.Codec` because the payload is voxel-truth-shaped and
  # is forwarded across services unchanged.
  def decode(<<@msg_voxel_build_reservation_intent, payload::binary>>) do
    case SceneServer.Voxel.Codec.decode_build_reservation_intent_payload(payload) do
      {:ok, intent} -> {:ok, {:voxel_build_reservation_intent, intent}}
      {:error, _reason} -> {:error, :invalid_message}
    end
  end

  # VoxelSurfaceElementIntent (0x66) — 形态轨 C5.2 表面元件放置/清除通道。
  # 固定 56 字节 body:request_id:u64 + client_intent_seq:u32 + logical_scene_id:u64 +
  # action:u8(0=place,1=clear) + target_world_micro:i64x3 + face:u8(0..5 ordinal) +
  # surface_type_id:u16 + attribute_set_ref:u32 + tag_set_ref:u32。gate 由
  # target_world_micro 解析宿主宏格(无 face_normal 偏移),face ordinal/type 在
  # SceneServer 侧校验,owner_actor_id 由 gate 用 cid 注入(不信任客户端)。
  def decode(
        <<@msg_voxel_surface_element_intent, request_id::64-big, client_intent_seq::32-big,
          logical_scene_id::64-big, action::8, wx::64-big-signed, wy::64-big-signed,
          wz::64-big-signed, face::8, surface_type_id::16-big, attribute_set_ref::32-big,
          tag_set_ref::32-big>>
      ) do
    {:ok,
     {:voxel_surface_element_intent,
      %{
        request_id: request_id,
        client_intent_seq: client_intent_seq,
        logical_scene_id: logical_scene_id,
        action: action,
        target_world_micro: {wx, wy, wz},
        face: face,
        surface_type_id: surface_type_id,
        attribute_set_ref: attribute_set_ref,
        tag_set_ref: tag_set_ref
      }}}
  end

  def decode(<<@msg_voxel_surface_element_intent, _rest::binary>>), do: {:error, :invalid_message}

  # VoxelPrefabPlaceIntent (0x67). Canonical decode lives in
  # `SceneServer.Voxel.Codec`; the gate codec only frames the opcode here.
  def decode(<<@msg_voxel_prefab_place_intent, payload::binary>>) do
    case SceneServer.Voxel.Codec.decode_prefab_place_intent_payload(payload) do
      {:ok, intent} -> {:ok, {:voxel_prefab_place_intent, intent}}
      {:error, _reason} -> {:error, :invalid_message}
    end
  end

  # VoxelDebugProbe:
  # 1 + request_id:u64 + command:string
  def decode(<<@msg_voxel_debug_probe, request_id::64-big, command_len::16-big, rest::binary>>)
      when byte_size(rest) == command_len do
    {:ok, {:voxel_debug_probe, %{request_id: request_id, command: rest}}}
  end

  def decode(<<@msg_voxel_debug_probe, _rest::binary>>), do: {:error, :invalid_message}

  def decode(
        <<@msg_voxel_field_conduct_intent, request_id::64-big, client_intent_seq::32-big,
          logical_scene_id::64-big, sx::64-big-signed, sy::64-big-signed, sz::64-big-signed,
          tx::64-big-signed, ty::64-big-signed, tz::64-big-signed, source_potential::float-64,
          max_ticks::32-big, conduction_mode::8, output_mode::8, power_flags::16-big,
          voltage::float-64, current_limit_amps::float-64, frequency_hz::float-64,
          load_current_amps::float-64, energy_budget_joules::float-64>>
      ) do
    {:ok,
     {:voxel_field_conduct_intent,
      %{
        request_id: request_id,
        client_intent_seq: client_intent_seq,
        logical_scene_id: logical_scene_id,
        source_world_macro: {sx, sy, sz},
        target_world_macro: {tx, ty, tz},
        source_potential: source_potential,
        max_ticks: max_ticks,
        conduction_mode: decode_field_conduct_mode(conduction_mode)
      }
      |> maybe_put_field_output_mode(power_flags, output_mode)
      |> maybe_put_field_power(:voltage, power_flags, 0x0002, voltage)
      |> maybe_put_field_power(:current_limit_amps, power_flags, 0x0004, current_limit_amps)
      |> maybe_put_field_power(:frequency_hz, power_flags, 0x0008, frequency_hz)
      |> maybe_put_field_power(:load_current_amps, power_flags, 0x0010, load_current_amps)
      |> maybe_put_field_power(:energy_budget_joules, power_flags, 0x0020, energy_budget_joules)}}
  end

  def decode(<<@msg_voxel_field_conduct_intent, _rest::binary>>), do: {:error, :invalid_message}

  def decode(<<type::8, _rest::binary>>) do
    {:error, {:unknown_message_type, type}}
  end

  def decode(_) do
    {:error, :invalid_message}
  end

  # ═══════════════════════════════════════════════════════════
  # Encode: structured tuple → iodata
  # ═══════════════════════════════════════════════════════════

  @doc """
  Encode one protocol tuple into a TCP payload.

  The returned value is iodata that can be passed straight to `:gen_tcp.send/2`.
  The socket's `{packet, 4}` setting adds the outer length prefix for us.

  ## Examples

      iex> {:ok, bin} = GateServer.Codec.encode({:player_leave, 42})
      iex> byte_size(bin)
      9

      iex> GateServer.Codec.encode(:ping)
      {:error, :unknown_message}
  """
  @spec encode(tuple() | atom()) :: {:ok, iodata()} | {:error, atom()}

  # ── Generic result (ok/error with packet_id) ──
  # ── EnterScene result (success with location + expected next input seq) ──
  # Audit B-S1 / B-SRV2: success carries expected_seq so the client can
  # initialise its local input-frame counter to the value the server is
  # going to validate against. v1 layout — no fallback / compatibility
  # branch; client and server must ship together.
  # ── Movement ack ──
  # Audit B-M2: trailing fixed_dt_ms (u16 BE) lets the client detect when
  # its own MovementProfile.fixed_dt_ms has drifted from the server's
  # authoritative value. Drift would silently accumulate prediction error
  # over hundreds of replay frames; surfacing it lets the client log and
  # downgrade gracefully.
  def encode(
        {:movement_ack, ack_seq, auth_tick, cid, {px, py, pz}, {vx, vy, vz}, {ax, ay, az},
         movement_mode, correction_flags, fixed_dt_ms, ground_z}
      )
      when is_integer(fixed_dt_ms) and fixed_dt_ms > 0 and is_float(ground_z) do
    {:ok,
     <<@msg_movement_ack, ack_seq::32-big, auth_tick::32-big, cid::64-big, px::float-64-big,
       py::float-64-big, pz::float-64-big, vx::float-64-big, vy::float-64-big, vz::float-64-big,
       ax::float-64-big, ay::float-64-big, az::float-64-big, encode_movement_mode(movement_mode),
       correction_flags::32-big, fixed_dt_ms::16-big, ground_z::float-64-big>>}
  end

  # ── Broadcast: player enter ──
  def encode({:player_enter, cid, {x, y, z}}) do
    {:ok, <<@msg_player_enter, cid::64-big, x::float-64-big, y::float-64-big, z::float-64-big>>}
  end

  # ── Broadcast: player leave ──
  def encode({:player_leave, cid}) do
    {:ok, <<@msg_player_leave, cid::64-big>>}
  end

  # ── Broadcast: player move snapshot ──
  def encode(
        {:player_move, cid, server_tick, {x, y, z}, {vx, vy, vz}, {ax, ay, az}, movement_mode,
         priority_band, priority_score, observer_distance, delivery_interval}
      )
      when is_integer(delivery_interval) and delivery_interval > 0 do
    {:ok,
     <<@msg_player_move, cid::64-big, server_tick::32-big, x::float-64-big, y::float-64-big,
       z::float-64-big, vx::float-64-big, vy::float-64-big, vz::float-64-big, ax::float-64-big,
       ay::float-64-big, az::float-64-big, encode_movement_mode(movement_mode),
       encode_priority_band(priority_band)::8, priority_score * 1.0::float-32-big,
       observer_distance * 1.0::float-32-big, delivery_interval::16-big>>}
  end

  def encode(
        {:player_move, cid, server_tick, {x, y, z}, {vx, vy, vz}, {ax, ay, az}, movement_mode}
      ) do
    {:ok,
     <<@msg_player_move, cid::64-big, server_tick::32-big, x::float-64-big, y::float-64-big,
       z::float-64-big, vx::float-64-big, vy::float-64-big, vz::float-64-big, ax::float-64-big,
       ay::float-64-big, az::float-64-big, encode_movement_mode(movement_mode)>>}
  end

  # ── TimeSync reply ──
  def encode({:time_sync_reply, packet_id, client_send_ts, server_recv_ts, server_send_ts}) do
    {:ok,
     <<@msg_time_sync_reply, packet_id::64-big, client_send_ts::64-big, server_recv_ts::64-big,
       server_send_ts::64-big>>}
  end

  # ── Heartbeat reply ──
  # ── Fast-lane bootstrap result (TCP) ──
  def encode({:fast_lane_result, :ok, packet_id, udp_port, ticket}) when is_binary(ticket) do
    {:ok,
     <<@msg_fast_lane_result, packet_id::64-big, @status_ok, udp_port::16-big,
       byte_size(ticket)::16-big, ticket::binary>>}
  end

  def encode({:fast_lane_result, :error, packet_id}) do
    {:ok, <<@msg_fast_lane_result, packet_id::64-big, @status_error>>}
  end

  # ── Fast-lane attached ack (UDP) ──
  def encode({:fast_lane_attached, :ok, packet_id}) do
    {:ok, <<@msg_fast_lane_attached, packet_id::64-big, @status_ok>>}
  end

  def encode({:fast_lane_attached, :error, packet_id}) do
    {:ok, <<@msg_fast_lane_attached, packet_id::64-big, @status_error>>}
  end

  # ── Chat message broadcast (TCP) ──
  def encode({:chat_message, cid, username, text})
      when is_integer(cid) and is_binary(username) and is_binary(text) do
    {:ok,
     <<@msg_chat_message, cid::64-big, byte_size(username)::16-big, username::binary,
       byte_size(text)::16-big, text::binary>>}
  end

  # ── Skill event broadcast (TCP) ──
  def encode({:skill_event, cid, skill_id, {x, y, z}})
      when is_integer(cid) and is_integer(skill_id) do
    {:ok,
     <<@msg_skill_event, cid::64-big, skill_id::16-big, x::float-64-big, y::float-64-big,
       z::float-64-big>>}
  end

  def encode({:player_state, cid, hp, max_hp, alive})
      when is_integer(cid) and is_integer(hp) and is_integer(max_hp) do
    {:ok, <<@msg_player_state, cid::64-big, hp::16-big, max_hp::16-big, encode_bool(alive)::8>>}
  end

  def encode({:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, {x, y, z}})
      when is_integer(source_cid) and is_integer(target_cid) and is_integer(skill_id) do
    {:ok,
     <<@msg_combat_hit, source_cid::64-big, target_cid::64-big, skill_id::16-big, damage::16-big,
       hp_after::16-big, x::float-64-big, y::float-64-big, z::float-64-big>>}
  end

  def encode({:actor_identity, cid, actor_kind, actor_name})
      when is_integer(cid) and is_binary(actor_name) do
    {:ok,
     <<@msg_actor_identity, cid::64-big, encode_actor_kind(actor_kind)::8,
       byte_size(actor_name)::16-big, actor_name::binary>>}
  end

  def encode(
        {:effect_event, source_cid, skill_id, cue_kind, {ox, oy, oz}, target_cid, {tx, ty, tz},
         radius, duration_ms}
      )
      when is_integer(source_cid) and is_integer(skill_id) do
    {:ok,
     <<@msg_effect_event, source_cid::64-big, skill_id::16-big, encode_cue_kind(cue_kind)::8,
       target_cid_or_zero(target_cid)::64-big-signed, ox::float-64-big, oy::float-64-big,
       oz::float-64-big, tx::float-64-big, ty::float-64-big, tz::float-64-big,
       radius::float-64-big, duration_ms::32-big>>}
  end

  def encode(
        {:voxel_chunk_snapshot,
         %{
           request_id: request_id,
           logical_scene_id: logical_scene_id,
           chunk_coord: {cx, cy, cz},
           schema_version: schema_version,
           chunk_size_in_macro: chunk_size_in_macro,
           micro_resolution: micro_resolution,
           chunk_version: chunk_version,
           chunk_hash: chunk_hash,
           sections: sections
         }}
      )
      when is_list(sections) do
    {:ok,
     [
       <<@msg_voxel_chunk_snapshot, request_id::64-big, logical_scene_id::64-big,
         cx::32-big-signed, cy::32-big-signed, cz::32-big-signed, schema_version::16-big,
         chunk_size_in_macro::8, micro_resolution::8, chunk_version::64-big, chunk_hash::64-big,
         length(sections)::16-big>>,
       encode_voxel_sections(sections)
     ]}
  end

  def encode({:voxel_chunk_snapshot_payload, payload}) when is_binary(payload) do
    {:ok, [<<@msg_voxel_chunk_snapshot>>, payload]}
  end

  def encode({:voxel_chunk_delta_payload, payload}) when is_binary(payload) do
    {:ok, [<<@msg_voxel_chunk_delta>>, payload]}
  end

  def encode({:voxel_chunk_invalidate_payload, payload}) when is_binary(payload) do
    {:ok, [<<@msg_voxel_chunk_invalidate>>, payload]}
  end

  def encode(
        {:voxel_heightmap_region,
         %{
           request_id: request_id,
           origin_x: origin_x,
           origin_z: origin_z,
           stride: stride,
           count_x: count_x,
           count_z: count_z,
           heights: heights
         } = region}
      )
      when is_binary(heights) do
    cells = count_x * count_z

    with {:ok, material_section} <-
           encode_heightmap_material_section(Map.get(region, :materials, <<>>), cells) do
      {:ok,
       [
         <<@msg_voxel_heightmap_region, request_id::64-big, origin_x::32-big-signed,
           origin_z::32-big-signed, stride::16-big, count_x::16-big, count_z::16-big>>,
         heights,
         material_section
       ]}
    end
  end

  def encode({:voxel_build_reservation_intent, %{} = intent}) do
    payload = SceneServer.Voxel.Codec.encode_build_reservation_intent_payload(intent)
    {:ok, [<<@msg_voxel_build_reservation_intent>>, payload]}
  end

  def encode({:voxel_prefab_place_intent, %{} = intent}) do
    payload = SceneServer.Voxel.Codec.encode_prefab_place_intent_payload(intent)
    {:ok, [<<@msg_voxel_prefab_place_intent>>, payload]}
  end

  def encode({:voxel_surface_element_intent, %{} = intent}) do
    with {:ok, request_id} <- u64!(intent[:request_id], :request_id),
         {:ok, client_intent_seq} <- u32!(intent[:client_intent_seq], :client_intent_seq),
         {:ok, logical_scene_id} <- u64!(intent[:logical_scene_id], :logical_scene_id),
         {:ok, action} <- u8!(intent[:action], :action),
         {:ok, {wx, wy, wz}} <- world_micro!(intent[:target_world_micro]),
         {:ok, face} <- u8!(intent[:face], :face),
         {:ok, surface_type_id} <- u16!(intent[:surface_type_id], :surface_type_id),
         {:ok, attribute_set_ref} <- u32!(intent[:attribute_set_ref], :attribute_set_ref),
         {:ok, tag_set_ref} <- u32!(intent[:tag_set_ref], :tag_set_ref) do
      {:ok,
       <<@msg_voxel_surface_element_intent, request_id::64-big, client_intent_seq::32-big,
         logical_scene_id::64-big, action::8, wx::64-big-signed, wy::64-big-signed,
         wz::64-big-signed, face::8, surface_type_id::16-big, attribute_set_ref::32-big,
         tag_set_ref::32-big>>}
    end
  end

  def encode({:voxel_debug_probe, %{request_id: request_id, result: result}})
      when is_binary(result) do
    {:ok,
     <<@msg_voxel_debug_probe, request_id::64-big, byte_size(result)::16-big, result::binary>>}
  end

  # Phase 4-bis (D2):0x6C ObjectStateDelta encoder 主战场已挪到
  # scene_server/voxel/codec.ex(对齐 chunk_snapshot/chunk_delta/chunk_invalidate
  # 风格)。gate codec 端只做 binary pass-through:scene 端先 encode
  # 出 binary,gate 端 prefix 0x6C opcode 后写到 socket。decode 仍保留在
  # gate 端供 server-side 调试 / 测试用(见 decode_voxel_object_state_delta_payload/1)。
  def encode({:voxel_object_state_delta_payload, payload}) when is_binary(payload) do
    {:ok, [<<@msg_voxel_object_state_delta>>, payload]}
  end

  def encode(_) do
    {:error, :unknown_message}
  end

  @doc """
  Phase 4:decodes a 0x6C `ObjectStateDelta` payload **(without the opcode
  byte)**. Returns `{:ok, %{...}, ""}` on success or `{:error, reason}`.
  """
  @spec decode_voxel_object_state_delta_payload(binary()) ::
          {:ok, map(), binary()} | {:error, atom()}
  def decode_voxel_object_state_delta_payload(
        <<logical_scene_id::64-big, object_id::64-big, object_version::64-big,
          state_flags::32-big, attribute_patch_count::16-big, tag_patch_count::16-big,
          affected_count::16-big, rest::binary>>
      ) do
    with {:ok, affected_chunks, after_chunks} <-
           decode_affected_chunks(rest, affected_count, []) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         object_id: object_id,
         object_version: object_version,
         state_flags: state_flags,
         attribute_patch_count: attribute_patch_count,
         tag_patch_count: tag_patch_count,
         affected_chunks: affected_chunks
       }, after_chunks}
    end
  end

  def decode_voxel_object_state_delta_payload(_), do: {:error, :invalid_object_state_delta}

  defp decode_affected_chunks(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_affected_chunks(
         <<x::32-big-signed, y::32-big-signed, z::32-big-signed, rest::binary>>,
         n,
         acc
       )
       when n > 0 do
    decode_affected_chunks(rest, n - 1, [{x, y, z} | acc])
  end

  defp decode_affected_chunks(_, _, _), do: {:error, :invalid_affected_chunks}

  defp decode_field_conduct_mode(1), do: :discharge
  defp decode_field_conduct_mode(_), do: :conductive

  defp decode_field_output_mode(1), do: :dc
  defp decode_field_output_mode(2), do: :ac
  defp decode_field_output_mode(3), do: :pulse
  defp decode_field_output_mode(_), do: nil

  defp maybe_put_field_output_mode(intent, flags, raw_mode) do
    if Bitwise.band(flags, 0x0001) != 0 do
      case decode_field_output_mode(raw_mode) do
        nil -> intent
        mode -> Map.put(intent, :output_mode, mode)
      end
    else
      intent
    end
  end

  defp maybe_put_field_power(intent, key, flags, flag, value) do
    if Bitwise.band(flags, flag) != 0 do
      Map.put(intent, key, value)
    else
      intent
    end
  end

  defp decode_voxel_known_chunks(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_voxel_known_chunks(
         <<cx::32-big-signed, cy::32-big-signed, cz::32-big-signed, version::64-big,
           rest::binary>>,
         count,
         acc
       )
       when count > 0 do
    decode_voxel_known_chunks(rest, count - 1, [
      %{chunk_coord: {cx, cy, cz}, chunk_version: version} | acc
    ])
  end

  defp decode_voxel_known_chunks(_rest, _count, _acc), do: {:error, :invalid_message}

  defp decode_voxel_chunk_coords(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_voxel_chunk_coords(
         <<cx::32-big-signed, cy::32-big-signed, cz::32-big-signed, rest::binary>>,
         count,
         acc
       )
       when count > 0 do
    decode_voxel_chunk_coords(rest, count - 1, [{cx, cy, cz} | acc])
  end

  defp decode_voxel_chunk_coords(_rest, _count, _acc), do: {:error, :invalid_message}

  defp encode_voxel_sections(sections) do
    Enum.map(sections, fn {section_type, section_data}
                          when is_integer(section_type) and is_binary(section_data) ->
      <<section_type::8, byte_size(section_data)::32-big, section_data::binary>>
    end)
  end

  defp encode_heightmap_material_section(nil, _cells), do: {:ok, []}
  defp encode_heightmap_material_section(<<>>, _cells), do: {:ok, []}

  defp encode_heightmap_material_section(materials, cells)
       when is_binary(materials) and is_integer(cells) and cells >= 0 do
    expected_bytes = cells * 2

    if byte_size(materials) == expected_bytes do
      {:ok,
       [
         <<@heightmap_section_materials_u16::8, expected_bytes::32-big>>,
         materials
       ]}
    else
      {:error, :invalid_heightmap_materials}
    end
  end

  defp encode_heightmap_material_section(_materials, _cells),
    do: {:error, :invalid_heightmap_materials}

  defp encode_movement_mode(:grounded), do: 0
  defp encode_movement_mode(:airborne), do: 1
  defp encode_movement_mode(:disabled), do: 2
  defp encode_movement_mode(:scripted), do: 3
  defp encode_movement_mode(mode) when is_integer(mode), do: mode
  defp encode_movement_mode(_mode), do: 0

  defp encode_priority_band(:high), do: 0
  defp encode_priority_band(:medium), do: 1
  defp encode_priority_band(:low), do: 2
  defp encode_priority_band(value) when is_integer(value), do: value
  defp encode_priority_band(_value), do: 0

  defp encode_bool(true), do: 1
  defp encode_bool(_), do: 0

  defp decode_bool(0), do: false
  defp decode_bool(_), do: true

  defp encode_actor_kind(:player), do: 0
  defp encode_actor_kind(:npc), do: 1
  defp encode_actor_kind(value) when is_integer(value), do: value
  defp encode_actor_kind(_value), do: 0

  defp decode_skill_target_kind(0), do: :auto
  defp decode_skill_target_kind(1), do: :actor
  defp decode_skill_target_kind(2), do: :point
  defp decode_skill_target_kind(_value), do: :auto

  defp decode_target_cid(value) when value < 0, do: nil
  defp decode_target_cid(value), do: value

  defp encode_cue_kind(:melee_arc), do: 0
  defp encode_cue_kind(:projectile), do: 1
  defp encode_cue_kind(:aoe_ring), do: 2
  defp encode_cue_kind(:chain_arc), do: 3
  defp encode_cue_kind(:impact_pulse), do: 4
  defp encode_cue_kind(value) when is_integer(value), do: value
  defp encode_cue_kind(_value), do: 0

  defp target_cid_or_zero(nil), do: -1
  defp target_cid_or_zero(value), do: value
end
