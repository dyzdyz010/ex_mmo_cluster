defmodule VoxelRegion.Magic.Cost do
  @moduledoc """
  全局系统功能（魔法）：施法成本、前摇时长与分阶段失败的唯一实现。纯值计算，不读 World；报价（action 0）与施放共用
  同一函数，客户端只显示服务端报价，不复制公式。现有两套：

  ## 结构报价（符号组合魔法 v2，切片 0b；目录 v5）

  `quote_structure/3` 按设计 v2.7（TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`，下称“设计”）
  §4.2 计价、§4.4 容量、§3.3 数值检查、§11.4.7 整数公式给出一个结构组的报价；`staged_failure/3` 按 §5.5 / §3.6
  判定建构在第几步中断、只结算第 1..k 步。落地决策见 `docs/10-active/magic/2026-11-19-glyph-v2-server-landing.md`.

  ```mermaid
  flowchart LR
    P["%Program{} 结构组<br/>（已过字节与签名）"] --> Q[quote_structure/3]
    Site[施放处读数<br/>温度·形成距离·热环境] --> Q
    Q -->|报价：造价·前摇·各步累计·rejects| F["staged_failure/3<br/>(余额, Ω_eff)"]
    Q -->|Structure 读的字段| S[Structure.new/4]
    S -.->|§4.3 公式（唯一定义）| Q
  ```

  - **构造顺序**（§3.5）：段序固定（形成锚 → 参考锚 → 形 → 质 → 能 → 动 → 应）；段内从上一字形起按“最近姿态优先”
    贪心，并列时按目录序（即规范字节序）；规则按优先级，每条依次是读数段、响应段、〈否〉内联响应。
  - **逐步计价**（§4.2、§11.4.7）：q_0 = 目录 `rest_pose`，d_i = ‖q_i − q_{i−1}‖₂；S_i、P_i 为前 i 步的单元与精度
    （P = 1 + Σπ），体积项 V/V_ref 在〈形〉一步加入，H_i 为前 i 步物理能量；
    b_i = b0·max(b_floor, S_i·P_i + V_i/V_ref + H_i/E_ref)^α；调整 T_adj = d_i·√(η/b_i)、注能 T_inj = E_i / P_max、
    本步损耗 L_i = 2·d_i·√(η·b_i) + b_i·T_inj；出手前置 hold = b_final·release_lead_s 计入最后一步。
  - **物理能量**（§4.2 第 3 条、§11.4.7，整数 mJ）：〈蓄〉一步 E₀_op；〈热〉一步 max(0, E_th0)；〈投〉一步动能。
    E_th0_mJ = mass_g·c·(t0_dk − T_ref_dk)/10，T_ref_dk = round(T_amb·10)；E_kin_mJ = round(mass_g·v_mmps²/2e6)。
  - **入账**：总支出 = E_phys（整数）+ round(ΣL_i + hold)（f64 按公式书写次序求值，四舍五入、半数远离零到 mJ），
    残差 `loss_rounding_mj` 交 World 记入分区账目 `structure_rounding_mj`（§5.8）。
  - **运行期量**：x*、出生维持、T13 首拍出账与 `life_s` 全部经 `Magic.Structure` 公开的 §4.3 公式计算，不复制。
  - **数值检查**（§3.3，只在服务端）：只做本组符号在目录 `numeric_checks` 中声明过的检查，结果全部列在 `rejects`。

  ## v4 报价（迁移期保留，切片 1 删除）

  `quote/3`、`misfire/3`、`draw/4`：Voxim Docs/Magic.md §4、§13.6 的旧程序报价、二值走火与取能整数分账；`world/casting.ex`
  与 NPC 法术仍在用。退出条件同 `Program` 的 v1 JSON：切片 1 第 4 项（施放结算改为构造结构）落地。
  """

  alias VoxelRegion.Magic.{Catalog, Semblance, Signature, Structure}
  alias VoxelRegion.Magic.Program
  alias VoxelRegion.Magic.Program.{Glyph, Group}

  # 斯特藩–玻尔兹曼常数（CODATA 2018 精确值），与热内核 `native/voxim_thermal/src/kernel.rs` 的 SIGMA 同值。
  @stefan_boltzmann 5.670374419e-8
  # 热内核显式稳定步长系数：dt ≤ 0.45·C / g（`kernel.rs` 的 `stable_dt`）；T15 按同一式检查（设计 §3.3、A.7）。
  @kernel_stability_factor 0.45
  # 接触面积的形状系数：球取内切圆占外切正方形投影的 π/4，块与板整面（与 `Semblance.contact/2` 同一几何）。
  @footprint %{"sphere" => :math.pi() / 4, "block" => 1.0, "plate" => 1.0}

  @typedoc """
  施放处读数（World 在报价时提供）：

  - `ambient_k`：施法处环境温度（K，f64）。量化为 T_ref_dk 存入结构（§11.4.7），也决定 env 与 `life_s`（§4.2 口径：
    只按施法者所在格温度，不含邻近干扰）。
  - `formation_distance_m`：施法者到形成位置的距离（〈握〉为 0；〈附〉为准星格面），T6 `domain` 用。
  - `emissivity`、`exchange_w_per_m2_k`：World 热环境的发射率与线性换热系数（`world/thermal.ex` 的 `emissivity`、
    `environment_w_per_m2_k`），T15 `thermal_step` 的 g_max 用（设计 A.7“实算用 World 的值”）。
  """
  @type site :: %{
          ambient_k: number(),
          formation_distance_m: number(),
          emissivity: number(),
          exchange_w_per_m2_k: number()
        }

  @typedoc """
  一条数值检查违规：检查名（§3.3：`:capacity` T5、`:domain` T6、`:first_tick` T13、`:ambient_floor` T14、
  `:thermal_step` T15）与比较的两侧数值。数值检查是组级的，按上述顺序排列。
  """
  @type reject :: %{check: atom(), detail: map()}

  @typedoc """
  构造的一步（1 起，按 §3.5 的自动顺序）：符号 id 与部件序号（与签名的 `part_index` 同一编号）、调整与注能时长（s）、
  到本步为止的建构复杂度 S_i·P_i（与 Ω_eff 比较）与累计支出（整数 mJ，最后一步含出手前置）。
  """
  @type step :: %{
          symbol: String.t(),
          part_index: non_neg_integer(),
          adjust_s: float(),
          inject_s: float(),
          complexity: number(),
          spent_mj: non_neg_integer()
        }

  # ===========================================================================
  # 结构报价（v2）
  # ===========================================================================

  @doc """
  一个结构组的报价。输入是已过字节层与签名层的合法程序（P1 只有 1 个结构组；多组的计价规则随 P2 定，此处函数子句
  不匹配即显式失败）。

  参数与原决策稿 `quote_structure/4` 的差异及理由：施法者分辨 Ω_eff 不进报价，只交给 `staged_failure/3`——设计 §4.1
  要求报价时用当前 Ω_eff、出手时用出手瞬间的 Ω_eff 重裁，同一份报价要能按两个值判定；施放处读数合并为 `site/0`，
  因为 T6 需要形成距离、T15 需要 World 的热环境系数，二者都不在目录里。

  返回的报价包含：

  - Structure 读的字段（`Structure.structure_quote/0`）：`units`、`precision`、`volume_m3`、`e_cap_mj`、`e_min_mj`、
    `phi_cap_w`、`r_base_per_s`、`e_th0_mj`、`c_th_j_per_k`、`t_ref_k`、`kinetic_mj`。
  - 计价：`physical_mj`、`loss_mj`、`total_mj`（= 二者之和，施放成功时向施法者扣的整数）、`loss_rounding_mj`、
    `windup_s`、`steps`（`step/0` 列表）。
  - 运行期报价（§4.2，显示用 f64，不入账）：`x0`、`x_star`、`p_maint_w`（出生时运行 + 修复 + 发光 + 活动）、
    `first_tick_min_mj`（撑过第一拍所需的最小 E₀_op，即 T13 的右侧，编辑器提示“至少需要 N J”）、`life_s`（能量切片
    求积；带热耦合者为保守下界）。
  - `rejects`：全部数值检查违规（`reject/0`）；空表即可施放。
  """
  @spec quote_structure(Program.t(), Catalog.t(), site()) :: map()
  def quote_structure(
        %Program{kind: :structure, groups: [%Group{} = group]},
        %Catalog{} = catalog,
        site
      ) do
    %{runtime: rt} = catalog
    placed = placements(group, catalog)
    shape = glyph(group.shape, "form.semblance")
    {volume, area} = geometry(shape.params)
    units = Enum.sum(Enum.map(placed, & &1.units))
    precision = 1 + Enum.sum(Enum.map(placed, & &1.precision))
    t_ref_dk = round(site.ambient_k * 10)
    thermal = thermal(group, shape.params, t_ref_dk, catalog)
    energy = glyph(group.energy, "energy.load").params["energy_mj"]
    kinetic = kinetic_mj(shape.params["mass_g"], find(group.motion, "act.throw"))

    upkeep = %{
      units: units,
      precision: precision,
      volume_m3: volume,
      e_cap_mj: round(rt.storage_density_j_per_m3 * volume * grade(group, "storage", rt) * 1000),
      e_min_mj: round(rt.min_energy_per_complexity_j * units * precision * 1000),
      phi_cap_w: rt.throughput_density_w_per_m2 * area,
      r_base_per_s: rt.repair_rate_per_s * hd(rt.repair_quality) * grade(group, "repair", rt),
      e_th0_mj: thermal.e_th0_mj,
      c_th_j_per_k: thermal.c_th_j_per_k,
      t_ref_k: t_ref_dk / 10,
      kinetic_mj: kinetic
    }

    physical = %{
      "energy.load" => energy,
      "cpl.thermal" => max(0, thermal.e_th0_mj),
      "act.throw" => kinetic
    }

    construction = construction(placed, physical, volume, catalog)
    runtime = runtime(group, upkeep, site, catalog)

    upkeep
    |> Map.merge(construction)
    |> Map.merge(runtime)
    |> Map.put(
      :rejects,
      rejects(placed, group, upkeep, thermal, runtime, shape.params, site, catalog)
    )
  end

  @doc """
  分阶段失败（设计 §5.5、§3.6；取代二值的 `misfire/3`）：按构造顺序找第一步 k，使到第 k 步为止的建构复杂度
  S_k·P_k 超过 `resolution`（Ω_eff），或到第 k 步为止的累计支出超过可用余额 `available_mj`。

  返回 `nil`（建成，按报价 `total_mj` 结算），或 `{k, spent_mj}`：k 从 1 起；第 1..k 步的注能与构型损耗照付，
  余额不足时付到耗尽为止，即 spent_mj = min(可用余额, 第 k 步累计支出)。其余步不发生、不扣费。
  """
  @spec staged_failure(map(), integer(), number()) :: nil | {pos_integer(), non_neg_integer()}
  def staged_failure(%{steps: steps}, available_mj, resolution) do
    steps
    |> Enum.with_index(1)
    |> Enum.find_value(fn {step, k} ->
      if step.complexity > resolution or step.spent_mj > available_mj,
        do: {k, min(available_mj, step.spent_mj)}
    end)
  end

  # ---- 部件与构造顺序（§3.5）----

  # 本组全部部件，按构造顺序排好：{符号, glyph, 部件序号, 单元, 精度}。部件序号是规范字节中的 0 起序号（签名同一编号）。
  defp placements(%Group{} = group, catalog) do
    segments =
      [
        [group.form_anchor],
        group.ref_anchors,
        group.shape,
        group.quality,
        group.energy,
        group.motion
      ] ++
        Enum.flat_map(group.rules, &[&1.readings, &1.responses, List.wrap(&1.backup_response)])

    {segments, _} =
      Enum.map_reduce(segments, 0, fn glyphs, next ->
        {Enum.with_index(glyphs, next), next + length(glyphs)}
      end)

    {ordered, _} =
      Enum.flat_map_reduce(segments, catalog.construction.rest_pose, fn segment, pose ->
        nearest_first(segment, pose, catalog, [])
      end)

    ordered
  end

  # 段内贪心：每次取与上一字形姿态最近的部件；`Enum.min_by` 在并列时取列表中靠前者，即目录序（规范字节序）。
  defp nearest_first([], pose, _catalog, acc), do: {Enum.reverse(acc), pose}

  defp nearest_first(segment, pose, catalog, acc) do
    {glyph, part_index} =
      next =
      Enum.min_by(segment, fn {glyph, _} -> distance(catalog.symbols[glyph.index].pose, pose) end)

    symbol = catalog.symbols[glyph.index]

    part = %{
      symbol: symbol.id,
      glyph: glyph,
      part_index: part_index,
      pose: symbol.pose,
      distance: distance(symbol.pose, pose),
      units: by_param(symbol.units_by_param, glyph, symbol, symbol.units),
      precision: by_param(symbol.precision_by_param, glyph, symbol, symbol.precision)
    }

    nearest_first(List.delete(segment, next), symbol.pose, catalog, [part | acc])
  end

  # 计价的 `*_by_param` 命中时取代基值（schema 文档 §5）；一个符号至多一个槽命中，多处命中即目录数据不合规，显式失败。
  defp by_param(table, glyph, symbol, base) do
    case Signature.by_param_values(table, glyph, symbol) do
      [] -> base
      [value] -> value
    end
  end

  defp distance(a, b), do: :math.sqrt(Enum.sum(Enum.zip_with(a, b, &((&1 - &2) ** 2))))

  # ---- 逐步计价（§4.2、§11.4.7）----

  defp construction(placed, physical, volume, %Catalog{
         runtime: rt,
         construction: c,
         caster: caster
       }) do
    start = %{units: 0, precision: 1, volume: 0.0, physical_mj: 0, loss_j: 0.0, b_w: nil}

    {steps, last} =
      Enum.map_reduce(placed, start, fn part, acc ->
        energy_mj = Map.get(physical, part.symbol, 0)
        units = acc.units + part.units
        precision = acc.precision + part.precision
        volume_term = if part.symbol == "form.semblance", do: volume, else: acc.volume
        physical_mj = acc.physical_mj + energy_mj

        b =
          c.b0_w *
            :math.pow(
              max(
                c.b_floor,
                units * precision + volume_term / rt.reference_volume_m3 +
                  physical_mj / 1000 / c.e_ref_j
              ),
              c.alpha
            )

        inject_s = energy_mj / 1000 / caster.max_power_w

        loss_j =
          acc.loss_j + (2 * part.distance * :math.sqrt(c.eta_j_s_per_rad2 * b) + b * inject_s)

        step = %{
          symbol: part.symbol,
          part_index: part.part_index,
          adjust_s: part.distance * :math.sqrt(c.eta_j_s_per_rad2 / b),
          inject_s: inject_s,
          complexity: units * precision,
          spent_mj: physical_mj + round(loss_j * 1000)
        }

        {step,
         %{
           acc
           | units: units,
             precision: precision,
             volume: volume_term,
             physical_mj: physical_mj,
             loss_j: loss_j,
             b_w: b
         }}
      end)

    # 出手前置：最终定形到出手帧的维护 b_final·release_lead_s，计入最后一步。
    loss_j = last.loss_j + last.b_w * c.release_lead_s
    loss_mj = round(loss_j * 1000)
    steps = List.update_at(steps, -1, &%{&1 | spent_mj: last.physical_mj + loss_mj})

    %{
      physical_mj: last.physical_mj,
      loss_mj: loss_mj,
      total_mj: last.physical_mj + loss_mj,
      loss_rounding_mj: loss_j * 1000 - loss_mj,
      windup_s: Enum.sum(Enum.map(steps, &(&1.adjust_s + &1.inject_s))) + c.release_lead_s,
      steps: steps
    }
  end

  # ---- 形、热、动的整数量（§11.4.7）----

  # 体积与表面积：球（半径）；块与板（三轴半边长，板的第三轴为半厚，§2.3）。
  defp geometry(%{"shape" => "sphere", "size1_mm" => r_mm}) do
    r = r_mm / 1000
    {4 / 3 * :math.pi() * r ** 3, 4 * :math.pi() * r ** 2}
  end

  defp geometry(%{"size1_mm" => a_mm, "size2_mm" => b_mm, "size3_mm" => c_mm}) do
    {a, b, c} = {a_mm / 1000, b_mm / 1000, c_mm / 1000}
    {8 * a * b * c, 8 * (a * b + b * c + c * a)}
  end

  # 〈热〉：E_th0_mJ = mass_g·c·(t0_dk − T_ref_dk)/10（整数；c 为奇数时对商四舍五入）；C_th = mass_g·c/1000 J/K。
  # 签名保证写〈热〉必有质量（`requires_all: mass`）。
  defp thermal(group, shape, t_ref_dk, %Catalog{semblance: %{specific_heat_j_per_kg_k: c}}) do
    case find(group.quality, "cpl.thermal") do
      %Glyph{params: %{"t0_dk" => t0_dk}} ->
        mass_g = shape["mass_g"]

        %{
          e_th0_mj: div_round(mass_g * c * (t0_dk - t_ref_dk), 10),
          c_th_j_per_k: mass_g * c / 1000,
          t0_dk: t0_dk,
          t_ref_dk: t_ref_dk
        }

      nil ->
        %{e_th0_mj: 0, c_th_j_per_k: nil, t0_dk: nil, t_ref_dk: t_ref_dk}
    end
  end

  # 动能 E_kin_mJ = round(mass_g·v_mmps²/2 000 000)；无质量或无〈投〉为 0。
  defp kinetic_mj(mass_g, %Glyph{params: %{"speed_mmps" => v}}) when is_integer(mass_g),
    do: div_round(mass_g * v * v, 2_000_000)

  defp kinetic_mj(_mass_g, _throw), do: 0

  # 〈容〉等级倍率（§4.4 g_E、§4.3 g_R）：目录 `grade_multipliers` 按等级 1..3 取；未写该种〈容〉为 1 级。
  defp grade(group, kind, rt) do
    case Enum.find(group.quality, &(&1.id == "cpl.capacity" and &1.params["cap_kind"] == kind)) do
      %Glyph{params: %{"grade" => grade}} -> Enum.at(rt.grade_multipliers, grade - 1)
      nil -> hd(rt.grade_multipliers)
    end
  end

  # ---- 运行期报价（§4.2、§4.3，经 Structure 的公式）----

  defp runtime(group, upkeep, site, catalog) do
    # 出生时的结构（报价用的出生值，不进入世界，id 无意义）：发光、活动与出生装载都从这里读。
    born = Structure.new({0, 0}, group, upkeep, 0)
    env = Structure.environment(site.ambient_k, [], false, catalog)
    activity_w = if born.activity, do: born.activity.power_w, else: 0
    tick_s = Structure.tick_ms() / 1000
    born_load = born.e_op_mj + abs(born.e_th_mj)
    born_upkeep_w = upkeep_w(upkeep, born_load, env, catalog)

    # 出生一拍的运转出账（T13）：运行 + 修复 + 发光按整拍，活动按本拍内的存续（τ 可能短于一拍）。
    first_tick_j =
      (born_upkeep_w + born.glow_w) * tick_s +
        activity_w * min(tick_s, if(born.activity, do: born.activity.duration_s, else: 0))

    %{
      x0: born_load / upkeep.e_cap_mj,
      x_star: Structure.steady_load(upkeep, env, 0, catalog),
      p_maint_w: born_upkeep_w + born.glow_w + activity_w,
      first_tick_min_mj: upkeep.e_min_mj + round(first_tick_j * 1000),
      life_s: life_s(born, upkeep, env, born.glow_w + activity_w, catalog)
    }
  end

  # 运行 + 修复损耗（W）：P_run(E) + e_r·min(D, R_max)，D 按装载 x = E / E_cap（§4.3；P1 无供能）。
  defp upkeep_w(upkeep, load_mj, env, catalog) do
    x = load_mj / upkeep.e_cap_mj

    Structure.running_loss_w(upkeep, load_mj, catalog) +
      Structure.repair_unit_cost_j(upkeep, catalog) *
        min(
          Structure.disruption_rate(upkeep, x, env, catalog),
          Structure.repair_cap(upkeep, 0, catalog)
        )
  end

  # 预计寿命（§4.2，C1-13）：能量切片求积 Σ h / drain(E_min + (k + ½)·h)，h = (E₀_op − E_min) / n，n = 目录
  # `quote_life_slices`；drain(E) = P_run + P_rep + 发光 + 活动 − 供能（P1 无供能），热份额按出生值计。
  defp life_s(born, upkeep, env, fixed_w, %Catalog{runtime: rt} = catalog) do
    slices = rt.quote_life_slices
    h_mj = (born.e_op_mj - upkeep.e_min_mj) / slices

    if h_mj <= 0 do
      0.0
    else
      Enum.sum(
        for k <- 0..(slices - 1) do
          load_mj = upkeep.e_min_mj + (k + 0.5) * h_mj + abs(born.e_th_mj)
          h_mj / 1000 / (upkeep_w(upkeep, load_mj, env, catalog) + fixed_w)
        end
      )
    end
  end

  # ---- 数值检查（§3.3）----

  @checks [
    {"capacity", :capacity},
    {"domain", :domain},
    {"first_tick", :first_tick},
    {"ambient_floor", :ambient_floor},
    {"thermal_step", :thermal_step}
  ]

  defp rejects(placed, group, upkeep, thermal, runtime, shape, site, catalog) do
    declared =
      MapSet.new(placed, & &1.glyph.index) |> Enum.flat_map(&catalog.symbols[&1].numeric_checks)

    for {name, check} <- @checks,
        name in declared,
        detail <- violations(check, group, upkeep, thermal, runtime, shape, site, catalog),
        do: %{check: check, detail: detail}
  end

  # T5：E₀_op + |E_th0| ≤ E_cap；〈辉〉功率 ≤ Φ_cap（〈链〉功率为 P2）。
  defp violations(:capacity, group, upkeep, _thermal, _runtime, _shape, _site, _catalog) do
    load_mj = glyph(group.energy, "energy.load").params["energy_mj"] + abs(upkeep.e_th0_mj)
    glow_w = Enum.find_value(group.quality, 0, &(&1.id == "cpl.glow" && &1.params["power_w"]))

    [
      load_mj > upkeep.e_cap_mj && %{load_mj: load_mj, e_cap_mj: upkeep.e_cap_mj},
      glow_w > upkeep.phi_cap_w && %{glow_w: glow_w, phi_cap_w: upkeep.phi_cap_w}
    ]
    |> Enum.filter(& &1)
  end

  # T6：形成位置须在本地施法域内（P1 没有〈传〉）。
  defp violations(:domain, _group, _upkeep, _thermal, _runtime, _shape, site, catalog) do
    limit = catalog.limits.local_domain_m

    if site.formation_distance_m > limit,
      do: [%{distance_m: site.formation_distance_m, local_domain_m: limit}],
      else: []
  end

  # T13：E₀_op ≥ E_min + 出生一拍的运转出账（整数 mJ 比较）。
  defp violations(:first_tick, group, _upkeep, _thermal, runtime, _shape, _site, _catalog) do
    energy = glyph(group.energy, "energy.load").params["energy_mj"]

    if energy < runtime.first_tick_min_mj,
      do: [%{e_op_mj: energy, required_mj: runtime.first_tick_min_mj}],
      else: []
  end

  # T14（P1）：〈热〉的 T0 ≥ 施法处环境温度（同为 0.1 K 整数）。
  defp violations(:ambient_floor, _group, _upkeep, thermal, _runtime, _shape, _site, _catalog) do
    if thermal.t0_dk < thermal.t_ref_dk,
      do: [%{t0_dk: thermal.t0_dk, t_ref_dk: thermal.t_ref_dk}],
      else: []
  end

  # T15：热节点显式稳定步长 0.45·C_th / g_max ≥ thermal_step_min_ms（设计 §3.3、A.7）；
  # g_max = 接触上限 + 4σε·A·T_chk³ + h·A。
  defp violations(:thermal_step, _group, upkeep, _thermal, _runtime, shape, site, catalog) do
    %{runtime: rt, semblance: %{thermal_conductivity_w_per_m_k: k}} = catalog
    {_volume, area} = geometry(shape)

    g_max =
      contact_conductance(shape, k) +
        4 * @stefan_boltzmann * site.emissivity * area * rt.thermal_check_temperature_k ** 3 +
        site.exchange_w_per_m2_k * area

    step_ms = @kernel_stability_factor * upkeep.c_th_j_per_k / g_max * 1000

    if step_ms < rt.thermal_step_min_ms,
      do: [
        %{
          step_ms: step_ms,
          min_ms: rt.thermal_step_min_ms,
          c_th_j_per_k: upkeep.c_th_j_per_k,
          g_max_w_per_k: g_max
        }
      ],
      else: []
  end

  # 接触导热上限：沿每个轴取“该轴接触面积 / 该轴半程”的最大值乘拟态导热率。接触面积 = 包围盒另两轴的全长之积 ×
  # 形状系数，路径 = 该轴半程（`Semblance.conductance/5` 的 r / k_s 同一串联式的拟态一侧）。球得 k·πr²/r = k·π·r（A.7）。
  defp contact_conductance(%{"shape" => "sphere", "size1_mm" => r}, k),
    do: box_conductance("sphere", {r, r, r}, k)

  defp contact_conductance(
         %{"shape" => shape, "size1_mm" => a, "size2_mm" => b, "size3_mm" => c},
         k
       ),
       do: box_conductance(shape, {a, b, c}, k)

  # 半边长 {a, b, c}（mm）。
  defp box_conductance(shape, {a, b, c}, k) do
    [{a, b, c}, {b, c, a}, {c, a, b}]
    |> Enum.map(fn {half, u, v} ->
      2 * u / 1000 * (2 * v / 1000) * @footprint[shape] / (half / 1000)
    end)
    |> Enum.max()
    |> Kernel.*(k)
  end

  # ---- 小工具 ----

  defp glyph(glyphs, id), do: find(glyphs, id) || raise(ArgumentError, "结构组缺少 #{id}")
  defp find(glyphs, id), do: Enum.find(glyphs, &(&1.id == id))

  # 整数除法，四舍五入、半数远离零（§11.4.7 round_half_away）。
  defp div_round(numerator, denominator)
       when is_integer(numerator) and is_integer(denominator) and denominator > 0 do
    quotient = div(abs(numerator), denominator)

    quotient =
      if rem(abs(numerator), denominator) * 2 >= denominator, do: quotient + 1, else: quotient

    if numerator < 0, do: -quotient, else: quotient
  end

  # ===========================================================================
  # v4 报价（迁移期保留，切片 1 删除）
  # ===========================================================================

  @doc """
  v4 程序报价：结构权重、物理能量、构型损耗、总支出（J）、前摇（s）与各步 `{调整 s, 注能 s}`。
  含拟态的程序需给出环境温度 `ambient_k`。

  - 物理能量 E_phys：`energy.draw` 为 0，`act.heat` 为其 `energy_j`；`form.semblance` 为热内容 C·(T − T_amb) 加发光
    预算 glow_w × lifetime_s；`act.throw` 为动能 ½·m·v²；`act.dispel` 与 `act.break_on_hit` 为 0。
  - 构型损耗（§13.6）：d_i = ‖q_i − q_{i−1}‖₂，b_i = b0·(S_i + H_i/E_ref)^α，T_adj = d_i·√(η/b_i)，T_inj = E_i / P_max，
    L_i = 2·d_i·√(η·b_i) + b_i·T_inj；前摇 = Σ(T_adj + T_inj) + release_lead_s，E_loss = Σ L_i + b_final·release_lead_s。
  """
  def quote(%{steps: steps}, catalog, ambient_k \\ nil) do
    form =
      Enum.find_value(steps, fn %{sym: sym, args: args} -> sym == "form.semblance" && args end)

    {parts, {_, structure, stored}} =
      Enum.map_reduce(steps, {catalog.rest_pose, 0.0, 0.0}, fn %{sym: sym} = step,
                                                               {previous, s, h} ->
        symbol = catalog.symbols[sym]
        energy = physical_j(step, form, catalog, ambient_k)
        {s, h} = {s + symbol.weight, h + energy}
        d = :math.sqrt(Enum.sum(Enum.zip_with(symbol.pose, previous, &((&1 - &2) ** 2))))
        b = catalog.b0_w * :math.pow(s + h / catalog.e_ref_j, catalog.alpha)
        inject = energy / catalog.max_power_w
        loss = 2 * d * :math.sqrt(catalog.eta * b) + b * inject
        {{energy, d * :math.sqrt(catalog.eta / b), inject, loss}, {symbol.pose, s, h}}
      end)

    physical = Enum.sum(for {e, _, _, _} <- parts, do: e) * 1.0

    hold =
      catalog.b0_w * :math.pow(structure + stored / catalog.e_ref_j, catalog.alpha) *
        catalog.release_lead_s

    loss = Enum.sum(for {_, _, _, l} <- parts, do: l) + hold

    %{
      structure: structure,
      physical_j: physical,
      loss_j: loss,
      total_j: physical + loss,
      windup_s: Enum.sum(for {_, a, i, _} <- parts, do: a + i) + catalog.release_lead_s,
      steps: for({_, a, i, _} <- parts, do: {a, i})
    }
  end

  defp physical_j(%{sym: "act.heat", args: %{"energy_j" => energy}}, _, _, _), do: energy

  defp physical_j(%{sym: sym}, _, _, _)
       when sym in ["energy.draw", "act.dispel", "act.break_on_hit"], do: 0.0

  defp physical_j(%{sym: "form.semblance", args: form}, _, catalog, ambient),
    do: Semblance.form_j(form, catalog, ambient)

  defp physical_j(%{sym: "act.throw", args: %{"speed_mps" => v}}, form, _, _),
    do: Semblance.kinetic_j(form["mass_kg"], v)

  @doc "v4 走火判定：`nil` = 正常施放；相干度先于能量（S > 相干度 → `:misfire_coherence`，余额 < 总支出 → `:misfire_energy`）。"
  def misfire(quote, available_j, catalog) do
    cond do
      quote.structure > catalog.coherence -> :misfire_coherence
      available_j < quote.total_j -> :misfire_energy
      true -> nil
    end
  end

  @doc """
  取能分账（整数 mJ，施法者账的最小单位）：石减少 taken_mj = 施法者取得 gained_mj + 损耗 loss_mj，两端同一整数。
  入参均为整数 mJ：请求（调用方 `round(energy_j × 1000)`）、石储能（调用方 `trunc(stored_j × 1000)`）、施法者余额；
  容量取 `round(capacity_j × 1000)`；取得按 `round(η × taken_mj)`，损耗是差额。
  """
  def draw(requested_mj, stored_mj, balance_mj, catalog) do
    taken = min(requested_mj, min(stored_mj, round(catalog.capacity_j * 1000) - balance_mj))
    gained = round(catalog.draw_efficiency * taken)
    %{taken_mj: taken, gained_mj: gained, loss_mj: taken - gained}
  end
end
