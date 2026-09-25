defmodule VoxelRegion.Magic.Semblance do
  @moduledoc """
  全局系统功能（魔法增量 2）：拟态运行时对象的纯值规则——记录、运动学弹道、热内核外部节点项与剩余能量
  （Voxim Docs/Magic.md §3）。不读 World；canonical 求交由调用方以 `cast` 回调提供。

  记录（World 持有于 `thermal.semblances`，id = {创建事务 seq, n}）：
  施法者 caster、形状 shape（0 球 / 1 立方，radius_m 为半径或半边长）、质量 mass_kg、热容 capacity（= 质量 × 目录比热，J/K）、
  温度 temperature_k、发光 glow_w、寿命 lifetime_s、已存在模拟时长 age_s、飞行中动能 kinetic_j、
  运动 origin / velocity / t0_us（服务端墙钟 µs，仅供客户端插值）/ flight_s（落点时刻，模拟秒）/ rest（落点）、
  命中 contact（nil 或 `%{target, key, cell}`：弹道命中的热节点，只用作到期 / 驱散时剩余能量的落点）。solid 恒为 false（实体拟态是增量 5）。

  - 弹道：先走眼 → 手直线段，再自手边按 p(t) = hand + v·t − ½·g·t²·ŷ（g = 9.81 m/s²，Y-up）以 0.05 s 弦段求交；
    命中面精确解出穿越时刻（x/z 面线性、y 面二次），拟态中心停在命中点沿面法线外移一个半径处。施法时对当时世界求交，
    之后世界变化不改弹道（已知偏差：运动学、无冲量与反冲、拟态中心点求交而非扫掠球体）。
  - 落地：飞行动能全部转为拟态自身内能（完全非弹性），ΔT = ½mv²/C。
  - 热节点：`{T, 1, 1, C, k_s, 1e6, 对流暴露面积, 0, 0, true}`（耐热阈值 1e6 K 使 HP 恒不变；无功率、无源余能、恒为活动种子）。
  - 接触（落地后每段按当前世界重算，不绑定命中格）：拟态的包围立方体（中心 rest、半边 r）与每个热节点的实占用盒
    （`ThermalGeometry.bounds/2`）贴面或重叠即接触；接触法向取重叠最小的轴，接触面积 = 其余两轴重叠
    （`ThermalGeometry.overlap/3`）× 形状系数（球 π/4 = 内切圆占外切正方形投影，立方体 1）。于是完整落在一个宏格面上的
    球接触面积为 πr²，跨格边界的球按各格实际重叠面积分到多条边。每条边导热 G = A / (r / k_s + d / k_o)，与
    `ThermalGeometry` 同一串联式（d = 该节点沿接触法向的半程）。
  - 辐射：球与接触节点之间按球对无限平面的角系数 F = 1/2 互换（εσF·A_exp·(T_s⁴ − T_c⁴)，A_exp = 总表面 − 接触面积之和），
    多条接触时按接触面积比例分摊，其余 (1 − F) 对天空；立方体接触面整面导热，其余面全部对天空（F = 0）。
    飞行中或无接触时全部暴露面对天空。
  - 剩余能量 = C·(T − T_amb) + 飞行中动能 + 发光余量 glow_w·(lifetime − age)。发光按 W·dt 计入光账（不进热账），
    寿命到期（即发光预算耗尽）移除，剩余能量作为有限热源释放。
  """

  @gravity 9.81
  @step_s 0.05
  # 球静置于平面上对该平面的角系数（经典解 1/2）；立方体以整面贴合导热，不计互见辐射。
  @view_factor %{0 => 0.5, 1 => 0.0}
  # 数值容差：累加的模拟时长与落点 / 寿命端点对齐判定。
  @epsilon 1.0e-9
  # 贴面判据（m）：落点 = 命中面 ± 半径，包围立方体的贴面只差浮点舍入。
  @touch 1.0e-9
  # 接触面积 = 包围立方体投影重叠 × 形状系数：球取内切圆占外切正方形的 π/4，立方体整面。
  @footprint %{0 => :math.pi() / 4, 1 => 1.0}

  @doc "重力加速度（m/s²，Y-up 向下）；弹道与客户端插值共用。"
  def gravity, do: @gravity

  @doc "弹道位置 p(t) = origin + v·t − ½·g·t²·ŷ。"
  def position({x, y, z}, {vx, vy, vz}, t), do: {x + vx * t, y + vy * t - @gravity * t * t / 2, z + vz * t}

  @doc "当前中心位置：飞行中按已存在时长求弹道，落地后为落点。"
  def current(s), do: if(landed?(s), do: s.rest, else: position(s.origin, s.velocity, s.age_s))

  @doc "拟态占据观察窗口的宏格（出发点与落点）。"
  def cells(s), do: Enum.uniq([macro(s.origin), macro(s.rest)])

  @doc "所在宏格（中心点所在）。"
  def macro(point), do: point |> Tuple.to_list() |> Enum.map(&floor/1) |> List.to_tuple()

  @doc """
  自眼睛经手边求首个实占用命中。`cast.(起点, 单位方向, 长度, state)` 返回 `{nil | {目标, 进入微格}, state}`。
  返回 `{{:hit, 落点时刻 s, 落点中心, 目标}, state}`；速度为零且眼 → 手无遮挡时 `{{:free, 手边}, state}`；
  抛出后在 `max_path` 路程内无命中 `{:miss, state}`。
  """
  def trace(eye, hand, velocity, radius, max_path, state, cast) do
    length = distance(eye, hand)

    {hit, state} =
      if length > 0, do: cast.(eye, direction(eye, hand, length), length, state), else: {nil, state}

    cond do
      hit != nil ->
        {target, micro} = hit
        d = direction(eye, hand, length)
        {axis, sign, s} = entry(eye, d, micro)
        point = eye |> advance(d, s) |> put_elem(axis, plane(micro, axis, sign))
        {{:hit, 0.0, rest(point, axis, sign, radius), target}, state}

      velocity == {0.0, 0.0, 0.0} ->
        {{:free, hand}, state}

      true ->
        arc(hand, velocity, radius, 0, length, max_path, state, cast)
    end
  end

  defp arc(_hand, _v, _radius, _i, path, max_path, state, _cast) when path >= max_path, do: {:miss, state}

  defp arc(hand, v, radius, i, path, max_path, state, cast) do
    t0 = i * @step_s
    a = position(hand, v, t0)
    b = position(hand, v, t0 + @step_s)
    length = distance(a, b)
    d = direction(a, b, length)

    case cast.(a, d, length, state) do
      {nil, state} ->
        arc(hand, v, radius, i + 1, path + length, max_path, state, cast)

      {{target, micro}, state} ->
        {axis, sign, s} = entry(a, d, micro)
        plane = plane(micro, axis, sign)
        t = crossing(hand, v, axis, plane, t0 + s / length * @step_s)
        point = hand |> position(v, t) |> put_elem(axis, plane)
        {{:hit, t, rest(point, axis, sign, radius), target}, state}
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

  # 抛物线穿越命中面的精确时刻：水平轴线性；竖直轴取二次方程中最接近弦段估计的根。
  defp crossing(hand, v, axis, plane, _estimate) when axis != 1, do: (plane - elem(hand, axis)) / elem(v, axis)

  defp crossing({_, y, _}, {_, vy, _}, 1, plane, estimate) do
    disc = vy * vy + 2 * @gravity * (y - plane)

    if disc < 0,
      do: estimate,
      else: Enum.min_by([(vy - :math.sqrt(disc)) / @gravity, (vy + :math.sqrt(disc)) / @gravity], &abs(&1 - estimate))
  end

  defp rest(point, axis, sign, radius), do: put_elem(point, axis, elem(point, axis) - sign * radius)

  defp distance({ax, ay, az}, {bx, by, bz}), do: :math.sqrt((bx - ax) ** 2 + (by - ay) ** 2 + (bz - az) ** 2)
  defp direction({ax, ay, az}, {bx, by, bz}, l), do: {(bx - ax) / l, (by - ay) / l, (bz - az) / l}
  defp advance({x, y, z}, {dx, dy, dz}, s), do: {x + dx * s, y + dy * s, z + dz * s}

  @doc "形态的物理能量（J）：热内容 m·c·(T − T_amb) 加发光预算 glow_w·lifetime_s；成本与账共用。"
  def form_j(form, catalog, ambient),
    do: form["mass_kg"] * catalog.semblance.specific_heat * (form["temperature_k"] - ambient) + form["glow_w"] * form["lifetime_s"]

  @doc "投掷动能 ½·m·v²（J）。"
  def kinetic_j(mass, speed), do: 0.5 * mass * speed * speed

  @doc "由合法程序的形态参数与弹道结果建立记录。`launch` = %{origin, velocity, t0_us, flight_s, rest, contact}。"
  def new(caster, form, catalog, launch) do
    capacity = form["mass_kg"] * catalog.semblance.specific_heat
    {vx, vy, vz} = launch.velocity

    Map.merge(launch, %{
      caster: caster,
      shape: trunc(form["shape"]),
      radius_m: form["radius_m"],
      mass_kg: form["mass_kg"],
      capacity: capacity,
      temperature_k: form["temperature_k"],
      glow_w: form["glow_w"],
      lifetime_s: form["lifetime_s"],
      age_s: 0.0,
      kinetic_j: kinetic_j(form["mass_kg"], :math.sqrt(vx * vx + vy * vy + vz * vz))
    })
  end

  @doc "已落地（静止）；只有落地的拟态与接触节点换热。"
  def landed?(s), do: s.age_s >= s.flight_s - @epsilon

  @doc "寿命已到（发光预算同时耗尽）。"
  def expired?(s), do: s.age_s >= s.lifetime_s - @epsilon

  @doc "本段模拟时长不越过任何落点或寿命端点，使落地转换与发光账在端点上精确结算。"
  def cap(semblances, duration) do
    Enum.reduce(semblances, duration, fn s, dt ->
      dt = min(dt, s.lifetime_s - s.age_s)
      if landed?(s), do: dt, else: min(dt, s.flight_s - s.age_s)
    end)
  end

  @doc "剩余能量（J）：显热 + 飞行中动能 + 发光余量。"
  def stored_j(s, ambient), do: thermal_j(s, ambient) + s.kinetic_j + glow_j(s)
  @doc "显热 C·(T − T_amb)。"
  def thermal_j(s, ambient), do: s.capacity * (s.temperature_k - ambient)
  @doc "发光余量 glow_w·(lifetime − age)。"
  def glow_j(s), do: s.glow_w * max(s.lifetime_s - s.age_s, 0.0)

  @doc "总表面积（m²）：球 4πr²，立方体 24r²（半边 r）。"
  def surface(%{shape: 0, radius_m: r}), do: 4 * :math.pi() * r * r
  def surface(%{shape: 1, radius_m: r}), do: 24 * r * r

  @doc "包围立方体 {低角, 高角}（m）：中心 rest、半边 radius_m。"
  def box(%{rest: {x, y, z}, radius_m: r}), do: {{x - r, y - r, z - r}, {x + r, y + r, z + r}}

  @doc "接触候选宏格：包围立方体覆盖或贴面的全部宏格（热内核的种子与接触查找范围）。"
  def span(s) do
    {lo, hi} = box(s)
    [xs, ys, zs] = for i <- 0..2, do: floor(elem(lo, i) - @touch)..floor(elem(hi, i) + @touch)//1
    for x <- xs, y <- ys, z <- zs, do: {x, y, z}
  end

  @doc """
  与一个实占用盒 `{低角, 高角}` 的接触：`{面积 m², 法向轴}`，不接触为 nil。任一轴分离即不接触；贴面或重叠时取重叠最小的轴
  为法向（贴面时该轴重叠为 0），面积 = 其余两轴重叠 × 形状系数。
  """
  def contact(s, other) do
    {lo, hi} = cube = box(s)
    {blo, bhi} = other
    {depth, axis} = for(i <- 0..2, do: min(elem(hi, i), elem(bhi, i)) - max(elem(lo, i), elem(blo, i))) |> Enum.with_index() |> Enum.min()
    area = VoxelRegion.ThermalGeometry.overlap(cube, other, axis) * @footprint[s.shape]
    if depth >= -@touch and area > 0, do: {area, axis}
  end

  @doc "热内核外部节点元组；`contact` 为本段全部接触面积之和（接触面不对流）。"
  def node(s, conductivity, contact),
    do: {s.temperature_k, 1.0, 1.0, s.capacity, conductivity, 1.0e6, max(surface(s) - contact, 0.0), 0.0, 0.0, true}

  @doc "一条接触边导热 G = A / (r / k_s + d / k_o)（W/K）；任一导热率为 0 时不导热。"
  def conductance(s, conductivity, other_k, other_half, area),
    do: if(conductivity == 0 or other_k == 0, do: 0.0, else: area / (s.radius_m / conductivity + other_half / other_k))

  @doc """
  辐射项 {与全部接触节点互换的 εF·A_exp 合计, 对天空 ε(1 − F)·A_exp}；`contact` 为接触面积之和，为 0 时全部对天空。
  互换项由调用方按各接触面积比例分摊；ε 取热环境发射率。
  """
  def radiation(s, emissivity, contact) do
    if contact > 0 do
      exposed = max(surface(s) - contact, 0.0)
      f = @view_factor[s.shape]
      {emissivity * f * exposed, emissivity * (1 - f) * exposed}
    else
      {0.0, emissivity * surface(s)}
    end
  end

  @doc """
  一段内核演进后的记录与账：返回 `{记录, 光 J, 流出 J}`。流出 = C·(T_前 − T_后)（经接触传给世界与散到环境之和）；
  发光按 glow_w·min(dt, 余寿) 计光；到达落点时飞行动能转为内能。
  """
  def step(s, temperature, done) do
    exchanged = s.capacity * (s.temperature_k - temperature)
    light = s.glow_w * max(min(done, s.lifetime_s - s.age_s), 0.0)
    s = %{s | temperature_k: temperature, age_s: s.age_s + done}

    s =
      if s.kinetic_j > 0 and landed?(s),
        do: %{s | temperature_k: s.temperature_k + s.kinetic_j / s.capacity, kinetic_j: 0.0},
        else: s

    {s, light, exchanged}
  end
end
