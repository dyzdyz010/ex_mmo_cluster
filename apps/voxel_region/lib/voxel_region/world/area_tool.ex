defmodule VoxelRegion.World.AreaTool do
  @moduledoc """
  全局系统功能：战斗招式的单段球形判定区（`object` 单体段、`direction` 范围段）。
  人物候选由 Scene authority 冻结提供；体素只作遮挡，不投递体素损伤（设计 §6.3、§6.4）。
  """
  require Logger
  alias MmoContracts.Session.Codec
  alias VoxelRegion.Damage
  alias VoxelRegion.World.{Canonical, Tools}

  @doc "接纳的非零方向在权威端归一化；所有形状参数来自同一作者目录。"
  def center(eye, direction, tool) do
    length = :math.sqrt(Enum.sum(for i <- 0..2, do: elem(direction, i) ** 2))
    map3(fn i -> elem(eye, i) + elem(direction, i) / length * tool["area_offset_m"] end)
  end

  @doc "精确球内点判定，包含边界；canonical XYZ，单位米。"
  def contains?(point, center, radius),
    do: Enum.sum(for i <- 0..2, do: (elem(point, i) - elem(center, i)) ** 2) <= radius * radius

  @doc """
  执行一段招式。先复核出招朝向（不消耗频率），再接纳本工具频率一次，最后在提交前快照里裁决遮挡。
  返回 `{:area, seq, [{target, :torso}]}`：空列表即打空（频率已消耗，世界不变）；
  朝向超出 `aim_max_deg` 返回 `{:error, :facing}`；其余为既有工具／频率错误。
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
            # owner {0,0} / incarnation 0 即无提示；人物 id 恒 > 0，不会与之相等。
            bodies = if tool["target_mode"] == "object",
              do: select(visible, center(actor.eye, request.direction, tool), {elem(request.owner, 0), request.incarnation}),
              else: visible
            Logger.info("voxel_area_tool request_id=#{request.request_id} client_seq=#{request.client_intent_seq} mode=#{tool["target_mode"]} visible=#{length(visible)} bodies=#{length(bodies)} seq=#{state.seq} elapsed_us=#{System.monotonic_time(:microsecond) - started}")
            {:reply, {:area, state.seq, Enum.map(bodies, &{&1, :torso})}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, before}
        end
    end
  end

  @doc """
  出招水平朝向复核：请求方向的水平分量与已确认 yaw 前向夹角 ≤ `max_deg`；俯仰不复核。
  yaw 为 canonical Y-up 量化角，前向同 `Session.Codec.yaw_forward/1`（0 → +X，16384 → +Z）。
  """
  def facing?(yaw, {dx, _, dz}, max_deg) do
    aim = round(:math.atan2(dz, dx) * 65536 / (2 * :math.pi()))
    abs(Codec.yaw_delta(yaw, aim)) * 360 / 65536 <= max_deg
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

  # 遮挡只经 canonical 宏格／微格／构件射线；附件不参与（已知缺口）。没有损伤许可的阻挡物也不当空气。
  defp visible_bodies(state, eye, aim, tool, bodies) do
    center = center(eye, aim, tool)
    Enum.map_reduce(Enum.uniq_by(bodies, &{&1.id, &1.life_generation}), state, fn target, state ->
      if body_in_range?(center, tool["area_radius_m"], target) do
        {direction, distance} = toward(eye, axis_point(target, elem(eye, 1)))
        case Damage.raycast(eye, direction, max(0.0, distance - target.profile.radius), state, &Canonical.target_at/2) do
          {:error, :no_target, state} -> {target, state}
          {:ok, _, state} -> {nil, state}
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
