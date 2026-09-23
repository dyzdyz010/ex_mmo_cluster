defmodule VoxelRegion.ThermalAttachmentsTest do
  @moduledoc "只测试：附件热容量、接触与能量守恒。"
  use ExUnit.Case, async: true
  alias VoxelRegion.{ThermalAttachments, ThermalGeometry, ThermalNative}
  @catalog %{materials: %{19 => %{"heat_capacity_per_macro" => 1000.0,
    "thermal_conductivity" => 10.0,"heat_resistance_kelvin" => 1000.0}},
    attachments: %{"material_units_per_micro" => 4096,"face_units" => 64,"edge_units" => 1,
      "face_thickness_m" => 1/512,"line_section_m2" => 1/(512*512)}}

  test "同次重建冻结唯一宿主点；下一次重建使用新的占用和相态体积" do
    slots=%{{0,1,{0,0,0}}=>{1,19},{1,0,{0,0,0}}=>{2,19},
      {0,0,{0,0,0}}=>{3,19}}
    host=%{micro: {0,0,0},granularity: 0,incarnation: 1,owner: {0,0},material: 19}
    points=ThermalAttachments.points(slots,@catalog)
    assert length(points)==MapSet.size(MapSet.new(points))
    full_samples=Map.new(points,&{&1,{host,1.0}})
    thin_samples=Map.new(points,&{&1,{host,1/512}})
    air_samples=Map.new(points,&{&1,nil})
    {full,_}=ThermalAttachments.add(%{},slots,@catalog,full_samples,nil)
    {thin,_}=ThermalAttachments.add(%{},slots,@catalog,thin_samples,nil)
    {air,_}=ThermalAttachments.add(%{},slots,@catalog,air_samples,nil)
    refute full==thin
    refute thin==air
  end

  # 只测试：把明确的几何夹具读成输入值，不给纯计算模块传递回调。
  defp samples(points, state, at, volume) do
    Map.new(points, fn point ->
      {target, _} = at.(point, state)
      target = if target && target.granularity == 2, do: %{target | granularity: 1}, else: target
      {point, if(target, do: {target, volume.(state, target)})}
    end)
  end

  defp geometry(slots, cells,volume \\ fn _,_ -> 1.0 end) do
    at=fn p,s ->
      cell=p |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1,8)) |> List.to_tuple()
      t=if cell in cells,do: %{micro: cell |> Tuple.to_list() |> Enum.map(&(&1*8)) |> List.to_tuple(),
        granularity: 0,incarnation: 1,owner: {0,0},material: 19}
      {t,s}
    end
    nodes=Enum.flat_map(cells,fn cell ->
      faces=ThermalGeometry.faces(cell,%{})
      ThermalGeometry.cell(faces,@catalog.materials,samples(ThermalGeometry.points(faces),nil,at,volume))
    end) |> Map.new()
    {nodes,_}=ThermalAttachments.add(nodes,slots,@catalog,samples(ThermalAttachments.points(slots,@catalog),nil,at,volume),nil)
    nodes
  end

  test "附件子图复用不吞掉远处节点变化；宿主、目录、槽和液面变化与无缓存结果相等" do
    slot={0,0,{8,0,0}}
    slots=%{slot=>{10,19}}
    nodes=geometry(%{},[{0,0,0},{1,0,0}])
    host=nodes[{0,{0,0,0}}].target
    at=fn p,s ->
      t=cond do
        elem(p,0)<8 -> host
        s.occupied -> %{host | micro: {8,0,0},material: s.material}
        true -> nil
      end
      {t,s}
    end
    volume=fn s,_ -> s.volume end
    state=%{occupied: true,material: 19,volume: 1.0}
    {_,cached}=ThermalAttachments.add(nodes,slots,@catalog,samples(ThermalAttachments.points(slots,@catalog),state,at,volume),nil)
    far=Map.put(nodes,{0,{80,0,0}},%{nodes[{0,{0,0,0}}] | target: %{host | micro: {80,0,0}}})
    {result,retained}=ThermalAttachments.add(far,slots,@catalog,samples(ThermalAttachments.points(slots,@catalog),state,at,volume),cached)
    assert result[{0,{80,0,0}}]==far[{0,{80,0,0}}]
    assert :erts_debug.same(elem(cached,1),elem(retained,1))
    changed_catalog=put_in(@catalog.materials[19]["thermal_conductivity"],20.0)
    for {ns,ss,catalog,world} <- [
      {Map.delete(nodes,{0,{8,0,0}}),slots,@catalog,%{state | occupied: false}},
      {Map.delete(nodes,{0,{8,0,0}}),slots,@catalog,%{state | material: 1}},
      {nodes,slots,@catalog,%{state | volume: 1/512}},
      {nodes,slots,changed_catalog,state},
      {nodes,%{slot=>{11,19}},@catalog,state},
      {nodes,%{},@catalog,state},
      {put_in(nodes[{0,{0,0,0}}].exposed_faces,0.25),slots,@catalog,state}
    ] do
      values=samples(ThermalAttachments.points(ss,catalog),world,at,volume)
      {hot,_}=ThermalAttachments.add(ns,ss,catalog,values,cached)
      {uncached,_}=ThermalAttachments.add(ns,ss,catalog,values,nil)
      assert hot==uncached
    end
  end

  test "薄水底板半程按高度，高侧板和顶部留空不传热，侧壁只算浸没面积" do
    bottom={0,1,{0,0,0}}; top={0,1,{0,8,0}}
    low_side={0,0,{0,0,0}}; high_side={0,0,{0,1,0}}
    slots=Map.new(Enum.with_index([bottom,top,low_side,high_side],fn s,i->{s,{i+1,19}} end))
    nodes=geometry(slots,[{0,0,0}],fn _,_->1/512 end)
    host={0,{0,0,0}}
    bottom_g=nodes[ThermalAttachments.key(bottom)].contacts |> List.keyfind(host,0) |> elem(1)
    assert_in_delta bottom_g,(1/64)/(1/1024/10+1/1024/10),1.0e-9
    side_g=nodes[ThermalAttachments.key(low_side)].contacts |> List.keyfind(host,0) |> elem(1)
    assert_in_delta side_g,(1/8/512)/(1/1024/10+0.5/10),1.0e-9
    for s<-[top,high_side],do: refute(List.keymember?(nodes[ThermalAttachments.key(s)].contacts,host,0))
    assert_in_delta nodes[host].capacity,1000/512,1.0e-12
  end

  test "每个槽保持实际体积；同地址面线与宿主独立，跨区连续线只接触一次" do
    face={0,1,{511,8,0}}; a={1,0,{511,8,0}}; b={1,0,{512,8,0}}
    slots=%{face=>{10,19},a=>{11,19},b=>{11,19}}
    nodes=geometry(slots,[{63,0,0},{64,0,0}])
    assert_in_delta nodes[ThermalAttachments.key(face)].capacity,1000/32768,1.0e-12
    assert_in_delta nodes[ThermalAttachments.key(a)].capacity,1000/2097152,1.0e-12
    assert nodes[ThermalAttachments.key(a)].target != nodes[ThermalAttachments.key(b)].target
    edges=ThermalGeometry.contacts(nodes)
    assert Enum.count(edges,fn {x,y,_}->MapSet.new([x,y])==MapSet.new([ThermalAttachments.key(a),ThermalAttachments.key(b)]) end)==1
    assert Enum.any?(edges,fn {x,y,g}->x==ThermalAttachments.key(face) and y==ThermalAttachments.key(a) and g>0 end)
  end

  test "夹层替换对应宿主直接接触；不把涂层重复算成并联热路" do
    face={0,0,{8,0,0}}
    nodes=geometry(%{face=>{10,19}},[{0,0,0},{1,0,0}])
    edges=ThermalGeometry.contacts(nodes)
    assert [{_,_,g}]=Enum.filter(edges,fn {a,b,_}->elem(a,0)==0 and elem(b,0)==0 end)
    assert_in_delta g,10*(1-1/64),1.0e-12
    assert Enum.count(edges,fn {_,b,_}->b==ThermalAttachments.key(face) end)==2
  end

  test "缺口不连接；无环境交换的薄线与宿主守恒，温度不超调" do
    a={1,0,{0,8,0}}; b={1,0,{2,8,0}}
    nodes=geometry(%{a=>{10,19},b=>{10,19}},[{0,0,0}])
    ordered=Enum.sort(nodes)
    index=ordered |> Enum.with_index() |> Map.new(fn {{id,_},i}->{id,i} end)
    edges=ThermalGeometry.contacts(nodes)
    refute Enum.any?(edges,fn {x,y,_}->x==ThermalAttachments.key(a) and y==ThermalAttachments.key(b) end)
    input=for {id,n}<-ordered,do: {if(id==ThermalAttachments.key(a),do: 400.0,else: 300.0),1.0,1.0,
      n.capacity*1.0,10.0,1000.0,0.0,0.0,0.0,true}
    contacts=for {a,b,g}<-edges,do: {index[a],index[b],g}
    {_,out,0.0,0.0}=ThermalNative.advance(input,contacts,293.15,0.0,0.01,0.1, {[], []})
    before=Enum.sum(for n<-input,do: elem(n,0)*elem(n,3))
    after_heat=Enum.zip_with(input,out,fn n,{t,_,_}->t*elem(n,3) end) |> Enum.sum()
    assert_in_delta before,after_heat,1.0e-7
    for {t,_,_}<-out,do: assert(t>=300.0-1.0e-9 and t<=400.0)
  end
end
