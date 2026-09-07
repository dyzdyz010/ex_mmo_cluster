defmodule MmoContracts.Voxel.Codec do
  @moduledoc "现行体素编辑/订阅/结果帧与小端 region、日志字节的唯一 owner。"

  @msg_voxel_intent_result 0x68
  @msg_voxel_edit_intent 0x70
  @msg_voxel_overlay_subscribe 0x76
  @msg_voxel_log_entry 0x77
  @msg_voxel_batch_edit_intent 0x78
  @msg_voxel_log_transaction 0x79

  import MmoContracts.Voxel.Fields

  @doc "当前上行 opcode 的归属，用于 Gate 纯路由选择。"
  defguard is_opcode(opcode)
           when opcode in [
                  @msg_voxel_edit_intent,
                  @msg_voxel_overlay_subscribe,
                  @msg_voxel_batch_edit_intent
                ]

  @doc "当前下行消息的归属，用于 Gate 纯路由选择。"
  defguard is_message(message)
           when is_tuple(message) and tuple_size(message) > 0 and
                  elem(message, 0) in [
                    :voxel_edit_intent,
                    :voxel_intent_result,
                    :voxel_log_entry_payload,
                    :voxel_log_transaction_payload
                  ]

  @doc "现行帧字节（不含传输长度前缀）解码。"
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
        <<@msg_voxel_overlay_subscribe, have_seq::64-big, x0::32-big-signed, y0::32-big-signed,
          z0::32-big-signed, x1::32-big-signed, y1::32-big-signed, z1::32-big-signed,
          coarse_min_level::8>>
      ) do
    {:ok,
     {:voxel_overlay_subscribe,
      %{have_seq: have_seq, box: {{x0, y0, z0}, {x1, y1, z1}}, coarse_min_level: coarse_min_level}}}
  end

  def decode(<<@msg_voxel_overlay_subscribe, _rest::binary>>), do: {:error, :invalid_message}

  def decode(
        <<@msg_voxel_batch_edit_intent, rid::64-big, seq::32-big, scene::64-big, count::32-big,
          cells::binary>>
      )
      when byte_size(cells) == count * 14 do
    edits =
      for <<x::32-big-signed, y::32-big-signed, z::32-big-signed, m::16-big <- cells>>,
        do: {{x, y, z}, m}

    if Enum.all?(edits, fn {_, m} -> MmoContracts.VoxelMaterialCatalog.valid_id?(m) end) do
      {:ok,
       {:voxel_batch_edit_intent,
        %{request_id: rid, client_intent_seq: seq, logical_scene_id: scene, edits: edits}}}
    else
      {:error, :invalid_message}
    end
  end

  def decode(<<@msg_voxel_batch_edit_intent, _::binary>>), do: {:error, :invalid_message}

  def decode(<<type::8, _::binary>>), do: {:error, {:unknown_message_type, type}}
  def decode(_), do: {:error, :invalid_message}

  @doc "协议值编码为现行帧 iodata。"
  def encode({:voxel_log_entry_payload, payload}) when is_binary(payload) do
    {:ok, [<<@msg_voxel_log_entry>>, payload]}
  end

  def encode({:voxel_log_transaction_payload, payload}) when is_binary(payload) do
    {:ok, [<<@msg_voxel_log_transaction>>, payload]}
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

  def encode({:voxel_edit_intent, %{} = intent}) do
    case encode_voxel_edit_intent_payload(intent) do
      {:ok, payload} -> {:ok, [<<@msg_voxel_edit_intent>>, payload]}
      {:error, _} = err -> err
    end
  end

  def encode(_), do: {:error, :unknown_message}

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

  defp encode_voxel_result_code(:accepted), do: 0
  defp encode_voxel_result_code(:deferred), do: 1
  defp encode_voxel_result_code(:rejected), do: 2
  defp encode_voxel_result_code(:stale), do: 3
  defp encode_voxel_result_code(value) when is_integer(value), do: value
  defp encode_voxel_result_code(_value), do: 2

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

  @doc "完整 RegionPayload 固定头的字节数。"
  def payload_header_bytes, do: @payload_header_bytes

  # ---- 请求 / 应答

  @doc "HTTP region 请求解码为版本与条目数组。"
  def decode_request(
        <<@request_magic, @wire_version::32-little, content_version::64-little, count::32-little,
          rest::binary>>
      ) do
    decode_items(rest, count, [], content_version)
  end

  def decode_request(_), do: {:error, :invalid_request}

  defp decode_items(<<>>, 0, acc, content_version), do: {:ok, content_version, Enum.reverse(acc)}

  defp decode_items(
         <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
           have_seq::64-little, have_hash::64-little, rest::binary>>,
         count,
         acc,
         content_version
       )
       when count > 0 do
    decode_items(
      rest,
      count - 1,
      [%{level: level, region: {x, y, z}, have_seq: have_seq, have_hash: have_hash} | acc],
      content_version
    )
  end

  defp decode_items(_, _, _, _), do: {:error, :invalid_request}

  @doc "HTTP region 版本与请求条目编码为 iodata。"
  def encode_request(content_version, items) do
    [
      <<@request_magic, @wire_version::32-little, content_version::64-little,
        length(items)::32-little>>
      | Enum.map(items, fn %{
                             level: level,
                             region: {x, y, z},
                             have_seq: have_seq,
                             have_hash: have_hash
                           } ->
          <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
            have_seq::64-little, have_hash::64-little>>
        end)
    ]
  end

  @doc "HTTP 四类 region 应答编码为 iodata。"
  def encode_reply(content_version, items) do
    [
      <<@reply_magic, @wire_version::32-little, content_version::64-little,
        length(items)::32-little>>
      | Enum.map(items, &encode_reply_item/1)
    ]
  end

  defp encode_reply_item({:unchanged, level, {x, y, z}}),
    do:
      <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
        @kind_unchanged::8>>

  defp encode_reply_item({:missing, level, {x, y, z}}),
    do:
      <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
        @kind_missing::8>>

  defp encode_reply_item({:payload, level, {x, y, z}, payload}) when is_binary(payload),
    do: [
      <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_payload::8,
        byte_size(payload)::32-little>>,
      payload
    ]

  defp encode_reply_item({:entries, level, {x, y, z}, transactions}) do
    [
      <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, @kind_entries::8,
        length(transactions)::32-little>>,
      Enum.map(transactions, fn txn ->
        b = IO.iodata_to_binary(encode_transaction(txn))
        [<<byte_size(b)::32-little>>, b]
      end)
    ]
  end

  @doc "HTTP region 应答解码为版本与条目数组。"
  def decode_reply(
        <<@reply_magic, @wire_version::32-little, content_version::64-little, count::32-little,
          rest::binary>>
      ) do
    decode_reply_items(rest, count, [], content_version)
  end

  def decode_reply(_), do: {:error, :invalid_reply}

  defp decode_reply_items(<<>>, 0, acc, cv), do: {:ok, cv, Enum.reverse(acc)}

  defp decode_reply_items(
         <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
           @kind_unchanged::8, rest::binary>>,
         count,
         acc,
         cv
       )
       when count > 0,
       do: decode_reply_items(rest, count - 1, [{:unchanged, level, {x, y, z}} | acc], cv)

  defp decode_reply_items(
         <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
           @kind_missing::8, rest::binary>>,
         count,
         acc,
         cv
       )
       when count > 0,
       do: decode_reply_items(rest, count - 1, [{:missing, level, {x, y, z}} | acc], cv)

  defp decode_reply_items(
         <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
           @kind_entries::8, n::32-little, rest::binary>>,
         count,
         acc,
         cv
       )
       when count > 0 do
    with {:ok, txns, rest} <- decode_transactions(rest, n, []) do
      decode_reply_items(rest, count - 1, [{:entries, level, {x, y, z}, txns} | acc], cv)
    end
  end

  defp decode_reply_items(
         <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
           @kind_payload::8, len::32-little, payload::binary-size(len), rest::binary>>,
         count,
         acc,
         cv
       )
       when count > 0,
       do: decode_reply_items(rest, count - 1, [{:payload, level, {x, y, z}, payload} | acc], cv)

  defp decode_reply_items(_, _, _, _), do: {:error, :invalid_reply}

  defp decode_transactions(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_transactions(<<n::32-little, bytes::binary-size(n), rest::binary>>, count, acc)
       when count > 0 do
    with {:ok, txn} <- decode_transaction(bytes),
         do: decode_transactions(rest, count - 1, [txn | acc])
  end

  defp decode_transactions(_, _, _), do: {:error, :invalid_reply}

  # ---- RegionPayload 头

  @doc "读取完整 RegionPayload 头，不解压 body。"
  def decode_payload_header(
        <<@payload_magic, @payload_version::32-little, level::8, x::32-little-signed,
          y::32-little-signed, z::32-little-signed, seq::64-little, content_version::64-little,
          hash::64-little, encoding::8, raw_bytes::32-little, body_bytes::32-little,
          _rest::binary>>
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

  @doc "快照内容未变而检查点前缀推进：只更新时间头；body/hash 保持不变。"
  def stamp_payload_seq(<<prefix::binary-size(21), _old_seq::64-little, rest::binary>>, seq) do
    <<prefix::binary, seq::64-little, rest::binary>>
  end

  @doc "头 + zlib body → 完整载荷字节。"
  def encode_payload(level, {x, y, z}, seq, content_version, raw_body) when is_binary(raw_body) do
    body = :zlib.compress(raw_body)

    <<@payload_magic, @payload_version::32-little, level::8, x::32-little-signed,
      y::32-little-signed, z::32-little-signed, seq::64-little, content_version::64-little,
      body_hash(raw_body)::64-little, 1::8, byte_size(raw_body)::32-little,
      byte_size(body)::32-little, body::binary>>
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

  @doc "raw body 的 MD5 前八字节按小端解释为内容 hash。"
  def body_hash(raw) do
    <<hash::64-little, _::binary>> = :crypto.hash(:md5, raw)
    hash
  end

  # ---- 日志条目

  @doc "事务信封：seq、带长度的条目数组、去重的粗格数组；全部小端。"
  def encode_transaction(%{seq: seq, entries: entries, coarse: coarse}) do
    [
      <<seq::64-little, length(entries)::32-little>>,
      Enum.map(entries, fn e ->
        b = IO.iodata_to_binary(encode_entry(e))
        [<<byte_size(b)::32-little>>, b]
      end),
      <<length(coarse)::32-little>>,
      Enum.map(coarse, &encode_coarse/1)
    ]
  end

  @doc "小端事务信封解码为 seq、entries、coarse。"
  def decode_transaction(<<seq::64-little, count::32-little, rest::binary>>) do
    with {:ok, entries, <<n::32-little, rest::binary>>} <-
           decode_transaction_entries(rest, count, []),
         {:ok, coarse, <<>>} <- decode_coarse(rest, n, []) do
      {:ok, %{seq: seq, entries: entries, coarse: coarse}}
    else
      _ -> {:error, :invalid_transaction}
    end
  end

  defp decode_transaction_entries(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_transaction_entries(<<n::32-little, b::binary-size(n), rest::binary>>, count, acc)
       when count > 0 do
    with {:ok, e} <- decode_entry(b), do: decode_transaction_entries(rest, count - 1, [e | acc])
  end

  defp decode_transaction_entries(_, _, _), do: {:error, :invalid_transaction}

  @doc "粗格记录的唯一编码，用于单格条目和事务。"
  def encode_coarse(%{level: level, cell: {x, y, z}, material: m, skins: {ext, faces}}) do
    [
      <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, m::16-little,
        ext::8>>,
      Enum.map(Tuple.to_list(faces), fn
        {id, nil} when ext == 1 -> <<id::16-little>>
        {id, nil} -> <<id::16-little, :binary.copy(<<id>>, ext * ext)::binary>>
        {id, texels} -> <<id::16-little, texels::binary>>
      end)
    ]
  end

  def encode_entry(%{seq: seq, payload: payload}), do: [<<seq::64-little, 1>>, payload]

  @doc "entry = %{seq, coord: {x,y,z}, material, coarse: [%{level, cell, material, skins: {ext, faces}}]}"
  def encode_entry(%{seq: seq, coord: {x, y, z}, material: material, coarse: coarse}) do
    [
      <<seq::64-little, 0::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
        material::16-little, length(coarse)::8>>
      | Enum.map(coarse, &encode_coarse/1)
    ]
  end

  @doc "小端 cell 或完整 region 日志条目解码。"
  def decode_entry(
        <<seq::64-little, 0::8, x::32-little-signed, y::32-little-signed, z::32-little-signed,
          material::16-little, levels::8, rest::binary>>
      ) do
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

  defp decode_coarse(
         <<level::8, cx::32-little-signed, cy::32-little-signed, cz::32-little-signed,
           m::16-little, ext::8, rest::binary>>,
         n,
         acc
       )
       when n > 0 do
    texel_bytes = if ext > 1, do: ext * ext, else: 0

    {faces, rest} =
      Enum.reduce(1..6, {[], rest}, fn _, {faces, rest} ->
        <<id::16-little, texels::binary-size(texel_bytes), rest::binary>> = rest
        {[{id, if(texel_bytes == 0, do: nil, else: texels)} | faces], rest}
      end)

    skins = MmoContracts.Voxel.Skins.canonical({ext, List.to_tuple(Enum.reverse(faces))})

    decode_coarse(rest, n - 1, [
      %{level: level, cell: {cx, cy, cz}, material: m, skins: skins} | acc
    ])
  end

  defp decode_coarse(_, _, _), do: {:error, :invalid_entry}
end
