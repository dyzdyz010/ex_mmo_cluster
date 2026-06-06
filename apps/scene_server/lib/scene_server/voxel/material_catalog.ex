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
  @ash_material_id 8
  @charcoal_material_id 9

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
    @ash_material_id => %{
      "density" => round(700.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.18 * @fixed32_scale),
      "specific_heat_capacity" => round(800.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_100.0 * @fixed32_scale),
      "freezing_point" => round(1_100.0 * @fixed32_scale),
      "boiling_point" => round(2_200.0 * @fixed32_scale),
      "electric_conductivity" => 0,
      "dielectric_strength" => round(5.0 * @fixed32_scale)
    },
    @charcoal_material_id => %{
      "density" => round(250.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.08 * @fixed32_scale),
      "specific_heat_capacity" => round(710.0 * @fixed32_scale),
      "ignition_temperature" => round(420.0 * @fixed32_scale),
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => @absolute_zero_raw,
      "boiling_point" => @inert_temperature_raw,
      "electric_conductivity" => round(0.02 * @fixed32_scale),
      "dielectric_strength" => round(8.0 * @fixed32_scale)
    }
  }

  @combustion_profiles %{
    @wood_material_id => %{
      material_name: :wood,
      ignition_temperature_celsius: 300.0,
      preheat_margin_celsius: 40.0,
      max_moisture_kg_per_m3: 180.0,
      min_oxygen_percent: 8.0,
      initial_fuel_mass_kg_per_m3: 45.0,
      burn_rate_kg_per_m3_second: 18.0,
      smolder_progress_percent: 72.0,
      smolder_heat_source_celsius: 360.0,
      heat_source_celsius: 680.0,
      oxygen_consumption_percent_per_kg: 0.28,
      smoke_yield_percent_per_kg: 1.1,
      carbonization_yield_percent_per_kg: 1.6,
      structural_loss_percent_per_kg: 1.4,
      residue: {:material, @charcoal_material_id}
    },
    @charcoal_material_id => %{
      material_name: :charcoal,
      ignition_temperature_celsius: 420.0,
      preheat_margin_celsius: 60.0,
      max_moisture_kg_per_m3: 80.0,
      min_oxygen_percent: 5.0,
      initial_fuel_mass_kg_per_m3: 18.0,
      burn_rate_kg_per_m3_second: 12.0,
      smolder_progress_percent: 60.0,
      smolder_heat_source_celsius: 460.0,
      heat_source_celsius: 780.0,
      oxygen_consumption_percent_per_kg: 0.35,
      smoke_yield_percent_per_kg: 0.45,
      carbonization_yield_percent_per_kg: 0.2,
      structural_loss_percent_per_kg: 2.0,
      residue: {:material, @ash_material_id}
    }
  }

  @doc "Returns the append-only material id for ordinary wood."
  @spec wood_material_id() :: pos_integer()
  def wood_material_id, do: @wood_material_id

  @doc "Returns the append-only material id for inert ash left by combustion."
  @spec ash_material_id() :: pos_integer()
  def ash_material_id, do: @ash_material_id

  @doc "Returns the append-only material id for charcoal left by oxygen-limited wood combustion."
  @spec charcoal_material_id() :: pos_integer()
  def charcoal_material_id, do: @charcoal_material_id

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

  @doc "Returns true when a material has a combustion profile."
  @spec combustible_material?(term()) :: boolean()
  def combustible_material?(material_id), do: is_map(combustion_profile(material_id))

  @doc """
  Returns the static combustion profile for a material id, or `nil` for inert
  materials. Runtime burn state remains in voxel attributes; only material-level
  thresholds and outcome policy live here.
  """
  @spec combustion_profile(term()) :: map() | nil
  def combustion_profile(material_id) when is_integer(material_id) do
    Map.get(@combustion_profiles, material_id)
  end

  def combustion_profile(_material_id), do: nil

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
