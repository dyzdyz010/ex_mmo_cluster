defmodule SceneServer.Voxel.Field.ThermalKernelSpecsTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldRegion, ThermalKernelSpecs}
  alias SceneServer.Voxel.Field.Kernels.SmokeDiffusionKernel
  alias SceneServer.Voxel.Phenomenon.CombustionKernel

  test "temperature sources use one shared thermal phenomenon kernel chain" do
    specs = ThermalKernelSpecs.temperature_source_specs()

    assert Enum.map(specs, & &1.id) == [
             :temperature_diffusion,
             :combustion,
             :phase_change,
             :smoke_diffusion,
             :oxygen_diffusion,
             :moisture_diffusion
           ]

    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: specs
      })

    assert region.field_types == [:temperature, :smoke_density, :oxygen, :moisture]
  end

  test "combustion handoffs inherit diffusion specs and replace combustion opts deliberately" do
    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :temperature_diffusion,
            module: SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
          },
          %{id: :combustion, module: CombustionKernel, opts: %{boundary_radius: 9}},
          %{id: :phase_change, module: SceneServer.Voxel.Phenomenon.PhaseChangeKernel},
          %{
            id: :smoke_diffusion,
            module: SmokeDiffusionKernel,
            opts: %{diffusion_alpha: 0.33, decay_per_second: 0.02}
          }
        ]
      })

    specs =
      ThermalKernelSpecs.inherit_region_specs(region,
        combustion_module: CombustionKernel,
        combustion_opts: %{profile: %{heat_source_celsius: 700.0}}
      )

    assert Enum.map(specs, & &1.id) == [
             :temperature_diffusion,
             :combustion,
             :phase_change,
             :smoke_diffusion,
             :oxygen_diffusion,
             :moisture_diffusion
           ]

    assert Enum.find(specs, &(&1.id == :combustion)).opts == %{
             profile: %{heat_source_celsius: 700.0}
           }

    assert Enum.find(specs, &(&1.id == :smoke_diffusion)).opts == %{
             diffusion_alpha: 0.33,
             decay_per_second: 0.02
           }
  end
end
