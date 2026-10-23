defmodule VoxelRegion.CanopyWorldTest do
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, Prefab, TestSupport}
  alias VoxelRegion.TestSupport.{Source,Actor}
  setup do
    root=Path.join(System.tmp_dir!(),"canopy_world_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    properties=Path.join(root,"properties.json")
    File.write!(properties,Jason.encode!(%{schema_version: 1,tags: [%{id: "damage"}],
      materials: for(m<-Enum.to_list(0..23)++[58],do: %{material_id: m,max_hp_per_macro: if(m==0,do: 0,else: 100),defense: 0,tags: [],responses: [%{action: "damage",multiplier: 1}]}),
      tools: [%{id: "pick",tool_id: 1,action: "damage",power: 200,range_macro: 10,interval_seconds: 0.1}],definitions: []}))
    opts=[source: Source,root: root,observer: self(),name: nil,property_catalog_path: properties,prefab_catalog_path: nil,production_materials: [11,19,58]]
    world=start_supervised!({World,opts})
    actor=%{cid: 1001,gate: self(),identity: :canopy,refresh: &Actor.tool_context/2,eye: {1.0625,1.0625,0.0625},tick_us: 16667}
    actor=Map.put(actor,:player,start_supervised!({Actor,actor}))
    on_exit(fn->File.rm_rf!(root) end)
    %{world: world,actor: actor,opts: opts}
  end
  defp definition(c,points,presentation) do
    bytes=Prefab.encode(%{cells: [],children: [],attachments: [],macro_cells: Enum.map(points,&{&1,58}),presentation_bindings: %{58=>presentation}})
    assert {:ok,id}=World.publish_prefab(c.world,c.actor,bytes)
    id
  end
  defp balance(c),do: Enum.find(World.material_balances(c.world,1001),&(&1.material==58)).balance
  defp anchors(c),do: for(level<-0..5,do: TestSupport.payload(c.world,level,{0,0,0}).canopy)
  test "normal publish place collect replace remove preserve payment and all LOD afterimages",c do
    points=[{0,0,0},{1,0,0},{0,1,0},{1,1,0},{0,0,1}]
    id=definition(c,points,2)
    next_id=definition(c,points,3)
    assert {:ok,_}=World.material_supply(c.world,1001,"canopy-author-sample",%{58=>2560})
    assert {:ok,birth}=World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,%{definition_id: id,anchor: {8,8,16},orientation: 0,client_intent_seq: 1})
    assert balance(c)==0
    assert Enum.all?(anchors(c),&(map_size(&1)==5))
    query=%{request_id: 1,client_intent_seq: 2,logical_scene_id: 1,action: 0,direction: {0.0,0.0,1.0},micro: {0,0,0},incarnation: 0,owner: {0,0},material: 0,tool_id: 1}
    assert {:ok,target}=World.tool_intent(c.world,c.actor,query)
    req=Map.merge(query,Map.take(target,[:micro,:granularity,:incarnation,:owner,:material])) |> Map.put(:action,1)
    assert {:ok,_}=World.tool_intent(c.world,Map.merge(c.actor,%{received_us: 1000000,clock_node: node()}),req)
    assert balance(c)==512
    assert :ok=World.compact(c.world)
    assert Enum.all?(anchors(c),&(map_size(&1)==4))
    stop_supervised!(World)
    c=%{c|world: start_supervised!({World,c.opts})}
    assert Enum.all?(anchors(c),&(map_size(&1)==4))
    assert {:ok,new_birth}=World.prefab_intent(c.world,c.actor,:voxel_prefab_replace_v1,%{instance_id: {birth,0},definition_id: next_id,client_intent_seq: 3})
    assert balance(c)==0
    assert Enum.all?(anchors(c),fn a->map_size(a)==5 and Enum.all?(a,fn {_,{58,_,p}}->p==3 end) end)
    assert {:ok,_}=World.prefab_intent(c.world,c.actor,:voxel_prefab_remove_v1,%{instance_id: {new_birth,0},client_intent_seq: 4})
    assert balance(c)==2560
    assert Enum.all?(anchors(c),&(&1==%{}))
    transactions=World.entries_after(c.world,new_birth)
    levels=for t<-transactions,e<-t.entries,Map.has_key?(e,:payload),do: elem(MmoContracts.Voxel.Codec.decode_payload_header(e.payload),1).level
    assert Enum.all?(0..5,&(&1 in levels))
    stop_supervised!(World)
    c=%{c|world: start_supervised!({World,c.opts})}
    assert Enum.all?(anchors(c),&(&1==%{}))
    assert balance(c)==2560
  end
  test "ordinary sibling edit survives journal replay when its residual changes",c do
    id=definition(c,[{0,0,0}],2)
    assert {:ok,_}=World.material_supply(c.world,1001,"canopy-sibling",%{58=>512})
    assert {:ok,_}=World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,%{definition_id: id,anchor: {8,8,16},orientation: 0,client_intent_seq: 1})
    assert Enum.all?(anchors(c),&(map_size(&1)==1))
    assert {:ok,_}=World.apply_edit(c.world,{0,1,2},11)
    before=TestSupport.payload(c.world,1,{0,0,0}).canopy_residual
    stop_supervised!(World)
    c=%{c|world: start_supervised!({World,c.opts})}
    assert TestSupport.payload(c.world,1,{0,0,0}).canopy_residual==before
    assert MmoContracts.Voxel.Payload.material(TestSupport.payload(c.world,0,{0,0,0}),{1,2,3})==11
  end
  defp attachment_fixture(c) do
    id=definition(c,[{0,0,0}],2)
    assert {:ok,_}=World.material_supply(c.world,1001,"canopy-face",%{58=>512,19=>512})
    assert {:ok,_}=World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,%{definition_id: id,anchor: {0,0,0},orientation: 0,client_intent_seq: 1})
    assert {:ok,_}=World.apply_edit(c.world,{1,0,0},11)
    :ok=GenServer.call(c.actor.player,{:eye,{2.5,0.5,0.5}})
    %{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 0,
      kind: 0,axis: 0,size: 8,anchor: {16,0,0},id: 0,material: 19,tool_id: 1}
  end
  defp canopy_afterimage(c,seq,level) do
    payloads=for txn<-World.entries_after(c.world,seq-1),entry<-txn.entries,
      Map.has_key?(entry,:payload),{:ok,p}<-[MmoContracts.Voxel.Payload.decode(entry.payload)],
      p.level==level and p.region=={0,0,0},do: p
    assert [p]=payloads
    assert map_size(p.canopy)==1
    p
  end
  test "face attachment placement and removal refresh every canopy residual",c do
    request=attachment_fixture(c)
    empty=TestSupport.payload(c.world,1,{0,0,0})
    assert {:ok,id}=World.attachment_intent(c.world,c.actor,request)
    placed=canopy_afterimage(c,id,1)
    refute placed.canopy_residual==empty.canopy_residual
    for level<-2..5,do: canopy_afterimage(c,id,level)
    assert {:ok,seq}=World.attachment_intent(c.world,c.actor,%{request|action: 1,id: id,client_intent_seq: 11,request_id: 11})
    removed=canopy_afterimage(c,seq,1)
    assert removed.canopy_residual==empty.canopy_residual
    for level<-2..5,do: canopy_afterimage(c,seq,level)
    assert Enum.find(World.material_balances(c.world,1001),&(&1.material==19)).balance==512
  end
  test "cross-parent occluder edits refresh neighboring canopy attachment skins",c do
    request=attachment_fixture(c)
    assert {:ok,_}=World.attachment_intent(c.world,c.actor,request)
    exposed=TestSupport.payload(c.world,1,{0,0,0})
    assert {:ok,seq}=World.apply_edit(c.world,{2,0,0},11)
    hidden=canopy_afterimage(c,seq,1)
    refute hidden.canopy_residual==exposed.canopy_residual
    assert World.stats(c.world).attachment_slots==64
    assert {:ok,seq}=World.apply_edit(c.world,{2,0,0},0)
    revealed=canopy_afterimage(c,seq,1)
    assert revealed.canopy_residual==exposed.canopy_residual
  end
  @tag :interop_fixture
  test "negative L2 mixed structure fixture comes from normal publish and place",c do
    points=[{0,0,0},{1,0,0},{0,1,0},{1,1,0},{0,0,1}]
    bytes=Prefab.encode(%{cells: [{{8,0,8},11}],children: [],attachments: [],macro_cells: Enum.map(points,&{&1,58}),presentation_bindings: %{58=>2}})
    assert {:ok,id}=World.publish_prefab(c.world,c.actor,bytes)
    assert {:ok,_}=World.material_supply(c.world,1001,"canopy-interop",%{58=>2560,11=>1})
    :ok=GenServer.call(c.actor.player,{:eye,{-1.9375,-1.9375,-3.9375}})
    assert {:ok,_}=World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,%{definition_id: id,anchor: {-16,-16,-16},orientation: 0,client_intent_seq: 1})
    dir=System.get_env("CANOPY_FIXTURE_DIR")
    metadata=for level<-0..5 do
      request=MmoContracts.Voxel.Codec.encode_request(0,[%{level: level,region: {-1,-1,-1},have_seq: 0,have_hash: 0}]) |> IO.iodata_to_binary()
      assert {:ok,reply}=World.serve(c.world,request)
      assert {:ok,_,[{:payload,^level,{-1,-1,-1},payload}]}=MmoContracts.Voxel.Codec.decode_reply(IO.iodata_to_binary(reply))
      assert {:ok,p}=MmoContracts.Voxel.Payload.decode(payload)
      assert map_size(p.canopy)==5
      if level>0,do: assert(map_size(p.canopy_residual_structure)>0)
      assert {:ok,header,raw}=MmoContracts.Voxel.Codec.unpack_payload_body(payload)
      if dir do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir,"negative-l#{level}.vxrd"),payload)
        File.write!(Path.join(dir,"negative-l#{level}.raw"),raw)
      end
      %{level: level,region: [-1,-1,-1],raw_bytes: byte_size(raw),payload_bytes: byte_size(payload),compressed_body_bytes: header.body_bytes,anchors: 5,residuals: map_size(p.canopy_residual),structures: map_size(p.canopy_residual_structure),hash: header.hash}
    end
    if dir do
      File.write!(Path.join(dir,"bound-mixed.vxpd"),bytes)
      File.write!(Path.join(dir,"metadata.json"),Jason.encode!(%{definition_sha256: Base.encode16(id,case: :lower),definition_bytes: byte_size(bytes),regions: metadata},pretty: true))
    end
  end
end