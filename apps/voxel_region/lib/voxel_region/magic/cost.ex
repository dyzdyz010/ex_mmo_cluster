defmodule VoxelRegion.Magic.Cost do
  @moduledoc """
  全局系统功能（魔法）：施法成本、前摇时长与分阶段失败的唯一实现。纯值计算，不读 World；报价（action 0）与施放共用
  同一函数，客户端只显示服务端报价，不复制公式。现有两套：

  ## 结构报价（符号组合魔法 v2，切片 0b；目录 v5）

  `quote_structure/3` 按设计 v2.10（TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`，下称“设计”）
  §4.2 计价、§4.4 容量、§4.5 从零定义、§3.3 数值检查、§11.4.7 整数公式给出一个结构组的报价（施法者动作程序只有
  构造计价与 T6 施法域检查）；`staged_failure/3` 按 §5.5 / §3.6 判定建构在第几步中断、只结算第 1..k 步。落地决策见
  `docs/10-active/magic/2026-11-19-glyph-v2-server-landing.md`。

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
    本步损耗 L_i = 2·d_i·√(η·b_i) + b_i·T_inj；出手前置 hold = b_final·release_lead_s 并入最后一步（§4.2，v2.9 A6）。
  - **从零定义**（§4.5，v2.9 Q21(a)）：P1 没有〈仿〉，同组写入 c ≥ 2 类性质（目录 `property_class`）时按从零定义计价：
    单元 = Σ_{i=1..c} (1 + s_u·(i − 1))、精度 +s_p·(c − 1)、修复质量 Q = `repair_quality[2]`；s_u、s_p 取目录
    `scratch_unit_step`、`scratch_precision_step`。附加量随构造顺序累加：引入第 k 类（k ≥ 2）的那一步加 s_u·(k − 1)
    单元与 s_p 精度，此后各步的 S_i·P_i 与 Ω 判定都含它（v2.10 E3 确认）。Q 只进运行期修复，不进构造计价；
    c ≤ 1 时 Q = `repair_quality[0]`（照原型或只写一类）。
  - **物理能量**（§4.2 第 3 条、§11.4.7，整数 mJ）：〈蓄〉一步 E₀_op；〈热〉一步 max(0, E_th0)；〈投〉一步动能。
    E_th0_mJ = mass_g·c·(t0_dk − T_ref_dk)/10，T_ref_dk = round(T_amb·10)；E_kin_mJ = round(mass_g·v_mmps²/2e6)。
  - **入账**：总支出 = E_phys（整数）+ round(ΣL_i + hold)（f64 按公式书写次序求值，四舍五入、半数远离零到 mJ），
    残差 `loss_rounding_mj` 交 World 记入分区账目 `structure_rounding_mj`（§5.8）。
  - **运行期量**：x*、出生维持、T13 首拍出账、`detect_w` 与 `life_s` 全部经 `Magic.Structure` 公开的 §4.3 公式计算，
    不复制。
  - **入口**（§4.2，v2.9 A5、v2.10 E1/E2）：`entries_spoof` 数规则所读、目录 `reading_source = external` 的读数种类；
    `entries_charge` P1 恒为 0；判据见 `entries/2`。
  - **数值检查**（§3.3，只在服务端）：只做本组符号在目录 `numeric_checks` 中声明过的检查，结果全部列在 `rejects`；
    检查名与顺序取自线协议的唯一定义 `MmoContracts.Voxel.Codec.spell_reject_checks/0`。
  - **取能分账**：`draw/4`，〈取〉成功时石储能、施法者所得与损耗的整数 mJ 分账。

  v1（JSON 程序、v4 目录）的报价与二值走火已随切片 3 删除（决策稿 `2026-11-19-slice3-protocol.md` §6）。
  """

  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.Magic.{Catalog, Signature, Structure}
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
  - `formation_distance_m`：施法者到形成位置的距离（〈握〉为 0；〈附〉为准星格面），T6 `domain` 用。取能程序
    （〈取〉）的形成位置就是能源目标：取施法者眼点到目标宏格中心 (x + 0.5, y + 0.5, z + 0.5) 的欧氏距离（设计 v2.10
    E4；决策稿 `2026-11-19-slice3-protocol.md` §3.5，口径沿用原 World `spell_target` 的距离检查）。
  - `emissivity`、`exchange_w_per_m2_k`：World 热环境的发射率与线性换热系数（`world/thermal.ex` 的 `emissivity`、
    `environment_w_per_m2_k`），T15 `thermal_step` 的 g_max 用。设计 v2.9 A2 确认二者属于 World 的热环境参数、
    不进目录，报价时由 World 传入（§3.3 T15、附录 A.7），以免形成第二份真值。
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

  施法者动作程序（〈取〉，`kind: :caster_action`）不建结构，只有构造计价（设计 v2.10 E4，§4.2、附录 A.12）：`units`、
  `precision`（S·P = 1，即 0x83 的 `quote_s`）、`physical_mj`（恒为 0：〈取〉的能量来自能源，不由施法者注入）、
  `loss_mj` = `total_mj`（构型损耗 + 出手前置维护）、`loss_rounding_mj`、`windup_s`、`steps`（`staged_failure/3`
  照常判 `fail_step`），以及 `rejects`。E4 规定 `rejects` 只可能含 T6：目录〈取〉声明 `numeric_checks: ["domain"]`
  （目录加载时保证施法者动作段只能声明 `domain`），按 `site.formation_distance_m`（施法者到能源目标）与结构共用同一个
  T6 判定。施法域距离只在这里判一次，World 不再另做距离检查（决策稿 §3.5）。0x83 的其余结构类字段对它填 0（§11.4.6）。

  参数与原决策稿 `quote_structure/4` 的差异及理由：施法者分辨 Ω_eff 不进报价，只交给 `staged_failure/3`；施放处读数
  合并为 `site/0`，因为 T6 需要形成距离、T15 需要 World 的热环境系数，二者都不在目录里。报价与施放同源（设计 v2.10
  E4 第 3 条，决策稿 §3.5）：报价、前摇开始与结算时 World 各用当时的 `site` 重新调用本函数、重新判 `rejects`，再以
  同一时刻的 Ω_eff 调 `staged_failure/3`；不复用早先时刻的报价。

  返回的报价包含：

  - Structure 读的字段（`Structure.structure_quote/0`）：`units`、`precision`、`volume_m3`、`e_cap_mj`、`e_min_mj`、
    `phi_cap_w`、`r_base_per_s`、`e_th0_mj`、`c_th_j_per_k`、`t_ref_k`、`kinetic_mj`。
  - 计价：`physical_mj`、`loss_mj`、`total_mj`（= 二者之和，施放成功时向施法者扣的整数）、`loss_rounding_mj`、
    `windup_s`、`steps`（`step/0` 列表）。
  - 运行期报价（§4.2，显示用 f64，不入账）：`x0`、`x_star`、`p_maint_w`（出生时运行 + 修复 + 发光 + 活动）、
    `first_tick_min_mj`（撑过第一拍所需的最小 E₀_op，即 T13 的右侧，编辑器提示“至少需要 N J”）、`life_s`（能量切片
    求积；带热耦合、热端口高于环境者为不超过真实寿命的下界）、`detect_w`（静持可察觉功率）。
  - 入口（§4.2，v2.9 A5、v2.10 E1/E2）：`entries_charge`、`entries_spoof`（整数）。
  - `rejects`：全部数值检查违规（`reject/0`）；空表即可施放。
  """
  @spec quote_structure(Program.t(), Catalog.t(), site()) :: map()
  def quote_structure(%Program{kind: :caster_action, action: %Glyph{} = action}, catalog, site) do
    {placed, _pose} = nearest_first([{action, 0}], catalog.construction.rest_pose, catalog, [])

    %{
      units: Enum.sum(Enum.map(placed, & &1.units)),
      precision: 1 + Enum.sum(Enum.map(placed, & &1.precision)),
      # 只有施放处读数：施法者动作段只能声明 T6（目录加载时保证），T6 只读 site。
      rejects: rejects(placed, %{site: site}, catalog)
    }
    |> Map.merge(construction(placed, %{}, 0.0, catalog))
  end

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
      # Φ_cap = φ_A·A·g_Φ（§4.4）。P1 目录只发布〈热〉phi_grade = 1（槽区间 [1, 1]，v2.9 A3），g_Φ ≡ 1，
      # 所以这里不读该槽；P2 随〈容 吞吐〉开放 2、3 级时须在此乘上 g_Φ = grade_multipliers[grade − 1]
      # （v2.10 E5，§4.4，与 `grade/3` 同一张倍率表）并按 `units_by_param` 计单元。
      phi_cap_w: rt.throughput_density_w_per_m2 * area,
      r_base_per_s:
        rt.repair_rate_per_s * repair_quality(placed, rt) * grade(group, "repair", rt),
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
    |> Map.merge(entries(group, catalog))
    |> Map.put(
      :rejects,
      rejects(
        placed,
        %{
          group: group,
          upkeep: upkeep,
          thermal: thermal,
          runtime: runtime,
          shape: shape.params,
          site: site
        },
        catalog
      )
    )
  end

  @doc """
  分阶段失败（设计 §5.5、§3.6）：按构造顺序找第一步 k，使到第 k 步为止的建构复杂度 S_k·P_k 超过 `resolution`
  （Ω_eff），或到第 k 步为止的累计支出超过可用余额 `available_mj`。

  返回 `nil`（建成，按报价 `total_mj` 结算），或 `{k, spent_mj, cause}`：k 从 1 起；第 1..k 步的注能与构型损耗照付，
  其余步不发生、不扣费。设计 v2.9 A6（§4.2 报价接口约定、§5.5）确认的扣费：余额耗尽时付到耗尽为止，即
  spent_mj = min(可用余额, 第 1..k 步累计支出)；Ω 不足时扣第 1..k 步累计支出（此时余额足够，min 取后者）。
  `cause`（决策稿 P6）是 `:omega`（分辨不足）或 `:energy`（余额耗尽）；同一步两者都不满足时记 `:omega`（沿用 v1
  “相干度先于能量”的判定次序）。扣费只取决于步号，与在哪个时刻结算无关（设计 v2.11 W1）。

  出手前置维护费已并入最后一步的累计支出（见 `construction/4`）。报价、前摇开始与结算（第 k 步时刻或出手，W1）
  各调用一次，报价与 Ω_eff 都取该时刻的值：结算时先按当时的 `site` 重新 `quote_structure/3`，不复用前摇开始时的报价
  （决策稿 §3.5、设计 v2.11 W9）。只判前 k 步时，调用方传入截到前 k 步的 `steps`。
  """
  @spec staged_failure(map(), integer(), number()) ::
          nil | {pos_integer(), non_neg_integer(), :omega | :energy}
  def staged_failure(%{steps: steps} = quote, available_mj, resolution) do
    steps
    |> Enum.with_index(1)
    |> Enum.find_value(fn {step, k} ->
      cond do
        step.complexity > resolution -> Tuple.append(charge_through(quote, k, available_mj), :omega)
        step.spent_mj > available_mj -> Tuple.append(charge_through(quote, k, available_mj), :energy)
        true -> nil
      end
    end)
  end

  @doc """
  在第 k 步中断的扣费（设计 §5.5、v2.9 A6）：`{k, min(可用余额, 第 1..k 步累计支出)}`，即“第 1..k 步照付、付到耗尽为止，
  其余步不发生”。分阶段失败（`staged_failure/3`）与前摇取消、打断（决策稿 §6.1、Q6-1：按进行中的步 k 结账）共用这一处。
  k 从 1 起、不超过报价步数。
  """
  @spec charge_through(map(), pos_integer(), integer()) :: {pos_integer(), non_neg_integer()}
  def charge_through(%{steps: steps}, k, available_mj) when k >= 1 and k <= length(steps),
    do: {k, min(available_mj, Enum.at(steps, k - 1).spent_mj)}

  # ---- 部件与构造顺序（§3.5）----

  # 本组全部部件，按构造顺序排好：{符号, glyph, 部件序号, 单元, 精度, 性质类}，单元与精度已含从零定义的附加量。
  # 部件序号是规范字节中的 0 起序号（签名同一编号）。
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

    from_scratch(ordered, catalog)
  end

  # 从零定义的附加量（§4.5，v2.9 Q21(a)）：按构造顺序，引入第 k 个不同性质类（k ≥ 2）的部件加
  # scratch_unit_step·(k − 1) 单元与 scratch_precision_step 精度；合计即 s_u·c(c − 1)/2 与 s_p·(c − 1)。
  # 只写一类（或不写）时没有附加量。P1 没有〈仿〉，所以写入的性质类都按从零计；P2 的原型分组随〈仿〉一起实现。
  defp from_scratch(ordered, %Catalog{runtime: rt}) do
    {parts, _classes} =
      Enum.map_reduce(ordered, MapSet.new(), fn %{property_class: class} = part, classes ->
        if class == nil or MapSet.member?(classes, class) do
          {part, classes}
        else
          k = MapSet.size(classes) + 1

          part =
            if k >= 2,
              do: %{
                part
                | units: part.units + rt.scratch_unit_step * (k - 1),
                  precision: part.precision + rt.scratch_precision_step
              },
              else: part

          {part, MapSet.put(classes, class)}
        end
      end)

    parts
  end

  # 修复质量 Q（§4.3、§4.5）：同组写入 ≥ 2 类性质为从零定义 `repair_quality[2]`，否则 `repair_quality[0]`。
  # `repair_quality[1]`（含偏离）随 P2 的〈偏〉启用。
  defp repair_quality(placed, %{repair_quality: [whole, _deviated, scratch]}) do
    if property_classes(placed) >= 2, do: scratch, else: whole
  end

  defp property_classes(placed),
    do:
      placed
      |> Enum.map(& &1.property_class)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

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
      precision: by_param(symbol.precision_by_param, glyph, symbol, symbol.precision),
      property_class: symbol.property_class
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

    # 出手前置：最终定形到出手帧的维护 b_final·release_lead_s，并入最后一步（§4.2 报价接口约定，v2.9 A6 确认）。
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

    # 静持可察觉功率（§4.2，v2.9 A5）：leak_heat_fraction × (出生时 P_run + P_rep，env = 1) + glow_w。
    # 热端口自身的放热是效果本身，不计入；活动整笔计为灵炁辐射（§5.3.3 R3），也不计入。
    detect_w =
      catalog.runtime.leak_heat_fraction *
        upkeep_w(upkeep, born_load, 1, catalog) + born.glow_w

    %{
      x0: born_load / upkeep.e_cap_mj,
      x_star: Structure.steady_load(upkeep, env, 0, catalog),
      p_maint_w: born_upkeep_w + born.glow_w + activity_w,
      first_tick_min_mj: upkeep.e_min_mj + round(first_tick_j * 1000),
      life_s: life_s(born, upkeep, env, born.glow_w + activity_w, catalog),
      detect_w: detect_w
    }
  end

  # 入口（§4.2，v2.9 A5、v2.10 E1/E2；编辑器据此列“灌能入口 ×n、伪造信号入口 ×m”，§3.6）。
  #
  # - `entries_spoof`：规则所读、目录 `reading_source = external` 的读数种类数；同一种读数在多条规则中出现只计 1。
  #   只看这个显式字段，不从签名的耦合要求推断（v2.10 E2：P3 的〈至〉依赖参考锚而非耦合，推断会误判）。
  # - `entries_charge`：P1 恒为 0（v2.10 E1 确认）。P2 开放〈纳〉前，目录按 v2.10 E1（§4.2、§11.4.5）加入符号字段
  #   `entry` / `entry_by_param` 与 `seals`，届时这里按数据计数：本组 `entry = "charge"` 的符号数，本组有 `seals`
  #   含 "charge" 的符号则为 0。
  defp entries(%Group{rules: rules}, catalog) do
    spoof =
      rules
      |> Enum.flat_map(& &1.readings)
      |> Enum.map(&catalog.symbols[&1.index])
      |> Enum.filter(&(&1.reading_source == :external))
      |> Enum.uniq_by(& &1.index)
      |> length()

    %{entries_charge: 0, entries_spoof: spoof}
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

  # `inputs` 是检查所读的报价中间量：结构组为 group、upkeep、thermal、runtime、shape（〈形〉参数）与 site；
  # 施法者动作只有 site。每条检查只匹配自己读的键。检查顺序即线上位序（`Codec.spell_reject_checks/0`，T5、T6、
  # T13、T14、T15），目录里的检查名是同名字符串。
  defp rejects(placed, inputs, catalog) do
    declared =
      MapSet.new(placed, & &1.glyph.index) |> Enum.flat_map(&catalog.symbols[&1].numeric_checks)

    for check <- Codec.spell_reject_checks(),
        Atom.to_string(check) in declared,
        detail <- violations(check, inputs, catalog),
        do: %{check: check, detail: detail}
  end

  # T5：E₀_op + |E_th0| ≤ E_cap；〈辉〉功率 ≤ Φ_cap（〈链〉功率为 P2）。
  defp violations(:capacity, %{group: group, upkeep: upkeep}, _catalog) do
    load_mj = glyph(group.energy, "energy.load").params["energy_mj"] + abs(upkeep.e_th0_mj)
    glow_w = Enum.find_value(group.quality, 0, &(&1.id == "cpl.glow" && &1.params["power_w"]))

    [
      load_mj > upkeep.e_cap_mj && %{load_mj: load_mj, e_cap_mj: upkeep.e_cap_mj},
      glow_w > upkeep.phi_cap_w && %{glow_w: glow_w, phi_cap_w: upkeep.phi_cap_w}
    ]
    |> Enum.filter(& &1)
  end

  # T6：形成位置须在本地施法域内（P1 没有〈传〉）。结构与〈取〉共用：〈取〉的形成位置是能源目标（见 `site/0`）。
  defp violations(:domain, %{site: site}, catalog) do
    limit = catalog.limits.local_domain_m

    if site.formation_distance_m > limit,
      do: [%{distance_m: site.formation_distance_m, local_domain_m: limit}],
      else: []
  end

  # T13：E₀_op ≥ E_min + 出生一拍的运转出账（整数 mJ 比较）。
  defp violations(:first_tick, %{group: group, runtime: runtime}, _catalog) do
    energy = glyph(group.energy, "energy.load").params["energy_mj"]

    if energy < runtime.first_tick_min_mj,
      do: [%{e_op_mj: energy, required_mj: runtime.first_tick_min_mj}],
      else: []
  end

  # T14（P1）：〈热〉的 T0 ≥ 施法处环境温度（同为 0.1 K 整数）。
  defp violations(:ambient_floor, %{thermal: thermal}, _catalog) do
    if thermal.t0_dk < thermal.t_ref_dk,
      do: [%{t0_dk: thermal.t0_dk, t_ref_dk: thermal.t_ref_dk}],
      else: []
  end

  # T15：热节点显式稳定步长 0.45·C_th / g_max ≥ thermal_step_min_ms（设计 §3.3、A.7）；
  # g_max = 接触上限 + 4σε·A·T_chk³ + h·A。
  defp violations(:thermal_step, %{upkeep: upkeep, shape: shape, site: site}, catalog) do
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

  # 接触导热上限 g_contact = k_s · max_轴(该轴法向面积 ÷ 该轴半程)（设计 v2.9 A2：§3.3 T15、附录 A.7）。接触面积 =
  # 包围盒另两轴的全长之积 × 形状系数，路径 = 该轴半程（`Semblance.conductance/5` 的 r / k_s 同一串联式的拟态一侧）。
  # 半尺寸 a、b、c 时：块 = k_s·max(4bc/a, 4ac/b, 4ab/c)；板同块（第三轴取半厚）；球 = k_s·(π/4)·4r²/r = k_s·π·r。
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
  # 取能分账（〈取〉）
  # ===========================================================================

  @doc """
  〈取〉的取能分账（整数 mJ，施法者账的最小单位；目录 v5 `caster`）：石减少 `taken_mj` = 施法者取得 `gained_mj` +
  损耗 `loss_mj`，两端同一整数。入参均为整数 mJ：请求（来自 IR v2 `energy_mj`）、石储能（调用方 `trunc(stored_j × 1000)`）、
  施法者余额；容量取 `round(caster.capacity_j × 1000)`；取得按 `round(η × taken_mj)`，损耗是差额。
  """
  def draw(requested_mj, stored_mj, balance_mj, %Catalog{caster: caster}) do
    taken = min(requested_mj, min(stored_mj, round(caster.capacity_j * 1000) - balance_mj))
    gained = round(caster.draw_efficiency * taken)
    %{taken_mj: taken, gained_mj: gained, loss_mj: taken - gained}
  end
end
