defmodule SceneServer.Voxel.Field.ElectricFieldTest do
  # Phase 6 局部场最小目标:ElectricField (BFS 电势 + ionization) 单元测试。
  #
  # 覆盖:
  #   - 单势源 → 邻近 cell 获得非零 potential
  #   - 远离势源 cell 的 potential 比近处小
  #   - 高 potential cell 上 ionization 增长
  #   - 空 source_points → 无 potential 扩散
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{ElectricField, FieldLayer, FieldRegion}
  alias SceneServer.Voxel.Field.Kernels.ElectricPotentialKernel
  alias SceneServer.Voxel.Types

  describe "tick/2 with nil storage (uses default density)" do
    test "single source point → adjacent cells receive non-zero potential" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          kernels: [%{id: :electric_potential, module: ElectricPotentialKernel}],
          source_points: [
            %{
              macro_index: Types.macro_index!({0, 0, 0}),
              field_type: :electric_potential,
              value: 100.0
            }
          ]
        })

      region = ElectricField.tick(region, nil)

      potential_layer = FieldRegion.get_layer(region, :electric_potential)

      # The source cell holds the full value.
      assert_in_delta FieldLayer.get(potential_layer, Types.macro_index!({0, 0, 0})), 100.0, 0.001

      # Adjacent cells (Manhattan distance 1) must have positive potential
      # < source value.
      Enum.each(
        [
          {1, 0, 0},
          {0, 1, 0},
          {0, 0, 1}
        ],
        fn coord ->
          val = FieldLayer.get(potential_layer, Types.macro_index!(coord))
          assert val > 0.0, "expected positive potential at #{inspect(coord)}, got #{val}"
          assert val < 100.0
        end
      )
    end

    test "potential strictly decreases with distance from source" do
      region =
        FieldRegion.new(%{
          region_id: 2,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {7, 0, 0}},
          kernels: [%{id: :electric_potential, module: ElectricPotentialKernel}],
          source_points: [
            %{
              macro_index: Types.macro_index!({0, 0, 0}),
              field_type: :electric_potential,
              value: 50.0
            }
          ]
        })

      region = ElectricField.tick(region, nil)
      layer = FieldRegion.get_layer(region, :electric_potential)

      near = FieldLayer.get(layer, Types.macro_index!({1, 0, 0}))
      far = FieldLayer.get(layer, Types.macro_index!({5, 0, 0}))

      assert near > 0.0
      assert far >= 0.0

      assert near > far,
             "expected near (#{near}) to exceed far (#{far})"
    end

    test "ionization grows on cells with high potential" do
      # Use a value well above @ionization_threshold (= 50.0) so even after
      # one step of decay the potential at the source still exceeds threshold.
      region =
        FieldRegion.new(%{
          region_id: 3,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          kernels: [%{id: :electric_potential, module: ElectricPotentialKernel}],
          source_points: [
            %{
              macro_index: Types.macro_index!({0, 0, 0}),
              field_type: :electric_potential,
              value: 200.0
            }
          ]
        })

      region = ElectricField.tick(region, nil)
      ionization = FieldRegion.get_layer(region, :ionization)

      # Source cell potential = 200.0 → above threshold → ionization grows
      # from 0.0 by @ionization_growth (= 5.0).
      assert FieldLayer.get(ionization, Types.macro_index!({0, 0, 0})) > 0.0
    end

    test "empty source_points → no potential spreads anywhere" do
      region =
        FieldRegion.new(%{
          region_id: 4,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          kernels: [%{id: :electric_potential, module: ElectricPotentialKernel}]
        })

      region = ElectricField.tick(region, nil)
      layer = FieldRegion.get_layer(region, :electric_potential)

      for x <- 0..3, y <- 0..3, z <- 0..3 do
        assert FieldLayer.get(layer, Types.macro_index!({x, y, z})) == 0.0
      end
    end
  end
end
