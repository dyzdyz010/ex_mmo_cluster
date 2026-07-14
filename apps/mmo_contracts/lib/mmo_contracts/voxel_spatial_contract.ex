defmodule MmoContracts.VoxelSpatialContract do
  @moduledoc """
  完整 XYZ 体素窗口与 full32km world-pack 的共享空间契约。

  tile identity、近场 chunk 立方体和 world-pack Y 边界必须共同演进，
  避免客户端窗口已经覆盖 tile 下方而服务端 baseline 仍从旧的有限 Y
  起点开始。这里仅提供不可变空间常量与纯坐标换算，不承载运行时状态。
  """

  @tile_size_chunks 7
  @near_tile_radius 1
  @near_chunk_radius @tile_size_chunks * @near_tile_radius + div(@tile_size_chunks, 2)
  @default_near_center_chunk {3, 3, 3}
  @full32km_chunk_min {-1024, -7, -1024}
  @full32km_chunk_max {1023, 98, 1023}
  @full32km_shard_chunk_shape {16, 106, 16}

  @type chunk_coord :: {integer(), integer(), integer()}

  @doc "返回 production tile 的单轴 chunk 数。"
  @spec tile_size_chunks() :: pos_integer()
  def tile_size_chunks, do: @tile_size_chunks

  @doc "返回默认近场的 tile L-infinity 半径。"
  @spec near_tile_radius() :: non_neg_integer()
  def near_tile_radius, do: @near_tile_radius

  @doc "返回 tile-center 表示下默认近场的 chunk L-infinity 半径。"
  @spec near_chunk_radius() :: non_neg_integer()
  def near_chunk_radius, do: @near_chunk_radius

  @doc "返回默认近场的 XYZ chunk 形状。"
  @spec near_chunk_shape() :: {pos_integer(), pos_integer(), pos_integer()}
  def near_chunk_shape do
    edge = @near_chunk_radius * 2 + 1
    {edge, edge, edge}
  end

  @doc "返回默认完整 XYZ 近场的 chunk 总数。"
  @spec near_chunk_count() :: pos_integer()
  def near_chunk_count do
    {x, y, z} = near_chunk_shape()
    x * y * z
  end

  @doc "把 canonical tile XYZ 换算为该 tile 的中心 chunk XYZ。"
  @spec tile_center_chunk(chunk_coord()) :: chunk_coord()
  def tile_center_chunk({tile_x, tile_y, tile_z})
      when is_integer(tile_x) and is_integer(tile_y) and is_integer(tile_z) do
    half = div(@tile_size_chunks, 2)

    {
      tile_x * @tile_size_chunks + half,
      tile_y * @tile_size_chunks + half,
      tile_z * @tile_size_chunks + half
    }
  end

  @doc "返回 tile `(0,0,0)` 对应的默认近场中心 chunk。"
  @spec default_near_center_chunk() :: chunk_coord()
  def default_near_center_chunk, do: @default_near_center_chunk

  @doc "返回给定 tile-center chunk 的默认近场闭区间边界。"
  @spec near_window_bounds(chunk_coord()) :: {chunk_coord(), chunk_coord()}
  def near_window_bounds({center_x, center_y, center_z})
      when is_integer(center_x) and is_integer(center_y) and is_integer(center_z) do
    radius = @near_chunk_radius

    {
      {center_x - radius, center_y - radius, center_z - radius},
      {center_x + radius, center_y + radius, center_z + radius}
    }
  end

  @doc "返回 full32km pack 的 canonical XYZ 最小 chunk。"
  @spec full32km_chunk_min() :: chunk_coord()
  def full32km_chunk_min, do: @full32km_chunk_min

  @doc "返回 full32km pack 的 canonical XYZ 最大 chunk。"
  @spec full32km_chunk_max() :: chunk_coord()
  def full32km_chunk_max, do: @full32km_chunk_max

  @doc "返回 full32km `.vxpack` 的 XYZ shard chunk 形状。"
  @spec full32km_shard_chunk_shape() :: chunk_coord()
  def full32km_shard_chunk_shape, do: @full32km_shard_chunk_shape
end
