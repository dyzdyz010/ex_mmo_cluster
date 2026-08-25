defmodule SceneServer.Voxel.WorldGenTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types
  alias SceneServer.Voxel.WorldGen

  @cave_chunk_coord {-2, -3, -8}
  @cave_chunk_hash "c3074cd53f9d98f1"
  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807

  describe "历史 column height helper" do
    test "同一世界坐标与 seed 的结果确定" do
      assert WorldGen.column_height(1234, -5678) == WorldGen.column_height(1234, -5678)

      assert WorldGen.column_height(1234, -5678, seed: 9) ==
               WorldGen.column_height(1234, -5678, seed: 9)

      refute WorldGen.column_height(1234, -5678, seed: 1) ==
               WorldGen.column_height(1234, -5678, seed: 2)
    end

    test "宽范围结果保持在高度带内" do
      heights =
        for wx <- 0..32_000//337, wz <- 0..32_000//331 do
          WorldGen.column_height(wx, wz)
        end

      assert Enum.min(heights) >= 0
      assert Enum.max(heights) <= 1600
    end

    test "宽范围同时包含盆地、低地和稀疏高山" do
      heights =
        for wx <- 0..32_000//101, wz <- 0..32_000//103 do
          WorldGen.column_height(wx, wz)
        end

      assert Enum.min(heights) < 64
      assert Enum.max(heights) > 500

      sorted = Enum.sort(heights)
      median = Enum.at(sorted, div(length(sorted), 2))
      assert median < 256

      slice = for wx <- 0..8000//40, do: WorldGen.column_height(wx, 0)
      assert Enum.max(slice) - Enum.min(slice) > 20
    end
  end

  describe "generate_chunk/3" do
    test "公开固定算法身份并生成 canonical XYZ 洞穴 fixture" do
      assert WorldGen.algorithm_version() == "worldgen_density_v2@1"

      assert {:ok, storage, observation} =
               WorldGen.generate_chunk(0, @cave_chunk_coord, seed: 1337)

      assert observation.algorithm_version == "worldgen_density_v2@1"
      assert observation.chunk_coord == @cave_chunk_coord
      assert observation.seed == 1337
      assert observation.total_cells == 4096
      assert observation.solid_cells == 4072
      assert observation.natural_air_cells == 0
      assert observation.cave_air_cells == 24
      assert observation.surface_cells == 0
      assert observation.subsurface_cells == 4072
      assert observation.generation_us >= 0

      assert observation.total_cells ==
               observation.natural_air_cells + observation.cave_air_cells +
                 observation.surface_cells + observation.subsurface_cells

      assert observation.solid_cells ==
               observation.surface_cells + observation.subsurface_cells

      assert solid_count(storage) == observation.solid_cells
      assert length(storage.normal_blocks) == observation.solid_cells

      # 固定洞穴单元同时钉住 x + y*16 + z*256 的 canonical 索引解释。
      assert material_at(storage, {14, 14, 0}) == :air
      assert material_at(storage, {13, 14, 0}) == MaterialCatalog.material_id(:stone)

      assert storage
             |> Codec.chunk_hash()
             |> Hash.encode64()
             |> Base.encode16(case: :lower) == @cave_chunk_hash
    end

    test "同一输入完全确定，不同 seed 改变 canonical truth" do
      assert {:ok, first, first_observation} =
               WorldGen.generate_chunk(7, @cave_chunk_coord, seed: 1337)

      assert {:ok, second, second_observation} =
               WorldGen.generate_chunk(7, @cave_chunk_coord, seed: 1337)

      assert first == second

      assert Map.delete(first_observation, :generation_us) ==
               Map.delete(second_observation, :generation_us)

      assert {:ok, changed_seed, changed_observation} =
               WorldGen.generate_chunk(7, @cave_chunk_coord, seed: 1338)

      refute Codec.chunk_hash(first) == Codec.chunk_hash(changed_seed)
      refute first_observation.cave_air_cells == changed_observation.cave_air_cells
    end

    test "洞穴垂直带以下保持 uniform subsurface" do
      assert {:ok, storage, observation} = WorldGen.generate_chunk(1, {0, -25, 0})

      assert observation.solid_cells == 4096
      assert observation.natural_air_cells == 0
      assert observation.cave_air_cells == 0
      assert observation.surface_cells == 0
      assert observation.subsurface_cells == 4096
      assert solid_count(storage) == 4096

      stone = MaterialCatalog.material_id(:stone)
      assert Enum.all?(storage.normal_blocks, &(&1.material_id == stone))
      refute WorldGen.air_chunk?({0, -25, 0})
    end

    test "表层 chunk 保持 dirt、保护层 stone 与自然空气分层" do
      assert WorldGen.column_height(0, 0) == 138
      assert {:ok, storage, observation} = WorldGen.generate_chunk(1, {0, 8, 0})

      assert observation.surface_cells > 0
      assert observation.subsurface_cells > 0
      assert observation.natural_air_cells > 0
      assert observation.cave_air_cells == 0
      assert material_at(storage, {0, 9, 0}) == MaterialCatalog.material_id(:dirt)
      assert material_at(storage, {0, 5, 0}) == MaterialCatalog.material_id(:stone)
      assert material_at(storage, {0, 10, 0}) == :air
      refute WorldGen.air_chunk?({0, 8, 0})
    end

    test "最大地形高度以上是精确全空气 chunk" do
      assert {:ok, storage, observation} = WorldGen.generate_chunk(1, {0, 110, 0})

      assert observation.solid_cells == 0
      assert observation.natural_air_cells == 4096
      assert observation.cave_air_cells == 0
      assert observation.surface_cells == 0
      assert observation.subsurface_cells == 0
      assert solid_count(storage) == 0
      assert WorldGen.air_chunk?({0, 110, 0})
    end

    test "接受 i64 seed 端点并显式拒绝非法配置与 canonical 坐标" do
      assert {:ok, _storage, %{seed: @i64_min}} =
               WorldGen.generate_chunk(0, {0, 110, 0}, seed: @i64_min)

      assert {:ok, _storage, %{seed: @i64_max}} =
               WorldGen.generate_chunk(0, {0, 110, 0}, seed: @i64_max)

      assert {:error, :invalid_logical_scene_id} = WorldGen.generate_chunk(-1, {0, 0, 0})

      assert {:error, :invalid_logical_scene_id} =
               WorldGen.generate_chunk(@i64_max + 1, {0, 0, 0})

      assert {:error, :invalid_chunk_coord} = WorldGen.generate_chunk(0, {0, 0})

      assert {:error, :worldgen_chunk_coord_out_of_range} =
               WorldGen.generate_chunk(0, {2_147_483_648, 0, 0})

      assert {:error, :invalid_worldgen_options} =
               WorldGen.generate_chunk(0, {0, 0, 0}, :invalid)

      assert {:error, :invalid_worldgen_options} =
               WorldGen.generate_chunk(0, {0, 0, 0}, [{:seed, 1}, :invalid])

      assert {:error, {:invalid_worldgen_option, :seed}} =
               WorldGen.generate_chunk(0, {0, 0, 0}, seed: @i64_max + 1)

      assert {:error, {:invalid_worldgen_option, :sea_level}} =
               WorldGen.generate_chunk(0, {0, 0, 0}, sea_level: -1)

      assert {:error, {:invalid_worldgen_option, :max_height}} =
               WorldGen.generate_chunk(0, {0, 0, 0}, max_height: 63)

      assert {:error, {:invalid_worldgen_option, :soil_depth}} =
               WorldGen.generate_chunk(0, {0, 0, 0}, soil_depth: 0)
    end

    test "Storage-only 兼容入口仍确定且失败不伪装成功" do
      first = WorldGen.generate_chunk_storage(1, @cave_chunk_coord)
      second = WorldGen.generate_chunk_storage(1, @cave_chunk_coord)

      assert first == second
      assert first.chunk_version == 0

      assert_raise ArgumentError, ~r/invalid_chunk_coord/, fn ->
        WorldGen.generate_chunk_storage(1, :invalid)
      end
    end
  end

  defp solid_count(storage) do
    Enum.count(storage.macro_headers, &(&1.mode == MacroCellHeader.cell_mode_solid_block()))
  end

  defp material_at(storage, local_coord) do
    header = Storage.macro_header_at(storage, Types.macro_index!(local_coord))

    if header.mode == MacroCellHeader.cell_mode_empty() do
      :air
    else
      Enum.at(storage.normal_blocks, header.payload_index).material_id
    end
  end
end
