defmodule VoxelRegion.Magic.Cost do
  @moduledoc """
  全局系统功能（魔法增量 1）：施法成本、相干度与走火判定、取能分账的唯一实现（Voxim Docs/Magic.md §4）。
  纯值计算，不读 World；报价（action 0）与施放共用同一函数，客户端只显示服务端报价，不复制公式。

  - 物理能量 E_phys：`energy.draw` 为 0（取能本身不耗施法者能量），`act.heat` 为其 `energy_j`。
  - 结构权重 S = Σ 符号 weight；控制开销 E_ctl = e0 · (S + E_phys / E_ref)^α。整道程序合并计价，
    α > 1 时合并开销大于拆开之和（超线性），拆步不能降价。
  - 施放总支出 = E_phys + E_ctl。S > 相干度 → `:misfire_coherence`（先判）；可支付能量 < 总支出 → `:misfire_energy`。
  - 取能：ΔE = min(请求, 石储能, 容量 − 余额)；施法者得 η·ΔE，(1 − η)·ΔE 为取能损耗。
  """

  @doc "程序报价：结构权重、物理能量、控制开销与总支出（J）。"
  def quote(%{steps: steps}, catalog) do
    structure = Enum.sum(for %{sym: sym} <- steps, do: catalog.symbols[sym].weight * 1.0)
    physical = Enum.sum(for step <- steps, do: physical_j(step))
    control = catalog.e0_j * :math.pow(structure + physical / catalog.e_ref_j, catalog.alpha)
    %{structure: structure, physical_j: physical, control_j: control, total_j: physical + control}
  end

  defp physical_j(%{sym: "act.heat", args: %{"energy_j" => energy}}), do: energy
  defp physical_j(%{sym: "energy.draw"}), do: 0.0

  @doc "走火判定：`nil` = 正常施放；相干度先于能量。`available_j` 是施放时可用来支付的能量。"
  def misfire(quote, available_j, catalog) do
    cond do
      quote.structure > catalog.coherence -> :misfire_coherence
      available_j < quote.total_j -> :misfire_energy
      true -> nil
    end
  end

  @doc "取能分账：石减少 taken_j = 施法者取得 gained_j + 损耗 loss_j。"
  def draw(requested_j, stored_j, balance_j, catalog) do
    taken = min(requested_j, min(stored_j, catalog.capacity_j - balance_j))
    gained = catalog.draw_efficiency * taken
    %{taken_j: taken, gained_j: gained, loss_j: taken - gained}
  end
end
