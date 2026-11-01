defmodule VoxelRegion.Spatial do
  # Compile the existing spatial owner, instead of declaring another chunk or metre scale.
  @spatial Path.expand("../../../../../Voxim/Source/Voxim/Voxel/VoxelSpatialConstants.h", __DIR__)
  @external_resource @spatial
  @spatial_text File.read!(@spatial)
  @chunk_size Regex.run(~r/VoxelChunkSizeInMacro\s*=\s*(\d+)/, @spatial_text)
              |> Enum.at(1)
              |> String.to_integer()
  @micro Regex.run(~r/VoxelMicroResolution\s*=\s*(\d+)/, @spatial_text)
         |> Enum.at(1)
         |> String.to_integer()
  def chunk_size, do: @chunk_size
  def micro_resolution, do: @micro

  # region（页）是 64³ 宏格的 core；载荷另带 1 格邻环，边长 66（`MmoContracts.Voxel.Payload.extent/0`）。
  @region_size MmoContracts.Voxel.Payload.extent() - 2

  @doc "一个 region 每边的宏格数（不含邻环）。"
  def region_size, do: @region_size

  @doc "最粗的层级：L0 逐宏格，Lk 每格覆盖 2^k 宏格，到 L5 为止。"
  def max_level, do: 5

  @doc "宏格（或某层级的格）所在的 region。"
  def region_of({x, y, z}),
    do:
      {Integer.floor_div(x, @region_size), Integer.floor_div(y, @region_size),
       Integer.floor_div(z, @region_size)}
end
