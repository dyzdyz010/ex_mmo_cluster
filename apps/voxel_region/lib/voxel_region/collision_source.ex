defmodule VoxelRegion.CollisionSource do
  @moduledoc "Pure core occupancy projection of the canonical R6 payload; no terrain state."

  alias MmoContracts.Voxel.{ChunkOccupancy, Payload}
  alias MmoContracts.VoxelMaterialCatalog

  # Compile the existing spatial owner, instead of declaring another chunk or metre scale.
  @spatial Path.expand("../../../../../Voxim/Source/Voxim/Voxel/VoxelSpatialConstants.h", __DIR__)
  @external_resource @spatial
  @spatial_text File.read!(@spatial)
  @chunk_size Regex.run(~r/VoxelChunkSizeInMacro\s*=\s*(\d+)/, @spatial_text)
              |> Enum.at(1)
              |> String.to_integer()
  @region_size Payload.extent() - 2

  def regions({{x0, y0, z0}, {x1, y1, z1}}) do
    for x <- x0..(x1 - 1), y <- y0..(y1 - 1), z <- z0..(z1 - 1), do: {x, y, z}
  end

  def chunk_coord({x, y, z}) do
    {Integer.floor_div(x, @chunk_size), Integer.floor_div(y, @chunk_size),
     Integer.floor_div(z, @chunk_size)}
  end

  def region_coord({x, y, z}) do
    n = div(@region_size, @chunk_size)
    {Integer.floor_div(x, n), Integer.floor_div(y, n), Integer.floor_div(z, n)}
  end

  def in_box?(coord, {{x0, y0, z0}, {x1, y1, z1}}) do
    {x, y, z} = region_coord(coord)
    x >= x0 and x < x1 and y >= y0 and y < y1 and z >= z0 and z < z1
  end

  def chunk_coords({rx, ry, rz}) do
    n = div(@region_size, @chunk_size)

    for x <- 0..(n - 1),
        y <- 0..(n - 1),
        z <- 0..(n - 1),
        do: {rx * n + x, ry * n + y, rz * n + z}
  end

  def capture(%Payload{level: 0} = payload, {cx, cy, cz} = coord) do
    {ox, oy, oz} = {cx * @chunk_size, cy * @chunk_size, cz * @chunk_size}

    cells =
      for z <- 0..(@chunk_size - 1),
          y <- 0..(@chunk_size - 1),
          x <- 0..(@chunk_size - 1),
          into: <<>> do
        material =
          Payload.material(payload, Payload.local(payload.region, {ox + x, oy + y, oz + z}))

        <<if(VoxelMaterialCatalog.blocks_movement?(material), do: 1, else: 0)>>
      end

    %ChunkOccupancy{
      coord: coord,
      n: @chunk_size,
      scale_m: 1.0,
      origin_m: {ox * 1.0, oy * 1.0, oz * 1.0},
      cells: cells
    }
  end
end
