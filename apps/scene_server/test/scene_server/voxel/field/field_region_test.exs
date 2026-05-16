defmodule SceneServer.Voxel.Field.FieldRegionTest do
  # Phase 7.A: FieldRegion is kernel-first. `field_types` is derived from
  # kernel required layers and then used as the wire/layer declaration.
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion}
  alias SceneServer.Voxel.Field.Kernels.{ElectricPotentialKernel, TemperatureDiffusionKernel}

  defmodule UnknownLayerKernel do
    @behaviour SceneServer.Voxel.Field.Kernel

    def kernel_id, do: :unknown_layer
    def required_layers(_opts), do: [:nonsense]
    def tick(region, _context, _opts), do: {:cont, region, []}
  end

  defmodule MissingTickKernel do
    def required_layers(_opts), do: [:temperature]
  end

  describe "new/1" do
    test "derives field_types and empty layers from kernel required layers" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          kernels: [temperature_kernel(), electric_kernel()]
        })

      assert region.region_id == 1
      assert region.chunk_coord == {0, 0, 0}
      assert region.aabb == {{0, 0, 0}, {7, 7, 7}}
      assert region.field_types == [:temperature, :electric_potential, :ionization]
      assert Enum.map(region.kernels, & &1.id) == [:temperature_diffusion, :electric_potential]
      assert region.tick_count == 0
      assert region.max_ticks == nil
      assert region.source_points == []
      assert Map.has_key?(region.layers, :temperature)
      assert Map.has_key?(region.layers, :electric_potential)
      assert Map.has_key?(region.layers, :ionization)
      assert match?(%FieldLayer{}, region.layers.temperature)
      assert FieldLayer.get(region.layers.temperature, 0) == 20
      assert FieldLayer.get(region.layers.electric_potential, 0) == 0.0
      assert FieldLayer.get(region.layers.ionization, 0) == 0.0
    end

    test "requires explicit non-empty kernels" do
      assert_raise ArgumentError, ~r/missing required :kernels/, fn ->
        FieldRegion.new(%{
          region_id: 2,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}}
        })
      end

      assert_raise ArgumentError, ~r/kernels must be a non-empty list/, fn ->
        FieldRegion.new(%{
          region_id: 3,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}},
          kernels: []
        })
      end
    end

    test "rejects field_types as an input truth source" do
      assert_raise ArgumentError, ~r/field_types are derived from kernels/, fn ->
        FieldRegion.new(%{
          region_id: 4,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}},
          field_types: [:temperature],
          kernels: [temperature_kernel()]
        })
      end
    end

    test "accepts source_points and max_ticks when source field_type is produced by kernels" do
      region =
        FieldRegion.new(%{
          region_id: 5,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {1, 1, 1}},
          kernels: [temperature_kernel()],
          source_points: [%{macro_index: 0, field_type: :temperature, value: 100.0}],
          max_ticks: 5
        })

      assert region.field_types == [:temperature]
      assert region.max_ticks == 5
      assert hd(region.source_points).value == 100.0
    end

    test "rejects source_points whose field_type is not produced by kernels" do
      assert_raise ArgumentError, ~r/source_point field_type :electric_potential/, fn ->
        FieldRegion.new(%{
          region_id: 6,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {1, 1, 1}},
          kernels: [temperature_kernel()],
          source_points: [%{macro_index: 0, field_type: :electric_potential, value: 100.0}]
        })
      end
    end

    test "normalizes custom kernel specs while deriving field_types from the kernel module" do
      region =
        FieldRegion.new(%{
          region_id: 7,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}},
          kernels: [
            %{
              "id" => :custom_temperature,
              "module" => TemperatureDiffusionKernel,
              "opts" => %{"mode" => "test"}
            }
          ]
        })

      assert region.field_types == [:temperature]

      assert region.kernels == [
               %{
                 id: :custom_temperature,
                 module: TemperatureDiffusionKernel,
                 opts: %{"mode" => "test"}
               }
             ]
    end

    test "rejects kernels requiring unknown layers" do
      assert_raise ArgumentError, ~r/requires unknown layer :nonsense/, fn ->
        FieldRegion.new(%{
          region_id: 8,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}},
          kernels: [%{id: :unknown_layer, module: UnknownLayerKernel}]
        })
      end
    end

    test "rejects kernel modules without the required callbacks" do
      assert_raise ArgumentError, ~r/must export required_layers\/1 and tick\/3/, fn ->
        FieldRegion.new(%{
          region_id: 9,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}},
          kernels: [%{id: :missing_tick, module: MissingTickKernel}]
        })
      end
    end
  end

  describe "in_aabb?/2" do
    test "true inside, false outside (inclusive bounds)" do
      region = temperature_region(aabb: {{1, 1, 1}, {3, 3, 3}})

      assert FieldRegion.in_aabb?(region, {1, 1, 1})
      assert FieldRegion.in_aabb?(region, {3, 3, 3})
      assert FieldRegion.in_aabb?(region, {2, 2, 2})
      refute FieldRegion.in_aabb?(region, {0, 0, 0})
      refute FieldRegion.in_aabb?(region, {4, 4, 4})
      refute FieldRegion.in_aabb?(region, {2, 4, 2})
    end
  end

  describe "tick_limit_reached?/1" do
    test "nil max_ticks -> never reached" do
      region = temperature_region()

      refute FieldRegion.tick_limit_reached?(region)

      region = %{region | tick_count: 9_999_999}
      refute FieldRegion.tick_limit_reached?(region)
    end

    test "tick_count >= max_ticks -> true" do
      region = temperature_region(max_ticks: 3)

      refute FieldRegion.tick_limit_reached?(region)

      region = %{region | tick_count: 2}
      refute FieldRegion.tick_limit_reached?(region)

      region = %{region | tick_count: 3}
      assert FieldRegion.tick_limit_reached?(region)

      region = %{region | tick_count: 100}
      assert FieldRegion.tick_limit_reached?(region)
    end
  end

  describe "put_layer/3 + get_layer/2" do
    test "round-trips the requested field_type" do
      region = temperature_region()

      new_layer = FieldLayer.put(FieldLayer.new(), 0, 42.0)
      region = FieldRegion.put_layer(region, :temperature, new_layer)

      assert FieldLayer.get(FieldRegion.get_layer(region, :temperature), 0) == 42.0
    end

    test "get_layer falls back to empty layer for missing field_type" do
      region = temperature_region()

      layer = FieldRegion.get_layer(region, :ionization)
      assert match?(%FieldLayer{}, layer)
      assert FieldLayer.get(layer, 0) == 0.0
    end
  end

  describe "increment_tick/1" do
    test "increments tick_count by 1" do
      region = temperature_region()

      assert region.tick_count == 0
      region = FieldRegion.increment_tick(region)
      assert region.tick_count == 1
      region = FieldRegion.increment_tick(region)
      assert region.tick_count == 2
    end
  end

  describe "aabb_cell_count/1" do
    test "computes inclusive volume" do
      region = temperature_region(aabb: {{0, 0, 0}, {7, 7, 7}})

      assert FieldRegion.aabb_cell_count(region) == 8 * 8 * 8
    end
  end

  defp temperature_region(attrs \\ []) do
    defaults = %{
      region_id: 1,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {0, 0, 0}},
      kernels: [temperature_kernel()]
    }

    attrs = Map.new(attrs)

    defaults
    |> Map.merge(attrs)
    |> FieldRegion.new()
  end

  defp temperature_kernel do
    %{id: :temperature_diffusion, module: TemperatureDiffusionKernel}
  end

  defp electric_kernel do
    %{id: :electric_potential, module: ElectricPotentialKernel}
  end
end
