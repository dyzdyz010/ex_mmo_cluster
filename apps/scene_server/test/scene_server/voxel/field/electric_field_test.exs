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
  alias SceneServer.Voxel.{NormalBlockData, Storage, Types}

  @iron 5
  @dirt 1

  describe "tick/2 with material-aware projection" do
    test "single source point spreads only through conductive material" do
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

      storage =
        Storage.new(7, {0, 0, 0})
        |> put_solid({0, 0, 0}, @iron)
        |> put_solid({1, 0, 0}, @iron)
        |> put_solid({0, 1, 0}, @dirt)
        |> put_solid({0, 0, 1}, @iron)

      region = ElectricField.tick(region, storage)

      potential_layer = FieldRegion.get_layer(region, :electric_potential)

      # The source cell holds the full value.
      assert_in_delta FieldLayer.get(potential_layer, Types.macro_index!({0, 0, 0})), 100.0, 0.001

      Enum.each([{1, 0, 0}, {0, 0, 1}], fn coord ->
        val = FieldLayer.get(potential_layer, Types.macro_index!(coord))
        assert val > 0.0, "expected positive potential at #{inspect(coord)}, got #{val}"
        assert val < 100.0
      end)

      assert FieldLayer.get(potential_layer, Types.macro_index!({0, 1, 0})) == 0.0
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

      storage =
        Enum.reduce(0..7, Storage.new(7, {0, 0, 0}), fn x, acc ->
          put_solid(acc, {x, 0, 0}, @iron)
        end)

      region = ElectricField.tick(region, storage)
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

      storage = Storage.new(7, {0, 0, 0}) |> put_solid({0, 0, 0}, @iron)
      region = ElectricField.tick(region, storage)
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

    test "nil storage does not invent conductive media" do
      source = Types.macro_index!({0, 0, 0})

      region =
        FieldRegion.new(%{
          region_id: 6,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {1, 0, 0}},
          kernels: [%{id: :electric_potential, module: ElectricPotentialKernel}],
          source_points: [
            %{macro_index: source, field_type: :electric_potential, value: 100.0}
          ]
        })

      region = ElectricField.tick(region, nil)
      assert active_cells(region, :electric_potential) == []
      assert active_cells(region, :ionization) == []
    end

    test "native backend matches the Elixir reference for potential and ionization" do
      region =
        FieldRegion.new(%{
          region_id: 5,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {5, 5, 0}},
          kernels: [%{id: :electric_potential, module: ElectricPotentialKernel}],
          source_points: [
            %{
              macro_index: Types.macro_index!({0, 0, 0}),
              field_type: :electric_potential,
              value: 100.0
            }
          ]
        })

      storage =
        for(x <- 0..5, y <- 0..5, do: {x, y, 0})
        |> Enum.reduce(Storage.new(7, {0, 0, 0}), fn coord, acc ->
          put_solid(acc, coord, @iron)
        end)

      native_region = ElectricField.tick(region, storage)
      elixir_region = ElectricField.tick(region, storage, electric_backend: :elixir)

      assert active_cells(native_region, :electric_potential) ==
               active_cells(elixir_region, :electric_potential)

      assert active_cells(native_region, :ionization) == active_cells(elixir_region, :ionization)
    end
  end

  defp active_cells(region, field_type) do
    region
    |> FieldRegion.get_layer(field_type)
    |> FieldLayer.active_cells(region.aabb, 0)
  end

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end
end
