defmodule SceneServer.Body do
  @moduledoc """
  角色身体 L1 的纯值状态（Voxim `Docs/Magic.md` §6）。

  首片只接体温这一路。体温是多层模型（Stolwijk 1971 被动系统按“躯干 + 头”与“四肢”两组归并，见 `body/README.md`）的
  七个节点温度：核心（头、躯干核心与中心血液）、躯干肌肉、躯干脂肪、四肢核心（骨等）、四肢肌肉、四肢脂肪、皮肤（全身共用一个）；
  另存烧伤与冻伤的组织损伤剂量、致命系统跌破阈值的持续时间和存活状态。以下都是由这些字段**推导**的只读视图，不另存第二份：

  - `systems/1`：体温调节、循环、神经三个系统的功能水平（1.0 = 正常，0.0 = 完全抑制）；
  - `life/1`：由致命系统（循环、神经）推导的生命值 0..100；`recoverable_life/1`：其中伤口愈合后会回来的那一截；
  - `injuries/1`：伤病表，每条 = 标签 + 部位 + 严重度 + 进展规则。

  另存两个能量储备（J）：`reserve_j`（糖原）与 `fat_reserve_j`（脂肪）。寒战热与修复合成能由两者合付——糖原付约 27%、脂肪付其余，
  一方耗尽后另一方全付，两者都耗尽才无寒战、无修复（Blondin 2010、Haman 2004，见 `body/README.md`）；只在寒战与修复时消耗、
  不随时间自然下降，进食补充（`SceneServer.Body.Repair.eat/3`）。
  另存蛋白质储备 `protein_g`（玩家看到的“营养”，上限 100 g，只在修复时消耗）与两处伤口的愈合进度 `burn_heal`、`frost_heal`（0..1），
  以及烧伤急性期计时 `burn_age_s`（当前烧伤严重度出现后经过的秒数，`Repair.tick/4` 推进）；修复账见 `SceneServer.Body.Repair`。
  另存局部接触组织块温度 `tissue_k`：鞋底 / 触碰处约 0.06 kg 的皮肤组织，是 World 热内核里接在皮肤上的小热容外部节点，
  只随 World 回传的热变化；烧伤 / 冻伤剂量读它。另存衣物湿度 `wetness`（0 干 .. 1 湿透）：只随浸水与干燥变化。
  身体（含两个储备、组织块、湿度）与其余字段一样不跨登录、死亡后重建（已知缺口，同 §10.7）。

  状态推进由 `SceneServer.Body.Repair.tick/4`（修复 → `SceneServer.Body.Thermo.step/3`）完成；本模块只放数据、参数与推导。

  所有参数集中在 `params/0` 与 `nodes/0`、`edges/0`（首片为模块常量，**待资产化**）。温度一律用开尔文，与
  `VoxelRegion.World` 热内核一致。参数取值与依据见同目录 `body/README.md`。
  """

  @c 273.15
  # Stolwijk 1971 的表以 kcal 为单位：1 kcal/K = 4186.8 J/K，1 kcal/h = 1.163 W。
  @kcal 4186.8
  @kcal_h 1.163

  # —— 多层节点（Stolwijk 1971, NASA CR-1855 表 5/8/12 的六段按“躯干 + 头”“四肢（臂、手、腿、足）”两组求和；皮肤六段合为一个）——
  # {字段, 热容 kcal/K, 基础产热 kcal/h, 与中心血液（= 核心节点）交换的基础血流 L/h, 寒战份额}
  # 核心 = 头核心 2.22 + 躯干核心 9.82 + 中心血液 2.25 + 头肌肉 0.33 + 头脂肪 0.22（头部组织块小、脑血流 45 L/h，并入核心）；
  # 四肢核心 = 臂 / 手 / 腿 / 足核心（骨与结缔组织，基础血流合计 3.79 L/h）。皮肤血流随体温调节，另算（`Thermo`）。
  # 寒战份额（表 12 CHILM）：头 0.02（并入核心，直接进核心）、躯干 0.85、臂 0.05 + 腿 0.07，按合计 0.99 归一。
  @nodes [
    {:core_k, 14.84, 58.43, 0.0, 0.02},
    {:trunk_muscle_k, 16.15, 5.00, 6.00, 0.85},
    {:trunk_fat_k, 4.25, 2.13, 2.56, 0.0},
    {:limb_core_k, 6.02, 3.14, 3.79, 0.0},
    {:limb_muscle_k, 12.33, 4.03, 4.83, 0.12},
    {:limb_fat_k, 2.23, 0.67, 0.81, 0.0},
    {:skin_k, 3.35, 1.05, 0.0, 0.0}
  ]

  # —— 层间导热（表 6 TC，kcal/(h·K)，同组各段并联求和）——
  # 头部“核心→肌肉→脂肪→皮肤”三段串联 1/(1/1.38 + 1/11.4 + 1/13.8) = 1.1302（头部肌肉、脂肪并入核心后成为核心→皮肤一条边）；
  # 躯干 1.37 / 4.75 / 19.80；四肢 臂 + 手 + 腿 + 足 = 29.7 / 48.65 / 114.2。
  @edges [
    {:core_k, :skin_k, 1 / (1 / 1.38 + 1 / 11.4 + 1 / 13.8)},
    {:core_k, :trunk_muscle_k, 1.37},
    {:trunk_muscle_k, :trunk_fat_k, 4.75},
    {:trunk_fat_k, :skin_k, 19.80},
    {:limb_core_k, :limb_muscle_k, 29.7},
    {:limb_muscle_k, :limb_fat_k, 48.65},
    {:limb_fat_k, :skin_k, 114.2}
  ]

  @params %{
    # —— 人体几何（Stolwijk 1971 标准人 74.4 kg、1.8877 m²（表 2 六段面积和））——
    area_m2: 1.8877,
    # —— 产热：1 met 静息代谢（ASHRAE），按 Stolwijk 表 8 基础产热比例分到各节点 ——
    metabolic_w_per_m2: 58.2,
    # —— 寒战（Tikuisis & Giesbrecht 1999，冷水浸泡 14 名男性拟合）：
    #    [155.5·(37 − T_核心) + 47.0·(33 − T_皮) − 1.57·(33 − T_皮)²] / √体脂%，W/m²；体脂 15%（Stolwijk 标准人脂肪 11.16/74.4 kg）。
    #    峰值 232.8 W/m²（约 4 met 额外，Eyolfson et al. 2001 峰值寒战 4.9 倍静息），不随储备多少变化（Haman 2004：糖原低时
    #    总产热不变）。——
    shiver_core_w_per_m2_k: 155.5,
    shiver_skin_w_per_m2_k: 47.0,
    shiver_skin_w_per_m2_k2: 1.57,
    shiver_core_ref_k: 37.0 + @c,
    shiver_skin_ref_k: 33.0 + @c,
    body_fat_percent: 15.0,
    shiver_max_w_per_m2: 232.8,
    # —— 能量储备：两个有限储备，只有寒战与修复合成从中取能（静息代谢不取），不随时间自然下降；进食补充（`Repair.eat/3`）。
    # 糖原 `reserve_j`：成人肝糖原约 100 g + 肌糖原约 350 g ≈ 450 g，氧化热约 17 kJ/g → 7.65 MJ。
    # 脂肪 `fat_reserve_j`：Stolwijk 1971 标准人 74.4 kg、脂肪 11.16 kg（15%）× 脂肪能量密度 9 kcal/g = 37.6812 MJ/kg
    # （Atwater 系数；纯甘油三酯燃烧热约 37–39 MJ/kg）→ 420.52 MJ；不扣必需脂肪，蛋白质氧化（Haman 2004 占 12–19%）并入此项。
    # 寒战热的 27% 由糖原付（Blondin et al. 2010：约 3 倍静息的中等寒战，肌糖原约占总产热 27%），其余由脂肪付；糖原不够时
    # 脂肪补足（Haman et al. 2004：低糖原时总产热不变、脂肪蛋白补上），脂肪不够时糖原补足，两者都空才无寒战。——
    reserve_full_j: 7_650_000.0,
    fat_full_j: 11.16 * 9 * 4_186_800.0,
    glycogen_shiver_share: 0.27,
    # —— 调定点（Gagge 1971）：血管舒缩与出汗读它们 ——
    core_set_k: 36.8 + @c,
    skin_set_k: 34.0 + @c,
    # —— 血液：1 kcal/(L·K)（Stolwijk 与 Gagge 同值）；寒战肌肉每 1 kcal/h 产热需 1 L/h 血流（Stolwijk 1971 p.29）——
    blood_w_h_per_l_k: 1.163,
    # —— 皮肤血流（Gagge 1971）：(6.3 + 50·暖核心)/(1 + 0.5·冷皮肤) L/(m²·h)；6.3 × 1.8877 = 11.9 L/h 与 Stolwijk 表 8 皮肤
    # 基础血流合计 11.89 L/h 一致 ——
    skin_blood_base_l_per_m2_h: 6.3,
    vasodilation_l_per_m2_h_k: 50.0,
    vasoconstriction_per_k: 0.5,
    # —— 出汗：170 g/(m²·h·K)，蒸发潜热 2430 J/g，不设湿度上限 ——
    sweat_g_per_m2_h_k: 170.0,
    sweat_skin_scale_k: 10.7,
    latent_j_per_g: 2430.0,
    # —— 皮肤-空气干热交换：对流 + 线性化辐射，外加 1 clo 服装热阻。对流系数 h_c = max(3.1, 8.3·v^0.6)
    # （Gagge / ASHRAE Fundamentals 第 9 章：静止空气自然对流下限 3.1，受迫对流 8.3·v^0.6，v 为风速 m/s）——
    convective_w_per_m2_k: 3.1,
    wind_convective_w_per_m2_k: 8.3,
    wind_exponent: 0.6,
    radiative_w_per_m2_k: 4.7,
    clothing_m2_k_per_w: 0.155,
    # —— 局部接触组织块（鞋底 / 手掌触碰处的皮肤组织，两处共用一块）：面积 0.03 m²（两脚掌着地面积，同 BodyContact 鞋底）
    # × 厚 2 mm（表皮 + 真皮全层，即三度烧伤的深度）× 1000 kg/m³ = 0.06 kg，比热 3490 J/(kg·K)（ASHRAE 人体组织），
    # 热容 209.4 J/K。与皮肤节点之间的导热 = 面积 × (局部组织壳导热 5.28 W/(m²·K)（Gagge 1971 组织导热，沿用；本次冷暴露
    # 校准未改）+ 血液 × 本步皮肤血流)。——
    contact_tissue_m2: 0.03,
    contact_tissue_kg: 0.06,
    tissue_specific_heat_j_per_kg_k: 3490.0,
    contact_tissue_w_per_m2_k: 5.28,
    # —— 湿衣：浸水部分的衣物按时间常数 20 s 趋于湿透（织物浸没数十秒内吸饱）。空气中湿衣的非蒸发保温损失按湿度线性
    # 到 16%（Bröde et al. 2008：湿中间层使总热阻降 0.02 m²·K/W，走动 16%、站立 9%，取大）；湿衣的主要作用是蒸发：
    # 衣面蒸发 = Lewis 比 16.5 K/kPa × h_c × (p_s(T_衣面) − 相对湿度 × p_s(T_空))（ASHRAE Fundamentals 第 9 章；Magnus 式，
    # Alduchov & Eskridge 1996），衣面温度按“经衣物导来的热 = 对流辐射 + 蒸发”求解（蒸发热必须穿过衣物送到衣面）。
    # 浸没在水里的湿衣热阻是 World 浸没边的 `VoxelRegion.BodyContact` 参数，不在这里。
    # 湿透衣物含水 1 kg（1 clo 常规服装约 1–1.5 kg，棉织物沥干后含水约为自重的 50–100%）；空气相对湿度 0.5（气候接口暂无湿度）。——
    soak_s: 20.0,
    wet_insulation_loss: 0.16,
    clothing_water_kg: 1.0,
    lewis_k_per_kpa: 16.5,
    relative_humidity: 0.5,
    # —— 系统功能水平带 {冷侧归零, 冷侧满值, 热侧满值, 热侧归零} ——
    thermoregulation_band: {28.0 + @c, 32.0 + @c, 40.0 + @c, 42.0 + @c},
    circulation_band: {24.0 + @c, 32.0 + @c, 40.0 + @c, 43.0 + @c},
    nervous_band: {28.0 + @c, 35.0 + @c, 39.0 + @c, 42.0 + @c},
    # —— 濒死：致命系统低于该水平持续 dying_after_s → 濒死，再持续 rescue_window_s → 死亡 ——
    lethal_level: 0.1,
    dying_after_s: 10.0,
    rescue_window_s: 120.0,
    # —— 体温伤病：核心低于 / 高于各阈值的个数即严重度 ——
    hypothermia_below_k: [35.0 + @c, 32.0 + @c, 28.0 + @c],
    hyperthermia_above_k: [38.5 + @c, 40.0 + @c, 41.0 + @c],
    # —— 烧伤：组织块温度 ≥ 44 °C 起累计剂量，剂量率 2^((T-60 °C)/1.32 K)，单位 = 60 °C 下的秒 ——
    burn_onset_k: 44.0 + @c,
    burn_reference_k: 60.0 + @c,
    burn_doubling_k: 1.32,
    burn_degree_dose_s: [1.0, 2.5, 5.0],
    # —— 冻伤：组织块温度低于组织冰点 −0.55 °C 起累计 K·s；浅 / 深两级（部位“脚”：冻伤只来自鞋底接触）。
    # 深 600 K·s 为原创取值（沿用）；浅 300 K·s 待确认——临床只按冻结深度分浅（1–2 度）/ 深（3–4 度），没有查到按
    # 过冷剂量分级的文献阈值（用户 2026-09-26：找不到依据取 300 并标待确认）。——
    frost_onset_k: -0.55 + @c,
    frostbite_dose_k_s: [300.0, 600.0],
    # —— 修复账（身体闭环 H1，Magic.md §6.5–6.7，body/README.md“修复账”）——
    # 伤口组织量 = 局部接触组织块面积 0.03 m² × 深度 × 1000 kg/m³；深度：1 度 0.1 mm（表皮）、2 度 1 mm（真皮中层）、
    # 3 度与深冻伤 2 mm（全层，即组织块厚度）；浅冻伤 1 mm（临床浅冻伤 = 1–2 度、清亮水疱，同 2 度烧伤的部分厚度）。
    # 湿皮蛋白约 30%（真皮约 70% 水、干重以胶原为主）。
    wound_depth_m: %{burn: [0.0001, 0.001, 0.002], frostbite: [0.001, 0.002]},
    tissue_density_kg_per_m3: 1000.0,
    tissue_protein_fraction: 0.30,
    # 真实愈合时间（天）：1 度 3–6 d 取 5，浅 2 度 2–3 周取 21，3 度（300 cm² 不植皮，靠收缩与边缘上皮化）取 90，
    # 浅冻伤取 7，深冻伤 4–8 周分界取 42。生物学只决定排序（Magic.md §12，用户 2026-09-26 定）：
    # 游戏内愈合时长 = clamp(30 s × 真实天数^0.7, 30 s, 1800 s)（`heal_s/2`）。
    wound_heal_days: %{burn: [5.0, 21.0, 90.0], frostbite: [7.0, 42.0]},
    heal_scale_s: 30.0,
    heal_exponent: 0.7,
    heal_bounds_s: {30.0, 1800.0},
    # 慢性影响（Magic.md §12）：伤口压低系统上限的深度 = 0.25 × √(一度烧伤时长 / 本伤时长)——越长每秒越弱、
    # 总量（深度 × 时长 ∝ √时长）越高；愈合中按进度线性回到 1.0。本增量只有烧伤压循环（体液丢失），冻伤不压系统（后果待 H5）。
    # 基数 0.25（用户 2026-09-26 定，原 0.10 时可恢复段只有 4–10%、玩家感知不到）：烧伤 1 / 2 / 3 度生命 75 / 85 / 91。
    chronic_depth_at_first_degree: 0.25,
    # 急性期（用户 2026-09-26 定）：伤后压低深度不瞬间到位，按 r = min(1, burn_age_s / onset) 线性加深。onset 用同一时长公式换算
    # 真实烧伤休克期约 1 天（伤后毛细血管渗漏、体液丢失在 24 h 内最甚，Parkland 公式按伤后 24 h 补液）：30 s × 1^0.7 = 30 s（`burn_onset_s/0`）。
    burn_onset_days: 1.0,
    # 蛋白质净沉积的合成能：肽键合成最低约 4 ATP/键 ≈ 4.2 kJ/g（Waterlow），修复中合成—降解周转约 3 倍 → 12 kJ/g
    # （设计稿区间 4.2–12 的上端）；由糖原 / 脂肪按寒战同一份额付（`fuel_split/2`），全部作为热进核心节点。
    synthesis_j_per_g: 12_000.0,
    # —— 营养（蛋白质储备，玩家看到的“营养”）：上限 100 g（人体游离氨基酸池量级），只在修复时消耗、不随时间下降；
    # 低于上限 20% 出现 `nutrition.hunger`（用户 2026-09-26 定）。蛋白质可代谢能 4 kcal/g = 16 747.2 J/g（Atwater）：
    # 食物能量（USDA，Atwater）已含其蛋白部分，进了蛋白储备的那部分不再计入能量储备；超上限的蛋白被氧化，其能量留在能量里。——
    protein_full_g: 100.0,
    hunger_below_fraction: 0.2,
    protein_atwater_j_per_g: 4 * 4186.8
  }

  # 调定点身体：核心 36.8 °C、皮肤 34 °C（Gagge 调定点），其余五层取该核心 / 皮肤温度、1 met、基础血流下的稳态
  # （每层：产热 + Σ 导热 × (邻层 − 本层) + 血液 × (核心 − 本层) = 0；高斯-赛德尔迭代，编译期解出）。
  @neutral (fn ->
              fixed = %{core_k: 36.8 + @c, skin_k: 34.0 + @c}
              total = Enum.sum(for {_, _, q, _, _} <- @nodes, do: q)
              free = for {f, _, _, _, _} <- @nodes, not Map.has_key?(fixed, f), do: f

              Enum.reduce(1..2000, Map.merge(fixed, Map.new(free, &{&1, 35.0 + @c})), fn _, t ->
                Enum.reduce(free, t, fn f, t ->
                  {^f, _, q, blood, _} = List.keyfind(@nodes, f, 0)
                  met = @params.metabolic_w_per_m2 * @params.area_m2 * q / total

                  links =
                    [{:core_k, @params.blood_w_h_per_l_k * blood}] ++
                      for({a, b, g} <- @edges, a == f, do: {b, g * @kcal_h}) ++
                      for({a, b, g} <- @edges, b == f, do: {a, g * @kcal_h})

                  num = met + Enum.sum(for {n, g} <- links, do: g * t[n])
                  Map.put(t, f, num / Enum.sum(for {_, g} <- links, do: g))
                end)
              end)
            end).()

  defstruct core_k: 36.8 + @c,
            trunk_muscle_k: @neutral.trunk_muscle_k,
            trunk_fat_k: @neutral.trunk_fat_k,
            limb_core_k: @neutral.limb_core_k,
            limb_muscle_k: @neutral.limb_muscle_k,
            limb_fat_k: @neutral.limb_fat_k,
            skin_k: 34.0 + @c,
            burn_dose_s: 0.0,
            frost_dose_k_s: 0.0,
            lethal_s: 0.0,
            reserve_j: 7_650_000.0,
            fat_reserve_j: 11.16 * 9 * 4_186_800.0,
            tissue_k: 34.0 + @c,
            wetness: 0.0,
            status: :alive,
            protein_g: 100.0,
            burn_heal: 0.0,
            frost_heal: 0.0,
            burn_age_s: 0.0

  @type status :: :alive | :dying | :dead
  @type t :: %__MODULE__{
          core_k: float(),
          trunk_muscle_k: float(),
          trunk_fat_k: float(),
          limb_core_k: float(),
          limb_muscle_k: float(),
          limb_fat_k: float(),
          skin_k: float(),
          burn_dose_s: float(),
          frost_dose_k_s: float(),
          lethal_s: float(),
          reserve_j: float(),
          fat_reserve_j: float(),
          tissue_k: float(),
          wetness: float(),
          status: status(),
          protein_g: float(),
          burn_heal: float(),
          frost_heal: float(),
          burn_age_s: float()
        }
  @type injury :: %{
          tag: String.t(),
          part: :whole | :contact | :feet,
          severity: pos_integer(),
          progression: :tracks_core | :heals | :tracks_protein,
          heal: float()
        }

  @doc "身体 L1 全部标量参数（首片常量，待资产化）。"
  @spec params() :: map()
  def params, do: @params

  @doc """
  多层节点表：`{字段, 热容 J/K, 静息产热 W（1 met 按基础产热比例分配）, 与核心交换的基础血流 L/h, 寒战份额}`，
  顺序固定（核心在前、皮肤在后）。寒战份额合计 1。
  """
  @spec nodes() :: [{atom(), float(), float(), float(), float()}]
  def nodes do
    total_q = Enum.sum(for {_, _, q, _, _} <- @nodes, do: q)
    total_s = Enum.sum(for {_, _, _, _, s} <- @nodes, do: s)

    for {f, c, q, blood, s} <- @nodes,
        do: {f, c * @kcal, @params.metabolic_w_per_m2 * @params.area_m2 * q / total_q, blood, s / total_s}
  end

  @doc "层间导热边：`{节点, 节点, W/K}`。"
  @spec edges() :: [{atom(), atom(), float()}]
  def edges, do: for({a, b, g} <- @edges, do: {a, b, g * @kcal_h})

  @doc "调定点上的健康身体：核心 36.8 °C、皮肤与组织块 34 °C、其余层为该核心 / 皮肤下的稳态，衣物干、无伤病、存活。"
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "身体各节点（七层 + 局部接触组织块）的热容 × 温度之和，J。能量账：一步的变化 = `Thermo.step/3` 的 `stored_j`。"
  @spec heat_content_j(t()) :: float()
  def heat_content_j(%__MODULE__{} = body) do
    Enum.sum(for {f, c, _, _, _} <- nodes(), do: c * Map.fetch!(body, f)) + tissue_capacity_j_per_k() * body.tissue_k
  end

  @doc "皮肤节点热容 J/K（World 外部节点）。"
  @spec skin_capacity_j_per_k() :: float()
  def skin_capacity_j_per_k, do: capacity(:skin_k)

  @doc "核心节点热容 J/K（头、躯干核心与中心血液）。"
  @spec core_capacity_j_per_k() :: float()
  def core_capacity_j_per_k, do: capacity(:core_k)

  @doc "局部接触组织块热容 J/K。"
  @spec tissue_capacity_j_per_k() :: float()
  def tissue_capacity_j_per_k, do: @params.contact_tissue_kg * @params.tissue_specific_heat_j_per_kg_k

  defp capacity(field), do: nodes() |> List.keyfind(field, 0) |> elem(1)

  @doc "伤口严重度（0 = 无）：烧伤 1–3 度、冻伤 1 浅 / 2 深，由累计组织损伤剂量按阈值推导。"
  @spec severity(t(), :burn | :frostbite) :: non_neg_integer()
  def severity(%__MODULE__{} = body, :burn), do: Enum.count(@params.burn_degree_dose_s, &(body.burn_dose_s >= &1))
  def severity(%__MODULE__{} = body, :frostbite), do: Enum.count(@params.frostbite_dose_k_s, &(body.frost_dose_k_s >= &1))

  @doc "游戏内愈合时长 s：clamp(30 s × 真实天数^0.7, 30 s, 1800 s)。"
  @spec heal_s(number()) :: float()
  def heal_s(days) do
    {low, high} = @params.heal_bounds_s
    (@params.heal_scale_s * :math.pow(days, @params.heal_exponent)) |> max(low) |> min(high)
  end

  @doc "伤口的游戏内愈合时长 s（循环满值、速率倍数 1 时）。"
  @spec heal_s(:burn | :frostbite, pos_integer()) :: float()
  def heal_s(kind, severity), do: @params.wound_heal_days |> Map.fetch!(kind) |> Enum.at(severity - 1) |> heal_s()

  @doc "慢性伤口压低系统上限的深度（未愈合时）：0.25 × √(一度烧伤时长 / 本伤时长)。"
  @spec chronic_depth(:burn | :frostbite, pos_integer()) :: float()
  def chronic_depth(kind, severity),
    do: @params.chronic_depth_at_first_degree * :math.sqrt(heal_s(:burn, 1) / heal_s(kind, severity))

  @doc "烧伤急性期时长 s：同一时长公式换算真实 `burn_onset_days`（1 天 → 30 s）。"
  @spec burn_onset_s() :: float()
  def burn_onset_s, do: heal_s(@params.burn_onset_days)

  @doc """
  烧伤此刻把循环上限压低的量：`chronic_depth(:burn, 度) × r × (1 − burn_heal)`，r = min(1, `burn_age_s` / `burn_onset_s/0`)
  （急性期线性加深，满 onset 后到位）；无烧伤为 0。
  """
  @spec burn_depression(t()) :: float()
  def burn_depression(%__MODULE__{} = body) do
    case severity(body, :burn) do
      0 -> 0.0
      burn -> chronic_depth(:burn, burn) * min(1.0, body.burn_age_s / burn_onset_s()) * (1 - body.burn_heal)
    end
  end

  @doc """
  寒战与修复合成共用的取能规则：`j` 焦耳由糖原付 `glycogen_shiver_share`（27%），脂肪付其余；一方不够时另一方补足
  （Blondin 2010、Haman 2004）。调用方保证 `j ≤ reserve_j + fat_reserve_j`。返回 `{糖原付, 脂肪付}`。
  """
  @spec fuel_split(t(), float()) :: {float(), float()}
  def fuel_split(%__MODULE__{} = body, j) do
    glycogen_j = min(max(@params.glycogen_shiver_share * j, j - body.fat_reserve_j), body.reserve_j)
    {glycogen_j, j - glycogen_j}
  end

  @doc """
  三个系统的功能水平，由核心温度按各自功能带线性推导，夹在 [0, 1]；循环另受烧伤上限约束（体液丢失）：
  上限 = 1 − `burn_depression/1`：伤后急性期内线性压深，同时随愈合进度线性回到 1.0。

  首片只有体温这一路写入，故不会出现亢进（> 1.0）；亢进留给后续魔法“调”动词。
  """
  @spec systems(t()) :: %{thermoregulation: float(), circulation: float(), nervous: float()}
  def systems(%__MODULE__{core_k: core} = body) do
    cap = 1 - burn_depression(body)

    %{
      thermoregulation: level(core, @params.thermoregulation_band),
      circulation: min(level(core, @params.circulation_band), cap),
      nervous: level(core, @params.nervous_band)
    }
  end

  @doc "由致命系统（循环、神经）推导的生命值 0..100：取两者最低功能水平 × 100 后四舍五入。"
  @spec life(t()) :: 0..100
  def life(%__MODULE__{} = body), do: round(100 * lethal_level(body))

  @doc """
  可恢复生命（生命条上另一种颜色的那一截）：伤口全部愈合后的生命 − 现在的生命 = `life(剂量与进度归零的同一身体) − life(body)`。
  只有慢性伤口压低的部分（本增量只有烧伤压循环）随愈合自己回来；体温偏离等急性损失不经伤口愈合，不计入——
  两者同时存在时取“去掉伤口后仍被急性压住”的部分为急性，例如核心低温把神经压到 0.70、一度烧伤上限 0.75 → 生命 70、可恢复 0。
  """
  @spec recoverable_life(t()) :: 0..100
  def recoverable_life(%__MODULE__{} = body),
    do: life(%{body | burn_dose_s: 0.0, burn_heal: 0.0, frost_dose_k_s: 0.0, frost_heal: 0.0}) - life(body)

  @doc "伤口此刻的愈合速率（进度 /s）：`m / T(严重度) × min(1, 循环)`；`Repair.heal/3` 与 `remaining_s/3` 共用这一处。"
  @spec heal_rate(t(), :burn | :frostbite, number()) :: float()
  def heal_rate(%__MODULE__{} = body, kind, m), do: m / heal_s(kind, severity(body, kind)) * min(1.0, systems(body).circulation)

  @doc """
  按此刻速度估算的剩余愈合秒数：`(1 − 进度) / heal_rate`（不预测之后循环变化、体温或营养变化：烧伤急性期内上限仍在下压，
  实际晚于估算；急性期过后上限随愈合回升，实际不晚于估算）。愈合停止时返回约定负值：营养（蛋白储备）为 0 → `-1.0`；速率为 0（循环归零，只在濒死 / 死亡时）→ `-2.0`。
  """
  @spec remaining_s(t(), :burn | :frostbite, number()) :: float()
  def remaining_s(%__MODULE__{} = body, kind, m) do
    rate = heal_rate(body, kind, m)
    progress = if kind == :burn, do: body.burn_heal, else: body.frost_heal

    cond do
      body.protein_g <= 0 -> -1.0
      rate <= 0 -> -2.0
      true -> (1 - progress) / rate
    end
  end

  @doc """
  当前伤病表。

  - `temperature.hypothermia` / `temperature.hyperthermia`：部位 `:whole`，严重度随核心温度，
    回到正常带即消失（`:tracks_core`）；
  - `trauma.thermal.burn`（1–3 度，部位 `:contact`）/ `trauma.thermal.frostbite`（1 浅 / 2 深，部位 `:feet`）：严重度由累计组织
    损伤剂量决定；按修复账愈合（`:heals`，`SceneServer.Body.Repair`），`heal` 是愈合进度 0..1，
    走完即剂量与进度归零、伤病消失。严重度不降级（深度烧伤以疤痕愈合，不经过浅度）；
  - `nutrition.hunger`：部位 `:whole`，蛋白质储备低于上限 `hunger_below_fraction` 时出现，进食回到阈值以上即消失（`:tracks_protein`）。
  """
  @spec injuries(t()) :: [injury()]
  def injuries(%__MODULE__{} = body) do
    hungry = body.protein_g < @params.hunger_below_fraction * @params.protein_full_g

    [
      {"temperature.hypothermia", :whole,
       Enum.count(@params.hypothermia_below_k, &(body.core_k < &1)), :tracks_core, 0.0},
      {"temperature.hyperthermia", :whole,
       Enum.count(@params.hyperthermia_above_k, &(body.core_k > &1)), :tracks_core, 0.0},
      {"trauma.thermal.burn", :contact, severity(body, :burn), :heals, body.burn_heal},
      {"trauma.thermal.frostbite", :feet, severity(body, :frostbite), :heals, body.frost_heal},
      {"nutrition.hunger", :whole, if(hungry, do: 1, else: 0), :tracks_protein, 0.0}
    ]
    |> Enum.filter(fn {_tag, _part, severity, _rule, _heal} -> severity > 0 end)
    |> Enum.map(fn {tag, part, severity, rule, heal} ->
      %{tag: tag, part: part, severity: severity, progression: rule, heal: heal}
    end)
  end

  @doc """
  推进 `dt` 秒的濒死计时。

  致命系统最低功能水平低于 `lethal_level` 时累计 `lethal_s`，否则清零（在濒死窗口内被救回即恢复 `:alive`）。
  累计达 `dying_after_s` 进入 `:dying`，再达 `rescue_window_s` 进入 `:dead`；`:dead` 为终态。
  """
  @spec progress(t(), float()) :: t()
  def progress(%__MODULE__{status: :dead} = body, _dt), do: body

  def progress(%__MODULE__{} = body, dt) do
    lethal_s = if lethal_level(body) < @params.lethal_level, do: body.lethal_s + dt, else: 0.0

    status =
      cond do
        lethal_s >= @params.dying_after_s + @params.rescue_window_s -> :dead
        lethal_s >= @params.dying_after_s -> :dying
        true -> :alive
      end

    %{body | lethal_s: lethal_s, status: status}
  end

  @doc """
  下行视图（Session.BodyState）：生命、可恢复生命（`recoverable_life/1`）、状态码（0 存活 / 1 濒死 / 2 死亡）、核心与皮肤温度、
  伤病 `{标签, 严重度, 愈合进度 %, 剩余秒数}`（进度 = ⌊heal × 100⌋，0..99；剩余 = `remaining_s/3`，含停止负值；
  不愈合的伤病进度与剩余都为 0）、蛋白质储备 g。`m` 是愈合速率倍数（Player 恒 1）。
  `key` 是“有变化”的比较键：温度取 0.1 K，蛋白质取 0.1 g，剩余取整秒，其余原值。
  """
  def report(%__MODULE__{} = body, m) do
    kinds = %{"trauma.thermal.burn" => :burn, "trauma.thermal.frostbite" => :frostbite}

    injuries =
      for i <- injuries(body) do
        remaining = if kind = kinds[i.tag], do: remaining_s(body, kind, m), else: 0.0
        {i.tag, i.severity, floor(i.heal * 100), remaining}
      end

    status = %{alive: 0, dying: 1, dead: 2}[body.status]
    life = life(body)
    recoverable = recoverable_life(body)

    %{life: life, recoverable: recoverable, status: status, core_k: body.core_k, skin_k: body.skin_k, injuries: injuries,
      protein_g: body.protein_g,
      key: {life, recoverable, status, round(body.core_k * 10), round(body.skin_k * 10),
            for({tag, n, heal, left} <- injuries, do: {tag, n, heal, round(left)}), round(body.protein_g * 10)}}
  end

  defp lethal_level(body) do
    %{circulation: circulation, nervous: nervous} = systems(body)
    min(circulation, nervous)
  end

  # 两侧线性斜坡取小再夹到 [0, 1]：带内 1，冷侧 / 热侧各自线性降到 0。
  defp level(t, {cold_zero, cold_full, hot_full, hot_zero}) do
    ((t - cold_zero) / (cold_full - cold_zero))
    |> min((hot_zero - t) / (hot_zero - hot_full))
    |> min(1.0)
    |> max(0.0)
  end
end
