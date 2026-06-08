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

    assert %{
             stage: :burning,
             effects: effects,
             heat_source_points: [source_point],
             field_source_points: field_source_points
           } =
             Combustion.evaluate(storage, macro_index, 500.0)

    assert %{
             macro_index: macro_index,
             field_type: :temperature,
             source_mode: :persistent,
             source_kind: :combustion,
             value: source_value
           } = source_point

    assert source_value > 500.0
    assert source_value <= 680.0

    assert Enum.any?(field_source_points, fn
             %{
               macro_index: ^macro_index,
               field_type: :smoke_density,
               source_mode: :impulse,
               source_kind: :combustion,
               value: smoke_value,
               smoke_delta_percent: smoke_delta
             }
             when smoke_value > 0.0 and smoke_delta > 0.0 ->
               true

             _other ->
               false
           end)

    assert Enum.any?(field_source_points, fn
             %{
               macro_index: ^macro_index,
               field_type: :oxygen,
               source_mode: :impulse,
               source_kind: :combustion,
               value: oxygen_after,
               oxygen_consumed_percent: oxygen_consumed
             }
             when oxygen_after < 100.0 and oxygen_consumed > 0.0 ->
               true

             _other ->
               false
           end)

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

  test "ignition emits an authority-owned combustion instance upsert" do
    macro_index = Types.macro_index!({0, 0, 0})
    wood_material_id = MaterialCatalog.wood_material_id()
    storage = storage_with_material(macro_index, wood_material_id)

    assert %{stage: :burning, effects: effects} =
             Combustion.evaluate(storage, macro_index, 500.0)

    assert Enum.any?(effects, fn
             {:upsert_phenomenon_instance,
              %{
                kind: :combustion,
                macro_index: ^macro_index,
                material_id: ^wood_material_id,
                stage: :burning,
                previous_stage: :idle
              }} ->
               true

             _other ->
               false
           end)
  end

  test "combustion heat source is derived from released fuel energy and voxel heat capacity" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    profile = %{
      initial_fuel_mass_kg_per_m3: 10.0,
      burn_rate_kg_per_m3_second: 1.0,
      combustion_heat_j_per_kg: 1_000_000.0,
      heat_release_efficiency: 1.0,
      heat_source_celsius: 1_000.0
    }

    assert %{effects: effects, heat_source_points: [source_point]} =
             Combustion.evaluate(storage, macro_index, 405.0,
               dt_seconds: 1.0,
               profile: profile
             )

    expected_delta = 1_000_000.0 / (600.0 * 1_700.0)
    expected_source = 405.0 + expected_delta

    assert_in_delta source_point.value, expected_source, 0.000001
    assert Map.fetch!(source_point, :released_heat_energy_joules) == 1_000_000.0
    assert_in_delta Map.fetch!(source_point, :heat_source_delta_celsius), expected_delta, 0.000001

    assert observe_fields =
             observe_event_fields(effects, "voxel_combustion_ignited", :burning)

    assert observe_fields.burned_fuel_kg_per_m3 == 1.0
    assert observe_fields.combustion_heat_j_per_kg == 1_000_000.0
    assert observe_fields.released_heat_energy_joules == 1_000_000.0
    assert_in_delta observe_fields.heat_source_celsius, expected_source, 0.000001
  end

  test "combustion heat source respects the material heat source cap" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    profile = %{
      initial_fuel_mass_kg_per_m3: 10.0,
      burn_rate_kg_per_m3_second: 1.0,
      combustion_heat_j_per_kg: 1_000_000.0,
      heat_release_efficiency: 1.0,
      heat_source_celsius: 405.5
    }

    assert %{heat_source_points: [source_point]} =
             Combustion.evaluate(storage, macro_index, 405.0,
               dt_seconds: 1.0,
               profile: profile
             )

    assert source_point.value == 405.5
    assert Map.fetch!(source_point, :heat_source_delta_celsius) == 0.5
  end

  test "wet wood dries under high heat before ignition can start" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      macro_index
      |> storage_with_material(MaterialCatalog.wood_material_id())
      |> put_attribute(macro_index, "moisture", 240.0)

    profile = %{drying_rate_kg_per_m3_second: 30.0}

    assert %{
             stage: :preheat,
             effects: drying_effects,
             heat_source_points: [],
             field_source_points: field_source_points
           } =
             Combustion.evaluate(storage, macro_index, 500.0,
               dt_seconds: 1.0,
               profile: profile
             )

    assert moisture_raw(drying_effects) == fixed32(180.0)

    assert Enum.any?(field_source_points, fn
             %{
               macro_index: ^macro_index,
               field_type: :moisture,
               source_mode: :impulse,
               source_kind: :combustion,
               value: 60.0,
               moisture_released_kg_per_m3: 60.0
             } ->
               true

             _other ->
               false
           end)

    assert observe_event?(drying_effects, "voxel_combustion_dried", :preheat)
    refute observe_event?(drying_effects, "voxel_combustion_ignited", :burning)
    refute fuel_mass_raw(drying_effects)

    dried_storage =
      Storage.put_attribute_for_cell(storage, macro_index, "moisture", fixed32(180.0))

    assert %{stage: :burning, heat_source_points: [_source_point]} =
             Combustion.evaluate(dried_storage, macro_index, 500.0,
               dt_seconds: 0.1,
               profile: profile
             )
  end

  test "combustion kernel reads active moisture field values before ignition" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    region =
      %{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{id: :combustion, module: CombustionKernel, opts: %{}},
          %{
            id: :moisture_diffusion,
            module: SceneServer.Voxel.Field.Kernels.MoistureDiffusionKernel
          }
        ]
      }
      |> FieldRegion.new()
      |> FieldRegion.put_layer(
        :temperature,
        FieldLayer.put(FieldLayer.new(), macro_index, 500.0)
      )
      |> FieldRegion.put_layer(
        :moisture,
        FieldLayer.put(FieldLayer.new(), macro_index, 240.0)
      )

    assert {:cont, next_region, effects} =
             CombustionKernel.tick(
               region,
               KernelContext.new(region, 1, storage, dt_ms: 1000),
               %{}
             )

    assert observe_event?(effects, "voxel_combustion_dried", :preheat)
    refute observe_event?(effects, "voxel_combustion_ignited", :burning)

    assert Enum.any?(next_region.source_points, fn
             %{
               macro_index: ^macro_index,
               field_type: :moisture,
               source_kind: :combustion,
               value: value
             }
             when value > 0.0 ->
               true

             _other ->
               false
           end)
  end

  test "low oxygen high heat carbonizes wood into charcoal without ignition heat source" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      macro_index
      |> storage_with_material(MaterialCatalog.wood_material_id())
      |> put_attribute(macro_index, "oxygen", 2.0)

    profile = %{
      oxygen_limited_carbonization_percent_per_second: 100.0,
      oxygen_limited_structural_loss_percent_per_second: 1.0,
      oxygen_limited_residue_threshold_percent: 50.0,
      oxygen_limited_residue: {:material, MaterialCatalog.charcoal_material_id()}
    }

    assert %{stage: :preheat, effects: effects, heat_source_points: []} =
             Combustion.evaluate(storage, macro_index, 500.0,
               dt_seconds: 1.0,
               profile: profile
             )

    assert carbonization_raw(effects) >= fixed32(50.0)
    assert observe_event?(effects, "voxel_combustion_carbonized", :preheat)
    refute observe_event?(effects, "voxel_combustion_ignited", :burning)

    assert {:transform_voxel_material,
            %{
              macro_index: macro_index,
              material_id: 9,
              reason: :oxygen_limited_carbonization,
              reset_attributes?: true
            }} in effects
  end

  test "active combustion extinguishes instead of staying burning when moisture exceeds sustain threshold" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      macro_index
      |> storage_with_material(MaterialCatalog.wood_material_id())
      |> put_attribute(macro_index, "moisture", 240.0)
      |> Storage.put_attribute_for_cell(
        macro_index,
        "combustion_stage",
        Combustion.stage_burning()
      )

    assert %{stage: :extinguished, effects: effects, heat_source_points: []} =
             Combustion.evaluate(storage, macro_index, 500.0)

    assert {:write_voxel_attribute,
            %{attribute: :combustion_stage, macro_index: macro_index, raw_value: 4}} in effects

    assert observe_event?(effects, "voxel_combustion_extinguished", :extinguished)
    refute moisture_raw(effects)
  end

  test "combustion emits a collapse candidate only when integrity crosses the material threshold" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    profile = %{
      initial_fuel_mass_kg_per_m3: 100.0,
      burn_rate_kg_per_m3_second: 1.0,
      structural_loss_percent_per_kg: 80.0,
      structural_failure_threshold_percent: 50.0
    }

    assert %{stage: :burning, effects: effects} =
             Combustion.evaluate(storage, macro_index, 500.0,
               dt_seconds: 1.0,
               profile: profile
             )

    assert structural_integrity_raw(effects) < fixed32(50.0)
    assert observe_event?(effects, "voxel_structural_collapse_candidate")

    already_failed_storage =
      storage
      |> put_attribute(macro_index, "structural_integrity", 40.0)

    assert %{effects: already_failed_effects} =
             Combustion.evaluate(already_failed_storage, macro_index, 500.0,
               dt_seconds: 1.0,
               profile: profile
             )

    refute observe_event?(already_failed_effects, "voxel_structural_collapse_candidate")
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

  test "low remaining fuel transitions from burning to smoldering with a lower heat source" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      macro_index
      |> storage_with_material(MaterialCatalog.wood_material_id())
      |> put_attribute(macro_index, "fuel_mass", 3.0)
      |> Storage.put_attribute_for_cell(
        macro_index,
        "combustion_stage",
        Combustion.stage_burning()
      )

    profile = %{
      ignition_temperature_celsius: 100.0,
      initial_fuel_mass_kg_per_m3: 10.0,
      burn_rate_kg_per_m3_second: 1.0,
      smolder_progress_percent: 70.0,
      heat_source_celsius: 800.0,
      smolder_heat_source_celsius: 320.0
    }

    assert %{
             stage: :smoldering,
             effects: effects,
             heat_source_points: [source_point]
           } =
             Combustion.evaluate(storage, macro_index, 500.0,
               dt_seconds: 1.0,
               profile: profile
             )

    assert {:write_voxel_attribute,
            %{attribute: :combustion_stage, macro_index: macro_index, raw_value: 3}} in effects

    assert %{
             macro_index: ^macro_index,
             field_type: :temperature,
             source_mode: :persistent,
             source_kind: :combustion,
             value: 320.0
           } = source_point

    assert Map.fetch!(source_point, :released_heat_energy_joules) > 0.0

    assert observe_event?(effects, "voxel_combustion_smoldering", :smoldering)
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

  test "combustion kernel keeps heat and smoke sources inside the field source lifecycle" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    profile = %{
      initial_fuel_mass_kg_per_m3: 10.0,
      burn_rate_kg_per_m3_second: 1.0,
      smoke_yield_percent_per_kg: 8.0
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

    assert {:cont, next_region, _effects} =
             CombustionKernel.tick(region, KernelContext.new(region, 1, storage, dt_ms: 1000), %{
               profile: profile
             })

    assert Enum.any?(next_region.source_points, fn
             %{macro_index: ^macro_index, field_type: :temperature, source_kind: :combustion} ->
               true

             _other ->
               false
           end)

    assert Enum.any?(next_region.source_points, fn
             %{
               macro_index: ^macro_index,
               field_type: :smoke_density,
               source_kind: :combustion,
               value: value
             }
             when value > 0.0 ->
               true

             _other ->
               false
           end)

    assert Enum.any?(next_region.source_points, fn
             %{
               macro_index: ^macro_index,
               field_type: :oxygen,
               source_kind: :combustion,
               value: value
             }
             when value < 100.0 ->
               true

             _other ->
               false
           end)
  end

  test "combustion kernel reads oxygen field values when deciding ignition versus carbonization" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    region =
      %{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{id: :combustion, module: CombustionKernel, opts: %{}},
          %{id: :oxygen_diffusion, module: SceneServer.Voxel.Field.Kernels.OxygenDiffusionKernel}
        ]
      }
      |> FieldRegion.new()
      |> FieldRegion.put_layer(
        :temperature,
        FieldLayer.put(FieldLayer.new(), macro_index, 500.0)
      )
      |> FieldRegion.put_layer(
        :oxygen,
        FieldLayer.put(FieldLayer.new(baseline: 100.0), macro_index, 2.0)
      )

    assert {:cont, _next_region, effects} =
             CombustionKernel.tick(region, KernelContext.new(region, 1, storage, dt_ms: 100), %{})

    assert observe_event?(effects, "voxel_combustion_carbonized", :preheat)
    refute observe_event?(effects, "voxel_combustion_ignited", :burning)
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

    assert observe_fields =
             observe_event_fields(effects, "voxel_combustion_extinguished", :extinguished)

    assert observe_fields.released_heat_energy_joules > 0.0
    assert is_nil(observe_fields.heat_source_celsius)
    assert Enum.any?(effects, &match?({:complete_phenomenon_instance, %{kind: :combustion}}, &1))
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

  test "dry grass uses its default profile to burn away completely" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.dry_grass_material_id())

    assert %{stage: :extinguished, effects: effects} =
             Combustion.evaluate(storage, macro_index, 700.0, dt_seconds: 5.0)

    assert {:clear_voxel_cell, %{macro_index: macro_index, reason: :combustion_exhausted}} in effects
  end

  test "cloth uses its default profile to leave ash" do
    macro_index = Types.macro_index!({0, 0, 0})
    storage = storage_with_material(macro_index, MaterialCatalog.cloth_material_id())
    ash_material_id = MaterialCatalog.ash_material_id()

    assert %{stage: :extinguished, effects: effects} =
             Combustion.evaluate(storage, macro_index, 900.0, dt_seconds: 10.0)

    assert {:transform_voxel_material,
            %{
              macro_index: macro_index,
              material_id: ash_material_id,
              reason: :combustion_exhausted,
              reset_attributes?: true
            }} in effects
  end

  defp storage_with_material(macro_index, material_id) do
    1
    |> Storage.empty({0, 0, 0})
    |> Storage.put_solid_block(macro_index, NormalBlockData.new(material_id))
  end

  defp put_attribute(storage, macro_index, attribute, value) do
    Storage.put_attribute_for_cell(storage, macro_index, attribute, fixed32(value))
  end

  defp observe_event?(effects, event, stage) do
    Enum.any?(effects, fn
      {:emit_observe, ^event, %{stage: ^stage}} -> true
      _other -> false
    end)
  end

  defp observe_event?(effects, event) do
    Enum.any?(effects, fn
      {:emit_observe, ^event, _fields} -> true
      _other -> false
    end)
  end

  defp observe_event_fields(effects, event, stage) do
    Enum.find_value(effects, fn
      {:emit_observe, ^event, %{stage: ^stage} = fields} -> fields
      _other -> nil
    end)
  end

  defp fuel_mass_raw(effects) do
    Enum.find_value(effects, fn
      {:write_voxel_attribute, %{attribute: :fuel_mass, raw_value: raw_value}} -> raw_value
      _other -> nil
    end)
  end

  defp moisture_raw(effects) do
    Enum.find_value(effects, fn
      {:write_voxel_attribute, %{attribute: :moisture, raw_value: raw_value}} -> raw_value
      _other -> nil
    end)
  end

  defp carbonization_raw(effects) do
    Enum.find_value(effects, fn
      {:write_voxel_attribute, %{attribute: :carbonization, raw_value: raw_value}} -> raw_value
      _other -> nil
    end)
  end

  defp structural_integrity_raw(effects) do
    Enum.find_value(effects, fn
      {:write_voxel_attribute, %{attribute: :structural_integrity, raw_value: raw_value}} ->
        raw_value

      _other ->
        nil
    end)
  end

  defp fixed32(value), do: round(value * 65_536)
end
