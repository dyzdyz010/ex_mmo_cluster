defmodule SceneServer.Body.Repair do
  @moduledoc """
  修复账（身体闭环 H1，Voxim `Docs/Magic.md` §6.5–6.7、§6.10）：伤口按真实组织量消耗蛋白质储备与合成能而愈合，进食补充储备。
  分类：Global system。纯函数，不持有进程；参数在 `SceneServer.Body.params/0`，依据见 `body/README.md`“修复账”。

  - **伤口** = 剂量（`burn_dose_s` / `frost_dose_k_s`，严重度由它推导）+ 愈合进度（`burn_heal` / `frost_heal`，0..1）。
    进度走到 1：剂量与进度同时归零、伤病消失。伤口总蛋白 = 组织块面积 × 深度（按严重度）× 密度 × 蛋白比例。
  - **速率**：`d(进度)/dt = M / T(严重度) × min(1, 循环功能水平)`，T = `Body.heal_s/2` 游戏内愈合时长
    （clamp(30 s × 真实天数^0.7, 30 s, 1800 s)），M 为速率倍数（魔法“调”留口，本增量恒 1）。再受底物约束：本步进度 × 伤口总蛋白不超过蛋白质储备，
    × 合成能 `synthesis_j_per_g` 不超过糖原 + 脂肪——付不起就停在原处，不欠账。多处伤口按烧伤、冻伤顺序共用同一储备。
  - **合成能**：由糖原 / 脂肪按寒战同一规则付（`Body.fuel_split/2`），全部作为热经 `Thermo.step/3` 的 `core_j` 进核心节点。
  - **加重**：愈合中伤口严重度上升（再次烧到更深一度、浅冻伤冻成深冻伤）时进度归零——已沉积的组织随新坏死一起失去，不返还蛋白。
  - **烧伤急性期计时** `burn_age_s`：烧伤存在时每步 + dt，愈合即归零。加重时从新严重度重新计时，但起点接上此刻的下压量
    （r₀ = min(1, 旧下压 / 新深度)）——否则 r 归零会让生命跳回；更深一度的满深度反而更浅（`Body.chronic_depth/2` 越长越弱），
    旧下压超过新满深度时 r₀ = 1，生命仍回升到新度的最低值（例：一度压满 0.25 后进二度，上限 0.75 → 0.848713）。
  - **进食**：蛋白质加到上限，食物能量（已含蛋白的 Atwater 份额）扣去进了蛋白储备的那部分后，先补糖原到满、余下进脂肪（不设上限）；
    超上限的蛋白被氧化，其能量留在能量里。

  账（每步闭合，单测逐项断言）：蛋白储备变化 = `food_protein_g − repair_protein_g`；糖原变化 = `food_glycogen_j − shiver_glycogen_j − synth_glycogen_j`，
  脂肪同理；`synth_j = synth_glycogen_j + synth_fat_j = core_j`；身体储热变化 = `stored_j`（含 `core_j`）。
  """

  alias SceneServer.Body
  alias SceneServer.Body.Thermo

  # {伤口, 进度字段, 剂量字段}；顺序即共用储备时的付账顺序。
  @wounds [{:burn, :burn_heal, :burn_dose_s}, {:frostbite, :frost_heal, :frost_dose_k_s}]

  @type account :: %{
          repair_protein_g: float(),
          synth_j: float(),
          synth_glycogen_j: float(),
          synth_fat_j: float()
        }

  @doc "伤口的总蛋白质，g：面积 × 深度 × 密度 × 蛋白比例（1 度烧伤 0.03 m² × 0.1 mm × 1000 kg/m³ × 30% = 0.9 g）。"
  @spec wound_protein_g(:burn | :frostbite, pos_integer()) :: float()
  def wound_protein_g(kind, severity) do
    p = Body.params()
    depth = p.wound_depth_m |> Map.fetch!(kind) |> Enum.at(severity - 1)
    p.contact_tissue_m2 * depth * p.tissue_density_kg_per_m3 * 1000 * p.tissue_protein_fraction
  end

  @doc """
  推进 `dt` 秒愈合（不改体温）。`m` 速率倍数，正数。
  返回 `{body, account}`，`synth_j` 是本步应作为 `core_j` 进核心的合成放热。
  """
  @spec heal(Body.t(), float(), number()) :: {Body.t(), account()}
  def heal(%Body{} = body, dt, m) do
    p = Body.params()
    zero = %{repair_protein_g: 0.0, synth_j: 0.0, synth_glycogen_j: 0.0, synth_fat_j: 0.0}

    Enum.reduce(@wounds, {body, zero}, fn {kind, heal_field, dose_field}, {b, acc} ->
      case Body.severity(b, kind) do
        0 ->
          {b, acc}

        severity ->
          total_g = wound_protein_g(kind, severity)
          heal = Map.fetch!(b, heal_field)
          fuel = b.reserve_j + b.fat_reserve_j

          step =
            Enum.min([
              1 - heal,
              Body.heal_rate(body, kind, m) * dt,
              b.protein_g / total_g,
              fuel / (total_g * p.synthesis_j_per_g)
            ])

          protein = min(step * total_g, b.protein_g)
          synth = min(protein * p.synthesis_j_per_g, fuel)
          {glycogen, fat} = Body.fuel_split(b, synth)

          b = %{b | protein_g: b.protein_g - protein, reserve_j: b.reserve_j - glycogen, fat_reserve_j: b.fat_reserve_j - fat}

          b =
            if step >= 1 - heal,
              do: b |> Map.put(heal_field, 0.0) |> Map.put(dose_field, 0.0),
              else: Map.put(b, heal_field, heal + step)

          {b,
           %{
             repair_protein_g: acc.repair_protein_g + protein,
             synth_j: acc.synth_j + synth,
             synth_glycogen_j: acc.synth_glycogen_j + glycogen,
             synth_fat_j: acc.synth_fat_j + fat
           }}
      end
    end)
  end

  @doc """
  身体的一次完整推进（Player 1 Hz 调用）：`heal/3` → `Thermo.step/3`（合成放热作 `core_j`）→ 加重的伤口进度归零。
  `inputs` 同 `Thermo.step/3`（不含 `core_j`）。返回 `{body, account}`，`account` = Thermo 账 ∪ 修复账。
  """
  @spec tick(Body.t(), float(), map(), number()) :: {Body.t(), map()}
  def tick(%Body{} = body, dt, inputs, m) do
    {healed, repair} = heal(body, dt, m)
    {next, account} = Thermo.step(healed, dt, Map.put(inputs, :core_j, repair.synth_j))

    next =
      Enum.reduce(@wounds, next, fn {kind, heal_field, _}, b ->
        if Body.severity(b, kind) > Body.severity(healed, kind), do: Map.put(b, heal_field, 0.0), else: b
      end)

    {%{next | burn_age_s: burn_age(next, healed, dt)}, Map.merge(account, repair)}
  end

  # 急性期计时：无烧伤 0；加重时按此刻（计时已走 dt）的旧下压量接续；否则 + dt。
  defp burn_age(next, healed, dt) do
    burn = Body.severity(next, :burn)

    cond do
      burn == 0 ->
        0.0

      burn > Body.severity(healed, :burn) ->
        depressed = Body.burn_depression(%{healed | burn_age_s: healed.burn_age_s + dt})
        Body.burn_onset_s() * min(1.0, depressed / Body.chronic_depth(:burn, burn))

      true ->
        healed.burn_age_s + dt
    end
  end

  @doc """
  吃下一份食物（目录“可食”轴的一株：蛋白 g、能量 J，能量为含蛋白在内的 Atwater 可代谢能）。
  蛋白加到上限 `protein_full_g`；进能量储备的 = 能量 − 进了蛋白储备的蛋白 × 16 747.2 J/g，先补糖原到满、余下进脂肪。
  储备满时照吃不拒绝（超上限的蛋白被氧化，能量全部进储备）。返回 `{body, account}`。
  """
  @spec eat(Body.t(), number(), number()) :: {Body.t(), map()}
  def eat(%Body{} = body, protein_g, energy_j) do
    p = Body.params()
    absorbed = min(protein_g, p.protein_full_g - body.protein_g)
    energy = energy_j - absorbed * p.protein_atwater_j_per_g
    glycogen = min(energy, p.reserve_full_j - body.reserve_j)

    {%{body | protein_g: body.protein_g + absorbed, reserve_j: body.reserve_j + glycogen,
       fat_reserve_j: body.fat_reserve_j + energy - glycogen},
     %{food_protein_g: absorbed, food_energy_j: energy, food_glycogen_j: glycogen, food_fat_j: energy - glycogen}}
  end
end
