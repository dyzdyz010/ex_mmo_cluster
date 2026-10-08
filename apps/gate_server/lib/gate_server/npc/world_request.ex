defmodule GateServer.Npc.WorldRequest do
  @moduledoc """
  全局系统功能：NPC 规范命令（形状见 `GateServer.Npc.Brain`）→ 与 `MmoContracts.Voxel.Codec.decode/1` 同形的
  `{kind, request}`，交给 `SceneServer.Movement.Intent.run/3`。纯函数，无进程。

  这里只做类型守卫（方向是数字三元组、tool / 坐标 / 目标句柄的身份字段是整数、definition 是二进制等），取值约束一律调
  `Codec.intent?/1`——线解码与本模块共用同一组谓词，任一不满足返回 nil（Body 回报 `:invalid_command`）。
  `client_intent_seq` 与 `request_id` 取调用方给的本会话序号，`logical_scene_id` 取当前 Scene。

  动词 → 线帧：`probe_toward` / `use_tool` / `dismantle` = 0x7D action 0 / 1 / 2；`place` / `scoop` / `pour` /
  `craft` / `eat` = 0x7F action 1..5；`attach` / `detach` = 0x81 action 0 / 1；`prefab_place` / `prefab_remove` /
  `prefab_replace` = 0x7A / 0x7B / 0x7C。冻结帧对拍见 `apps/gate_server/test/gate_server/npc_world_request_test.exs`。
  """
  alias MmoContracts.Voxel.Codec

  @tool %{probe_toward: 0, use_tool: 1, dismantle: 2}
  @production %{place: 1, scoop: 2, pour: 3}
  # 合成与进食不读坐标与工具（World 生产意图 action 4 / 5），与玩家客户端同样填零坐标与 1 号工具。
  @inventory %{craft: 4, eat: 5}
  @attachment %{attach: 0, detach: 1}
  @prefab %{
    prefab_place: :voxel_prefab_place_v1,
    prefab_remove: :voxel_prefab_remove_v1,
    prefab_replace: :voxel_prefab_replace_v1
  }
  # 工具目标句柄里进请求的身份字段（与 0x7D 线帧同名）。
  @handle [:micro, :incarnation, :owner, :material, :granularity]
  @verbs Enum.flat_map([@tool, @production, @inventory, @attachment, @prefab], &Map.keys/1)

  @type context :: %{seq: pos_integer(), scene_id: non_neg_integer(), eye: {number(), number(), number()} | nil}

  @doc "本模块拼装的全部规范动词（Body 据此把命令交给世界意图入口）。"
  def verbs, do: @verbs

  @doc "该命令是否要由 Body 按眼点补方向（`use_tool` / `dismantle` 给了目标句柄、没给方向）；眼点未知时 Body 回 `:invalid_session`。"
  def aims?(%{verb: verb} = command) when verb in [:use_tool, :dismantle],
    do: Map.get(command, :direction) == nil and is_map(Map.get(command, :target))

  def aims?(_command), do: false

  @doc """
  规范命令 → `{kind, request}`；不合法返回 nil。`context.eye` 只在 `aims?/1` 为真时使用。
  """
  @spec build(map(), context()) :: {atom(), map()} | nil
  def build(command, context) do
    intent = shape(command, context)
    if intent != nil and Codec.intent?(intent), do: intent
  end

  @doc """
  目标句柄的瞄准方向（单位向量，自眼点）：g0 瞄宏格中心（`micro + 4` micro），g1 / g2 瞄该 micro 的中心
  （`micro + 0.5`），g3 附件按身份寻址、任取 +X，g5 人物用探测时的方向（句柄里的 `direction`）。
  micro 坐标 / 8 = 米。形状不对，或眼点恰在瞄准点上（没有方向，同 `Attention.toward/2` 的 zero_direction）返回 nil。
  """
  def aim(_eye, %{granularity: 5} = handle), do: vector(Map.get(handle, :direction))
  def aim(_eye, %{granularity: 3}), do: {1.0, 0.0, 0.0}

  def aim({ex, ey, ez}, %{micro: {x, y, z}} = handle)
      when is_integer(x) and is_integer(y) and is_integer(z) do
    offset = if Map.get(handle, :granularity, 0) == 0, do: 4, else: 0.5
    {dx, dy, dz} = {(x + offset) / 8 - ex, (y + offset) / 8 - ey, (z + offset) / 8 - ez}
    length = :math.sqrt(dx * dx + dy * dy + dz * dz)
    if length > 0, do: {dx / length, dy / length, dz / length}
  end

  def aim(_eye, _handle), do: nil

  # —— 各动词的类型守卫与拼装；取值约束留给 Codec.intent?/1 ——

  # action 0 = 沿方向探测实际命中；1 = 攻击 / 使用该目标身份；2 = 拆解构件（按剩余燃料退料）。
  # target 只能是身份 map 或缺省（缺省时交权威按射线裁决）；g3 附件按身份寻址，g5 是人物 `{cid, 0}`。
  defp shape(%{verb: verb, tool_id: tool} = command, context)
       when is_map_key(@tool, verb) and is_integer(tool) do
    target = Map.get(command, :target)

    direction =
      if aims?(command),
        do: aim(context.eye, target),
        else: vector(Map.get(command, :direction))

    if direction != nil and handle?(target) do
      fields =
        %{
          action: @tool[verb],
          direction: direction,
          micro: {0, 0, 0},
          incarnation: 0,
          owner: {0, 0},
          material: 0,
          tool_id: tool,
          granularity: 0
        }
        |> Map.merge(if(is_map(target), do: Map.take(target, @handle), else: %{}))

      {:voxel_tool_intent, common(context, fields)}
    end
  end

  defp shape(%{verb: verb, coord: {x, y, z}, material: material, tool_id: tool}, context)
       when is_map_key(@production, verb) and is_integer(x) and is_integer(y) and is_integer(z) and
              is_integer(material) and is_integer(tool),
       do:
         {:voxel_production_intent,
          common(context, %{
            action: @production[verb],
            coord: {x, y, z},
            material: material,
            tool_id: tool
          })}

  defp shape(%{verb: verb, material: material}, context)
       when is_map_key(@inventory, verb) and is_integer(material),
       do:
         {:voxel_production_intent,
          common(context, %{
            action: @inventory[verb],
            coord: {0, 0, 0},
            material: material,
            tool_id: 1
          })}

  # anchor 是 micro 坐标；detach 要带上那件附件的 id（attachment_id）与材料，与玩家请求同形。
  defp shape(
         %{
           verb: verb,
           kind: _,
           axis: _,
           size: _,
           anchor: {x, y, z},
           material: material,
           tool_id: tool
         } = command,
         context
       )
       when is_map_key(@attachment, verb) and is_integer(x) and is_integer(y) and is_integer(z) and
              is_integer(material) and is_integer(tool) do
    id = Map.get(command, :attachment_id, 0)

    if is_integer(id),
      do:
        {:voxel_attachment_intent,
         common(
           context,
           Map.take(command, [:kind, :axis, :size, :anchor, :material, :tool_id])
           |> Map.merge(%{action: @attachment[verb], id: id})
         )}
  end

  defp shape(%{verb: :prefab_place, definition_id: id, anchor: {x, y, z}} = command, context)
       when is_binary(id) and is_integer(x) and is_integer(y) and is_integer(z) do
    if is_map_key(command, :orientation),
      do:
        {@prefab.prefab_place,
         common(context, Map.take(command, [:definition_id, :anchor, :orientation]))}
  end

  defp shape(%{verb: :prefab_remove, instance_id: {birth, occurrence}}, context)
       when is_integer(birth) and is_integer(occurrence),
       do: {@prefab.prefab_remove, common(context, %{instance_id: {birth, occurrence}})}

  defp shape(
         %{verb: :prefab_replace, instance_id: {birth, occurrence}, definition_id: id},
         context
       )
       when is_integer(birth) and is_integer(occurrence) and is_binary(id),
       do:
         {@prefab.prefab_replace,
          common(context, %{instance_id: {birth, occurrence}, definition_id: id})}

  defp shape(_command, _context), do: nil

  # 目标句柄的类型守卫：给出的身份字段必须与线解码同型（整数、整数元组），缺的字段取上面的零值。
  # 非整数（如 JSON 的 12.0）会让 World 进程内的整数运算（`Damage.macro/1` 等）崩溃，所以在这里挡下。
  defp handle?(nil), do: true

  defp handle?(%{} = target),
    do: Enum.all?(Map.take(target, @handle), fn {key, value} -> handle_field?(key, value) end)

  defp handle?(_), do: false

  defp handle_field?(:micro, {x, y, z}), do: is_integer(x) and is_integer(y) and is_integer(z)
  defp handle_field?(:owner, {id, n}), do: is_integer(id) and is_integer(n)

  defp handle_field?(key, value) when key in [:incarnation, :material, :granularity],
    do: is_integer(value)

  defp handle_field?(_key, _value), do: false

  defp vector({dx, dy, dz} = direction) when is_number(dx) and is_number(dy) and is_number(dz),
    do: direction

  defp vector(_), do: nil

  # 与玩家请求同形的公共字段；client_intent_seq 在本会话内跨所有事务严格递增（由调用方分配）。
  defp common(context, fields),
    do:
      Map.merge(fields, %{
        request_id: context.seq,
        client_intent_seq: context.seq,
        logical_scene_id: context.scene_id
      })
end
