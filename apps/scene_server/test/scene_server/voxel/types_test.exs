defmodule SceneServer.Voxel.TypesTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.AabbI64
  alias SceneServer.Voxel.Types

  test "normalizes chunk coords and half-open AABB boundaries" do
    assert Types.normalize_chunk_coord!([1, -2, 3]) == {1, -2, 3}
    assert Types.normalize_chunk_coord!(%{cx: -1, cy: 0, cz: 2}) == {-1, 0, 2}

    assert_raise ArgumentError, fn ->
      Types.normalize_chunk_coord!({2_147_483_648, 0, 0})
    end

    aabb = Types.normalize_aabb_i64!(%{min_world_micro: {0, 0, 0}, max_world_micro: {8, 8, 8}})

    assert %AabbI64{} = aabb
    assert Types.aabb_contains?(aabb, {0, 0, 0})
    assert Types.aabb_contains?(aabb, {7, 7, 7})
    refute Types.aabb_contains?(aabb, {8, 7, 7})
    refute Types.aabb_contains?(aabb, {7, 8, 7})
    refute Types.aabb_contains?(aabb, {7, 7, 8})

    assert_raise ArgumentError, fn ->
      Types.normalize_aabb_i64!({{1, 0, 0}, {0, 1, 1}})
    end
  end

  test "uses floor division and Euclidean local coordinates for negative world macro positions" do
    assert Types.chunk_and_local_macro!({-1, -16, -17}) == {{-1, -1, -2}, {15, 0, 15}}
    assert Types.chunk_and_local_macro!({0, 15, 16}) == {{0, 0, 1}, {0, 15, 0}}
  end

  test "normalizes macro and micro index boundaries" do
    assert Types.macro_index!({0, 0, 0}) == 0
    assert Types.macro_index!({15, 15, 15}) == 4095
    assert Types.macro_coord!(0) == {0, 0, 0}
    assert Types.macro_coord!(4095) == {15, 15, 15}

    assert_raise ArgumentError, fn -> Types.macro_index!({16, 0, 0}) end
    assert_raise ArgumentError, fn -> Types.macro_coord!(4096) end

    assert Types.micro_index!({0, 0, 0}) == 0
    assert Types.micro_index!({7, 7, 7}) == 511
    assert Types.micro_coord!(511) == {7, 7, 7}

    assert_raise ArgumentError, fn -> Types.micro_index!({8, 0, 0}) end
    assert_raise ArgumentError, fn -> Types.micro_coord!(512) end
  end
end
