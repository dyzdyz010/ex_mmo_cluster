defmodule SceneServer.Voxel.Field.FieldRegionTest do
  # Phase 6 局部场最小目标:FieldRegion 结构 / 行为单元测试。
  #
  # 覆盖:
  #   - new/1 按 field_types 创建空 layers,默认 max_ticks = nil
  #   - in_aabb?/2 inclusive 边界判定
  #   - tick_limit_reached?/1:nil = never, tick_count >= max_ticks = true
  #   - put_layer/3 + get_layer/2 round-trip
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion}

  describe "new/1" do
    test "creates empty layers for the requested field_types" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}},
          field_types: [:temperature, :electric_potential, :ionization]
        })

      assert region.region_id == 1
      assert region.chunk_coord == {0, 0, 0}
      assert region.aabb == {{0, 0, 0}, {7, 7, 7}}
      assert region.field_types == [:temperature, :electric_potential, :ionization]
      assert region.tick_count == 0
      assert region.max_ticks == nil
      assert region.source_points == []
      assert Map.has_key?(region.layers, :temperature)
      assert Map.has_key?(region.layers, :electric_potential)
      assert Map.has_key?(region.layers, :ionization)
      assert match?(%FieldLayer{}, region.layers.temperature)
    end

    test "defaults field_types to [:temperature]" do
      region =
        FieldRegion.new(%{
          region_id: 2,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}}
        })

      assert region.field_types == [:temperature]
    end

    test "raises on unknown field_type" do
      assert_raise ArgumentError, fn ->
        FieldRegion.new(%{
          region_id: 3,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}},
          field_types: [:nonsense]
        })
      end
    end

    test "accepts source_points and max_ticks" do
      region =
        FieldRegion.new(%{
          region_id: 4,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {1, 1, 1}},
          source_points: [%{macro_index: 0, field_type: :temperature, value: 100.0}],
          max_ticks: 5
        })

      assert region.max_ticks == 5
      assert hd(region.source_points).value == 100.0
    end
  end

  describe "in_aabb?/2" do
    test "true inside, false outside (inclusive bounds)" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{1, 1, 1}, {3, 3, 3}}
        })

      assert FieldRegion.in_aabb?(region, {1, 1, 1})
      assert FieldRegion.in_aabb?(region, {3, 3, 3})
      assert FieldRegion.in_aabb?(region, {2, 2, 2})
      refute FieldRegion.in_aabb?(region, {0, 0, 0})
      refute FieldRegion.in_aabb?(region, {4, 4, 4})
      refute FieldRegion.in_aabb?(region, {2, 4, 2})
    end
  end

  describe "tick_limit_reached?/1" do
    test "nil max_ticks → never reached" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}}
        })

      refute FieldRegion.tick_limit_reached?(region)

      region = %{region | tick_count: 9_999_999}
      refute FieldRegion.tick_limit_reached?(region)
    end

    test "tick_count >= max_ticks → true" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}},
          max_ticks: 3
        })

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
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}},
          field_types: [:temperature]
        })

      new_layer = FieldLayer.put(FieldLayer.new(), 0, 42.0)
      region = FieldRegion.put_layer(region, :temperature, new_layer)

      assert FieldLayer.get(FieldRegion.get_layer(region, :temperature), 0) == 42.0
    end

    test "get_layer falls back to empty layer for missing field_type" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}},
          field_types: [:temperature]
        })

      layer = FieldRegion.get_layer(region, :ionization)
      assert match?(%FieldLayer{}, layer)
      assert FieldLayer.get(layer, 0) == 0.0
    end
  end

  describe "increment_tick/1" do
    test "increments tick_count by 1" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {0, 0, 0}}
        })

      assert region.tick_count == 0
      region = FieldRegion.increment_tick(region)
      assert region.tick_count == 1
      region = FieldRegion.increment_tick(region)
      assert region.tick_count == 2
    end
  end

  describe "aabb_cell_count/1" do
    test "computes inclusive volume" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 7, 7}}
        })

      assert FieldRegion.aabb_cell_count(region) == 8 * 8 * 8
    end
  end
end
