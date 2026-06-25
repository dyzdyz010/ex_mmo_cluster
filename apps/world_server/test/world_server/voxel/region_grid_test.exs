defmodule WorldServer.Voxel.RegionGridTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias WorldServer.Voxel.RegionGrid

  describe "region_index/2 (floor division, negatives included)" do
    test "origin and positive chunks land in the expected region index" do
      grid = RegionGrid.new(8, 64, 8)
      assert RegionGrid.region_index(grid, {0, 0, 0}) == {0, 0, 0}
      assert RegionGrid.region_index(grid, {7, 63, 7}) == {0, 0, 0}
      assert RegionGrid.region_index(grid, {8, 64, 8}) == {1, 1, 1}
      assert RegionGrid.region_index(grid, {15, 0, 23}) == {1, 0, 2}
    end

    test "negative chunks floor toward -inf (no off-by-one across the origin)" do
      grid = RegionGrid.new(8, 64, 8)
      assert RegionGrid.region_index(grid, {-1, -1, -1}) == {-1, -1, -1}
      assert RegionGrid.region_index(grid, {-8, -64, -8}) == {-1, -1, -1}
      assert RegionGrid.region_index(grid, {-9, -65, -9}) == {-2, -2, -2}
    end
  end

  describe "bounds/2 (half-open AABB)" do
    test "bounds wrap exactly the chunks that map back to the index" do
      grid = RegionGrid.new(8, 64, 8)
      assert RegionGrid.bounds(grid, {0, 0, 0}) == {{0, 0, 0}, {8, 64, 8}}
      assert RegionGrid.bounds(grid, {-1, -1, -1}) == {{-8, -64, -8}, {0, 0, 0}}
      assert RegionGrid.bounds(grid, {2, 0, -1}) == {{16, 0, -8}, {24, 64, 0}}
    end

    test "every chunk in a region's bounds maps back to that region index" do
      grid = RegionGrid.new(8, 64, 8)

      for index <- [{0, 0, 0}, {-1, 0, 3}, {5, -2, -7}] do
        {{minx, miny, minz}, {maxx, maxy, maxz}} = RegionGrid.bounds(grid, index)

        for cx <- [minx, maxx - 1], cy <- [miny, maxy - 1], cz <- [minz, maxz - 1] do
          assert RegionGrid.region_index(grid, {cx, cy, cz}) == index
        end
      end
    end
  end

  describe "region_id/2 ↔ decode_region_id/1 (bijection)" do
    test "round-trips logical_scene_id + region index across sign and magnitude" do
      cases = [
        {1, {0, 0, 0}},
        {1, {-1, -1, -1}},
        {7, {32_767, 63, -32_768}},
        {16_777_215, {-32_768, -64, 32_767}},
        {987_650, {12_345, -7, -6_789}}
      ]

      for {ls, index} <- cases do
        rid = RegionGrid.region_id(ls, index)
        assert rid >= 0
        assert RegionGrid.decode_region_id(rid) == {ls, index}
      end
    end

    test "distinct logical scenes never collide on the same spatial region" do
      index = {3, 0, -4}
      a = RegionGrid.region_id(1, index)
      b = RegionGrid.region_id(2, index)
      refute a == b
      assert RegionGrid.decode_region_id(a) == {1, index}
      assert RegionGrid.decode_region_id(b) == {2, index}
    end

    test "region_id stays within signed bigint at the encoding extremes" do
      max_bigint = (1 <<< 63) - 1
      rid = RegionGrid.region_id(16_777_215, {32_767, 63, 32_767})
      assert rid >= 0
      assert rid <= max_bigint
    end

    test "raises rather than aliasing when a field exceeds its bit budget" do
      assert_raise ArgumentError, fn -> RegionGrid.region_id(16_777_216, {0, 0, 0}) end
      assert_raise ArgumentError, fn -> RegionGrid.region_id(1, {32_768, 0, 0}) end
      assert_raise ArgumentError, fn -> RegionGrid.region_id(1, {0, 64, 0}) end
      assert_raise ArgumentError, fn -> RegionGrid.region_id(1, {-32_769, 0, 0}) end
    end
  end

  describe "locate/3" do
    test "bundles index, globally-unique id, and bounds consistently" do
      grid = RegionGrid.new(8, 64, 8)
      located = RegionGrid.locate(grid, 1, {17, 5, -3})

      assert located.region_index == {2, 0, -1}
      assert located.region_id == RegionGrid.region_id(1, {2, 0, -1})
      assert located.bounds_chunk_min == {16, 0, -8}
      assert located.bounds_chunk_max == {24, 64, 0}

      # The id round-trips and the bounds contain the original chunk.
      assert RegionGrid.decode_region_id(located.region_id) == {1, {2, 0, -1}}
      {{minx, miny, minz}, {maxx, maxy, maxz}} =
        {located.bounds_chunk_min, located.bounds_chunk_max}

      assert minx <= 17 and 17 < maxx
      assert miny <= 5 and 5 < maxy
      assert minz <= -3 and -3 < maxz
    end
  end
end
