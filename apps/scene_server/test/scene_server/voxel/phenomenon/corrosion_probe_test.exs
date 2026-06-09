defmodule SceneServer.Voxel.Phenomenon.CorrosionProbeTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Phenomenon.Corrosion
  alias SceneServer.Voxel.Phenomenon.CorrosionProbe
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

  test "reads active corrosion truth without mutating authority" do
    logical_scene_id = 86_400 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)
    iron_material_id = 5

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk_pid,
               world_macro,
               NormalBlockData.new(iron_material_id)
             )

    assert {:ok, %{rejected_count: 0}} =
             ChunkProcess.apply_field_effects(
               chunk_pid,
               [
                 Effect.write_voxel_attribute(macro_index, :moisture, fixed32(120.0)),
                 Effect.write_voxel_attribute(
                   macro_index,
                   :chemical_concentration,
                   fixed32(45.0)
                 ),
                 Effect.write_voxel_attribute(
                   macro_index,
                   :surface_state,
                   Corrosion.surface_corroding()
                 ),
                 Effect.write_voxel_attribute(macro_index, :corrosion, fixed32(14.25)),
                 Effect.write_voxel_attribute(
                   macro_index,
                   :structural_integrity,
                   fixed32(94.25)
                 ),
                 Effect.write_voxel_attribute(
                   macro_index,
                   :electric_conductivity,
                   fixed32(7.75)
                 ),
                 Effect.upsert_phenomenon_instance(:corrosion, macro_index, %{
                   material_id: iron_material_id,
                   stage: :corroding,
                   previous_stage: :exposed,
                   corrosion_after_percent: 14.25
                 })
               ],
               %{source: :corrosion_probe_test}
             )

    before_probe = ChunkProcess.debug_state(chunk_pid)

    assert {:ok, summary} =
             CorrosionProbe.probe(
               logical_scene_id: logical_scene_id,
               world_macro: world_macro
             )

    after_probe = ChunkProcess.debug_state(chunk_pid)
    assert before_probe.phenomenon_instances == after_probe.phenomenon_instances

    assert summary.corrodible == true
    assert summary.material_id == iron_material_id
    assert summary.material_name == :iron
    assert summary.cell_mode == :solid
    assert summary.surface_state == :corroding
    assert summary.surface_state_raw == Corrosion.surface_corroding()
    assert summary.active_corrosion == true
    assert summary.active_corrosion_instance == true
    assert summary.world_macro == %{x: 0, y: 0, z: 0}

    attrs = summary.attributes
    assert_in_delta attrs.moisture_kg_per_m3, 120.0, 0.001
    assert_in_delta attrs.chemical_concentration_percent, 45.0, 0.001
    assert_in_delta attrs.corrosion_percent, 14.25, 0.001
    assert_in_delta attrs.corrosion_resistance_percent, 35.0, 0.001
    assert_in_delta attrs.structural_integrity_percent, 94.25, 0.001
    assert_in_delta attrs.electric_conductivity_ms_per_m, 7.75, 0.001

    assert summary.profile.material_name == :iron
    assert summary.profile.moisture_threshold_kg_per_m3 > 0.0
    assert summary.profile.chemical_threshold_percent > 0.0
    assert summary.profile.corrosion_rate_percent_per_second > 0.0

    assert summary.phenomenon_instance.kind == :corrosion
    assert summary.phenomenon_instance.stage == :corroding
    assert summary.phenomenon_instance.macro_index == macro_index
  end

  test "reports inert material as non-corrodible without inventing a profile" do
    logical_scene_id = 86_500 + System.unique_integer([:positive])
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
             CorrosionProbe.probe(
               logical_scene_id: logical_scene_id,
               world_macro: world_macro
             )

    assert summary.material_id == stone_material_id
    assert summary.corrodible == false
    assert summary.material_name == :stone
    assert summary.profile == nil
    assert summary.surface_state == :clean
    assert summary.active_corrosion == false
    assert summary.active_corrosion_instance == false
    assert summary.phenomenon_instance == nil
  end

  defp fixed32(value), do: round(value * 65_536)
end
