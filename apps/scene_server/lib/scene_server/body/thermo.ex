defmodule SceneServer.Body.Thermo do
  @moduledoc """
  身体体温的一步推进（Gagge 两节点模型的简化版，显式欧拉）。

  - 皮肤节点：吸收世界回传的接触热 `q_j`，经服装与空气做干热交换（对流 + 线性化辐射；对流系数随风速，
    h_c = max(3.1, 8.3·v^0.6)），出汗蒸发散热；
  - 核心节点：静息代谢 + 寒战产热，经组织导热与皮肤血流把热送到皮肤；寒战产热全部取自有限的糖原储备
    `reserve_j`，寒战上限按 储备/满储备 线性下降（储备为零即无寒战；上限饱和后储备按指数趋零）；
  - 体温调节（血管舒缩、寒战、出汗）按 `SceneServer.Body.systems/1` 的体温调节功能水平缩放；
  - 接触温度累计烧伤 / 冻伤剂量，最后推进濒死计时。鞋底接触隔着鞋底：脚底组织温度取核心经核心-皮肤导热、
    经鞋底热阻到地面的稳态分压 `T_脚 = T_地 + (T_核 − T_地)·R_鞋/(1/K_cs + R_鞋)`（K_cs 为本步核心-皮肤导热，W/(m²·K)）；
    裸接触（浸没、触碰）直接取接触温度。剂量按两者中的最高温度累计。

  能量账：本步身体储热变化 `stored_j = q_j + metabolic_j − convection_j − sweat_j`，核心-皮肤之间的内部
  传热两边抵消，不进账。`metabolic_j` 含寒战 `shiver_j`，后者等于本步储备减少量（储备 → 体热，闭合）。

  浸没：`immersed` 为浸在液体里的体表比例（World 按身体与液体宏格的竖向重叠算出）；这部分皮肤不与空气换热、
  不蒸发出汗，与液体的换热由世界回传的 `q_j` 体现。

  未建模（首片已知偏差）：呼吸散热、湿度对出汗蒸发的上限、辐射加热。
  """

  alias SceneServer.Body

  @type inputs :: %{
          required(:q_j) => float(),
          required(:max_contact_k) => float() | nil,
          required(:air_k) => float(),
          optional(:sole_k) => float(),
          optional(:wind_mps) => float(),
          optional(:immersed) => float()
        }
  @type account :: %{
          stored_j: float(),
          q_j: float(),
          metabolic_j: float(),
          convection_j: float(),
          sweat_j: float(),
          shiver_j: float()
        }

  @doc """
  推进 `dt` 秒。

  `inputs`：
  - `q_j`：世界算出的本步接触热，J，正为身体吸热；
  - `max_contact_k`：本步裸接触（浸没液体、触碰拟态）的最高温度，K；无裸接触时为 nil；
  - `sole_k`：脚下地面温度，K（可选；Scene 传 World 回传的鞋底格温度，无鞋底接触时传所在区空气温度 = 区温地面）；
    与 `max_contact_k` 至少给一项；
  - `air_k`：环境空气温度，K；
  - `wind_mps`：风速，m/s（缺省 0 = 静止空气）；
  - `immersed`：浸在液体里的体表比例 0..1（缺省 0）；空气干热交换与出汗蒸发按 1 − immersed 缩放。

  返回 `{body, account}`，`account` 各项单位 J，`convection_j` / `sweat_j` 为正表示身体散热。
  """
  @spec step(Body.t(), float(), inputs()) :: {Body.t(), account()}
  def step(%Body{} = body, dt, %{q_j: q, max_contact_k: contact_k, air_k: air_k} = inputs) do
    p = Body.params()
    level = Body.systems(body).thermoregulation
    area = p.area_m2
    exposed = area * (1 - Map.get(inputs, :immersed, 0.0))

    cold_core = max(p.core_set_k - body.core_k, 0.0)
    warm_core = max(body.core_k - p.core_set_k, 0.0)
    cold_skin = max(p.skin_set_k - body.skin_k, 0.0)
    warm_skin = max(body.skin_k - p.skin_set_k, 0.0)

    skin_blood =
      (p.skin_blood_base_l_per_m2_h + level * p.vasodilation_l_per_m2_h_k * warm_core) /
        (1 + level * p.vasoconstriction_per_k * cold_skin)

    core_to_skin_w_per_m2_k = p.tissue_w_per_m2_k + p.blood_w_h_per_l_k * skin_blood
    core_to_skin_w = core_to_skin_w_per_m2_k * area * (body.core_k - body.skin_k)

    shiver_cap = p.shiver_max_w_per_m2 * body.reserve_j / p.reserve_full_j

    shiver_w =
      level * min(p.shiver_w_per_m2_k2 * cold_skin * cold_core, shiver_cap) * area

    sweat_w =
      level * p.sweat_g_per_m2_h_k * warm_core * :math.exp(warm_skin / p.sweat_skin_scale_k) *
        p.latent_j_per_g / 3600 * exposed

    # Gagge / ASHRAE：静止空气（自然对流）下限 3.1，受迫对流 8.3·v^0.6 W/(m²·K)。v = 0 时即 3.1，与引入风速前逐位相同。
    convective = max(p.convective_w_per_m2_k, p.wind_convective_w_per_m2_k * :math.pow(Map.get(inputs, :wind_mps, 0.0), p.wind_exponent))

    convection_w =
      exposed * (body.skin_k - air_k) /
        (p.clothing_m2_k_per_w + 1 / (convective + p.radiative_w_per_m2_k))

    contact_k = dose_k(inputs[:sole_k], contact_k, body.core_k, core_to_skin_w_per_m2_k)

    shiver_j = min(shiver_w * dt, body.reserve_j)
    metabolic_j = p.metabolic_w_per_m2 * area * dt + shiver_j
    core_to_skin_j = core_to_skin_w * dt
    convection_j = convection_w * dt
    sweat_j = sweat_w * dt

    body = %{
      body
      | core_k: body.core_k + (metabolic_j - core_to_skin_j) / Body.core_capacity_j_per_k(),
        skin_k:
          body.skin_k +
            (q + core_to_skin_j - convection_j - sweat_j) / Body.skin_capacity_j_per_k(),
        burn_dose_s: body.burn_dose_s + burn_rate(contact_k, p) * dt,
        frost_dose_k_s: body.frost_dose_k_s + max(p.frost_onset_k - contact_k, 0.0) * dt,
        reserve_j: body.reserve_j - shiver_j
    }

    account = %{
      stored_j: q + metabolic_j - convection_j - sweat_j,
      q_j: q,
      metabolic_j: metabolic_j,
      convection_j: convection_j,
      sweat_j: sweat_j,
      shiver_j: shiver_j
    }

    {Body.progress(body, dt), account}
  end

  # 剂量温度：鞋底接触折算成脚底组织温度（核心 ↔ 地面的稳态分压，组织侧 1/K_cs、外侧鞋底热阻），与裸接触取最高。
  defp dose_k(nil, bare_k, _core_k, _k_cs), do: bare_k

  defp dose_k(sole_k, bare_k, core_k, k_cs) do
    r = VoxelRegion.BodyContact.params().sole_m2_k_per_w
    foot_k = sole_k + (core_k - sole_k) * r / (1 / k_cs + r)
    if bare_k, do: max(foot_k, bare_k), else: foot_k
  end

  # 烧伤剂量率（单位：60 °C 接触下的秒/秒）：44 °C 以下为 0，以上每升 burn_doubling_k 翻倍。
  # 指数上限 64 只为避免极高温（如熔岩）浮点溢出：2^64 秒远超三度阈值，结果不可观察地相同。
  defp burn_rate(contact_k, p) do
    if contact_k < p.burn_onset_k,
      do: 0.0,
      else: :math.pow(2, min((contact_k - p.burn_reference_k) / p.burn_doubling_k, 64))
  end
end
