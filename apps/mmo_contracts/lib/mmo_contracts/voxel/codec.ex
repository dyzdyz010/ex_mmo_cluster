defmodule MmoContracts.Voxel.Codec do
  alias MmoContracts.Voxel

  @m1_messages %{
    1 =>
      {Voxel.CollisionApplied,
       [
         identity: :identity,
         collision_revision: :u64,
         transaction_seq: :u64,
         apply_tick: :u64,
         changed_chunks: {:array, :u32, :coord}
       ]},
    2 =>
      {Voxel.CanonicalBootstrap,
       [
         identity: :identity,
         content_version: :u64,
         collision_revision: :u64,
         transaction_seq: :u64,
         l0_min: :coord,
         l0_max_exclusive: :coord,
         travel_min_m: :vec3,
         travel_max_exclusive_m: :vec3,
         regions: {:array, :u32, :region}
       ]},
    3 =>
      {Voxel.TimelineFence,
       [identity: :identity, server_tick: :u64, transaction_seq: :u64, collision_revision: :u64]},
    4 =>
      {Voxel.CollisionWindow,
       [
         apply_tick: :u64,
         identity: :identity,
         content_version: :u64,
         collision_revision: :u64,
         transaction_seq: :u64,
         l0_min: :coord,
         l0_max_exclusive: :coord,
         travel_min_m: :vec3,
         travel_max_exclusive_m: :vec3,
         regions: {:array, :u32, :region}
       ]},
    5 =>
      {Voxel.PropertyBatch,
       [
         identity: :identity,
         transaction_seq: :u64,
         l0_min: :coord,
         l0_max_exclusive: :coord,
         complete: :bool,
         hp_enabled: :bool,
         digest: :hash,
         thermal_enabled: :bool,
         ambient_kelvin: :f64,
         epochs: :bytes,
         states: {:array, :u32, :bytes},
         protection: :bytes,
         semblances: :bytes,
         casts: :bytes
       ]}
  }

  @doc "新增 M1 Voxel envelope；既有 R6 入口和内嵌字节不变。"
  def encode_m1(message), do: MmoContracts.Session.Wire.encode(3, @m1_messages, message)

  @doc "在网络边界一次解析 M1 Voxel envelope。"
  def decode_m1(bytes), do: MmoContracts.Session.Wire.decode(3, bytes, @m1_messages, &accept_m1/1)

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
                  @msg_voxel_batch_edit_intent,
                  0x71,
                  0x7A,
                  0x7B,
                  0x7C,
                  0x7D,
                  0x7F,
                  0x81,
                  0x82
                ]

  @doc "当前下行消息的归属，用于 Gate 纯路由选择。"
  defguard is_message(message)
           when is_tuple(message) and tuple_size(message) > 0 and
                  elem(message, 0) in [
                    :voxel_edit_intent,
                    :voxel_intent_result,
                    :voxel_log_entry_payload,
                    :voxel_log_transaction_payload,
                    :voxel_property_state,
                    :voxel_material_balance,
                    :voxel_caster_state
                  ]

  @doc "工具意图的合法性，线解码与进程内调用方（NPC Body）共用同一组约束。"
  def tool_intent?(%{action: action, tool_id: tool, direction: {dx, dy, dz}} = request) do
    norm = dx * dx + dy * dy + dz * dz

    action in [0, 1, 2] and tool > 0 and Map.get(request, :granularity, 0) in [0, 1, 2, 3] and
      norm > 0.99 and norm < 1.01
  end

  @doc "生产意图（0 余额、1 放置、2 盛取、3 倾倒、4 按目录配方合成 material 一次）的合法性，线解码与进程内调用方（NPC Body）共用。"
  def production_intent?(%{action: action, tool_id: tool}), do: action in [0, 1, 2, 3, 4] and tool > 0

  @doc "附件意图的合法性，线解码与进程内调用方（NPC Body）共用同一组约束。"
  def attachment_intent?(%{action: action, kind: kind, axis: axis, size: size, tool_id: tool}),
    do: action in [0, 1] and kind in [0, 1] and axis in 0..2 and size in [1, 8] and tool > 0

  @doc "Prefab 放置的合法性，线解码与进程内调用方（NPC Body）共用。"
  def prefab_place?(%{definition_id: id, orientation: orientation}),
    do: byte_size(id) == 32 and orientation in 0..23

  @doc """
  魔法施法意图 0x82（Hello 25），大端，与 0x7D 工具意图同一目标表示：
  rid u64、client_intent_seq u32、scene u64、action u8（0 报价 / 1 施放）、魔法目录 digest 32B、
  眼睛方向 f64×3（单位向量）、目标微格 i64×3、incarnation u64、owner {birth u64, occurrence u32}、material u16、
  granularity u8（0..2）、目标拟态 id {seq u64, n u32}（增量 2，驱散用；其余程序填 0）、程序 u16 长度 + UTF-8 JSON。
  程序内容由 `VoxelRegion.Magic.Program` 在 World 裁决。
  """
  def spell_intent?(%{action: action, direction: {dx, dy, dz}, granularity: granularity}) do
    norm = dx * dx + dy * dy + dz * dz
    action in [0, 1] and granularity in [0, 1, 2] and norm > 0.99 and norm < 1.01
  end

  @doc "现行帧字节（不含传输长度前缀）解码。"
  def decode(
        <<0x81, rid::64, seq::32, scene::64, action, kind, axis, size, x::signed-64, y::signed-64,
          z::signed-64, id::64, material::16, tool::16>>
      ) do
    request = %{
      request_id: rid,
      client_intent_seq: seq,
      logical_scene_id: scene,
      action: action,
      kind: kind,
      axis: axis,
      size: size,
      anchor: {x, y, z},
      id: id,
      material: material,
      tool_id: tool
    }

    if attachment_intent?(request),
      do: {:ok, {:voxel_attachment_intent, request}},
      else: {:error, :invalid_message}
  end

  def decode(<<0x81, _::binary>>), do: {:error, :invalid_message}

  def decode(
        <<0x82, rid::64, seq::32, scene::64, action::8, digest::binary-size(32), dx::float-64,
          dy::float-64, dz::float-64, x::signed-64, y::signed-64, z::signed-64, incarnation::64,
          birth::64, occurrence::32, material::16, granularity::8, semblance_seq::64, semblance_n::32, n::16,
          program::binary-size(n)>>
      ) do
    request = %{
      request_id: rid,
      client_intent_seq: seq,
      logical_scene_id: scene,
      action: action,
      catalog_digest: digest,
      direction: {dx, dy, dz},
      micro: {x, y, z},
      incarnation: incarnation,
      owner: {birth, occurrence},
      material: material,
      granularity: granularity,
      semblance: {semblance_seq, semblance_n},
      program: program
    }

    if spell_intent?(request),
      do: {:ok, {:voxel_spell_intent, request}},
      else: {:error, :invalid_message}
  end

  def decode(<<0x82, _::binary>>), do: {:error, :invalid_message}

  def decode(
        <<0x7F, rid::64, seq::32, scene::64, action::8, x::signed-32, y::signed-32, z::signed-32,
          tool::16, material::16>>
      ) do
    request = %{
      request_id: rid,
      client_intent_seq: seq,
      logical_scene_id: scene,
      action: action,
      coord: {x, y, z},
      tool_id: tool,
      material: material
    }

    if production_intent?(request),
      do: {:ok, {:voxel_production_intent, request}},
      else: {:error, :invalid_message}
  end

  def decode(<<0x7F, _::binary>>), do: {:error, :invalid_message}

  def decode(
        <<0x7D, rid::64, seq::32, scene::64, action::8, dx::float-64, dy::float-64, dz::float-64,
          x::signed-64, y::signed-64, z::signed-64, incarnation::64, birth::64, occurrence::32,
          material::16, tool::16, granularity::8>>
      ) do
    request = %{
      request_id: rid,
      client_intent_seq: seq,
      logical_scene_id: scene,
      action: action,
      direction: {dx, dy, dz},
      micro: {x, y, z},
      incarnation: incarnation,
      owner: {birth, occurrence},
      material: material,
      tool_id: tool,
      granularity: granularity
    }

    if tool_intent?(request),
      do: {:ok, {:voxel_tool_intent, request}},
      else: {:error, :invalid_message}
  end

  def decode(<<0x7D, _::binary>>), do: {:error, :invalid_message}

  def decode(
        <<0x7A, rid::64, seq::32, scene::64, id::binary-size(32), x::signed-64, y::signed-64,
          z::signed-64, orientation::8>>
      ) do
    request = %{
      request_id: rid,
      client_intent_seq: seq,
      logical_scene_id: scene,
      definition_id: id,
      anchor: {x, y, z},
      orientation: orientation
    }

    if prefab_place?(request),
      do: {:ok, {:voxel_prefab_place_v1, request}},
      else: {:error, :invalid_message}
  end

  def decode(<<0x7B, rid::64, seq::32, scene::64, birth::64, occurrence::32>>) do
    {:ok,
     {:voxel_prefab_remove_v1,
      %{
        request_id: rid,
        client_intent_seq: seq,
        logical_scene_id: scene,
        instance_id: {birth, occurrence}
      }}}
  end

  def decode(
        <<0x7C, rid::64, seq::32, scene::64, birth::64, occurrence::32, id::binary-size(32)>>
      ) do
    {:ok,
     {:voxel_prefab_replace_v1,
      %{
        request_id: rid,
        client_intent_seq: seq,
        logical_scene_id: scene,
        instance_id: {birth, occurrence},
        definition_id: id
      }}}
  end

  def decode(<<opcode, _::binary>>) when opcode in [0x7A, 0x7B, 0x7C],
    do: {:error, :invalid_message}

  # D3 玩家运行时发布：整份 VXPD 字节 + 名称（Hello18）；名称、上限、格式与目录校验由 World.publish_prefab 统一裁决。
  def decode(
        <<0x71, rid::64, seq::32, scene::64, n::32, definition::binary-size(n), name_len::16,
          name::binary-size(name_len)>>
      ),
      do:
        {:ok,
         {:voxel_prefab_publish_v1,
          %{
            request_id: rid,
            client_intent_seq: seq,
            logical_scene_id: scene,
            definition: definition,
            name: name
          }}}

  def decode(<<0x71, _::binary>>), do: {:error, :invalid_message}

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
  def encode({:voxel_material_balance, t}) do
    {:ok, <<0x81, t.request_id::64, t.seq::64, t.material::16, t.balance::64, t.cost::32>>}
  end

  # 魔法增量 1（Hello 24）施法者状态 0x83，大端：request_id u64（登录下发为 0）、world seq u64、
  # 能量 J、容量 J、相干度、最近一次报价总支出 J、报价结构权重 S、本次实际支出 J（报价与登录为 0），
  # Hello 28 末尾追加本次报价的前摇 s（非报价推送为 0），均为 f64。
  def encode({:voxel_caster_state, t}) do
    {:ok,
     <<0x83, t.request_id::64, t.seq::64, t.energy_j::float-64, t.capacity_j::float-64,
       t.coherence::float-64, t.quote_j::float-64, t.quote_s::float-64, t.spent_j::float-64,
       t.quote_windup_s::float-64>>}
  end

  def encode({:voxel_property_state, t}) do
    {x, y, z} = t.micro
    {birth, occurrence} = t.owner

    temperature =
      case Map.fetch(t, :temperature_kelvin) do
        {:ok, value} -> <<value::float-64>>
        :error -> <<>>
      end

    combustion =
      case Map.fetch(t, :burning) do
        {:ok, burning} ->
          <<if(burning, do: 1, else: 0)::8, t.remaining_fuel_j::float-64, t.power_w::float-64>>

        :error ->
          <<>>
      end

    # 协议 20：发光导体（目录 λ > 0）的电功率与穿过电流，只随带温度的格/槽记录出现，16 字节、在最后；
    # 由 flags 位 1 声明（位 0 仍是删除），不靠剩余长度猜。
    {electric, present} =
      case Map.fetch(t, :electric_w) do
        {:ok, w} -> {<<w::float-64, t.current_a::float-64>>, 2}
        :error -> {<<>>, 0}
      end

    # 协议 21：开关材料（目录 circuit_switch）的格／附件行闭合时置 flags 位 2，无后缀；缺省或断开为 0。
    closed = if Map.get(t, :closed, false), do: 4, else: 0

    # 协议 22：蓄能石／热电石格行的电源后缀 24 字节（储能 J、电动势 V、带号电流 A，+ 为向外供能），flags 位 3，
    # 在发光后缀之后。只有储能而本段不在网络里的蓄能石行电动势与电流为 0。设备记录（原电源等）已无生产者，不再编码。
    {source, supply} =
      if Map.has_key?(t, :stored_j) or Map.has_key?(t, :source_emf_v),
        do: {<<Map.get(t, :stored_j, 0.0)::float-64, Map.get(t, :source_emf_v, 0.0)::float-64,
               Map.get(t, :source_current_a, 0.0)::float-64>>, 8},
        else: {<<>>, 0}

    {:ok,
     <<0x7E, t.request_id::64, t.seq::64, x::signed-64, y::signed-64, z::signed-64,
       t.granularity::8, t.incarnation::64, birth::64, occurrence::32, t.material::16,
       t.hp::float-64, t.max_hp::float-64, t.defense::float-64, t.digest::binary-size(32),
       t.flags + present + closed + supply::8, temperature::binary, combustion::binary, electric::binary,
       source::binary>>}
  end

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
  @payload_header_bytes 54

  @kind_unchanged 0
  @kind_entries 1
  @kind_payload 2
  @kind_missing 3

  @doc "完整 RegionPayload 固定头的字节数。"
  def payload_header_bytes, do: @payload_header_bytes

  @doc "当前raw/DEFLATE载荷的保守线格式下界，非经验压缩率。"
  def payload_min_bytes do
    # RFC 1951 sections 3.2.5/3.2.7: a literal/length code consumes at least
    # one bit and emits at most 258 bytes. Ignoring distance/tree/framing bits
    # only weakens the bound. Stored/raw encoding is larger still.
    # https://www.rfc-editor.org/rfc/rfc1951
    bytes_per_encoded_byte = 258 * 8
    raw_min = MmoContracts.Voxel.Payload.min_body_bytes()
    @payload_header_bytes + div(raw_min + bytes_per_encoded_byte - 1, bytes_per_encoded_byte)
  end

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

  @doc "D3-2 `POST /voxel/prefabs` 应答：count:u32 + 每项 publisher_cid:u64、name_len:u16、UTF-8 名称、len:u32、VXPD 字节，全部小端，按发布序。"
  def encode_prefab_list(published) do
    [
      <<length(published)::32-little>>
      | Enum.map(published, fn {cid, name, bytes} ->
          [<<cid::64-little, byte_size(name)::16-little>>, name, <<byte_size(bytes)::32-little>>, bytes]
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
        <<magic::binary-size(4), version::32-little, level::8, x::32-little-signed,
          y::32-little-signed, z::32-little-signed, seq::64-little, content_version::64-little,
          hash::64-little, encoding::8, raw_bytes::32-little, body_bytes::32-little,
          _rest::binary>>
      )
      when (magic == "VXR4" and version == 4) or (magic == "VXR5" and version == 5) or
             (magic == "VXR6" and version == 6) or (magic == "VXR7" and version == 7) or
             (magic == "VXR8" and version == 8) or (magic == "VXR9" and version == 9) or
             (magic == "VXRA" and version == 10) or (magic == "VXRB" and version == 11) or
             (magic == "VXRC" and version == 12) do
    {:ok,
     %{
       version: version,
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
  def encode_payload(level, {x, y, z}, seq, content_version, raw_body, version \\ 4)
      when is_binary(raw_body) do
    body = :zlib.compress(raw_body)

    magic =
      case version do
        9 -> "VXR9"
        12 -> "VXRC"
        11 -> "VXRB"
        10 -> "VXRA"
        8 -> "VXR8"
        7 -> "VXR7"
        6 -> "VXR6"
        5 -> "VXR5"
        4 -> @payload_magic
      end

    <<magic::binary, version::32-little, level::8, x::32-little-signed, y::32-little-signed,
      z::32-little-signed, seq::64-little, content_version::64-little,
      body_hash(raw_body)::64-little, 1::8, byte_size(raw_body)::32-little,
      byte_size(body)::32-little, body::binary>>
  end

  @doc "解压 body（校验 hash）。"
  def decode_payload_body(bytes) do
    with {:ok, header, raw} <- unpack_payload_body(bytes),
         true <- body_hash(raw) == header.hash do
      {:ok, header, raw}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  @doc "解包已接纳的不可变载荷，供内部缓存重写使用；外部输入必须走 decode_payload_body 校验内容 hash。"
  def unpack_payload_body(bytes) do
    with {:ok, header} <- decode_payload_header(bytes),
         true <-
           header.encoding in [0, 1] and
             header.raw_bytes <=
               MmoContracts.Voxel.Payload.max_body_bytes() +
                 if(header.version == 6, do: MmoContracts.Voxel.Structure.max_bytes(), else: 0),
         <<_::binary-size(@payload_header_bytes), body::binary-size(header.body_bytes)>> <- bytes,
         {:ok, raw} <- decode_raw_body(body, header.encoding, header.raw_bytes),
         true <- byte_size(raw) == header.raw_bytes do
      {:ok, header, raw}
    else
      _ -> {:error, :invalid_payload}
    end
  rescue
    ErlangError -> {:error, :invalid_payload}
  end

  defp decode_raw_body(body, 0, _raw_bytes), do: {:ok, body}

  defp decode_raw_body(body, 1, raw_bytes) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)

      with {:ok, chunks} <- inflate_chunks(z, body, raw_bytes, []) do
        # finished 只表示输入队列耗尽；inflateEnd 确认流完整后才合并输出。
        :ok = :zlib.inflateEnd(z)
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}
      end
    after
      :zlib.close(z)
    end
  end

  defp inflate_chunks(z, input, remaining, acc) do
    case :zlib.safeInflate(z, input) do
      {status, chunk} when status in [:continue, :finished] ->
        remaining = remaining - IO.iodata_length(chunk)

        cond do
          # 超限块不进入累积列表，也不继续解压后续输出。
          remaining < 0 -> {:error, :invalid_payload}
          status == :continue -> inflate_chunks(z, [], remaining, [chunk | acc])
          remaining == 0 -> {:ok, [chunk | acc]}
          true -> {:error, :invalid_payload}
        end

      {:need_dictionary, _, _} ->
        {:error, :invalid_payload}
    end
  end

  @doc "raw body 的 MD5 前八字节按小端解释为内容 hash。"
  def body_hash(raw) do
    <<hash::64-little, _::binary>> = :crypto.hash(:md5, raw)
    hash
  end

  # ---- 日志条目

  @doc "事务信封：seq、带长度的条目数组、去重的粗格数组；全部小端。"
  def encode_transaction(%{seq: seq, entries: entries, coarse: coarse} = txn) do
    [
      <<seq::64-little, length(entries)::32-little>>,
      Enum.map(entries, fn e ->
        b = IO.iodata_to_binary(encode_entry(e))
        [<<byte_size(b)::32-little>>, b]
      end),
      <<length(coarse)::32-little>>,
      Enum.map(coarse, &encode_coarse/1),
      encode_liquid_falls(Map.get(txn, :liquid_falls))
    ]
  end

  @doc "小端事务信封解码为 seq、entries、coarse。"
  def decode_transaction(<<seq::64-little, count::32-little, rest::binary>>) do
    with {:ok, entries, <<n::32-little, rest::binary>>} <-
           decode_transaction_entries(rest, count, []),
         {:ok, coarse, rest} <- decode_coarse(rest, n, []),
         {:ok, metadata} <- decode_liquid_falls(rest) do
      {:ok, Map.merge(%{seq: seq, entries: entries, coarse: coarse}, metadata)}
    else
      _ -> {:error, :invalid_transaction}
    end
  end

  # 全局系统功能：实时展示整帧，不承载数量或物理状态。
  defp encode_liquid_falls(nil), do: []

  defp encode_liquid_falls(%{material: material, transfers: transfers}) do
    [
      <<2, material::little-16, length(transfers)::little-32>>,
      Enum.map(transfers, fn {{x, y, z}, units} ->
        <<x::little-signed-32, y::little-signed-32, z::little-signed-32, units::little-32>>
      end)
    ]
  end

  defp decode_liquid_falls(<<>>), do: {:ok, %{}}

  defp decode_liquid_falls(<<2, material::little-16, count::little-32, bytes::binary>>)
       when material in [21, 22] and byte_size(bytes) == count * 16 do
    transfers =
      for <<x::little-signed-32, y::little-signed-32, z::little-signed-32,
            units::little-32 <- bytes>>,
          do: {{x, y, z}, units}

    if Enum.all?(transfers, fn {_, units} -> units > 0 end),
      do: {:ok, %{liquid_falls: %{material: material, transfers: transfers}}},
      else: {:error, :invalid_transaction}
  end

  defp decode_liquid_falls(_), do: {:error, :invalid_transaction}

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

  def encode_entry(%{seq: seq, level: level, cell: {x, y, z}, structure: grid}) do
    [
      <<seq::64-little, 2, level::8, x::32-little-signed, y::32-little-signed,
        z::32-little-signed, div(byte_size(grid), 2)::32-little>>,
      grid
    ]
  end

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

  def decode_entry(
        <<seq::64-little, 2, level::8, x::32-little-signed, y::32-little-signed,
          z::32-little-signed, count::32-little, grid::binary>>
      )
      when level in 1..5 do
    if (count == 0 and grid == <<>>) or
         (byte_size(grid) == count * 2 and MmoContracts.Voxel.Structure.valid?(grid)) do
      {:ok, %{seq: seq, level: level, cell: {x, y, z}, structure: grid}}
    else
      {:error, :invalid_entry}
    end
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

  defp accept_m1(%Voxel.CollisionApplied{changed_chunks: chunks}),
    do: MmoContracts.Session.Wire.ordered!(chunks)

  defp accept_m1(%module{} = value)
       when module in [Voxel.CanonicalBootstrap, Voxel.CollisionWindow] do
    {x0, y0, z0} = value.l0_min
    {x1, y1, z1} = value.l0_max_exclusive
    true = x0 < x1 and y0 < y1 and z0 < z1
    true = length(value.regions) == (x1 - x0) * (y1 - y0) * (z1 - z0)
    expected = for x <- x0..(x1 - 1), y <- y0..(y1 - 1), z <- z0..(z1 - 1), do: {x, y, z}
    true = Enum.map(value.regions, &elem(&1, 0)) == expected

    true =
      Enum.zip(Tuple.to_list(value.travel_min_m), Tuple.to_list(value.travel_max_exclusive_m))
      |> Enum.all?(fn {a, b} -> a < b end)

    Enum.each(value.regions, fn {coord, bytes} ->
      {:ok, header, raw} = Voxel.Codec.decode_payload_body(bytes)

      true =
        header.level == 0 and header.region == coord and header.seq == value.transaction_seq and
          header.content_version == value.content_version

      {:ok, _} = Voxel.Payload.decode_body(raw, header.version)
    end)
  end

  defp accept_m1(%Voxel.PropertyBatch{protection: bytes, semblances: semblances, casts: casts, complete: complete}) do
    {:ok, delta} = decode_protection(bytes)
    true = complete == 0 or Enum.all?(delta, fn {_, region} -> region != nil end)
    {:ok, delta} = decode_semblances(semblances)
    true = complete == 0 or Enum.all?(delta, fn {_, s} -> s != nil end)
    {:ok, delta} = decode_casts(casts)
    true = complete == 0 or Enum.all?(delta, fn {_, c} -> c.live == 1 end)
  end

  defp accept_m1(_), do: :ok

  @doc """
  全局系统功能（协议 19）：受保护区域增量 `%{{seq, n} => 区域 | nil}` 的线字节，放在 PropertyBatch 末尾。
  每条 37 B、大端、按 id 升序且唯一：

      id_seq:u64, id_n:u32, holder:u8 (0 删除 / 1 保留 / 2 角色), cid:u64,
      min_x:i32, min_z:i32, max_x:i32, max_z:i32

  删除记录 cid 与矩形全为 0；保留区域 cid 为 0；矩形是闭区间宏格，y 不限。
  """
  def encode_protection(delta) do
    for {{seq, n}, region} <- Enum.sort(delta), into: <<>> do
      {holder, cid, {x0, z0}, {x1, z1}} =
        case region do
          nil -> {0, 0, {0, 0}, {0, 0}}
          %{holder: :reserved} -> {1, 0, region.min, region.max}
          %{holder: {:character, cid}} -> {2, cid, region.min, region.max}
        end

      <<seq::64, n::32, holder::8, cid::64, x0::signed-32, z0::signed-32, x1::signed-32,
        z1::signed-32>>
    end
  end

  @doc "`encode_protection/1` 的逆；区域只含 holder/min/max。"
  def decode_protection(bytes), do: decode_protection(bytes, nil, %{})

  defp decode_protection(<<>>, _, acc), do: {:ok, acc}

  defp decode_protection(
         <<seq::64, n::32, holder::8, cid::64, x0::signed-32, z0::signed-32, x1::signed-32,
           z1::signed-32, rest::binary>>,
         previous,
         acc
       )
       when previous == nil or {seq, n} > previous do
    region =
      case {holder, cid} do
        {0, 0} when {x0, z0, x1, z1} == {0, 0, 0, 0} -> nil
        {1, 0} when x0 <= x1 and z0 <= z1 -> %{holder: :reserved, min: {x0, z0}, max: {x1, z1}}
        {2, cid} when cid > 0 and x0 <= x1 and z0 <= z1 -> %{holder: {:character, cid}, min: {x0, z0}, max: {x1, z1}}
        _ -> :invalid
      end

    if region == :invalid,
      do: {:error, :invalid_protection},
      else: decode_protection(rest, {seq, n}, Map.put(acc, {seq, n}, region))
  end

  defp decode_protection(_, _, _), do: {:error, :invalid_protection}

  @doc """
  魔法增量 2（协议 25）：拟态增量 `%{{seq, n} => 拟态 | nil}` 的线字节，放在 PropertyBatch 末尾（受保护区域之后）。
  每条 134 B、大端、按 id 升序且唯一；坐标为 canonical 米（Y-up），客户端不逐 tick 接收位置而自行插值：

      id_seq:u64, id_n:u32, live:u8 (0 删除 / 1 存在), caster:u64, shape:u8 (0 球 / 1 立方),
      radius_m:f64, temperature_k:f64, glow_w:f64,
      origin_x/y/z:f64, velocity_x/y/z:f64, t0_us:u64, flight_s:f64, rest_x/y/z:f64

  位置 p(τ) = origin + velocity·τ − ½·9.81·τ²·ŷ，τ = min((服务端时钟 µs − t0_us)/1e6, flight_s)；τ ≥ flight_s 后停在 rest。
  静止拟态 velocity 为 0、flight_s 为 0、rest = origin。t0_us 是服务端墙钟（与 SessionStart.server_time_us 同源）。
  删除记录除 id 外全为 0。
  """
  def encode_semblances(delta) do
    for {{seq, n}, s} <- Enum.sort(delta), into: <<>> do
      case s do
        nil ->
          <<seq::64, n::32, 0::8, 0::size(121)-unit(8)>>

        s ->
          {ox, oy, oz} = s.origin
          {vx, vy, vz} = s.velocity
          {rx, ry, rz} = s.rest

          <<seq::64, n::32, 1::8, s.caster::64, s.shape::8, s.radius_m::float-64, s.temperature_k::float-64,
            s.glow_w::float-64, ox::float-64, oy::float-64, oz::float-64, vx::float-64, vy::float-64,
            vz::float-64, s.t0_us::64, s.flight_s::float-64, rx::float-64, ry::float-64, rz::float-64>>
      end
    end
  end

  @doc "`encode_semblances/1` 的逆；拟态只含线上字段。"
  def decode_semblances(bytes), do: decode_semblances(bytes, nil, %{})

  defp decode_semblances(<<>>, _, acc), do: {:ok, acc}

  defp decode_semblances(<<seq::64, n::32, 0::8, zero::binary-size(121), rest::binary>>, previous, acc)
       when previous == nil or {seq, n} > previous do
    if zero == <<0::size(121)-unit(8)>>,
      do: decode_semblances(rest, {seq, n}, Map.put(acc, {seq, n}, nil)),
      else: {:error, :invalid_semblance}
  end

  defp decode_semblances(
         <<seq::64, n::32, 1::8, caster::64, shape::8, radius::float-64, temperature::float-64, glow::float-64,
           ox::float-64, oy::float-64, oz::float-64, vx::float-64, vy::float-64, vz::float-64, t0::64,
           flight::float-64, rx::float-64, ry::float-64, rz::float-64, rest::binary>>,
         previous,
         acc
       )
       when (previous == nil or {seq, n} > previous) and shape in [0, 1] and radius > 0 and temperature > 0 and
              glow >= 0 and flight >= 0 do
    s = %{caster: caster, shape: shape, radius_m: radius, temperature_k: temperature, glow_w: glow,
      origin: {ox, oy, oz}, velocity: {vx, vy, vz}, t0_us: t0, flight_s: flight, rest: {rx, ry, rz}}

    decode_semblances(rest, {seq, n}, Map.put(acc, {seq, n}, s))
  end

  defp decode_semblances(_, _, _), do: {:error, :invalid_semblance}

  @doc """
  施放前摇（协议 27，Voxim Docs/Magic.md §13.6）：待施放增量 `%{caster => 记录}` 的线字节，放在 PropertyBatch 末尾
  （拟态之后）。大端、按 caster 升序且唯一，变长：

      caster:u64, live:u8 (1 前摇中 / 0 已结算), outcome:u8 (0 成功 / 1 走火 / 2 结算时拒绝；live=1 时为 0),
      t0_us:u64, origin_x/y/z:f64, n:u8, n × (adjust_s:f64, inject_s:f64), program_len:u16, program bytes

  t0_us 是服务端墙钟（与拟态 t0_us、SessionStart.server_time_us 同源），第 k 步构型调整段接在前一步注能段之后；
  origin 是施法者手边位置（canonical 米，Y-up）；program 为施放意图里的规范程序字节原样。
  已结算记录除 caster、live、outcome 外全为 0（n = 0、program_len = 0）。
  """
  def encode_casts(delta) do
    for {caster, c} <- Enum.sort(delta), into: <<>> do
      case c do
        %{live: 0, outcome: outcome} ->
          <<caster::64, 0::8, outcome::8, 0::64, 0.0::float-64, 0.0::float-64, 0.0::float-64, 0::8, 0::16>>

        %{live: 1, t0_us: t0, origin: {x, y, z}, steps: steps, program: program} ->
          <<caster::64, 1::8, 0::8, t0::64, x::float-64, y::float-64, z::float-64, length(steps)::8,
            (for {a, i} <- steps, into: <<>>, do: <<a::float-64, i::float-64>>)::binary,
            byte_size(program)::16, program::binary>>
      end
    end
  end

  @doc """
  `encode_casts/1` 的逆。已结算记录按同一布局解析，只取 caster、live、outcome（其余字段编码端写 0，解码端不用）；
  前摇中记录要求 outcome 0、至少 1 步、各段时长非负、程序非空。
  """
  def decode_casts(bytes), do: decode_casts(bytes, nil, %{})

  defp decode_casts(<<>>, _, acc), do: {:ok, acc}

  defp decode_casts(
         <<caster::64, live::8, outcome::8, t0::64, x::float-64, y::float-64, z::float-64, n::8,
           steps::binary-size(n * 16), size::16, program::binary-size(size), rest::binary>>,
         previous,
         acc
       )
       when previous == nil or caster > previous do
    steps = for <<a::float-64, i::float-64 <- steps>>, do: {a, i}

    cond do
      live == 0 and outcome in [0, 1, 2] ->
        decode_casts(rest, caster, Map.put(acc, caster, %{live: 0, outcome: outcome}))

      live == 1 and outcome == 0 and n > 0 and size > 0 and Enum.all?(steps, fn {a, i} -> a >= 0 and i >= 0 end) ->
        decode_casts(rest, caster, Map.put(acc, caster,
          %{live: 1, t0_us: t0, origin: {x, y, z}, steps: steps, program: program}))

      true ->
        {:error, :invalid_cast}
    end
  end

  defp decode_casts(_, _, _), do: {:error, :invalid_cast}
end
