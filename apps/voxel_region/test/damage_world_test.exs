defmodule VoxelRegion.DamageWorldTest do
  use ExUnit.Case, async: false
  alias VoxelRegion.{World,OverlayLog}
  alias MmoContracts.Voxel.{Payload,Codec}

  defmodule Source do
    def open(opts), do: {:ok,%{root: Keyword.fetch!(opts,:root),observer: Keyword.fetch!(opts,:observer)}}
    def content_version(_), do: 123
    def world_dir(s), do: s.root
    def generated(_), do: 0
    def ensure(s,level,region) do
      send(s.observer,{:prepared,level,region})
      :ok
    end
    def read(s,level,region) do
      if level==0 and region in [{10,0,0},{11,0,0}] do
        send(s.observer,{:region_read_started,self(),region})
        receive do :continue_region_read -> :ok after 1_000 -> :ok end
      end
      p=%Payload{level: level,region: region,cells: :binary.copy(<<0,0>>,66*66*66)}
      bytes=Payload.encode(p,%{},0,123)
      {:ok,h}=Codec.decode_payload_header(bytes)
      {:ok,bytes,h}
    end
  end

  defmodule Actor do
    use GenServer
    def start_link(state),do: GenServer.start_link(__MODULE__,state)
    def init(state),do: {:ok,state}
    def tool_context(player,id),do: GenServer.call(player,{:tool_context,id})
    def handle_call({:tool_context,id},_,%{identity: id}=state),do: {:reply,{:ok,Map.put(state,:player,self())},state}
    def handle_call({:tool_context,_},_,state),do: {:reply,{:error,:invalid_state},state}
    def handle_call({:eye,eye},_,state),do: {:reply,:ok,%{state | eye: eye}}
    def handle_call(:seal,_,state),do: {:reply,:ok,%{state | identity: :sealed}}
  end

  defmodule Log do
    defdelegate open(path,cv),to: OverlayLog.File
    defdelegate replay(path),to: OverlayLog.File
    def checkpoint(path,txn) do
      File.write!(path<>".checkpoint_calls","1",[:append])
      OverlayLog.File.checkpoint(path,txn)
    end
    def append(path,txn) do
      if File.exists?(path<>".reject"),do: {:error,:test_disk_failure},else: OverlayLog.File.append(path,txn)
    end
  end

  setup do
    root=Path.join(System.tmp_dir!(),"b1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    catalog=Path.join(root,"properties.json")
    materials=for id <- 0..23,do: %{material_id: id,max_hp_per_macro: if(id==0,do: 0.0,else: 100.0),
      defense: 2.0,tags: [],responses: [%{action: "damage",multiplier: 1.0}]}
    data=%{schema_version: 1,tags: [%{id: "damage"}],materials: materials,
      tools: [%{id: "pickaxe",tool_id: 1,action: "damage",power: 30.0,range_macro: 6.0,interval_seconds: 0.5}],definitions: []}
    File.write!(catalog,Jason.encode!(data))
    prefab=Path.join(root,"prefabs")
    File.mkdir_p!(prefab)
    bytes=<<"VXPD",1::32-little,2::32-little,
      0::signed-little-32,0::signed-little-32,0::signed-little-32,11::16-little,
      1::signed-little-32,0::signed-little-32,0::signed-little-32,19::16-little,0::32-little>>
    File.write!(Path.join(prefab,"test.vxpd"),bytes)
    opts=[source: Source,log: Log,root: root,observer: self(),property_catalog_path: catalog,prefab_catalog_path: prefab,name: nil,production_materials: [19,11]]
    w=start_supervised!({World,opts})
    actor=%{cid: 1001,gate: self(),identity: :test_session,refresh: &Actor.tool_context/2,eye: {1.0625,1.0625,0.0625},tick_us: 16_667}
    actor=Map.put(actor,:player,start_supervised!({Actor,actor}))
    request=%{request_id: 1,client_intent_seq: 1,logical_scene_id: 1,action: 0,
      direction: {0.0,0.0,1.0},micro: {0,0,0},incarnation: 0,owner: {0,0},material: 0,tool_id: 1}
    on_exit(fn -> File.rm_rf!(root) end)
    %{w: w,actor: actor,request: request,opts: opts,id: :crypto.hash(:sha256,bytes),catalog: catalog}
  end

  defp attack(w,actor,request,target,seq) do
    request=Map.merge(request,Map.take(target,[:micro,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 1,client_intent_seq: seq})
    actor=Map.merge(actor,%{received_us: System.monotonic_time(:microsecond),clock_node: node()})
    World.tool_intent(w,actor,request)
  end

  @tag :b2
  test "B2 harvest and paid build preserve world and balance in the same log", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    for seq <- 1..4 do
      actor=Map.merge(c.actor,%{received_us: seq*500_000,clock_node: node()})
      request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
        |> Map.merge(%{action: 1,client_intent_seq: seq})
      assert {:ok,_}=World.tool_intent(c.w,actor,request)
      assert balance(c.w,1001).balance == if(seq==4,do: 512,else: 0)
    end
    build=%{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 1,coord: {1,1,2},tool_id: 1,material: 19}
    assert {:ok,6}=World.production_intent(c.w,c.actor,build)
    assert balance(c.w,1001).balance == 0
    assert {:ok,6}=World.production_intent(c.w,c.actor,build)
    assert {:error,:insufficient_material}=World.production_intent(c.w,c.actor,%{build | request_id: 11,client_intent_seq: 11,coord: {2,1,2}})
    assert [%{material_balances: %{{1001,19}=>512}},%{material_balances: %{{1001,19}=>0}}]=World.entries_after(c.w,4)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.seq(w)==6
    assert balance(w,1001).balance==0
    assert {:ok,%{material: 19,hp: 100.0}}=World.tool_intent(w,c.actor,c.request)
  end

  test "packed skins preserve every mask and canonicalize uniform maps" do
    import Bitwise
    ids = Enum.reduce(0..5,0,fn face,acc -> acc ||| ((face+1) <<< (face*8)) end)
    for mask <- 0..63, uniform <- [false,true] do
      maps = for face <- 0..5, into: <<>>, do: if(uniform,do: :binary.copy(<<face+1>>,4),else: <<face+1,9,8,7>>)
      indices = for face <- 0..5, (mask &&& (1 <<< face)) != 0, into: <<>>, do: <<face::16-little>>
      p = %Payload{records: %{{1,2,3} => {ids,mask,1}},map_extent: 2,fmi: <<5::16-little,indices::binary>>,maps: maps}
      faces = for face <- 0..5 do
        texels = if (mask &&& (1 <<< face)) != 0,do: binary_part(maps,face*4,4),else: nil
        {face+1,texels}
      end
      assert Payload.skins(p,{1,2,3},19) == MmoContracts.Voxel.Skins.canonical({2,List.to_tuple(faces)})
      assert Payload.skins(p,{4,5,6},19) == MmoContracts.Voxel.Skins.uniform(19)
    end
  end

  defp balance(w,cid,material \\ 19), do: Enum.find(World.material_balances(w,cid), &(&1.material==material))

  defp b2_hit(c,actor,target,seq) do
    actor=Map.merge(actor,%{received_us: seq*500_000,clock_node: node()})
    request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 1,client_intent_seq: seq})
    World.tool_intent(c.w,actor,request)
  end

  defp full_component(c,anchor) do
    cells=for x<-0..7,y<-0..7,z<-0..7,into: <<>>,do:
      <<x::signed-little-32,y::signed-little-32,z::signed-little-32,if(x<4,do: 11,else: 19)::16-little>>
    bytes=<<"VXPD",1::32-little,512::32-little,cells::binary,0::32-little>>
    path=Keyword.fetch!(c.opts,:prefab_catalog_path)
    File.write!(Path.join(path,"full.vxpd"),bytes)
    :ok=World.publish_prefabs(c.w,path)
    World.place_prefab(c.w,:crypto.hash(:sha256,bytes),anchor,0)
  end

  test "component health follows the leaf across hit positions and lethal damage removes all its materials", c do
    assert {:ok,1}=full_component(c,{8,8,16})
    assert {:ok,2}=full_component(c,{8,8,24})
    assert {:ok,stone}=World.tool_intent(c.w,c.actor,c.request)
    assert stone.granularity==2 and stone.hp==100.0
    for seq<-1..3 do
      assert {:ok,_}=b2_hit(c,c.actor,stone,seq)
      assert map_size(:sys.get_state(c.w).refined[{1,1,2}])==512
      assert balance(c.w,1001,11).balance==0
    end
    GenServer.call(c.actor.player,{:eye,{1.8125,1.0625,0.0625}})
    assert {:ok,wood}=World.tool_intent(c.w,c.actor,c.request)
    assert wood.material==19 and wood.hp==16.0 and wood.owner==stone.owner
    assert {:ok,6}=b2_hit(c,c.actor,wood,4)
    state=:sys.get_state(c.w)
    refute Map.has_key?(state.refined,{1,1,2})
    assert map_size(state.refined[{1,1,3}])==512
    assert balance(c.w,1001,11).balance==256 and balance(c.w,1001,19).balance==256
    assert {:error,:stale_target}=b2_hit(c,c.actor,wood,5)
  end

  @tag :b2
  test "B2 explicit dismantle removes only the hit occurrence and credits its remaining wood", c do
    assert {:ok,1}=full_component(c,{8,8,16})
    assert {:ok,2}=World.place_prefab(c.w,c.id,{8,8,24},0)
    GenServer.call(c.actor.player,{:eye,{1.1875,1.0625,0.0625}})
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    assert {:ok,3}=b2_hit(c,c.actor,target,1)
    request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 2,client_intent_seq: 2})
    actor=Map.merge(c.actor,%{received_us: 1_000_000,clock_node: node()})
    assert {:ok,4}=World.tool_intent(c.w,actor,request)
    state=:sys.get_state(c.w)
    refute Map.has_key?(state.refined,{1,1,2})
    assert map_size(state.refined[{1,1,3}])==2
    assert balance(c.w,1001).balance==256
    assert balance(c.w,1001,11).balance==256
    assert {:error,:stale_target}=World.tool_intent(c.w,actor,request)
    assert World.seq(c.w)==4
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert balance(w,1001).balance==256
    assert balance(w,1001,11).balance==256
    assert :sys.get_state(w).refined==state.refined
  end

  @tag :b2
  test "B2 legacy holes and micro damage migrate without healing or paying already harvested slots", c do
    assert {:ok,1}=full_component(c,{8,8,16})
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    # Persist the former live format: one harvested slot and two partially damaged slots.
    :sys.replace_state(c.w,fn s ->
      a=%{target | granularity: 1,micro: {8,8,16},max_hp: 100.0/512,hp: 72.0/512}
      b=%{a | micro: {9,8,16},hp: 44.0/512}
      slots=Map.delete(s.refined[{1,1,2}],2)
      %{s | refined: Map.put(s.refined,{1,1,2},slots),
        payloads: %{},lru: :gb_trees.empty(),lru_ticks: %{},lru_bytes: 0,resident_bytes: 0,
        damage: Map.new([a,b],&{VoxelRegion.Damage.key(&1),&1}),material_balances: %{{1001,11}=>1}}
    end)
    assert :ok=World.compact(c.w)
    before=:sys.get_state(c.w)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    migrated=:sys.get_state(w)
    assert migrated.refined==before.refined
    assert Map.new(migrated.instances,fn {id,i}->{id,Map.take(i,[:definition_id,:anchor,:orientation])} end)==
      Map.new(before.instances,fn {id,i}->{id,Map.take(i,[:definition_id,:anchor,:orientation])} end)
    assert migrated.material_balances==before.material_balances and migrated.seq==before.seq
    assert {:ok,leaf}=World.tool_intent(w,c.actor,c.request)
    assert leaf.granularity==2 and leaf.max_hp==511*100.0/512 and leaf.hp==(511*100.0-84.0)/512
    assert map_size(migrated.damage)==1
    assert :ok=World.compact(w)
    [checkpoint]=World.entries_after(w,0)
    assert [restored]=checkpoint |> OverlayLog.rows() |> OverlayLog.transactions()
    assert restored.property_states==checkpoint.property_states
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert {:ok,^leaf}=World.tool_intent(w,c.actor,c.request)
    request=Map.merge(c.request,Map.take(leaf,[:micro,:incarnation,:owner,:material])) |> Map.put(:action,2)
    actor=Map.merge(c.actor,%{received_us: 500_000,clock_node: node()})
    assert {:error,:stale_target}=World.tool_intent(w,actor,%{request | owner: {999,0}})
    assert {:ok,2}=World.tool_intent(w,actor,request)
    assert balance(w,1001,11).balance==256 and balance(w,1001,19).balance==256
    assert :sys.get_state(w).refined==%{}
  end

  @tag :b2
  test "B2 failed dismantle append rolls back materials, damage and occurrence", c do
    assert {:ok,1}=full_component(c,{8,8,16})
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    assert {:ok,2}=b2_hit(c,c.actor,target,1)
    before=:sys.get_state(c.w)
    {_,path}=before.log
    File.write!(path<>".reject","")
    request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 2,client_intent_seq: 2})
    actor=Map.merge(c.actor,%{received_us: 1_000_000,clock_node: node()})
    assert {:error,:test_disk_failure}=World.tool_intent(c.w,actor,request)
    after_state=:sys.get_state(c.w)
    assert Map.take(after_state,[:seq,:damage,:refined,:instances,:material_balances])==
      Map.take(before,[:seq,:damage,:refined,:instances,:material_balances])
    File.rm!(path<>".reject")
    assert {:ok,3}=World.tool_intent(c.w,actor,request)
    assert balance(c.w,1001).balance==256
  end

  defp b2_actor(c,cid) do
    gate=start_supervised!(Supervisor.child_spec({Task,fn -> Process.sleep(:infinity) end},id: {:gate,cid}))
    actor=%{c.actor | cid: cid,gate: gate,identity: make_ref()}
    player=start_supervised!(Supervisor.child_spec({Actor,actor},id: {:actor,cid}))
    %{actor | player: player}
  end

  defp b2_harvest(c,actor) do
    assert {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,target}=World.tool_intent(c.w,actor,c.request)
    for seq <- 1..4,do: assert({:ok,_}=b2_hit(c,actor,target,seq))
  end

  @tag :b2
  test "B2 competing attacks on different positions share HP and settle the whole leaf once", c do
    other=b2_actor(c,1002)
    assert {:ok,1}=full_component(c,{8,8,16})
    GenServer.call(other.player,{:eye,{1.8125,1.0625,0.0625}})
    assert {:ok,stone}=World.tool_intent(c.w,c.actor,c.request)
    assert {:ok,wood}=World.tool_intent(c.w,other,c.request)
    for seq<-1..3,do: assert({:ok,_}=b2_hit(c,c.actor,stone,seq))
    tasks=for {actor,target,seq}<-[{c.actor,stone,4},{other,wood,1}],do:
      Task.async(fn -> b2_hit(c,actor,target,seq) end)
    results=Enum.map(tasks,&Task.await(&1,10_000))
    assert Enum.count(results,&match?({:ok,5},&1))==1
    assert Enum.count(results,&match?({:error,_},&1))==1
    for material<-[19,11],do: assert(Enum.sort(for cid<-[1001,1002],do: balance(c.w,cid,material).balance)==[0,256])
    assert balance(c.w,1001,19).balance==balance(c.w,1001,11).balance
    assert {:error,_}=b2_hit(c,c.actor,stone,4)
    assert {:error,_}=b2_hit(c,other,wood,1)
    assert :sys.get_state(c.w).refined==%{} and :sys.get_state(c.w).damage==%{}
  end

  @tag :b2
  test "B2 two players dismantling different cells of one component credit one winner", c do
    other=b2_actor(c,1002)
    assert {:ok,1}=World.place_prefab(c.w,c.id,{8,8,16},0)
    GenServer.call(other.player,{:eye,{1.1875,1.0625,0.0625}})
    assert {:ok,stone}=World.tool_intent(c.w,c.actor,c.request)
    assert {:ok,wood}=World.tool_intent(c.w,other,c.request)
    tasks=for {actor,target}<- [{c.actor,stone},{other,wood}],do: Task.async(fn ->
      request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material])) |> Map.put(:action,2)
      actor=Map.merge(actor,%{received_us: 500_000,clock_node: node()})
      World.tool_intent(c.w,actor,request)
    end)
    results=Enum.map(tasks,&Task.await(&1,10_000))
    assert Enum.count(results,&match?({:ok,2},&1))==1
    assert Enum.count(results,&match?({:error,_},&1))==1
    for material<-[19,11],do: assert(Enum.sort(for cid<-[1001,1002],do: balance(c.w,cid,material).balance)==[0,1])
    assert balance(c.w,1001,19).balance==balance(c.w,1001,11).balance
  end

  @tag :b2
  test "B2 stone harvest pays for stone without spending or creating wood", c do
    stop_supervised(World)
    opts=Keyword.put(c.opts,:production_materials,[19,11])
    w=start_supervised!({World,opts})
    c=%{c | w: w}
    assert {:ok,1}=World.apply_edit(w,{1,1,2},11)
    assert {:ok,target}=World.tool_intent(w,c.actor,c.request)
    for seq<-1..4,do: assert({:ok,_}=b2_hit(c,c.actor,target,seq))
    build=%{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 1,coord: {1,1,2},tool_id: 1,material: 11}
    assert {:ok,6}=World.production_intent(w,c.actor,build)
    assert {:ok,%{material: 11}}=World.tool_intent(w,c.actor,c.request)
    assert {:error,:insufficient_material}=World.production_intent(w,c.actor,%{build | request_id: 11,client_intent_seq: 11,material: 19,coord: {2,1,2}})
    assert {:error,:unknown_resource}=World.production_intent(w,c.actor,%{build | request_id: 12,client_intent_seq: 12,material: 17,coord: {2,1,2}})
    stop_supervised(World)
    w=start_supervised!({World,opts})
    assert Enum.all?(World.material_balances(w,1001),&(&1.balance==0))
    assert {:ok,%{material: 11}}=World.tool_intent(w,c.actor,c.request)
  end

  @tag :b2
  test "B2 competing lethal hits credit only the winner and stale repeats cannot harvest again", c do
    other=b2_actor(c,1002)
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    for seq <- 1..3,do: assert({:ok,_}=b2_hit(c,c.actor,target,seq))
    tasks=for {actor,seq} <- [{c.actor,4},{other,1}],do: Task.async(fn -> b2_hit(c,actor,target,seq) end)
    results=Enum.map(tasks,&Task.await(&1,10_000))
    assert Enum.count(results,&match?({:ok,5},&1))==1
    assert Enum.count(results,&match?({:error,_},&1))==1
    assert Enum.sort(for cid <- [1001,1002],do: balance(c.w,cid).balance)==[0,512]
    assert {:error,_}=b2_hit(c,c.actor,target,4)
    assert {:error,_}=b2_hit(c,other,target,1)
    assert World.seq(c.w)==5
  end

  @tag :b2
  test "B2 one lethal hit recovers all materials of a small leaf and checkpoint preserves settlement", c do
    assert {:ok,1}=World.place_prefab(c.w,c.id,{8,8,16},0)
    GenServer.call(c.actor.player,{:eye,{1.1875,1.0625,0.0625}})
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    assert target.material==19 and target.granularity==2
    assert {:ok,2}=b2_hit(c,c.actor,target,1)
    assert :sys.get_state(c.w).refined==%{}
    assert [%{property_states: [%{granularity: 2,flags: 1,hp: +0.0}]}]=World.entries_after(c.w,1)
    assert :ok=World.compact(c.w)
    [checkpoint]=World.entries_after(c.w,0)
    assert [restored]=checkpoint |> OverlayLog.rows() |> OverlayLog.transactions()
    assert restored.material_balances==%{{1001,19}=>1,{1001,11}=>1}
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert balance(w,1001).balance==1
    assert balance(w,1002).balance==0
    assert :sys.get_state(w).refined==%{}
  end

  @tag :b2
  test "B2 contested builds, occupancy, failed append and session fencing preserve balances", c do
    other=b2_actor(c,1002)
    b2_harvest(c,c.actor)
    b2_harvest(c,other)
    build=%{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 1,coord: {2,1,2},tool_id: 1,material: 19}
    {_,path}=:sys.get_state(c.w).log
    File.write!(path<>".reject","")
    assert {:error,:test_disk_failure}=World.production_intent(c.w,c.actor,build)
    assert World.seq(c.w)==10 and balance(c.w,1001).balance==512
    File.rm!(path<>".reject")
    next=%{build | request_id: 11,client_intent_seq: 11}
    tasks=for actor <- [c.actor,other],do: Task.async(fn -> {actor,World.production_intent(c.w,actor,next)} end)
    results=Enum.map(tasks,&Task.await(&1,10_000))
    {winner,{:ok,11}}=Enum.find(results,fn {_,r}->match?({:ok,_},r) end)
    {loser,{:error,:occupied}}=Enum.find(results,fn {_,r}->match?({:error,_},r) end)
    assert balance(c.w,winner.cid).balance==0
    assert balance(c.w,loser.cid).balance==512
    assert {:ok,12}=World.apply_edit(c.w,build.coord,0)
    assert {:ok,11}=World.production_intent(c.w,winner,next)
    assert World.seq(c.w)==12
    assert {:error,:replayed_build}=World.production_intent(c.w,winner,build)
    assert {:ok,13}=World.place_prefab(c.w,c.id,{16,8,16},0)
    assert {:error,:occupied}=World.production_intent(c.w,loser,%{next | client_intent_seq: 12})
    GenServer.call(loser.player,:seal)
    assert {:error,:invalid_state}=World.production_intent(c.w,loser,%{next | client_intent_seq: 13,coord: {3,1,2}})
    assert balance(c.w,loser.cid).balance==512
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.seq(w)==13
    assert balance(w,winner.cid).balance==0
    assert balance(w,loser.cid).balance==512
  end

  @tag :b2
  test "B2 failed lethal append neither credits wood nor destroys its remaining HP", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    for seq <- 1..3,do: assert({:ok,_}=b2_hit(c,c.actor,target,seq))
    {_,path}=:sys.get_state(c.w).log
    File.write!(path<>".reject","")
    assert {:error,:test_disk_failure}=b2_hit(c,c.actor,target,4)
    assert balance(c.w,1001).balance==0
    assert World.seq(c.w)==4
    assert {:ok,%{hp: 16.0,material: 19}}=World.tool_intent(c.w,c.actor,c.request)
    File.rm!(path<>".reject")
    assert {:ok,5}=b2_hit(c,c.actor,target,4)
    assert balance(c.w,1001).balance==512
  end

  @tag :b2
  test "B2 transfer keeps build dedup on the authenticated connection after old Player exits", c do
    b2_harvest(c,c.actor)
    build=%{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 1,coord: {2,1,2},tool_id: 1,material: 19}
    assert {:ok,6}=World.production_intent(c.w,c.actor,build)
    assert {:ok,7}=World.apply_edit(c.w,build.coord,0)
    transferred=%{c.actor | identity: :new_scene}
    player=start_supervised!(Supervisor.child_spec({Actor,transferred},id: :transferred))
    transferred=%{transferred | player: player}
    stop_supervised(Actor)
    b2_harvest(c,transferred)
    assert World.seq(c.w)==12 and balance(c.w,1001).balance==512
    assert {:ok,6}=World.production_intent(c.w,transferred,build)
    assert World.seq(c.w)==12 and balance(c.w,1001).balance==512
    assert {:ok,13}=World.production_intent(c.w,transferred,%{build | request_id: 11,client_intent_seq: 11,logical_scene_id: 2,coord: {3,1,2}})
    assert balance(c.w,1001).balance==0
  end

  @tag :b2
  test "B2 balance query uses authenticated cid before movement Ready; author bypasses stay closed", c do
    alias GateServer.Session.{Dispatch,Sink}
    state=%{status: :in_scene,voxim_overlay: true,cid: 1001,world_ref: c.w,
      sink: Sink.quic(self(),:session),builder: false}
    request=%{request_id: 1,client_intent_seq: 1,logical_scene_id: 1,action: 0,coord: {0,0,0},tool_id: 1}
    assert {:ok,^state}=Dispatch.handle({:voxel_production_intent,request},state)
    assert_receive {:mmo_voxel_bytes,:session,<<0x81,1::64,0::64,19::16,0::64,512::32>>}
    assert_receive {:mmo_voxel_bytes,:session,<<0x81,1::64,0::64,11::16,0::64,512::32>>}
    for kind <- [:voxel_edit_intent,:voxel_batch_edit_intent,:voxel_prefab_place_v1,
      :voxel_prefab_remove_v1,:voxel_prefab_replace_v1] do
      assert {:ok,^state}=Dispatch.handle({kind,request},state)
      assert_receive {:mmo_voxel_bytes,:session,bytes}
      assert :binary.match(bytes,"builder_permission_required") != :nomatch
    end
    assert World.seq(c.w)==0 and balance(c.w,1001).balance==0
  end

  test "HTTP materialization preserves reduced textures after editing an empty coarse region", c do
    assert {:ok,1}=World.apply_edits(c.w,[{{1,1,2},11},{{0,1,2},19}])
    expected=for {{level,cell},value} <- :sys.get_state(c.w).overlay,
      level in [1,2],into: %{},do: {{level,cell},value}
    assert Enum.any?(expected,fn {_,{_,{_,faces}}} ->
      Enum.any?(Tuple.to_list(faces),fn {_,texels} -> texels != nil end)
    end)
    items=for level <- [1,2],do: %{level: level,region: {0,0,0},have_seq: 0,have_hash: 0}
    request=Codec.encode_request(0,items)|>IO.iodata_to_binary()
    assert {:ok,reply}=World.serve(c.w,request)
    assert {:ok,123,payloads}=Codec.decode_reply(IO.iodata_to_binary(reply))
    for {:payload,level,region,bytes} <- payloads do
      assert {:ok,p}=Payload.decode(bytes)
      for {{^level,cell},value} <- expected do
        assert Payload.value(p,Payload.local(region,cell))==value
      end
    end
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert {:ok,replayed}=World.serve(w,request)
    assert IO.iodata_to_binary(replayed)==IO.iodata_to_binary(reply)
  end

  test "packed CSR records and value overrides produce identical complete bytes" do
    import Bitwise
    alias MmoContracts.Voxel.Skins
    ids = Enum.reduce(0..5,0,fn face,acc -> acc ||| ((face+1) <<< (face*8)) end)
    bare = %Payload{level: 1,region: {0,0,0},map_extent: 2,cells: :binary.copy(<<19::16-little>>,66*66*66)}
    for mask <- 0..63, uniform <- [false,true] do
      maps = for face <- 0..5, into: <<>>, do: if(uniform,do: :binary.copy(<<face+1>>,4),else: <<1,2,3,4>>)
      fmi = for face <- 0..5, (mask &&& (1 <<< face)) != 0, into: <<>>, do: <<face::16-little>>
      p = %{bare | records: %{{2,3,4}=>{ids,mask,0},{4,3,4}=>{ids,mask,0}},fmi: fmi,maps: maps}
      edits = %{{4,3,4}=>{19,Skins.uniform(19)},{1,3,4}=>{19,Payload.skins(p,{2,3,4},19)}}
      expected = Map.put(edits,{2,3,4},{19,Payload.skins(p,{2,3,4},19)})
      assert Payload.encode(p,edits,7,123) == Payload.encode(bare,expected,7,123)
    end
  end

  @tag :interaction_latency
  test "tool preparation only ensures regions not already decoded by the owner", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    drain = fn drain ->
      receive do {:prepared,_,_} -> drain.(drain) after 0 -> :ok end
    end
    drain.(drain)
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    assert target.hp==100.0
    assert_receive {:prepared,0,{-1,-1,-1}}
    refute_receive {:prepared,0,{0,0,0}}
    drain.(drain)
    assert {:ok,2}=attack(c.w,c.actor,c.request,target,1)
    for level <- 0..5 do
      refute_receive {:prepared,^level,{0,0,0}}
    end
    assert [%{property_states: [%{hp: 72.0}]}]=World.entries_after(c.w,1)
  end

  @tag :interaction_latency
  test "small sparse transaction never encodes a losing region candidate", c do
    assert {:ok,1}=World.apply_edits(c.w,[{{1,1,2},11}])
    assert {:ok,2}=World.apply_edits(c.w,[{{1,1,2},0}])
    items=for level <- 0..5, do: %{level: level,region: {0,0,0},have_seq: 0,have_hash: 0}
    assert {:ok,_}=World.serve(c.w,Codec.encode_request(0,items)|>IO.iodata_to_binary())
    w=c.w
    :erlang.trace_pattern({Payload,:encode,4},true,[])
    :erlang.trace(w,true,[:call])
    try do
      assert {:ok,3}=World.apply_edits(w,[{{1,1,2},11}])
      delivered=:erlang.trace_delivered(w)
      assert_receive {:trace_delivered,^w,^delivered}
      refute_received {:trace,^w,:call,{Payload,:encode,_}}
      [txn]=World.entries_after(w,2)
      assert [%{coord: {1,1,2},material: 11}]=txn.entries
      assert txn.coarse != []
    after
      :erlang.trace(w,false,[:call])
      :erlang.trace_pattern({Payload,:encode,4},false,[])
    end
  end

  test "payload lower bound matches the raw layout and large batches still choose full regions", c do
    empty=%Payload{cells: :binary.copy(<<0,0>>,Payload.extent()*Payload.extent()*Payload.extent())}
    bytes=Payload.encode(empty,%{},0,123)
    {:ok,_header,raw}=Codec.unpack_payload_body(bytes)
    assert byte_size(raw)==Payload.min_body_bytes()
    assert byte_size(bytes)>=Codec.payload_min_bytes()
    edits=for x <- 1..8,y <- 1..8,z <- 1..4,do: {{x,y,z},11}
    assert {:ok,1}=World.apply_edits(c.w,edits)
    [txn]=World.entries_after(c.w,0)
    assert Enum.any?(txn.entries,fn
      %{payload: bytes} -> {:ok,h}=Codec.decode_payload_header(bytes); h.level==0
      _ -> false
    end)
  end

  test "server ingress phase survives unequal authority work and does not grant extra arrivals", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
      |> Map.put(:action,1)
    received=System.monotonic_time(:microsecond)
    actor=Map.merge(c.actor,%{received_us: received-500_000,clock_node: node()})
    assert {:ok,2}=World.tool_intent(c.w,actor,request)
    actor=%{actor | received_us: received}
    assert {:ok,3}=World.tool_intent(c.w,actor,%{request | client_intent_seq: 2})
    assert {:error,:tool_cooldown}=World.tool_intent(c.w,actor,%{request | client_intent_seq: 3})
    assert {:error,:replayed_attack}=World.tool_intent(c.w,actor,%{request | client_intent_seq: 2})
  end

  test "macro damage is sparse with no geometry and replacement rejects the old target", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    assert t.hp==100.0 and t.granularity==0 and t.micro=={8,8,16}
    assert_receive {:prepared,0,{0,0,0}}
    assert {:ok,2}=attack(c.w,c.actor,c.request,t,1)
    assert [txn]=World.entries_after(c.w,1)
    assert txn.entries==[] and txn.coarse==[]
    assert [%{hp: 72.0}]=txn.property_states
    assert {:ok,t2}=World.tool_intent(c.w,c.actor,c.request)
    assert t2.hp==72.0 and t2.incarnation==t.incarnation
    assert {:error,:tool_cooldown}=attack(c.w,c.actor,c.request,t2,2)
    assert {:error,:replayed_attack}=attack(c.w,c.actor,c.request,t2,1)
    assert {:ok,3}=World.apply_edit(c.w,{1,1,2},0)
    assert {:ok,4}=World.apply_edit(c.w,{1,1,2},11)
    assert {:error,:stale_target}=attack(c.w,c.actor,c.request,t,3)
    assert {:ok,fresh}=World.tool_intent(c.w,c.actor,c.request)
    assert fresh.hp==100.0 and fresh.incarnation != t.incarnation
  end

  test "four real hits destroy macro, emit tombstone, and both canonical observers receive state", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    parent=self()
    observer=spawn(fn -> relay(parent) end)
    # Two existing canonical stream subscribers; empty chunk boxes avoid unrelated collision work.
    :sys.replace_state(c.w,fn s -> %{s | canonical_subs: %{parent=>{{0,0,0},{0,0,0}},observer=>{{0,0,0},{0,0,0}}}} end)
    for seq <- 1..4 do
      if seq>1,do: Process.sleep(510)
      assert {:ok,n}=attack(c.w,c.actor,c.request,t,seq)
      assert n==seq+1
    end
    assert {:error,:no_target}=World.tool_intent(c.w,c.actor,c.request)
    assert_receive {:canonical_delta,%{transaction: %{property_states: [%{hp: 72.0}]},chunks: []}}
    assert_receive {:canonical_delta,%{transaction: %{property_states: [%{flags: 1,hp: +0.0}]}}}
    assert_receive {:observer,{:canonical_delta,%{transaction: %{property_states: [%{hp: 72.0}]}}}}
    assert :sys.get_state(c.w).damage==%{}
    Process.exit(observer,:kill)
    # A legal catalog switch must not reject tombstoned historical damage during replay.
    File.write!(c.catalog," ",[:append])
    assert :ok=World.publish_properties(c.w,c.catalog)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.seq(w)==5
    assert :sys.get_state(w).damage==%{}
  end

  defp relay(parent) do
    receive do
      m -> send(parent,{:observer,m});relay(parent)
    end
  end

  test "lethal leaf damage removes its sibling material but preserves a separate occurrence", c do
    assert {:ok,1}=World.place_prefab(c.w,c.id,{8,8,16},0)
    assert {:ok,2}=World.place_prefab(c.w,c.id,{8,8,24},0)
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    assert t.granularity==2 and t.hp==200.0/512 and t.owner=={1,0}
    assert {:ok,3}=attack(c.w,c.actor,c.request,t,1)
    state=:sys.get_state(c.w)
    refute Map.has_key?(state.refined,{1,1,2})
    assert map_size(state.refined[{1,1,3}])==2
    assert {:ok,next}=World.tool_intent(c.w,c.actor,c.request)
    assert next.owner=={2,0} and next.hp==200.0/512
  end

  test "checkpoint and DB row replay preserve damage and incarnation with exact catalog version", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    assert {:ok,2}=attack(c.w,c.actor,c.request,t,1)
    assert :ok=World.compact(c.w)
    [checkpoint]=World.entries_after(c.w,0)
    assert [restored]=checkpoint |> OverlayLog.rows() |> OverlayLog.transactions()
    assert restored.property_states==checkpoint.property_states
    assert restored.epochs==checkpoint.epochs
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert {:ok,restored}=World.tool_intent(w,c.actor,c.request)
    assert restored.hp==72.0 and restored.incarnation==t.incarnation
    assert World.seq(w)==2
    assert :sys.get_state(w).damage |> map_size()==1
  end

  test "range, first obstruction and forged tool are rejected", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,8},11)
    assert {:error,:no_target}=World.tool_intent(c.w,c.actor,c.request)
    assert {:error,:invalid_tool}=World.tool_intent(c.w,c.actor,%{c.request | tool_id: 300})
    assert {:ok,2}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    assert t.material==19
    assert {:error,:stale_target}=attack(c.w,c.actor,c.request,%{t | material: 11},1)
    assert {:error,:stale_target}=attack(c.w,c.actor,c.request,%{t | owner: {999,0}},2)
  end
  test "stale captured player session and eye are rechecked at atomic admission", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    GenServer.call(c.actor.player,{:eye,{30.0,1.0625,0.0625}})
    assert {:error,:no_target}=attack(c.w,c.actor,c.request,t,1)
    GenServer.call(c.actor.player,:seal)
    assert {:error,:invalid_state}=attack(c.w,c.actor,c.request,t,2)
    assert World.seq(c.w)==1
  end

  test "failed refined lethal persistence leaves prior HP, occupancy and seq", c do
    assert {:ok,1}=full_component(c,{8,8,16})
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    for seq <- 1..3 do
      if seq>1,do: Process.sleep(510)
      assert {:ok,_}=attack(c.w,c.actor,c.request,t,seq)
    end
    {_,path}=:sys.get_state(c.w).log
    File.write!(path<>".reject","")
    Process.sleep(510)
    assert {:error,:test_disk_failure}=attack(c.w,c.actor,c.request,t,4)
    assert World.seq(c.w)==4
    assert {:ok,current}=World.tool_intent(c.w,c.actor,c.request)
    assert current.hp==16.0
    assert map_size(:sys.get_state(c.w).refined[{1,1,2}])==512
    assert balance(c.w,1001).balance==0 and balance(c.w,1001,11).balance==0
  end

  test "replica retains sparse live changes in the next join baseline", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    assert {:ok,2}=attack(c.w,c.actor,c.request,t,1)
    # Minimal region box uses the actual Replica upstream snapshot/subscription.
    replica=start_supervised!({VoxelRegion.Replica,[authority_ref: c.w,l0_box: {{0,0,0},{1,1,1}},name: nil]})
    assert :ok=VoxelRegion.Replica.canonical_snapshot_and_subscribe(replica,{{0,0,0},{1,1,1}},self(),:join,false)
    assert_receive {:canonical_snapshot,:join,%{property_states: [%{hp: 72.0}],transaction_seq: 2}}
    Process.sleep(510)
    assert {:ok,3}=attack(c.w,c.actor,c.request,t,2)
    assert_receive {:canonical_delta,%{transaction_seq: 3}}
    assert :ok=VoxelRegion.Replica.canonical_snapshot_and_subscribe(replica,{{0,0,0},{1,1,1}},self(),:again,false)
    assert_receive {:canonical_snapshot,:again,%{property_states: [%{hp: 44.0}],transaction_seq: 3}}
  end

  @tag :owner_queue
  test "tool admission survives an existing World callback queued longer than five seconds", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    :ok=:sys.suspend(c.w)
    parent=self()
    worker=spawn_monitor(fn -> send(parent,{:tool_reply,World.tool_intent(c.w,c.actor,c.request)}) end)
    balance_worker=spawn_monitor(fn -> send(parent,{:balance_reply,balance(c.w,1001)}) end)
    Process.sleep(5_100)
    :ok=:sys.resume(c.w)
    assert_receive {:tool_reply,{:ok,%{hp: 100.0}}},5_000
    assert_receive {:balance_reply,%{balance: 0}},5_000
    {_,balance_monitor}=balance_worker
    assert_receive {:DOWN,^balance_monitor,:process,_,:normal}
    {_,monitor}=worker
    assert_receive {:DOWN,^monitor,:process,_,:normal}
  end

  @tag :interaction_latency
  test "durable geometry append returns without a full-world checkpoint", c do
    assert {:ok,1}=World.place_prefab(c.w,c.id,{8,8,16},0)
    assert {:ok,2}=World.apply_edit(c.w,{1,1,3},11)
    {_,path}=:sys.get_state(c.w).log
    refute File.exists?(path<>".checkpoint_calls")
    # 最后一个 region 事务在回执前已追加，重启重放不依赖在线检查点。
    txns=OverlayLog.File.replay(path)
    assert List.last(txns).seq==2
    assert Enum.any?(List.last(txns).entries,&Map.has_key?(&1,:payload))
    # 完整 afterimage 已含相同 core 的地形和结构，不应再构造/发送重复的 coarse。
    covered = for %{payload: bytes} <- List.last(txns).entries,into: MapSet.new() do
      {:ok,h}=Codec.decode_payload_header(bytes)
      {h.level,h.region}
    end
    refute Enum.any?(List.last(txns).coarse,fn %{level: level,cell: cell} ->
      region=cell |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1,64)) |> List.to_tuple()
      MapSet.member?(covered,{level,region})
    end)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.seq(w)==2
    GenServer.call(c.actor.player,{:eye,{1.0625,1.0625,2.9}})
    assert {:ok,t}=World.tool_intent(w,c.actor,c.request)
    assert t.material==11
    assert :ok=World.compact(w)
    assert File.exists?(path<>".checkpoint_calls")
  end

  @tag :interaction_latency
  test "an HTTP batch yields authority admission between its natural region units", c do
    items=for r <- [{10,0,0},{11,0,0}],do: %{level: 0,region: r,have_seq: 0,have_hash: 0}
    request=Codec.encode_request(0,items) |> IO.iodata_to_binary()
    parent=self()
    reader=spawn_monitor(fn -> send(parent,{:regions_result,World.serve(c.w,request)}) end)
    assert_receive {:region_read_started,owner,{10,0,0}},5_000
    admission=:gen_server.send_request(c.w,{:tool_range,1})
    send(owner,:continue_region_read)
    result=:gen_server.receive_response(admission,200)
    # 红绿两次都先解除第二个 region 的阻塞，再断言。
    assert_receive {:region_read_started,^owner,{11,0,0}},5_000
    send(owner,:continue_region_read)
    assert result=={:reply,6.0}
    assert_receive {:regions_result,{:ok,bytes}},5_000
    assert {:ok,123,[{:payload,0,{10,0,0},_},{:payload,0,{11,0,0},_}]}=Codec.decode_reply(IO.iodata_to_binary(bytes))
    {_,monitor}=reader
    assert_receive {:DOWN,^monitor,:process,_,:normal}
  end

  @tag :interaction_latency
  test "uniform material byte updates preserve prefab suffix and replace nonuniform skins", c do
    assert {:ok,1}=World.place_prefab(c.w,c.id,{8,8,16},0)
    [%{entries: entries}]=World.entries_after(c.w,0)
    prior=Enum.find_value(entries,fn %{payload: bytes} ->
      {:ok,h}=Codec.decode_payload_header(bytes)
      if h.level==0 and h.region=={0,0,0},do: bytes
    end)
    {:ok,p}=Payload.decode(prior)
    overrides=%{{0,0,0}=>{11,MmoContracts.Voxel.Skins.uniform(11)},
      {65,65,65}=>{19,MmoContracts.Voxel.Skins.uniform(19)}}
    materials=Map.new(overrides,fn {local,{m,_}}->{local,m} end)
    expected=Payload.encode(p,overrides,2,123)
    actual=Payload.replace_uniform_cells(prior,materials,2,123)
    assert actual==expected
    {:ok,next}=Payload.decode(actual)
    assert next.refined==p.refined and next.instances==p.instances
    # 通用合法L0可能有CSR：覆盖该格须移除旧非均匀表皮，不能盲保留其记录。
    skins={1,{{19,nil},{11,nil},{11,nil},{11,nil},{11,nil},{11,nil}}}
    nonuniform=Payload.encode(p,%{{0,0,0}=>{11,skins}},1,123)
    {:ok,p}=Payload.decode(nonuniform)
    assert map_size(p.records)==1
    assert Payload.replace_uniform_cells(nonuniform,materials,2,123)==Payload.encode(p,overrides,2,123)
  end

  @tag :interaction_latency
  test "cached macro afterimages equal cold canonical materialization across region rings", c do
    assert {:ok,1}=World.place_prefab(c.w,c.id,{8,504,16},0)
    assert {:ok,2}=World.apply_edit(c.w,{1,63,3},11)
    assert {:ok,3}=World.apply_edit(c.w,{1,64,3},19)
    assert {:ok,4}=World.apply_edit(c.w,{1,63,3},0)
    [txn]=World.entries_after(c.w,3)
    # 包含选择器/Replica共用的热L0缓存，而不只检查事务中的粗层afterimage。
    expected = Map.new(:sys.get_state(c.w).payloads,fn {key,{bytes,_}} ->
      {key,Codec.stamp_payload_seq(bytes,4)}
    end)
    afterimages = for %{payload: bytes} <- txn.entries,into: %{} do
      {:ok,h}=Codec.decode_payload_header(bytes)
      {{h.level,h.region},bytes}
    end
    assert map_size(afterimages)>1
    expected=Map.merge(expected,afterimages)
    # 可丢弃缓存不得改变世界；强制冷物化须与增量构造逐字节相同。
    :sys.replace_state(c.w,fn s -> %{s | payloads: %{},lru: :gb_trees.empty(),lru_ticks: %{},
      lru_bytes: 0,resident_bytes: 0} end)
    for {{level,region},bytes} <- expected do
      request=Codec.encode_request(0,[%{level: level,region: region,have_seq: 0,have_hash: 0}])
        |> IO.iodata_to_binary()
      assert {:ok,reply}=World.serve(c.w,request)
      assert {:ok,_,[{:payload,^level,^region,^bytes}]}=Codec.decode_reply(IO.iodata_to_binary(reply))
    end
  end

  @tag :cadence
  test "one authoritative tick of early arrival borrows against the next interval", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    assert {:ok,2}=attack(c.w,c.actor,c.request,t,1)
    deadline=System.monotonic_time(:microsecond)+15_000
    :sys.replace_state(c.w,fn state ->
      update_in(state.tool_sessions[c.actor.player].next_us,fn _ -> deadline end)
    end)
    assert {:ok,3}=attack(c.w,c.actor,c.request,t,2)
    assert :sys.get_state(c.w).tool_sessions[c.actor.player].next_us==deadline+500_000
    assert {:error,:tool_cooldown}=attack(c.w,c.actor,c.request,t,3)
  end

  @tag :interaction_latency
  test "interleaved edits keep each region core and ring at its own payload sequence", c do
    items=for r <- [{10,0,0},{11,0,0}],do: %{level: 0,region: r,have_seq: 0,have_hash: 0}
    request=Codec.encode_request(0,items) |> IO.iodata_to_binary()
    parent=self()
    spawn_link(fn -> send(parent,{:regions_result,World.serve(c.w,request)}) end)
    assert_receive {:region_read_started,owner,{10,0,0}},5_000
    mutation=:gen_server.send_request(c.w,{:apply_edits,[{{703,1,1},11},{{704,1,1},19}]})
    send(owner,:continue_region_read)
    assert_receive {:region_read_started,^owner,{11,0,0}},5_000
    send(owner,:continue_region_read)
    assert {:reply,{:ok,1}}=:gen_server.receive_response(mutation,5_000)
    assert_receive {:regions_result,{:ok,bytes}},5_000
    assert {:ok,123,[{:payload,0,{10,0,0},left},{:payload,0,{11,0,0},right}]}=Codec.decode_reply(IO.iodata_to_binary(bytes))
    assert {:ok,l}=Payload.decode(left)
    assert {:ok,r}=Payload.decode(right)
    assert {:ok,%{seq: 0}}=Codec.decode_payload_header(left)
    assert {:ok,%{seq: 1}}=Codec.decode_payload_header(right)
    assert Payload.material(l,Payload.local({10,0,0},{703,1,1}))==0
    assert Payload.material(l,Payload.local({10,0,0},{704,1,1}))==0
    assert Payload.material(r,Payload.local({11,0,0},{703,1,1}))==11
    assert Payload.material(r,Payload.local({11,0,0},{704,1,1}))==19
    # cv 是基线标识，不冒充批次快照序号；同一个 region 的 core/ring 不拆开。
    assert {:ok,empty}=World.serve(c.w,Codec.encode_request(123,[]) |> IO.iodata_to_binary())
    assert {:ok,123,[]}=Codec.decode_reply(IO.iodata_to_binary(empty))
  end

end
