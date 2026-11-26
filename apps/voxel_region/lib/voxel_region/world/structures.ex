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
  - 规则触发不设触发预算（切片 7）。〈散〉的线上事件按触发它的规则：读〈遇〉的记 live 2，其余记 live 6（Q4-W3）。

  ## 飞行（切片 5，决策稿 §5、§14 用户答复）

  - 带初速的结构出生即在飞行（物理体 `flight = %{age_s, source}`），由 `World.Projectiles` 按墙钟 50 ms 拍逐段推进
    （设计 §5.8）；施放时的弹道求交只作线上记录里的预测。无质量者直线匀速、无射程终点；有质量者按弹道直到落地或接触。
  - 飞行中照常在热拍步进（不进热内核），位置取已推进到的飞行时长；在飞行中终止（衰竭、〈满〉〈时〉触发等）就地释放，
    终态快照的落点即该位置，释放落不进格、计入辐射账。
  - 投射物提交点（`land/5`、`hit_body/5`、`deliver/3`、`dissipate/3`）：动能经 `settle_kinetic/1` 在命中格沉积，〈遇〉按
    `last_tick + 1` 求值（含读数丢失），〈散〉在同一提交点 `respond/3` 结算；人物命中冻结交付，等 Player 接纳后终止。
  - **待设计确认**：Q5-3 命中时不补记不足一拍的维持费（差额随释放入账）；人物命中读数丢失时停在命中点而不是穿过；
    离开 World 能读出 canonical 的范围时以 live 3 散解（`World.Projectiles` moduledoc）。
  """
  require Logger
  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.{Access, Damage}
  alias VoxelRegion.Magic.{Catalog, Semblance, Structure}
  alias VoxelRegion.Magic.Program.Group
  alias VoxelRegion.World.Thermal
  import VoxelRegion.World.Canonical

  # 空间网格边长（m）：每拍开始建一次，邻居查找只看相邻 27 格（设计 §5.3 第 1 步“8 m 空间网格”）。
  @grid_m 8.0
  # 账目科目（整数 mJ；舍入残差为浮点 mJ），决策稿 §4.2 按去向记（Q4-8）。
  # 切片 5 加 `structure_body_mj`：人物命中时进入目标组织的能量（Q5-2），按去向与进格的释放分列。
  @accounts [
    :structure_created_mj,
    :structure_heat_in_mj,
    :structure_light_mj,
    :anima_radiated_mj,
    :structure_leak_heat_mj,
    :structure_released_mj,
    :structure_body_mj
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
  `{:free, 点}` 静止在该点；`{:hit, t, 落点, 目标}` 在 t 秒落到落点并以目标为接触格；`{:miss, t}` 射程窗口内未命中，
  落点取窗口端点。

  切片 5 起，带初速且未在眼 → 手段被挡住（`flight_s > 0`）的结构由 `World.Projectiles` 按墙钟逐段飞行（设计 §5.8），
  这里的 `flight_s`/`rest` 只是施放时对当时世界、在射程窗口内的**预测**（线上记录的飞行字段，客户端在飞行位置位时
  不按它截断，见 `body/5`）；真实终点由飞行驱动在接触、衰竭或离开可读范围时写回。
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

  飞行（切片 5）：带初速且 `flight_s > 0` 的发射出生即在飞行，`flight = %{age_s: 0.0, source: nil}`（`age_s` 是飞行驱动
  已推进到的墙钟飞行时长；`source` 是人物采样的施法者身份，由 `sampled/2` 填入）。飞行中没有接触格（接触在飞行驱动命中时
  才确定），其余为 `flight = nil`。
  """
  def body(%Group{} = group, %Catalog{} = catalog, caster, launch, t0_us) do
    shape = shape_params(group)
    flying = launch.velocity != {0.0, 0.0, 0.0} and launch.flight_s > 0

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
      contact: if(flying, do: nil, else: launch.contact),
      flight: if(flying, do: %{age_s: 0.0, source: nil})
    }
  end

  @doc """
  人物采样的来源（决策稿 Q5-4：只对 `ends_on_contact` 结构；沿 v1 只有 Player 形状的施法者——带 `life_generation`——才采样，
  NPC 与测试施法者不采样）：飞行中的物理体记下施法者的 cid、会话身份、生命代次与施放时位置，采样后端据此找施法者的当前
  owner 并判战斗范围（`Harm`，设计 §12.1 的 World 侧判定点）。
  """
  def sampled(%{flight: %{} = flight, ends_on_contact: true} = body, %{life_generation: _} = actor),
    do: %{body | flight: %{flight | source: Map.take(actor, [:cid, :identity, :life_generation, :position])}}

  def sampled(body, _actor), do: body

  @doc "物理体此刻的中心：飞行中取已推进到的飞行时长处的弹道位置，否则取落点。"
  def position(%{flight: %{age_s: age}} = body), do: Semblance.position(body.origin, body.velocity, age, body.massless)
  def position(%{rest: rest}), do: rest

  @doc "飞行中的结构（不含已冻结人物命中交付的），按 id 升序。"
  def flights(state),
    do: all(state) |> Enum.filter(fn {_, e} -> e.body.flight != nil and not Map.has_key?(e, :delivery) end) |> Enum.sort()

  @doc "已冻结、等待目标 Player 接纳的人物命中交付，按 id 升序。"
  def deliveries(state), do: all(state) |> Enum.filter(fn {_, e} -> Map.has_key?(e, :delivery) end) |> Enum.sort()

  @doc "飞行驱动推进到墙钟飞行时长 `age_s` 且这段无接触：只改内存里的飞行进度，随下一笔带 `thermal` 的事务落盘。"
  def advance(state, id, age_s),
    do: update_in(state.thermal.structures[id].body.flight, &%{&1 | age_s: age_s})

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
    %{structure: s, body: body, wire: with_flight(Structure.wire({s, quote}), body.flight != nil)}
  end

  defp with_flight(wire, true), do: %{wire | status: Enum.uniq(wire.status ++ [:flying])}
  defp with_flight(wire, false), do: %{wire | status: wire.status -- [:flying]}

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

  defp to_record(%{structure: s} = entry), do: %{entry | structure: Structure.to_record(s)}

  @doc """
  World 恢复后一次校验持久化的结构记录并换成运行值（持久化加载是信任边界，AGENTS §2.2-6）。记录损坏、物理体或动态字段
  不合法、或 `last_tick ≠ commit_tick` 时抛出带原因的错误：恢复出一个与提交拍号不一致的结构就不能“从下一拍继续”。
  已冻结人物命中交付的结构（条目带 `delivery`）不再步进，拍号停在冻结时，不按这条核对。
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
       when map_size(record) == 3 or (map_size(record) == 4 and is_map_key(record, :delivery)) do
    delivery = Map.get(record, :delivery)

    with {:ok, %Structure{id: ^id} = s} <- Structure.from_record(s, magic),
         true <- s.last_tick == commit_tick or delivery != nil or {:error, :tick_or_id},
         true <- body?(body) or {:error, :body},
         true <- wire?(wire) or {:error, :wire},
         true <- delivery == nil or delivery?(delivery) or {:error, :delivery} do
      {:ok, Map.put(record, :structure, s)}
    else
      {:ok, %Structure{}} -> {:error, :tick_or_id}
      {:error, _} = error -> error
    end
  end

  defp from_record(_id, _record, _magic, _tick), do: {:error, :record}

  @body_keys ~w(caster shape half size1_m size2_mm size3_mm mass_g massless ends_on_contact coupling anchor_type
               origin velocity t0_us flight_s rest contact flight)a

  defp body?(%{shape: shape, half: {a, b, c}, flight_s: flight, caster: caster} = body) do
    Enum.sort(Map.keys(body)) == Enum.sort(@body_keys) and shape in 0..2 and Enum.all?([a, b, c], &(is_number(&1) and &1 > 0)) and
      is_number(flight) and flight >= 0 and is_integer(caster) and Enum.all?([body.origin, body.rest, body.velocity], &vector?/1) and
      (body.contact == nil or match?(%{target: %{granularity: _}, key: _, cell: {_, _, _}}, body.contact)) and
      flight?(body.flight)
  end

  defp body?(_), do: false

  defp flight?(nil), do: true
  defp flight?(%{age_s: age, source: source} = f) when map_size(f) == 2, do: is_number(age) and age >= 0 and (source == nil or is_map(source))
  defp flight?(_), do: false

  defp delivery?(%{key: {_, _, _}, actor: %{}, target: %{id: _, life_generation: _}, q_mj: q, tick: tick, live: live} = d)
       when map_size(d) == 8,
       do: is_integer(q) and q >= 0 and is_integer(tick) and live in [2, 6] and vector?(d.position) and is_integer(d.sampled_us)

  defp delivery?(_), do: false

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
  本次热提交作为内核外部节点的结构（按 id 升序）：带〈热〉（C_th 非空）且已落地。飞行中的结构不进热内核
  （设计 §5.3 C1-15 跳过第 0、2、11 步），已冻结人物命中交付的结构也不进（冻结期间不换热，沿 v1 合同）。
  """
  def heat_nodes(state) do
    all(state)
    |> Enum.filter(fn {_, %{structure: s, body: body} = e} ->
      s.c_th_j_per_k != nil and body.flight == nil and not Map.has_key?(e, :delivery)
    end)
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
      # 已冻结人物命中交付的结构不步进（不出账、不计时、不触发），等目标接纳结果在投射物提交点终止（沿 v1 合同）。
      ordered = structures |> Enum.reject(fn {_, e} -> Map.has_key?(e, :delivery) end) |> Enum.sort()
      neighbors = neighbor_index(ordered, catalog)

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
          "step_us_total=#{Enum.sum(acc.step_us)} step_us_max=#{Enum.max(acc.step_us, fn -> 0 end)} ended=#{ended} " <>
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

    # 第 12 步之后：P1 的响应只有〈散〉，触发预算属切片 7，按优先级执行第一个带〈散〉的触发。读〈遇〉的规则触发记 live 2
    # （投射物命中时读数丢失、接触保持待决，在之后的热拍触发），其余记 live 6（设计方答复 Q4-W3）。
    {final, responded, contact?} =
      case release_trigger(out.triggered) do
        {release, contact?} when stepped.status == :running ->
          {ended, response_out} = Structure.respond(stepped, release, catalog)
          {ended, response_out, contact?}

        _ ->
          {stepped, nil, false}
      end

    requests = out.requests ++ if(responded, do: responded.requests, else: [])
    {state, deposit} = execute(state, site, requests)
    ledgers = [out.ledger | if(responded, do: [responded.ledger], else: [])]
    state = account(state, ledgers, deposit)
    rounding = out.ledger.heat_rounding_mj
    wire = with_flight(Structure.wire({stepped, out}), body.flight != nil)

    case final.status do
      :running ->
        changed = bins(wire) != bins(entry.wire)
        states = if changed, do: Map.put(acc.states, id, record(body, wire, 1)), else: acc.states

        # 可观测面（AGENTS §3）：随状态增量（分箱改变时，每结构每拍至多一行）记下装载、稳态线与 env，越线可直接对照 x*。
        if changed,
          do:
            Logger.info(
              "voxel_structure_state sid=#{inspect(id)} tick=#{tick} load=#{out.metrics.load} x_star=#{out.metrics.steady_load} " <>
                "env=#{out.metrics.env} coherence=#{out.metrics.coherence} status=#{inspect(wire.status)} temperature_k=#{site.temperature_k}"
            )

        state = put_entry(state, id, %{entry | structure: final, wire: wire})
        %{acc | state: state, states: states, rounding: acc.rounding + rounding}

      {:terminated, type} ->
        # 终止类型即线上事件（Codec 唯一定义编号）。在飞行中终止（衰竭、〈满〉〈时〉触发的〈散〉等）的结构就地释放：
        # 终态快照的落点与飞行终点取飞行驱动已推进到的位置（释放落不进格，全部计入辐射账，见 `site/3`）。
        live = Codec.structure_end_live(if(contact?, do: :contact, else: type))
        released_mj = Enum.sum(for {:terminated, _, %{released_mj: mj}} <- out.events ++ if(responded, do: responded.events, else: []), do: mj)
        state = %{state | thermal: Map.update!(state.thermal, :structures, &Map.delete(&1, id))}
        {body, flight} = settle_flight(body)

        Logger.info(
          "voxel_structure_end seq=#{state.seq + 1} sid=#{inspect(id)} cid=#{body.caster} live=#{live} type=#{type} tick=#{tick} " <>
            "released_mj=#{released_mj} heat_mj=#{deposit.heat_mj} radiation_mj=#{deposit.radiation_mj} " <>
            "thermal_mj=#{deposit.thermal_mj} cell=#{inspect(site.deposit && Damage.macro(site.deposit))} protected=#{site.protected}" <>
            if(flight, do: " in_flight=true flight_s=#{body.flight_s} path_m=#{path_m(body)}", else: "")
        )

        %{
          acc
          | state: state,
            records: Map.put(acc.records, id, record(body, with_flight(wire, false), live)),
            ended: [{site.position, released_mj} | acc.ended],
            rounding: acc.rounding + rounding
        }
    end
  end

  # ---------------------------------------------------------------------------
  # 飞行终点（切片 5，决策稿 §5.1；`World.Projectiles` 在投射物提交点调用）
  # ---------------------------------------------------------------------------

  @doc """
  飞行在墙钟飞行时长 `age_s`、中心 `point` 处碰到地形 `target`（canonical 求交的实占用目标）。投射物提交点上依次：

  1. 落地：飞行结束，接触格取命中的未细分宏格（释放、泄漏沉积与热接触都按它，执行时复核持有者）；
  2. 动能出口 `Structure.settle_kinetic/1`：动能在命中格沉积为热（设计 §5.3.3 R7③）；
  3. 〈遇〉：按 `last_tick + 1` 调 `Structure.evaluate_rules/4`（含读数丢失）。触发〈散〉即 `respond/3` 就地终止，读〈遇〉的
     规则记 live 2（终态快照的落点即命中点）；丢失时接触保持待决，结构作为静止结构留下，下一热拍重判（设计 §5.4 R5）。

  Q5-3（暂行，**待设计确认**）：从上一拍到命中这段不足一拍的维持费不补记，差额随释放入账（账目仍闭合）。
  返回 `{state, extra}`，`extra` 是这笔投射物提交事务随附下发的结构记录。
  """
  def land(state, id, age_s, point, target) do
    entry = Map.fetch!(all(state), id)
    body = %{entry.body | flight: nil, flight_s: age_s, rest: point, contact: contact(target)}
    {s, kinetic} = Structure.settle_kinetic(entry.structure)
    {s, triggered} = Structure.evaluate_rules(s, %{contact: true}, s.last_tick + 1, state.magic)
    {site, state} = site_at(state, body)
    finish_contact(state, id, %{entry | body: body}, s, [kinetic], triggered, site, :terrain)
  end

  @doc """
  人物命中（只对 `ends_on_contact` 结构采样，Q5-4）：飞行结束在命中时刻的弹道点，按 `last_tick + 1` 求值〈遇〉。

  - 触发〈散〉：冻结交付。条目记 `delivery`（不可变收据：目标身份与生命、进入组织的能量 `q_mj`、求值拍号、live），结构值
    停在求值后、不再步进，等目标 Player 接纳（Player 复核会话、生命与战斗范围，Harm 的第二个判定点）。本次提交只下发
    “停在命中点”的存在记录（live 1，不再飞行），终止记录在接纳结果的提交点下发（沿 v1 合同 `cast-phases-2026-10-05.md`）。
  - 读数丢失：接触保持待决，结构停在命中点（空气中，无接触格），动能与之后的释放落不进格，计入辐射账；下一热拍重判
    （**待设计确认**：丢失时也可以选择穿过人物继续飞，本实现取“命中即飞行终点”，与设计 §5.1 飞行终点定义一致）。

  进入组织的部分按 Q5-2（用户以设计方身份答复）：E_op 的热半 + 热份额（至多把组织块加热到 T_port）+ 动能；E_op 的辐射半
  与热份额中超出部分只记灵炁辐射账。`target` 是采样后端给的命中上下文（含组织块温度 `tissue_k` 与热容 `tissue_c_j_per_k`）。
  """
  def hit_body(state, id, age_s, point, hit) do
    entry = Map.fetch!(all(state), id)
    body = %{entry.body | flight: nil, flight_s: age_s, rest: point, contact: nil}
    entry = %{entry | body: body, wire: with_flight(entry.wire, false)}
    tick = entry.structure.last_tick + 1
    {s, triggered} = Structure.evaluate_rules(entry.structure, %{contact: true}, tick, state.magic)

    case release_trigger(triggered) do
      {release, contact?} ->
        {requests, _ledgers, _events} = body_release(s, release, state.magic)
        {q_mj, _radiation_mj} = tissue_split(requests, hit.target)
        {seq, n} = id

        delivery = %{
          key: {state.cv, seq, n},
          actor: hit.actor,
          target: Map.take(hit.target, [:id, :identity, :life_generation, :position, :velocity]),
          q_mj: q_mj,
          tick: tick,
          live: Codec.structure_end_live(if(contact?, do: :contact, else: :released)),
          position: point,
          sampled_us: hit.sampled_us
        }

        Logger.info(
          "voxel_structure_flight sid=#{inspect(id)} cid=#{body.caster} phase=contact target=body t_s=#{age_s} path_m=#{path_m(body)} " <>
            "reading_lost=false target_id=#{delivery.target.id} target_life=#{delivery.target.life_generation} q_mj=#{q_mj} " <>
            "tissue_k=#{hit.target.tissue_k} sampled_us=#{hit.sampled_us}"
        )

        entry = entry |> Map.put(:structure, s) |> Map.put(:delivery, delivery)
        {put_entry(state, id, entry), %{structures: %{id => record(body, entry.wire, 1)}}}

      nil ->
        # 丢失：停在命中点、接触待决；动能落不进格（空气），计入辐射账。
        {s, kinetic} = Structure.settle_kinetic(s)
        {site, state} = site_at(state, body)
        finish_contact(state, id, entry, s, [kinetic], [], site, :body)
    end
  end

  # 地形落地与人物命中（丢失）的共同收尾：执行动能与（触发时）释放请求、记账，产出终止记录或停住的存在记录。
  defp finish_contact(state, id, entry, s, outputs, triggered, site, hit) do
    {final, outputs, live} =
      case release_trigger(triggered) do
        {release, contact?} ->
          {ended, out} = Structure.respond(s, release, state.magic)
          {ended, outputs ++ [out], Codec.structure_end_live(if(contact?, do: :contact, else: :released))}

        nil ->
          {s, outputs, 1}
      end

    {state, deposit} = execute(state, site, Enum.flat_map(outputs, & &1.requests))
    state = account(state, Enum.map(outputs, & &1.ledger), deposit)
    body = entry.body
    wire = with_flight(entry.wire, false)

    Logger.info(
      "voxel_structure_flight sid=#{inspect(id)} cid=#{body.caster} phase=#{if body.ends_on_contact, do: "contact", else: "landed"} " <>
        "target=#{hit} t_s=#{body.flight_s} path_m=#{path_m(body)} reading_lost=#{body.ends_on_contact and live == 1} " <>
        "cell=#{inspect(site.deposit && Damage.macro(site.deposit))} kinetic_mj=#{Enum.sum(for o <- outputs, do: o.ledger.out.kinetic_mj)}"
    )

    if live == 1 do
      {put_entry(state, id, %{entry | structure: final, wire: wire}), %{structures: %{id => record(body, wire, 1)}}}
    else
      released_mj = Enum.sum(for o <- outputs, {:terminated, _, %{released_mj: mj}} <- o.events, do: mj)
      state = %{state | thermal: Map.update!(state.thermal, :structures, &Map.delete(&1, id))}
      log_end(state, id, body, live, :released, s.last_tick + 1, released_mj, deposit, site, "hit=#{hit}")
      {state, %{structures: %{id => record(body, wire, live)}}}
    end
  end

  @doc """
  已冻结人物命中交付的接纳结果（投射物提交点，`World.Projectiles`）：结构以冻结时的〈散〉终止，记录 live 2（或 6）。
  接纳（`{:ok, 收据}`）时进入组织的 `q_mj` 记 `structure_body_mj`（并沿 v1 记分项 `projectile_body_j` 与身体总流入
  `body_exchange_j`），其余计入辐射账；未接纳（旧生命、旧 owner、战斗范围外等）时全部散入空气（命中点无接触格，计入辐射账），
  分项记 `projectile_rejected_j`，不转给新生命。返回 `{state, extra, accepted?}`。
  """
  def deliver(state, id, result) do
    %{structure: s, body: body, delivery: delivery} = entry = Map.fetch!(all(state), id)
    accepted = match?({:ok, _}, result)
    {release, _contact?} = fired_release(s, delivery.tick)
    {requests, ledgers, events} = body_release(s, release, state.magic)
    total = Enum.sum(for request <- requests, do: elem(request, 1))
    into_body = if accepted, do: delivery.q_mj, else: 0
    deposit = %{leak_mj: 0, heat_mj: 0, thermal_mj: 0, radiation_mj: total - into_body}
    state = account(state, ledgers, deposit)

    thermal =
      state.thermal
      |> Map.update(:structure_body_mj, into_body, &(&1 + into_body))
      |> then(fn thermal ->
        if accepted,
          do: thermal |> Thermal.ledger(:projectile_body_j, delivery.q_mj / 1000) |> Thermal.ledger(:body_exchange_j, delivery.q_mj / 1000),
          else: Thermal.ledger(thermal, :projectile_rejected_j, delivery.q_mj / 1000)
      end)

    state = %{state | thermal: Map.update!(thermal, :structures, &Map.delete(&1, id))}
    released_mj = Enum.sum(for {:terminated, _, %{released_mj: mj}} <- events, do: mj)
    site = %{deposit: nil, protected: false}

    log_end(state, id, body, delivery.live, :released, delivery.tick, released_mj, deposit, site,
      "hit=body accepted=#{accepted} body_mj=#{into_body} target_id=#{delivery.target.id} result=#{inspect(result)}")

    {state, %{structures: %{id => record(body, entry.wire, delivery.live)}}, accepted}
  end

  @doc """
  飞行中的结构就地散解（live 3，`Structure.dissipate/2`）：飞行终点取已推进到的位置，释放落不进格，全部计入辐射账。
  两处调用（决策稿 §5.1、本片 §14）：冷重启恢复时仍在飞行（W5-5），以及飞行离开 World 能读出 canonical 的范围
  （`World.Projectiles` 的显式终止规则）。`reason` 进日志。返回 `{state, extra}`。
  """
  def dissipate(state, id, reason) do
    %{structure: s, body: body} = entry = Map.fetch!(all(state), id)
    {body, _} = settle_flight(body)
    {ended, out} = Structure.dissipate(s, state.magic)
    site = %{deposit: nil, protected: false}
    {state, deposit} = execute(state, site, out.requests)
    state = account(state, [out.ledger], deposit)
    state = %{state | thermal: Map.update!(state.thermal, :structures, &Map.delete(&1, id))}
    {:terminated, type} = ended.status
    live = Codec.structure_end_live(type)
    released_mj = Enum.sum(for {:terminated, _, %{released_mj: mj}} <- out.events, do: mj)

    Logger.info(
      "voxel_structure_flight sid=#{inspect(id)} cid=#{body.caster} phase=#{reason} target=none t_s=#{body.flight_s} " <>
        "path_m=#{path_m(body)} rest=#{inspect(body.rest)}"
    )

    log_end(state, id, body, live, type, s.last_tick, released_mj, deposit, site, "reason=#{reason}")
    {state, %{structures: %{id => record(body, with_flight(entry.wire, false), live)}}}
  end

  # 冻结的〈散〉在交付结果时重放：settle_kinetic 后 respond（与冻结时求 q 的同一组纯函数，结果逐位相同）。
  defp body_release(s, release, catalog) do
    {s, kinetic} = Structure.settle_kinetic(s)
    {_ended, out} = Structure.respond(s, release, catalog)
    {kinetic.requests ++ out.requests, [kinetic.ledger, out.ledger], out.events}
  end

  # 冻结时触发的规则（fired_tick = 求值拍号）里的〈散〉：持久化后重放用，不另存响应符号。
  defp fired_release(s, tick),
    do: release_trigger(for rule <- s.rules, rule.fired_tick == tick, do: %{responses: rule.responses, contact: Enum.any?(rule.readings, &(&1.kind == :contact))})

  # Q5-2：请求 → {进入组织的 mJ, 计入辐射的 mJ}。有限热源（泄漏热半、E_op 热半、动能）整笔进组织；热份额至多把组织块
  # 加热到端口温度 C_tissue·(T_port − T_tissue)，余下计入辐射。组织块温度与热容取命中采样时的目标上下文。
  defp tissue_split(requests, target) do
    Enum.reduce(requests, {0, 0}, fn
      {:deposit_heat, mj, _cause}, {body, radiation} ->
        {body + mj, radiation}

      {:release_thermal, mj, port}, {body, radiation} ->
        cap = max(0, trunc(target.tissue_c_j_per_k * (port - target.tissue_k) * 1000))
        into = if mj > 0, do: min(mj, cap), else: 0
        {body + into, radiation + mj - into}
    end)
  end

  defp log_end(state, id, body, live, type, tick, released_mj, deposit, site, extra) do
    Logger.info(
      "voxel_structure_end seq=#{state.seq + 1} sid=#{inspect(id)} cid=#{body.caster} live=#{live} type=#{type} tick=#{tick} " <>
        "released_mj=#{released_mj} heat_mj=#{deposit.heat_mj} radiation_mj=#{deposit.radiation_mj} " <>
        "thermal_mj=#{deposit.thermal_mj} cell=#{inspect(site.deposit && Damage.macro(site.deposit))} protected=#{site.protected} " <>
        "rest=#{inspect(body.rest)} flight_s=#{body.flight_s} " <> extra
    )
  end

  # 第一个带〈散〉的触发：{响应符号, 该规则是否读〈遇〉}，没有时为 nil。
  defp release_trigger(triggered) do
    Enum.find_value(triggered, fn trigger ->
      case Enum.find(trigger.responses, &(&1.id == "resp.release")) do
        nil -> nil
        release -> {release, trigger.contact}
      end
    end)
  end

  # 飞行在此刻结束（就地终止）：飞行终点取已推进到的飞行时长与位置；返回 {物理体, 是否原在飞行}。
  defp settle_flight(%{flight: %{age_s: age}} = body),
    do: {%{body | flight: nil, flight_s: age, rest: position(body), contact: nil}, true}

  defp settle_flight(body), do: {body, false}

  # 自出发点到落点的路程（m，可观测量）：有质量者按弦长累计，无质量者为直线距离。
  defp path_m(%{massless: true} = body), do: distance(body.origin, body.rest)

  defp path_m(body) do
    body
    |> Map.put(:age_s, 0.0)
    |> Semblance.flight_segments(body.flight_s)
    |> Enum.reduce(0.0, fn {_, _, a, b}, sum -> sum + distance(a, b) end)
  end

  defp put_entry(state, id, entry),
    do: %{state | thermal: Map.update!(state.thermal, :structures, &Map.put(&1, id, entry))}

  # 本拍读数的位置：落地后取落点；飞行中取飞行驱动已推进到的位置（墙钟飞行，设计 §5.8）。沉积格（接触格）只在落地后
  # 存在，并按执行时复核。
  defp site(state, %{body: body}, _tick), do: elem(site_at(state, body), 0)

  defp site_at(state, body) do
    landed = body.flight == nil
    position = position(body)
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

    {%{
       position: position,
       deposit: deposit,
       protected: protected,
       temperature_k: temperature * 1.0,
       cell_c: cell_c * 1.0,
       embedded: own != nil
     }, state}
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
  defp neighbor_index(ordered, catalog) do
    for {id, %{structure: s, body: body}} <- ordered, into: %{} do
      position = position(body)
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

  @doc """
  物理体弹道的 canonical 求交（`Magic.Semblance.trace/8`、`segment/5` 的 `cast` 回调；施放时的预测与飞行驱动共用）：
  与工具同一 Amanatides–Woo 射线，命中返回 `{{目标, 进入的微格}, state}`，否则 `{nil, state}`。
  """
  def cast(origin, direction, length, state) do
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
