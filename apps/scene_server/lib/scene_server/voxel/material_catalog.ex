defmodule SceneServer.Voxel.MaterialCatalog do
  @moduledoc """
  Material-specific defaults for `material_default` voxel attributes.

  `Storage` owns per-chunk truth, while this module is the small static material
  lookup table used to derive L1 defaults from a normal/refined cell's
  `material_id`. Runtime voxel state should store only dynamic changes; stable
  material thresholds and physical constants belong here and in the attribute
  catalog definition.
  """

  @fixed32_scale 65_536
  @absolute_zero_raw -17_904_824
  @inert_temperature_raw 327_680_000

  @dirt_material_id 1
  @stone_material_id 2
  @wood_material_id 3
  @ice_material_id 4
  @iron_material_id 5
  @power_block_material_id 6
  @electric_load_material_id 7
  # 功能完善 · 反应层:相变/燃烧目标材料。append-only id。R1 water;R4 steam;R5 ash(燃尽)。
  @water_material_id 8
  @steam_material_id 9
  @ash_material_id 10

  # 材料名 ↔ id(反应规则用名引用,稳定不写裸 id)。
  @material_ids %{
    dirt: @dirt_material_id,
    stone: @stone_material_id,
    wood: @wood_material_id,
    ice: @ice_material_id,
    iron: @iron_material_id,
    power_block: @power_block_material_id,
    electric_load: @electric_load_material_id,
    water: @water_material_id,
    steam: @steam_material_id,
    ash: @ash_material_id
  }

  @power_source_defaults %{
    output_mode: :dc,
    voltage: 120.0,
    current_limit_amps: 20.0,
    energy_budget_joules: 20_000.0
  }

  @material_default_attributes %{
    @dirt_material_id => %{
      "density" => round(1_600.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.25 * @fixed32_scale),
      "specific_heat_capacity" => round(800.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_100.0 * @fixed32_scale),
      "freezing_point" => round(1_100.0 * @fixed32_scale),
      "boiling_point" => round(2_200.0 * @fixed32_scale),
      "electric_conductivity" => round(0.01 * @fixed32_scale),
      "dielectric_strength" => round(10.0 * @fixed32_scale)
    },
    @stone_material_id => %{
      "density" => round(2_700.0 * @fixed32_scale),
      "thermal_conductivity" => round(2.5 * @fixed32_scale),
      "specific_heat_capacity" => round(790.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_200.0 * @fixed32_scale),
      "freezing_point" => round(1_200.0 * @fixed32_scale),
      "boiling_point" => round(3_000.0 * @fixed32_scale),
      "electric_conductivity" => 0,
      "dielectric_strength" => round(12.0 * @fixed32_scale)
    },
    @wood_material_id => %{
      "density" => round(600.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.13 * @fixed32_scale),
      "specific_heat_capacity" => round(1_700.0 * @fixed32_scale),
      "ignition_temperature" => round(300.0 * @fixed32_scale),
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => @absolute_zero_raw,
      "boiling_point" => @inert_temperature_raw,
      "electric_conductivity" => 0,
      "dielectric_strength" => round(10.0 * @fixed32_scale)
    },
    @ice_material_id => %{
      "density" => round(917.0 * @fixed32_scale),
      "thermal_conductivity" => round(2.2 * @fixed32_scale),
      "specific_heat_capacity" => round(2_100.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => 0,
      "freezing_point" => 0,
      "boiling_point" => round(100.0 * @fixed32_scale),
      "electric_conductivity" => 0,
      "dielectric_strength" => round(9.8 * @fixed32_scale)
    },
    @iron_material_id => %{
      "density" => round(7_870.0 * @fixed32_scale),
      "thermal_conductivity" => round(80.0 * @fixed32_scale),
      "specific_heat_capacity" => round(449.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_538.0 * @fixed32_scale),
      "freezing_point" => round(1_538.0 * @fixed32_scale),
      "boiling_point" => round(2_862.0 * @fixed32_scale),
      "electric_conductivity" => round(10.0 * @fixed32_scale),
      "dielectric_strength" => 0
    },
    @power_block_material_id => %{
      "density" => round(7_870.0 * @fixed32_scale),
      "thermal_conductivity" => round(80.0 * @fixed32_scale),
      "specific_heat_capacity" => round(449.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_538.0 * @fixed32_scale),
      "freezing_point" => round(1_538.0 * @fixed32_scale),
      "boiling_point" => round(2_862.0 * @fixed32_scale),
      "electric_conductivity" => round(12.0 * @fixed32_scale),
      "dielectric_strength" => 0
    },
    @electric_load_material_id => %{
      "density" => round(7_870.0 * @fixed32_scale),
      "thermal_conductivity" => round(65.0 * @fixed32_scale),
      "specific_heat_capacity" => round(520.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_450.0 * @fixed32_scale),
      "freezing_point" => round(1_450.0 * @fixed32_scale),
      "boiling_point" => round(2_700.0 * @fixed32_scale),
      "electric_conductivity" => round(8.0 * @fixed32_scale),
      "dielectric_strength" => 0
    },
    # 反应层 R1:水(冰熔化目标)。freezing_point=0 冻回冰;boiling_point=100 → 蒸汽。
    @water_material_id => %{
      "density" => round(1_000.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.6 * @fixed32_scale),
      "specific_heat_capacity" => round(4_186.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => 0,
      "boiling_point" => round(100.0 * @fixed32_scale),
      "electric_conductivity" => round(0.005 * @fixed32_scale),
      "dielectric_strength" => 0
    },
    # 反应层 R4:蒸汽(水沸腾目标)。低密度、低导热;condense 阈值后续接。
    @steam_material_id => %{
      "density" => round(0.6 * @fixed32_scale),
      "thermal_conductivity" => round(0.025 * @fixed32_scale),
      "specific_heat_capacity" => round(2_010.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => @absolute_zero_raw,
      "boiling_point" => @inert_temperature_raw,
      "electric_conductivity" => 0,
      "dielectric_strength" => 0
    },
    # 反应层 R5:灰烬(木燃尽目标)。轻、ignition inert(不复燃),惰性产物。
    @ash_material_id => %{
      "density" => round(80.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.05 * @fixed32_scale),
      "specific_heat_capacity" => round(840.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => @absolute_zero_raw,
      "boiling_point" => @inert_temperature_raw,
      "electric_conductivity" => 0,
      "dielectric_strength" => round(3.0 * @fixed32_scale)
    }
  }

  @doc "材料名 → append-only id(未知名返回 nil)。反应规则用名引用。"
  @spec material_id(atom()) :: pos_integer() | nil
  def material_id(name) when is_atom(name), do: Map.get(@material_ids, name)

  @doc """
  material_id 是否在 catalog 中已定义(反应层用:未知材料不参与阈值反应,避免缺省阈值 0 反转惰性安全)。
  """
  @spec known_material?(term()) :: boolean()
  def known_material?(material_id), do: Map.has_key?(@material_default_attributes, material_id)

  @doc "id → 材料名(未知 id 返回 nil)。"
  @spec material_name(integer()) :: atom() | nil
  def material_name(id) when is_integer(id) do
    Enum.find_value(@material_ids, fn {name, mid} -> if mid == id, do: name end)
  end

  @doc "全部已知材料名 → id 映射。"
  @spec material_ids() :: %{atom() => pos_integer()}
  def material_ids, do: @material_ids

  @doc "Q16.16 定点比例(1.0 == 65536 raw)。反应层把 raw 阈值转摄氏度用。"
  @spec fixed32_scale() :: pos_integer()
  def fixed32_scale, do: @fixed32_scale

  @doc "Returns the append-only material id for the physical electric power block."
  @spec power_source_material_id() :: pos_integer()
  def power_source_material_id, do: @power_block_material_id

  @doc "Returns true when a material id represents a physical power block."
  @spec power_source_material?(term()) :: boolean()
  def power_source_material?(material_id), do: material_id == @power_block_material_id

  @doc "Returns the append-only material id for a physical electric load/sink block."
  @spec electric_load_material_id() :: pos_integer()
  def electric_load_material_id, do: @electric_load_material_id

  @doc "Returns true when a material id represents a circuit load/sink."
  @spec electric_load_material?(term()) :: boolean()
  def electric_load_material?(material_id), do: material_id == @electric_load_material_id

  @doc "Returns the current default supply policy for a physical power block."
  @spec power_source_defaults() :: %{
          output_mode: :dc,
          voltage: float(),
          current_limit_amps: float(),
          energy_budget_joules: float()
        }
  def power_source_defaults, do: @power_source_defaults

  @doc """
  Returns all material-default attributes for a material id.
  """
  @spec material_defaults(non_neg_integer() | nil) :: %{optional(String.t()) => integer()}
  def material_defaults(material_id) do
    Map.get(@material_default_attributes, material_id, %{})
  end

  @doc """
  Returns a material-specific attribute value, or `fallback` for unknown
  material ids / attributes.
  """
  @spec default_attribute_value(non_neg_integer() | nil, String.t(), integer()) :: integer()
  def default_attribute_value(material_id, attr_name, fallback)
      when is_binary(attr_name) and is_integer(fallback) do
    material_id
    |> material_defaults()
    |> Map.get(attr_name, fallback)
  end
end
