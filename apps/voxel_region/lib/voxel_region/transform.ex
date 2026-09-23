defmodule VoxelRegion.Transform do
  @moduledoc """
  全局系统功能：材料单向转化（R8 §3 "透明 + 单向转化" 轴，B7 相变的不可逆版本；§10 冶炼主干）。

  目录字段（均在源材料上，缺一不可）：
  - `transform_material_id`：产物材料；同体积 1:1 替换源材料，占用、归属与完整度比例保留。
  - `transform_kelvin`：节点温度达到即转化。
  - `transform_heat_per_macro_j`：每 m³ 源材料吸收的反应热（J），从该节点显热中扣除。
  - `transform_reductant_material_id`：必须面接触的还原剂；须是可燃材料，其剩余量即剩余化学燃料比例。
  - `transform_reductant_units_per_unit`：每单位源材料消耗的还原剂数量（体积量子之比）。

  无接触还原剂或余量不足时不转化，节点只是保持高温。只计算值，不读取 World、不分配事务序号。
  """
  alias VoxelRegion.Combustion

  def enabled?(material), do: Map.has_key?(material, "transform_material_id")

  @doc "未归零、带温度且达到阈值的宏格或精确微格节点。"
  def due?(row, material) do
    enabled?(material) and row.granularity in [0, 1] and row.hp > 0 and
      Map.get(row, :temperature_kelvin, 0.0) >= material["transform_kelvin"]
  end

  @doc "体积 volume（m³）的源材料需要消耗的还原剂化学燃料（J）；与还原剂格的大小无关。"
  def reductant_j(material, volume, reductant),
    do: material["transform_reductant_units_per_unit"] * volume * reductant["fuel_energy_per_macro_j"]

  @doc """
  按给定次序从接触还原剂行扣除 need 焦耳化学燃料；行须已带 remaining_fuel_j。
  余量合计不足返回 :insufficient，不做部分转化。
  """
  def draw(rows, need) do
    if Enum.reduce(rows, 0.0, &(&1.remaining_fuel_j + &2)) < need do
      :insufficient
    else
      {taken, _} =
        Enum.flat_map_reduce(rows, need, fn row, left ->
          used = min(left, row.remaining_fuel_j)
          {if(used > 0, do: [Combustion.consume(row, used)], else: []), left - used}
        end)

      {:ok, taken}
    end
  end

  @doc "产物温度：源节点相对环境的显热减去反应热，按产物热容重新折算；体积约去。"
  def product_temperature(temperature, material, product, ambient) do
    ambient +
      (material["heat_capacity_per_macro"] * (temperature - ambient) -
         material["transform_heat_per_macro_j"]) / product["heat_capacity_per_macro"]
  end
end
