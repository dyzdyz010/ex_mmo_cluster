defmodule NpcServer.Skills.Build do
  @moduledoc """
  全局系统功能：把已发布定义交给正式 Body `prefab_place`（与玩家同一入口），够不着就自己走到射程内再放，按权威结果结束。
  技能壳只经 Body 原子动作 `prefab_place` / `survey` / `move_to`（后两个经 `Skills.Travel.walk/2`，都由 `Skill.call/2` 发出），
  另读一次 World 的足迹（`VoxelRegion.World.prefab_cells/4`）；不直接写 World。

  流程：

  1. 先原样 `prefab_place`。够不够得着只由权威裁决（World `prefab_reach`：眼点到足迹任一宏格在工具射程内），本地不按射程预检，
     所以已在射程内时一步放下、不走路；Settler 树先 travel 到工地站位再 build 时也是这一步；
  2. 被拒 `out_of_reach`：站位是锚点 + 定义足迹的派生事实，不由作者手写——足迹取 `World.prefab_cells/4`：与放置同一几何的
     定义格（micro 格与宏格，含朝向；不含附件格，权威的射程判据另把附件所在宏格算进去），按 `VoxelRegion.Prefab.macro_slot/1`
     归到宏格，站位 = `NpcServer.Blueprint.stands/2`（足迹四条边中点外 1.5 米，与 gather、expand、蓝图施工同一函数），按离自己
     由近到远。定义只有附件时没有定义格、求不出站位，直接以 `:out_of_reach` 结束（见 `approach/3`）；
  3. 逐个站位：`Travel.walk/2` 分段走过去（远处也走得到），再 `prefab_place` 一次。走不到（`Skill.unreachable/0`）或到了仍
     `out_of_reach` → 下一个站位；
  4. 站位用尽：一个都没走到 → `:unreachable`；走到过但都够不着 → `:out_of_reach`。

  其余拒绝（`occupied`、`insufficient_material`、`out_of_bounds`、`protected_region`、会话丢失…）在哪一步遇到都原样作为终态：
  换站位不会改变它们。done 的 data 是放置成功那一次的权威回执。
  """
  @behaviour NpcServer.Skill
  alias NpcServer.{Blueprint, Skill}
  alias NpcServer.Skills.Travel
  alias VoxelRegion.{Prefab, World}

  @metrics %{request_count: 0, jev_request_count: 0}
  # move_to / travel 被这些原因拒绝 = 这个站位去不了，换下一个；其余拒绝原样作为终态。
  @unreachable Skill.unreachable()

  @impl true
  def definition(_profile) do
    %{
      description:
        "将已发布的 definition 整体放到地图上，经现有 prefab_place 结算。锚点是 micro 坐标，" <>
          "1 米 = #{VoxelRegion.Spatial.micro_resolution()} micro。够不着时技能自己走到建筑足迹四边外的站位" <>
          "（由近到远，远处也会分段走过去）再放；站位都走不到时以 unreachable 结束，走到了仍够不着时以 out_of_reach 结束。" <>
          "材料不够时也会先走到建筑旁，再以 insufficient_material 结束。",
      parameters: %{
        type: "object",
        properties:
          Map.put(NpcServer.Skill.placement_properties(), :definition, %{type: "string"}),
        required: ["definition", "anchor_micro", "orientation"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def run(context, %{"definition" => text, "anchor_micro" => anchor, "orientation" => o}, _config)
      when is_binary(text) do
    with {:ok, <<id::binary-size(32)>>} <- Base.decode16(text, case: :mixed),
         {:ok, anchor} <- NpcServer.Skill.anchor(anchor, o) do
      state = %{body: context.body, call: context.call_id, step: 0}
      command = %{verb: :prefab_place, definition_id: id, anchor: anchor, orientation: o}

      case Skill.call(state, command) do
        {:ok, data, _state} ->
          {:ok, Map.put(data, :metrics, @metrics)}

        {:error, :out_of_reach, state} ->
          approach(context, command, state)

        {:error, reason, _state} ->
          {:error, reason, @metrics}
      end
    else
      _ -> {:error, :invalid_skill_arguments, @metrics}
    end
  end

  def run(_, _, _), do: {:error, :invalid_skill_arguments, @metrics}

  # 够不着：取这份定义在这个锚点与朝向的足迹，按站位由近到远逐个走过去再放。
  defp approach(context, command, state) do
    case World.prefab_cells(context.world, command.definition_id, command.anchor, command.orientation) do
      # 定义只有附件：prefab_cells 不含附件格（见 moduledoc 第 2 步），没有足迹就求不出站位（Blueprint.bounds/1 要非空），
      # 权威的够不着原样作为终态。
      {:ok, []} ->
        {:error, :out_of_reach, @metrics}

      {:ok, cells} ->
        {px, _, pz} = position = context.observation.self.position
        footprint = Map.new(cells, fn {micro, material} -> {macro(micro), material} end)

        state =
          Map.merge(state, %{
            position: position,
            half_height: context.movement_profile.half_height,
            reached: false
          })

        visit(Blueprint.stands(footprint, {floor(px), 0, floor(pz)}), command, state)

      {:error, reason} ->
        {:error, reason, @metrics}
    end
  end

  defp visit([], _command, %{reached: false}), do: {:error, :unreachable, @metrics}
  defp visit([], _command, _state), do: {:error, :out_of_reach, @metrics}

  defp visit([stand | rest], command, state) do
    case Travel.walk(state, stand) do
      {:ok, state} ->
        case Skill.call(%{state | reached: true}, command) do
          {:ok, data, _state} -> {:ok, Map.put(data, :metrics, @metrics)}
          {:error, :out_of_reach, state} -> visit(rest, command, state)
          {:error, reason, _state} -> {:error, reason, @metrics}
        end

      {:error, reason, state} when reason in @unreachable ->
        visit(rest, command, state)

      {:error, reason, _state} ->
        {:error, reason, @metrics}
    end
  end

  # 足迹的 micro 坐标所在的宏格（与 World 归并足迹宏格同一换算）。
  defp macro(micro), do: elem(Prefab.macro_slot(micro), 0)
end
