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
end
