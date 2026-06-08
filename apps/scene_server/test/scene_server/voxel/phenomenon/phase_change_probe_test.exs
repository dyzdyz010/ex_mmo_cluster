defmodule SceneServer.Voxel.Phenomenon.PhaseChangeProbeTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Phenomenon.Effect
  alias SceneServer.Voxel.Phenomenon.PhaseChangeProbe
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

  test "reads frozen contained-moisture state without mutating authority" do
    logical_scene_id = 84_000 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk_pid,
               world_macro,
               NormalBlockData.new(MaterialCatalog.wood_material_id())
             )

    assert {:ok, %{changed?: true}} =
             ChunkProcess.write_temperature_attribute(chunk_pid, %{
               macro: world_macro,
               target_temperature: -8.0
             })

    assert {:ok, %{rejected_count: 0}} =
             ChunkProcess.apply_field_effects(
               chunk_pid,
               [
                 Effect.write_voxel_attribute(macro_index, :moisture, fixed32(32.0)),
                 Effect.write_voxel_attribute(macro_index, :phase_state, 1),
                 Effect.write_voxel_attribute(macro_index, :structural_integrity, fixed32(91.5)),
                 Effect.upsert_phenomenon_instance(:phase_change, macro_index, %{
                   material_id: MaterialCatalog.wood_material_id(),
                   stage: :frozen,
                   previous_stage: :stable,
                   temperature_celsius: -8.0,
                   moisture_kg_per_m3: 32.0
                 })
               ],
               %{source: :phase_change_probe_test}
             )

    before_probe = ChunkProcess.debug_state(chunk_pid)

    assert {:ok, summary} =
             PhaseChangeProbe.probe(
               logical_scene_id: logical_scene_id,
               world_macro: world_macro
             )

    after_probe = ChunkProcess.debug_state(chunk_pid)
    assert before_probe.phenomenon_instances == after_probe.phenomenon_instances

    assert summary.phase_state == :frozen
    assert summary.phase_state_raw == 1
    assert summary.active_phase_change == true
    assert summary.active_phase_change_instance == true
    assert summary.material_name == :wood
    assert summary.cell_mode == :solid
    assert summary.world_macro == %{x: 0, y: 0, z: 0}

    attrs = summary.attributes
    assert_in_delta attrs.temperature_celsius, -8.0, 0.001
    assert_in_delta attrs.moisture_kg_per_m3, 32.0, 0.001
    assert_in_delta attrs.structural_integrity_percent, 91.5, 0.001

    assert summary.phenomenon_instance.stage == :frozen
    assert summary.phenomenon_instance.kind == :phase_change
    assert summary.phenomenon_instance.macro_index == macro_index
  end

  test "summarizes vaporized hot material and current moisture truth" do
    logical_scene_id = 84_100 + System.unique_integer([:positive])
    world_macro = {1, 0, 0}
    macro_index = Types.macro_index!(world_macro)

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk_pid,
               world_macro,
               NormalBlockData.new(MaterialCatalog.wood_material_id())
             )

    assert {:ok, %{changed?: true}} =
             ChunkProcess.write_temperature_attribute(chunk_pid, %{
               macro: world_macro,
               target_temperature: 155.0
             })

    assert {:ok, %{rejected_count: 0}} =
             ChunkProcess.apply_field_effects(
               chunk_pid,
               [
                 Effect.write_voxel_attribute(macro_index, :moisture, fixed32(0.0)),
                 Effect.write_voxel_attribute(macro_index, :phase_state, 3)
               ],
               %{source: :phase_change_probe_test}
             )

    assert {:ok, summary} =
             PhaseChangeProbe.probe(
               logical_scene_id: logical_scene_id,
               world_macro: world_macro
             )

    assert summary.phase_state == :vapor
    assert summary.phase_state_raw == 3
    assert summary.active_phase_change == true
    assert summary.active_phase_change_instance == false
    assert summary.phenomenon_instance == nil
    assert_in_delta summary.attributes.temperature_celsius, 155.0, 0.001
    assert_in_delta summary.attributes.moisture_kg_per_m3, 0.0, 0.001
  end

  defp fixed32(value), do: round(value * 65_536)
end
