defmodule SceneServer.Voxel.Field.FieldRuntimeTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.FieldRuntime
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  @fixed32_scale 65_536
  @iron_material_id 5

  defp solid_storage_with_temperature_delta(world_macro, delta_celsius) do
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    macro_index = Types.macro_index!(local_macro)
    raw_delta = round(delta_celsius * @fixed32_scale)

    storage =
      Storage.new(7, chunk_coord)
      |> Storage.put_solid_block(macro_index, NormalBlockData.new(1))
      |> Storage.put_attribute_for_cell(macro_index, "temperature", raw_delta)

    {storage, local_macro, macro_index}
  end

  describe "ensure_temperature_anomaly/1" do
    test "default heat skill targets 800C and reports the real iron heat budget" do
      logical_scene_id = 71_000 + System.unique_integer([:positive])
      world_macro = {0, 0, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 world_macro,
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:ok, summary} =
               FieldRuntime.ensure_temperature_anomaly(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 max_ticks: 100
               )

      assert summary.target_temperature == 800.0
      assert summary.attribute_write.target_temperature == 800.0
      assert summary.attribute_write.density == 7_870.0
      assert summary.attribute_write.specific_heat_capacity == 449.0
      assert_in_delta summary.attribute_write.heat_energy_joules, 2_756_231_400.0, 1.0
    end

    test "reuses the active field source for repeated heat on the same voxel" do
      logical_scene_id = 70_000 + System.unique_integer([:positive])
      world_macro = {0, 0, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(chunk_pid, world_macro, NormalBlockData.new(1))

      assert {:ok, first} =
               FieldRuntime.ensure_temperature_anomaly(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 heat_energy_joules: 2_560_000,
                 max_ticks: 100
               )

      assert first.field_region_created == true

      assert {:ok, second} =
               FieldRuntime.ensure_temperature_anomaly(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 heat_energy_joules: 2_560_000,
                 max_ticks: 100
               )

      assert second.region_id == first.region_id
      assert second.field_region_created == false
    end
  end

  describe "build_temperature_anomaly/1" do
    test "builds a kernel-first local temperature field from the voxel stored temperature" do
      world_macro = {-1, 16, 17}

      {storage, _local_macro, _macro_index} =
        solid_storage_with_temperature_delta(world_macro, 80)

      assert {:ok, plan} =
               FieldRuntime.build_temperature_anomaly(%{
                 logical_scene_id: 7,
                 storage: storage,
                 world_macro: world_macro,
                 target_temperature: 20,
                 max_ticks: 120,
                 radius: 2
               })

      assert plan.logical_scene_id == 7
      assert plan.chunk_coord == {-1, 1, 1}
      assert plan.local_macro == {15, 0, 1}
      assert plan.source_index == Types.macro_index!({15, 0, 1})

      assert plan.region_attrs == %{
               chunk_coord: {-1, 1, 1},
               aabb: {{13, 0, 0}, {15, 2, 3}},
               kernels: [
                 %{
                   id: :temperature_diffusion,
                   module: TemperatureDiffusionKernel,
                   opts: %{
                     diffusion_time_scale: 1.0,
                     ambient_loss_per_second: 0.0,
                     cell_size_meters: 1.0
                   }
                 }
               ],
               source_points: [
                 %{
                   macro_index: Types.macro_index!({15, 0, 1}),
                   field_type: :temperature,
                   source_mode: :impulse,
                   value: 100.0
                 }
               ],
               max_ticks: 120
             }

      assert plan.summary.created == true
      assert plan.summary.target_temperature == 100.0
      assert plan.summary.baseline_temperature == 20.0
      assert plan.summary.anomaly_delta == 80.0
      assert plan.summary.field_types == ["temperature"]
      assert plan.summary.world_macro == %{x: -1, y: 16, z: 17}
      assert plan.summary.local_macro == %{x: 15, y: 0, z: 1}
    end

    test "does not create a field when the voxel effective temperature is still the baseline" do
      world_macro = {1, 2, 3}
      {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
      macro_index = Types.macro_index!(local_macro)

      storage =
        Storage.new(7, chunk_coord)
        |> Storage.put_solid_block(macro_index, NormalBlockData.new(1))

      assert {:ignore, summary} =
               FieldRuntime.build_temperature_anomaly(%{
                 logical_scene_id: 7,
                 storage: storage,
                 world_macro: world_macro,
                 target_temperature: 100
               })

      assert summary.created == false
      assert summary.reason == :temperature_within_environment_threshold
      assert summary.baseline_temperature == 20.0
      assert summary.target_temperature == 20.0
    end
  end
end
