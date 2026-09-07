defmodule MmoContracts.Session.Codec do
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
end
