defmodule MmoContracts.Session.Codec do
  alias MmoContracts.Session

  @m1_messages %{
    1 =>
      {Session.Hello,
       [protocol_version: {:constant, :u16, 1}, kernel_id: :hash, profile_id: :hash]},
    2 =>
      {Session.Join, [request_id: :u64, username: :utf8, token: :utf8, cid: :u64, scene_id: :u64]},
    3 =>
      {Session.SessionStart,
       [
         identity: :identity,
         entity_id: :u64,
         entity_epoch: :u64,
         server_tick: :u64,
         server_time_us: :u64,
         content_version: :u64,
         collision_revision: :u64,
         baseline_transaction_seq: :u64,
         state: :state,
         profile: :profile
       ]},
    4 =>
      {Session.Ready,
       [identity: :identity, baseline_transaction_seq: :u64, collision_revision: :u64]},
    5 =>
      {Session.InputStart,
       [
         identity: :identity,
         anchor_tick: :u64,
         transaction_seq: :u64,
         collision_revision: :u64,
         state: :state,
         origin_tick: :u64,
         first_input_seq: {:constant, :u32, 1},
         prediction_lead_ticks: {:constant, :u16, 8}
       ]},
    6 => {Session.TimeProbe, [request_id: :u64, client_send_us: :u64]},
    7 =>
      {Session.TimeReply,
       [
         request_id: :u64,
         client_send_us: :u64,
         server_receive_us: :u64,
         server_send_us: :u64,
         server_tick: :u64
       ]},
    8 =>
      {Session.EntityEnter,
       [
         identity: :identity,
         entity_id: :u64,
         entity_epoch: :u64,
         interest_generation: :u64,
         server_tick: :u64,
         state: :state
       ]},
    9 =>
      {Session.EntityLeave,
       [
         identity: :identity,
         entity_id: :u64,
         entity_epoch: :u64,
         interest_generation: :u64,
         server_tick: :u64
       ]},
    10 => {Session.SessionEnd, [identity: :identity, reason: :reason]}
  }

  @moduledoc "现行认证、入场、心跳的纯字节契约；大端，入场位置仍为旧 UE/cm，不是 canonical 米。"

  @msg_enter_scene 0x02
  @msg_heartbeat 0x04
  @msg_auth_request 0x05
  @msg_result 0x80
  @msg_enter_scene_result 0x84
  @msg_heartbeat_reply 0x86
  @status_ok 0x00
  @status_error 0x01
  @max_username_bytes 1024
  @max_auth_code_bytes 4096

  @doc "当前上行 opcode 的归属，用于 Gate 纯路由选择。"
  defguard is_opcode(opcode) when opcode in [@msg_enter_scene, @msg_heartbeat, @msg_auth_request]

  @doc "当前下行消息的归属，用于 Gate 纯路由选择。"
  defguard is_message(message)
           when is_tuple(message) and tuple_size(message) > 0 and
                  elem(message, 0) in [:result, :enter_scene_result, :heartbeat_reply]

  @doc "现行帧字节（不含传输长度前缀）解码。"
  def decode(<<255, _::binary>> = bytes),
    do: MmoContracts.Session.Wire.decode(1, bytes, @m1_messages, &accept_m1/1)

  def decode(<<@msg_enter_scene, request_id::64-big, cid::64-big>>) do
    {:ok, {:enter_scene, cid, request_id}}
  end

  def decode(<<@msg_enter_scene, _rest::binary>>), do: {:error, :invalid_message}

  def decode(<<@msg_heartbeat, timestamp::64-big>>) do
    {:ok, {:heartbeat, timestamp}}
  end

  def decode(<<@msg_heartbeat, _rest::binary>>), do: {:error, :invalid_message}

  def decode(
        <<@msg_auth_request, request_id::64-big, ulen::16-big, username::binary-size(ulen),
          clen::16-big, code::binary-size(clen)>>
      )
      when ulen <= @max_username_bytes and clen <= @max_auth_code_bytes do
    {:ok, {:auth_request, username, code, request_id}}
  end

  def decode(<<@msg_auth_request, _rest::binary>>), do: {:error, :invalid_message}

  def decode(<<type::8, _::binary>>), do: {:error, {:unknown_message_type, type}}
  def decode(_), do: {:error, :invalid_message}

  @doc "协议值编码为现行帧 iodata。"
  def encode(%{__struct__: _} = message),
    do: MmoContracts.Session.Wire.encode(1, @m1_messages, message)

  def encode({:result, :ok, packet_id}) do
    {:ok, <<@msg_result, packet_id::64-big, @status_ok>>}
  end

  def encode({:result, :error, packet_id}) do
    {:ok, <<@msg_result, packet_id::64-big, @status_error>>}
  end

  def encode({:enter_scene_result, :ok, packet_id, {x, y, z}, expected_seq})
      when is_integer(expected_seq) and expected_seq >= 0 do
    {:ok,
     <<@msg_enter_scene_result, packet_id::64-big, @status_ok, x::float-64-big, y::float-64-big,
       z::float-64-big, expected_seq::32-big>>}
  end

  def encode({:enter_scene_result, :error, packet_id}) do
    {:ok, <<@msg_enter_scene_result, packet_id::64-big, @status_error>>}
  end

  def encode({:heartbeat_reply, timestamp}) do
    {:ok, <<@msg_heartbeat_reply, timestamp::64-big>>}
  end

  def encode(_), do: {:error, :unknown_message}

  @doc "profile 身份所用的规范 122 字节，导出时把 −0 变为 +0。"
  defdelegate encode_profile(profile), to: MmoContracts.Session.Wire

  @doc "SHA256(profile 前缀、规范 profile、raw32 blocking_hash)。"
  defdelegate profile_id(profile, blocking_hash), to: MmoContracts.Session.Wire

  @doc "未分配 identity 的 application close code；13 仅用于认证拒绝。"
  def pre_auth_close(reason) when reason in 1..13, do: 0x10000 + reason

  @doc "canonical Y-up yaw 对应水平朝向。"
  def yaw_forward(yaw),
    do: {:math.cos(yaw * 2 * :math.pi() / 65536), 0.0, :math.sin(yaw * 2 * :math.pi() / 65536)}

  @doc "最短 yaw 差（量化角单位）；恰半圈选正向。"
  def yaw_delta(from, to) do
    delta = Integer.mod(to - from, 65536)
    if delta > 32768, do: delta - 65536, else: delta
  end

  defp accept_m1(%Session.InputStart{anchor_tick: a, origin_tick: origin}),
    do: true = origin == a + 30

  defp accept_m1(_), do: :ok
end
