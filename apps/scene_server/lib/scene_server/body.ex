defmodule SceneServer.Body do
  @moduledoc """
  角色身体 L1 的纯值状态（Voxim `Docs/Magic.md` §6）。

  首片只接体温这一路：核心 / 皮肤两节点温度、烧伤与冻伤的组织损伤剂量、致命系统跌破阈值的持续时间和
  存活状态。以下都是由这些字段**推导**的只读视图，不另存第二份：

  - `systems/1`：体温调节、循环、神经三个系统的功能水平（1.0 = 正常，0.0 = 完全抑制）；
  - `life/1`：由致命系统（循环、神经）推导的生命值 0..100；
  - `injuries/1`：伤病表，每条 = 标签 + 部位 + 严重度 + 进展规则。

  状态推进由 `SceneServer.Body.Thermo.step/3` 完成；本模块只放数据、参数与推导。

  所有参数集中在 `params/0`（首片为模块常量，**待资产化**）。温度一律用开尔文，与
  `VoxelRegion.World` 热内核一致。参数取值与依据见同目录 `body/README.md`。
  """

  @c 273.15

  @params %{
    # —— 人体几何与热容（ASHRAE Fundamentals 第 9 章两节点模型标准人）——
    area_m2: 1.8,
    mass_kg: 70.0,
    specific_heat_j_per_kg_k: 3490.0,
    skin_mass_fraction: 0.1,
    # —— 产热（1 met 静息代谢；寒战峰值约为静息的 5 倍，即额外 4 met）——
    metabolic_w_per_m2: 58.2,
    shiver_w_per_m2_k2: 19.4,
    shiver_max_w_per_m2: 232.8,
    # —— 调定点（Gagge 1971）——
    core_set_k: 36.8 + @c,
    skin_set_k: 34.0 + @c,
    # —— 核心-皮肤传导：组织导热 + 皮肤血流 ——
    tissue_w_per_m2_k: 5.28,
    blood_w_h_per_l_k: 1.163,
    skin_blood_base_l_per_m2_h: 6.3,
    vasodilation_l_per_m2_h_k: 50.0,
    vasoconstriction_per_k: 0.5,
    # —— 出汗：170 g/(m²·h·K)，蒸发潜热 2430 J/g，不设湿度上限 ——
    sweat_g_per_m2_h_k: 170.0,
    sweat_skin_scale_k: 10.7,
    latent_j_per_g: 2430.0,
    # —— 皮肤-空气干热交换：静止空气对流 + 线性化辐射，外加 1 clo 服装热阻 ——
    convective_w_per_m2_k: 3.1,
    radiative_w_per_m2_k: 4.7,
    clothing_m2_k_per_w: 0.155,
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
    # —— 烧伤：接触温度 ≥ 44 °C 起累计剂量，剂量率 2^((T-60 °C)/1.32 K)，单位 = 60 °C 下的秒 ——
    burn_onset_k: 44.0 + @c,
    burn_reference_k: 60.0 + @c,
    burn_doubling_k: 1.32,
    burn_degree_dose_s: [1.0, 2.5, 5.0],
    # —— 冻伤：接触温度低于组织冰点 −0.55 °C 起累计 K·s ——
    frost_onset_k: -0.55 + @c,
    frostbite_dose_k_s: [600.0]
  }

  defstruct core_k: 36.8 + @c,
            skin_k: 34.0 + @c,
            burn_dose_s: 0.0,
            frost_dose_k_s: 0.0,
            lethal_s: 0.0,
            status: :alive

  @type status :: :alive | :dying | :dead
  @type t :: %__MODULE__{
          core_k: float(),
          skin_k: float(),
          burn_dose_s: float(),
          frost_dose_k_s: float(),
          lethal_s: float(),
          status: status()
        }
  @type injury :: %{
          tag: String.t(),
          part: :whole | :contact,
          severity: pos_integer(),
          progression: :tracks_core | :permanent
        }

  @doc "身体 L1 全部参数（首片常量，待资产化）。"
  @spec params() :: map()
  def params, do: @params

  @doc "调定点上的健康身体：核心 36.8 °C、皮肤 34 °C、无伤病、存活。"
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "皮肤节点热容 J/K。"
  @spec skin_capacity_j_per_k() :: float()
  def skin_capacity_j_per_k,
    do: @params.skin_mass_fraction * @params.mass_kg * @params.specific_heat_j_per_kg_k

  @doc "核心节点热容 J/K。"
  @spec core_capacity_j_per_k() :: float()
  def core_capacity_j_per_k,
    do: (1 - @params.skin_mass_fraction) * @params.mass_kg * @params.specific_heat_j_per_kg_k

  @doc """
  三个系统的功能水平，由核心温度按各自功能带线性推导，夹在 [0, 1]。

  首片只有体温这一路写入，故不会出现亢进（> 1.0）；亢进留给后续魔法“调”动词。
  """
  @spec systems(t()) :: %{thermoregulation: float(), circulation: float(), nervous: float()}
  def systems(%__MODULE__{core_k: core}) do
    %{
      thermoregulation: level(core, @params.thermoregulation_band),
      circulation: level(core, @params.circulation_band),
      nervous: level(core, @params.nervous_band)
    }
  end

  @doc "由致命系统（循环、神经）推导的生命值 0..100：取两者最低功能水平 × 100 后四舍五入。"
  @spec life(t()) :: 0..100
  def life(%__MODULE__{} = body), do: round(100 * lethal_level(body))

  @doc """
  当前伤病表。

  - `temperature.hypothermia` / `temperature.hyperthermia`：部位 `:whole`，严重度随核心温度，
    回到正常带即消失（`:tracks_core`）；
  - `trauma.thermal.burn`（1–3 度）/ `trauma.thermal.frostbite`：部位 `:contact`，严重度由累计组织
    损伤剂量决定，只增不减（`:permanent`）——首片按设计“伤口撤不回”，自然愈合留给后续切片。
  """
  @spec injuries(t()) :: [injury()]
  def injuries(%__MODULE__{} = body) do
    [
      {"temperature.hypothermia", :whole,
       Enum.count(@params.hypothermia_below_k, &(body.core_k < &1)), :tracks_core},
      {"temperature.hyperthermia", :whole,
       Enum.count(@params.hyperthermia_above_k, &(body.core_k > &1)), :tracks_core},
      {"trauma.thermal.burn", :contact,
       Enum.count(@params.burn_degree_dose_s, &(body.burn_dose_s >= &1)), :permanent},
      {"trauma.thermal.frostbite", :contact,
       Enum.count(@params.frostbite_dose_k_s, &(body.frost_dose_k_s >= &1)), :permanent}
    ]
    |> Enum.filter(fn {_tag, _part, severity, _rule} -> severity > 0 end)
    |> Enum.map(fn {tag, part, severity, rule} ->
      %{tag: tag, part: part, severity: severity, progression: rule}
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
