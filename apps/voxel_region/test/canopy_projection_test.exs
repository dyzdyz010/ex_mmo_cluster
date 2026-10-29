defmodule VoxelRegion.CanopyProjectionTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.World.Canopy
  alias MmoContracts.Voxel.Skins
  defp state(cells,bound) do
    bytes = VoxelRegion.Prefab.encode(%{cells: [], children: [], attachments: [],
      macro_cells: [{{0,0,0},58}], presentation_bindings: %{58=>2}})
    {:ok, id, compiled} = VoxelRegion.Prefab.compile(bytes, %{})
    VoxelRegion.World.Canonical.index_macro_owners(%{macro_owners: Map.new(bound,&{&1,{1,0}}),instances: %{{1,0}=>%{definition_id: id,anchor: {0,0,0},orientation: 0,parent_id: {0,0},component_slot: 0}},
      prefabs: %{id=>compiled},refined: %{},attachments: %{},attachment_regions: %{},structure: %{},canopy: %{},
      overlay: Map.new(cells,fn {p,m}->{{0,p},{m,Skins.uniform(m)}} end),region_bases: %{},decoded: %{},
      source: VoxelRegion.TestSupport.Source,source_state: %{observer: self(),root: "unused"}})
  end
  # L1–L5 的投影合并随提交维护的树冠片段（M2b）：投影前按当前夹具状态重算片段，断言不变。
  defp project(s,level,region),do: Canopy.project(Canopy.refresh_all(s),level,region)

  test "two five of eight layouts with the same coarse material retain distinct actual anchors at all LODs" do
    all=for z<- -2..-1,y<- -2..-1,x<- -2..-1,do: {x,y,z}
    a=Enum.take(all,5); b=Enum.take(Enum.reverse(all),5)
    for bound<-[a,b] do
      s=state(Enum.map(bound,&{&1,58}),bound)
      for level<-0..5 do
        {anchors,instances,residual,_,_}=project(s,level,{-1,-1,-1})
        assert Enum.sort(Map.keys(anchors))==Enum.sort(bound)
        assert map_size(instances)==1
        assert Enum.all?(residual,fn {_,{m,_}}->m==0 end)
      end
    end
    assert VoxelRegion.Reducer.reduce_material(List.duplicate(58,5)++[0,0,0])==58
    refute Enum.sort(a)==Enum.sort(b)
  end
  test "residual preserves unbound old material and excludes deleted canonical leaves" do
    all=for z<-0..1,y<-0..1,x<-0..1,do: {x,y,z}
    s=state(Enum.map(all,&{&1,58}),[{0,0,0}])
    {anchors,_,residual,_,_}=project(s,1,{0,0,0})
    assert map_size(anchors)==1
    assert {58,_}=residual[MmoContracts.Voxel.Payload.cell_index({1,1,1})]
    s=put_in(s.overlay[{0,{0,0,0}}],{0,Skins.uniform(0)})
    assert {%{},%{},%{},%{},_}=project(s,1,{0,0,0})
  end
  test "negative XYZ boundary anchor is shared by core and ring without template expansion" do
    s=state([{{-64,-64,-64},58}],[{-64,-64,-64}])
    for region<-[{-1,-1,-1},{-2,-2,-2}] do
      {a,_,_,_,_}=project(s,0,region)
      assert Map.keys(a)==[{-64,-64,-64}]
    end
    keys=Canopy.affected_keys(s,s,[{-63,-63,-63}])
    assert {1,{-1,-1,-1}} in keys
    refute {0,{-1,-1,-1}} in keys
    assert Enum.uniq(Enum.map(keys,&elem(&1,0)))==[1,2,3,4,5]
  end
  test "affected keys include attachment neighbors from before and after removal" do
    before=state([{{0,0,0},58},{{1,0,0},11}],[{0,0,0}])
    before=VoxelRegion.World.Canonical.put_attachments(before,%{{0,0,{16,0,0}}=>{2,19}})
    after_removal=VoxelRegion.World.Canonical.drop_attachments(before,[{0,0,{16,0,0}}])
    for {a,b}<-[{before,before},{before,after_removal},{after_removal,before}] do
      assert {1,{0,0,0}} in Canopy.affected_keys(a,b,[{2,0,0}])
    end
  end
  test "mixed micro structure and directional attachment survive render-only removal" do
    s=state([{{0,0,0},58}],[{0,0,0}])
    slots=%{0=>{11,{2,0}}}
    original=VoxelRegion.Structure.from_canonical([58,VoxelRegion.RefinedSlots.from_map(slots),0,0,0,0,0,0])
    s=%{s | refined: %{{1,0,0}=>VoxelRegion.RefinedSlots.from_map(slots)},structure: %{{1,{0,0,0}}=>original}}
    {_,_,_,structures,_}=project(s,1,{0,0,0})
    grid=structures[MmoContracts.Voxel.Payload.cell_index({1,1,1})]
    assert <<0::16-little,_::binary>>=grid
    assert <<267::16-little>>=binary_part(grid,8*2,2)
    assert s.structure[{1,{0,0,0}}]==original
  end
end
