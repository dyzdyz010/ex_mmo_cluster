defmodule AuthServer.Voxel.RegionCodec do
  @moduledoc """
  `POST /ingame/voxel/regions` 的线格式（Voxim R6 决策稿 §4.1 / §5.1；客户端实现
  `Voxim/Source/Voxim/Voxel/Net/VoxelRegionCodec.cpp`）。全部 little-endian。

  - 请求：`"VXRQ"` + version u32 + content_version u64（0 = 客户端还不知道）+ count u32 +
    items{level u8, region i32×3, have_seq u64, have_hash u64}（29 B / 项）
  - 应答：`"VXRS"` + version u32 + content_version u64（服务端的）+ count u32 +
    items{level u8, region i32×3, kind u8, [kind = payload: len u32 + RegionPayload bytes]}
  - RegionPayload 头（54 B）：`"VXR3"` + version u32 + level u8 + region i32×3 + seq u64 + content_version u64 +
    hash u64（解压后 body 的 MD5 前 8 字节）+ encoding u8（1 = zlib）+ raw_bytes u32 + body_bytes u32；body 紧随其后。

  本模块只做编解码，不碰文件；`RegionFileStore` 用它。
  """

  @request_magic "VXRQ"
  @reply_magic "VXRS"
  @payload_magic "VXR3"
  @wire_version 1
  @payload_version 3
  @payload_header_bytes 54

  @kind_unchanged 0
  @kind_entries 1
  @kind_payload 2
  @kind_missing 3

  @type item :: %{level: non_neg_integer(), region: {integer(), integer(), integer()}, have_seq: non_neg_integer(), have_hash: non_neg_integer()}
  @type reply_item :: {:unchanged | :missing, non_neg_integer(), {integer(), integer(), integer()}} | {:payload, non_neg_integer(), {integer(), integer(), integer()}, binary()}
  @type header :: %{level: non_neg_integer(), region: {integer(), integer(), integer()}, seq: non_neg_integer(), content_version: non_neg_integer(), hash: non_neg_integer(), encoding: non_neg_integer(), raw_bytes: non_neg_integer(), body_bytes: non_neg_integer()}

  def payload_header_bytes, do: @payload_header_bytes

  @doc "解请求；坏帧 → `{:error, :invalid_request}`。"
  @spec decode_request(binary()) :: {:ok, non_neg_integer(), [item()]} | {:error, :invalid_request}
  def decode_request(<<@request_magic, @wire_version::32-little, content_version::64-little, count::32-little, rest::binary>>) do
    decode_items(rest, count, [], content_version)
  end

  def decode_request(_), do: {:error, :invalid_request}

  defp decode_items(<<>>, 0, acc, content_version), do: {:ok, content_version, Enum.reverse(acc)}

  defp decode_items(
         <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, have_seq::64-little, have_hash::64-little, rest::binary>>,
         count,
         acc,
         content_version
       )
       when count > 0 do
    decode_items(rest, count - 1, [%{level: level, region: {x, y, z}, have_seq: have_seq, have_hash: have_hash} | acc], content_version)
  end

  defp decode_items(_, _, _, _), do: {:error, :invalid_request}

  @doc "编应答。"
  @spec encode_reply(non_neg_integer(), [reply_item()]) :: iodata()
  def encode_reply(content_version, items) do
    [
      <<@reply_magic, @wire_version::32-little, content_version::64-little, length(items)::32-little>>
      | Enum.map(items, &encode_reply_item/1)
    ]
  end

  defp encode_reply_item({:unchanged, level, {x, y, z}}),
    do: <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_unchanged::8>>

  defp encode_reply_item({:missing, level, {x, y, z}}),
    do: <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_missing::8>>

  defp encode_reply_item({:payload, level, {x, y, z}, payload}) when is_binary(payload),
    do: [<<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_payload::8, byte_size(payload)::32-little>>, payload]

  @doc "解应答（测试用）。"
  @spec decode_reply(binary()) :: {:ok, non_neg_integer(), [reply_item()]} | {:error, :invalid_reply}
  def decode_reply(<<@reply_magic, @wire_version::32-little, content_version::64-little, count::32-little, rest::binary>>) do
    decode_reply_items(rest, count, [], content_version)
  end

  def decode_reply(_), do: {:error, :invalid_reply}

  defp decode_reply_items(<<>>, 0, acc, content_version), do: {:ok, content_version, Enum.reverse(acc)}

  defp decode_reply_items(<<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_unchanged::8, rest::binary>>, count, acc, cv) when count > 0,
    do: decode_reply_items(rest, count - 1, [{:unchanged, level, {x, y, z}} | acc], cv)

  defp decode_reply_items(<<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_missing::8, rest::binary>>, count, acc, cv) when count > 0,
    do: decode_reply_items(rest, count - 1, [{:missing, level, {x, y, z}} | acc], cv)

  defp decode_reply_items(<<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_entries::8, rest::binary>>, count, acc, cv) when count > 0,
    do: decode_reply_items(rest, count - 1, [{:entries, level, {x, y, z}} | acc], cv)

  defp decode_reply_items(
         <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_payload::8, len::32-little, payload::binary-size(len), rest::binary>>,
         count,
         acc,
         cv
       )
       when count > 0,
       do: decode_reply_items(rest, count - 1, [{:payload, level, {x, y, z}, payload} | acc], cv)

  defp decode_reply_items(_, _, _, _), do: {:error, :invalid_reply}

  @doc "读 RegionPayload 的 54 B 头；magic / 版本不对 → `{:error, :invalid_payload}`。"
  @spec decode_payload_header(binary()) :: {:ok, header()} | {:error, :invalid_payload}
  def decode_payload_header(
        <<@payload_magic, @payload_version::32-little, level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, seq::64-little,
          content_version::64-little, hash::64-little, encoding::8, raw_bytes::32-little, body_bytes::32-little, _rest::binary>>
      ) do
    {:ok,
     %{
       level: level,
       region: {x, y, z},
       seq: seq,
       content_version: content_version,
       hash: hash,
       encoding: encoding,
       raw_bytes: raw_bytes,
       body_bytes: body_bytes
     }}
  end

  def decode_payload_header(_), do: {:error, :invalid_payload}

  @doc "造一份 RegionPayload（测试 / 工具用；服务端生产路径只转发文件）。body 走 zlib。"
  @spec encode_payload(non_neg_integer(), {integer(), integer(), integer()}, non_neg_integer(), non_neg_integer(), binary()) :: binary()
  def encode_payload(level, {x, y, z}, seq, content_version, raw_body) when is_binary(raw_body) do
    body = :zlib.compress(raw_body)
    <<hash::64-little, _::binary>> = :crypto.hash(:md5, raw_body)

    <<@payload_magic, @payload_version::32-little, level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, seq::64-little,
      content_version::64-little, hash::64-little, 1::8, byte_size(raw_body)::32-little, byte_size(body)::32-little, body::binary>>
  end
end
