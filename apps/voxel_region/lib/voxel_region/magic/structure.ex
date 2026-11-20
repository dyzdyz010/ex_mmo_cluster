defmodule VoxelRegion.Magic.Structure do
  @moduledoc """
  符号组合魔法 v2（切片 0c）：运行中结构对象的纯值步进。

  设计来源：TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md` v2.7（下称“设计”）§4.3、§5.1–5.5、§5.8、
  §7.3；落地决策见 `docs/10-active/magic/2026-11-19-glyph-v2-server-landing.md`（D3 整数 mJ 即真值、D4 按热提交拍号推进）。
  运行期常数全部读目录 v5 `runtime`（schema 文档 §4）；本模块只保留设计正文写死、目录没有字段的归一常数。

  §4.3 运行期公式（`environment/4`、`disruption_rate/4`、`repair_unit_cost_j/2`、`repair_cap/3`、`running_loss_w/3`、
  `steady_load/4`）在这里唯一定义并公开；报价 `Magic.Cost` 直接调用，不复制。它们接受结构值或报价值（二者都带
  `units`、`precision`、`volume_m3`、`phi_cap_w`、`r_base_per_s`）。

  ## 职责边界

  本模块只做纯计算：不读 World、不发消息、不写世界、不读墙钟、不用随机源（铁律 5）。调用方（World 的热提交点）
  在每次热提交后按结构 id 升序调用 `step/4`，把显式读数交进来，再把返回的 **请求** 与热结算放进同一笔 commit。
  暂停或积压冻结时调用方不调用即可，本模块没有“暂停”概念（D4）。

  ```mermaid
  flowchart LR
    W[World 热提交点] -->|拍号 + 环境读数 + 净热 + 供能 + 干预场| S[Structure.step/4]
    S -->|新结构值| W
    S -->|沉积/热释放/施法者侧热 请求| W
    S -->|事件、触发、账目、观测量| W
  ```

  ## 能量与账目（整数 mJ）

  储能分四个池，全部为整数 mJ：运转储能 `e_op_mj`、热份额 `e_th_mj`、动能 `kinetic_mj`、未沉积泄漏 `pending_leak_mj`。
  每次调用返回的账目满足：`Σ 流入 = Σ 流出 + (stored_after − stored_before)`，逐项为整数，无舍入吞没。
  唯一的跨系统舍入是热内核的 f64 净热换算为 mJ（四舍五入、半数远离零，设计 §5.8），残差以 `heat_rounding_mj`
  单列交给 World 记入分区账目 `structure_rounding_mj`。

  动能单列，只经 `settle_kinetic/1` 与终止释放离开结构，一律在落点或命中点所在格沉积为热、不进热份额
  （设计 §5.3.3 R7③）；该出口是动量接触（决策稿风险 4）将要替换的唯一位置。

  出账细则按设计 §5.3.3：储能不足时按 泄漏 → 发光 → 活动 的顺序支付、E_op 不为负，活动未付足时该拍的场按
  t_eff = 实付活动能 ÷ P_act 缩短（R7②）；活动能整笔计为灵炁辐射 `activity_mj`，不进 pending_leak（R3）；
  R_max 中的供能取施法者本拍推送的链功率（R7④）；〈散〉不收调整耗散（R7①）。

  ## 每拍顺序（设计 §5.3，P1 范围）

  第 2 步热 → 第 3 步供能 → 第 1、5 步 env、装载、扰乱、修复上限 → 第 6 步修复与欠账（含干预剂量与邻近终止释放剂量）
  → 第 7 步出账 → 第 8 步泄漏沉积 → 第 10 步终止检查 → 第 12 步条件求值。第 0 步与热内核限流属于切片 1；
  第 4 步〈汲〉、第 9 步分段与泄放口为 P2；第 11 步热节点休眠需要接触节点温差，由 World 侧判定（切片 1/5）。

  ## 终止类型（设计 §5.5、§11.3）

  `:exhausted` 断供衰竭（3）、`:collapsed` 过载崩解（4）、`:dispelled` 驱散（5）、`:released` 主动终止（6）。
  第 10 步按设计 §5.5（v2.7 R4）的顺序取第一个成立的：相干跌破且 debt_int > debt/2 → 驱散；相干跌破且
  x ≥ 0.8·x* → 过载崩解；其余（含 E_op < E_min）→ 断供衰竭。线上编号属于协议切片，本模块只给类型。
  """

  alias VoxelRegion.Magic.Catalog
  alias VoxelRegion.Magic.Program.{Glyph, Group, Rule}

  # 热提交拍长（D4：结构时钟 = 热提交拍号，每拍 0.5 模拟秒）。与 `world/thermal.ex` 的 500 ms 自然步同值，
  # 那里目前写的是字面量；切片 5 接线时应让二者引用同一定义。
  @tick_ms 500
  @tick_s @tick_ms / 1000

  # 设计正文写死、目录 v5 没有字段的归一常数（其余运行期常数都读目录 `runtime`）：
  # env 邻居项按 1 kW 归一（§4.3）；驱散剂量按 1 kW 归一（§7.3 写明的“1 kW × 1 s”常数）；终止释放剂量按 1 kJ 归一（§5.5）。
  @neighbor_power_unit_w 1000
  @dose_power_unit_w 1000
  @release_energy_unit_mj 1_000_000
  # 过载崩解要求 x ≥ 0.8·x*（§5.5）。
  @overload_share 0.8
  # 〈满〉读数按 1/32 量化（§5.4）；阈值槽单位为基点（1/10000）。
  @load_steps 32
  @basis_points 10_000
  # debt 与 debt_int 的整数存储单位：1e-6 无量纲相干度单位，C = 1 − c_d·debt（§5.1，v2.7 R6）。
  @micro 1_000_000

  @typedoc "结构 id：`{创建事务 seq, n}`（与现行拟态记录同法；设计 §11.2 B6）。"
  @type id :: {non_neg_integer(), non_neg_integer()}

  @typedoc "终止类型，见 moduledoc。"
  @type termination :: :exhausted | :collapsed | :dispelled | :released

  @typedoc """
  报价（`Cost.quote_structure/3` 的产出）中本模块消费的字段。能量为整数 mJ，由报价方按设计 §11.4.7 的整数公式
  一次算定，与向施法者收取的物理能量是同一个整数，从而施放前后账目闭合。

  - `units`、`precision`、`volume_m3`：S、P、V（§4.5、§4.2）。
  - `e_cap_mj`：储能硬上限 E_cap（§4.4，含〈容 储能〉倍率）；`e_min_mj`：E_min = 目录 `min_energy_per_complexity_j` × S·P。
  - `phi_cap_w`：吞吐上限 Φ_cap（§4.4）。
  - `r_base_per_s`：修复基值 r0·Q·g_R（§4.3、§5.1 `r_base`）。
  - `e_th0_mj`、`c_th_j_per_k`、`t_ref_k`：出生热份额 C_th·(T0 − T_ref)、热容（无〈热〉时为 `nil`）、施放处环境温度
    （按 0.1 K 量化，§11.4.7 的 T_ref_dk）。
  - `kinetic_mj`：〈投〉的 ½·m·v²（无质量或无〈投〉时为 0）。
  """
  @type structure_quote :: %{
          units: number(),
          precision: number(),
          volume_m3: number(),
          e_cap_mj: pos_integer(),
          e_min_mj: pos_integer(),
          phi_cap_w: number(),
          r_base_per_s: number(),
          e_th0_mj: integer(),
          c_th_j_per_k: number() | nil,
          t_ref_k: number(),
          kinetic_mj: non_neg_integer()
        }

  @typedoc """
  一个干预场在本拍对某个目标的作用（`disruption_field/4` 的结果）：`env` 是环境因子增量，`seconds` 是本拍内
  从拍首起的存续时长（0 < seconds ≤ 0.5）。
  """
  @type field :: %{env: float(), seconds: float()}

  @typedoc """
  `step/4` 的显式读数，全部由 World 提供：

  - `net_heat_j`：热内核本拍给本节点的净热（J，f64，流入为正；已限流；飞行中或无热耦合为 0）。
  - `feed_w`：供能链本拍功率上限（整数 W；无链为 0）。
  - `temperature_k`：所在格温度；`cell_heat_capacity_j_per_k`：所在格热容（泄漏沉积阈值用）；`embedded`：是否嵌在固体内。
  - `neighbors`：World 在目录 `env_neighbor_radius_m` 内选出的贡献最大的 ≤ `env_neighbor_max` 个邻近结构
    `%{leak_w, distance_m}`（§5.3 第 1 步、§5.3.2）。
  - `fields`：本拍存续中的干预场（`disruption_field/4`）；不含结构自身发出的场（§7.3 R2：发出者不受自身场）。
  - `release_doses`：3 m 内本拍终止的结构 `%{energy_mj, distance_m}`（终止事件的 `released_mj`）。
  - `contact`：本拍是否发生〈遇〉接触（热拍中首次出现导热边，或投射物命中）。
  """
  @type inputs :: %{
          net_heat_j: number(),
          feed_w: non_neg_integer(),
          temperature_k: number(),
          cell_heat_capacity_j_per_k: number(),
          embedded: boolean(),
          neighbors: [%{leak_w: number(), distance_m: number()}],
          fields: [field()],
          release_doses: [%{energy_mj: non_neg_integer(), distance_m: number()}],
          contact: boolean()
        }

  @typedoc """
  交给 World 提交的请求（本模块不写世界）：

  - `{:deposit_heat, mj, cause}`：在结构所在格沉积有限热源；`cause` 为 `:leak`（泄漏批量沉积中的热份额
    `leak_heat_fraction`）、`:release`（终止时运转储能中的热份额 `release_heat_fraction`）或 `:kinetic`（动能出口）。
  - `{:release_thermal, mj, port_temperature_k}`：终止时的热份额，每格至多加热（或冷却）到端口温度，余下计入辐射账（§5.2）。
  - `{:caster_heat, mj}`：供能推不进的部分，留在施法者一侧发热（§4.4，现有 `cast_waste` 科目）。
  """
  @type request ::
          {:deposit_heat, pos_integer(), :leak | :release | :kinetic}
          | {:release_thermal, integer(), float()}
          | {:caster_heat, pos_integer()}

  @typedoc "一条被触发的规则：优先级、判定结果与要执行的响应（交给 World 按触发预算调度，再调 `respond/2`）。"
  @type trigger :: %{
          priority: non_neg_integer(),
          outcome: :met | :unmet | :undecidable,
          responses: [Glyph.t()]
        }

  @typedoc """
  一次调用的输出。`ledger` 全部为整数 mJ（`heat_rounding_mj` 除外）：

  - `in`：`heat_mj`（净热，有符号）、`feed_mj`（供能链提供的全部能量）。
  - `out`：`feed_rejected_mj`、`light_mj`（发光）、`activity_mj`（干预活动）、`leak_heat_mj` / `leak_radiation_mj`
    （泄漏沉积的热半与灵炁辐射半）、`release_heat_mj` / `release_radiation_mj`（终止时运转储能两半）、
    `release_thermal_mj`（终止时热份额，有符号）、`kinetic_mj`（动能出口）。
  - `stored_before_mj` / `stored_after_mj`：四个储能池之和。

  `metrics` 是本拍可观测量（切片 1 的 `voxel_structure_*` 日志直接取用）。
  """
  @type outputs :: %{
          requests: [request()],
          events: [{:terminated, termination(), %{released_mj: non_neg_integer()}}],
          triggered: [trigger()],
          ledger: map(),
          metrics: map()
        }

  @type t :: %__MODULE__{}

  @enforce_keys [
    :id,
    :born_tick,
    :last_tick,
    :units,
    :precision,
    :volume_m3,
    :e_cap_mj,
    :e_min_mj,
    :phi_cap_w,
    :r_base_per_s,
    :t_ref_k,
    :e_op_mj
  ]
  defstruct [
    # 身份与时钟（热提交拍号）
    :id,
    :born_tick,
    :last_tick,
    # 计价与容量（来自报价）
    :units,
    :precision,
    :volume_m3,
    :e_cap_mj,
    :e_min_mj,
    :phi_cap_w,
    :r_base_per_s,
    # 热耦合：无〈热〉时 c_th 为 nil
    :t_ref_k,
    :e_op_mj,
    c_th_j_per_k: nil,
    e_th_mj: 0,
    kinetic_mj: 0,
    pending_leak_mj: 0,
    # 耦合：发光功率（W）；干预活动 %{power_w, radius_m, duration_s}
    glow_w: 0,
    activity: nil,
    # 最近一次步进的那一拍里，本结构发出的场实际存续的秒数（实付活动折算的 t_eff，§5.3.3 R7②）
    field_s: 0.0,
    # 欠账（1e-6 相干度）与其中来自干预剂量的部分
    debt_micro: 0,
    debt_int_micro: 0,
    rules: [],
    status: :running
  ]

  @out_keys [
    :feed_rejected_mj,
    :light_mj,
    :activity_mj,
    :leak_heat_mj,
    :leak_radiation_mj,
    :release_heat_mj,
    :release_radiation_mj,
    :release_thermal_mj,
    :kinetic_mj
  ]

  @doc "热提交拍长（毫秒）。结构的一切计时都按拍号乘以它（D4）。"
  def tick_ms, do: @tick_ms

  # ---------------------------------------------------------------------------
  # 出生
  # ---------------------------------------------------------------------------

  @doc """
  由合法结构组（`Program.decode_ir/2` 的产出）与报价构造运行中的结构。`born_tick` 是出生时最近一次已完成的热提交
  拍号，第一次 `step/4` 的拍号为 `born_tick + 1`。

  - 运转储能取〈蓄〉的 `energy_mj`；发光取〈辉〉的 `power_w`；〈乱〉的存续 τ = (E₀_op − E_min) / P_act（§7.3）。
  - 〈时〉的到期拍号 = born_tick + ⌈时长 / 拍长⌉（向上取整，不早于写明时长触发）。
  """
  @spec new(id(), Group.t(), structure_quote(), non_neg_integer()) :: t()
  def new({seq, n} = id, %Group{} = group, structure_quote, born_tick)
      when is_integer(seq) and is_integer(n) and is_integer(born_tick) do
    %{
      units: units,
      precision: precision,
      volume_m3: volume,
      e_cap_mj: e_cap,
      e_min_mj: e_min,
      phi_cap_w: phi,
      r_base_per_s: r_base,
      e_th0_mj: e_th0,
      c_th_j_per_k: c_th,
      t_ref_k: t_ref,
      kinetic_mj: kinetic
    } = structure_quote

    %Glyph{params: %{"energy_mj" => e_op}} = glyph!(group.energy, "energy.load")

    %__MODULE__{
      id: id,
      born_tick: born_tick,
      last_tick: born_tick,
      units: units,
      precision: precision,
      volume_m3: volume,
      e_cap_mj: e_cap,
      e_min_mj: e_min,
      phi_cap_w: phi,
      r_base_per_s: r_base,
      c_th_j_per_k: c_th,
      t_ref_k: t_ref,
      e_op_mj: e_op,
      e_th_mj: e_th0,
      kinetic_mj: kinetic,
      glow_w: glow_w(group.quality),
      activity: activity(group.quality, e_op, e_min),
      rules: Enum.map(group.rules, &rule(&1, born_tick))
    }
  end

  defp glyph!(glyphs, id),
    do: Enum.find(glyphs, &(&1.id == id)) || raise(ArgumentError, "结构组缺少 #{id}")

  defp glow_w(quality) do
    case Enum.find(quality, &(&1.id == "cpl.glow")) do
      %Glyph{params: %{"power_w" => power}} -> power
      nil -> 0
    end
  end

  defp activity(quality, e_op, e_min) do
    case Enum.find(quality, &(&1.id == "int.disrupt")) do
      %Glyph{params: %{"activity_w" => power, "radius_mm" => radius}} ->
        # τ = 有效能量 / 活动功率（模拟秒）；mJ / W = ms。
        %{
          power_w: power,
          radius_m: radius / 1000,
          duration_s: max(0, e_op - e_min) / power / 1000
        }

      nil ->
        nil
    end
  end

  defp rule(%Rule{} = rule, born_tick) do
    %{
      priority: rule.priority,
      readings: Enum.map(rule.readings, &reading(&1, born_tick)),
      responses: rule.responses,
      backup: rule.backup,
      backup_response: rule.backup_response,
      fired_tick: nil
    }
  end

  # 读数状态只记录“待决”的事实（§5.4 v2.7 R5）：〈遇〉的接触在被一次未丢失的求值消费前保持待决（`pending`）；
  # 〈时〉到期后在被消费前保持待决（`done` 为 false）；〈满〉的“上次量化值”只在未丢失的求值后更新（`last_q`）。
  defp reading(%Glyph{id: "cond.contact"}, _born_tick), do: %{kind: :contact, pending: false}

  # P1 的〈时〉只能从出生起计（`from` 槽未启用引用，解码后恒为 nil）；P2 开放〈记〉起点时这里须一起实现。
  # 到期拍 = 出生拍 + ⌈duration ÷ 拍长⌉（§5.4）。
  defp reading(
         %Glyph{id: "cond.timer", params: %{"duration_cs" => cs, "from" => nil}},
         born_tick
       ),
       do: %{
         kind: :timer,
         due_tick: born_tick + div(cs * 10 + @tick_ms - 1, @tick_ms),
         done: false
       }

  defp reading(
         %Glyph{
           id: "cond.load",
           params: %{"quantity" => quantity, "dir" => dir, "threshold_bp" => bp}
         },
         _
       ) do
    %{
      kind: :load,
      quantity: Map.fetch!(%{"load" => :load, "coherence" => :coherence}, quantity),
      dir: Map.fetch!(%{"above" => :above, "below" => :below}, dir),
      threshold: bp / @basis_points,
      last_q: nil
    }
  end

  # ---------------------------------------------------------------------------
  # 每拍步进
  # ---------------------------------------------------------------------------

  @doc """
  在热提交拍 `tick`（必须等于 `last_tick + 1`）推进一拍，返回 `{新结构, outputs}`。

  已终止的结构不能再步进（函数子句不匹配即显式失败）。终止时本拍同时清空全部储能池并给出释放请求。
  """
  @spec step(t(), inputs(), non_neg_integer(), Catalog.t()) :: {t(), outputs()}
  def step(%__MODULE__{status: :running, last_tick: last} = s, inputs, tick, %Catalog{} = catalog)
      when tick == last + 1 do
    %{
      net_heat_j: net_heat_j,
      feed_w: feed_w,
      temperature_k: temperature_k,
      cell_heat_capacity_j_per_k: cell_c,
      embedded: embedded,
      neighbors: neighbors,
      fields: fields,
      release_doses: release_doses,
      contact: contact
    } = inputs

    rt = catalog.runtime
    before = stored_mj(s)

    # 第 2 步：热份额吃进内核净热（换算 mJ 时四舍五入、半数远离零，残差单列）。
    heat_mj = round(net_heat_j * 1000)
    s = %{s | e_th_mj: s.e_th_mj + heat_mj}

    # 第 3 步：供能 min(链功率, Φ_cap, (E_cap − E)/Δt)·Δt；推不进的部分留在施法者一侧。W × ms = mJ。
    offered = feed_w * @tick_ms
    accepted = Enum.min([offered, trunc(s.phi_cap_w * @tick_ms), max(0, s.e_cap_mj - load_mj(s))])
    s = %{s | e_op_mj: s.e_op_mj + accepted}

    # 第 1、5 步：env、装载、修复上限；第 6 步：修复与欠账（含干预剂量），再加邻近终止释放剂量（不计入 debt_int，§5.5 R4）。
    env = environment(temperature_k, neighbors, embedded, catalog)
    x = load_ratio(s)
    line = line(s, x, env, fields, feed_w, catalog)
    debt = line.debt + release_debt(s, x, release_doses, catalog)

    # 第 7 步：出账。运行损耗按本拍装载计；泄漏部分（运行、修复、越线、偿还）进 pending_leak。
    # 储能不足时按 泄漏 → 发光 → 活动 的顺序支付，E_op 不为负；未付的部分不发生（§5.3.3 R7②）。
    run_j = running_loss_w(s, load_mj(s), catalog) * @tick_s
    leak_mj = round((run_j + line.repair_j + line.overline_j + line.repay_j) * 1000)
    nominal_field_s = nominal_field_seconds(s, tick)
    activity_due = activity_mj(s, nominal_field_s)

    {[leak_paid, light, activity], e_op} =
      pay([leak_mj, s.glow_w * @tick_ms, activity_due], s.e_op_mj)

    debt_micro = round(debt * @micro)

    s = %{
      s
      | e_op_mj: e_op,
        pending_leak_mj: s.pending_leak_mj + leak_paid,
        last_tick: tick,
        field_s: field_seconds_paid(s, activity, activity_due, nominal_field_s),
        debt_micro: debt_micro,
        debt_int_micro: min(debt_micro, round(line.debt_int * @micro))
    }

    # 第 8 步：泄漏批量沉积，阈值 Q_dep = min(10 kJ, 2 K × 所在格热容)。
    {s, deposit_requests, deposit_out} = deposit_leak(s, cell_c, rt)

    # 第 10 步：终止检查。x* 用本拍按存续时长加权的 env（§7.3“按存续时长比例计入”）。
    effective_env = env + Enum.sum(Enum.map(fields, &(&1.env * &1.seconds / @tick_s)))
    x_star = steady_load(s, effective_env, feed_w, catalog)
    x_now = load_ratio(s)

    metrics = %{
      env: effective_env,
      load: x_now,
      steady_load: x_star,
      disruption_per_s: line.base_rate,
      repair_cap_per_s: line.repair_cap,
      debt: s.debt_micro / @micro,
      coherence: coherence(s, rt),
      dose: line.dose,
      leak_w: leak_paid / @tick_ms,
      field_s: s.field_s
    }

    inflow = %{heat_mj: heat_mj, feed_mj: offered}
    outflow = %{feed_rejected_mj: offered - accepted, light_mj: light, activity_mj: activity}
    rejected = if offered > accepted, do: [{:caster_heat, offered - accepted}], else: []
    requests = rejected ++ deposit_requests
    outflow = add_out(outflow, deposit_out)

    {s, requests, outflow, events, triggered} =
      case termination(s, x_now, x_star, rt) do
        nil ->
          # 第 12 步：条件求值（只产出触发，响应由 World 按触发预算调用 `respond/2` 执行）。
          {s, triggered} = evaluate_rules(s, %{contact: contact}, tick, catalog)
          {s, requests, outflow, [], triggered}

        type ->
          {s, release_requests, release_out, event} = terminate(s, type, rt)
          {s, requests ++ release_requests, add_out(outflow, release_out), [event], []}
      end

    ledger =
      ledger(before, s, inflow, outflow)
      |> Map.put(:heat_rounding_mj, net_heat_j * 1000 - heat_mj)

    {s,
     %{requests: requests, events: events, triggered: triggered, ledger: ledger, metrics: metrics}}
  end

  # 第 6 步（§4.3 拍内分段，v2.7 R1；§7.3）：本拍按各干预场的结束时刻切成若干段，段内扰乱速度恒定。
  # - 越线段（D > R_max）：欠账 += (D − R_max)·t；修复按 R_max 付；越线部分 overline_leak_factor·e_r·(D − R_max)·t
  #   计入泄漏。干预剂量 = (有场时的越线量 − 无场时的越线量)·t，累加进 debt_int（§5.1）。
  # - 线内段：修复按 D 付；偿还 min(debt, (R_max − D)·t)，偿还耗能 e_r·偿还量计入泄漏；debt_int 按偿还比例同步减少。
  # 调用方再把 debt_int 截到不超过 debt（§5.1“始终 ≤ debt”）。
  defp line(s, x, env, fields, feed_w, %Catalog{runtime: rt} = catalog) do
    unit_rate = disruption_rate(s, x, 1, catalog)
    repair_cap = repair_cap(s, feed_w, catalog)
    unit_cost = repair_unit_cost_j(s, catalog)
    base_rate = unit_rate * env
    base_over = max(0.0, base_rate - repair_cap)

    start = %{
      debt: s.debt_micro / @micro,
      debt_int: s.debt_int_micro / @micro,
      dose: 0.0,
      repair_j: 0.0,
      overline_j: 0.0,
      repay_j: 0.0,
      base_rate: base_rate,
      repair_cap: repair_cap
    }

    Enum.reduce(pieces(fields), start, fn {t, extra_env}, acc ->
      rate = unit_rate * (env + extra_env)

      if rate > repair_cap do
        over = rate - repair_cap
        dose = (over - base_over) * t

        %{
          acc
          | debt: acc.debt + over * t,
            debt_int: acc.debt_int + dose,
            dose: acc.dose + dose,
            repair_j: acc.repair_j + unit_cost * repair_cap * t,
            overline_j: acc.overline_j + rt.overline_leak_factor * unit_cost * over * t
        }
      else
        repaid = min(acc.debt, (repair_cap - rate) * t)
        debt_int = if acc.debt > 0, do: acc.debt_int * (1 - repaid / acc.debt), else: 0.0

        %{
          acc
          | debt: acc.debt - repaid,
            debt_int: debt_int,
            repair_j: acc.repair_j + unit_cost * rate * t,
            repay_j: acc.repay_j + unit_cost * repaid
        }
      end
    end)
  end

  # 每个场从拍首起存续 seconds；按各场结束时刻切段，返回 [{段长, 段内活动场的 env 增量之和}]，覆盖整拍。
  defp pieces(fields) do
    bounds =
      fields |> Enum.map(& &1.seconds) |> Enum.concat([@tick_s]) |> Enum.uniq() |> Enum.sort()

    {pieces, _} =
      Enum.map_reduce(bounds, 0.0, fn bound, from ->
        extra = fields |> Enum.filter(&(&1.seconds >= bound)) |> Enum.map(& &1.env) |> Enum.sum()
        {{bound - from, extra}, bound}
      end)

    Enum.filter(pieces, fn {t, _} -> t > 0 end)
  end

  # §5.5：Δdebt = D0·P·(1 + κx²)·a_X·k_rel·(E_释放 / 1 kJ)·(1 − d / release_dose_radius_m)²。
  defp release_debt(s, x, doses, %Catalog{runtime: rt} = catalog) do
    unit = disruption_rate(s, x, 1, catalog) * rt.disruption_dose_gain * rt.release_dose_ratio

    Enum.sum(
      Enum.map(doses, fn %{energy_mj: energy, distance_m: d} ->
        falloff = max(0.0, 1 - d / rt.release_dose_radius_m)
        unit * energy / @release_energy_unit_mj * falloff * falloff
      end)
    )
  end

  # 本拍出账按顺序付款，每项至多付到运转储能耗尽（§5.3.3 R7②：未付的部分本拍没有发生，不透支）。
  defp pay(items, available) do
    Enum.map_reduce(items, available, fn item, left ->
      paid = min(item, left)
      {paid, left - paid}
    end)
  end

  defp deposit_leak(s, cell_c, rt) do
    threshold = round(min(rt.leak_deposit_max_j, rt.leak_deposit_temperature_k * cell_c) * 1000)

    if s.pending_leak_mj >= threshold do
      {heat, radiation} = split(s.pending_leak_mj, rt.leak_heat_fraction)

      {%{s | pending_leak_mj: 0}, deposit(heat, :leak),
       %{leak_heat_mj: heat, leak_radiation_mj: radiation}}
    else
      {s, [], %{}}
    end
  end

  # 第 10 步，判定顺序见 moduledoc（§5.5 v2.7 R4）。debt_int > debt/2 用整数写作 2·debt_int > debt。
  defp termination(s, x, x_star, rt) do
    collapsed = coherence(s, rt) < rt.coherence_min

    cond do
      collapsed and 2 * s.debt_int_micro > s.debt_micro -> :dispelled
      collapsed and x >= @overload_share * x_star -> :collapsed
      collapsed or s.e_op_mj < s.e_min_mj -> :exhausted
      true -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # 终止与出口
  # ---------------------------------------------------------------------------

  @doc """
  执行一个已触发的响应（World 按触发预算调度后调用）。P1 只有〈散〉：主动终止并释放（§5.4“〈散〉直接进入终止”），
  不收调整耗散（§5.3.3 R7①）。返回值与 `step/4` 同形；`metrics` 为空。
  """
  @spec respond(t(), Glyph.t(), Catalog.t()) :: {t(), outputs()}
  def respond(%__MODULE__{status: :running} = s, %Glyph{id: "resp.release"}, %Catalog{runtime: rt}) do
    before = stored_mj(s)
    {s, requests, out, event} = terminate(s, :released, rt)

    {s,
     %{
       requests: requests,
       events: [event],
       triggered: [],
       ledger: ledger(before, s, %{}, out),
       metrics: %{}
     }}
  end

  @doc """
  动能的唯一出口：飞行结束（命中或落地）时由 World 调用。整笔动能作为有限热源沉积到落点或命中点所在格，不进热份额，
  有无〈热〉都一样（设计 §5.3.3 R7③）；动量接触（P4，决策稿风险 4）落地时替换本函数，不改其他步进逻辑。
  """
  @spec settle_kinetic(t()) :: {t(), outputs()}
  def settle_kinetic(%__MODULE__{status: :running, kinetic_mj: kinetic} = s) do
    before = stored_mj(s)
    s = %{s | kinetic_mj: 0}

    {s,
     %{
       requests: deposit(kinetic, :kinetic),
       events: [],
       triggered: [],
       ledger: ledger(before, s, %{}, %{kinetic_mj: kinetic}),
       metrics: %{}
     }}
  end

  # 释放形态（§5.5、§5.2）：pending_leak 一次清空（按 leak_heat_fraction 分热与辐射）；E_op 按 release_heat_fraction
  # 一份作为有限热源沉积、其余计入辐射账；E_th 按端口温度上限交 World 沉积；剩余动能经同一动能出口沉积。
  # `released_mj` 供 World 计算邻近释放剂量。
  defp terminate(s, type, rt) do
    {leak_heat, leak_radiation} = split(s.pending_leak_mj, rt.leak_heat_fraction)
    {release_heat, release_radiation} = split(s.e_op_mj, rt.release_heat_fraction)

    thermal =
      if s.e_th_mj != 0, do: [{:release_thermal, s.e_th_mj, port_temperature(s)}], else: []

    requests =
      deposit(leak_heat, :leak) ++
        deposit(release_heat, :release) ++ thermal ++ deposit(s.kinetic_mj, :kinetic)

    out = %{
      leak_heat_mj: leak_heat,
      leak_radiation_mj: leak_radiation,
      release_heat_mj: release_heat,
      release_radiation_mj: release_radiation,
      release_thermal_mj: s.e_th_mj,
      kinetic_mj: s.kinetic_mj
    }

    event = {:terminated, type, %{released_mj: s.e_op_mj + abs(s.e_th_mj)}}

    s = %{
      s
      | e_op_mj: 0,
        e_th_mj: 0,
        kinetic_mj: 0,
        pending_leak_mj: 0,
        status: {:terminated, type}
    }

    {s, requests, out, event}
  end

  defp deposit(0, _cause), do: []
  defp deposit(mj, cause), do: [{:deposit_heat, mj, cause}]

  # 把整数 mJ 按热份额分成 {热, 辐射}：热取四舍五入（半数远离零，§11.4.7 入账规则），辐射取余数，二者之和恒等于原值。
  defp split(mj, heat_fraction) do
    heat = round(mj * heat_fraction)
    {heat, mj - heat}
  end

  # ---------------------------------------------------------------------------
  # 干预剂量（§7.3）
  # ---------------------------------------------------------------------------

  @doc """
  干预结构（〈乱〉）在拍 `tick` 对距离 `distance_m` 处目标的作用；无作用时为 `nil`。

  env 增量 = a_X·(P_act / 1 kW)·(1 − d/r)²（平方型衰减、到半径边缘为零），存续时长从拍首起计：

  - 发出者本拍尚未步进（`tick = last_tick + 1`）：名义时长 = 本拍内 τ 的剩余部分（A.4：τ = 0.595 s 时第 1 拍 0.5 s、
    第 2 拍 0.095 s）。
  - 发出者本拍已步进（`tick = last_tick`，含在本拍终止）：实付活动能折算的 t_eff = 实付活动能 ÷ P_act
    （§5.3.3 R7②；活动付足时等于名义时长）。

  World 按 §5.8 的 id 升序步进，步进每个目标时向各发出者取当时的场：比目标 id 小的发出者已步进、给 t_eff，
  比目标 id 大的尚未步进、给名义时长。二者只在发出者活动未付足的那一拍（即它断供终止的那一拍）不同。
  场不作用于发出它的结构自身（§7.3 R2）：World 不把发出者自己的场交给它的 `step/4`。
  """
  @spec disruption_field(t(), number(), non_neg_integer(), Catalog.t()) :: field() | nil
  def disruption_field(%__MODULE__{activity: nil}, _distance_m, _tick, %Catalog{}), do: nil

  def disruption_field(%__MODULE__{activity: activity} = s, distance_m, tick, %Catalog{
        runtime: rt
      }) do
    seconds = field_seconds(s, tick)

    if seconds > 0 and distance_m < activity.radius_m do
      falloff = 1 - distance_m / activity.radius_m

      %{
        env: rt.disruption_dose_gain * activity.power_w / @dose_power_unit_w * falloff * falloff,
        seconds: seconds
      }
    end
  end

  # 见 `disruption_field/4`：未步进的运行中发出者给名义时长，已步进的给本拍记录的 t_eff。其余情况（已在更早的拍终止、
  # 拍号不连续）没有匹配子句，显式失败。
  defp field_seconds(%__MODULE__{status: :running, last_tick: last} = s, tick)
       when tick == last + 1,
       do: nominal_field_seconds(s, tick)

  defp field_seconds(%__MODULE__{last_tick: tick, field_s: seconds}, tick), do: seconds

  @doc """
  一个干预场在一拍内给目标带来的毛剂量（A.4 每拍公式，不扣偿还）：
  max(0, D(env + Δenv) − R_max)·t − max(0, D(env) − R_max)·t，D、R_max 按目标当前装载与 `feed_w` 计（§4.3）。
  `step/4` 用同一段函数计算 `debt_int` 与观测量 `dose`；净欠账（扣去同拍线内段的偿还）见 `step/4` 后的 `debt_micro`。
  """
  @spec dose(t(), field(), %{env: number(), feed_w: non_neg_integer()}, Catalog.t()) :: float()
  def dose(%__MODULE__{} = s, field, %{env: env, feed_w: feed_w}, %Catalog{} = catalog) do
    line(%{s | debt_micro: 0, debt_int_micro: 0}, load_ratio(s), env, [field], feed_w, catalog).dose
  end

  # 名义存续时长：τ = (E₀_op − E_min) / P_act 在拍 `tick` 内剩余的部分（无〈乱〉时为 0）。
  defp nominal_field_seconds(%__MODULE__{activity: nil}, _tick), do: 0.0

  defp nominal_field_seconds(%__MODULE__{activity: activity, born_tick: born}, tick),
    do: min(@tick_s, max(0.0, activity.duration_s - (tick - born - 1) * @tick_s))

  defp activity_mj(%__MODULE__{activity: nil}, _seconds), do: 0
  defp activity_mj(s, seconds), do: round(s.activity.power_w * seconds * 1000)

  # 本拍场实际存续的秒数：活动付足时等于名义时长；未付足时 t_eff = 实付 mJ ÷ P_act（mJ / W = ms）。
  defp field_seconds_paid(_s, due, due, nominal_s), do: nominal_s
  defp field_seconds_paid(s, paid, _due, _nominal_s), do: paid / s.activity.power_w / 1000

  # ---------------------------------------------------------------------------
  # §4.3 运行期公式（唯一定义处；报价 `Magic.Cost` 调用这里而不是复制）
  # ---------------------------------------------------------------------------

  @typedoc "§4.3 公式需要的结构几何与计价量：结构值或报价值（`structure_quote/0`）都满足。"
  @type upkeep_params :: %{
          :units => number(),
          :precision => number(),
          :volume_m3 => number(),
          :phi_cap_w => number(),
          :r_base_per_s => number(),
          optional(atom()) => term()
        }

  @doc """
  环境因子 env = 1 + a_T·max(0, (T − T_ref,env)/T_scale) + a_N·Σ (P_leak/1 kW)·max(0, 1 − d/r_N) + a_M·[嵌在固体内]（§4.3）。
  T_ref,env、T_scale、r_N 取目录 `env_temperature_ref_k`、`env_temperature_scale_k`、`env_neighbor_radius_m`。
  """
  @spec environment(number(), [%{leak_w: number(), distance_m: number()}], boolean(), Catalog.t()) ::
          float()
  def environment(temperature_k, neighbors, embedded, %Catalog{runtime: rt}) do
    neighbor =
      Enum.sum(
        Enum.map(neighbors, fn %{leak_w: leak_w, distance_m: d} ->
          leak_w / @neighbor_power_unit_w * max(0.0, 1 - d / rt.env_neighbor_radius_m)
        end)
      )

    1 +
      rt.env_temperature_gain *
        max(0.0, (temperature_k - rt.env_temperature_ref_k) / rt.env_temperature_scale_k) +
      rt.env_neighbor_gain * neighbor + if(embedded, do: rt.env_embedded_gain, else: 0)
  end

  @doc "扰乱速度 D = D0·P·env·(1 + κ·x²)（相干度单位 / s，§4.3；P1 无承载项）。"
  @spec disruption_rate(upkeep_params(), number(), number(), Catalog.t()) :: float()
  def disruption_rate(params, x, env, %Catalog{runtime: rt}),
    do: rt.disruption_rate_per_s * params.precision * env * (1 + rt.disruption_load_gain * x * x)

  @doc "修复单价 e_r = e_r0·(1 + V/V_ref)^(2/3)（J / 相干度单位，§4.3）。"
  @spec repair_unit_cost_j(upkeep_params(), Catalog.t()) :: float()
  def repair_unit_cost_j(params, %Catalog{runtime: rt}),
    do: rt.repair_unit_cost_j * :math.pow(1 + params.volume_m3 / rt.reference_volume_m3, 2 / 3)

  @doc """
  修复上限 R_max = r_base + min(P_feed, Φ_cap) / e_r（相干度单位 / s，§4.3）；P_feed 是施法者本拍向链推送的功率，
  不是实际被接受的功率（§5.3.3 R7④）。
  """
  @spec repair_cap(upkeep_params(), number(), Catalog.t()) :: float()
  def repair_cap(params, feed_w, %Catalog{} = catalog),
    do: params.r_base_per_s + min(feed_w, params.phi_cap_w) / repair_unit_cost_j(params, catalog)

  @doc """
  运行损耗 P_run = ρ_run·b0·max(b_floor, S·P + V/V_ref + E/E_ref)^α（W，§4.3；底数下限见 §11.4.7）。
  `load_mj` 是总装载 E = E_op + |E_th|（整数 mJ）。
  """
  @spec running_loss_w(upkeep_params(), integer(), Catalog.t()) :: float()
  def running_loss_w(params, load_mj, %Catalog{runtime: rt, construction: c}) do
    rt.run_loss_ratio * c.b0_w *
      :math.pow(
        max(
          c.b_floor,
          params.units * params.precision + params.volume_m3 / rt.reference_volume_m3 +
            load_mj / 1000 / c.e_ref_j
        ),
        c.alpha
      )
  end

  @doc """
  稳态线 x* = √(max(0, (R_max / (D0·P·env) − 1) / κ))，上限 1（§4.3）；R_max 见 `repair_cap/3`。
  """
  @spec steady_load(upkeep_params(), number(), number(), Catalog.t()) :: float()
  def steady_load(params, env, feed_w, %Catalog{runtime: rt} = catalog) do
    ratio =
      repair_cap(params, feed_w, catalog) / (rt.disruption_rate_per_s * params.precision * env)

    min(1.0, :math.sqrt(max(0.0, (ratio - 1) / rt.disruption_load_gain)))
  end

  # ---------------------------------------------------------------------------
  # 条件求值（§5.4）
  # ---------------------------------------------------------------------------

  @doc """
  按脏标记求值全部规则，返回 `{新结构, 触发列表}`（按优先级升序）。热拍由 `step/4` 在第 12 步调用；
  投射物命中时 World 以 `contact: true` 直接调用（`tick` 取当前热提交拍号）。

  - 何时求值（脏）：〈遇〉有待决接触时；〈时〉到期拍起、直到被消费；〈满〉的 1/32 量化读数成立状态相对上次量化值
    改变时（首次求值必求）。
  - 越线失准：debt > 0 时以 p = min(dropout_max, debt / dropout_debt_scale) 判为无法判定，伪随机只用
    hash(id, tick)（§5.8 R8）。丢失作用于全部读数，且**不消费读数**（§5.4 R5）：接触、到期保持待决，〈满〉不更新
    上次量化值，下一拍重新求值，直到某一拍未丢失或结构终止。
  - 未丢失的求值消费本规则的全部读数：满足则执行响应；未满足时若规则的 `backup` 为 `:unmet` 则执行〈否〉内联响应。
    丢失时若 `backup` 为 `:undecidable` 则执行〈否〉内联响应，读数照样保持待决。
  - 每拍每条规则至多触发一次（本拍已触发的规则不再求值，新到的接触保持待决）；触发预算与推迟队列跨结构，由 World 持有。
  """
  @spec evaluate_rules(t(), %{contact: boolean()}, non_neg_integer(), Catalog.t()) ::
          {t(), [trigger()]}
  def evaluate_rules(%__MODULE__{status: :running} = s, %{contact: contact}, tick, %Catalog{
        runtime: rt
      }) do
    lost = reading_lost?(s, tick, rt)

    {rules, triggered} =
      Enum.map_reduce(s.rules, [], fn rule, acc ->
        observed = Enum.map(rule.readings, &observe(&1, s, contact, tick, rt))
        pending = %{rule | readings: Enum.map(observed, & &1.pending)}

        if rule.fired_tick == tick or not Enum.any?(observed, & &1.dirty) do
          {pending, acc}
        else
          {outcome, rule} =
            cond do
              lost -> {:undecidable, pending}
              Enum.all?(observed, & &1.holds) -> {:met, consumed(rule, observed)}
              true -> {:unmet, consumed(rule, observed)}
            end

          case responses(rule, outcome) do
            [] ->
              {rule, acc}

            responses ->
              {%{rule | fired_tick: tick},
               [%{priority: rule.priority, outcome: outcome, responses: responses} | acc]}
          end
        end
      end)

    {%{s | rules: rules}, Enum.reverse(triggered)}
  end

  defp consumed(rule, observed), do: %{rule | readings: Enum.map(observed, & &1.consumed)}

  defp responses(rule, :met), do: rule.responses
  defp responses(%{backup: outcome, backup_response: response}, outcome), do: [response]
  defp responses(_rule, _outcome), do: []

  # 一个读数在本拍的观察：`pending` 为不消费时的新状态（吸收本拍新事件），`consumed` 为被未丢失的求值消费后的状态，
  # `dirty` 为本拍是否需要求值，`holds` 为条件是否成立。
  defp observe(%{kind: :contact} = reading, _s, contact, _tick, _rt) do
    pending = reading.pending or contact

    %{
      pending: %{reading | pending: pending},
      consumed: %{reading | pending: false},
      dirty: pending,
      holds: pending
    }
  end

  defp observe(%{kind: :timer, due_tick: due} = reading, _s, _contact, tick, _rt) do
    due? = tick >= due

    %{
      pending: reading,
      consumed: %{reading | done: due?},
      dirty: due? and not reading.done,
      holds: due?
    }
  end

  defp observe(%{kind: :load} = reading, s, _contact, _tick, rt) do
    value = if reading.quantity == :load, do: load_ratio(s), else: coherence(s, rt)
    q = floor(value * @load_steps)
    holds = holds?(reading, q)

    %{
      pending: reading,
      consumed: %{reading | last_q: q},
      dirty: reading.last_q == nil or holds?(reading, reading.last_q) != holds,
      holds: holds
    }
  end

  defp holds?(%{dir: :above, threshold: threshold}, q), do: q / @load_steps > threshold
  defp holds?(%{dir: :below, threshold: threshold}, q), do: q / @load_steps < threshold

  defp reading_lost?(%__MODULE__{debt_micro: 0}, _tick, _rt), do: false

  defp reading_lost?(s, tick, rt),
    do: unit_draw(s.id, tick) < min(rt.dropout_max, s.debt_micro / @micro / rt.dropout_debt_scale)

  # 设计 §5.8（v2.7 R8）规定的计数器式伪随机（对照 Salmon et al., SC 2011）：SplitMix64 终混函数 mix64
  # （Steele, Lea & Flood, OOPSLA 2014，即 Java SplittableRandom 的 mix64）依次吸收 seq、n、tick：
  # h = mix64(mix64(mix64(seq) xor n) xor tick)，u = (h >> 11) / 2^53 ∈ [0, 1)。纯整数运算，跨平台逐位一致。
  @mask64 0xFFFF_FFFF_FFFF_FFFF
  defp unit_draw({seq, n}, tick) do
    h = seq |> mix64() |> Bitwise.bxor(n) |> mix64() |> Bitwise.bxor(tick) |> mix64()
    Bitwise.bsr(h, 11) / 9_007_199_254_740_992
  end

  defp mix64(z) do
    z = Bitwise.band(z + 0x9E37_79B9_7F4A_7C15, @mask64)
    z = Bitwise.band(Bitwise.bxor(z, Bitwise.bsr(z, 30)) * 0xBF58_476D_1CE4_E5B9, @mask64)
    z = Bitwise.band(Bitwise.bxor(z, Bitwise.bsr(z, 27)) * 0x94D0_49BB_1331_11EB, @mask64)
    Bitwise.bxor(z, Bitwise.bsr(z, 31))
  end

  # ---------------------------------------------------------------------------
  # 派生量
  # ---------------------------------------------------------------------------

  @doc "热内核看到的端口温度 T_port = T_ref + E_th / C_th（§5.2）；无热耦合时为 `nil`。"
  @spec port_temperature(t()) :: float() | nil
  def port_temperature(%__MODULE__{c_th_j_per_k: nil}), do: nil
  def port_temperature(%__MODULE__{} = s), do: s.t_ref_k + s.e_th_mj / 1000 / s.c_th_j_per_k

  # 总装载 E = E_op + |E_th|（mJ）与装载比 x = E / E_cap（§4.3、§5.2）。
  defp load_mj(s), do: s.e_op_mj + abs(s.e_th_mj)
  defp load_ratio(s), do: load_mj(s) / s.e_cap_mj

  # 相干度 C = 1 − c_d·debt（§4.3）。
  defp coherence(s, rt), do: 1 - rt.coherence_loss_per_debt * s.debt_micro / @micro

  defp stored_mj(s), do: s.e_op_mj + s.e_th_mj + s.kinetic_mj + s.pending_leak_mj

  defp add_out(a, b), do: Map.merge(a, b, fn _key, x, y -> x + y end)

  defp ledger(before, s, inflow, outflow) do
    %{
      stored_before_mj: before,
      stored_after_mj: stored_mj(s),
      in: Map.merge(%{heat_mj: 0, feed_mj: 0}, inflow),
      out: Map.merge(Map.new(@out_keys, &{&1, 0}), outflow),
      heat_rounding_mj: 0.0
    }
  end
end
