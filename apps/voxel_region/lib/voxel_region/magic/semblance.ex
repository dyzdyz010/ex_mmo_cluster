defmodule VoxelRegion.Magic.Semblance do
  @moduledoc """
  全局系统功能（魔法）：结构物理体的纯几何规则——运动学弹道、canonical 求交后的落点、热内核外部节点的接触与辐射项。
  不读 World；canonical 求交由调用方以 `cast` 回调提供。能量与寿命不在这里：结构的储能、出账与终止全部归
  `VoxelRegion.Magic.Structure`（符号组合魔法 v2；拟态的能量运行时已随切片 4c 删除，旧存档由
  `VoxelRegion.World.SemblanceMigration` 一次散解）。

  物理体（World 的 `World.Structures` 持有）用到的字段：形状 `shape`（0 球 / 1 块 / 2 板）、三轴半尺寸 `half`
  （`{a, b, c}` m；球为 `{r, r, r}`，块与板为〈形〉的 size1–3 半边长，板的第三轴为半厚，设计 §2.3）、落点 `rest`。
  物理体与世界轴对齐（第一轴 x、第二轴 y、第三轴 z；P1 没有朝向，待设计确认）。

  - 弹道：先走眼 → 手直线段，再自手边按 p(t) = hand + v·t − ½·g·t²·ŷ（g = 9.81 m/s²，Y-up；无质量时 g = 0）以 0.05 s
    弦段求交；命中面精确解出穿越时刻（x/z 面线性、y 面二次），物理体中心停在命中点沿面法线外移该轴半尺寸处。施法时对当时
    世界求交，之后世界变化不改弹道（已知偏差：运动学、无冲量与反冲、中心点求交而非扫掠体）。
  - 接触（落地后每段按当前世界重算，不绑定命中格）：物理体的包围盒（中心 rest、半尺寸 half）与每个热节点的实占用盒
    （`ThermalGeometry.bounds/2`）贴面或重叠即接触；接触法向取重叠最小的轴，接触面积 = 其余两轴重叠
    （`ThermalGeometry.overlap/3`）× 形状系数（球 π/4 = 内切圆占外切正方形投影，块与板 1）。每条边导热
    G = A / (h / k_s + d / k_o)，h 为物理体沿接触法向的半尺寸，d 为对方节点沿法向的半程（与 `ThermalGeometry` 同一串联式，
    也与报价 T15 的接触上限同一几何，`Magic.Cost`）。
  - 辐射：球与接触节点之间按球对无限平面的角系数 F = 1/2 互换（εσF·A_exp·(T_s⁴ − T_c⁴)，A_exp = 总表面 − 接触面积之和），
    多条接触时按接触面积比例分摊，其余 (1 − F) 对天空；块与板的接触面整面导热，其余面全部对天空（F = 0）。
    飞行中或无接触时全部暴露面对天空。
  """

  @gravity 9.81
  @step_s 0.05
  # 球静置于平面上对该平面的角系数（经典解 1/2）；块与板以整面贴合导热，不计互见辐射。
  @view_factor %{0 => 0.5, 1 => 0.0, 2 => 0.0}
  # 贴面判据（m）：落点 = 命中面 ± 半尺寸，包围盒的贴面只差浮点舍入。
  @touch 1.0e-9
  # 接触面积 = 包围盒投影重叠 × 形状系数：球取内切圆占外切正方形的 π/4，块与板整面。
  @footprint %{0 => :math.pi() / 4, 1 => 1.0, 2 => 1.0}

  @doc "重力加速度（m/s²，Y-up 向下）；弹道与客户端插值共用。"
  def gravity, do: @gravity

  @doc "弹道位置 p(t) = origin + v·t − ½·g·t²·ŷ；`massless` 为 true 时 g = 0（直线飞行，设计 Q17(a)）。"
  def position(origin, velocity, t, massless \\ false)
  def position({x, y, z}, {vx, vy, vz}, t, true), do: {x + vx * t, y + vy * t, z + vz * t}
  def position({x, y, z}, {vx, vy, vz}, t, false), do: {x + vx * t, y + vy * t - @gravity * t * t / 2, z + vz * t}

  @doc "物理体占据观察窗口的宏格（出发点与落点）。"
  def cells(%{origin: origin, rest: rest}), do: Enum.uniq([macro(origin), macro(rest)])

  @doc "所在宏格（中心点所在）。"
  def macro(point), do: point |> Tuple.to_list() |> Enum.map(&floor/1) |> List.to_tuple()

  @doc """
  自眼睛经手边求首个实占用命中。`cast.(起点, 单位方向, 长度, state)` 返回 `{nil | {目标, 进入微格}, state}`；
  `half` 为物理体三轴半尺寸 `{a, b, c}`（落点沿命中面法线外移该轴的半尺寸）。
  返回 `{{:hit, 落点时刻 s, 落点中心, 目标}, state}`；速度为零且眼 → 手无遮挡时 `{{:free, 手边}, state}`；
  抛出后在 `max_path` 路程内无命中 `{{:miss, 射程端点时刻 s}, state}`：已求交的弦段覆盖到该时刻为止。
  `massless` 为 true 时自手边以 g = 0 直线求交。
  """
  def trace(eye, hand, velocity, half, max_path, state, cast, massless \\ false) do
    length = distance(eye, hand)

    {hit, state} =
      if length > 0, do: cast.(eye, direction(eye, hand, length), length, state), else: {nil, state}

    cond do
      hit != nil ->
        {target, micro} = hit
        d = direction(eye, hand, length)
        {axis, sign, s} = entry(eye, d, micro)
        point = eye |> advance(d, s) |> put_elem(axis, plane(micro, axis, sign))
        {{:hit, 0.0, rest(point, axis, sign, half), target}, state}

      velocity == {0.0, 0.0, 0.0} ->
        {{:free, hand}, state}

      true ->
        arc(hand, velocity, half, 0, length, max_path, state, cast, massless)
    end
  end

  defp arc(_hand, _v, _half, i, path, max_path, state, _cast, _massless) when path >= max_path, do: {{:miss, i * @step_s}, state}

  defp arc(hand, v, half, i, path, max_path, state, cast, massless) do
    t0 = i * @step_s
    a = position(hand, v, t0, massless)
    b = position(hand, v, t0 + @step_s, massless)
    length = distance(a, b)
    d = direction(a, b, length)

    case cast.(a, d, length, state) do
      {nil, state} ->
        arc(hand, v, half, i + 1, path + length, max_path, state, cast, massless)

      {{target, micro}, state} ->
        {axis, sign, s} = entry(a, d, micro)
        plane = plane(micro, axis, sign)
        t = crossing(hand, v, axis, plane, t0 + s / length * @step_s, massless)
        point = hand |> position(v, t, massless) |> put_elem(axis, plane)
        {{:hit, t, rest(point, axis, sign, half), target}, state}
    end
  end

  # 弦段进入命中微格的面：最大进入参数所在轴（slab 法）；起点已在格内时取 0。
  defp entry(a, d, micro) do
    {axis, s} =
      for(i <- 0..2, elem(d, i) != 0.0, do: {i, near(a, d, micro, i)})
      |> Enum.max_by(&elem(&1, 1))

    {axis, if(elem(d, axis) > 0, do: 1, else: -1), max(s, 0.0)}
  end

  defp near(a, d, micro, i) do
    lo = elem(micro, i) / 8
    min((lo - elem(a, i)) / elem(d, i), (lo + 1 / 8 - elem(a, i)) / elem(d, i))
  end

  defp plane(micro, axis, sign), do: (elem(micro, axis) + if(sign > 0, do: 0, else: 1)) / 8

  # 弹道穿越命中面的精确时刻：水平轴或无重力时线性（速度分量为 0 则退回弦段估计）；有重力的竖直轴取二次方程中最接近弦段估计的根。
  defp crossing(hand, v, axis, plane, estimate, massless) when axis != 1 or massless do
    va = elem(v, axis)
    if va == 0.0, do: estimate, else: (plane - elem(hand, axis)) / va
  end

  defp crossing({_, y, _}, {_, vy, _}, 1, plane, estimate, false) do
    disc = vy * vy + 2 * @gravity * (y - plane)

    if disc < 0,
      do: estimate,
      else: Enum.min_by([(vy - :math.sqrt(disc)) / @gravity, (vy + :math.sqrt(disc)) / @gravity], &abs(&1 - estimate))
  end

  defp rest(point, axis, sign, half), do: put_elem(point, axis, elem(point, axis) - sign * elem(half, axis))

  defp distance({ax, ay, az}, {bx, by, bz}), do: :math.sqrt((bx - ax) ** 2 + (by - ay) ** 2 + (bz - az) ** 2)

  @doc """
  一条弦段 a → b 的 canonical 首接触：`{{进入参数（0..1）, 物理体中心落点, 目标}, state}`，无命中为 `{nil, state}`。
  落点 = 进入面上的交点沿面法线外移该轴半尺寸（同 `trace/8`）。
  """
  def segment(a, b, half, state, cast) do
    length = distance(a, b)
    if length == 0.0 do
      {nil, state}
    else
      d = direction(a, b, length)
      case cast.(a, d, length, state) do
        {nil, state} -> {nil, state}
        {{target, micro}, state} ->
          {axis, sign, s} = entry(a, d, micro)
          point = a |> advance(d, s) |> put_elem(axis, plane(micro, axis, sign))
          {{s / length, rest(point, axis, sign, half), target}, state}
      end
    end
  end

  @doc """
  按已过时间把飞行切成最多 0.05 s 的弹道弦段 `[{t0, t1, a, b}]`（自 `age_s` 到 `ending`）。人物采样后端
  `WorldServer.Movement.Projectile` 用它沿弦段扫掠人物；该后端的飞行体 map 仍是 v1 形状（`no_gravity` 键），
  切片 5 把人物采样接回结构时改为物理体的 `massless`（决策稿 §5.1）。
  """
  def flight_segments(s, ending) do
    no_gravity = Map.get(s, :no_gravity, false)

    Stream.unfold(s.age_s, fn t ->
      if t >= ending - 1.0e-9 do
        nil
      else
        next = min(t + @step_s, ending)
        {{t, next, position(s.origin, s.velocity, t, no_gravity), position(s.origin, s.velocity, next, no_gravity)}, next}
      end
    end)
    |> Enum.to_list()
  end

  defp direction({ax, ay, az}, {bx, by, bz}, l), do: {(bx - ax) / l, (by - ay) / l, (bz - az) / l}
  defp advance({x, y, z}, {dx, dy, dz}, s), do: {x + dx * s, y + dy * s, z + dz * s}

  @doc "总表面积（m²）：球 4πr²；块与板 8(ab + bc + ca)（半尺寸 a、b、c，与报价 `Magic.Cost` 同一几何）。"
  def surface(%{shape: 0, half: {r, _, _}}), do: 4 * :math.pi() * r * r
  def surface(%{half: {a, b, c}}), do: 8 * (a * b + b * c + c * a)

  @doc "包围盒 {低角, 高角}（m）：中心 rest、半尺寸 half。"
  def box(%{rest: {x, y, z}, half: {a, b, c}}), do: {{x - a, y - b, z - c}, {x + a, y + b, z + c}}

  @doc "接触候选宏格：包围盒覆盖或贴面的全部宏格（热内核的种子与接触查找范围）。"
  def span(body) do
    {lo, hi} = box(body)
    [xs, ys, zs] = for i <- 0..2, do: floor(elem(lo, i) - @touch)..floor(elem(hi, i) + @touch)//1
    for x <- xs, y <- ys, z <- zs, do: {x, y, z}
  end

  @doc """
  与一个实占用盒 `{低角, 高角}` 的接触：`{面积 m², 法向轴}`，不接触为 nil。任一轴分离即不接触；贴面或重叠时取重叠最小的轴
  为法向（贴面时该轴重叠为 0），面积 = 其余两轴重叠 × 形状系数。
  """
  def contact(body, other) do
    {lo, hi} = cube = box(body)
    {blo, bhi} = other
    {depth, axis} = for(i <- 0..2, do: min(elem(hi, i), elem(bhi, i)) - max(elem(lo, i), elem(blo, i))) |> Enum.with_index() |> Enum.min()
    area = VoxelRegion.ThermalGeometry.overlap(cube, other, axis) * @footprint[body.shape]
    if depth >= -@touch and area > 0, do: {area, axis}
  end

  @doc """
  热内核外部节点元组 `{T, 1, 1, C, k_s, 1e6, 对流暴露面积, 0, 0, true}`（耐热阈值 1e6 K 使 HP 恒不变；无功率、无源余能、
  恒为活动种子）；`contact` 为本段全部接触面积之和（接触面不对流）。
  """
  def node(body, temperature, capacity, conductivity, contact),
    do: {temperature, 1.0, 1.0, capacity, conductivity, 1.0e6, max(surface(body) - contact, 0.0), 0.0, 0.0, true}

  @doc "沿法向轴 `axis` 的一条接触边导热 G = A / (h / k_s + d / k_o)（W/K）；任一导热率为 0 时不导热。"
  def conductance(body, axis, conductivity, other_k, other_half, area),
    do:
      if(conductivity == 0 or other_k == 0,
        do: 0.0,
        else: area / (elem(body.half, axis) / conductivity + other_half / other_k)
      )

  @doc """
  辐射项 {与全部接触节点互换的 εF·A_exp 合计, 对天空 ε(1 − F)·A_exp}；`contact` 为接触面积之和，为 0 时全部对天空。
  互换项由调用方按各接触面积比例分摊；ε 取热环境发射率。
  """
  def radiation(body, emissivity, contact) do
    if contact > 0 do
      exposed = max(surface(body) - contact, 0.0)
      f = @view_factor[body.shape]
      {emissivity * f * exposed, emissivity * (1 - f) * exposed}
    else
      {0.0, emissivity * surface(body)}
    end
  end
end
