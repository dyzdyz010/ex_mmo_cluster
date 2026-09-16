defmodule VoxelRegion.AttachmentsTest do
  @moduledoc "只测试：规范共享地址与客户端 VXR8 接缝。"
  use ExUnit.Case, async: true
  @moduletag :b4
  alias MmoContracts.Voxel.{Attachments,Payload,Codec}

  test "attachment encoder preserves signed tuple order independently of insertion and identity" do
    entries=for kind<-[0,1],axis<-0..2,x<-[-9223372036854775808,-513,-1,0,512,9223372036854775807],
      do: {{kind,axis,{x,-x-1,axis-1}},{100-kind*10-axis,19}}
    slots=Map.new(Enum.reverse(entries))
    expected=[<<length(entries)::32-little>>,(for {{k,a,{x,y,z}},{id,m}}<-entries,
      do: <<k,a,x::signed-little-64,y::signed-little-64,z::signed-little-64,id::64-little,m::16-little>>)] |> IO.iodata_to_binary()
    assert Attachments.encode(slots)==expected
    assert {:ok,^slots}=Attachments.decode(expected)
    assert Attachments.encode(%{})==<<0::32-little>>
  end

  test "grouped L1 projection equals full canonical traversal on every axis and signed parent boundary" do
    alias VoxelRegion.Attachments,as: A
    slots=for kind<-[0,1],axis<-0..2,x<-[-17,-16,-1,0,15,16],y<-[-1,0,16],z<-[-1,0,16],
      into: %{},do: {{kind,axis,{x,y,z}},{1,19}}
    parents=for x<- -2..1,y<- -1..1,z<- -1..1,do: {x,y,z}
    groups=A.l1_faces(slots,parents)
    sample=fn {x,y,z},s -> {if(rem(x+y+z,3)==0,do: 11,else: 0),s} end
    base=MmoContracts.Voxel.Skins.uniform(11)
    for parent<-parents do
      assert A.project_l1(parent,base,Map.get(groups,parent,[]),sample,nil)==
        A.project_l1(parent,base,slots,sample,nil)
    end
  end

  test "L1 face grouping keeps both sides of negative and positive boundaries without lines" do
    alias VoxelRegion.Attachments,as: A
    slots=%{{0,0,{0,-1,16}}=>{7,19},{0,1,{-16,0,16}}=>{8,19},{1,0,{0,-1,16}}=>{9,19}}
    parents=for x<- -2..1,y<- -1..0,z<-0..1,do: {x,y,z}
    groups=A.l1_faces(slots,parents)
    for parent<-parents do
      expected=Map.filter(slots,fn {slot,_}-> elem(slot,0)==0 and Enum.any?(A.neighbors(slot),fn {x,y,z}->
        {Integer.floor_div(x,16),Integer.floor_div(y,16),Integer.floor_div(z,16)}==parent end) end)
      assert Map.new(Map.get(groups,parent,[]))==expected
    end
    assert A.l1_faces(slots,[])==%{}
    for region<-[{-1,-1,0},{0,0,0},{1,1,1}] do
      expected=Map.filter(slots,fn {{_,_,p},_}->Enum.all?(0..2,fn i->
        origin=elem(region,i)*512;v=elem(p,i);v>=origin-8 and v<origin+520 end) end)
      assert A.extract(slots,region)==expected
    end
  end

  test "VXR8 roundtrip keeps negative anchors, nested identity and shared boundary slots" do
    slots=%{{0,0,{-512,0,0}}=>{42,19},{1,1,{-512,0,0}}=>{43,16}}
    p=%Payload{region: {-1,0,0},cells: :binary.copy(<<0,0>>,66*66*66),attachments: slots}
    bytes=Payload.encode(p,%{},44,123)
    assert {:ok,%{format_version: 8,attachments: ^slots}}=Payload.decode(bytes)
    assert {:ok,header,body}=Codec.decode_payload_body(bytes)
    assert header.version==8
    assert {:ok,%{attachments: ^slots}}=Payload.decode_body(body,8)
    assert {:error,:invalid_payload}=Payload.decode_body(body,4)
    assert {:error,:invalid_attachments}=Attachments.decode(Attachments.encode(%{{0,3,{0,0,0}}=>{1,19}}))
    assert {:error,:invalid_attachments}=Attachments.decode(Attachments.encode(%{{0,0,{0,0,0}}=>{1,20}}))
    assert {:error,:invalid_payload}=Payload.decode(Payload.encode(%{p | region: {2,0,0}},%{},44,123))
  end

  test "wire explicitly rejects old hello and malformed attachment requests" do
    alias MmoContracts.Session
    h=%Session.Hello{protocol_version: 8,kernel_id: <<0::256>>,profile_id: <<0::256>>}
    bytes=Session.Codec.encode(h) |> elem(1) |> IO.iodata_to_binary()
    assert {:ok,^h}=Session.Codec.decode(bytes)
    <<prefix::binary-size(9),_::16,rest::binary>>=bytes
    assert {:error,_}=Session.Codec.decode(prefix<><<1::16>><>rest)
    valid=<<0x81,1::64,1::32,1::64,0,1,0,8,512::signed-64,8::signed-64,0::signed-64,0::64,19::16,1::16>>
    assert {:ok,{:voxel_attachment_intent,%{anchor: {512,8,0},kind: 1,size: 8}}}=Codec.decode(valid)
    assert {:error,:invalid_message}=Codec.decode(valid<><<0>>)
  end

  test "structure attachment skins keep direction, omit edges and buried faces, reduce and remove" do
    alias VoxelRegion.Structure
    alias MmoContracts.Voxel.Structure,as: Wire
    owner={1,0}
    cells=for x<-0..7,y<-0..7,into: %{},do: {x+8*y,{11,owner}}
    grid=Structure.from_canonical([cells,0,0,0,0,0,0,0])
    hosts=for x<-0..7,y<-0..7,into: %{},do: {{x,y,0},11}
    sample=fn p,s -> {Map.get(s,p,0),s} end
    slots=Map.new(VoxelRegion.Attachments.footprint(0,2,{0,0,0},8),&{&1,{2,19}})
    {painted,_}=Structure.project_attachments(grid,{0,0,0},slots,sample,hosts)
    assert Wire.valid?(painted)
    assert {:ok,%{0=>^painted}}=Wire.decode(Wire.encode(%{0=>painted}))
    assert {:ok,%{0=>^grid}}=Wire.decode(<<1::32-little,1::32-little,0::32-little,grid::binary>>)
    face=fn g,f,i -> <<m::16-little>>=binary_part(g,2*((f+1)*4096+i),2);m end
    assert face.(painted,4,0)==19
    assert face.(painted,5,0)==0
    coarse=Structure.reduce([painted,0,0,0,0,0,0,0])
    assert face.(coarse,4,0)==19
    assert face.(coarse,5,0)==0
    coarse2=Structure.reduce([coarse,0,0,0,0,0,0,0])
    assert face.(coarse2,4,0)==19
    blocked=Map.put(hosts,{0,0,-1},11)
    {hidden,_}=Structure.project_attachments(grid,{0,0,0},slots,sample,blocked)
    assert face.(hidden,4,0)==0
    assert face.(hidden,4,1)==19
    assert {^grid,_}=Structure.project_attachments(grid,{0,0,0},%{},sample,hosts)
    edges=Map.new(VoxelRegion.Attachments.footprint(1,1,{0,0,0},8),&{&1,{3,19}})
    assert {^grid,_}=Structure.project_attachments(grid,{0,0,0},edges,sample,hosts)
    assert {:ok,%{structure: ^painted}}=Codec.decode_entry(Codec.encode_entry(%{seq: 3,level: 1,cell: {0,0,0},structure: painted}) |> IO.iodata_to_binary())
  end

  test "L1 projection preserves occupancy skins, occlusion, shared support and exact area vote" do
    alias VoxelRegion.{Attachments,Reducer}
    base=MmoContracts.Voxel.Skins.uniform(11)
    slots=Map.new(Attachments.footprint(0,2,{0,0,0},8),&{&1,{1,19}})
    sample=fn p,s -> {Map.get(s,p,0),s} end
    hosts=for x<-0..7,y<-0..7,z<-0..7,into: %{},do: {{x,y,z},11}
    {skins,_}=Attachments.project_l1({0,0,0},base,slots,sample,hosts)
    assert Reducer.texel(skins,4,0,0)==19
    assert Reducer.texel(skins,4,1,0)==11
    assert Reducer.texel(skins,5,0,0)==11
    # 外侧遮挡时仍保留事实，但不投影。
    blocked=for x<-0..7,y<-0..7,into: hosts,do: {{x,y,-1},11}
    assert {^base,_}=Attachments.project_l1({0,0,0},base,slots,sample,blocked)
    half=Map.filter(slots,fn {{_,_,{x,_,_}},_}->x<4 end)
    {skins,_}=Attachments.project_l1({0,0,0},base,half,sample,hosts)
    assert Reducer.texel(skins,4,0,0)==11
    # 删除不留投影颜色；线元不写表皮。
    assert {^base,_}=Attachments.project_l1({0,0,0},base,%{},sample,hosts)
    edges=Map.new(Attachments.footprint(1,0,{0,0,0},8),&{&1,{2,19}})
    assert {^base,_}=Attachments.project_l1({0,0,0},base,edges,sample,hosts)
  end
end
