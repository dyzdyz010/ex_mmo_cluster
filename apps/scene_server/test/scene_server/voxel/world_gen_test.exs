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

    test "stays within the [0, max_height] band across a wide span" do
      heights =
        for wx <- 0..32_000//337, wz <- 0..32_000//331 do
          WorldGen.column_height(wx, wz)
        end

      assert Enum.min(heights) >= 0
      assert Enum.max(heights) <= 1600
    end

    test "produces lowland basins + rare tall mountains over a wide area" do
      heights =
        for wx <- 0..32_000//101, wz <- 0..32_000//103 do
          WorldGen.column_height(wx, wz)
        end

      # Basins/valleys dip below sea level (lowland is centred on it).
      assert Enum.min(heights) < 64, "expected basins below sea level"

      # Real mountains tower well above the lowland band somewhere.
      assert Enum.max(heights) > 500, "expected tall mountains, got max #{Enum.max(heights)}"

      # Most of the world is lowland (mountains are gated to a few regions), so the
      # median sits in the lowland band, far below the peaks.
      sorted = Enum.sort(heights)
      median = Enum.at(sorted, div(length(sorted), 2))
      assert median < 256, "expected lowland-biased terrain, median #{median}"

      # A single column slice still has real relief (not a flat slab).
      slice = for wx <- 0..8000//40, do: WorldGen.column_height(wx, 0)
      assert Enum.max(slice) - Enum.min(slice) > 20
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

    test "a chunk above the max terrain height is fully air" do
      # Chunk floor (110*16 = 1760) is above @max_height (1600) → air everywhere,
      # regardless of where the mountains are.
      assert WorldGen.air_chunk?({0, 110, 0})
      storage = WorldGen.generate_chunk_storage(1, {0, 110, 0})
      assert solid_count(storage) == 0
    end

    test "a surface chunk is partially filled with dirt over stone" do
      # The chunk layer straddling the terrain top at column (0,0) is partial:
      # that column's surface falls inside it, so it has solid below + air above.
      surface_y = WorldGen.column_height(0, 0)
      cy = div(surface_y, Types.chunk_size_in_macro())
      storage = WorldGen.generate_chunk_storage(1, {0, cy, 0})
      n = solid_count(storage)
      assert n > 0 and n < 4096

      refute WorldGen.air_chunk?({0, cy, 0})
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
