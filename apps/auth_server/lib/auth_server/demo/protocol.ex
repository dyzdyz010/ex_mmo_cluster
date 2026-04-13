defmodule Demo.Protocol do
  @moduledoc """
  Minimal wire helpers for scripted demo bots.
  """

  @status_ok 0x00

  def parse_gate_addr(addr) when is_binary(addr) do
    case String.split(addr, ":", parts: 2) do
      [host, port] ->
        case Integer.parse(port) do
          {parsed, ""} -> {:ok, {host, parsed}}
          _ -> {:error, :invalid_gate_addr}
        end

      _ ->
        {:error, :invalid_gate_addr}
    end
  end

  def encode_auth_request(username, token, request_id) do
    <<0x05, request_id::64-big, byte_size(username)::16-big, username::binary,
      byte_size(token)::16-big, token::binary>>
  end

  def encode_enter_scene(cid, request_id), do: <<0x02, request_id::64-big, cid::64-big>>
  def encode_fast_lane_request(request_id), do: <<0x06, request_id::64-big>>

  def encode_fast_lane_attach(request_id, ticket) do
    <<0x07, request_id::64-big, byte_size(ticket)::16-big, ticket::binary>>
  end

  def encode_chat_say(text, request_id) do
    <<0x08, request_id::64-big, byte_size(text)::16-big, text::binary>>
  end

  def encode_skill_cast(skill_id, request_id), do: <<0x09, request_id::64-big, skill_id::16-big>>

  def encode_movement_input(
        seq,
        client_tick,
        {input_dir_x, input_dir_y},
        dt_ms,
        speed_scale,
        movement_flags
      ) do
    <<0x01, seq::32-big, client_tick::32-big, dt_ms::16-big, input_dir_x::float-32-big,
      input_dir_y::float-32-big, speed_scale::float-32-big, movement_flags::16-big>>
  end

  def encode_time_sync(request_id, client_send_ts) do
    <<0x03, request_id::64-big, client_send_ts::64-big>>
  end

  def encode_heartbeat(timestamp), do: <<0x04, timestamp::64-big>>

  def decode_server(<<0x80, request_id::64-big, status::8>>) do
    {:ok, {:result, status(status), request_id}}
  end

  def decode_server(<<0x81, cid::64-big, x::float-64-big, y::float-64-big, z::float-64-big>>) do
    {:ok, {:player_enter, cid, {x, y, z}}}
  end

  def decode_server(<<0x82, cid::64-big>>) do
    {:ok, {:player_leave, cid}}
  end

  def decode_server(
        <<0x83, cid::64-big, server_tick::32-big, x::float-64-big, y::float-64-big,
          z::float-64-big, vx::float-64-big, vy::float-64-big, vz::float-64-big, ax::float-64-big,
          ay::float-64-big, az::float-64-big, movement_mode::8>>
      ) do
    {:ok, {:player_move, cid, server_tick, {x, y, z}, {vx, vy, vz}, {ax, ay, az}, movement_mode}}
  end

  def decode_server(
        <<0x84, request_id::64-big, status::8, x::float-64-big, y::float-64-big, z::float-64-big>>
      ) do
    {:ok, {:enter_scene_result, status(status), request_id, {x, y, z}}}
  end

  def decode_server(<<0x84, request_id::64-big, status::8>>) do
    {:ok, {:enter_scene_result, status(status), request_id, nil}}
  end

  def decode_server(
        <<0x85, request_id::64-big, client_ts::64-big, server_recv_ts::64-big,
          server_send_ts::64-big>>
      ) do
    {:ok, {:time_sync_reply, request_id, client_ts, server_recv_ts, server_send_ts}}
  end

  def decode_server(<<0x86, timestamp::64-big>>) do
    {:ok, {:heartbeat_reply, timestamp}}
  end

  def decode_server(
        <<0x87, request_id::64-big, status::8, udp_port::16-big, tlen::16-big,
          ticket::binary-size(tlen)>>
      ) do
    {:ok, {:fast_lane_result, status(status), request_id, udp_port, ticket}}
  end

  def decode_server(<<0x87, request_id::64-big, status::8>>) do
    {:ok, {:fast_lane_result, status(status), request_id, nil, nil}}
  end

  def decode_server(<<0x88, request_id::64-big, status::8>>) do
    {:ok, {:fast_lane_attached, status(status), request_id}}
  end

  def decode_server(
        <<0x8B, ack_seq::32-big, auth_tick::32-big, cid::64-big, x::float-64-big, y::float-64-big,
          z::float-64-big, vx::float-64-big, vy::float-64-big, vz::float-64-big, ax::float-64-big,
          ay::float-64-big, az::float-64-big, movement_mode::8, correction_flags::32-big>>
      ) do
    {:ok,
     {:movement_ack, ack_seq, auth_tick, cid, {x, y, z}, {vx, vy, vz}, {ax, ay, az},
      movement_mode, correction_flags}}
  end

  def decode_server(
        <<0x89, cid::64-big, ulen::16-big, username::binary-size(ulen), tlen::16-big,
          text::binary-size(tlen)>>
      ) do
    {:ok, {:chat_message, cid, username, text}}
  end

  def decode_server(
        <<0x8A, cid::64-big, skill_id::16-big, x::float-64-big, y::float-64-big, z::float-64-big>>
      ) do
    {:ok, {:skill_event, cid, skill_id, {x, y, z}}}
  end

  def decode_server(_payload), do: {:error, :unknown_payload}

  defp status(@status_ok), do: :ok
  defp status(_), do: :error
end
