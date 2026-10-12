defmodule NpcServer.Attention do
  @moduledoc """
  全局系统功能：NPC 本地关注与观察方向。无世界副本，不改变移动、阵营或攻击。
  13 个关注动词的能力条目（group :attend，形状见 `NpcServer.Abilities`）也在这里，动词表由条目派生。
  """
  @groups [:enemy, :friendly]
  @reach NpcServer.Perception.reach()
  @doc "关注动词（由条目名派生；Body 据此把命令交给本模块）。"
  def verbs, do: for(entry <- entries(), do: String.to_atom(entry.name))
  @doc "初始观察朝 +X；各组独立焦点，本地标记独立于清空选择。"
  def new,
    do: %{
      direction: {1.0, 0.0, 0.0},
      enemy: %{members: [], focus: nil},
      friendly: %{members: [], focus: nil},
      mark: nil
    }

  @doc "观测范围沿用已有感知上限；视锥半角为 45 度。"
  def view(a, origin),
    do: %{
      origin: origin,
      direction: a.direction,
      range_m: NpcServer.Perception.reach(),
      half_angle_degrees: 45.0
    }

  @doc "目标身份只接受当前已同步且同一代次的角色。"
  def resolve(entities, %{entity_id: id, entity_epoch: epoch})
      when is_integer(id) and is_integer(epoch) do
    case entities[id] do
      %{entity_epoch: ^epoch} = e -> {:ok, Map.put(e, :entity_id, id)}
      _ -> {:error, :stale_target}
    end
  end

  def resolve(_, _), do: {:error, :invalid_target}
  @doc "实体离开或更换代次，清除两组成员、焦点与标记。"
  def forget(a, id) do
    a = Enum.reduce(@groups, a, fn g, acc -> Map.update!(acc, g, &remove(&1, id)) end)
    if a.mark && a.mark.entity_id == id, do: %{a | mark: nil}, else: a
  end

  defp remove(g, id) do
    members = Enum.reject(g.members, &(&1.entity_id == id))

    %{
      members: members,
      focus: if(g.focus && g.focus.entity_id == id, do: List.first(members), else: g.focus)
    }
  end

  @doc "归一化完整 XYZ 方向；坐标各轴沿用感知查询范围，零方向显式拒绝。"
  def toward({x, y, z}, {tx, ty, tz}) when is_number(tx) and is_number(ty) and is_number(tz) do
    if tx < x - @reach or tx > x + @reach or ty < y - @reach or ty > y + @reach or tz < z - @reach or
         tz > z + @reach do
      {:error, :out_of_range}
    else
      d = :math.sqrt((tx - x) ** 2 + (ty - y) ** 2 + (tz - z) ** 2)

      if d == 0,
        do: {:error, :zero_direction},
        else: {:ok, {(tx - x) / d, (ty - y) / d, (tz - z) / d}}
    end
  end

  def toward(_, _), do: {:error, :invalid_position}
  @doc "中心点的距离与视锥过滤；遮挡由 World 独立裁决。"
  def in_view?(a, origin, point) do
    distance = distance(origin, point)

    case toward(origin, point) do
      {:ok, {x, y, z}} ->
        {dx, dy, dz} = a.direction

        distance <= NpcServer.Perception.reach() &&
          x * dx + y * dy + z * dz >= :math.cos(:math.pi() / 4)

      {:error, :zero_direction} ->
        true

      {:error, :out_of_range} ->
        false
    end
  end

  @doc "canonical 米坐标的距离。"
  def distance({x, y, z}, {a, b, c}), do: :math.sqrt((x - a) ** 2 + (y - b) ** 2 + (z - c) ** 2)

  @doc "执行本地关注命令；返回新状态与结果，或明确拒绝。"
  def apply(a, %{verb: :get_targets}, _, _), do: {:ok, a, Map.take(a, [:enemy, :friendly, :mark])}
  def apply(a, %{verb: :get_view}, _, origin), do: {:ok, a, view(a, origin)}

  def apply(_, %{verb: :look_at, position: _, target: _}, _, _), do: {:error, :invalid_command}

  def apply(a, %{verb: :look_at, position: p}, _, origin) do
    with {:ok, d} <- toward(origin, p),
         do: {:ok, %{a | direction: d}, view(%{a | direction: d}, origin)}
  end

  def apply(a, %{verb: :look_at, target: t}, entities, origin) do
    with {:ok, e} <- resolve(entities, t),
         do: apply(a, %{verb: :look_at, position: e.position}, entities, origin)
  end

  def apply(a, %{verb: :select_target, target: t, group: g}, entities, _) when g in @groups do
    with {:ok, _} <- resolve(entities, t) do
      t = Map.take(t, [:entity_id, :entity_epoch])
      # 显式归组；同一角色不能同时在敌、友两组。
      other = if g == :enemy, do: :friendly, else: :enemy
      a = Map.update!(a, other, &remove(&1, t.entity_id))
      group = a[g]
      members = if t in group.members, do: group.members, else: group.members ++ [t]
      done(Map.put(a, g, %{members: members, focus: t}))
    end
  end

  def apply(a, %{verb: :remove_target, target: t}, entities, _) do
    with {:ok, _} <- resolve(entities, t),
         do:
           done(
             Enum.reduce(@groups, a, fn g, b -> Map.update!(b, g, &remove(&1, t.entity_id)) end)
           )
  end

  def apply(a, %{verb: :set_focus, target: t, group: g}, entities, _) when g in @groups do
    with {:ok, _} <- resolve(entities, t) do
      t = Map.take(t, [:entity_id, :entity_epoch])
      if t in a[g].members, do: done(put_in(a, [g, :focus], t)), else: {:error, :not_selected}
    end
  end

  def apply(a, %{verb: :cycle_focus, group: g, direction: d}, _, _)
      when g in @groups and d in [-1, 1] do
    group = a[g]

    if group.members == [],
      do: done(a),
      else:
        done(
          put_in(
            a,
            [g, :focus],
            Enum.at(
              group.members,
              Integer.mod(
                Enum.find_index(group.members, &(&1 == group.focus)) + d,
                length(group.members)
              )
            )
          )
        )
  end

  def apply(a, %{verb: :remove_focus, group: g}, _, _) when g in @groups do
    done(if a[g].focus, do: Map.update!(a, g, &remove(&1, a[g].focus.entity_id)), else: a)
  end

  def apply(a, %{verb: :clear_targets}, _, _),
    do: done(%{a | enemy: new().enemy, friendly: new().friendly})

  def apply(a, %{verb: :toggle_mark}, _, _),
    do: done(%{a | mark: if(a.mark == a.enemy.focus, do: nil, else: a.enemy.focus)})

  def apply(_, _, _, _), do: {:error, :invalid_command}
  defp done(a), do: {:ok, a, Map.take(a, [:enemy, :friendly, :mark])}

  @doc "关注条目（顺序固定）：目标参数是 entity_id + entity_epoch，group 是 enemy / friendly。"
  def entries do
    target = [entity_id: :integer, entity_epoch: :integer]
    group = [group: {:enum, %{"enemy" => :enemy, "friendly" => :friendly}}]
    nullable = fn fields -> for {key, spec} <- fields, do: {key, {:nullable, spec}} end

    for {verb, description, params} <- [
          {:get_view, "获取观察位置、方向、距离与视角；独立于移动朝向。", []},
          {:look_at,
           "看向坐标或当前角色：给完整 x/y/z（entity_id、entity_epoch 写 null），或给 entity_id/entity_epoch（x/y/z 写 null）；" <>
             "不改变选择、不攻击。", nullable.(target ++ [x: :number, y: :number, z: :number])},
          {:get_aim, "获取当前观察射线最近的角色或方块/构件；范围不代表攻击可达，附件未采样。", []},
          {:get_visible_entities, "获取已同步角色中，中心点位于视锥内且无遮挡的角色；不枚举全部地形。", []},
          {:get_target_status, "查询角色有效性、距离与中心点可见状态，不裁决技能射程。", target},
          {:select_target, "加入指定本地组并聚焦；不转向、不攻击，不改变真实阵营。", target ++ group},
          {:remove_target, "从选中组移除角色；本地标记独立。", target},
          {:get_targets, "获取敌友两组、各组焦点及本地标记。", []},
          {:set_focus, "在已选组中指定焦点，不增加成员。", target ++ group},
          {:cycle_focus, "仅轮换已选组，direction 为 1 或 -1。", group ++ [direction: {:enum, [-1, 1]}]},
          {:remove_focus, "移除指定组当前焦点，首个剩余成员成为焦点。", group},
          {:clear_targets, "清空两组，保留独立本地标记。", []},
          {:toggle_mark, "切换敌方焦点的本地标记，不向团队广播。", []}
        ],
        do: %{
          name: Atom.to_string(verb),
          group: :attend,
          description: description,
          done: "立即返回（带 self_tick 采样版本），只改本地关注状态。",
          params: params,
          build: fn args, _ -> command(verb, args) end
        }
  end

  # 定型参数 → 规范命令：entity_id 非空才带 target，x 非空才带 position。
  defp command(verb, args) do
    %{verb: verb}
    |> put_if(Map.get(args, :entity_id) != nil, :target, fn ->
      %{entity_id: args.entity_id, entity_epoch: args.entity_epoch}
    end)
    |> put_if(Map.get(args, :x) != nil, :position, fn -> {args.x, args.y, args.z} end)
    |> put_if(Map.has_key?(args, :group), :group, fn -> args.group end)
    |> put_if(Map.has_key?(args, :direction), :direction, fn -> args.direction end)
  end

  defp put_if(command, true, key, value), do: Map.put(command, key, value.())
  defp put_if(command, false, _key, _value), do: command
end
