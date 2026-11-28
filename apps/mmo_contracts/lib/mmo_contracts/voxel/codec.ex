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
         structures: :bytes,
         casts: :bytes,
         structure_states: :bytes
       ]},
    # 身体闭环 H2（Hello 31）：复活瞬移。本人在 apply_tick − 1 的移动状态换成 state（会话出生点），apply_tick 起从它推进。
    # 与 CollisionWindow、TimelineFence 同一可靠流：流送时紧接在覆盖出生点的新窗口之前发出（同一 apply_tick）。
    6 => {Voxel.Relocate, [identity: :identity, apply_tick: :u64, state: :state]}
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
                    :voxel_caster_state,
                    :voxel_beacon_directory
                  ]

  @doc "工具意图的合法性，线解码与进程内调用方（`NpcServer.WorldRequest`，经 `intent?/1`）共用同一组约束。"
  def tool_intent?(%{action: action, tool_id: tool, direction: {dx, dy, dz}} = request) do
    norm = dx * dx + dy * dy + dz * dz

    # g=6 战斗招式：无提示 owner {0,0}+incarnation 0，或单体提示 owner {人物 id,0}+incarnation 生命代次；不成对拒绝（Hello 43）。
    action in [0, 1, 2] and tool > 0 and Map.get(request, :granularity, 0) in [0, 1, 2, 3, 5, 6] and
      (Map.get(request, :granularity, 0) != 6 or
         (action == 1 and request.material == 0 and request.micro == {0, 0, 0} and
            ((match?({0, 0}, request.owner) and request.incarnation == 0) or
               (match?({id, 0} when id > 0, request.owner) and request.incarnation > 0)))) and
      (Map.get(request, :granularity, 0) != 5 or
         (action in [0, 1] and match?({id, 0} when id > 0, request.owner) and
            (action == 0 or request.incarnation > 0))) and
      norm > 0.99 and norm < 1.01
  end

  @doc "生产意图（0 余额、1 放置、2 盛取、3 倾倒、4 按目录配方合成 material 一次、5 吃一株可食材料 material（Hello 29）、6 徒手分选一份混合矿 material（tool = ore.sort，coord 忽略）、7 取消当前分选（Hello 44））的合法性，线解码与进程内调用方（`NpcServer.WorldRequest`，经 `intent?/1`）共用。"
  # Voxim 交互设计“2026-11-09 修订”第 3 步：合成 4 与吃 5 不携带工具（tool 0 合法，旧客户端的非零工具也照收；两者从不读工具），字节格式不变。
  def production_intent?(%{action: action, tool_id: tool} = request),
    do:
      action in [0, 1, 2, 3, 4, 5, 6, 7] and (tool > 0 or action in [4, 5]) and
        (action != 2 or
           match?(
             %{granularity: 0, micro: {_, _, _}, incarnation: _, owner: {_, _}, material: _},
             Map.get(request, :target)
           ))

  @doc "附件意图的合法性，线解码与进程内调用方（`NpcServer.WorldRequest`，经 `intent?/1`）共用同一组约束。"
  def attachment_intent?(%{action: action, kind: kind, axis: axis, size: size, tool_id: tool}),
    do: action in [0, 1] and kind in [0, 1] and axis in 0..2 and size in [1, 8] and tool > 0

  @doc "Prefab 放置的合法性，线解码与进程内调用方（`NpcServer.WorldRequest`，经 `intent?/1`）共用。"
  def prefab_place?(%{definition_id: id, orientation: orientation}),
    do: byte_size(id) == 32 and orientation in 0..23

  @doc "Prefab 拆除 0x7B 的取值约束：实例 id = {birth u64, occurrence u32}，与线布局同界；进程内调用方（`NpcServer.WorldRequest`，经 `intent?/1`）共用。"
  def prefab_remove?(%{instance_id: {birth, occurrence}}),
    do: birth in 0..0xFFFF_FFFF_FFFF_FFFF and occurrence in 0..0xFFFF_FFFF

  @doc "Prefab 替换 0x7C 的取值约束：同拆除的实例 id，另加 32 字节新定义 id。"
  def prefab_replace?(%{definition_id: id} = request),
    do: prefab_remove?(request) and byte_size(id) == 32

  @doc """
  角色世界意图 `{kind, request}`（`decode/1` 的输出形状）按 kind 分派上面的取值谓词。
  只做取值约束，类型守卫由进程内调用方（`NpcServer.WorldRequest`）先做；`decode/1` 与字节不受影响。
  发布 0x71 没有线层取值约束（名称、格式与目录由 `World.publish_prefab` 裁决），不在此列。
  施法 0x82 用下面的 `spell_intent?/1`（NPC 施放与取消；施法不经 `SceneServer.Movement.Intent`，走 `Player.cast_spell/5`）。
  """
  def intent?({:voxel_tool_intent, request}), do: tool_intent?(request)
  def intent?({:voxel_production_intent, request}), do: production_intent?(request)
  def intent?({:voxel_attachment_intent, request}), do: attachment_intent?(request)
  def intent?({:voxel_prefab_place_v1, request}), do: prefab_place?(request)
  def intent?({:voxel_prefab_remove_v1, request}), do: prefab_remove?(request)
  def intent?({:voxel_prefab_replace_v1, request}), do: prefab_replace?(request)
  def intent?({:voxel_spell_intent, request}), do: spell_intent?(request)

  @doc """
  魔法施法意图 0x82 v2（Hello 46，设计 §11.4.6，决策稿 slice3-protocol §3.1）的取值约束，线解码与进程内调用方
  （`NpcServer.WorldRequest`，经 `intent?/1`）共用。帧 127 + n B，大端，与 0x7D 工具意图同一目标表示：

  | 偏移 | 字段 | 类型 |
  |---|---|---|
  | 0 | opcode | u8 = 0x82 |
  | 1 | `request_id` | u64 |
  | 9 | `client_intent_seq` | u32 |
  | 13 | `logical_scene_id` | u64 |
  | 21 | `action` | u8：0 报价、1 施放、2 取消、3 改向 |
  | 22 | `catalog_digest` | 32 B（目录 v5 文件字节的 sha256） |
  | 54 | `direction` | f64 × 3，单位向量（范数 ∈ (0.99, 1.01)） |
  | 78 | `micro` | i64 × 3，准星目标微格 |
  | 102 | `incarnation` | u64 |
  | 110 | `owner` | birth u64、occurrence u32 |
  | 122 | `material` | u16 |
  | 124 | `granularity` | u8（0..2） |
  | 125 | `program_len` | u16 |
  | 127 | `program` | n B，IR v2 字节 |

  v1 偏移 125–136 的 12 B 拟态 id 已删除（驱散改为区域，〈调〉的目标走程序内的 `sid96`）。
  这里只判帧形与上表的取值；n 的上下限与程序内容归 World 的 `VoxelRegion.Magic.Program`（唯一信任边界）。
  """
  def spell_intent?(%{action: action, direction: {dx, dy, dz}, granularity: granularity}) do
    norm = dx * dx + dy * dy + dz * dz
    action in [0, 1, 2, 3] and granularity in [0, 1, 2] and norm > 0.99 and norm < 1.01
  end

  # 计价层数值检查（设计 §3.3）的线上位序：0x83 `rejects` 位掩码的第 0–4 位与 0x68 "rejects:<名,…>" 的排列
  # 同用这一张表，客户端用同一张“检查名 → 提示文案”表处理两种来源（决策稿 §3.5）。
  @spell_reject_checks [:capacity, :domain, :first_tick, :ambient_floor, :thermal_step]

  @doc """
  计价层数值检查名的线上位序：T5 `capacity`、T6 `domain`、T13 `first_tick`、T14 `ambient_floor`、
  T15 `thermal_step`，下标即 0x83 `rejects` 的位号。
  """
  def spell_reject_checks, do: @spell_reject_checks

  @doc """
  检查名列表 → 0x83 `rejects` 位掩码（整数；编码端以 f64 承载）。空表为 0；表外的名字显式失败（`ArgumentError`）。
  """
  def spell_rejects_mask(checks) do
    checks
    |> Enum.map(&Bitwise.bsl(1, spell_reject_bit(&1)))
    |> Enum.reduce(0, &Bitwise.bor/2)
  end

  @doc """
  检查名列表 → 0x68 拒绝原因串 `"rejects:<检查名,…>"`（按 `spell_reject_checks/0` 的位序、去重，以逗号连接；
  决策稿 §3.4–3.5）。不带冒号前缀，与 `inspect` 形式的其他拒绝（如 `":no_target"`）有意区分。
  空表与表外名字显式失败（`ArgumentError`）：没有违规就不该有这条拒绝。
  """
  def spell_rejects_reason([_ | _] = checks) do
    Enum.each(checks, &spell_reject_bit/1)

    "rejects:" <>
      Enum.map_join(Enum.filter(@spell_reject_checks, &(&1 in checks)), ",", &Atom.to_string/1)
  end

  def spell_rejects_reason(checks),
    do: raise(ArgumentError, "rejects 原因串至少要有一个检查名，收到 #{inspect(checks)}")

  defp spell_reject_bit(check) do
    case Enum.find_index(@spell_reject_checks, &(&1 == check)) do
      nil -> raise ArgumentError, "未知的计价数值检查名 #{inspect(check)}"
      bit -> bit
    end
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
          birth::64, occurrence::32, material::16, granularity::8, n::16,
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
      program: program
    }

    if spell_intent?(request),
      do: {:ok, {:voxel_spell_intent, request}},
      else: {:error, :invalid_message}
  end

  def decode(<<0x82, _::binary>>), do: {:error, :invalid_message}

  # 传送信标出发（Hello 41，Voxim Docs/Gameplay/Beacon.md），大端：request_id u64、client_intent_seq u32、scene u64、
  # 出发信标 id（u8 长度 + UTF-8）、目的信标 id（同）。
  def decode(
        <<0x87, rid::64, seq::32, scene::64, nf, from::binary-size(nf), nt, to::binary-size(nt)>>
      )
      when nf > 0 and nt > 0 do
    {:ok,
     {:voxel_beacon_travel,
      %{request_id: rid, client_intent_seq: seq, logical_scene_id: scene, from: from, to: to}}}
  end

  def decode(<<0x87, _::binary>>), do: {:error, :invalid_message}

  def decode(
        <<0x7F, rid::64, seq::32, scene::64, action::8, x::signed-32, y::signed-32, z::signed-32,
          tool::16, material::16, identity::binary>>
      ) do
    target =
      case {action, identity} do
        {2,
         <<mx::signed-64, my::signed-64, mz::signed-64, incarnation::64, birth::64,
           occurrence::32, mat::16, granularity::8>>} ->
          %{
            micro: {mx, my, mz},
            incarnation: incarnation,
            owner: {birth, occurrence},
            material: mat,
            granularity: granularity
          }

        {a, <<>>} when a != 2 ->
          nil

        _ ->
          :invalid
      end

    request = %{
      request_id: rid,
      client_intent_seq: seq,
      logical_scene_id: scene,
      action: action,
      coord: {x, y, z},
      tool_id: tool,
      material: material
    }

    request = if target == nil, do: request, else: Map.put(request, :target, target)

    if target != :invalid and production_intent?(request),
      do: {:ok, {:voxel_production_intent, request}},
      else: {:error, :invalid_message}
  end

  def decode(<<0x7F, _::binary>>), do: {:error, :invalid_message}

  def decode(
        <<0x7D, rid::64, seq::32, scene::64, action::8, dx::float-64, dy::float-64, dz::float-64,
          x::signed-64, y::signed-64, z::signed-64, incarnation::64, birth::64, occurrence::32,
          material::16, tool::16, granularity::8, id_size::8, beacon_id::binary-size(id_size)>>
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
      granularity: granularity,
      beacon_id: beacon_id
    }

    if String.valid?(beacon_id) and tool_intent?(request),
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
  # 传送信标目录（Hello 41）0x87，大端：request_id u64（登录下发为 0）、条数 u16，每条：id（u8 长度 + UTF-8）、
  # 站名（u16 长度 + UTF-8）、核心中心 x/y/z f64（canonical 米，Y-up）、本角色已调谐 u8（0/1）。
  def encode({:voxel_beacon_directory, t}) do
    entries =
      for e <- t.entries do
        {x, y, z} = e.core

        <<byte_size(e.id)::8, e.id::binary, byte_size(e.name)::16, e.name::binary, x::float-64,
          y::float-64, z::float-64, if(e.attuned, do: 1, else: 0)::8>>
      end

    {:ok, IO.iodata_to_binary([<<0x87, t.request_id::64, length(t.entries)::16>> | entries])}
  end

  def encode({:voxel_material_balance, t}) do
    {:ok, <<0x81, t.request_id::64, t.seq::64, t.material::16, t.balance::64, t.cost::32>>}
  end

  # 施法者状态 0x83 v2（Hello 46，设计 §11.4.6，决策稿 slice3-protocol §3.2），161 B，大端：
  #
  #   0 opcode u8 = 0x83 | 1 request_id u64（登录与身体推送为 0）| 9 seq u64（World 事务号）
  #   17 energy_j | 25 capacity_j | 33 resolution_eff（Ω_eff，原 coherence）| 41 quote_j
  #   49 quote_s（S·P，原 S）| 57 spent_j（本次实际扣除，只发施法者本人）| 65 quote_windup_s
  #   报价扩展（v2 追加 11 × f64）：73 x0 | 81 x_star | 89 e_min_j | 97 p_maint_w | 105 life_s | 113 detect_w
  #   121 fail_step | 129 rejects（位掩码，见 `spell_rejects_mask/1`）| 137 entries_charge | 145 entries_spoof
  #   153 first_tick_min_j
  #
  # 17 起全部是 f64；fail_step、rejects、entries_* 是整数值，以 f64 承载。前 73 B 位置与 v1 相同。
  # 扩展段只在报价回复（action 0）中非零——这是 World 的填写规则，编码端只承载，不替调用方补 0：
  # 缺字段即显式失败（KeyError）。`rejects` 传检查名列表，按 `spell_reject_checks/0` 的位序编码。
  def encode({:voxel_caster_state, t}) do
    {:ok,
     <<0x83, t.request_id::64, t.seq::64, t.energy_j::float-64, t.capacity_j::float-64,
       t.resolution_eff::float-64, t.quote_j::float-64, t.quote_s::float-64, t.spent_j::float-64,
       t.quote_windup_s::float-64, t.x0::float-64, t.x_star::float-64, t.e_min_j::float-64,
       t.p_maint_w::float-64, t.life_s::float-64, t.detect_w::float-64, t.fail_step::float-64,
       spell_rejects_mask(t.rejects)::float-64, t.entries_charge::float-64,
       t.entries_spoof::float-64, t.first_tick_min_j::float-64>>}
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
        do:
          {<<Map.get(t, :stored_j, 0.0)::float-64, Map.get(t, :source_emf_v, 0.0)::float-64,
             Map.get(t, :source_current_a, 0.0)::float-64>>, 8},
        else: {<<>>, 0}

    {:ok,
     <<0x7E, t.request_id::64, t.seq::64, x::signed-64, y::signed-64, z::signed-64,
       t.granularity::8, t.incarnation::64, birth::64, occurrence::32, t.material::16,
       t.hp::float-64, t.max_hp::float-64, t.defense::float-64, t.digest::binary-size(32),
       t.flags + present + closed + supply::8, temperature::binary, combustion::binary,
       electric::binary, source::binary>>}
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
  def payload_min_bytes(raw_min \\ MmoContracts.Voxel.Payload.min_body_bytes()) do
    # RFC 1951 sections 3.2.5/3.2.7: a match emits at most 258 bytes and
    # needs at least one length bit AND one distance bit (even a single
    # distance code uses one bit). Literals and stored/raw blocks are larger.
    # Ignoring tree/framing/extra bits only weakens this format-derived bound.
    # https://www.rfc-editor.org/rfc/rfc1951
    bytes_per_encoded_byte = 258 * 4
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
          [
            <<cid::64-little, byte_size(name)::16-little>>,
            name,
            <<byte_size(bytes)::32-little>>,
            bytes
          ]
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
             (magic == "VXRC" and version == 12) or (magic == "VXRD" and version == 13) do
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

  @doc "接纳原始body的binary或iodata，在唯一边界物化后生成头与原zlib正文。"
  def encode_payload(level, {x, y, z}, seq, content_version, raw_body, version \\ 4)
      when is_binary(raw_body) or is_list(raw_body) do
    raw_bytes = IO.iodata_length(raw_body)

    # 写端与解码同界：超出 Payload.max_body_bytes/1 的 body 写出后读不回，显式拒绝。
    if raw_bytes > MmoContracts.Voxel.Payload.max_body_bytes(version),
      do:
        raise(
          ArgumentError,
          "VXR#{version} raw body #{raw_bytes} B exceeds format capacity"
        )

    raw_body = IO.iodata_to_binary(raw_body)
    body = :zlib.compress(raw_body)

    # 与 compressed_prefix_bytes/1 同一 zlib 流（OTP :zlib.compress/1 = deflateInit(:default) 后一次 :finish）。

    magic =
      case version do
        9 -> "VXR9"
        13 -> "VXRD"
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
      body_hash(raw_body)::64-little, 1::8, raw_bytes::32-little, byte_size(body)::32-little,
      body::binary>>
  end

  @doc """
  encode_payload/6 的 body 若以这段 iodata 开头，其压缩流至少有多少字节：同参数 zlib 流在 Z_NO_FLUSH 下已输出的字节。

  deflate 的输出只追加不回改，且与输入分段方式无关（zlib 手册 deflate()：Z_NO_FLUSH 由库自行决定何时输出；
  输出只取决于数据、参数与 flush 序列），所以返回值是完整 body 压缩字节数的下界。
  """
  def compressed_prefix_bytes(prefix) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, :default)
      IO.iodata_length(:zlib.deflate(z, prefix, :none))
    after
      :zlib.close(z)
    end
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
             header.raw_bytes <= MmoContracts.Voxel.Payload.max_body_bytes(header.version),
         <<_::binary-size(@payload_header_bytes), body::binary-size((^header).body_bytes)>> <-
           bytes,
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
      encode_liquid_falls(Map.get(txn, :liquid_falls)),
      encode_operation(Map.get(txn, :operation))
    ]
  end

  @doc "小端事务信封解码为 seq、entries、coarse。"
  def decode_transaction(<<seq::64-little, count::32-little, rest::binary>>) do
    with {:ok, entries, <<n::32-little, rest::binary>>} <-
           decode_transaction_entries(rest, count, []),
         {:ok, coarse, rest} <- decode_coarse(rest, n, []),
         {:ok, metadata} <- decode_transaction_metadata(rest, %{}) do
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

  # Global system: ephemeral authoritative player feedback, never world truth.
  defp encode_operation(nil), do: []

  defp encode_operation(%{
         character: character,
         client_seq: client_seq,
         kind: kind,
         material: material,
         micro: {x, y, z}
       }) do
    <<3, character::little-64, client_seq::little-32, kind, material::little-16,
      x::little-signed-64, y::little-signed-64, z::little-signed-64>>
  end

  defp decode_transaction_metadata(<<>>, metadata), do: {:ok, metadata}

  defp decode_transaction_metadata(
         <<2, material::little-16, count::little-32, bytes::binary-size(count * 16),
           rest::binary>>,
         metadata
       )
       when material in [21, 22] and not is_map_key(metadata, :liquid_falls) do
    transfers =
      for <<x::little-signed-32, y::little-signed-32, z::little-signed-32,
            units::little-32 <- bytes>>,
          do: {{x, y, z}, units}

    if Enum.all?(transfers, fn {_, units} -> units > 0 end),
      do:
        decode_transaction_metadata(
          rest,
          Map.put(metadata, :liquid_falls, %{material: material, transfers: transfers})
        ),
      else: {:error, :invalid_transaction}
  end

  defp decode_transaction_metadata(
         <<3, character::little-64, client_seq::little-32, kind, material::little-16,
           x::little-signed-64, y::little-signed-64, z::little-signed-64, rest::binary>>,
         metadata
       )
       when kind in 0..2 and not is_map_key(metadata, :operation) do
    decode_transaction_metadata(
      rest,
      Map.put(metadata, :operation, %{
        character: character,
        client_seq: client_seq,
        kind: kind,
        material: material,
        micro: {x, y, z}
      })
    )
  end

  defp decode_transaction_metadata(_, _), do: {:error, :invalid_transaction}

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
        <<id::16-little, texels::binary-size(^texel_bytes), rest::binary>> = rest
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

  defp accept_m1(%Voxel.PropertyBatch{
         protection: bytes,
         structures: structures,
         casts: casts,
         structure_states: states,
         complete: complete
       }) do
    {:ok, delta} = decode_protection(bytes)
    true = complete == 0 or Enum.all?(delta, fn {_, region} -> region != nil end)

    # 完整快照只列存在中的结构（live 1）；删除（0）与终止事件（2–6）只在增量批里出现。
    {:ok, records} = decode_structures(structures)
    true = complete == 0 or Enum.all?(records, fn {_, s} -> s != nil and s.live == 1 end)

    {:ok, delta} = decode_casts(casts)
    true = complete == 0 or Enum.all?(delta, fn {_, c} -> c.live == 1 end)

    # 状态增量只在增量批里出现；同一批已有结构记录（含删除与终止快照）的 id 不再发增量——
    # 完整记录本身带同样的状态字段，重复出现时两者的先后没有定义。
    {:ok, states} = decode_structure_states(states)

    true =
      states == %{} or
        (complete == 0 and not Enum.any?(Map.keys(states), &Map.has_key?(records, &1)))
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
        {0, 0} when {x0, z0, x1, z1} == {0, 0, 0, 0} ->
          nil

        {1, 0} when x0 <= x1 and z0 <= z1 ->
          %{holder: :reserved, min: {x0, z0}, max: {x1, z1}}

        {2, cid} when cid > 0 and x0 <= x1 and z0 <= z1 ->
          %{holder: {:character, cid}, min: {x0, z0}, max: {x1, z1}}

        _ ->
          :invalid
      end

    if region == :invalid,
      do: {:error, :invalid_protection},
      else: decode_protection(rest, {seq, n}, Map.put(acc, {seq, n}, region))
  end

  defp decode_protection(_, _, _), do: {:error, :invalid_protection}

  # ── 结构记录 v2 与状态增量（Hello 46，魔法 v2 切片 4a；决策稿 `2026-11-26-p1-closure-slices4-8.md` §3）──
  #
  # 位表与事件编号只在这里定义（SSOT）；World 用名字（原子）构造记录，编码端换算成位，解码端换回名字。

  # 记录 `flags` 字节：第 0 位 ends_on_contact（程序有〈遇〉→〈散〉规则），第 1 位 massless（无质量即不受重力，
  # 用户 Q4-2）；其余位必须为 0。
  @structure_flags [:ends_on_contact, :massless]
  # `coupling_mask` u16：第 0–3 位依次为〈热〉〈辉〉〈容〉〈乱〉；其余位保留为 0。
  @structure_couplings [:thermal, :glow, :capacity, :disrupt]
  # `status` u8：第 0–5 位；第 6–7 位保留为 0。
  @structure_status [:overline, :folded, :feeding, :vent_damaged, :flying, :asleep]
  # 终止事件（live 2–6，用户 Q4-W3）：接触触发的〈散〉为 2；非接触读数（〈时〉〈满〉）触发的〈散〉为 6；
  # 3–5 对应 `VoxelRegion.Magic.Structure` 的终止类型。live 0 只表示无事件删除，live 1 表示存在。
  @structure_ends [contact: 2, exhausted: 3, collapsed: 4, dispelled: 5, released: 6]

  @doc "结构记录 `coupling_mask` 的位序：第 i 位 = 第 i 个名字（〈热〉〈辉〉〈容〉〈乱〉）。"
  def structure_couplings, do: @structure_couplings

  @doc "结构 `status` 字节的位序：第 i 位 = 第 i 个名字（越线、折叠、供能中、泄放口已损、飞行、热节点休眠）。"
  def structure_status_bits, do: @structure_status

  @doc """
  终止事件 → 记录 `live`（2–6）：`:contact` 接触触发的〈散〉（含〈遇〉→〈散〉）、`:exhausted` 断供衰竭、
  `:collapsed` 过载崩解、`:dispelled` 驱散、`:released` 非接触读数触发的〈散〉。表外名字显式失败。
  """
  def structure_end_live(event), do: Keyword.fetch!(@structure_ends, event)

  @doc """
  结构增量 `%{{seq, n} => 记录 | nil}` 的线字节（PropertyBatch `structures` 字段）。每条 160 B、大端、按 id 升序且唯一；
  坐标为 canonical 米（Y-up）：

      偏移  0 id_seq:u64 | 8 id_n:u32 | 12 live:u8 | 13 caster:u64 | 21 shape:u8 (0 球 / 1 块 / 2 板)
          22 flags:u8 (位 0 ends_on_contact / 位 1 massless) | 23 size1_m:f64 | 31 temperature_k:f64 (T_port，无〈热〉为 0)
          39 glow_w:f64 (本拍实际光功率) | 47 origin:f64×3 | 71 velocity:f64×3 | 95 t0_us:u64 | 103 flight_s:f64
          111 rest:f64×3 | 135 size2_mm:u16 | 137 size3_mm:u16 | 139 proto_id:u16 | 141 coupling_mask:u16
          143 load:u8 | 144 coherence:u8 | 145 status:u8 | 146 failed_segments:u8 | 147 anchor_type:u8 (0 手边 / 1 格面)
          148 anchor_ref:12 B

  记录（`live` 1–6）的键：`live caster shape ends_on_contact massless size1_m temperature_k glow_w origin velocity t0_us
  flight_s rest size2_mm size3_mm proto_id coupling load coherence status failed_segments anchor_type anchor_ref`。
  `coupling`、`status` 是名字列表（`structure_couplings/0`、`structure_status_bits/0`），`load`、`coherence` 是已量化的
  u8（round(x·255)、round(clamp(C, 0, 1)·255)），`anchor_ref` 是 12 B 二进制（P1 全 0）。

  - `nil` 是无事件删除：id + `live = 0` + 147 B 全 0。
  - `live` 1 存在；2–6 是终止事件（`structure_end_live/1`），一律带终态完整快照，客户端无需先有存在记录。
    live 2 要求 `ends_on_contact`。完整快照批只能含 live 1（`decode_m1/1` 拒绝）。
  - 位置 p(τ) = origin + velocity·τ − ½·g·τ²·ŷ，`massless` 时 g = 0；τ = (服务端时钟 µs − t0_us)/1e6，t0_us 是服务器
    时间线 `MmoContracts.ServerTime`。`status` 含 `flying` 时 `flight_s`/`rest` 只是施放时的预测（投掷结构没有射程终点），
    不按它截断，飞行结束由下一条记录给出；不含 `flying` 时 τ 截到 `flight_s`，之后停在 rest。
  - 球的 size2_mm、size3_mm 为 0；块与板二者为正。

  不满足上述约束的记录编码时显式失败（`ArgumentError`），不产生客户端会拒收的字节。
  """
  def encode_structures(delta) do
    for {{seq, n} = id, record} <- Enum.sort(delta), into: <<>> do
      case record do
        nil ->
          <<seq::64, n::32, 0::8, 0::size(147)-unit(8)>>

        record ->
          f = structure_wire_fields(record)

          structure_fields_valid?(f) ||
            raise ArgumentError, "结构记录 #{inspect(id)} 不满足 Hello 46 约束：#{inspect(record)}"

          {ox, oy, oz} = f.origin
          {vx, vy, vz} = f.velocity
          {rx, ry, rz} = f.rest

          <<seq::64, n::32, f.live::8, f.caster::64, f.shape::8, f.flags::8, f.size1_m::float-64,
            f.temperature_k::float-64, f.glow_w::float-64, ox::float-64, oy::float-64,
            oz::float-64, vx::float-64, vy::float-64, vz::float-64, f.t0_us::64,
            f.flight_s::float-64, rx::float-64, ry::float-64, rz::float-64, f.size2_mm::16,
            f.size3_mm::16, f.proto_id::16, f.coupling_mask::16, f.load::8, f.coherence::8,
            f.status::8, f.failed_segments::8, f.anchor_type::8, f.anchor_ref::binary-size(12)>>
      end
    end
  end

  @doc "`encode_structures/1` 的逆，返回 `{:ok, %{{seq, n} => 记录 | nil}}` 或 `{:error, :invalid_structure}`。"
  def decode_structures(bytes), do: decode_structures(bytes, nil, %{})

  defp decode_structures(<<>>, _, acc), do: {:ok, acc}

  defp decode_structures(
         <<seq::64, n::32, 0::8, zero::binary-size(147), rest::binary>>,
         previous,
         acc
       )
       when previous == nil or {seq, n} > previous do
    if zero == <<0::size(147)-unit(8)>>,
      do: decode_structures(rest, {seq, n}, Map.put(acc, {seq, n}, nil)),
      else: {:error, :invalid_structure}
  end

  defp decode_structures(
         <<seq::64, n::32, live::8, caster::64, shape::8, flags::8, size1::float-64,
           temperature::float-64, glow::float-64, ox::float-64, oy::float-64, oz::float-64,
           vx::float-64, vy::float-64, vz::float-64, t0::64, flight::float-64, rx::float-64,
           ry::float-64, rz::float-64, size2::16, size3::16, proto::16, coupling::16, load::8,
           coherence::8, status::8, failed::8, anchor_type::8, anchor_ref::binary-size(12),
           rest::binary>>,
         previous,
         acc
       )
       when previous == nil or {seq, n} > previous do
    f = %{
      live: live,
      caster: caster,
      shape: shape,
      flags: flags,
      size1_m: size1,
      temperature_k: temperature,
      glow_w: glow,
      origin: {ox, oy, oz},
      velocity: {vx, vy, vz},
      t0_us: t0,
      flight_s: flight,
      rest: {rx, ry, rz},
      size2_mm: size2,
      size3_mm: size3,
      proto_id: proto,
      coupling_mask: coupling,
      load: load,
      coherence: coherence,
      status: status,
      failed_segments: failed,
      anchor_type: anchor_type,
      anchor_ref: anchor_ref
    }

    if structure_fields_valid?(f),
      do: decode_structures(rest, {seq, n}, Map.put(acc, {seq, n}, structure_record(f))),
      else: {:error, :invalid_structure}
  end

  defp decode_structures(_, _, _), do: {:error, :invalid_structure}

  # 记录（名字与布尔）→ 线上字段（位掩码）；缺键即显式失败（KeyError）。
  defp structure_wire_fields(record) do
    flags =
      for {name, true} <- [ends_on_contact: record.ends_on_contact, massless: record.massless],
          do: name

    record
    |> Map.take(
      ~w(live caster shape size1_m temperature_k glow_w origin velocity t0_us flight_s rest
         size2_mm size3_mm proto_id load coherence failed_segments anchor_type anchor_ref)a
    )
    |> Map.merge(%{
      flags: names_mask(@structure_flags, flags),
      coupling_mask: names_mask(@structure_couplings, record.coupling),
      status: names_mask(@structure_status, record.status)
    })
  end

  # 线上字段 → 记录：位掩码换回名字（按位序）。
  defp structure_record(f) do
    f
    |> Map.drop([:flags, :coupling_mask])
    |> Map.merge(%{
      ends_on_contact: Bitwise.band(f.flags, 1) == 1,
      massless: Bitwise.band(f.flags, 2) == 2,
      coupling: mask_names(@structure_couplings, f.coupling_mask),
      status: mask_names(@structure_status, f.status)
    })
  end

  # 编码与解码共用的唯一约束（Hello 46）：live 1–6（live 2 须 ends_on_contact）；shape 0–2 且球的尺寸 2、3 为 0、
  # 块与板为正；flags、coupling_mask、status 的保留位为 0；size1 > 0；温度、发光、飞行时长非负；anchor_type 0–1；
  # 整数字段在各自宽度内（编码端防截断）。
  defp structure_fields_valid?(f) do
    f.live in 1..6 and (f.live != 2 or Bitwise.band(f.flags, 1) == 1) and
      f.flags in 0..3 and f.coupling_mask in 0..15 and f.status in 0..63 and
      f.shape in 0..2 and
      if(f.shape == 0,
        do: f.size2_mm == 0 and f.size3_mm == 0,
        else: f.size2_mm in 1..0xFFFF and f.size3_mm in 1..0xFFFF
      ) and
      f.size1_m > 0 and f.temperature_k >= 0 and f.glow_w >= 0 and f.flight_s >= 0 and
      f.proto_id in 0..0xFFFF and f.load in 0..255 and f.coherence in 0..255 and
      f.failed_segments in 0..255 and f.anchor_type in 0..1 and
      f.caster in 0..0xFFFF_FFFF_FFFF_FFFF and f.t0_us in 0..0xFFFF_FFFF_FFFF_FFFF and
      byte_size(f.anchor_ref) == 12
  end

  @doc """
  结构状态增量 `%{{seq, n} => 状态}` 的线字节（PropertyBatch `structure_states` 字段）。每条 20 B、大端、按 id 升序且唯一：

      偏移 0 id_seq:u64 | 8 id_n:u32 | 12 load:u8 | 13 coherence:u8 | 14 status:u8 | 15 failed_segments:u8
          16 temperature_dk:u16 (0.1 K，饱和到 65535) | 18 glow_w:u16 (W，饱和到 65535)

  状态的键：`load coherence status failed_segments temperature_dk glow_w`，含义与结构记录同名字段相同；由完整记录
  投影得到（`structure_state/1`）。完整快照批不带增量；同一批已有结构记录的 id 不再出现在增量里（`decode_m1/1` 拒绝）。
  发送条件（固定分箱，决策稿 §3.3）属于 World，编码端不判。超出字段宽度的值编码时显式失败（`ArgumentError`）。
  """
  def encode_structure_states(delta) do
    for {{seq, n} = id, state} <- Enum.sort(delta), into: <<>> do
      %{
        load: load,
        coherence: coherence,
        status: status,
        failed_segments: failed,
        temperature_dk: temperature,
        glow_w: glow
      } = state

      status = names_mask(@structure_status, status)

      (load in 0..255 and coherence in 0..255 and failed in 0..255 and temperature in 0..0xFFFF and
         glow in 0..0xFFFF) ||
        raise ArgumentError, "结构状态增量 #{inspect(id)} 超出字段宽度：#{inspect(state)}"

      <<seq::64, n::32, load::8, coherence::8, status::8, failed::8, temperature::16, glow::16>>
    end
  end

  @doc "`encode_structure_states/1` 的逆，返回 `{:ok, %{{seq, n} => 状态}}` 或 `{:error, :invalid_structure_state}`。"
  def decode_structure_states(bytes), do: decode_structure_states(bytes, nil, %{})

  defp decode_structure_states(<<>>, _, acc), do: {:ok, acc}

  defp decode_structure_states(
         <<seq::64, n::32, load::8, coherence::8, status::8, failed::8, temperature::16, glow::16,
           rest::binary>>,
         previous,
         acc
       )
       when (previous == nil or {seq, n} > previous) and status in 0..63 do
    state = %{
      load: load,
      coherence: coherence,
      status: mask_names(@structure_status, status),
      failed_segments: failed,
      temperature_dk: temperature,
      glow_w: glow
    }

    decode_structure_states(rest, {seq, n}, Map.put(acc, {seq, n}, state))
  end

  defp decode_structure_states(_, _, _), do: {:error, :invalid_structure_state}

  @doc """
  完整结构记录 → 状态增量：装载、相干、状态、失效段原样；温度换成 0.1 K、发光换成 W，四舍五入（半数远离零）后
  饱和到 65535。状态增量的量化只在这里定义。
  """
  def structure_state(record) do
    %{
      load: record.load,
      coherence: record.coherence,
      status: record.status,
      failed_segments: record.failed_segments,
      temperature_dk: min(0xFFFF, round(record.temperature_k * 10)),
      glow_w: min(0xFFFF, round(record.glow_w))
    }
  end

  # 名字列表 ↔ 位掩码（位号 = 名字在表中的下标）。表外名字显式失败（`ArgumentError`）。
  defp names_mask(table, names) do
    Enum.reduce(names, 0, fn name, mask ->
      case Enum.find_index(table, &(&1 == name)) do
        nil -> raise ArgumentError, "未知的位名 #{inspect(name)}（位表 #{inspect(table)}）"
        bit -> Bitwise.bor(mask, Bitwise.bsl(1, bit))
      end
    end)
  end

  defp mask_names(table, mask),
    do:
      for(
        {name, bit} <- Enum.with_index(table),
        Bitwise.band(mask, Bitwise.bsl(1, bit)) != 0,
        do: name
      )

  @doc """
  施放记录 v2（Hello 46，设计 §11.4.6，决策稿 slice3-protocol §3.3）：待施放增量 `%{caster => 记录}` 的线字节，
  放在 PropertyBatch 末尾（结构记录之后、结构状态增量之前）。大端、按 caster 升序且唯一，变长（定长部分 46 B，每步 17 B）：

      caster:u64, live:u8 (1 前摇中 / 0 已结算),
      outcome:u8 (0 建成 / 1 建构在第 k 步中断 / 2 结算时拒绝、不扣能；live = 1 时为 0),
      fail_step:u8 (outcome = 1 时为 k，1 起；其余为 0),
      t0_us:u64, origin_x/y/z:f64,
      n:u8, n × (part_index:u8, adjust_s:f64, inject_s:f64),
      program_len:u16, program bytes (IR v2)

  记录形状：

  - 前摇中 `%{live: 1, t0_us:, origin: {x, y, z}, steps: [%{part_index:, adjust_s:, inject_s:}], program:}`。
    `steps` 按服务端构造顺序（设计 §3.5）排列；`part_index` 是本步部件在规范字节中的 0 起序号，与签名、报价
    `steps[].part_index` 同一编号，n 步的 `part_index` 必须是 0..n−1 的一个排列。编码端只取这三个键，可以直接
    传 `VoxelRegion.Magic.Cost` 报价的 `steps`。
  - 已结算 `%{live: 0, outcome:, fail_step:}`：其余字段全为 0（n = 0、program_len = 0）。

  实际扣除量不进本记录（记录随批次广播，扣除量会泄露余额）；它只经 0x83 `spent_j` 发给施法者本人（v2.11 W3）。
  t0_us 是服务器时间线 `MmoContracts.ServerTime`（与结构记录 t0_us、SessionStart.server_time_us 同源），第 k 步构型调整段接在前一步注能段之后；
  origin 是施法者手边位置（canonical 米，Y-up）；program 为施放意图里的规范程序字节原样。

  违反上述约束的记录（`part_index` 不是排列、步数不在 1..255、`fail_step` 与 `outcome` 不符）编码时显式失败
  （`ArgumentError`），不产生客户端会拒收的字节。
  """
  def encode_casts(delta) do
    for {caster, c} <- Enum.sort(delta), into: <<>> do
      case c do
        %{live: 0, outcome: outcome, fail_step: fail_step} ->
          settled_fail_step?(outcome, fail_step) ||
            raise ArgumentError,
                  "施放记录 #{caster}：outcome #{inspect(outcome)} 与 fail_step #{inspect(fail_step)} 不符"

          <<caster::64, 0::8, outcome::8, fail_step::8, 0::64, 0.0::float-64, 0.0::float-64,
            0.0::float-64, 0::8, 0::16>>

        %{live: 1, t0_us: t0, origin: {x, y, z}, steps: steps, program: program} ->
          part_permutation?(steps) ||
            raise ArgumentError,
                  "施放记录 #{caster}：part_index #{inspect(Enum.map(steps, & &1.part_index))} " <>
                    "不是 0..n−1 的排列（n 须在 1..255）"

          <<caster::64, 1::8, 0::8, 0::8, t0::64, x::float-64, y::float-64, z::float-64,
            length(steps)::8,
            for(
              %{part_index: p, adjust_s: a, inject_s: i} <- steps,
              into: <<>>,
              do: <<p::8, a::float-64, i::float-64>>
            )::binary, byte_size(program)::16, program::binary>>
      end
    end
  end

  @doc """
  `encode_casts/1` 的逆，返回 `{:ok, %{caster => 记录}}` 或 `{:error, :invalid_cast}`。
  已结算记录按同一布局解析，只取 caster、live、outcome、fail_step（其余字段编码端写 0，解码端不用）；
  outcome 1 要求 fail_step ≥ 1，outcome 0 / 2 要求 fail_step = 0。前摇中记录要求 outcome 与 fail_step 为 0、
  至少 1 步、各段时长非负、程序非空。任何记录的 `part_index` 都必须是 0..n−1 的排列。
  """
  def decode_casts(bytes), do: decode_casts(bytes, nil, %{})

  defp decode_casts(<<>>, _, acc), do: {:ok, acc}

  defp decode_casts(
         <<caster::64, live::8, outcome::8, fail_step::8, t0::64, x::float-64, y::float-64,
           z::float-64, n::8, steps::binary-size(n * 17), size::16, program::binary-size(size),
           rest::binary>>,
         previous,
         acc
       )
       when previous == nil or caster > previous do
    steps =
      for <<p::8, a::float-64, i::float-64 <- steps>>,
        do: %{part_index: p, adjust_s: a, inject_s: i}

    record =
      cond do
        not (n == 0 or part_permutation?(steps)) ->
          :invalid

        live == 0 and settled_fail_step?(outcome, fail_step) ->
          %{live: 0, outcome: outcome, fail_step: fail_step}

        live == 1 and outcome == 0 and fail_step == 0 and n > 0 and size > 0 and
            Enum.all?(steps, &(&1.adjust_s >= 0 and &1.inject_s >= 0)) ->
          %{live: 1, t0_us: t0, origin: {x, y, z}, steps: steps, program: program}

        true ->
          :invalid
      end

    if record == :invalid,
      do: {:error, :invalid_cast},
      else: decode_casts(rest, caster, Map.put(acc, caster, record))
  end

  defp decode_casts(_, _, _), do: {:error, :invalid_cast}

  # 已结算记录的 outcome / fail_step 组合：只有“第 k 步中断”（outcome 1）带步号，k 从 1 起。
  defp settled_fail_step?(1, fail_step), do: fail_step in 1..255
  defp settled_fail_step?(outcome, fail_step), do: outcome in [0, 2] and fail_step == 0

  # 前摇各步的 part_index 是 0..n−1 的一个排列（设计 v2.11：构造顺序可以与字节序不同，但每个部件恰好一步）。
  defp part_permutation?(steps) do
    n = length(steps)
    n in 1..255 and Enum.sort(Enum.map(steps, & &1.part_index)) == Enum.to_list(0..(n - 1))
  end
end
