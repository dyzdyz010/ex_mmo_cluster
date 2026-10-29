defmodule VoxelRegion.CollisionSource do
  @moduledoc "canonical 格到完整 chunk 占用的纯投影；载荷与 World 读取共用同一算法，不持有地形状态。"

  alias MmoContracts.Voxel.{ChunkOccupancy, Payload}
  alias MmoContracts.VoxelMaterialCatalog

  @chunk_size VoxelRegion.Spatial.chunk_size()
  @micro VoxelRegion.Spatial.micro_resolution()
  @region_size Payload.extent() - 2

  # 全局系统功能：由唯一材质目录编译密集阻挡投影，高频循环直接索引，无逐格远程查询。
  @blocking VoxelMaterialCatalog.table()
            |> Enum.map(fn %{"id" => id} ->
              if VoxelMaterialCatalog.blocks_movement?(id), do: 1, else: 0
            end)
            |> List.to_tuple()
  @compile {:inline, blocked: 1}
  defp blocked(material), do: elem(@blocking, material)

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

  @doc "窗口快照的碰撞 chunk：逐区域解码 L0 载荷字节并投影其全部 chunk，按坐标排序。"
  def snapshot_chunks(regions, capacity) do
    regions
    |> Enum.flat_map(fn {coord, bytes} ->
      {:ok, payload} = Payload.decode(bytes)
      Enum.map(chunk_coords(coord), &capture(payload, &1, capacity))
    end)
    |> Enum.sort_by(& &1.coord)
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

  @doc "将有限宏格数量投影为向上取整的微格阻挡层，原细化槽覆盖对应位置。"
  # 派生碰撞层最多向上多覆盖不足 1/8m；实际显示高度仍为 quantity/capacity。
  # 有数量记录的实体宏格（相态固体、熔岩与 R8-07 散体）都按同一规则取整；水不挡移动，不投影。
  def phase_slots(material, slots, quantity, capacity) when material not in [0,21] and is_integer(quantity) and quantity < capacity do
    layers=div(quantity*@micro+capacity-1,capacity)
    Map.new(0..(@micro*@micro*@micro-1),fn slot ->
      {slot,{if(rem(div(slot,@micro),@micro)<layers,do: material,else: 0),{0,0}}}
    end) |> then(&Enum.into(slots, &1))
  end
  def phase_slots(_material,slots,_quantity,_capacity),do: slots

  @doc "从完整 L0 载荷或世界格读取器投影相同完整 chunk 占用。"
  def capture(payload, coord, capacity \\ 0)
  def capture(%Payload{level: 0, refined: refined, liquid_units: quantities} = payload, {cx,cy,cz}=coord, _capacity) when map_size(refined)==0 and map_size(quantities)==0 do
    # 普通载荷按连续行读取，避免每格重复坐标换算、函数调用和空微格表查询。
    # 材质阻挡仍由同一个目录定义；细化载荷继续使用下面的微格投影。
    {lx,ly,lz}=Payload.local(payload.region,{cx*@chunk_size,cy*@chunk_size,cz*@chunk_size})
    cells=for z<-0..(@chunk_size-1),y<-0..(@chunk_size-1),into: <<>> do
      row=binary_part(payload.cells,2*Payload.cell_index({lx,ly+y,lz+z}),2*@chunk_size)
      for <<material::little-16 <- row>>,into: <<>>,
        do: <<blocked(material)>>
    end
    %ChunkOccupancy{coord: coord,n: @chunk_size,scale_m: 1.0,
      origin_m: {cx*@chunk_size*1.0,cy*@chunk_size*1.0,cz*@chunk_size*1.0},cells: cells}
  end

  def capture(%Payload{level: 0} = payload, coord, capacity) do
    capture(coord,fn cell ->
      local = Payload.local(payload.region,cell)
      material=Payload.material(payload,local)
      index=Payload.cell_index(local)
      {material,phase_slots(material,Map.get(payload.refined,index,%{}),Map.get(payload.liquid_units,index),capacity)}
    end)
  end

  def capture(coord, value_at, _capacity) when is_function(value_at, 1) do
    {blocks, refined} = prepare_chunk(coord, value_at)
    capture_prepared(coord, blocks, refined)
  end

  @doc """
  提交已给出此 chunk 的完整、不重复变化宏格集合；仅实际占用或分辨率变化时构造 new。

  未列出的宏格由提交 owner 保证相同，旧侧只读取变化宏格。判定与完整捕获共用实际占用投影，
  不能用材质／owner／原槽表结构是否相等替代阻挡位相等。所有计数仅为本次输入的派生值。
  """
  def capture_changed({cx, cy, cz} = coord, before_at, after_at, changed_cells) do
    {blocks, refined} = prepare_chunk(coord, after_at)
    old_count =
      Enum.reduce_while(changed_cells, map_size(refined), fn {x, y, z} = cell, count ->
        local = {x - cx * @chunk_size, y - cy * @chunk_size, z - cz * @chunk_size}
        {lx, ly, lz} = local
        new_block = :binary.at(blocks, lx + @chunk_size * (ly + @chunk_size * lz))
        new_slots = Map.get(refined, local, %{})
        {old_material, old_slots} = before_at.(cell)
        old_refined = Enum.count(old_slots) > 0
        new_refined = Enum.count(new_slots) > 0

        if macro_cells(blocked(old_material), old_slots) == macro_cells(new_block, new_slots) do
          {:cont, count + if(old_refined, do: 1, else: 0) - if(new_refined, do: 1, else: 0)}
        else
          {:halt, :changed}
        end
      end)

    # 局部阻挡相等仍不能忽略首个／最后一个非空槽引起的 16³ ↔ 128³ 输出变化。
    if old_count == :changed or (old_count == 0) != (map_size(refined) == 0),
      do: capture_prepared(coord, blocks, refined), else: nil
  end

  defp prepare_chunk({cx, cy, cz}, value_at) do
    {ox, oy, oz} = {cx * @chunk_size, cy * @chunk_size, cz * @chunk_size}
    # 读取器只回答世界格的 {terrain 材质, 实际微格占用}；编辑不经过 wire 往返。
    {blocks,refined} = for z <- 0..(@chunk_size-1),y <- 0..(@chunk_size-1),x <- 0..(@chunk_size-1),reduce: {[],%{}} do
      {blocks,refined} ->
        {material,slots} = value_at.({ox+x,oy+y,oz+z})
        blocked = blocked(material)
        # 普通 map 与紧凑槽均提供常数时间计数；判空不提前解码首槽。
        refined = if Enum.count(slots) == 0, do: refined, else: Map.put(refined, {x, y, z}, slots)
        {[<<blocked>>|blocks],refined}
    end
    {blocks |> Enum.reverse() |> IO.iodata_to_binary(), refined}
  end

  defp capture_prepared({cx, cy, cz} = coord, blocks, refined) do
    n = if map_size(refined) == 0, do: @chunk_size, else: @chunk_size*@micro
    sampling = if n == @chunk_size, do: 1, else: @micro
    %ChunkOccupancy{
      coord: coord,
      n: n,
      scale_m: 1.0/sampling,
      origin_m: {cx * @chunk_size * 1.0, cy * @chunk_size * 1.0, cz * @chunk_size * 1.0},
      cells: occupancy_cells(blocks, refined, @chunk_size, sampling)
    }
  end

  defp macro_cells(block, slots) do
    occupancy_cells(<<block>>, %{{0, 0, 0} => slots}, 1, @micro)
  end

  # 完整 chunk 与单宏格比较共用此投影；只改变自然输入尺寸，不另定义材料或覆盖规则。
  defp occupancy_cells(blocks, refined, extent, sampling) do
    n = extent * sampling
    cells = if sampling == 1,do: blocks,else: (for z <- 0..(extent-1), into: <<>> do
      slab = for y <- 0..(extent-1), into: <<>> do
        row = for x <- 0..(extent-1), into: <<>> do
          blocked = :binary.at(blocks,x+extent*(y+extent*z))
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
      {x+n*(y+n*z),blocked(material)}
    end
    {parts,pos} = Enum.reduce(Enum.sort(updates),{[],0},fn {index,value},{parts,pos} ->
      {[<<value>>,binary_part(cells,pos,index-pos)|parts],index+1}
    end)
    IO.iodata_to_binary(Enum.reverse([binary_part(cells,pos,byte_size(cells)-pos)|parts]))
  end
end
