defmodule SceneServer.Voxel.Field.FieldSourceTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.FieldSource
  alias SceneServer.Voxel.Field.Kernels.ConductionPathKernel
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.Types

  describe "normalize/1" do
    test "normalizes a temperature voxel source into a deterministic runtime struct" do
      assert Code.ensure_loaded?(FieldSource),
             "FieldSource module is required for Phase 7.D2"

      assert function_exported?(FieldSource, :normalize, 1),
             "FieldSource.normalize/1 is required for Phase 7.D2"

      source =
        FieldSource.normalize(%{
          logical_scene_id: 7,
          world_macro: {-1, 16, 17},
          target_temperature_celsius: 0,
          max_ticks: 120,
          radius: 2,
          created_tick: 11,
          updated_tick: 13,
          lease_token: :lease_1
        })

      assert source.source_id == {:temperature, 7, {-1, 16, 17}}
      assert source.source_key == {:temperature, Types.macro_index!({15, 0, 1})}
      assert source.source_kind == :temperature
      assert source.source_mode == :impulse

      assert source.owner_ref == %{
               kind: :voxel,
               logical_scene_id: 7,
               world_macro: %{x: -1, y: 16, z: 17}
             }

      assert source.location == %{
               world_macro: %{x: -1, y: 16, z: 17},
               chunk_coord: %{x: -1, y: 1, z: 1},
               local_macro: %{x: 15, y: 0, z: 1},
               macro_index: Types.macro_index!({15, 0, 1})
             }

      assert source.target_value == 0.0
      assert source.source_value == 0.0

      assert source.kernel_specs == [
               %{
                 id: :temperature_diffusion,
                 module: TemperatureDiffusionKernel,
                 opts: %{
                   diffusion_time_scale: 20_000.0,
                   ambient_loss_per_second: 0.08,
                   cell_size_meters: 1.0
                 }
               }
             ]

      assert source.decay_policy == %{field_radius: 2, max_ticks: 120}
      assert source.lease_token == :lease_1
      assert source.created_tick == 11
      assert source.updated_tick == 13
    end

    test "normalizes an electric conduction source with owner ttl and budget" do
      source =
        FieldSource.normalize(%{
          source_kind: :electric,
          source_mode: :persistent,
          logical_scene_id: 9,
          source_world_macro: {0, 1, 0},
          target_world_macro: {3, 1, 0},
          source_potential: "150",
          max_ticks: 90,
          ttl_ticks: 45,
          radius: 1,
          max_frontier: 64,
          energy_budget_joules: "5000",
          owner_ref: %{kind: :device, id: "coil-7"}
        })

      source_index = Types.macro_index!({0, 1, 0})
      target_index = Types.macro_index!({3, 1, 0})

      assert source.source_kind == :electric
      assert source.source_mode == :persistent
      assert source.owner_ref == %{kind: :device, id: "coil-7"}
      assert source.source_id == {:electric, 9, {:device, "coil-7"}, {0, 1, 0}, {3, 1, 0}}
      assert source.source_key == {:electric, {:device, "coil-7"}, source_index, target_index}

      assert source.location == %{
               source_world_macro: %{x: 0, y: 1, z: 0},
               target_world_macro: %{x: 3, y: 1, z: 0},
               chunk_coord: %{x: 0, y: 0, z: 0},
               source_local_macro: %{x: 0, y: 1, z: 0},
               target_local_macro: %{x: 3, y: 1, z: 0},
               source_index: source_index,
               target_index: target_index
             }

      assert source.source_value == 150.0
      assert source.target_value == %{world_macro: %{x: 3, y: 1, z: 0}, macro_index: target_index}

      assert source.kernel_specs == [
               %{
                 id: :conduction_path,
                 module: ConductionPathKernel,
                 opts: %{target_macro_index: target_index, max_frontier: 64}
               }
             ]

      assert source.decay_policy == %{
               field_radius: 1,
               max_ticks: 90,
               ttl_ticks: 45,
               max_frontier: 64,
               energy_budget_joules: 5000.0
             }
    end
  end
end
