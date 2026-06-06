defmodule SceneServer.Voxel.Phenomenon.CombustionTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Phenomenon.Combustion
  alias SceneServer.Voxel.Phenomenon.CombustionKernel
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "wood enters preheat before ignition without producing heat source" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    assert %{stage: :preheat, heat_source_points: [], effects: effects} =
             Combustion.evaluate(storage, macro_index, 275.0)

    assert {:write_voxel_attribute,
            %{attribute: :combustion_stage, macro_index: macro_index, raw_value: 1}} in effects

    assert observe_event?(effects, "voxel_combustion_preheated", :preheat)
  end

  test "high temperature wood ignites, consumes fuel, and emits a persistent heat source" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    assert %{stage: :burning, effects: effects, heat_source_points: [source_point]} =
             Combustion.evaluate(storage, macro_index, 500.0)

    assert source_point == %{
             macro_index: macro_index,
             field_type: :temperature,
             source_mode: :persistent,
             source_kind: :combustion,
             value: 680.0
           }

    assert {:write_voxel_attribute,
            %{attribute: :combustion_stage, macro_index: macro_index, raw_value: 2}} in effects

    assert Enum.any?(effects, fn
             {:write_voxel_attribute, %{attribute: :fuel_mass, raw_value: raw_value}} ->
               raw_value > 0

             _other ->
               false
           end)

    assert observe_event?(effects, "voxel_combustion_ignited", :burning)
  end

  test "top-level tick delta controls fuel consumption" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    profile = %{
      initial_fuel_mass_kg_per_m3: 10.0,
      burn_rate_kg_per_m3_second: 1.0
    }

    assert %{effects: short_tick_effects} =
             Combustion.evaluate(storage, macro_index, 500.0,
               dt_seconds: 0.1,
               profile: profile
             )

    assert %{effects: long_tick_effects} =
             Combustion.evaluate(storage, macro_index, 500.0,
               dt_seconds: 1.0,
               profile: profile
             )

    assert fuel_mass_raw(long_tick_effects) < fuel_mass_raw(short_tick_effects)
  end

  test "combustion kernel threads tick delta into fuel consumption" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    profile = %{
      initial_fuel_mass_kg_per_m3: 10.0,
      burn_rate_kg_per_m3_second: 1.0
    }

    region =
      %{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [%{id: :combustion, module: CombustionKernel, opts: %{profile: profile}}]
      }
      |> FieldRegion.new()
      |> FieldRegion.put_layer(
        :temperature,
        FieldLayer.put(FieldLayer.new(), macro_index, 500.0)
      )

    assert {:cont, _next_region, short_tick_effects} =
             CombustionKernel.tick(region, KernelContext.new(region, 1, storage, dt_ms: 100), %{
               profile: profile
             })

    assert {:cont, _next_region, long_tick_effects} =
             CombustionKernel.tick(region, KernelContext.new(region, 1, storage, dt_ms: 1000), %{
               profile: profile
             })

    assert fuel_mass_raw(long_tick_effects) < fuel_mass_raw(short_tick_effects)
  end

  test "fuel exhaustion turns wood into charcoal" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    assert %{stage: :extinguished, effects: effects, heat_source_points: []} =
             Combustion.evaluate(storage, macro_index, 700.0,
               profile: %{initial_fuel_mass_kg_per_m3: 1.0, burn_rate_kg_per_m3_second: 1000.0}
             )

    assert {:transform_voxel_material,
            %{
              macro_index: macro_index,
              material_id: 9,
              reason: :combustion_exhausted,
              reset_attributes?: true
            }} in effects

    assert observe_event?(effects, "voxel_combustion_extinguished", :extinguished)
  end

  test "combustion profiles can burn a material away completely" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    assert %{stage: :extinguished, effects: effects} =
             Combustion.evaluate(storage, macro_index, 700.0,
               profile: %{
                 initial_fuel_mass_kg_per_m3: 1.0,
                 burn_rate_kg_per_m3_second: 1000.0,
                 residue: :clear
               }
             )

    assert {:clear_voxel_cell, %{macro_index: macro_index, reason: :combustion_exhausted}} in effects
  end

  defp storage_with_material(macro_index, material_id) do
    1
    |> Storage.empty({0, 0, 0})
    |> Storage.put_solid_block(macro_index, NormalBlockData.new(material_id))
  end

  defp observe_event?(effects, event, stage) do
    Enum.any?(effects, fn
      {:emit_observe, ^event, %{stage: ^stage}} -> true
      _other -> false
    end)
  end

  defp fuel_mass_raw(effects) do
    Enum.find_value(effects, fn
      {:write_voxel_attribute, %{attribute: :fuel_mass, raw_value: raw_value}} -> raw_value
      _other -> nil
    end)
  end
end
