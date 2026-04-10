defmodule GateServer.Codec do
  @moduledoc """
  Custom binary codec for game messages.

  Replaces protobuf for maximum decode/encode performance using Erlang
  binary pattern matching. All vectors use float-64 (double precision)
  for consistency with internal representation and Rust NIFs.

  ## Wire Format

  Each message (after the 4-byte length header handled by `{packet, 4}`)
  starts with a 1-byte message type ID followed by type-specific fields.

  ## Message Type IDs

  ### Client → Server (0x01–0x7F)
    - 0x01: Movement
    - 0x02: EnterScene
    - 0x03: TimeSync
    - 0x04: Heartbeat
    - 0x05: AuthRequest

  ### Server → Client (0x80–0xFF)
    - 0x80: Result (generic reply)
    - 0x81: PlayerEnter (broadcast)
    - 0x82: PlayerLeave (broadcast)
    - 0x83: PlayerMove (broadcast)
    - 0x84: EnterSceneResult
    - 0x85: TimeSync (reply)
    - 0x86: Heartbeat (reply)
  """

  # ── Client → Server message types ──
  @msg_movement 0x01
  @msg_enter_scene 0x02
  @msg_time_sync 0x03
  @msg_heartbeat 0x04
  @msg_auth_request 0x05

  # ── Server → Client message types ──
  @msg_result 0x80
  @msg_player_enter 0x81
  @msg_player_leave 0x82
  @msg_player_move 0x83
  @msg_enter_scene_result 0x84
  @msg_time_sync_reply 0x85
  @msg_heartbeat_reply 0x86

  # ── Status codes ──
  @status_ok 0x00
  @status_error 0x01

  # ═══════════════════════════════════════════════════════════
  # Decode: binary → structured tuple
  # ═══════════════════════════════════════════════════════════

  @doc """
  Decode a binary message (without the 4-byte length prefix) into a tuple.

  Returns `{:ok, message_tuple}` or `{:error, reason}`.
  """
  @spec decode(binary()) :: {:ok, tuple()} | {:error, atom()}

  # Movement: 1 + 8 + 8 + 8 + (9 * 8) = 97 bytes
  def decode(
        <<@msg_movement, request_id::64-big, cid::64-big, timestamp::64-big, lx::float-64-big,
          ly::float-64-big, lz::float-64-big, vx::float-64-big, vy::float-64-big,
          vz::float-64-big, ax::float-64-big, ay::float-64-big, az::float-64-big>>
      ) do
    {:ok, {:movement, cid, timestamp, {lx, ly, lz}, {vx, vy, vz}, {ax, ay, az}, request_id}}
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
  Encode a message tuple into binary (without the 4-byte length prefix;
  `{packet, 4}` on the socket handles that automatically).

  Returns `{:ok, iodata}` or `{:error, reason}`.
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

  # ── Movement result (ack with player location) ──
  def encode({:movement_result, :ok, packet_id, cid, {x, y, z}}) do
    {:ok,
     <<@msg_result, packet_id::64-big, @status_ok, cid::64-big, x::float-64-big, y::float-64-big,
       z::float-64-big>>}
  end

  # ── Broadcast: player enter ──
  def encode({:player_enter, cid, {x, y, z}}) do
    {:ok, <<@msg_player_enter, cid::64-big, x::float-64-big, y::float-64-big, z::float-64-big>>}
  end

  # ── Broadcast: player leave ──
  def encode({:player_leave, cid}) do
    {:ok, <<@msg_player_leave, cid::64-big>>}
  end

  # ── Broadcast: player move ──
  def encode({:player_move, cid, {x, y, z}}) do
    {:ok, <<@msg_player_move, cid::64-big, x::float-64-big, y::float-64-big, z::float-64-big>>}
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

  def encode(_) do
    {:error, :unknown_message}
  end
end
