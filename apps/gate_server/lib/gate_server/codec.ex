defmodule GateServer.Codec do
  @moduledoc """
  Binary codec for the gate socket protocol.

  `GateServer.Codec` is the translation layer between raw TCP frames and the
  tuples consumed by `GateServer.TcpConnection`. The socket itself uses
  `{packet, 4}`, so this module only handles the payload after the 4-byte
  length prefix.

  ## Wire shape

  - message type is always 1 byte
  - request IDs and entity IDs are unsigned 64-bit big-endian integers
  - positions and velocities use 64-bit big-endian floats
  - variable-length text fields are prefixed with 16-bit big-endian lengths

  ## Message families

  ### Client → server

  - `0x01` MovementInput
  - `0x02` EnterScene
  - `0x03` TimeSync
  - `0x04` Heartbeat
  - `0x05` AuthRequest
  - `0x08` ChatSay
  - `0x09` SkillCast
  - `0x60` Voxel ChunkSubscribe
  - `0x61` Voxel ChunkUnsubscribe
  - `0x64` VoxelImpactIntent
  - `0x65` VoxelBuildReservationIntent
  - `0x66` VoxelSurfaceElementIntent
  - `0x67` VoxelPrefabPlaceIntent
  - `0x6F` VoxelDebugProbe
  - `0x75` FieldConductIntent

  ### Server → client

  - `0x80` Result
  - `0x81` PlayerEnter
  - `0x82` PlayerLeave
  - `0x83` PlayerMove
  - `0x84` EnterSceneResult
  - `0x85` TimeSync reply
  - `0x86` Heartbeat reply
  - `0x89` ChatMessage
  - `0x8A` SkillEvent
  - `0x8B` MovementAck
  - `0x8C` PlayerState
  - `0x8D` CombatHit
  - `0x8E` ActorIdentity
  - `0x8F` EffectEvent
  - `0x62` Voxel ChunkSnapshot
  - `0x68` VoxelIntentResult
  - `0x6B` VoxelHeightmapRegion
  - `0x6F` VoxelDebugProbe

  ## Round trip example

      iex> {:ok, bin} = GateServer.Codec.encode({:player_leave, 42})
      iex> byte_size(bin)
      9
      iex> GateServer.Codec.decode(<<0x04, 123::64-big>>)
      {:ok, {:heartbeat, 123}}
  """

  # ── Client → Server message types ──
  @msg_movement 0x01
  @msg_enter_scene 0x02
  @msg_time_sync 0x03
  @msg_heartbeat 0x04
  @msg_auth_request 0x05
  @msg_fast_lane_request 0x06
  @msg_fast_lane_attach 0x07
  @msg_chat_say 0x08
  @msg_skill_cast 0x09
  @msg_voxel_chunk_subscribe 0x60
  @msg_voxel_chunk_unsubscribe 0x61
  @msg_voxel_chunk_snapshot 0x62
  @msg_voxel_chunk_delta 0x63
  # DEPRECATED for client-side direct edit; use @msg_voxel_edit_intent (0x70).
  # Kept for skill/tool-system flow per protocol §13.6.
  @msg_voxel_impact_intent 0x64
  @msg_voxel_build_reservation_intent 0x65
  # 形态轨 C5.2:表面元件(火炬/拉杆)放置/清除——绑宿主宏格一面,零 occupancy。
  @msg_voxel_surface_element_intent 0x66
  @msg_voxel_prefab_place_intent 0x67
  @msg_voxel_intent_result 0x68
  @msg_voxel_chunk_invalidate 0x69
  @msg_voxel_object_state_delta 0x6C
  @msg_voxel_debug_probe 0x6F
  # Far/LOD terrain: client requests a coarse surface heightmap region; server
  # derives it from authoritative voxel snapshots / LOD mip truth and streams it
  # back (no client-side generation). See protocol §13.7.
  @msg_voxel_heightmap_request 0x6A
  @msg_voxel_heightmap_region 0x6B
  @heightmap_section_materials_u16 0x01
  @msg_voxel_edit_intent 0x70
  @msg_voxel_field_conduct_intent 0x75

  # ── Server → Client message types ──
  @msg_result 0x80
  @msg_player_enter 0x81
  @msg_player_leave 0x82
  @msg_player_move 0x83
  @msg_enter_scene_result 0x84
  @msg_time_sync_reply 0x85
  @msg_heartbeat_reply 0x86
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
  # 不进一步处理。配合 acceptor 的 packet_size 2MB 总帧上限,客户端→服务端不可逼爆内存。
  # 上限取「远大于任何合法输入、远小于 64KB u16 上界」:auth code / ticket 可能承载 JWT
  # (常见 ~1-2KB,带 claims 更长),故给 4KB 余量,避免误拒真实凭据。
  @max_username_bytes 1024
  @max_auth_code_bytes 4096
  @max_ticket_bytes 4096
  @max_chat_text_bytes 2048
  @max_known_chunks 512

  # ═══════════════════════════════════════════════════════════
  # Decode: binary → structured tuple
  # ═══════════════════════════════════════════════════════════

  @doc """
  Decode one payload frame into a protocol tuple.

  `decode/1` expects the binary after the 4-byte packet prefix has already been
  removed. When the frame is valid, it returns a tuple that the connection
  worker can dispatch immediately.

  ## Examples

      iex> GateServer.Codec.decode(<<0x04, 123::64-big>>)
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

  # EnterScene: 1 + 8 + 8 = 17 bytes
  def decode(<<@msg_enter_scene, request_id::64-big, cid::64-big>>) do
    {:ok, {:enter_scene, cid, request_id}}
  end

  def decode(<<@msg_enter_scene, _rest::binary>>), do: {:error, :invalid_message}

  # TimeSync: 1 + 8 + 8 = 17 bytes
  def decode(<<@msg_time_sync, request_id::64-big, client_send_ts::64-big>>) do
    {:ok, {:time_sync, request_id, client_send_ts}}
  end

  def decode(<<@msg_time_sync, _rest::binary>>), do: {:error, :invalid_message}

  # Heartbeat: 1 + 8 = 9 bytes
  def decode(<<@msg_heartbeat, timestamp::64-big>>) do
    {:ok, {:heartbeat, timestamp}}
  end

  def decode(<<@msg_heartbeat, _rest::binary>>), do: {:error, :invalid_message}

  # AuthRequest: 1 + 8 + 2 + username + 2 + code
  def decode(
        <<@msg_auth_request, request_id::64-big, ulen::16-big, username::binary-size(ulen),
          clen::16-big, code::binary-size(clen)>>
      )
      when ulen <= @max_username_bytes and clen <= @max_auth_code_bytes do
    {:ok, {:auth_request, username, code, request_id}}
  end

  def decode(<<@msg_auth_request, _rest::binary>>), do: {:error, :invalid_message}

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

  # VoxelHeightmapRequest (0x6A):
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

  # VoxelEditIntent (0x70) — typed client edit channel; see protocol §13.6.1.
  # Fixed 91-byte payload. Phase 1b: Gate decodes and observes only; routing
  # to Scene mutation API arrives in Phase 1c.
  def decode(
        <<@msg_voxel_edit_intent, request_id::64-big, client_intent_seq::32-big,
          logical_scene_id::64-big, action::8, target_granularity::8, wx::64-big-signed,
          wy::64-big-signed, wz::64-big-signed, fnx::8-signed, fny::8-signed, fnz::8-signed,
          material_id::16-big, blueprint_ref::32-big, object_ref::64-big, part_ref::32-big,
          attribute_patch_ref::32-big, expected_chunk_version::64-big, expected_cell_hash::32-big,
          client_hint_hash::64-big>>
      ) do
    {:ok,
     {:voxel_edit_intent,
      %{
        request_id: request_id,
        client_intent_seq: client_intent_seq,
        logical_scene_id: logical_scene_id,
        action: action,
        target_granularity: target_granularity,
        target_world_micro: {wx, wy, wz},
        face_normal: {fnx, fny, fnz},
        material_id: material_id,
        blueprint_ref: blueprint_ref,
        object_ref: object_ref,
        part_ref: part_ref,
        attribute_patch_ref: attribute_patch_ref,
        expected_chunk_version: expected_chunk_version,
        expected_cell_hash: expected_cell_hash,
        client_hint_hash: client_hint_hash
      }}}
  end

  def decode(<<@msg_voxel_edit_intent, _rest::binary>>), do: {:error, :invalid_message}

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

  # Unknown message type
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
  def encode({:result, :ok, packet_id}) do
    {:ok, <<@msg_result, packet_id::64-big, @status_ok>>}
  end

  def encode({:result, :error, packet_id}) do
    {:ok, <<@msg_result, packet_id::64-big, @status_error>>}
  end

  # ── EnterScene result (success with location + expected next input seq) ──
  # Audit B-S1 / B-SRV2: success carries expected_seq so the client can
  # initialise its local input-frame counter to the value the server is
  # going to validate against. v1 layout — no fallback / compatibility
  # branch; client and server must ship together.
  def encode({:enter_scene_result, :ok, packet_id, {x, y, z}, expected_seq})
      when is_integer(expected_seq) and expected_seq >= 0 do
    {:ok,
     <<@msg_enter_scene_result, packet_id::64-big, @status_ok, x::float-64-big, y::float-64-big,
       z::float-64-big, expected_seq::32-big>>}
  end

  def encode({:enter_scene_result, :error, packet_id}) do
    {:ok, <<@msg_enter_scene_result, packet_id::64-big, @status_error>>}
  end

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
  def encode({:heartbeat_reply, timestamp}) do
    {:ok, <<@msg_heartbeat_reply, timestamp::64-big>>}
  end

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

  # VoxelHeightmapRegion (0x6B):
  # 1 + request_id:u64 + origin_macro_x:i32 + origin_macro_z:i32 + stride:u16 +
  # count_x:u16 + count_z:u16 + heights:u16-be[count_x*count_z] (X fastest). Heights
  # are big-endian u16 (terrain peaks exceed 1 km, so the old u8 no longer fits).
  #
  # Optional trailing sections are appended after the fixed height array as
  # section_type:u8 + section_len:u32 + section_payload. Section 0x01 carries
  # top-surface material ids as u16-be[count_x*count_z], same X-fastest order.
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

  def encode(
        {:voxel_intent_result,
         %{
           request_id: request_id,
           client_intent_seq: client_intent_seq,
           logical_scene_id: logical_scene_id,
           result_code: result_code,
           result_ref: result_ref,
           authoritative: authoritative,
           reason: reason
         }}
      )
      when is_list(authoritative) and is_binary(reason) do
    {:ok,
     [
       <<@msg_voxel_intent_result, request_id::64-big, client_intent_seq::32-big,
         logical_scene_id::64-big, encode_voxel_result_code(result_code)::8, result_ref::64-big,
         length(authoritative)::16-big>>,
       encode_voxel_authoritative(authoritative),
       <<byte_size(reason)::16-big, reason::binary>>
     ]}
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

  def encode({:voxel_edit_intent, %{} = intent}) do
    case encode_voxel_edit_intent_payload(intent) do
      {:ok, payload} -> {:ok, [<<@msg_voxel_edit_intent>>, payload]}
      {:error, _} = err -> err
    end
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

  defp encode_voxel_edit_intent_payload(intent) do
    with {:ok, request_id} <- u64!(intent[:request_id], :request_id),
         {:ok, client_intent_seq} <- u32!(intent[:client_intent_seq], :client_intent_seq),
         {:ok, logical_scene_id} <- u64!(intent[:logical_scene_id], :logical_scene_id),
         {:ok, action} <- u8!(intent[:action], :action),
         {:ok, granularity} <- u8!(intent[:target_granularity], :target_granularity),
         {:ok, {wx, wy, wz}} <- world_micro!(intent[:target_world_micro]),
         {:ok, {fnx, fny, fnz}} <- face_normal!(intent[:face_normal]),
         {:ok, material_id} <- u16!(intent[:material_id], :material_id),
         {:ok, blueprint_ref} <- u32!(intent[:blueprint_ref], :blueprint_ref),
         {:ok, object_ref} <- u64!(intent[:object_ref], :object_ref),
         {:ok, part_ref} <- u32!(intent[:part_ref], :part_ref),
         {:ok, attribute_patch_ref} <- u32!(intent[:attribute_patch_ref], :attribute_patch_ref),
         {:ok, expected_chunk_version} <-
           u64!(intent[:expected_chunk_version], :expected_chunk_version),
         {:ok, expected_cell_hash} <- u32!(intent[:expected_cell_hash], :expected_cell_hash),
         {:ok, client_hint_hash} <- u64!(intent[:client_hint_hash], :client_hint_hash) do
      {:ok,
       <<request_id::64-big, client_intent_seq::32-big, logical_scene_id::64-big, action::8,
         granularity::8, wx::64-big-signed, wy::64-big-signed, wz::64-big-signed, fnx::8-signed,
         fny::8-signed, fnz::8-signed, material_id::16-big, blueprint_ref::32-big,
         object_ref::64-big, part_ref::32-big, attribute_patch_ref::32-big,
         expected_chunk_version::64-big, expected_cell_hash::32-big, client_hint_hash::64-big>>}
    end
  end

  defp u8!(v, _f) when is_integer(v) and v in 0..0xFF, do: {:ok, v}
  defp u8!(v, f), do: {:error, {:invalid_field, f, v}}

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

  defp u16!(v, _f) when is_integer(v) and v in 0..0xFFFF, do: {:ok, v}
  defp u16!(v, f), do: {:error, {:invalid_field, f, v}}

  defp u32!(v, _f) when is_integer(v) and v in 0..0xFFFF_FFFF, do: {:ok, v}
  defp u32!(v, f), do: {:error, {:invalid_field, f, v}}

  defp u64!(v, _f) when is_integer(v) and v >= 0 and v <= 0xFFFF_FFFF_FFFF_FFFF, do: {:ok, v}
  defp u64!(v, f), do: {:error, {:invalid_field, f, v}}

  defp world_micro!({x, y, z})
       when is_integer(x) and is_integer(y) and is_integer(z) and
              x in -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF and
              y in -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF and
              z in -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF do
    {:ok, {x, y, z}}
  end

  defp world_micro!(other), do: {:error, {:invalid_field, :target_world_micro, other}}

  defp face_normal!({nx, ny, nz})
       when is_integer(nx) and is_integer(ny) and is_integer(nz) and nx in -128..127 and
              ny in -128..127 and nz in -128..127 do
    {:ok, {nx, ny, nz}}
  end

  defp face_normal!(other), do: {:error, {:invalid_field, :face_normal, other}}

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

  defp encode_voxel_authoritative(authoritative) do
    Enum.map(authoritative, fn %{
                                 chunk_coord: {cx, cy, cz},
                                 chunk_version: chunk_version,
                                 macro_index: macro_index,
                                 cell_version: cell_version,
                                 cell_hash: cell_hash,
                                 payload_kind: payload_kind,
                                 cell_payload: cell_payload
                               }
                               when is_binary(cell_payload) ->
      <<cx::32-big-signed, cy::32-big-signed, cz::32-big-signed, chunk_version::64-big,
        macro_index::16-big, cell_version::32-big, cell_hash::32-big, payload_kind::8,
        byte_size(cell_payload)::32-big, cell_payload::binary>>
    end)
  end

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

  defp encode_voxel_result_code(:accepted), do: 0
  defp encode_voxel_result_code(:deferred), do: 1
  defp encode_voxel_result_code(:rejected), do: 2
  defp encode_voxel_result_code(:stale), do: 3
  defp encode_voxel_result_code(value) when is_integer(value), do: value
  defp encode_voxel_result_code(_value), do: 2

  defp target_cid_or_zero(nil), do: -1
  defp target_cid_or_zero(value), do: value
end
