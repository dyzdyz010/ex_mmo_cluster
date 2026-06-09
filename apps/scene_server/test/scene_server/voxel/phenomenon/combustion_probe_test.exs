defmodule SceneServer.Voxel.Phenomenon.CombustionProbeTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Phenomenon.Combustion
  alias SceneServer.Voxel.Phenomenon.CombustionProbe
  alias SceneServer.Voxel.Phenomenon.Effect
  alias SceneServer.Voxel.Types

  setup_all do
    {:ok, _} = Application.ensure_all_started(:scene_server)
    :ok
  end

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "reads active combustion truth without mutating authority" do
    logical_scene_id = 85_000 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)
    wood_material_id = MaterialCatalog.wood_material_id()

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk_pid,
               world_macro,
               NormalBlockData.new(wood_material_id)
             )

    assert {:ok, %{changed?: true}} =
             ChunkProcess.write_temperature_attribute(chunk_pid, %{
               macro: world_macro,
               target_temperature: 520.0
             })

    assert {:ok, %{rejected_count: 0}} =
             ChunkProcess.apply_field_effects(
               chunk_pid,
               [
                 Effect.write_voxel_attribute(
                   macro_index,
                   :combustion_stage,
                   Combustion.stage_burning()
                 ),
                 Effect.write_voxel_attribute(macro_index, :fuel_mass, fixed32(12.5)),
                 Effect.write_voxel_attribute(macro_index, :oxygen, fixed32(73.25)),
                 Effect.write_voxel_attribute(macro_index, :combustion_progress, fixed32(42.0)),
                 Effect.write_voxel_attribute(macro_index, :smoke_density, fixed32(6.75)),
                 Effect.write_voxel_attribute(macro_index, :carbonization, fixed32(18.5)),
                 Effect.write_voxel_attribute(
                   macro_index,
                   :structural_integrity,
                   fixed32(82.25)
                 ),
                 Effect.upsert_phenomenon_instance(:combustion, macro_index, %{
                   material_id: wood_material_id,
                   stage: :burning,
                   previous_stage: :preheat,
                   temperature_celsius: 520.0,
                   burned_fuel_kg_per_m3: 1.25,
                   oxygen_after_percent: 73.25
                 })
               ],
               %{source: :combustion_probe_test}
             )

    before_probe = ChunkProcess.debug_state(chunk_pid)

    assert {:ok, summary} =
             CombustionProbe.probe(
               logical_scene_id: logical_scene_id,
               world_macro: world_macro
             )

    after_probe = ChunkProcess.debug_state(chunk_pid)
    assert before_probe.phenomenon_instances == after_probe.phenomenon_instances

    assert summary.combustible == true
    assert summary.material_id == wood_material_id
    assert summary.material_name == :wood
    assert summary.cell_mode == :solid
    assert summary.combustion_stage == :burning
    assert summary.combustion_stage_raw == Combustion.stage_burning()
    assert summary.active_combustion == true
    assert summary.active_combustion_instance == true
    assert summary.world_macro == %{x: 0, y: 0, z: 0}

    attrs = summary.attributes
    assert_in_delta attrs.temperature_celsius, 520.0, 0.001
    assert_in_delta attrs.fuel_mass_kg_per_m3, 12.5, 0.001
    assert_in_delta attrs.oxygen_percent, 73.25, 0.001
    assert_in_delta attrs.combustion_progress_percent, 42.0, 0.001
    assert_in_delta attrs.smoke_density_percent, 6.75, 0.001
    assert_in_delta attrs.carbonization_percent, 18.5, 0.001
    assert_in_delta attrs.structural_integrity_percent, 82.25, 0.001

    assert summary.profile.material_name == :wood
    assert summary.profile.ignition_temperature_celsius > 0.0
    assert summary.profile.residue == %{type: :material, material_id: 9}

    assert summary.phenomenon_instance.kind == :combustion
    assert summary.phenomenon_instance.stage == :burning
    assert summary.phenomenon_instance.macro_index == macro_index
  end

  test "reports inert material as non-combustible without inventing a profile" do
    logical_scene_id = 85_100 + System.unique_integer([:positive])
    world_macro = {1, 0, 0}
    stone_material_id = 2

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk_pid,
               world_macro,
               NormalBlockData.new(stone_material_id)
             )

    assert {:ok, summary} =
             CombustionProbe.probe(
               logical_scene_id: logical_scene_id,
               world_macro: world_macro
             )

    assert summary.material_id == stone_material_id
    assert summary.combustible == false
    assert summary.material_name == nil
    assert summary.profile == nil
    assert summary.combustion_stage == :idle
    assert summary.active_combustion == false
    assert summary.active_combustion_instance == false
    assert summary.phenomenon_instance == nil
  end

  defp fixed32(value), do: round(value * 65_536)
end
