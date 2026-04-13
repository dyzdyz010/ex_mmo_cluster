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

  # ── Status codes ──
  @status_ok 0x00
  @status_error 0x01

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
      ) do
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
      ) do
    {:ok, {:fast_lane_attach, request_id, ticket}}
  end

  # ChatSay: 1 + 8 + 2 + text
  def decode(<<@msg_chat_say, request_id::64-big, tlen::16-big, text::binary-size(tlen)>>) do
    {:ok, {:chat_say, text, request_id}}
  end

  def decode(<<@msg_chat_say, _rest::binary>>), do: {:error, :invalid_message}

  # SkillCast: 1 + 8 + 2
  def decode(<<@msg_skill_cast, request_id::64-big, skill_id::16-big>>) do
    {:ok, {:skill_cast, skill_id, request_id}}
  end

  def decode(<<@msg_skill_cast, _rest::binary>>), do: {:error, :invalid_message}

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

  # ── EnterScene result (success with location) ──
  def encode({:enter_scene_result, :ok, packet_id, {x, y, z}}) do
    {:ok,
     <<@msg_enter_scene_result, packet_id::64-big, @status_ok, x::float-64-big, y::float-64-big,
       z::float-64-big>>}
  end

  def encode({:enter_scene_result, :error, packet_id}) do
    {:ok, <<@msg_enter_scene_result, packet_id::64-big, @status_error>>}
  end

  # ── Movement ack ──
  def encode(
        {:movement_ack, ack_seq, auth_tick, cid, {px, py, pz}, {vx, vy, vz}, {ax, ay, az},
         movement_mode, correction_flags}
      ) do
    {:ok,
     <<@msg_movement_ack, ack_seq::32-big, auth_tick::32-big, cid::64-big, px::float-64-big,
       py::float-64-big, pz::float-64-big, vx::float-64-big, vy::float-64-big, vz::float-64-big,
       ax::float-64-big, ay::float-64-big, az::float-64-big, encode_movement_mode(movement_mode),
       correction_flags::32-big>>}
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

  def encode(_) do
    {:error, :unknown_message}
  end

  defp encode_movement_mode(:grounded), do: 0
  defp encode_movement_mode(:airborne), do: 1
  defp encode_movement_mode(:disabled), do: 2
  defp encode_movement_mode(mode) when is_integer(mode), do: mode
  defp encode_movement_mode(_mode), do: 0

  defp encode_bool(true), do: 1
  defp encode_bool(_), do: 0
end
