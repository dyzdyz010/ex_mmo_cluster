defmodule SceneServer.Body.Thermo do
  @moduledoc """
  身体体温的一步推进（多层模型，显式欧拉）。结构与参数见 `SceneServer.Body` 的 `nodes/0`、`edges/0` 与 `body/README.md`。

  - 七个节点（核心、躯干肌肉 / 脂肪、四肢核心 / 肌肉 / 脂肪、皮肤）按 Stolwijk 1971 被动系统换热：层间导热（`Body.edges/0`），
    每层与中心血液（= 核心节点）按血流换热（血液 1 kcal/(L·K)）；肌肉血流 = 基础 + 寒战产热（每 1 kcal/h 需 1 L/h，Stolwijk），
    所以寒战越强，肌肉与核心耦合越紧；皮肤血流按 Gagge 血管舒缩（冷皮肤收缩、暖核心舒张），只作用于皮肤；
  - 皮肤节点：吸收世界回传的接触热中没存进局部接触组织块的部分 `q_j − tissue_j`，经服装与空气做干热交换（对流 + 线性化辐射；
    对流系数随风速，h_c = max(3.1, 8.3·v^0.6)），出汗蒸发、湿衣蒸发散热；
  - 局部接触组织块：温度只随 World 回传的 `tissue_j` 变化；烧伤 / 冻伤剂量按本步末组织块温度累计；
  - 产热：1 met 静息代谢按 Stolwijk 基础产热比例分到各节点；寒战（Tikuisis & Giesbrecht 1999，读核心与皮肤温度）按份额进
    躯干 / 四肢肌肉（头部份额进核心），封顶峰值；寒战热由糖原 `reserve_j` 付 27%、脂肪 `fat_reserve_j` 付其余，一方不够时
    另一方补足，总寒战不因糖原低而下降（Blondin 2010、Haman 2004），两者都空才无寒战；
  - 体温调节（血管舒缩、寒战、出汗）按 `SceneServer.Body.systems/1` 的体温调节功能水平缩放（核心 32 → 28 °C 线性降到 0）；
  - 衣物湿度：浸水部分按 `soak_s` 时间常数趋于湿透；空气中湿衣保温按湿度线性损失 16%，露出水面的湿衣在衣面蒸发
    （`drying_j`，潜热经衣物取自皮肤），衣面温度解“经衣物导来的热 = 对流辐射 + 蒸发”，湿度按蒸发掉的水量下降。最后推进濒死计时。

  能量账：本步身体储热变化 `stored_j = q_j + core_j + metabolic_j − convection_j − sweat_j − drying_j` = Σ 各节点热容 × 温升 + 组织块热容 × 温升
  （`Body.heat_content_j/1` 之差）；层间导热与血液换热两边抵消，不进账。`metabolic_j` 含寒战 `shiver_j` = `shiver_glycogen_j` + `shiver_fat_j`，
  两项分别等于本步糖原与脂肪储备的减少量。

  浸没：`immersed` 为浸在液体里的体表比例（World 按身体与液体宏格的竖向重叠算出）；这部分皮肤不与空气换热、
  不蒸发出汗，与液体的换热由世界回传的 `q_j` 体现。

  未建模（首片已知偏差）：呼吸散热、湿度对出汗蒸发的上限、辐射加热（附近火焰）、湿衣吸水的水温与世界水量、各肢段各自的皮肤温度。
  """

  alias SceneServer.Body

  @type inputs :: %{
          required(:q_j) => float(),
          required(:air_k) => float(),
          optional(:tissue_j) => float(),
          optional(:core_j) => float(),
          optional(:wind_mps) => float(),
          optional(:immersed) => float(),
          optional(:clothing_m2_k_per_w) => float()
        }
  @type account :: %{
          stored_j: float(),
          q_j: float(),
          core_j: float(),
          tissue_j: float(),
          metabolic_j: float(),
          convection_j: float(),
          sweat_j: float(),
          drying_j: float(),
          shiver_j: float(),
          shiver_glycogen_j: float(),
          shiver_fat_j: float()
        }

  @doc """
  推进 `dt` 秒。

  `inputs`：
  - `q_j`：世界算出的本步接触热，J，正为身体吸热（皮肤与组织块合计）；
  - `tissue_j`：其中存进局部接触组织块的部分，J（缺省 0）；
  - `core_j`：进核心节点的体内外来热，J（缺省 0；修复合成放热，由 `SceneServer.Body.Repair` 从储备付出后传入）；
  - `air_k`：环境空气温度，K；
  - `wind_mps`：风速，m/s（缺省 0 = 静止空气）；
  - `immersed`：浸在液体里的体表比例 0..1（缺省 0）；空气干热交换、出汗与湿衣蒸发按 1 − immersed 缩放；
  - `clothing_m2_k_per_w`：干衣热阻（缺省 1 clo = 0.155；衣物系统接入前只有校验场景传它）。

  返回 `{body, account}`，`account` 各项单位 J，`convection_j` / `sweat_j` / `drying_j` 为正表示身体散热。
  """
  @spec step(Body.t(), float(), inputs()) :: {Body.t(), account()}
  def step(%Body{} = body, dt, %{q_j: q, air_k: air_k} = inputs) do
    p = Body.params()
    level = Body.systems(body).thermoregulation
    area = p.area_m2
    immersed = Map.get(inputs, :immersed, 0.0)
    tissue_q = Map.get(inputs, :tissue_j, 0.0)
    exposed = area * (1 - immersed)

    warm_core = max(body.core_k - p.core_set_k, 0.0)
    warm_skin = max(body.skin_k - p.skin_set_k, 0.0)

    fuel = max(body.reserve_j + body.fat_reserve_j, 0.0)
    shiver_j = min(level * min(shiver_demand_w_per_m2(body), p.shiver_max_w_per_m2) * area * dt, fuel)
    # 糖原付 27%；脂肪不够付其余时糖原补足；糖原不够时脂肪补足（shiver_j ≤ 两者之和，故两项都不超过各自储备）。
    {glycogen_j, fat_j} = Body.fuel_split(body, shiver_j)
    core_q = Map.get(inputs, :core_j, 0.0)

    sweat_w =
      level * p.sweat_g_per_m2_h_k * warm_core * :math.exp(warm_skin / p.sweat_skin_scale_k) *
        p.latent_j_per_g / 3600 * exposed

    # Gagge / ASHRAE：静止空气（自然对流）下限 3.1，受迫对流 8.3·v^0.6 W/(m²·K)。
    convective = max(p.convective_w_per_m2_k, p.wind_convective_w_per_m2_k * :math.pow(Map.get(inputs, :wind_mps, 0.0), p.wind_exponent))
    air_r = 1 / (convective + p.radiative_w_per_m2_k)
    # 空气中湿衣：非蒸发保温按湿度线性损失 wet_insulation_loss（Bröde et al. 2008）。
    clothing = Map.get(inputs, :clothing_m2_k_per_w, p.clothing_m2_k_per_w) * (1 - p.wet_insulation_loss * body.wetness)
    {convection_w, drying_w} = surface_w(body, clothing, air_r, convective, air_k, p)

    convection_j = convection_w * exposed * dt
    sweat_j = sweat_w * dt
    drying_j = drying_w * exposed * dt
    internal = internal_w(body, shiver_j / dt)

    temps =
      for {f, c, met_w, _blood, share} <- Body.nodes(), into: %{} do
        e = (met_w + internal[f]) * dt + share * shiver_j

        e =
          case f do
            :skin_k -> e + q - tissue_q - convection_j - sweat_j - drying_j
            :core_k -> e + core_q
            _ -> e
          end
        {f, Map.fetch!(body, f) + e / c}
      end

    tissue_k = body.tissue_k + tissue_q / Body.tissue_capacity_j_per_k()
    metabolic_j = p.metabolic_w_per_m2 * area * dt + shiver_j

    body =
      body
      |> Map.merge(temps)
      |> Map.merge(%{
        tissue_k: tissue_k,
        burn_dose_s: body.burn_dose_s + burn_rate(tissue_k, p) * dt,
        frost_dose_k_s: body.frost_dose_k_s + max(p.frost_onset_k - tissue_k, 0.0) * dt,
        reserve_j: body.reserve_j - glycogen_j,
        fat_reserve_j: body.fat_reserve_j - fat_j,
        wetness: wetness(body.wetness, drying_j, immersed, dt, p)
      })

    account = %{
      stored_j: q + core_q + metabolic_j - convection_j - sweat_j - drying_j,
      q_j: q,
      core_j: core_q,
      tissue_j: tissue_q,
      metabolic_j: metabolic_j,
      convection_j: convection_j,
      sweat_j: sweat_j,
      drying_j: drying_j,
      shiver_j: shiver_j,
      shiver_glycogen_j: glycogen_j,
      shiver_fat_j: fat_j
    }

    {Body.progress(body, dt), account}
  end

  @doc """
  寒战需求，W/m²（Tikuisis & Giesbrecht 1999）：[155.5·(37 − T_核心) + 47.0·(33 − T_皮) − 1.57·(33 − T_皮)²] / √体脂%，负值取 0。
  实际寒战 = 体温调节功能水平 × min(需求, 峰值) × 体表面积，不超过糖原 + 脂肪储备。
  """
  @spec shiver_demand_w_per_m2(Body.t()) :: float()
  def shiver_demand_w_per_m2(%Body{} = body) do
    p = Body.params()
    cold_core = p.shiver_core_ref_k - body.core_k
    cold_skin = p.shiver_skin_ref_k - body.skin_k

    max(
      (p.shiver_core_w_per_m2_k * cold_core + p.shiver_skin_w_per_m2_k * cold_skin -
         p.shiver_skin_w_per_m2_k2 * cold_skin * cold_skin) / :math.sqrt(p.body_fat_percent),
      0.0
    )
  end

  @doc "本步皮肤血流，L/(m²·h)（Gagge 1971：(6.3 + 50·暖核心)/(1 + 0.5·冷皮肤)，按体温调节功能水平缩放舒缩）。"
  @spec skin_blood_l_per_m2_h(Body.t()) :: float()
  def skin_blood_l_per_m2_h(%Body{} = body) do
    p = Body.params()
    level = Body.systems(body).thermoregulation
    warm_core = max(body.core_k - p.core_set_k, 0.0)
    cold_skin = max(p.skin_set_k - body.skin_k, 0.0)

    (p.skin_blood_base_l_per_m2_h + level * p.vasodilation_l_per_m2_h_k * warm_core) /
      (1 + level * p.vasoconstriction_per_k * cold_skin)
  end

  @doc """
  局部接触组织块与皮肤节点之间的单位面积导热，W/(m²·K) = 局部组织壳导热 5.28 + 血液热容 × 本步皮肤血流（冷时血管收缩降、
  热时舒张升）。Player 每秒按 `contact_tissue_m2 ×` 本值报给 World。
  """
  @spec contact_tissue_w_per_m2_k(Body.t()) :: float()
  def contact_tissue_w_per_m2_k(%Body{} = body) do
    p = Body.params()
    p.contact_tissue_w_per_m2_k + p.blood_w_h_per_l_k * skin_blood_l_per_m2_h(body)
  end

  # 各节点的内部净得热，W：层间导热 + 与中心血液（核心节点）的血流换热。肌肉血流 = 基础 + 寒战份额 × 寒战功率 / 1.163
  # （每 1 kcal/h 产热 1 L/h）；皮肤血流按血管舒缩。各项成对出现，总和为 0。
  defp internal_w(body, shiver_w) do
    p = Body.params()
    zero = Map.new(Body.nodes(), fn {f, _, _, _, _} -> {f, 0.0} end)

    conducted =
      Enum.reduce(Body.edges(), zero, fn {a, b, g}, acc ->
        h = g * (Map.fetch!(body, a) - Map.fetch!(body, b))
        acc |> Map.update!(a, &(&1 - h)) |> Map.update!(b, &(&1 + h))
      end)

    Enum.reduce(Body.nodes(), conducted, fn
      {:core_k, _, _, _, _}, acc ->
        acc

      {f, _, _, blood, share}, acc ->
        blood =
          if f == :skin_k,
            do: skin_blood_l_per_m2_h(body) * p.area_m2,
            else: blood + share * shiver_w / p.blood_w_h_per_l_k

        h = p.blood_w_h_per_l_k * blood * (body.core_k - Map.fetch!(body, f))
        acc |> Map.update!(:core_k, &(&1 - h)) |> Map.update!(f, &(&1 + h))
    end)
  end

  # 皮肤经衣物向空气的散热，W/m²，返回 {对流辐射, 湿衣蒸发}。干衣：(T_皮 − T_空)/(R_衣 + R_空)，不蒸发。
  # 湿衣：衣面温度 T_面 满足 (T_皮 − T_面)/R_衣 = (T_面 − T_空)/R_空 + E(T_面)，E = 16.5·h_c·(p_s(T_面) − φ·p_s(T_空))·湿度（≥ 0）；
  # 左边随 T_面 单调减、右边单调增，二分求唯一根。两项之和 = 经衣物离开皮肤的热，所以蒸发热全部经衣物取自皮肤。
  defp surface_w(%Body{wetness: w} = body, clothing, air_r, _h_c, air_k, _p) when w <= 0,
    do: {(body.skin_k - air_k) / (clothing + air_r), 0.0}

  defp surface_w(body, clothing, air_r, h_c, air_k, p) do
    evap = fn t -> p.lewis_k_per_kpa * h_c * max(saturation_kpa(t) - p.relative_humidity * saturation_kpa(air_k), 0.0) * body.wetness end
    residual = fn t -> (body.skin_k - t) / clothing - (t - air_k) / air_r - evap.(t) end

    {lo, hi} =
      Enum.reduce(1..60, {min(body.skin_k, air_k) - 60.0, max(body.skin_k, air_k)}, fn _, {lo, hi} ->
        mid = (lo + hi) / 2
        if residual.(mid) > 0, do: {mid, hi}, else: {lo, mid}
      end)

    t = (lo + hi) / 2
    {(t - air_k) / air_r, evap.(t)}
  end

  # Magnus 式饱和水汽压（kPa，水面；Alduchov & Eskridge 1996），T 为开尔文。
  defp saturation_kpa(k) do
    c = k - 273.15
    0.61094 * :math.exp(17.625 * c / (c + 243.04))
  end

  # 湿度：先减去本步蒸发掉的水（drying_j / 潜热 / 湿透含水），再让浸水部分按 soak_s 趋于湿透（只升不降）；夹在 [0, 1]。
  defp wetness(w, drying_j, immersed, dt, p) do
    w = max(w - drying_j / (p.latent_j_per_g * 1000 * p.clothing_water_kg), 0.0)
    if immersed > w, do: w + (immersed - w) * (1 - :math.exp(-dt / p.soak_s)), else: w
  end

  # 烧伤剂量率（单位：60 °C 接触下的秒/秒）：44 °C 以下为 0，以上每升 burn_doubling_k 翻倍。
  # 指数上限 64 只为避免极高温（如熔岩）浮点溢出：2^64 秒远超三度阈值，结果不可观察地相同。
  defp burn_rate(tissue_k, p) do
    if tissue_k < p.burn_onset_k,
      do: 0.0,
      else: :math.pow(2, min((tissue_k - p.burn_reference_k) / p.burn_doubling_k, 64))
  end
end
