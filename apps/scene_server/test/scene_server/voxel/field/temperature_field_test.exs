defmodule SceneServer.Voxel.Field.TemperatureFieldTest do
  # Phase 6 局部场最小目标:TemperatureField (7-stencil) 单元测试。
  #
  # 覆盖:
  #   - 热源点 → 相邻 cell 温度按真实 SI 扩散步长缓慢上升
  #   - 无热源时保持 env_temp (20.0)
  #   - persistent source_points 在 tick 末被重置(热源持续)
  #   - impulse source_points 只注入一次,适合技能热量输入
  #   - 默认热扩散率路径不报错(用 nil storage 跑默认 α)
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, TemperatureField}
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.{NormalBlockData, Storage}
  alias SceneServer.Voxel.Types

  @iron_material_id 5

  describe "tick/2" do
    test "heat source raises neighbor temperature by the physical dt-scaled amount" do
      source_idx = Types.macro_index!({3, 3, 3})

      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
          source_points: [
            %{macro_index: source_idx, field_type: :temperature, value: 500.0}
          ]
        })

      # Tick repeatedly to let heat diffuse.
      region =
        Enum.reduce(1..10, region, fn _, acc -> TemperatureField.tick(acc, nil) end)

      layer = FieldRegion.get_layer(region, :temperature)

      # Source maintained at 500.0 (re-applied each tick).
      assert FieldLayer.get(layer, source_idx) == 500.0

      # 1m voxels at 10Hz conduct slowly under real SI units; the neighbor is
      # measurably warmer but nowhere near the debug-era env+1 jump.
      neighbor_val = FieldLayer.get(layer, Types.macro_index!({4, 3, 3}))
      env = TemperatureField.env_temperature()

      assert neighbor_val > env
      assert neighbor_val < env + 0.05
    end

    test "without sources, layer remains ambient and has no active cells" do
      region =
        FieldRegion.new(%{
          region_id: 2,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}]
        })

      region =
        Enum.reduce(1..50, region, fn _, acc -> TemperatureField.tick(acc, nil) end)

      layer = FieldRegion.get_layer(region, :temperature)
      env = TemperatureField.env_temperature()

      for x <- 0..3, y <- 0..3, z <- 0..3 do
        val = FieldLayer.get(layer, Types.macro_index!({x, y, z}))
        assert val == env
      end

      assert FieldLayer.active_cells(layer, {{0, 0, 0}, {3, 3, 3}}) == []
    end

    test "far cells stay close to env_temp after a small number of ticks" do
      source_idx = Types.macro_index!({0, 0, 0})

      region =
        FieldRegion.new(%{
          region_id: 3,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
          source_points: [
            %{macro_index: source_idx, field_type: :temperature, value: 100.0}
          ]
        })

      region = Enum.reduce(1..10, region, fn _, acc -> TemperatureField.tick(acc, nil) end)

      layer = FieldRegion.get_layer(region, :temperature)
      env = TemperatureField.env_temperature()
      far = FieldLayer.get(layer, Types.macro_index!({7, 7, 7}))

      # 10 ticks is not enough for heat at (0,0,0) to significantly warm
      # the opposite corner; allow a wide tolerance to avoid false flake.
      assert abs(far - env) < 30.0,
             "expected far cell to be near env (#{env}); got #{far}"
    end

    test "diffusion keeps temperature layer sparse and preserves fractional heat" do
      source_idx = Types.macro_index!({3, 3, 3})

      region =
        FieldRegion.new(%{
          region_id: 5,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
          source_points: [
            %{macro_index: source_idx, field_type: :temperature, value: 500.0}
          ]
        })

      region = Enum.reduce(1..6, region, fn _, acc -> TemperatureField.tick(acc, nil) end)
      layer = FieldRegion.get_layer(region, :temperature)
      active = FieldLayer.active_cells(layer, {{0, 0, 0}, {7, 7, 7}})
      active_indices = Enum.map(active, &elem(&1, 0))

      assert source_idx in active_indices
      assert Types.macro_index!({7, 7, 7}) not in active_indices
      assert length(active) < FieldRegion.aabb_cell_count(region)
      assert Enum.any?(active, fn {_idx, value} -> value != round(value) end)
    end

    test "high source stays local over short real-time windows" do
      source_idx = Types.macro_index!({3, 3, 3})
      second_ring_idx = Types.macro_index!({5, 3, 3})

      region =
        FieldRegion.new(%{
          region_id: 6,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
          source_points: [
            %{macro_index: source_idx, field_type: :temperature, value: 500.0}
          ]
        })

      region = Enum.reduce(1..8, region, fn _, acc -> TemperatureField.tick(acc, nil) end)
      layer = FieldRegion.get_layer(region, :temperature)

      active_indices =
        layer |> FieldLayer.active_cells({{0, 0, 0}, {7, 7, 7}}) |> Enum.map(&elem(&1, 0))

      refute second_ring_idx in active_indices
      assert FieldLayer.get(layer, second_ring_idx) < TemperatureField.env_temperature() + 0.001
    end

    test "default 100C heat source does not reach second ring in two seconds" do
      source_idx = Types.macro_index!({4, 4, 4})
      second_ring_idx = Types.macro_index!({6, 4, 4})

      region =
        FieldRegion.new(%{
          region_id: 7,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {8, 8, 8}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
          source_points: [
            %{macro_index: source_idx, field_type: :temperature, value: 100.0}
          ]
        })

      region = Enum.reduce(1..20, region, fn _, acc -> TemperatureField.tick(acc, nil) end)
      layer = FieldRegion.get_layer(region, :temperature)

      assert FieldLayer.get(layer, second_ring_idx) < TemperatureField.env_temperature() + 0.001

      active_indices =
        layer |> FieldLayer.active_cells({{0, 0, 0}, {8, 8, 8}}) |> Enum.map(&elem(&1, 0))

      refute second_ring_idx in active_indices
    end

    test "800C iron impulse barely cools over two ticks in a one-meter voxel" do
      source_idx = Types.macro_index!({3, 3, 3})

      storage =
        Storage.new(7, {0, 0, 0})
        |> Storage.put_solid_block(source_idx, NormalBlockData.new(@iron_material_id))

      region =
        FieldRegion.new(%{
          region_id: 9,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
          source_points: [
            %{
              macro_index: source_idx,
              field_type: :temperature,
              source_mode: :impulse,
              value: 800.0
            }
          ]
        })

      region = Enum.reduce(1..2, region, fn _, acc -> TemperatureField.tick(acc, storage) end)
      layer = FieldRegion.get_layer(region, :temperature)
      center = FieldLayer.get(layer, source_idx)
      neighbor = FieldLayer.get(layer, Types.macro_index!({4, 3, 3}))

      assert center > 799.99
      assert neighbor > TemperatureField.env_temperature()
      assert neighbor < TemperatureField.env_temperature() + 0.01
    end

    test "interactive heat profile compresses field time and dissipates visibly" do
      source_idx = Types.macro_index!({3, 3, 3})
      first_ring_idx = Types.macro_index!({4, 3, 3})
      second_ring_idx = Types.macro_index!({5, 3, 3})

      storage =
        Storage.new(7, {0, 0, 0})
        |> Storage.put_solid_block(source_idx, NormalBlockData.new(@iron_material_id))

      region =
        FieldRegion.new(%{
          region_id: 10,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
          source_points: [
            %{
              macro_index: source_idx,
              field_type: :temperature,
              source_mode: :impulse,
              value: 800.0
            }
          ]
        })

      region =
        Enum.reduce(1..10, region, fn _, acc ->
          TemperatureField.tick(acc, storage,
            diffusion_time_scale: 20_000.0,
            ambient_loss_per_second: 0.08
          )
        end)

      layer = FieldRegion.get_layer(region, :temperature)
      env = TemperatureField.env_temperature()

      assert FieldLayer.get(layer, source_idx) < 760.0
      assert FieldLayer.get(layer, first_ring_idx) > env + 20.0
      assert FieldLayer.get(layer, second_ring_idx) > env + 2.0
    end

    test "source_points are re-applied each tick (heat sources are maintained)" do
      source_idx = Types.macro_index!({2, 2, 2})

      region =
        FieldRegion.new(%{
          region_id: 4,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
          source_points: [
            %{macro_index: source_idx, field_type: :temperature, value: 250.0}
          ]
        })

      region =
        Enum.reduce(1..20, region, fn _, acc -> TemperatureField.tick(acc, nil) end)

      layer = FieldRegion.get_layer(region, :temperature)
      assert FieldLayer.get(layer, source_idx) == 250.0
    end

    test "impulse source_points inject heat once instead of being maintained" do
      source_idx = Types.macro_index!({2, 2, 2})

      region =
        FieldRegion.new(%{
          region_id: 8,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
          source_points: [
            %{
              macro_index: source_idx,
              field_type: :temperature,
              source_mode: :impulse,
              value: 100.0
            }
          ]
        })

      after_first_tick = TemperatureField.tick(region, nil)
      after_second_tick = TemperatureField.tick(after_first_tick, nil)

      first_layer = FieldRegion.get_layer(after_first_tick, :temperature)
      second_layer = FieldRegion.get_layer(after_second_tick, :temperature)

      assert after_first_tick.source_points == []
      assert FieldLayer.get(first_layer, source_idx) > TemperatureField.env_temperature()
      assert FieldLayer.get(second_layer, source_idx) < FieldLayer.get(first_layer, source_idx)
    end
  end
end
