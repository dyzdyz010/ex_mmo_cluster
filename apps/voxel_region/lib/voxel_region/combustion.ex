defmodule VoxelRegion.Combustion do
  @moduledoc "全局系统功能：B6 充足氧气下的有限燃料燃烧规则。"
  @fuel_epsilon_j 1.0e-9

  @doc "已初始化燃料达到耗尽阈值；无记录表示尚未点燃，不虚构余量。"
  def exhausted?(row),
    do: is_map_key(row, :remaining_fuel_j) and row.remaining_fuel_j <= @fuel_epsilon_j

  @doc "读取已发布目录的 B6 三个材料字段；未发布完整字段的材料不可燃。"
  def properties(material) do
    %{
      ignition_kelvin: Map.get(material, "ignition_kelvin"),
      fuel_energy_per_macro_j: Map.get(material, "fuel_energy_per_macro_j"),
      burn_power_per_macro_w: Map.get(material, "burn_power_per_macro_w")
    }
  end

  def combustible?(material) do
    %{ignition_kelvin: ignition, fuel_energy_per_macro_j: fuel, burn_power_per_macro_w: power} =
      properties(material)

    is_number(ignition) and ignition > 0 and is_number(fuel) and fuel > 0 and
      is_number(power) and power > 0
  end

  def capacity_j(material, volume),
    do: properties(material).fuel_energy_per_macro_j * volume

  def power_w(material, volume),
    do: properties(material).burn_power_per_macro_w * volume

  @doc "回收实际剩余化学燃料对应的整数材料量；未点燃的材料保持完整数量。"
  def recover_units(row, material, volume, units) do
    case Map.fetch(row, :remaining_fuel_j) do
      :error -> units
      {:ok, remaining} -> floor(units * remaining / capacity_j(material, volume))
    end
  end

  @doc "点燃只创建燃烧标记；首次燃料来自材料实际体积，已有余量绝不补满。"
  def ignite(row, material, volume) do
    if combustible?(material) and not Map.get(row, :burning, false) do
      remaining =
        case Map.get(row, :remaining_fuel_j) do
          value when is_number(value) -> max(0.0, value)
          nil -> capacity_j(material, volume)
        end

      Map.merge(row, %{
        burning: remaining > 0,
        remaining_fuel_j: remaining,
        power_w: if(remaining > 0, do: power_w(material, volume), else: 0.0)
      })
    else
      row
    end
  end

  def extinguish(row), do: Map.merge(row, %{burning: false, power_w: 0.0})

  @doc "推进一个模拟时间步，返回新行、放热 J、实际耗燃 J。"
  def step(row, dt) do
    power = if row.burning, do: row.power_w, else: 0.0
    fuel = max(0.0, Map.get(row, :remaining_fuel_j, 0.0))
    used = min(fuel, power * dt)
    {consume(Map.put(row, :remaining_fuel_j, fuel), used), used, used}
  end

  @doc "从已初始化的余量中取走 used 焦耳化学燃料；取尽即熄灭，由既有耗尽规则移除。"
  def consume(row, used) do
    left = row.remaining_fuel_j - used
    alive = left > @fuel_epsilon_j and Map.get(row, :burning, false)

    row
    |> Map.put(:remaining_fuel_j, left)
    |> Map.put(:power_w, if(alive, do: row.power_w, else: 0.0))
    |> Map.put(:burning, alive)
  end
end
