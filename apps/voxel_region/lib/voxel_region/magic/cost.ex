defmodule VoxelRegion.Magic.Cost do
  @moduledoc """
  全局系统功能（魔法增量 1–2、前摇）：施法成本、前摇时长、相干度与走火判定、取能分账的唯一实现
  （Voxim Docs/Magic.md §4、§13.6）。纯值计算，不读 World；报价（action 0）与施放共用同一函数，客户端只显示
  服务端报价与广播的各步时长，不复制公式。

  - 物理能量 E_phys：`energy.draw` 为 0（取能本身不耗施法者能量），`act.heat` 为其 `energy_j`；
    `form.semblance` 为拟态的热内容 C·(T − T_amb)（C = 质量 × 目录比热）加发光预算 glow_w × lifetime_s；
    `act.throw` 为动能 ½·m·v²（m 取同一程序里拟态的质量）；`act.dispel` 与 `act.break_on_hit` 为 0（释放的是拟态自身剩余能量）。
  - 构型损耗（§13.6，取代增量 1 的控制开销 e0·(…)^α）：第 i 步姿态 q_i 取目录（弧度），q_0 = 目录 rest_pose（六维）；
    d_i = ‖q_i − q_{i−1}‖₂，S_i / H_i 为前 i 步权重 / 物理能量之和，维护功率 b_i = b0·(S_i + H_i/E_ref)^α；
    构型调整 T_adj = d_i·√(η/b_i)，注能 T_inj = E_i / P_max，本步损耗 L_i = 2·d_i·√(η·b_i) + b_i·T_inj。
    前摇 = Σ(T_adj + T_inj) + release_lead_s，E_loss = Σ L_i + b_final·release_lead_s；施放总支出 = E_phys + E_loss。
  - S > 相干度 → `:misfire_coherence`（先判）；可支付能量 < 总支出 → `:misfire_energy`。
  - 取能：ΔE = min(请求, 石储能, 容量 − 余额)；施法者得 η·ΔE，(1 − η)·ΔE 为取能损耗。施法者账是整数 mJ，
    分账在整数 mJ 上做（`draw/4`）；报价与走火的能量比较仍按 J 给出，施放结算处换成整数扣款（`World.Casting`）。
  """

  alias VoxelRegion.Magic.Semblance


  @doc """
  程序报价：结构权重、物理能量、构型损耗、总支出（J）、前摇（s）与各步 `{调整 s, 注能 s}`。
  含拟态的程序需给出环境温度 `ambient_k`。
  """
  def quote(%{steps: steps}, catalog, ambient_k \\ nil) do
    form = Enum.find_value(steps, fn %{sym: sym, args: args} -> sym == "form.semblance" && args end)

    {parts, {_, structure, stored}} =
      Enum.map_reduce(steps, {catalog.rest_pose, 0.0, 0.0}, fn %{sym: sym} = step, {previous, s, h} ->
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
    hold = catalog.b0_w * :math.pow(structure + stored / catalog.e_ref_j, catalog.alpha) * catalog.release_lead_s
    loss = Enum.sum(for {_, _, _, l} <- parts, do: l) + hold

    %{structure: structure,
      physical_j: physical, loss_j: loss, total_j: physical + loss,
      windup_s: Enum.sum(for {_, a, i, _} <- parts, do: a + i) + catalog.release_lead_s,
      steps: for({_, a, i, _} <- parts, do: {a, i})}
  end

  defp physical_j(%{sym: "act.heat", args: %{"energy_j" => energy}}, _, _, _), do: energy
  defp physical_j(%{sym: sym}, _, _, _) when sym in ["energy.draw", "act.dispel", "act.break_on_hit"], do: 0.0

  defp physical_j(%{sym: "form.semblance", args: form}, _, catalog, ambient), do: Semblance.form_j(form, catalog, ambient)
  defp physical_j(%{sym: "act.throw", args: %{"speed_mps" => v}}, form, _, _), do: Semblance.kinetic_j(form["mass_kg"], v)

  @doc "走火判定：`nil` = 正常施放；相干度先于能量。`available_j` 是施放时可用来支付的能量。"
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
