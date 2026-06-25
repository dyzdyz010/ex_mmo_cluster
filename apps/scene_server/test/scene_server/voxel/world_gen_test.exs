defmodule SceneServer.Voxel.WorldGenTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types
  alias SceneServer.Voxel.WorldGen

  describe "column_height — layered deterministic noise" do
    test "is deterministic in (wx, wz, seed)" do
      assert WorldGen.column_height(1234, -5678) == WorldGen.column_height(1234, -5678)
      assert WorldGen.column_height(1234, -5678, seed: 9) == WorldGen.column_height(1234, -5678, seed: 9)
      # A different seed generally yields a different world.
      refute WorldGen.column_height(1234, -5678, seed: 1) ==
               WorldGen.column_height(1234, -5678, seed: 2)
    end

    test "stays within the configured [sea_level, max_height] band across a wide span" do
      heights =
        for wx <- 0..32_000//337, wz <- 0..32_000//331 do
          WorldGen.column_height(wx, wz)
        end

      assert Enum.min(heights) >= 64
      assert Enum.max(heights) <= 224
    end

    test "produces both meadows and mountains over a wide area, meadow-biased" do
      heights =
        for wx <- 0..16_000//173, wz <- 0..16_000//167 do
          WorldGen.column_height(wx, wz)
        end

      span = Enum.max(heights) - Enum.min(heights)
      # Real mountains exist somewhere (exponential shaper → sharp peaks).
      assert span > 60, "expected meadows + mountains, got span #{span}"

      # Most of the world is gentle meadow (the exponential shaper biases low).
      mid = Enum.min(heights) + (Enum.max(heights) - Enum.min(heights)) / 3
      below = Enum.count(heights, &(&1 < mid))
      assert below > length(heights) / 2, "expected meadow-biased terrain"

      # And a single column slice still has gentle relief (not a flat slab).
      slice = for wx <- 0..4000//40, do: WorldGen.column_height(wx, 0)
      assert Enum.max(slice) - Enum.min(slice) > 8
    end
  end

  describe "generate_chunk_storage" do
    defp solid_count(storage) do
      storage.macro_headers
      |> Enum.count(&(&1.mode == MacroCellHeader.cell_mode_solid_block()))
    end

    test "a deep underground chunk is fully solid stone" do
      storage = WorldGen.generate_chunk_storage(1, {0, -10, 0})
      assert solid_count(storage) == 4096
      # Bottom-corner macro is stone (well below the soil layer).
      header = Storage.macro_header_at(storage, Types.macro_index!({0, 0, 0}))
      assert header.mode == MacroCellHeader.cell_mode_solid_block()
      stone = MaterialCatalog.material_id(:stone)
      assert Enum.at(storage.normal_blocks, header.payload_index).material_id == stone
    end

    test "a high-altitude chunk is fully air" do
      storage = WorldGen.generate_chunk_storage(1, {0, 30, 0})
      assert solid_count(storage) == 0
      assert WorldGen.air_chunk?({0, 30, 0})
    end

    test "a surface chunk is partially filled with dirt over stone" do
      # cy=4 → world_y 64..79, straddling sea_level 64.
      storage = WorldGen.generate_chunk_storage(1, {0, 4, 0})
      n = solid_count(storage)
      assert n > 0 and n < 4096

      refute WorldGen.air_chunk?({0, 4, 0})
    end

    test "is deterministic — same chunk regenerates identically (version 0, regenerable base)" do
      a = WorldGen.generate_chunk_storage(1, {3, 4, -2})
      b = WorldGen.generate_chunk_storage(1, {3, 4, -2})
      assert a == b
      assert a.chunk_version == 0
    end

    test "generating a full chunk is fast (batched fill, < 50ms)" do
      {micros, storage} =
        :timer.tc(fn -> WorldGen.generate_chunk_storage(1, {100, -5, 200}) end)

      assert solid_count(storage) == 4096
      assert micros < 50_000, "chunk gen took #{div(micros, 1000)} ms"
    end
  end
end
