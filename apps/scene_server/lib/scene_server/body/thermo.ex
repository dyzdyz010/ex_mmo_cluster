defmodule SceneServer.Body.Thermo do
  @moduledoc """
  身体体温的一步推进（Gagge 两节点模型的简化版，显式欧拉）。

  - 皮肤节点：吸收世界回传的接触热中没存进局部接触组织块的部分 `q_j − tissue_j`（含组织块经内部边送来的热），经服装与
    空气做干热交换（对流 + 线性化辐射；对流系数随风速，h_c = max(3.1, 8.3·v^0.6)），出汗蒸发、湿衣蒸发散热；
  - 局部接触组织块：温度只随 World 回传的 `tissue_j` 变化（World 热内核里它经鞋底 / 触碰接触边与世界换热、经内部边与皮肤
    换热）；烧伤 / 冻伤剂量按本步末组织块温度累计——伤害只由真实传入组织的热决定；
  - 核心节点：静息代谢 + 寒战产热，经组织导热与皮肤血流把热送到皮肤；寒战产热全部取自有限的糖原储备
    `reserve_j`，寒战上限按 储备/满储备 线性下降（储备为零即无寒战；上限饱和后储备按指数趋零）；
  - 体温调节（血管舒缩、寒战、出汗）按 `SceneServer.Body.systems/1` 的体温调节功能水平缩放；
  - 衣物湿度：浸水部分按 `soak_s` 时间常数趋于湿透；湿衣热阻在干 1 clo 与湿透值之间线性插值；露出水面的湿衣按 ASHRAE
    Lewis 关系蒸发（`drying_j`，潜热取自皮肤），湿度按蒸发掉的水量下降。最后推进濒死计时。

  能量账：本步身体储热变化 `stored_j = q_j + metabolic_j − convection_j − sweat_j − drying_j`
  = C_core·ΔT_core + C_skin·ΔT_skin + C_tissue·ΔT_tissue；核心-皮肤、组织块-皮肤之间的内部传热两边抵消，不进账。
  `metabolic_j` 含寒战 `shiver_j`，后者等于本步储备减少量（储备 → 体热，闭合）。

  浸没：`immersed` 为浸在液体里的体表比例（World 按身体与液体宏格的竖向重叠算出）；这部分皮肤不与空气换热、
  不蒸发出汗，与液体的换热由世界回传的 `q_j` 体现。

  未建模（首片已知偏差）：呼吸散热、湿度对出汗蒸发的上限、辐射加热（附近火焰）、湿衣吸水的水温与世界水量。
  """

  alias SceneServer.Body

  @type inputs :: %{
          required(:q_j) => float(),
          required(:air_k) => float(),
          optional(:tissue_j) => float(),
          optional(:wind_mps) => float(),
          optional(:immersed) => float()
        }
  @type account :: %{
          stored_j: float(),
          q_j: float(),
          tissue_j: float(),
          metabolic_j: float(),
          convection_j: float(),
          sweat_j: float(),
          drying_j: float(),
          shiver_j: float()
        }

  @doc """
  推进 `dt` 秒。

  `inputs`：
  - `q_j`：世界算出的本步接触热，J，正为身体吸热（皮肤与组织块合计）；
  - `tissue_j`：其中存进局部接触组织块的部分，J（缺省 0）；
  - `air_k`：环境空气温度，K；
  - `wind_mps`：风速，m/s（缺省 0 = 静止空气）；
  - `immersed`：浸在液体里的体表比例 0..1（缺省 0）；空气干热交换、出汗与湿衣蒸发按 1 − immersed 缩放。

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

    cold_core = max(p.core_set_k - body.core_k, 0.0)
    warm_core = max(body.core_k - p.core_set_k, 0.0)
    cold_skin = max(p.skin_set_k - body.skin_k, 0.0)
    warm_skin = max(body.skin_k - p.skin_set_k, 0.0)

    core_to_skin_w = core_to_skin_w_per_m2_k(body) * area * (body.core_k - body.skin_k)

    shiver_cap = p.shiver_max_w_per_m2 * body.reserve_j / p.reserve_full_j

    shiver_w =
      level * min(p.shiver_w_per_m2_k2 * cold_skin * cold_core, shiver_cap) * area

    sweat_w =
      level * p.sweat_g_per_m2_h_k * warm_core * :math.exp(warm_skin / p.sweat_skin_scale_k) *
        p.latent_j_per_g / 3600 * exposed

    # Gagge / ASHRAE：静止空气（自然对流）下限 3.1，受迫对流 8.3·v^0.6 W/(m²·K)。v = 0 时即 3.1，与引入风速前逐位相同。
    convective = max(p.convective_w_per_m2_k, p.wind_convective_w_per_m2_k * :math.pow(Map.get(inputs, :wind_mps, 0.0), p.wind_exponent))
    air_r = 1 / (convective + p.radiative_w_per_m2_k)
    # 湿衣热阻：干 1 clo 与湿透值（BodyContact 浸没边同一常数）之间按湿度线性插值；干衣与引入湿衣前逐位相同。
    clothing = p.clothing_m2_k_per_w + body.wetness * (VoxelRegion.BodyContact.params().wet_m2_k_per_w - p.clothing_m2_k_per_w)
    convection_w = exposed * (body.skin_k - air_k) / (clothing + air_r)
    drying_w = drying_w(body, clothing, air_r, convective, air_k, exposed, p)

    shiver_j = min(shiver_w * dt, body.reserve_j)
    metabolic_j = p.metabolic_w_per_m2 * area * dt + shiver_j
    core_to_skin_j = core_to_skin_w * dt
    convection_j = convection_w * dt
    sweat_j = sweat_w * dt
    drying_j = drying_w * dt
    tissue_k = body.tissue_k + tissue_q / Body.tissue_capacity_j_per_k()

    body = %{
      body
      | core_k: body.core_k + (metabolic_j - core_to_skin_j) / Body.core_capacity_j_per_k(),
        skin_k:
          body.skin_k +
            (q - tissue_q + core_to_skin_j - convection_j - sweat_j - drying_j) / Body.skin_capacity_j_per_k(),
        tissue_k: tissue_k,
        burn_dose_s: body.burn_dose_s + burn_rate(tissue_k, p) * dt,
        frost_dose_k_s: body.frost_dose_k_s + max(p.frost_onset_k - tissue_k, 0.0) * dt,
        reserve_j: body.reserve_j - shiver_j,
        wetness: wetness(body.wetness, drying_j, immersed, dt, p)
    }

    account = %{
      stored_j: q + metabolic_j - convection_j - sweat_j - drying_j,
      q_j: q,
      tissue_j: tissue_q,
      metabolic_j: metabolic_j,
      convection_j: convection_j,
      sweat_j: sweat_j,
      drying_j: drying_j,
      shiver_j: shiver_j
    }

    {Body.progress(body, dt), account}
  end

  @doc """
  本步核心-皮肤导热 K_cs，W/(m²·K) = 组织导热 + 血液热容 × 皮肤血流（Gagge 1971；血流随体温调节的血管舒张 / 收缩）。
  局部接触组织块与皮肤之间的导热 = 组织块面积 × K_cs（Player 每秒随身体报告给 World）。
  """
  @spec core_to_skin_w_per_m2_k(Body.t()) :: float()
  def core_to_skin_w_per_m2_k(%Body{} = body) do
    p = Body.params()
    level = Body.systems(body).thermoregulation
    warm_core = max(body.core_k - p.core_set_k, 0.0)
    cold_skin = max(p.skin_set_k - body.skin_k, 0.0)

    skin_blood =
      (p.skin_blood_base_l_per_m2_h + level * p.vasodilation_l_per_m2_h_k * warm_core) /
        (1 + level * p.vasoconstriction_per_k * cold_skin)

    p.tissue_w_per_m2_k + p.blood_w_h_per_l_k * skin_blood
  end

  # 湿衣蒸发（W）：E = LR·h_c·(p_s(T_衣) − φ·p_s(T_空))·露出面积·湿度，衣面温度取干热回路分压；推动力为负（衣面比空气湿冷）时不蒸发。
  defp drying_w(%Body{wetness: w}, _clothing, _air_r, _h_c, _air_k, _exposed, _p) when w <= 0, do: 0.0

  defp drying_w(body, clothing, air_r, h_c, air_k, exposed, p) do
    surface_k = air_k + (body.skin_k - air_k) * air_r / (clothing + air_r)
    gradient = saturation_kpa(surface_k) - p.relative_humidity * saturation_kpa(air_k)
    p.lewis_k_per_kpa * h_c * max(gradient, 0.0) * exposed * body.wetness
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
