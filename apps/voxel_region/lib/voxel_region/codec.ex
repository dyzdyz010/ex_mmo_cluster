defmodule VoxelRegion.Codec do
  @moduledoc """
  Voxim R6 的线格式（决策稿 §4 / §5；客户端 `Voxim/Source/Voxim/Voxel/Net/VoxelRegionCodec.cpp`）。全部 little-endian。

  - 请求：`"VXRQ"` + version u32 + content_version u64（0 = 客户端还不知道）+ count u32 +
    items{level u8, region i32×3, have_seq u64, have_hash u64}（29 B / 项）
  - 应答：`"VXRS"` + version u32 + content_version u64（服务端的）+ count u32 +
    items{level u8, region i32×3, kind u8, [kind = payload: len u32 + RegionPayload bytes]}
    kind=entries：事务数 u32 + 每项长度 u32 / 事务信封（无 0x79 opcode）。客户端对已核对的磁盘副本解码后应用，不改写原文件。
  - RegionPayload 头（54 B）：`"VXR4"` + version u32 + level u8 + region i32×3 + seq u64 + content_version u64 +
    hash u64（解压后 body 的 MD5 前 8 字节）+ encoding u8（1 = zlib）+ raw_bytes u32 + body_bytes u32；body 紧随其后（布局见 `VoxelRegion.Payload`）。
  - 日志条目（`0x77 VoxelLogEntry` 的 payload，也是 HTTP `entries` 的元素）：
    seq u64 + kind u8 (0 = cell) + coord i32×3 + material u16 + levels u8 +
    coarse × levels { level u8, cell i32×3, material u16, map_extent u8, faces × 6 { id u16, texels u8 × map_extent²（map_extent > 1 时）} }
  - kind=1：seq u64 + kind u8 + 完整 RegionPayload。0x79 的事务信封：seq u64、条目数 u32、每项长度 u32/条目、粗格数 u32/粗格。

  本模块只做编解码，不碰文件。
  """

  @request_magic "VXRQ"
  @reply_magic "VXRS"
  @payload_magic "VXR4"
  @wire_version 1
  @payload_version 4
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

  defp encode_reply_item({:entries, level, {x,y,z}, transactions}) do
    [<<level::8,x::32-little-signed,y::32-little-signed,z::32-little-signed,@kind_entries::8,length(transactions)::32-little>>,
     Enum.map(transactions, fn txn -> b=IO.iodata_to_binary(encode_transaction(txn)); [<<byte_size(b)::32-little>>,b] end)]
  end

  def decode_reply(<<@reply_magic, @wire_version::32-little, content_version::64-little, count::32-little, rest::binary>>) do
    decode_reply_items(rest, count, [], content_version)
  end

  def decode_reply(_), do: {:error, :invalid_reply}

  defp decode_reply_items(<<>>, 0, acc, cv), do: {:ok, cv, Enum.reverse(acc)}

  defp decode_reply_items(<<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_unchanged::8, rest::binary>>, count, acc, cv) when count > 0,
    do: decode_reply_items(rest, count - 1, [{:unchanged, level, {x, y, z}} | acc], cv)

  defp decode_reply_items(<<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_missing::8, rest::binary>>, count, acc, cv) when count > 0,
    do: decode_reply_items(rest, count - 1, [{:missing, level, {x, y, z}} | acc], cv)

  defp decode_reply_items(<<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_entries::8, n::32-little, rest::binary>>, count, acc, cv) when count > 0 do
    with {:ok,txns,rest} <- decode_transactions(rest,n,[]) do
      decode_reply_items(rest,count-1,[{:entries,level,{x,y,z},txns}|acc],cv)
    end
  end

  defp decode_reply_items(
         <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_payload::8, len::32-little, payload::binary-size(len), rest::binary>>,
         count,
         acc,
         cv
       )
       when count > 0,
       do: decode_reply_items(rest, count - 1, [{:payload, level, {x, y, z}, payload} | acc], cv)

  defp decode_reply_items(_, _, _, _), do: {:error, :invalid_reply}

  defp decode_transactions(rest,0,acc), do: {:ok,Enum.reverse(acc),rest}
  defp decode_transactions(<<n::32-little,bytes::binary-size(n),rest::binary>>,count,acc) when count > 0 do
    with {:ok,txn} <- decode_transaction(bytes), do: decode_transactions(rest,count-1,[txn|acc])
  end
  defp decode_transactions(_,_,_), do: {:error,:invalid_reply}

  # ---- RegionPayload 头

  def decode_payload_header(
        <<@payload_magic, @payload_version::32-little, level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, seq::64-little,
          content_version::64-little, hash::64-little, encoding::8, raw_bytes::32-little, body_bytes::32-little, _rest::binary>>
      ) do
    {:ok, %{level: level, region: {x, y, z}, seq: seq, content_version: content_version, hash: hash, encoding: encoding, raw_bytes: raw_bytes, body_bytes: body_bytes}}
  end

  def decode_payload_header(_), do: {:error, :invalid_payload}

  @doc "快照内容未变而检查点前缀推进：只更新时间头；body/hash 保持不变。"
  def stamp_payload_seq(<<prefix::binary-size(21), _old_seq::64-little, rest::binary>>, seq) do
    <<prefix::binary, seq::64-little, rest::binary>>
  end

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

  @doc "事务信封：seq、带长度的条目数组、去重的粗格数组；全部小端。"
  def encode_transaction(%{seq: seq, entries: entries, coarse: coarse}) do
    [<<seq::64-little, length(entries)::32-little>>,
     Enum.map(entries, fn e -> b = IO.iodata_to_binary(encode_entry(e)); [<<byte_size(b)::32-little>>, b] end),
     <<length(coarse)::32-little>>, Enum.map(coarse, &encode_coarse/1)]
  end

  def decode_transaction(<<seq::64-little, count::32-little, rest::binary>>) do
    with {:ok, entries, <<n::32-little, rest::binary>>} <- decode_transaction_entries(rest, count, []),
         {:ok, coarse, <<>>} <- decode_coarse(rest, n, []) do
      {:ok, %{seq: seq, entries: entries, coarse: coarse}}
    else
      _ -> {:error, :invalid_transaction}
    end
  end

  defp decode_transaction_entries(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}
  defp decode_transaction_entries(<<n::32-little, b::binary-size(n), rest::binary>>, count, acc) when count > 0 do
    with {:ok, e} <- decode_entry(b), do: decode_transaction_entries(rest, count - 1, [e | acc])
  end
  defp decode_transaction_entries(_, _, _), do: {:error, :invalid_transaction}

  @doc "粗格记录的唯一编码，用于单格条目和事务。"
  def encode_coarse(%{level: level, cell: {x, y, z}, material: m, skins: {ext, faces}}) do
    [<<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, m::16-little, ext::8>>,
     Enum.map(Tuple.to_list(faces), fn
       {id, nil} when ext == 1 -> <<id::16-little>>
       {id, nil} -> <<id::16-little, :binary.copy(<<id>>, ext * ext)::binary>>
       {id, texels} -> <<id::16-little, texels::binary>>
     end)]
  end

  def encode_entry(%{seq: seq, payload: payload}), do: [<<seq::64-little, 1>>, payload]

  @doc "entry = %{seq, coord: {x,y,z}, material, coarse: [%{level, cell, material, skins: {ext, faces}}]}"
  def encode_entry(%{seq: seq, coord: {x, y, z}, material: material, coarse: coarse}) do
    [
      <<seq::64-little, 0::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, material::16-little, length(coarse)::8>>
      | Enum.map(coarse, &encode_coarse/1)
    ]
  end

  def decode_entry(<<seq::64-little, 0::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, material::16-little, levels::8, rest::binary>>) do
    with {:ok, coarse, <<>>} <- decode_coarse(rest, levels, []) do
      {:ok, %{seq: seq, coord: {x, y, z}, material: material, coarse: coarse}}
    else
      _ -> {:error, :invalid_entry}
    end
  end

  def decode_entry(<<seq::64-little, 1, payload::binary>>) do
    with {:ok, _, _} <- decode_payload_body(payload), do: {:ok, %{seq: seq, payload: payload}}
  end
  def decode_entry(_), do: {:error, :invalid_entry}

  @doc "一个粗格条目（`encode_coarse/1` 的逆），必须恰好用完字节。"
  def decode_coarse(bytes) do
    with {:ok, [coarse], <<>>} <- decode_coarse(bytes, 1, []), do: {:ok, coarse}
  end

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
