defmodule VoxelRegion.World.Structures do
  @moduledoc """
  全局系统功能（魔法 v2 切片 4c）：World 持有的运行中结构——物理体、线上记录、持久化与每拍步进的编排。

  决策稿 `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md` §2、§4（Q4-3 终止记录、Q4-4 状态增量、Q4-5 每人 6 个、
  Q4-7 显式字段 map、Q4-8 热账按去向、Q4-9 整数拍号）；设计 TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`
  §5.1–5.5、§5.8、§5.9、§11.1–11.3、§12.1 更正 3。

  ## 真值与分工

  - 结构的储能、欠账与规则状态归纯值 `Magic.Structure`（整数 mJ / 1e-6）；本模块只编排：取读数、调用 `step/4` 与
    `respond/3`、执行它返回的请求、记账、产出线上记录。
  - 每个结构在 `thermal.structures` 里是一个条目 `%{structure: %Structure{}, body: 物理体, wire: 最近一次的动态字段}`：
    - 物理体（形状、三轴半尺寸、质量、锚、`ends_on_contact`、运动学弹道与接触格）施放时由程序与当时的世界求出，此后不变；
      几何规则在 `Magic.Semblance`。
    - `wire` 是最近一次出生或步进算出的线上动态字段（`Structure.wire/1` 加 World 判定的飞行位），只用于 Q4-4 的
      “步进前后分箱比较”与观察快照，不是“上次发送值”。
  - 热提交拍号 `thermal.commit_tick`（Q4-9）：有结构参与的热提交每完成一次 +1；结构的第 k 拍即拍号 `born_tick + k`。
    没有结构时拍号不推进也不出现（它的唯一读者是结构；无魔法的世界热状态因此与引入结构前逐位相同）。冷重启从持久化的
    拍号继续，不补算（设计 §5.9）；积压冻结时热提交不开始，结构随之冻结（§5.8）。

  ```mermaid
  flowchart LR
    C[World.Casting 结算] -->|new/4 + 物理体| E[thermal.structures]
    T[World.Thermal 热提交] -->|落地的热结构 = 受限外部节点| K[voxim_thermal]
    K -->|本拍净热| T
    T -->|settle：按 id 升序| S[Structures.tick/3]
    S -->|step/4 → respond/3| E
    S -->|沉积请求 → 有限热源 / 辐射账| T
    S -->|structures + structure_states| B[热事务 → PropertyBatch]
  ```

  ## 持久化（Q4-7）

  条目随每笔带 `thermal` 的事务落盘；写出前 `persisted_thermal/1` 把条目换成显式字段 map（`Structure.to_record/1` 与物理体、
  动态字段的普通 map），World 启动恢复后 `restore/1` 一次校验并换回运行值（`Structure.from_record/2`），同时核对
  `last_tick = commit_tick`（每次提交都步进全部结构，所以这是恢复时必须成立的不变量）。

  ## 沉积去向与保护区（设计 §5.5 释放形态、§12.1 更正 3、Q4-8）

  请求里的热（泄漏批量沉积、终止释放、动能）只能落进结构的接触格：施放时射线命中、落地后仍是同一未细分热节点、且施法者
  此刻对它可写（执行时复核持有者，`Access.writable?/3`）。否则（手边悬空、飞行中、接触格已变、他人保护区）全部计入灵炁
  辐射账，不写任何格。热份额按端口温度上限沉积：每格至多加热到 T_port，余下计入辐射账（§5.2）。

  ## 待设计确认（决策稿未覆盖，取最保守的可逆做法，§14 有记录）

  - 所在格温度：落地且有接触格时取接触格温度，否则取中心所在格（实占用格取其温度，空气取气候区温度）；
    泄漏沉积阈值用接触格热容，没有接触格时为 0（每拍沉积，热半落不进格即计入辐射）。
  - 邻居项的 P_leak 取邻居拍首的运行损耗 `Structure.running_loss_w/3`（与处理顺序无关）。
  - 邻近终止释放剂量：按 id 升序，本拍已终止结构的释放作用于其后处理的结构。
  - 规则触发在 4c 不设触发预算（切片 7），〈遇〉接触读数恒为 false（切片 5 接通），〈散〉一律记 live 6。
  - 飞行：弹道在施放时对当时世界求交（射程端点未命中时停在端点，有质量者继续下落属切片 5）；落地后才作为热节点，
    动能留在结构里直到终止释放（`settle_kinetic/1` 的接线属切片 5）。
  """
  require Logger
  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.{Access, Damage}
  alias VoxelRegion.Magic.{Catalog, Semblance, Structure}
  alias VoxelRegion.Magic.Program.Group
  import VoxelRegion.World.Canonical

  @tick_s Structure.tick_ms() / 1000
  # 飞行终点对齐容差（模拟秒）：拍号 × 拍长与施放时求出的落地时刻比较。
  @epsilon 1.0e-9
  # 空间网格边长（m）：每拍开始建一次，邻居查找只看相邻 27 格（设计 §5.3 第 1 步“8 m 空间网格”）。
  @grid_m 8.0
  # 账目科目（整数 mJ；舍入残差为浮点 mJ），决策稿 §4.2 按去向记（Q4-8）。
  @accounts [
    :structure_created_mj,
    :structure_heat_in_mj,
    :structure_light_mj,
    :anima_radiated_mj,
    :structure_leak_heat_mj,
    :structure_released_mj
  ]

  @doc "账目科目（整数 mJ），观察快照与热提交日志按这张表列出；另有浮点 `structure_rounding_mj`。"
  def accounts, do: @accounts

  @doc "运行中结构（id => 条目）；无热环境时为空。"
  def all(%{thermal: nil}), do: %{}
  def all(%{thermal: thermal}), do: Map.get(thermal, :structures, %{})

  @doc "热提交拍号（Q4-9）：最近一次完成的热提交；没有提交过为 0。"
  def commit_tick(%{thermal: thermal}), do: Map.get(thermal, :commit_tick, 0)

  @doc "某施法者名下运行中的结构数（Q4-5：切片 4–6 只判每人上限，由 `World.Casting` 在施放检查里调用）。"
  def count(state, cid), do: Enum.count(all(state), fn {_, e} -> e.body.caster == cid end)

  @doc "全部结构的存量（mJ）：账目闭合式的 Δstored 项。"
  def stored_mj(structures),
    do:
      Enum.sum(
        for {_, %{structure: s}} <- structures,
            do: s.e_op_mj + s.e_th_mj + s.kinetic_mj + s.pending_leak_mj
      )

  # ---------------------------------------------------------------------------
  # 物理体（施放时求出）
  # ---------------------------------------------------------------------------

  @doc """
  施放时的发射：按形成锚求出发点并按〈投〉初速求弹道（`Magic.Semblance.trace/8`，对当时世界求交）。
  〈握〉自手边出发；〈附〉沿眼睛射线命中 `target` 的格面，中心外移该轴半尺寸。返回 `{:ok, launch, state}`，〈附〉的射线
  已不再命中 `target` 时 `{:error, :stale_target, state}`。
  """
  def launch(state, actor, request, %Group{} = group, target, %Catalog{} = catalog) do
    {dx, dy, dz} = direction = request.direction
    {ex, ey, ez} = eye = actor.eye
    shape = shape_params(group)
    half = half(shape)
    massless = shape["mass_g"] == nil

    velocity =
      case Enum.find(group.motion, &(&1.id == "act.throw")) do
        %{params: %{"speed_mmps" => v}} -> {dx * v / 1000, dy * v / 1000, dz * v / 1000}
        nil -> {0.0, 0.0, 0.0}
      end

    case group.form_anchor.id do
      "anchor.hand" ->
        hand = {ex + dx * hand_reach(), ey + dy * hand_reach(), ez + dz * hand_reach()}
        {trace, state} = Semblance.trace(eye, hand, velocity, half, catalog.limits.range_m, state, &cast/4, massless)
        {:ok, launch(trace, hand, velocity, massless), state}

      "anchor.surface" ->
        far = {ex + dx * catalog.limits.range_m, ey + dy * catalog.limits.range_m, ez + dz * catalog.limits.range_m}

        case Semblance.segment(eye, far, half, state, &cast/4) do
          {{_fraction, point, hit}, state} ->
            if Damage.key(hit) == Damage.key(target) do
              # 〈附〉上的〈投〉自格面点抛出（待设计确认）；无〈投〉时静止在格面上，接触即目标格。
              {trace, state} = Semblance.trace(point, point, velocity, half, catalog.limits.range_m, state, &cast/4, massless)

              launch =
                case trace do
                  {:free, _} -> %{origin: point, velocity: velocity, flight_s: 0.0, rest: point, contact: contact(hit)}
                  trace -> launch(trace, point, velocity, massless)
                end

              {:ok, launch, state}
            else
              {:error, :stale_target, state}
            end

          {nil, state} ->
            {:error, :stale_target, state}
        end
    end
    |> then(fn
      {:ok, launch, state} -> {:ok, Map.put(launch, :direction, direction), state}
      error -> error
    end)
  end

  @doc """
  弹道求交结果 → 运动字段 `%{origin, velocity, flight_s, rest, contact}`（纯函数；线上记录与样本生成器共用）：
  `{:free, 点}` 静止在该点；`{:hit, t, 落点, 目标}` 在 t 秒落到落点并以目标为接触格；`{:miss, t}` 飞到射程端点后停在端点。
  """
  def launch({:free, point}, _from, _velocity, _massless),
    do: %{origin: point, velocity: {0.0, 0.0, 0.0}, flight_s: 0.0, rest: point, contact: nil}

  def launch({:hit, t, rest, target}, from, velocity, _massless),
    do: %{origin: from, velocity: velocity, flight_s: t, rest: rest, contact: contact(target)}

  def launch({:miss, t}, from, velocity, massless),
    do: %{origin: from, velocity: velocity, flight_s: t, rest: Semblance.position(from, velocity, t, massless), contact: nil}

  # 弹道命中的接触格：只认未细分的宏格（落点、释放与热接触都按宏格；细分构件按 g=1 节点身份）。
  defp contact(target) do
    node = if target.granularity == 2, do: %{target | granularity: 1}, else: target
    %{target: target, key: VoxelRegion.ThermalGeometry.key(node), cell: Damage.macro(target)}
  end

  @doc "手边点到眼睛的距离（m），与 `World.Casting` 的形成位置同一常数。"
  def hand_reach, do: 0.5

  @doc """
  由结构组、目录与发射求物理体（纯函数）：形状枚举序号、三轴半尺寸、`size1_m` 与 `size2_mm`/`size3_mm`、质量、无质量位、
  `ends_on_contact`（有一条读〈遇〉且响应〈散〉的规则，设计 §11.1 v2.11 W5）、耦合位名、锚类型，以及运动字段与 `t0_us`。
  """
  def body(%Group{} = group, %Catalog{} = catalog, caster, launch, t0_us) do
    shape = shape_params(group)

    %{
      caster: caster,
      shape: shape_index(catalog, shape["shape"]),
      half: half(shape),
      size1_m: shape["size1_mm"] / 1000,
      size2_mm: shape["size2_mm"],
      size3_mm: shape["size3_mm"],
      mass_g: shape["mass_g"],
      massless: shape["mass_g"] == nil,
      ends_on_contact:
        Enum.any?(group.rules, fn rule ->
          Enum.any?(rule.readings, &(&1.id == "cond.contact")) and
            Enum.any?(rule.responses, &(&1.id == "resp.release"))
        end),
      coupling:
        for(
          {name, id} <- [thermal: "cpl.thermal", glow: "cpl.glow", capacity: "cpl.capacity", disrupt: "int.disrupt"],
          Enum.any?(group.quality, &(&1.id == id)),
          do: name
        ),
      anchor_type: Map.fetch!(%{"anchor.hand" => 0, "anchor.surface" => 1}, group.form_anchor.id),
      origin: launch.origin,
      velocity: launch.velocity,
      t0_us: t0_us,
      flight_s: launch.flight_s,
      rest: launch.rest,
      contact: launch.contact
    }
  end

  defp shape_params(group), do: Enum.find(group.shape, &(&1.id == "form.semblance")).params

  defp shape_index(catalog, name) do
    {_, form} = Enum.find(catalog.symbols, fn {_, s} -> s.id == "form.semblance" end)
    %{enum: names} = Enum.find(form.params, &(&1.name == "shape"))
    {index, _} = Enum.find(names, fn {_, n} -> n == name end)
    index
  end

  # 三轴半尺寸（m）：球 {r, r, r}；块与板为 size1–3 半边长（板的第三轴为半厚，设计 §2.3、`Magic.Cost` 同一几何）。
  defp half(%{"shape" => "sphere", "size1_mm" => r}), do: {r / 1000, r / 1000, r / 1000}
  defp half(%{"size1_mm" => a, "size2_mm" => b, "size3_mm" => c}), do: {a / 1000, b / 1000, c / 1000}

  @doc "新结构的条目：结构值、物理体与出生时的动态字段（`Structure.wire/1` 的出生子句，加飞行位）。"
  def entry(%Structure{} = s, body, quote) do
    %{structure: s, body: body, wire: with_flight(Structure.wire({s, quote}), flying?(body, s, s.born_tick))}
  end

  # 拍号 `tick` 结束时是否仍在飞行：自出生起的模拟时长 < 落地时刻（静止结构 flight_s = 0）。
  defp flying?(body, s, tick), do: (tick - s.born_tick) * @tick_s < body.flight_s - @epsilon

  defp with_flight(wire, true), do: %{wire | status: wire.status ++ [:flying]}
  defp with_flight(wire, false), do: wire

  # ---------------------------------------------------------------------------
  # 线上记录（决策稿 §3.1、§3.3；编码 `MmoContracts.Voxel.Codec.encode_structures/1`）
  # ---------------------------------------------------------------------------

  @doc """
  一条完整结构记录（`Codec.encode_structures/1` 的输入形状）：物理体的静态与运动字段 + 动态字段 `wire` + `live`。
  状态位按线上位序排列；P1 的 `proto_id` 为 0、`anchor_ref` 全 0（格面沿用位置字段，设计 §11.1）。
  """
  def record(body, wire, live) do
    %{
      live: live,
      caster: body.caster,
      shape: body.shape,
      ends_on_contact: body.ends_on_contact,
      massless: body.massless,
      size1_m: body.size1_m,
      size2_mm: body.size2_mm,
      size3_mm: body.size3_mm,
      proto_id: 0,
      coupling: body.coupling,
      anchor_type: body.anchor_type,
      anchor_ref: <<0::96>>,
      origin: body.origin,
      velocity: body.velocity,
      t0_us: body.t0_us,
      flight_s: body.flight_s,
      rest: body.rest,
      load: wire.load,
      coherence: wire.coherence,
      status: Enum.filter(Codec.structure_status_bits(), &(&1 in wire.status)),
      failed_segments: wire.failed_segments,
      temperature_k: wire.temperature_k,
      glow_w: wire.glow_w
    }
  end

  @doc "全部运行中结构的存在记录（live 1），观察快照用。"
  def records(state), do: Map.new(all(state), fn {id, e} -> {id, record(e.body, e.wire, 1)} end)

  # Q4-4 固定分箱（决策稿 §3.3）：装载、相干各 ⌊v·32⌋（v 取线上 u8 / 255）；温度 ⌊T / 25 K⌋；发光 0 单列，
  # 其余 ⌊ln(glow) / ln 1.1⌋；状态位与失效段直接比较。
  defp bins(wire) do
    {div(wire.load * 32, 255), div(wire.coherence * 32, 255), floor(wire.temperature_k / 25),
     if(wire.glow_w == 0, do: :dark, else: floor(:math.log(wire.glow_w) / :math.log(1.1))),
     Enum.sort(wire.status), wire.failed_segments}
  end

  # ---------------------------------------------------------------------------
  # 持久化（Q4-7）
  # ---------------------------------------------------------------------------

  @doc "写出前的 `thermal`：结构条目换成显式字段 map（`Log` 的事务元数据与分页全局行共用）。"
  def persisted_thermal(%{structures: structures} = thermal),
    do: %{thermal | structures: Map.new(structures, fn {id, e} -> {id, to_record(e)} end)}

  def persisted_thermal(thermal), do: thermal

  defp to_record(%{structure: s, body: body, wire: wire}),
    do: %{structure: Structure.to_record(s), body: body, wire: wire}

  @doc """
  World 恢复后一次校验持久化的结构记录并换成运行值（持久化加载是信任边界，AGENTS §2.2-6）。记录损坏、物理体或动态字段
  不合法、或 `last_tick ≠ commit_tick` 时抛出带原因的错误：恢复出一个与提交拍号不一致的结构就不能“从下一拍继续”。
  """
  def restore(%{thermal: %{structures: records} = thermal, magic: magic} = state) do
    commit_tick = Map.get(thermal, :commit_tick, 0)

    structures =
      Map.new(records, fn {id, record} ->
        case from_record(id, record, magic, commit_tick) do
          {:ok, entry} -> {id, entry}
          {:error, reason} -> raise "voxel_structure_restore_failed id=#{inspect(id)} reason=#{inspect(reason)}"
        end
      end)

    Logger.info("voxel_structure_restored structures=#{map_size(structures)} commit_tick=#{commit_tick}")
    %{state | thermal: %{thermal | structures: structures}}
  end

  def restore(state), do: state

  defp from_record(id, %{structure: s, body: body, wire: wire} = record, magic, commit_tick)
       when map_size(record) == 3 do
    with {:ok, %Structure{id: ^id, last_tick: ^commit_tick} = s} <- Structure.from_record(s, magic),
         true <- body?(body) or {:error, :body},
         true <- wire?(wire) or {:error, :wire} do
      {:ok, %{structure: s, body: body, wire: wire}}
    else
      {:ok, %Structure{}} -> {:error, :tick_or_id}
      {:error, _} = error -> error
    end
  end

  defp from_record(_id, _record, _magic, _tick), do: {:error, :record}

  @body_keys ~w(caster shape half size1_m size2_mm size3_mm mass_g massless ends_on_contact coupling anchor_type
               origin velocity t0_us flight_s rest contact)a

  defp body?(%{shape: shape, half: {a, b, c}, flight_s: flight, caster: caster} = body) do
    Enum.sort(Map.keys(body)) == Enum.sort(@body_keys) and shape in 0..2 and Enum.all?([a, b, c], &(is_number(&1) and &1 > 0)) and
      is_number(flight) and flight >= 0 and is_integer(caster) and Enum.all?([body.origin, body.rest, body.velocity], &vector?/1) and
      (body.contact == nil or match?(%{target: %{granularity: _}, key: _, cell: {_, _, _}}, body.contact))
  end

  defp body?(_), do: false

  defp vector?({x, y, z}), do: is_number(x) and is_number(y) and is_number(z)
  defp vector?(_), do: false

  defp wire?(%{load: l, coherence: c, status: status, failed_segments: f, temperature_k: t, glow_w: g} = w)
       when map_size(w) == 6,
       do: l in 0..255 and c in 0..255 and is_list(status) and f in 0..255 and is_number(t) and is_number(g)

  defp wire?(_), do: false

  # ---------------------------------------------------------------------------
  # 热内核外部节点（`World.Thermal` 每次内核调用前取）
  # ---------------------------------------------------------------------------

  @doc """
  本次热提交作为内核外部节点的结构（按 id 升序）：带〈热〉（C_th 非空）且在本拍开始时已落地。飞行中的结构不进热内核
  （设计 §5.3 C1-15 跳过第 0、2、11 步）。
  """
  def heat_nodes(state) do
    ticks = commit_tick(state)

    all(state)
    |> Enum.filter(fn {_, %{structure: s, body: body}} -> s.c_th_j_per_k != nil and not flying?(body, s, ticks) end)
    |> Enum.sort()
  end

  @doc """
  结构节点在本次内核调用时的端口温度 T_port = T_ref + (E_th + 本拍已累计净热) / C_th（决策稿 §4.1）与限流参数
  `{Φ_cap, t_lo, t_hi}`（设计 §5.3.1：t_lo = T_ref（P1 只有热端口），t_hi = min(T_ref + (E_cap − E_op)/C_th, T_chk)）。
  """
  def port(%Structure{} = s, heat_j, %Catalog{runtime: rt}) do
    temperature = s.t_ref_k + (s.e_th_mj / 1000 + heat_j) / s.c_th_j_per_k
    t_hi = min(s.t_ref_k + (s.e_cap_mj - s.e_op_mj) / 1000 / s.c_th_j_per_k, rt.thermal_check_temperature_k * 1.0)
    {temperature, {s.phi_cap_w * 1.0, s.t_ref_k * 1.0, t_hi * 1.0}}
  end

  # ---------------------------------------------------------------------------
  # 每拍步进（热提交末，`World.Thermal.settle_run/2` 调用）
  # ---------------------------------------------------------------------------

  @doc """
  热提交拍 `tick`（= `commit_tick + 1`）的结构步进：按 id 升序对每个运行中结构取读数、调用 `Structure.step/4`，对触发的
  〈散〉调用 `respond/3`，执行沉积请求并记账；终止的结构移除并产出终止记录（live 2–6），其余按 Q4-4 分箱比较决定是否
  发状态增量。`heat` 是本拍内核给各结构节点的净热（J，`World.Thermal` 按调用累计）。

  返回 `{state, extra}`，`extra` 是随本次热事务下发的 `%{structures: 删除或终止记录, structure_states: 完整记录}`
  （没有变化的键省略）。调用方负责把 `thermal.commit_tick` 置为 `tick`。
  """
  def tick(state, tick, heat) do
    structures = all(state)

    if structures == %{} do
      {state, %{}}
    else
      started = System.monotonic_time(:microsecond)
      catalog = state.magic
      ordered = Enum.sort(structures)
      neighbors = neighbor_index(ordered, tick, catalog)

      acc = %{state: state, ended: [], records: %{}, states: %{}, step_us: [], rounding: 0.0}

      acc =
        Enum.reduce(ordered, acc, fn {id, entry}, acc ->
          step_started = System.monotonic_time(:microsecond)
          acc = step_one(acc, id, entry, tick, Map.get(heat, id, 0.0), neighbors, catalog)
          %{acc | step_us: [System.monotonic_time(:microsecond) - step_started | acc.step_us]}
        end)

      state = acc.state
      ended = length(acc.ended)

      Logger.info(
        "voxel_structure_tick tick=#{tick} structures=#{map_size(structures)} awake_nodes=#{map_size(heat)} " <>
          "step_us_total=#{Enum.sum(acc.step_us)} step_us_max=#{Enum.max(acc.step_us)} ended=#{ended} " <>
          "deltas=#{map_size(acc.states)} rounding_mj=#{acc.rounding} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
      )

      extra =
        [structures: acc.records, structure_states: acc.states]
        |> Enum.reject(fn {_, m} -> m == %{} end)
        |> Map.new()

      {state, extra}
    end
  end

  defp step_one(acc, id, entry, tick, heat_j, neighbors, catalog) do
    %{structure: s, body: body} = entry
    state = acc.state
    site = site(state, entry, tick)

    inputs = %{
      net_heat_j: heat_j,
      feed_w: 0,
      temperature_k: site.temperature_k,
      cell_heat_capacity_j_per_k: site.cell_c,
      embedded: site.embedded,
      neighbors: neighbors_of(neighbors, id, site.position, catalog),
      fields: [],
      release_doses: release_doses(acc.ended, site.position, catalog),
      contact: false
    }

    {stepped, out} = Structure.step(s, inputs, tick, catalog)

    # 第 12 步之后：P1 的响应只有〈散〉，4c 不设触发预算（切片 7），按优先级执行第一个；接触读数尚未接通（切片 5），
    # 所以由〈散〉终止一律是非接触读数触发（live 6，用户 Q4-W3）。
    {final, responded} =
      case for(%{responses: responses} <- out.triggered, glyph <- responses, glyph.id == "resp.release", do: glyph) do
        [release | _] when stepped.status == :running ->
          {ended, response_out} = Structure.respond(stepped, release, catalog)
          {ended, response_out}

        _ ->
          {stepped, nil}
      end

    requests = out.requests ++ if(responded, do: responded.requests, else: [])
    {state, deposit} = execute(state, site, requests)
    ledgers = [out.ledger | if(responded, do: [responded.ledger], else: [])]
    state = account(state, ledgers, deposit)
    rounding = out.ledger.heat_rounding_mj
    wire = with_flight(Structure.wire({stepped, out}), flying?(body, stepped, tick))

    case final.status do
      :running ->
        states = if bins(wire) != bins(entry.wire), do: Map.put(acc.states, id, record(body, wire, 1)), else: acc.states
        state = put_entry(state, id, %{entry | structure: final, wire: wire})
        %{acc | state: state, states: states, rounding: acc.rounding + rounding}

      {:terminated, type} ->
        # 终止类型即线上事件（Codec 唯一定义编号）；〈遇〉触发的〈散〉（live 2）在切片 5 接通后由投射物提交点产生。
        live = Codec.structure_end_live(type)
        released_mj = Enum.sum(for {:terminated, _, %{released_mj: mj}} <- out.events ++ if(responded, do: responded.events, else: []), do: mj)
        state = %{state | thermal: Map.update!(state.thermal, :structures, &Map.delete(&1, id))}

        Logger.info(
          "voxel_structure_end seq=#{state.seq + 1} sid=#{inspect(id)} cid=#{body.caster} live=#{live} type=#{type} tick=#{tick} " <>
            "released_mj=#{released_mj} heat_mj=#{deposit.heat_mj} radiation_mj=#{deposit.radiation_mj} " <>
            "thermal_mj=#{deposit.thermal_mj} cell=#{inspect(site.deposit && Damage.macro(site.deposit))} protected=#{site.protected}"
        )

        %{
          acc
          | state: state,
            records: Map.put(acc.records, id, record(body, wire, live)),
            ended: [{site.position, released_mj} | acc.ended],
            rounding: acc.rounding + rounding
        }
    end
  end

  defp put_entry(state, id, entry),
    do: %{state | thermal: Map.update!(state.thermal, :structures, &Map.put(&1, id, entry))}

  # 本拍读数的位置：落地后取落点；飞行中取拍首时刻的弹道位置。沉积格（接触格）只在落地后存在，并按执行时复核。
  defp site(state, %{structure: s, body: body}, tick) do
    elapsed = (tick - 1 - s.born_tick) * @tick_s
    landed = elapsed >= body.flight_s - @epsilon
    position = if landed, do: body.rest, else: Semblance.position(body.origin, body.velocity, elapsed, body.massless)
    cell = Semblance.macro(position)
    {own, state} = target_at(micro(position), state)
    {deposit, protected, state} = if landed, do: release_cell(state, body), else: {nil, false, state}

    temperature =
      cond do
        deposit -> temperature(state, deposit)
        own != nil and heat_node?(state, own) -> temperature(state, own)
        true -> ambient_at(state, cell)
      end

    cell_c = if deposit, do: heat_capacity(state, deposit), else: 0.0

    %{
      position: position,
      deposit: deposit,
      protected: protected,
      temperature_k: temperature * 1.0,
      cell_c: cell_c * 1.0,
      embedded: own != nil
    }
  end

  defp micro({x, y, z}), do: {floor(x * 8), floor(y * 8), floor(z * 8)}

  @doc """
  释放格（设计 §5.5、§12.1 更正 3）：物理体的接触格仍是同一未细分热节点、且施法者此刻对它可写时返回该格目标；
  否则 `nil`。返回 `{目标 | nil, 是否因他人保护区被拒, state}`。
  """
  def release_cell(state, %{contact: %{target: %{granularity: 0} = target}, caster: caster}) do
    {current, state} = target_at(target.micro, state)

    cond do
      not (current != nil and same_target?(current, target) and heat_node?(state, current)) -> {nil, false, state}
      Access.writable?({:character, caster}, state.protection, [Damage.macro(current)]) -> {current, false, state}
      true -> {nil, true, state}
    end
  end

  def release_cell(state, _body), do: {nil, false, state}

  defp temperature(state, target),
    do: Map.get(property_state(state, target), :temperature_kelvin, ambient_at(state, Damage.macro(target)))

  defp heat_capacity(state, target),
    do: Map.get(state.properties.materials[target.material], "heat_capacity_per_macro", 0.0)

  # 执行沉积请求（设计 §5.5 释放形态）：返回 {state, %{leak_mj, heat_mj, thermal_mj, radiation_mj}}，按去向分账。
  defp execute(state, site, requests) do
    zero = %{leak_mj: 0, heat_mj: 0, thermal_mj: 0, radiation_mj: 0}

    Enum.reduce(requests, {state, zero}, fn
      {:deposit_heat, mj, cause}, {state, d} ->
        if site.deposit do
          key = if cause == :leak, do: :leak_mj, else: :heat_mj
          {deposit(state, site.deposit, mj), Map.update!(d, key, &(&1 + mj))}
        else
          {state, Map.update!(d, :radiation_mj, &(&1 + mj))}
        end

      {:release_thermal, mj, port}, {state, d} ->
        into =
          if site.deposit && mj > 0,
            do: min(mj, max(0, trunc(site.cell_c * (port - site.temperature_k) * 1000))),
            else: 0

        {deposit(state, site.deposit, into), %{d | thermal_mj: d.thermal_mj + into, radiation_mj: d.radiation_mj + mj - into}}
    end)
  end

  defp deposit(state, _target, 0), do: state

  defp deposit(state, target, mj),
    do: %{state | thermal: VoxelRegion.World.Thermal.deposit_heat(%{state.thermal | active: true}, target, mj / 1000)}

  # 按去向记账（Q4-8，整数 mJ）：净热、发光、灵炁辐射（泄漏与释放的辐射半、活动能、落不进格的热），
  # 沉积进格的泄漏热与终止释放（运转储能热半 + 热份额 + 动能）。
  defp account(state, ledgers, deposit) do
    sum = fn key -> Enum.sum(for l <- ledgers, do: Map.get(l.out, key, 0)) end
    heat_in = Enum.sum(for l <- ledgers, do: l.in.heat_mj)
    rounding = Enum.sum(for l <- ledgers, do: l.heat_rounding_mj)

    radiated = sum.(:leak_radiation_mj) + sum.(:release_radiation_mj) + sum.(:activity_mj) + deposit.radiation_mj

    thermal =
      Enum.reduce(
        [
          structure_heat_in_mj: heat_in,
          structure_light_mj: sum.(:light_mj),
          anima_radiated_mj: radiated,
          structure_leak_heat_mj: deposit.leak_mj,
          structure_released_mj: deposit.heat_mj + deposit.thermal_mj,
          structure_rounding_mj: rounding
        ],
        state.thermal,
        fn {key, value}, thermal -> Map.update(thermal, key, value, &(&1 + value)) end
      )

    %{state | thermal: thermal}
  end

  # 邻居（设计 §5.3 第 1 步、§5.3.2）：拍首建 8 m 网格；P_leak 取邻居拍首的运行损耗（待设计确认，见 moduledoc）。
  defp neighbor_index(ordered, tick, catalog) do
    for {id, %{structure: s, body: body}} <- ordered, into: %{} do
      elapsed = (tick - 1 - s.born_tick) * @tick_s
      position = if elapsed >= body.flight_s - @epsilon, do: body.rest, else: Semblance.position(body.origin, body.velocity, elapsed, body.massless)
      leak_w = Structure.running_loss_w(s, s.e_op_mj + abs(s.e_th_mj), catalog)
      {id, %{position: position, leak_w: leak_w, bucket: bucket(position)}}
    end
  end

  defp bucket({x, y, z}), do: {floor(x / @grid_m), floor(y / @grid_m), floor(z / @grid_m)}

  defp neighbors_of(index, id, position, %Catalog{runtime: rt}) do
    {bx, by, bz} = bucket(position)
    r = rt.env_neighbor_radius_m

    for({other, n} <- index, other != id, {nx, ny, nz} = n.bucket, abs(nx - bx) <= 1 and abs(ny - by) <= 1 and abs(nz - bz) <= 1,
        d = distance(position, n.position), d < r, do: {other, %{leak_w: n.leak_w, distance_m: d}})
    |> Enum.sort_by(fn {other, n} -> {-n.leak_w * (1 - n.distance_m / r), other} end)
    |> Enum.take(rt.env_neighbor_max)
    |> Enum.map(&elem(&1, 1))
  end

  defp release_doses(ended, position, %Catalog{runtime: rt}) do
    for {at, released_mj} <- ended, d = distance(position, at), d < rt.release_dose_radius_m,
        do: %{energy_mj: released_mj, distance_m: d}
  end

  defp distance({ax, ay, az}, {bx, by, bz}), do: :math.sqrt((bx - ax) ** 2 + (by - ay) ** 2 + (bz - az) ** 2)

  # 物理体弹道的 canonical 求交：与工具同一 Amanatides–Woo 射线，命中返回目标与进入的微格。
  defp cast(origin, direction, length, state) do
    at = fn micro, s ->
      {target, s} = target_at(micro, s)
      {target && {target, micro}, s}
    end

    case Damage.raycast(origin, direction, length, state, at) do
      {:ok, hit, state} -> {hit, state}
      {:error, :no_target, state} -> {nil, state}
    end
  end
end
