defmodule VoxelRegion.CollisionSource do
  @moduledoc "Pure core occupancy projection of the canonical R6 payload; no terrain state."

  alias MmoContracts.Voxel.{ChunkOccupancy, Payload}
  alias MmoContracts.VoxelMaterialCatalog

  @chunk_size VoxelRegion.Spatial.chunk_size()
  @micro VoxelRegion.Spatial.micro_resolution()
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

    refined = for {index, slots} <- payload.refined,
      local = {rem(index,66),rem(div(index,66),66),div(index,66*66)},
      {px,py,pz} = Payload.origin(payload.region),
      {x,y,z} = local,
      wx = px+x, wy = py+y, wz = pz+z,
      wx >= ox and wx < ox+@chunk_size and wy >= oy and wy < oy+@chunk_size and wz >= oz and wz < oz+@chunk_size,
      into: %{}, do: {{wx-ox,wy-oy,wz-oz},slots}
    n = if map_size(refined) == 0, do: @chunk_size, else: @chunk_size*@micro
    sampling = if n == @chunk_size, do: 1, else: @micro
    # Preserve the 16-grid path. Refined chunks expand the blocking rows once, then splice actual slots.
    cells = for z <- 0..(@chunk_size-1), into: <<>> do
      slab = for y <- 0..(@chunk_size-1), into: <<>> do
        row = for x <- 0..(@chunk_size-1), into: <<>> do
          material = Payload.material(payload,Payload.local(payload.region,{ox+x,oy+y,oz+z}))
          blocked = if VoxelMaterialCatalog.blocks_movement?(material),do: 1,else: 0
          :binary.copy(<<blocked>>,sampling)
        end
        :binary.copy(row,sampling)
      end
      :binary.copy(slab,sampling)
    end
    updates = for {{mx,my,mz},slots} <- refined, {slot,{material,_}} <- slots do
      x = mx*@micro+rem(slot,@micro)
      y = my*@micro+rem(div(slot,@micro),@micro)
      z = mz*@micro+div(slot,@micro*@micro)
      {x+n*(y+n*z),if(VoxelMaterialCatalog.blocks_movement?(material),do: 1,else: 0)}
    end
    {parts,pos} = Enum.reduce(Enum.sort(updates),{[],0},fn {index,value},{parts,pos} ->
      {[<<value>>,binary_part(cells,pos,index-pos)|parts],index+1}
    end)
    cells = IO.iodata_to_binary(Enum.reverse([binary_part(cells,pos,byte_size(cells)-pos)|parts]))

    %ChunkOccupancy{
      coord: coord,
      n: n,
      scale_m: 1.0/sampling,
      origin_m: {ox * 1.0, oy * 1.0, oz * 1.0},
      cells: cells
    }
  end
end
