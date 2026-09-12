defmodule VoxelRegion.CollisionSource do
  @moduledoc "canonical 格到完整 chunk 占用的纯投影；载荷与 World 读取共用同一算法，不持有地形状态。"

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

  @doc "从完整 L0 载荷，或世界格读取器（coord → {terrain 材质, slot map}）投影相同 chunk 占用。"
  def capture(%Payload{level: 0} = payload, coord) do
    capture(coord,fn cell ->
      local = Payload.local(payload.region,cell)
      {Payload.material(payload,local),Map.get(payload.refined,Payload.cell_index(local),%{})}
    end)
  end

  def capture({cx, cy, cz} = coord, value_at) when is_function(value_at,1) do
    {ox, oy, oz} = {cx * @chunk_size, cy * @chunk_size, cz * @chunk_size}
    # 读取器只回答世界格的 {terrain 材质, 实际微格占用}；编辑不经过 wire 往返。
    {blocks,refined} = for z <- 0..(@chunk_size-1),y <- 0..(@chunk_size-1),x <- 0..(@chunk_size-1),reduce: {[],%{}} do
      {blocks,refined} ->
        {material,slots} = value_at.({ox+x,oy+y,oz+z})
        blocked = if VoxelMaterialCatalog.blocks_movement?(material),do: 1,else: 0
        refined = if map_size(slots) == 0,do: refined,else: Map.put(refined,{x,y,z},slots)
        {[<<blocked>>|blocks],refined}
    end
    blocks = blocks |> Enum.reverse() |> IO.iodata_to_binary()
    n = if map_size(refined) == 0, do: @chunk_size, else: @chunk_size*@micro
    sampling = if n == @chunk_size, do: 1, else: @micro
    # 普通格保留 16³；细化 chunk 先扩展阻挡行，再拼接实际微格。
    cells = if sampling == 1,do: blocks,else: (for z <- 0..(@chunk_size-1), into: <<>> do
      slab = for y <- 0..(@chunk_size-1), into: <<>> do
        row = for x <- 0..(@chunk_size-1), into: <<>> do
          blocked = :binary.at(blocks,x+@chunk_size*(y+@chunk_size*z))
          :binary.copy(<<blocked>>,sampling)
        end
        :binary.copy(row,sampling)
      end
      :binary.copy(slab,sampling)
    end)
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
