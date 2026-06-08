defmodule SceneServer.Voxel.Phenomenon.PhaseChangeTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Phenomenon.PhaseChange
  alias SceneServer.Voxel.Phenomenon.PhaseChangeKernel
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "wet material freezes below water freezing point and records persistent phase state" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      macro_index
      |> storage_with_material(MaterialCatalog.wood_material_id())
      |> put_attribute(macro_index, "moisture", 25.0)

    assert %{
             stage: :frozen,
             effects: effects,
             field_source_points: []
           } = PhaseChange.evaluate(storage, macro_index, -10.0, dt_seconds: 1.0)

    assert {:write_voxel_attribute,
            %{attribute: :phase_state, macro_index: macro_index, raw_value: 1}} in effects

    assert structural_integrity_raw(effects) < fixed32(100.0)
    assert observe_event?(effects, "voxel_phase_change_frozen", :frozen)

    assert Enum.any?(effects, fn
             {:upsert_phenomenon_instance,
              %{
                kind: :phase_change,
                macro_index: ^macro_index,
                stage: :frozen,
                moisture_kg_per_m3: 25.0
              }} ->
               true

             _other ->
               false
           end)
  end

  test "freezing structural damage uses the shared collapse candidate boundary" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      macro_index
      |> storage_with_material(MaterialCatalog.wood_material_id())
      |> put_attribute(macro_index, "moisture", 25.0)
      |> put_attribute(macro_index, "structural_integrity", 16.0)

    assert %{stage: :frozen, effects: effects} =
             PhaseChange.evaluate(storage, macro_index, -10.0,
               freeze_stress_loss_percent: 3.0,
               structural_failure_threshold_percent: 15.0
             )

    assert structural_integrity_raw(effects) == fixed32(13.0)

    assert {:emit_observe, "voxel_structural_collapse_candidate", fields} =
             Enum.find(effects, fn
               {:emit_observe, "voxel_structural_collapse_candidate", _fields} -> true
               _other -> false
             end)

    assert fields.reason == :phase_change_freeze_stress
    assert fields.stage == :frozen
    assert fields.structural_integrity_before_percent == 16.0
    assert fields.structural_integrity_after_percent == 13.0
    assert fields.structural_failure_threshold_percent == 15.0
  end

  test "hot wet material boils moisture into a local vapor field source" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      macro_index
      |> storage_with_material(MaterialCatalog.wood_material_id())
      |> put_attribute(macro_index, "moisture", 120.0)

    assert %{
             stage: :boiling,
             effects: effects,
             field_source_points: [source_point]
           } =
             PhaseChange.evaluate(storage, macro_index, 150.0,
               dt_seconds: 1.0,
               boiling_rate_kg_per_m3_second: 40.0
             )

    assert {:write_voxel_attribute,
            %{attribute: :phase_state, macro_index: macro_index, raw_value: 2}} in effects

    assert moisture_raw(effects) == fixed32(80.0)

    assert %{
             macro_index: ^macro_index,
             field_type: :moisture,
             source_mode: :impulse,
             source_kind: :phase_change,
             value: 40.0,
             moisture_released_kg_per_m3: 40.0
           } = source_point

    assert observe_event?(effects, "voxel_phase_change_boiling", :boiling)
  end

  test "dry cells and stable wet cells do not create phase effects" do
    macro_index = Types.macro_index!({0, 0, 0})
    dry_storage = storage_with_material(macro_index, MaterialCatalog.wood_material_id())

    assert :ignore = PhaseChange.evaluate(dry_storage, macro_index, 150.0)

    wet_storage = put_attribute(dry_storage, macro_index, "moisture", 10.0)
    assert :ignore = PhaseChange.evaluate(wet_storage, macro_index, 20.0)
  end

  test "phase change kernel participates in the field lifecycle" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      macro_index
      |> storage_with_material(MaterialCatalog.wood_material_id())
      |> put_attribute(macro_index, "moisture", 120.0)

    region =
      %{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :phase_change,
            module: PhaseChangeKernel,
            opts: %{boiling_rate_kg_per_m3_second: 40.0}
          },
          %{
            id: :moisture_diffusion,
            module: SceneServer.Voxel.Field.Kernels.MoistureDiffusionKernel
          }
        ]
      }
      |> FieldRegion.new()
      |> FieldRegion.put_layer(
        :temperature,
        FieldLayer.put(FieldLayer.new(baseline: 20.0), macro_index, 150.0)
      )

    assert [:temperature, :moisture] == PhaseChangeKernel.required_layers(%{})

    assert {:cont, next_region, effects} =
             PhaseChangeKernel.tick(
               region,
               KernelContext.new(region, 1, storage, dt_ms: 1000),
               %{boiling_rate_kg_per_m3_second: 40.0}
             )

    assert observe_event?(effects, "voxel_phase_change_boiling", :boiling)

    assert Enum.any?(next_region.source_points, fn
             %{
               macro_index: ^macro_index,
               field_type: :moisture,
               source_kind: :phase_change,
               value: 40.0
             } ->
               true

             _other ->
               false
           end)
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

  defp moisture_raw(effects) do
    Enum.find_value(effects, fn
      {:write_voxel_attribute, %{attribute: :moisture, raw_value: raw_value}} -> raw_value
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
