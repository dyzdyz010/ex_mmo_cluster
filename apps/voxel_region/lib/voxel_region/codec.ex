defmodule VoxelRegion.Codec do
  @moduledoc """
  Voxim R6 的线格式（决策稿 §4 / §5；客户端 `Voxim/Source/Voxim/Voxel/Net/VoxelRegionCodec.cpp`）。全部 little-endian。

  - 请求：`"VXRQ"` + version u32 + content_version u64（0 = 客户端还不知道）+ count u32 +
    items{level u8, region i32×3, have_seq u64, have_hash u64}（29 B / 项）
  - 应答：`"VXRS"` + version u32 + content_version u64（服务端的）+ count u32 +
    items{level u8, region i32×3, kind u8, [kind = payload: len u32 + RegionPayload bytes]}
  - RegionPayload 头（54 B）：`"VXR3"` + version u32 + level u8 + region i32×3 + seq u64 + content_version u64 +
    hash u64（解压后 body 的 MD5 前 8 字节）+ encoding u8（1 = zlib）+ raw_bytes u32 + body_bytes u32；body 紧随其后。
  - 日志条目（`0x77 VoxelLogEntry` 的 payload，也是 HTTP `entries` 的元素）：
    seq u64 + kind u8 (0 = cell) + coord i32×3 + material u16 + levels u8 +
    coarse × levels { level u8, cell i32×3, material u16, map_extent u8, faces × 6 { id u16, texels u8 × map_extent²（map_extent > 1 时）} }

  本模块只做编解码，不碰文件。
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

  def payload_header_bytes, do: @payload_header_bytes

  # ---- 请求 / 应答

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

  def encode_request(content_version, items) do
    [
      <<@request_magic, @wire_version::32-little, content_version::64-little, length(items)::32-little>>
      | Enum.map(items, fn %{level: level, region: {x, y, z}, have_seq: have_seq, have_hash: have_hash} ->
          <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, have_seq::64-little, have_hash::64-little>>
        end)
    ]
  end

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

  def decode_reply(<<@reply_magic, @wire_version::32-little, content_version::64-little, count::32-little, rest::binary>>) do
    decode_reply_items(rest, count, [], content_version)
  end

  def decode_reply(_), do: {:error, :invalid_reply}

  defp decode_reply_items(<<>>, 0, acc, cv), do: {:ok, cv, Enum.reverse(acc)}

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

  # ---- RegionPayload 头

  def decode_payload_header(
        <<@payload_magic, @payload_version::32-little, level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, seq::64-little,
          content_version::64-little, hash::64-little, encoding::8, raw_bytes::32-little, body_bytes::32-little, _rest::binary>>
      ) do
    {:ok, %{level: level, region: {x, y, z}, seq: seq, content_version: content_version, hash: hash, encoding: encoding, raw_bytes: raw_bytes, body_bytes: body_bytes}}
  end

  def decode_payload_header(_), do: {:error, :invalid_payload}

  @doc "头 + zlib body → 完整载荷字节。"
  def encode_payload(level, {x, y, z}, seq, content_version, raw_body) when is_binary(raw_body) do
    body = :zlib.compress(raw_body)

    <<@payload_magic, @payload_version::32-little, level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, seq::64-little,
      content_version::64-little, body_hash(raw_body)::64-little, 1::8, byte_size(raw_body)::32-little, byte_size(body)::32-little, body::binary>>
  end

  @doc "解压 body（校验 hash）。"
  def decode_payload_body(bytes) do
    with {:ok, header} <- decode_payload_header(bytes),
         <<_::binary-size(@payload_header_bytes), body::binary-size(header.body_bytes)>> <- bytes,
         raw <- if(header.encoding == 1, do: :zlib.uncompress(body), else: body),
         true <- body_hash(raw) == header.hash do
      {:ok, header, raw}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  def body_hash(raw) do
    <<hash::64-little, _::binary>> = :crypto.hash(:md5, raw)
    hash
  end

  # ---- 日志条目

  @doc "entry = %{seq, coord: {x,y,z}, material, coarse: [%{level, cell, material, skins: {ext, faces}}]}"
  def encode_entry(%{seq: seq, coord: {x, y, z}, material: material, coarse: coarse}) do
    [
      <<seq::64-little, 0::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, material::16-little, length(coarse)::8>>
      | Enum.map(coarse, fn %{level: level, cell: {cx, cy, cz}, material: m, skins: {ext, faces}} ->
          [
            <<level::8, cx::32-little-signed, cy::32-little-signed, cz::32-little-signed, m::16-little, ext::8>>
            | Enum.map(Tuple.to_list(faces), fn
                {id, nil} when ext == 1 -> <<id::16-little>>
                {id, nil} -> <<id::16-little, :binary.copy(<<id>>, ext * ext)::binary>>
                {id, texels} -> <<id::16-little, texels::binary>>
              end)
          ]
        end)
    ]
  end

  def decode_entry(<<seq::64-little, 0::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, material::16-little, levels::8, rest::binary>>) do
    with {:ok, coarse, <<>>} <- decode_coarse(rest, levels, []) do
      {:ok, %{seq: seq, coord: {x, y, z}, material: material, coarse: coarse}}
    else
      _ -> {:error, :invalid_entry}
    end
  end

  def decode_entry(_), do: {:error, :invalid_entry}

  defp decode_coarse(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_coarse(<<level::8, cx::32-little-signed, cy::32-little-signed, cz::32-little-signed, m::16-little, ext::8, rest::binary>>, n, acc) when n > 0 do
    texel_bytes = if ext > 1, do: ext * ext, else: 0

    {faces, rest} =
      Enum.reduce(1..6, {[], rest}, fn _, {faces, rest} ->
        <<id::16-little, texels::binary-size(texel_bytes), rest::binary>> = rest
        {[{id, if(texel_bytes == 0, do: nil, else: texels)} | faces], rest}
      end)

    skins = VoxelRegion.Reducer.canonical({ext, List.to_tuple(Enum.reverse(faces))})
    decode_coarse(rest, n - 1, [%{level: level, cell: {cx, cy, cz}, material: m, skins: skins} | acc])
  end

  defp decode_coarse(_, _, _), do: {:error, :invalid_entry}
end
