defmodule VoxelRegion.Spatial do
  # Compile the existing spatial owner, instead of declaring another chunk or metre scale.
  @spatial Path.expand("../../../../../Voxim/Source/Voxim/Voxel/VoxelSpatialConstants.h", __DIR__)
  @external_resource @spatial
  @spatial_text File.read!(@spatial)
  @chunk_size Regex.run(~r/VoxelChunkSizeInMacro\s*=\s*(\d+)/, @spatial_text)
              |> Enum.at(1)
              |> String.to_integer()
  @micro Regex.run(~r/VoxelMicroResolution\s*=\s*(\d+)/, @spatial_text) |> Enum.at(1) |> String.to_integer()
  def chunk_size, do: @chunk_size
  def micro_resolution, do: @micro
end
