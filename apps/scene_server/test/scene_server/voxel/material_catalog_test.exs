defmodule SceneServer.Voxel.MaterialCatalogTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.MaterialCatalog

  test "power block material is append-only and electrically active" do
    material_id = MaterialCatalog.power_source_material_id()

    assert material_id == 6
    assert MaterialCatalog.power_source_material?(material_id)
    assert MaterialCatalog.default_attribute_value(material_id, "electric_conductivity", 0) > 0

    assert MaterialCatalog.default_attribute_value(material_id, "dielectric_strength", 65_536) ==
             0
  end

  test "power block declares bounded default supply policy" do
    assert MaterialCatalog.power_source_defaults() == %{
             output_mode: :dc,
             voltage: 120.0,
             current_limit_amps: 20.0,
             energy_budget_joules: 20_000.0
           }
  end

  test "load block material is append-only and electrically conductive" do
    material_id = MaterialCatalog.electric_load_material_id()

    assert material_id == 7
    assert MaterialCatalog.electric_load_material?(material_id)
    assert MaterialCatalog.default_attribute_value(material_id, "electric_conductivity", 0) > 0
  end

  test "material ids expose stable catalog names even when they have no phenomenon profile" do
    assert MaterialCatalog.material_name(1) == :dirt
    assert MaterialCatalog.material_name(2) == :stone
    assert MaterialCatalog.material_name(MaterialCatalog.wood_material_id()) == :wood
    assert MaterialCatalog.material_name(MaterialCatalog.ash_material_id()) == :ash
    assert MaterialCatalog.material_name(MaterialCatalog.dry_grass_material_id()) == :dry_grass
    assert MaterialCatalog.material_name(999_999) == nil
    assert MaterialCatalog.material_name(nil) == nil
  end

  test "iron declares corrosion response without becoming a combustion material" do
    iron_material_id = 5

    refute MaterialCatalog.combustible_material?(iron_material_id)

    assert MaterialCatalog.default_attribute_value(
             iron_material_id,
             "corrosion_resistance",
             0
           ) == round(35.0 * 65_536)

    assert %{material_name: :iron} = profile = MaterialCatalog.corrosion_profile(iron_material_id)
    assert profile.moisture_threshold_kg_per_m3 > 0.0
    assert profile.chemical_threshold_percent > 0.0
    assert profile.corrosion_rate_percent_per_second > 0.0
    assert profile.structural_failure_threshold_percent > 0.0
    assert profile.electric_conductivity_loss_percent_per_corrosion_percent > 0.0
  end

  test "combustion residue materials are append-only and inert or reusable fuel" do
    assert MaterialCatalog.ash_material_id() == 8
    assert MaterialCatalog.charcoal_material_id() == 9

    refute MaterialCatalog.combustible_material?(MaterialCatalog.ash_material_id())
    assert MaterialCatalog.combustible_material?(MaterialCatalog.charcoal_material_id())

    assert MaterialCatalog.default_attribute_value(
             MaterialCatalog.ash_material_id(),
             "ignition_temperature",
             0
           ) == 327_680_000

    assert MaterialCatalog.default_attribute_value(
             MaterialCatalog.charcoal_material_id(),
             "ignition_temperature",
             0
           ) > 0
  end

  test "wood combustion profile burns into charcoal before charcoal burns into ash" do
    wood_profile = MaterialCatalog.combustion_profile(MaterialCatalog.wood_material_id())
    charcoal_profile = MaterialCatalog.combustion_profile(MaterialCatalog.charcoal_material_id())

    assert wood_profile.residue == {:material, MaterialCatalog.charcoal_material_id()}
    assert charcoal_profile.residue == {:material, MaterialCatalog.ash_material_id()}

    assert wood_profile.ignition_temperature_celsius <
             charcoal_profile.ignition_temperature_celsius

    assert wood_profile.combustion_heat_j_per_kg > 0.0
    assert charcoal_profile.combustion_heat_j_per_kg > wood_profile.combustion_heat_j_per_kg
    assert wood_profile.heat_release_efficiency > 0.0
  end

  test "combustion catalog includes burn-away and ash-producing materials" do
    assert MaterialCatalog.dry_grass_material_id() == 10
    assert MaterialCatalog.cloth_material_id() == 11

    dry_grass_profile =
      MaterialCatalog.combustion_profile(MaterialCatalog.dry_grass_material_id())

    cloth_profile = MaterialCatalog.combustion_profile(MaterialCatalog.cloth_material_id())

    assert dry_grass_profile.residue == :clear
    assert cloth_profile.residue == {:material, MaterialCatalog.ash_material_id()}
    assert dry_grass_profile.combustion_heat_j_per_kg > 0.0
    assert cloth_profile.combustion_heat_j_per_kg > 0.0

    assert dry_grass_profile.ignition_temperature_celsius <
             MaterialCatalog.combustion_profile(MaterialCatalog.wood_material_id()).ignition_temperature_celsius

    assert MaterialCatalog.default_attribute_value(
             MaterialCatalog.cloth_material_id(),
             "ignition_temperature",
             0
           ) > 0
  end
end
