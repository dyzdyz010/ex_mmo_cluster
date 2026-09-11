defmodule VoxelRegion.StructurePublishedTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias VoxelRegion.{Prefab, Structure}

  @assets [
    stair: "a50dc77b6eef3f3f712198873f5de5396ea6679ee9fba506f6ac1d047327f668",
    wall: "663e89a683b961571f75849079ade4611c076286f05474d958d13ee3cee3bdf6",
    door: "08b02c1b3007008ff7fbdefacd304bb1dd77684d3ffba0ba17ebcd5c846e1197"
  ]

  @tag timeout: 300_000
  test "published stair wall doorway preserve whole L1 grids and geometric cover through L3 in 24 orientations" do
    anchors = [{0,0,0},{-17,-9,-1},{-18,-10,-2},{-19,-11,-3}]
    for {name,id} <- @assets, orientation <- 0..23, anchor <- anchors do
      footprint = Prefab.footprint(published(id),anchor,orientation)
      canonical = Map.new(footprint)
      levels = levels(footprint,3)
      context = inspect({name,orientation,anchor})
      for {cell,grid} <- levels[1] do
        {cx,cy,cz} = cell
        expected = for z <- 0..15,y <- 0..15,x <- 0..15,into: <<>> do
          m = Map.get(canonical,{cx*16+x,cy*16+y,cz*16+z},0)
          <<if(m == 0,do: 0,else: m ||| 256)::16-little>>
        end
        assert grid == expected, "L1 complete-grid mismatch #{context} cell=#{inspect(cell)}"
      end
      for level <- 1..3 do
        assert_cover(levels[level],footprint,level,context)
        if name == :door, do: assert_opening(levels[level],anchor,orientation,level,context)
      end
    end
    IO.puts("A3_PUBLISHED_ORACLE assets=3 orientations=24 anchors=4 scenarios=288 L1=whole_grid L1_L3=exact_geometric_cover")
  end

  @tag timeout: 300_000
  test "published doorway stays traversable in every L3 anchor residue including negative coordinates" do
    definition = published(@assets[:door])
    for orientation <- 0..23,dx <- 0..3,dy <- 0..3,dz <- 0..3 do
      anchor = {-16+dx,-16+dy,-16+dz}
      footprint = Prefab.footprint(definition,anchor,orientation)
      derived = levels(footprint,3)
      for level <- 1..3 do
        assert_cover(derived[level],footprint,level,inspect(anchor))
        assert_opening(derived[level],anchor,orientation,level,inspect({anchor,orientation}))
      end
    end
    IO.puts("A3_DOOR_RESIDUES production_cases=1536 orientations=24 residues_xyz=4x4x4 L1_L3=full_clear_aperture minimum_width=1m")
  end

  test "published doorway has a minimal aligned L4 closure and all offsets close at L5" do
    footprint = Prefab.footprint(published(@assets[:door]),{0,0,0},0)
    derived = levels(footprint,5)
    assert_cover(derived[4],footprint,4,"L4 aligned counterexample")
    assert_cover(derived[5],footprint,5,"L5 aligned counterexample")
    # L4 对齐门框的投影宽度只有两列，两列均被左右柱覆盖；整张框内平面无孔。
    occupied = occupied(derived[4])
    assert Enum.all?(for(x <- 0..1,y <- 0..2,do: {x,y,0}),&MapSet.member?(occupied,&1))
    # 几何条件独立于层级规约：洞宽12微格小于L5样本32微格，无法容纳一整列。
    for offset <- 0..31, do: assert(full_samples({offset+2,offset+14},32) == [])
    # L4 并非所有偏移都闭合：平移4微格后，中间有完整8微格空列。
    shifted = Prefab.footprint(published(@assets[:door]),{4,0,0},0) |> levels(4)
    assert_opening(shifted[4],{4,0,0},0,4,"L4 shifted aperture")
    IO.puts("A3_DOOR_COUNTEREXAMPLE L4_anchor=0,0,0 orientation=0 aperture_columns=0 L4_anchor_x4=open L5_all_width_residues=closed")
  end

  defp published(id) do
    root = System.get_env("A3_PUBLISHED") || Path.expand("../../../../Voxim/Content/Voxel/R7/Published",__DIR__)
    bytes = File.read!(Path.join(root,id<>".vxpd"))
    assert Base.encode16(:crypto.hash(:sha256,bytes),case: :lower) == id
    {:ok,cells} = Prefab.decode(bytes)
    cells
  end

  # 仅组合被测API，不实现规约规则。期望值下面直接来自原始几何投影。
  defp levels(footprint,max_level) do
    macros = Enum.reduce(footprint,%{},fn {cell,m},acc ->
      {macro,slot} = Prefab.macro_slot(cell)
      Map.update(acc,macro,%{slot=>{m,{1,0}}},&Map.put(&1,slot,{m,{1,0}}))
    end)
    {_,all} = Enum.reduce(1..max_level,{macros,%{}},fn level,{children,all} ->
      parents = children |> Map.keys() |> Enum.map(&divide(&1,2)) |> Enum.uniq()
      grids = Map.new(parents,fn {x,y,z}=parent ->
        inputs = for dz <- 0..1,dy <- 0..1,dx <- 0..1,do: Map.get(children,{x*2+dx,y*2+dy,z*2+dz},0)
        grid = if level == 1,do: Structure.from_canonical(inputs),else: Structure.reduce(inputs)
        {parent,grid}
      end)
      {grids,Map.put(all,level,grids)}
    end)
    all
  end

  defp divide({x,y,z},step), do: {Integer.floor_div(x,step),Integer.floor_div(y,step),Integer.floor_div(z,step)}

  defp occupied(grids) do
    for {{cx,cy,cz},grid} <- grids,
      {value,index} <- Enum.with_index(for(<<v::16-little <- grid>>,do: v)),value != 0,
      into: MapSet.new(),do: {cx*16+rem(index,16),cy*16+rem(div(index,16),16),cz*16+div(index,256)}
  end

  defp assert_cover(grids,footprint,level,context) do
    step = 1 <<< (level-1)
    expected = MapSet.new(footprint,fn {coord,_}->divide(coord,step) end)
    assert occupied(grids) == expected,"geometry cover mismatch L#{level} #{context}"
    materials = footprint |> Enum.map(&elem(&1,1)) |> Enum.uniq()
    for {_cell,grid} <- grids,<<v::16-little <- grid>>,v != 0 do
      assert (v &&& 256) != 0 and (v &&& 255) in materials
    end
  end

  defp full_samples({minimum,maximum},step) do
    first = -Integer.floor_div(-minimum,step)
    last = Integer.floor_div(maximum,step)-1
    if first > last,do: [],else: Enum.to_list(first..last)
  end

  defp assert_opening(grids,anchor,orientation,level,context) do
    # VXPD08b02的完整洞口是x=[2,14),y=[0,20),z=[0,2)；旋转沿用canonical体积变换。
    hole = for x <- 2..13,y <- 0..19,z <- 0..1,do: {{x,y,z},19}
    transformed = Prefab.footprint(hole,anchor,orientation) |> Enum.map(&elem(&1,0))
    bounds = for axis <- 0..2,do: {Enum.min_by(transformed,&elem(&1,axis)) |> elem(axis),(Enum.max_by(transformed,&elem(&1,axis)) |> elem(axis))+1}
    normal = Enum.find_index(bounds,fn {a,b}->b-a == 2 end)
    step = 1 <<< (level-1)
    ranges = bounds |> Enum.with_index() |> Enum.map(fn {{a,b},axis}->
      if axis == normal,do: Enum.to_list(Integer.floor_div(a,step)..Integer.floor_div(b-1,step)),else: full_samples({a,b},step)
    end)
    assert Enum.all?(ranges,&(&1 != [])),"closed aperture L#{level} #{context}"
    [xs,ys,zs] = ranges
    occupied = occupied(grids)
    assert Enum.all?(for(x <- xs,y <- ys,z <- zs,do: {x,y,z}),&(not MapSet.member?(occupied,&1))),"blocked clear aperture L#{level} #{context}"
    width_axis = Enum.find_index(bounds,fn {a,b}->b-a == 12 end)
    if level <= 3,do: assert(length(Enum.at(ranges,width_axis))*step >= 8,"opening narrower than 1m #{context}")
  end
end
