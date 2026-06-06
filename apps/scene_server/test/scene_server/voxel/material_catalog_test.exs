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
    assert wood_profile.ignition_temperature_celsius < charcoal_profile.ignition_temperature_celsius
  end
end
