defmodule VoxelRegion.ThermalGeometryTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.{ThermalGeometry,Prefab,ThermalNative}
  @materials %{19=>%{"heat_capacity_per_macro"=>1000.0,"thermal_conductivity"=>1000.0,"heat_resistance_kelvin"=>1000.0}}

  test "有限高度只接触实际底面和低侧壁；容量与法向半程由同一体积派生" do
    cells=[{0,0,0},{0,-1,0},{0,1,0},{1,0,0}]
    at=fn p,s ->
      {cell,_}=Prefab.macro_slot(p)
      t=if cell in cells,do: %{granularity: 0,micro: cell |> Tuple.to_list() |> Enum.map(&(&1*8)) |> List.to_tuple(),
        owner: {0,0},incarnation: 1,material: 19}
      {t,s}
    end
    volume=fn _,t -> if t.micro=={0,0,0},do: 1/512,else: 1.0 end
    nodes=Map.new(Enum.flat_map(cells,fn c->elem(ThermalGeometry.cell(c,%{},@materials,nil,at,volume),0) end))
    water=nodes[{0,{0,0,0}}]
    assert_in_delta water.capacity,1000/512,1.0e-12
    assert_in_delta water.exposed_faces,1+3/512,1.0e-12
    assert_in_delta elem(List.keyfind(water.contacts,{0,{0,-8,0}},0),1),1/(1/1024/1000+0.5/1000),1.0e-9
    assert_in_delta elem(List.keyfind(water.contacts,{0,{8,0,0}},0),1),(1/512)/(0.5/1000+0.5/1000),1.0e-9
    refute List.keymember?(water.contacts,{0,{0,8,0}},0)
    # A microcell above the thin free surface has no side contact.
    refined=%{{1,0,0}=>%{8=>{19,{1,0}}}}
    fine_at=fn p,s ->
      case Prefab.macro_slot(p) do
        {{1,0,0},8}->{%{granularity: 2,micro: p,owner: {1,0},incarnation: 1,material: 19},s}
        {{1,0,0},_}->{nil,s}
        _->at.(p,s)
      end
    end
    {thin,_}=ThermalGeometry.cell({0,0,0},refined,@materials,nil,fine_at,volume)
    refute Enum.any?(elem(hd(thin),1).contacts,fn {{g,_},_}->g==1 end)
  end

  test "部分接触按真实面积，微格热容量按实际体积，跨区不改变几何" do
    macro={63,0,0}
    fine={64,0,0}
    refined=%{fine=>%{0=>{19,{1,0}}}}
    at=fn micro,s ->
      {cell,slot}=Prefab.macro_slot(micro)
      t=cond do
        cell==macro -> %{granularity: 0,micro: {504,0,0},owner: {0,0},incarnation: 1,material: 19}
        cell==fine and slot==0 -> %{granularity: 2,micro: micro,owner: {1,0},incarnation: 1,material: 19}
        true -> nil
      end
      {t,s}
    end
    {a,_}=ThermalGeometry.cell(macro,refined,@materials,nil,at)
    {b,_}=ThermalGeometry.cell(fine,refined,@materials,nil,at)
    nodes=Map.new(a++b)
    assert nodes[{0,{504,0,0}}].capacity==1000.0
    assert nodes[{1,{512,0,0}}].capacity==1000.0/512
    assert nodes[{0,{504,0,0}}].exposed_faces==6.0-1.0/64
    assert nodes[{1,{512,0,0}}].exposed_faces==5.0/64
    assert [{_,_,g}]=ThermalGeometry.contacts(nodes)
    assert_in_delta g,(1.0/64)/(0.5/1000+0.0625/1000),1.0e-12
  end

  test "极小体积自动缩短步长：守恒且不超调，不同采样预算收敛" do
    input=[{400.0,1.0,1.0,1000.0/512,1000.0,1000.0,0.0,0.0,0.0,true},
           {300.0,1.0,1.0,1000.0/512,1000.0,1000.0,0.0,0.0,0.0,true}]
    {0.5,rows,0.0,0.0}=ThermalNative.advance(input,[{0,1,125.0}],293.15,0.0,0.01,0.5)
    for {t,_,_}<-rows,do: assert(t>=300.0 and t<=400.0)
    assert_in_delta Enum.sum(Enum.map(rows,&elem(&1,0))),700.0,1.0e-9
    assert_in_delta elem(hd(rows),0),350.0,1.0e-6
    small=Enum.reduce(1..100,input,fn _,nodes->
      {_,next,_,_}=ThermalNative.advance(nodes,[{0,1,125.0}],293.15,0.0,0.01,0.005)
      Enum.zip_with(nodes,next,fn n,{t,hp,left}->n |> put_elem(0,t) |> put_elem(1,hp) |> put_elem(8,left) end)
    end)
    assert_in_delta elem(hd(small),0),elem(hd(rows),0),1.0e-6
  end
end
