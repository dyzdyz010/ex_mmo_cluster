defmodule VoxelRegion.World.AreaTool do
  @moduledoc """
  全局系统功能：战斗招式的单段球形判定区（`object` 单体段、`direction` 范围段）。
  人物候选由 Scene authority 冻结提供；体素只作遮挡，不投递体素损伤（设计 §6.3、§6.4）。
  """
  require Logger
  alias MmoContracts.Session.Codec
  alias VoxelRegion.World.Tools

  # 水平分量短于此值的方向视为竖直，没有出招朝向。
  @vertical 1.0e-6

  @doc """
  判定球心：眼点沿出招水平朝向前移 `area_offset_m`。请求方向只表达水平朝向（客户端 `AttackDirection` 恒为水平），
  俯仰分量在权威端丢弃，判定球不随俯仰移到眼点上下；所有形状参数来自同一作者目录。
  """
  def center(eye, direction, tool) do
    {hx, _, hz} = bearing(direction)
    {x, y, z} = eye
    {x + hx * tool["area_offset_m"], y, z + hz * tool["area_offset_m"]}
  end

  # 请求方向投影到水平面后归一化；近乎竖直（水平分量 < @vertical）没有朝向，返回 nil。
  defp bearing({dx, _, dz}) do
    length = :math.sqrt(dx * dx + dz * dz)
    if length < @vertical, do: nil, else: {dx / length, 0.0, dz / length}
  end

  @doc "精确球内点判定，包含边界；canonical XYZ，单位米。"
  def contains?(point, center, radius),
    do: Enum.sum(for i <- 0..2, do: (elem(point, i) - elem(center, i)) ** 2) <= radius * radius

  @doc """
  执行一段招式。先复核出招朝向（不消耗频率），再接纳本工具频率一次，最后在提交前快照里裁决遮挡。
  候选带 Scene 侧 Harm 许可标记 `permitted`；区内可见者中只在可作用者里选（单体段按 §6.3，范围段全部）。
  返回 `{:area, seq, [{target, :torso}]}`：区内无可见者即打空（频率已消耗，世界不变）；
  区内有可见者但全都不可作用返回 `{:error, :combat_not_permitted}`（频率同样已消耗）；
  朝向超出 `aim_max_deg` 或近乎竖直返回 `{:error, :facing}`；其余为既有工具／频率错误。
  """
  def run(before, state, actor, request, tool) do
    started = System.monotonic_time(:microsecond)
    cond do
      tool["target_mode"] not in ["object", "direction"] or request.action != 1 ->
        {:reply, {:error, :invalid_tool}, before}

      not facing?(actor.yaw, request.direction, tool["aim_max_deg"]) ->
        Logger.info("voxel_area_tool request_id=#{request.request_id} client_seq=#{request.client_intent_seq} result=facing yaw=#{actor.yaw}")
        {:reply, {:error, :facing}, before}

      true ->
        case Tools.admit_tool(state, actor, request, tool) do
          {:ok, state} ->
            {visible, state} = visible_bodies(state, actor.eye, request.direction, tool, Map.get(actor, :area_targets, []))
            permitted = Enum.filter(visible, & &1.permitted)
            # owner {0,0} / incarnation 0 即无提示；人物 id 恒 > 0，不会与之相等。
            bodies = if tool["target_mode"] == "object",
              do: select(permitted, center(actor.eye, request.direction, tool), {elem(request.owner, 0), request.incarnation}),
              else: permitted
            Logger.info("voxel_area_tool request_id=#{request.request_id} client_seq=#{request.client_intent_seq} mode=#{tool["target_mode"]} visible=#{length(visible)} permitted=#{length(permitted)} bodies=#{length(bodies)} seq=#{state.seq} elapsed_us=#{System.monotonic_time(:microsecond) - started}")
            if visible != [] and permitted == [],
              do: {:reply, {:error, :combat_not_permitted}, state},
              else: {:reply, {:area, state.seq, Enum.map(bodies, &{&1, :torso})}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, before}
        end
    end
  end

  @doc """
  出招水平朝向复核：请求方向的水平分量与已确认 yaw 前向夹角 ≤ `max_deg`；俯仰不参与判定区（见 `center/3`），
  水平分量为零的竖直方向没有朝向，拒绝。
  yaw 为 canonical Y-up 量化角，前向同 `Session.Codec.yaw_forward/1`（0 → +X，16384 → +Z）。
  """
  def facing?(yaw, direction, max_deg) do
    case bearing(direction) do
      nil -> false
      {hx, _, hz} ->
        aim = round(:math.atan2(hz, hx) * 65536 / (2 * :math.pi()))
        abs(Codec.yaw_delta(yaw, aim)) * 360 / 65536 <= max_deg
    end
  end

  @doc """
  单体段在已冻结、已过遮挡的可见集合中只选一个（设计 §6.3）：提示 `{id, 生命代次}` 在集合里只选它；
  同 id 不同生命代次的候选剔除、不作替补；否则选判定中心到胶囊轴段最近者，同距按 id 升序；集合为空即打空。
  """
  def select(bodies, center, {id, life}) do
    candidates = Enum.reject(bodies, &(&1.id == id and &1.life_generation != life))
    case Enum.find(candidates, &(&1.id == id)) do
      nil -> candidates |> Enum.min_by(&{axis_distance(center, &1), &1.id}, fn -> nil end) |> List.wrap()
      target -> [target]
    end
  end

  @doc "球与 Y-up 胶囊相交；人物范围使用公开移动 profile，不扩大为地面圆。"
  def body_in_range?(center, radius, target),
    do: contains?(axis_point(target, elem(center, 1)), center, radius + target.profile.radius)

  defp axis_distance(center, target) do
    point = axis_point(target, elem(center, 1))
    :math.sqrt(Enum.sum(for i <- 0..2, do: (elem(point, i) - elem(center, i)) ** 2))
  end

  # 胶囊轴段上离高度 y 最近的点。
  defp axis_point(target, y) do
    {x, ty, z} = target.position
    half_line = target.profile.half_height - target.profile.radius
    {x, min(max(y, ty - half_line), ty + half_line), z}
  end

  # 遮挡与 g5 人物射线同一判定（`Tools.body_occluded?/4`：体素、构件、附件面挡，液体透明）。
  defp visible_bodies(state, eye, aim, tool, bodies) do
    center = center(eye, aim, tool)
    Enum.map_reduce(Enum.uniq_by(bodies, &{&1.id, &1.life_generation}), state, fn target, state ->
      if body_in_range?(center, tool["area_radius_m"], target) do
        {direction, distance} = toward(eye, axis_point(target, elem(eye, 1)))
        case Tools.body_occluded?(state, eye, direction, max(0.0, distance - target.profile.radius)) do
          {false, state} -> {target, state}
          {true, state} -> {nil, state}
        end
      else
        {nil, state}
      end
    end)
    |> then(fn {bodies, state} -> {Enum.reject(bodies, &is_nil/1), state} end)
  end

  defp toward(a, b) do
    delta = map3(fn i -> elem(b, i) - elem(a, i) end)
    distance = :math.sqrt(Enum.sum(for i <- 0..2, do: elem(delta, i) ** 2))
    # 重叠人物没有非零射线段；方向任意但距离仍为零，照常检查起始格遮挡。
    {if(distance == 0.0, do: {1.0, 0.0, 0.0}, else: map3(fn i -> elem(delta, i) / distance end)), distance}
  end

  defp map3(fun), do: {fun.(0), fun.(1), fun.(2)}
end
