defmodule SceneServer.Voxel.Field.SmokeDiffusionKernelTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.SmokeDiffusionKernel
  alias SceneServer.Voxel.Types

  test "persistent smoke sources diffuse through the scalar field without leaving voxel attributes as the only truth" do
    source_index = Types.macro_index!({1, 1, 1})
    neighbor_index = Types.macro_index!({2, 1, 1})

    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {3, 3, 3}},
        kernels: [%{id: :smoke_diffusion, module: SmokeDiffusionKernel}],
        source_points: [
          %{
            macro_index: source_index,
            field_type: :smoke_density,
            source_mode: :persistent,
            value: 60.0
          }
        ]
      })

    assert {:cont, updated, []} =
             SmokeDiffusionKernel.tick(region, KernelContext.new(region, 1, nil, dt_ms: 100), %{
               diffusion_alpha: 0.6,
               decay_per_second: 0.0
             })

    smoke_layer = FieldRegion.get_layer(updated, :smoke_density)

    assert FieldLayer.get(smoke_layer, source_index) == 60.0
    assert FieldLayer.get(smoke_layer, neighbor_index) > 0.0
  end

  test "impulse smoke sources are consumed and then decay toward clear air" do
    source_index = Types.macro_index!({1, 1, 1})

    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {2, 2, 2}},
        kernels: [%{id: :smoke_diffusion, module: SmokeDiffusionKernel}],
        source_points: [
          %{
            macro_index: source_index,
            field_type: :smoke_density,
            source_mode: :impulse,
            value: 30.0
          }
        ]
      })

    assert {:cont, after_impulse, []} =
             SmokeDiffusionKernel.tick(region, KernelContext.new(region, 1, nil, dt_ms: 100), %{
               diffusion_alpha: 0.0,
               decay_per_second: 1.0
             })

    assert after_impulse.source_points == []

    value_after_impulse =
      after_impulse
      |> FieldRegion.get_layer(:smoke_density)
      |> FieldLayer.get(source_index)

    assert value_after_impulse > 0.0
    assert value_after_impulse < 30.0

    assert {:cont, after_decay, []} =
             SmokeDiffusionKernel.tick(
               after_impulse,
               KernelContext.new(after_impulse, 1, nil, dt_ms: 100),
               %{
                 diffusion_alpha: 0.0,
                 decay_per_second: 1.0
               }
             )

    value_after_decay =
      after_decay
      |> FieldRegion.get_layer(:smoke_density)
      |> FieldLayer.get(source_index)

    assert value_after_decay < value_after_impulse
  end
end
