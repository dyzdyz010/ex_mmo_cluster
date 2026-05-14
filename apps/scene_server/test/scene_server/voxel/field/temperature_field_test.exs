defmodule SceneServer.Voxel.Field.TemperatureFieldTest do
  # Phase 6 局部场最小目标:TemperatureField (7-stencil) 单元测试。
  #
  # 覆盖:
  #   - 热源点 → 相邻 cell 温度上升
  #   - 衰减:无热源时温度向 env_temp (20.0) 靠近
  #   - source_points 在 tick 末被重置(热源持续)
  #   - 高 thermal_conductivity 路径不报错(用 nil storage 跑默认 α)
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, TemperatureField}
  alias SceneServer.Voxel.Types

  describe "tick/2" do
    test "heat source raises temperature in neighbor cells over multiple ticks" do
      source_idx = Types.macro_index!({3, 3, 3})

      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          field_types: [:temperature],
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

      # Adjacent cells (Manhattan distance 1) heated above env_temp.
      neighbor_val = FieldLayer.get(layer, Types.macro_index!({4, 3, 3}))
      env = TemperatureField.env_temperature()

      assert neighbor_val > env + 1.0,
             "expected neighbor cell to be heated above env+1; got #{neighbor_val} vs env #{env}"
    end

    test "without sources, layer remains ambient and has no active cells" do
      region =
        FieldRegion.new(%{
          region_id: 2,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          field_types: [:temperature]
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
          field_types: [:temperature],
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

    test "diffusion keeps temperature layer sparse and integer-valued" do
      source_idx = Types.macro_index!({3, 3, 3})

      region =
        FieldRegion.new(%{
          region_id: 5,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          field_types: [:temperature],
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
      assert Enum.all?(active, fn {_idx, value} -> value == round(value) end)
    end

    test "high dev-style source spreads beyond the immediate 6-neighbor shell" do
      source_idx = Types.macro_index!({3, 3, 3})
      second_ring_idx = Types.macro_index!({5, 3, 3})

      region =
        FieldRegion.new(%{
          region_id: 6,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          field_types: [:temperature],
          source_points: [
            %{macro_index: source_idx, field_type: :temperature, value: 500.0}
          ]
        })

      region = Enum.reduce(1..8, region, fn _, acc -> TemperatureField.tick(acc, nil) end)
      layer = FieldRegion.get_layer(region, :temperature)

      active_indices =
        layer |> FieldLayer.active_cells({{0, 0, 0}, {7, 7, 7}}) |> Enum.map(&elem(&1, 0))

      assert second_ring_idx in active_indices
      assert FieldLayer.get(layer, second_ring_idx) > TemperatureField.env_temperature()
    end

    test "source_points are re-applied each tick (heat sources are maintained)" do
      source_idx = Types.macro_index!({2, 2, 2})

      region =
        FieldRegion.new(%{
          region_id: 4,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          field_types: [:temperature],
          source_points: [
            %{macro_index: source_idx, field_type: :temperature, value: 250.0}
          ]
        })

      region =
        Enum.reduce(1..20, region, fn _, acc -> TemperatureField.tick(acc, nil) end)

      layer = FieldRegion.get_layer(region, :temperature)
      assert FieldLayer.get(layer, source_idx) == 250.0
    end
  end
end
