defmodule SceneServer.Voxel.Field.OxygenDiffusionKernelTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.OxygenDiffusionKernel
  alias SceneServer.Voxel.Types

  test "oxygen deficit diffuses outward from a combustion sink" do
    source_index = Types.macro_index!({1, 1, 1})
    neighbor_index = Types.macro_index!({2, 1, 1})

    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {3, 3, 3}},
        kernels: [%{id: :oxygen_diffusion, module: OxygenDiffusionKernel}],
        source_points: [
          %{
            macro_index: source_index,
            field_type: :oxygen,
            source_mode: :persistent,
            value: 40.0
          }
        ]
      })

    assert {:cont, updated, []} =
             OxygenDiffusionKernel.tick(
               region,
               KernelContext.new(region, 1, nil, dt_ms: 100),
               %{
                 diffusion_alpha: 0.6,
                 decay_per_second: 0.0
               }
             )

    oxygen_layer = FieldRegion.get_layer(updated, :oxygen)

    assert FieldLayer.get(oxygen_layer, source_index) == 40.0
    assert FieldLayer.get(oxygen_layer, neighbor_index) < 100.0
  end

  test "oxygen decay restores deficits toward ambient air instead of toward zero" do
    source_index = Types.macro_index!({1, 1, 1})

    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {2, 2, 2}},
        kernels: [%{id: :oxygen_diffusion, module: OxygenDiffusionKernel}],
        source_points: [
          %{
            macro_index: source_index,
            field_type: :oxygen,
            source_mode: :impulse,
            value: 40.0
          }
        ]
      })

    assert {:cont, after_impulse, []} =
             OxygenDiffusionKernel.tick(
               region,
               KernelContext.new(region, 1, nil, dt_ms: 100),
               %{
                 diffusion_alpha: 0.0,
                 decay_per_second: 1.0
               }
             )

    assert after_impulse.source_points == []

    value_after_impulse =
      after_impulse
      |> FieldRegion.get_layer(:oxygen)
      |> FieldLayer.get(source_index)

    assert value_after_impulse > 40.0
    assert value_after_impulse < 100.0
  end
end
