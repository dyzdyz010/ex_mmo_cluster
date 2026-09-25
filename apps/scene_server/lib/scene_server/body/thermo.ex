defmodule SceneServer.Body.Thermo do
  @moduledoc """
  身体体温的一步推进（Gagge 两节点模型的简化版，显式欧拉）。

  - 皮肤节点：吸收世界回传的接触热 `q_j`，经服装与空气做干热交换（对流 + 线性化辐射），出汗蒸发散热；
  - 核心节点：静息代谢 + 寒战产热，经组织导热与皮肤血流把热送到皮肤；
  - 体温调节（血管舒缩、寒战、出汗）按 `SceneServer.Body.systems/1` 的体温调节功能水平缩放；
  - 接触温度累计烧伤 / 冻伤剂量，最后推进濒死计时。

  能量账：本步身体储热变化 `stored_j = q_j + metabolic_j − convection_j − sweat_j`，核心-皮肤之间的内部
  传热两边抵消，不进账。

  浸没：`immersed` 为浸在液体里的体表比例（World 按身体与液体宏格的竖向重叠算出）；这部分皮肤不与空气换热、
  不蒸发出汗，与液体的换热由世界回传的 `q_j` 体现。

  未建模（首片已知偏差）：呼吸散热、湿度对出汗蒸发的上限、辐射加热。
  """

  alias SceneServer.Body

  @type inputs :: %{
          required(:q_j) => float(),
          required(:max_contact_k) => float(),
          required(:air_k) => float(),
          optional(:immersed) => float()
        }
  @type account :: %{
          stored_j: float(),
          q_j: float(),
          metabolic_j: float(),
          convection_j: float(),
          sweat_j: float()
        }

  @doc """
  推进 `dt` 秒。

  `inputs`：
  - `q_j`：世界算出的本步接触热，J，正为身体吸热；
  - `max_contact_k`：本步接触宏格的最高温度，K；**无接触时传空气温度**（低于烧伤阈值、高于冻伤阈值即不累计）；
  - `air_k`：环境空气温度，K；
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

    core_to_skin_w =
      (p.tissue_w_per_m2_k + p.blood_w_h_per_l_k * skin_blood) * area *
        (body.core_k - body.skin_k)

    shiver_w =
      level * min(p.shiver_w_per_m2_k2 * cold_skin * cold_core, p.shiver_max_w_per_m2) * area

    sweat_w =
      level * p.sweat_g_per_m2_h_k * warm_core * :math.exp(warm_skin / p.sweat_skin_scale_k) *
        p.latent_j_per_g / 3600 * exposed

    convection_w =
      exposed * (body.skin_k - air_k) /
        (p.clothing_m2_k_per_w + 1 / (p.convective_w_per_m2_k + p.radiative_w_per_m2_k))

    metabolic_j = (p.metabolic_w_per_m2 * area + shiver_w) * dt
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
        frost_dose_k_s: body.frost_dose_k_s + max(p.frost_onset_k - contact_k, 0.0) * dt
    }

    account = %{
      stored_j: q + metabolic_j - convection_j - sweat_j,
      q_j: q,
      metabolic_j: metabolic_j,
      convection_j: convection_j,
      sweat_j: sweat_j
    }

    {Body.progress(body, dt), account}
  end

  # 烧伤剂量率（单位：60 °C 接触下的秒/秒）：44 °C 以下为 0，以上每升 burn_doubling_k 翻倍。
  # 指数上限 64 只为避免极高温（如熔岩）浮点溢出：2^64 秒远超三度阈值，结果不可观察地相同。
  defp burn_rate(contact_k, p) do
    if contact_k < p.burn_onset_k,
      do: 0.0,
      else: :math.pow(2, min((contact_k - p.burn_reference_k) / p.burn_doubling_k, 64))
  end
end
