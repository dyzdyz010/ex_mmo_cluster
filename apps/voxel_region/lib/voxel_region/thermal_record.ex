defmodule VoxelRegion.ThermalRecord do
  @moduledoc """
  全局系统功能：热节点工作副本与属性记录之间的换算（纯函数，不读取 World）。

  装入：由内核节点（几何与目录）和当前记录得到原生侧的静态量与动态量，与原 `ThermalBatch.prepare/6` 的读取相同
  （无记录时温度为所在气候区空气温度，相态节点的焓按 `Phase.energy/4`）。写回：把原生侧的当前值放回记录，
  字段集合与原每步结算写出的记录相同——温度、HP 总是写；燃料、功率、燃烧只在记录已有燃料时写；焓、采掘基线只在存在时写。
  """
  alias VoxelRegion.Phase

  @fields [:temperature_kelvin, :hp, :max_hp, :remaining_fuel_j, :power_w, :burning, :pick_baseline_hp, :phase_energy_j]

  @doc """
  节点静态量 `{热容, 导热率, 耐热阈值, 暴露面, 空气温度, 点燃温度, 共享完整度?, 整宏格?, 相态目录值}`；
  `phase?` 为该节点是否按相态宏格结算（有限数量的相态材料）。
  """
  def static(node, ambient, phase?) do
    m = node.material
    granularity = node.target.granularity

    {node.capacity * 1.0, m["thermal_conductivity"] * 1.0, m["heat_resistance_kelvin"] * 1.0,
     node.exposed_faces * 1.0, ambient * 1.0, node.ignition, granularity in [1, 4], granularity == 0,
     if(phase?, do: {m["phase_transition_kelvin"] * 1.0, m["latent_heat_per_macro_j"] * 1.0,
                     m["heat_capacity_per_macro"] * 1.0, Phase.liquid?(node.target.material)})}
  end

  @doc "记录的动态量 `{温度, HP, MaxHP, 燃料, 功率, 燃烧?, 采掘基线, 相态 {体积, 焓, 记录已有焓?}}`；`volume` 为相态节点的有限体积。"
  def dynamic(row, ambient, material, volume) do
    {Map.get(row, :temperature_kelvin, ambient), row.hp, row.max_hp, Map.get(row, :remaining_fuel_j),
     Map.get(row, :power_w, 0.0), Map.get(row, :burning, false), Map.get(row, :pick_baseline_hp),
     if(volume != nil, do: {volume * 1.0, Phase.energy(row, volume, material, ambient),
                            Map.has_key?(row, :phase_energy_j)})}
  end

  @doc "把原生侧的当前值写回记录 `base`（已有记录，或带当前 seq 的默认记录）。"
  def row(base, {temperature, hp, _max_hp, fuel, power, burning, baseline, phase}) do
    fields = %{temperature_kelvin: temperature, hp: hp}
    fields = if fuel == nil, do: fields, else: Map.merge(fields, %{remaining_fuel_j: fuel, power_w: power, burning: burning})
    fields = if baseline == nil, do: fields, else: Map.put(fields, :pick_baseline_hp, baseline)

    fields =
      case phase do
        {_volume, energy, true} -> Map.put(fields, :phase_energy_j, energy)
        _ -> fields
      end

    Map.merge(base, fields)
  end

  @doc "两条记录（或 nil）在热模拟读取的字段上是否相同；事务号、请求号等不计。"
  def same?(row, row), do: true
  def same?(nil, _), do: false
  def same?(_, nil), do: false
  def same?(a, b), do: Map.take(a, @fields) == Map.take(b, @fields)
end
