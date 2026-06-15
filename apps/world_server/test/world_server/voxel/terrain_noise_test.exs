defmodule WorldServer.Voxel.TerrainNoiseTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.TerrainNoise

  @opts [seed: 1337, min_height: 2, max_height: 14]

  test "heights stay within the clamped range" do
    for wx <- -40..40//7, wz <- -40..40//7 do
      h = TerrainNoise.height(wx, wz, @opts)
      assert h >= 2 and h <= 14, "height #{h} at (#{wx},#{wz}) out of range"
    end
  end

  test "is deterministic for the same coord and seed" do
    assert TerrainNoise.height(5, 9, @opts) == TerrainNoise.height(5, 9, @opts)
    assert TerrainNoise.height(-13, 22, @opts) == TerrainNoise.height(-13, 22, @opts)
  end

  test "produces relief (not a constant height across the region)" do
    heights =
      for wx <- -32..32, wz <- -32..32, into: MapSet.new() do
        TerrainNoise.height(wx, wz, @opts)
      end

    assert MapSet.size(heights) > 3, "expected varied terrain, got #{inspect(heights)}"
  end

  test "different seeds yield different terrain" do
    a = for wx <- 0..15, wz <- 0..15, do: TerrainNoise.height(wx, wz, seed: 1, max_height: 14)
    b = for wx <- 0..15, wz <- 0..15, do: TerrainNoise.height(wx, wz, seed: 2, max_height: 14)
    assert a != b
  end

  test "neighboring columns vary smoothly (value noise, not white noise)" do
    # Adjacent columns should rarely jump the full range at once.
    big_jumps =
      for wx <- 0..30, wz <- 0..30, reduce: 0 do
        acc ->
          if abs(TerrainNoise.height(wx, wz, @opts) - TerrainNoise.height(wx + 1, wz, @opts)) > 6,
            do: acc + 1,
            else: acc
      end

    assert big_jumps == 0, "value noise should not produce >6-macro single-step jumps"
  end
end
