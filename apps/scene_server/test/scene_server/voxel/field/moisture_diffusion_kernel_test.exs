defmodule SceneServer.Voxel.Field.MoistureDiffusionKernelTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.MoistureDiffusionKernel
  alias SceneServer.Voxel.Types

  test "released moisture diffuses outward from a drying combustion source" do
    source_index = Types.macro_index!({1, 1, 1})
    neighbor_index = Types.macro_index!({2, 1, 1})

    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {3, 3, 3}},
        kernels: [%{id: :moisture_diffusion, module: MoistureDiffusionKernel}],
        source_points: [
          %{
            macro_index: source_index,
            field_type: :moisture,
            source_mode: :persistent,
            value: 180.0
          }
        ]
      })

    assert {:cont, updated, []} =
             MoistureDiffusionKernel.tick(
               region,
               KernelContext.new(region, 1, nil, dt_ms: 100),
               %{
                 diffusion_alpha: 0.6,
                 decay_per_second: 0.0
               }
             )

    moisture_layer = FieldRegion.get_layer(updated, :moisture)

    assert FieldLayer.get(moisture_layer, source_index) == 180.0
    assert FieldLayer.get(moisture_layer, neighbor_index) > 0.0
  end

  test "moisture decay dries released vapor toward zero" do
    source_index = Types.macro_index!({1, 1, 1})

    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {2, 2, 2}},
        kernels: [%{id: :moisture_diffusion, module: MoistureDiffusionKernel}],
        source_points: [
          %{
            macro_index: source_index,
            field_type: :moisture,
            source_mode: :impulse,
            value: 180.0
          }
        ]
      })

    assert {:cont, after_impulse, []} =
             MoistureDiffusionKernel.tick(
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
      |> FieldRegion.get_layer(:moisture)
      |> FieldLayer.get(source_index)

    assert value_after_impulse > 0.0
    assert value_after_impulse < 180.0
  end
end
