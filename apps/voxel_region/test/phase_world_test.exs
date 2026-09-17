defmodule VoxelRegion.PhaseWorldTest do
  @moduledoc "Test-only: phase uses real tool, thermal, quantity, collision and journal seams."
  use ExUnit.Case, async: false
  @moduletag :b7
  alias VoxelRegion.{World,Phase,Damage,CollisionSource}
  alias VoxelRegion.DamageWorldTest.{Source,Actor,Log}
  @capacity 2_097_152
  @quarter div(@capacity,4)

  setup do
    root=Path.join(System.tmp_dir!(),"b7_phase_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    catalog=Path.join(root,"catalog.json")
    data=Jason.decode!(File.read!("Content/Voxel/Properties/Published/ade8e630274214b6d9abba77286d8a5d8625d485bd6018e92a9bf0a43d3231ba.json"))
    materials=Enum.map(data["materials"],fn m->
      if m["material_id"] in [20,21],do: Map.merge(m,%{
        "phase_peer_material_id"=>if(m["material_id"]==20,do: 21,else: 20),
        "phase_transition_kelvin"=>273.15,"latent_heat_per_macro_j"=>334_000_000.0,
        "heat_capacity_per_macro"=>if(m["material_id"]==20,do: 1_930_000.0,else: 4_180_000.0),
        "thermal_conductivity"=>if(m["material_id"]==20,do: 2.2,else: 0.6),"heat_resistance_kelvin"=>1_000_000.0}),else: m
    end)
    tools=for {id,action} <- [{11,"liquid.scoop"},{12,"liquid.pour"},{13,"phase.cool"},{14,"phase.heat"}],do:
      %{"tool_id"=>id,"id"=>action,"action"=>action,"power"=>1,"range_macro"=>8,"interval_seconds"=>0.1,
        "liquid_transfer_units"=>@quarter,"fuel_material_id"=>15,"fuel_units"=>1,
        "cooling_energy_j"=>60_000_000.0,"heat_energy_j"=>1_000_000_000.0}
    data=data |> Map.put("materials",materials) |> Map.update!("tools",&(&1++tools))
      |> Map.update!("tags",&(&1++Enum.map(tools,fn t->%{"id"=>t["action"]} end)))
      |> Map.put("liquid",%{"step_seconds"=>3600,"gravity_units_per_step"=>@quarter,"side_units_per_step"=>div(@capacity,16)})
    File.write!(catalog,Jason.encode!(data))
    environment=Path.join(root,"environment.json")
    File.write!(environment,Jason.encode!(%{ambient_kelvin: 293.15,environment_w_per_m2_k: 0.0,tolerance_kelvin: 0.00001}))
    prefab=Path.join(root,"prefabs"); File.mkdir_p!(prefab)
    opts=[source: Source,log: Log,root: root,observer: self(),property_catalog_path: catalog,
      thermal_environment_path: environment,prefab_catalog_path: prefab,name: nil,
      production_materials: [15,20,21],liquid_bounds: {{62,0,1},{66,4,4}}]
    w=start_supervised!({World,opts})
    actor=%{cid: 1001,gate: self(),identity: :b7phase,refresh: &Actor.tool_context/2,eye: {63.5,1.0625,0.5},tick_us: 16_667}
    actor=Map.put(actor,:player,start_supervised!({Actor,actor}))
    :sys.replace_state(w,&%{&1 | material_balances: %{{1001,21}=>@capacity,{1001,15}=>1000}})
    on_exit(fn->File.rm_rf!(root) end)
    %{w: w,opts: opts,actor: actor,root: root,catalog: catalog}
  end

  defp transfer(c,action,seq,cell) do
    World.production_intent(c.w,Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()}),
      %{request_id: seq,client_intent_seq: seq,logical_scene_id: 1,action: action,material: 21,
        tool_id: if(action==2,do: 11,else: 12),coord: cell})
  end
  defp row(w,cell),do: Enum.find(Map.values(:sys.get_state(w).damage),&(Damage.macro(&1)==cell))
  defp operate(c,tool,seq,cell \\ {63,1,2},action \\ 1) do
    eye=:sys.get_state(c.actor.player).eye
    delta=Enum.zip_with(Tuple.to_list(cell),Tuple.to_list(eye),&(&1+0.0625-&2))
    length=:math.sqrt(Enum.sum(Enum.map(delta,&(&1*&1))))
    direction=delta |> Enum.map(&(&1/length)) |> List.to_tuple()
    query=%{request_id: seq,client_intent_seq: seq,logical_scene_id: 1,action: 0,
      tool_id: tool,direction: direction,micro: {0,0,0},granularity: 0,incarnation: 0,owner: {0,0},material: 0}
    {:ok,t}=World.tool_intent(c.w,c.actor,query)
    request=Map.take(t,[:micro,:granularity,:incarnation,:owner,:material])
      |> Map.merge(%{request_id: seq,client_intent_seq: seq,logical_scene_id: 1,action: action,tool_id: tool,direction: direction})
    World.tool_intent(c.w,Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()}),request)
  end
  defp total(w),do: (s=:sys.get_state(w); Enum.sum(Map.values(s.liquid_units))+
    Map.get(s.material_balances,{1001,21},0)+Map.get(s.material_balances,{1001,20},0))
  defp freeze(c,seq,cell \\ {63,1,2}) do
    assert {:ok,_}=operate(c,13,seq,cell)
    assert {:ok,_}=operate(c,13,seq+1,cell)
    assert row(c.w,cell).material==20
  end

  test "paid partial latent interval, exact quantity, Ice collision and cold phase recovery",c do
    assert {:ok,_}=transfer(c,3,1,{63,1,2})
    initial=row(c.w,{63,1,2}).phase_energy_j
    assert_in_delta initial,104_400_000.0,0.001
    assert :ok=World.canonical_snapshot_and_subscribe(c.w,{{0,0,0},{2,1,1}},self(),:phase,false)
    assert_receive {:canonical_snapshot,:phase,_}
    assert {:ok,_}=operate(c,13,2)
    water=row(c.w,{63,1,2})
    assert water.material==21
    assert_in_delta water.temperature_kelvin,273.15,0.00001
    assert_in_delta water.phase_energy_j,44_400_000.0,0.001
    assert {:ok,_}=operate(c,13,3)
    frozen=:sys.get_state(c.w)
    ice=row(c.w,{63,1,2})
    assert ice.material==20 and ice.max_hp==25.0
    assert ice.phase_energy_j==0.0
    assert frozen.liquid_units==%{{63,1,2}=>@quarter}
    assert total(c.w)==@capacity
    assert_in_delta frozen.thermal.phase_paid_j,120_000_000.0,0.001
    assert_in_delta frozen.thermal.phase_unused_j,15_600_000.0,0.001
    assert_in_delta initial+frozen.thermal.phase_supplied_j,ice.phase_energy_j,0.001
    assert_receive {:canonical_delta,%{transaction_seq: seq,chunks: []}}
    assert seq==frozen.seq-1
    assert_receive {:canonical_delta,%{transaction_seq: seq,chunks: [chunk]}}
    assert seq==frozen.seq and chunk.n==128
    # x=63 => chunk-local15, y=1; exact .25m => two occupied micro layers.
    assert :binary.at(chunk.cells,120+128*(9+128*16))==1
    assert :binary.at(chunk.cells,120+128*(10+128*16))==0
    assert :ok=World.compact(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert :sys.get_state(w).liquid_units==frozen.liquid_units
    assert row(w,{63,1,2}).phase_energy_j==0.0
    assert row(w,{63,1,2}).hp==ice.hp
    assert total(w)==@capacity
    assert :ok=World.canonical_snapshot_and_subscribe(w,{{0,0,0},{1,1,1}},self(),:cold_phase,true)
    assert_receive {:canonical_snapshot,:cold_phase,cold}
    assert Enum.find(cold.chunks,&(&1.coord==chunk.coord)).cells==chunk.cells
  end

  test "damage survives melt, scoop, cold carried recovery, cross-region pour and refreeze",c do
    assert {:ok,_}=transfer(c,3,1,{63,1,2})
    freeze(c,2)
    assert {:ok,_}=operate(c,1,4)
    damaged=row(c.w,{63,1,2})
    ratio=damaged.hp/damaged.max_hp
    assert ratio>0 and ratio<1
    assert {:ok,_}=operate(c,14,5)
    assert_in_delta row(c.w,{63,1,2}).hp/25,ratio,1.0e-9
    assert {:ok,_}=transfer(c,2,6,{63,1,2})
    saved=:sys.get_state(c.w)
    assert saved.liquid_units==%{}
    assert total(c.w)==@capacity
    publication=File.read!(c.catalog)
    changed=Jason.decode!(publication) |> Map.update!("materials",fn ms->
      Enum.map(ms,fn m->if m["material_id"] in [20,21],do: Map.put(m,"latent_heat_per_macro_j",1.0),else: m end)
    end)
    File.write!(c.catalog,Jason.encode!(changed))
    assert {:error,:property_version_in_use}=World.publish_properties(c.w,c.catalog)
    File.write!(c.catalog,publication)
    assert :ok=World.compact(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    c=%{c | w: w}
    assert :sys.get_state(w).phase_inventory==saved.phase_inventory
    # Carried original pristine water mixes by amount, with damage debt conserved.
    expected=(0.75+ratio*0.25)
    assert {:ok,_}=transfer(c,3,7,{64,1,2})
    freeze(c,8,{64,1,2})
    assert_in_delta row(w,{64,1,2}).hp/25,expected,1.0e-9
    assert total(w)==@capacity
    assert {:error,:use_liquid_tool}=World.apply_edit(w,{64,1,2},0)
  end

  test "flow transports energy and integrity even when a cell has equal inflow/outflow",c do
    assert {:ok,_}=transfer(c,3,1,{63,2,2})
    assert {:ok,_}=transfer(c,3,2,{64,2,2})
    before=:sys.get_state(c.w)
    energy=Enum.sum(for {_,r}<-before.damage,do: r.phase_energy_j)
    send(c.w,:liquid_commit)
    after_step=:sys.get_state(c.w)
    assert after_step.liquid_units[{63,1,2}]>0 and after_step.liquid_units[{64,1,2}]>0
    assert_in_delta Enum.sum(for {_,r}<-after_step.damage,do: r.phase_energy_j),energy,0.001
    assert total(c.w)==@capacity
    # Actual synchronous flux API used by World, with a balanced intermediate cell.
    q=%{a: 10,b: 10,c: 10}; values=%{a: {100.0,10.0},b: {0.0,5.0},c: {50.0,10.0}}
    next=Phase.transport(values,q,[{:a,:b,5},{:b,:c,5}])
    assert next.b=={50.0,7.5}
    assert_in_delta Enum.sum(for {_,{e,_}}<-next,do: e),150.0,1.0e-9
    assert_in_delta Enum.sum(for {_,{_,i}}<-next,do: i),25.0,1.0e-9
  end

  test "conservative collision rounds only the top micro layer and leaves quantity exact" do
    q=div(@capacity,3)
    slots=CollisionSource.phase_slots(20,%{},q,@capacity)
    layers=Enum.count(slots,fn {_,{m,_}}->m==20 end)/64
    assert layers==3
    assert layers/8>=q/@capacity and layers/8-q/@capacity<1/8
  end

  test "balanced flow commits changed thermal carrier without quantity/identity change",c do
    for y<-1..3,do: assert({:ok,_}=transfer(c,3,y,{63,y,2}))
    walls=for x<-62..64,y<-0..3,z<-1..3, y==0 or x != 63 or z != 2,do: {{x,y,z},11}
    assert {:ok,_}=World.apply_edits(c.w,walls)
    :sys.replace_state(c.w,fn s->
      r=Enum.find(Map.values(s.damage),&(Damage.macro(&1)=={63,2,2}))
      r=%{r | phase_energy_j: 50_000_000.0,temperature_kelvin: 273.15,hp: 12.5}
      %{s | damage: Map.put(s.damage,Damage.key(r),r)}
    end)
    mid=row(c.w,{63,2,2}); source=row(c.w,{63,3,2})
    send(c.w,:liquid_commit)
    next=:sys.get_state(c.w)
    assert next.liquid_units[{63,2,2}]==@quarter
    current=row(c.w,{63,2,2})
    assert current.incarnation==mid.incarnation
    assert_in_delta current.phase_energy_j,source.phase_energy_j,0.001
    assert current.hp==source.hp
    assert current.seq>mid.seq
    assert total(c.w)==@capacity
  end

  test "occupied catalog upgrade preserves legacy Ice damage; mining and rebuilding carries exact mass/HP/energy",c do
    phase_bytes=File.read!(c.catalog)
    legacy=Jason.decode!(phase_bytes) |> Map.update!("materials",fn materials->
      Enum.map(materials,&Map.drop(&1,~w(phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j)))
    end)
    File.write!(c.catalog,Jason.encode!(legacy))
    assert :ok=World.publish_properties(c.w,c.catalog)
    assert {:ok,_}=World.apply_edit(c.w,{63,1,2},20)
    assert {:ok,_}=operate(c,1,1)
    old=row(c.w,{63,1,2})
    assert old.hp<old.max_hp
    assert :sys.get_state(c.w).liquid_units==%{}
    File.write!(c.catalog,phase_bytes)
    assert :ok=World.publish_properties(c.w,c.catalog)
    published=row(c.w,{63,1,2})
    assert published.hp==old.hp and published.temperature_kelvin==old.temperature_kelvin
    assert published.digest != old.digest
    assert {:ok,_}=operate(c,1,2,{63,1,2},2)
    mined=:sys.get_state(c.w)
    assert mined.material_balances[{1001,20}]==@capacity
    assert mined.liquid_units==%{}
    {energy,integrity}=mined.phase_inventory[{1001,20}]
    assert integrity<@capacity
    build=%{request_id: 3,client_intent_seq: 3,logical_scene_id: 1,action: 1,
      material: 20,tool_id: 1,coord: {64,1,2}}
    assert {:ok,_}=World.production_intent(c.w,c.actor,build)
    rebuilt=row(c.w,{64,1,2})
    assert rebuilt.material==20 and rebuilt.max_hp==100.0
    assert_in_delta rebuilt.hp/100.0,integrity/@capacity,1.0e-9
    assert rebuilt.phase_energy_j==energy
    assert :sys.get_state(c.w).material_balances[{1001,20}]==0
    assert :sys.get_state(c.w).liquid_units==%{{64,1,2}=>@capacity}
    # Once used, published latent heat cannot silently reinterpret stored energy.
    changed=Jason.decode!(phase_bytes) |> Map.update!("materials",fn ms->
      Enum.map(ms,fn m->if m["material_id"] in [20,21],do: Map.put(m,"latent_heat_per_macro_j",1.0),else: m end)
    end)
    File.write!(c.catalog,Jason.encode!(changed))
    assert {:error,:property_version_in_use}=World.publish_properties(c.w,c.catalog)
  end

  test "failed paid phase append rolls back energy, fuel, quantity, identity and HP",c do
    assert {:ok,_}=transfer(c,3,1,{63,1,2})
    before=:sys.get_state(c.w)
    {_,path}=before.log
    File.write!(path<>".reject","")
    assert {:error,:test_disk_failure}=operate(c,13,2)
    after_failure=:sys.get_state(c.w)
    for key<-[:seq,:liquid_units,:damage,:thermal,:material_balances,:phase_inventory,:epochs],
      do: assert(Map.fetch!(before,key)==Map.fetch!(after_failure,key))
  end

  test "fully broken Ice stays finite carried fragments and cannot build a zero-HP collider",c do
    assert {:ok,_}=transfer(c,3,1,{63,1,2})
    freeze(c,2)
    Enum.reduce_while(4..30,nil,fn seq,_ ->
      if row(c.w,{63,1,2})==nil,do: {:halt,nil},else: (assert {:ok,_}=operate(c,1,seq); {:cont,nil})
    end)
    s=:sys.get_state(c.w)
    assert s.liquid_units==%{}
    assert s.material_balances[{1001,20}]==@quarter
    assert elem(s.phase_inventory[{1001,20}],1)==0.0
    # Test-only combine four equal fragments, preserving their actual carried fields.
    :sys.replace_state(c.w,fn s->%{s | material_balances: Map.put(s.material_balances,{1001,20},@capacity),
      phase_inventory: Map.update!(s.phase_inventory,{1001,20},&Phase.scale(&1,4))} end)
    before=:sys.get_state(c.w)
    build=%{request_id: 40,client_intent_seq: 40,logical_scene_id: 1,action: 1,material: 20,tool_id: 1,coord: {64,1,2}}
    assert {:error,:broken_material}=World.production_intent(c.w,c.actor,build)
    after_reject=:sys.get_state(c.w)
    assert after_reject.material_balances==before.material_balances
    assert after_reject.phase_inventory==before.phase_inventory
    assert after_reject.liquid_units==%{}
  end

  test "real thin-water mining seam skips water for stone and phase ray uses exact height",c do
    :sys.replace_state(c.w,fn s->%{s | material_balances: Map.put(s.material_balances,{1001,21},28)} end)
    assert {:ok,_}=World.apply_edit(c.w,{63,1,2},11)
    assert {:ok,_}=transfer(c,3,1,{63,2,2})
    :ok=GenServer.call(c.actor.player,{:eye,{63.5,3.5,2.5}})
    query=%{request_id: 2,client_intent_seq: 2,logical_scene_id: 1,action: 0,tool_id: 1,
      direction: {0.0,-1.0,0.0},micro: {504,8,16},granularity: 0,incarnation: 0,owner: {0,0},material: 11}
    assert {:ok,stone}=World.tool_intent(c.w,c.actor,query)
    assert stone.material==11
    attack=Map.merge(query,Map.take(stone,[:micro,:granularity,:incarnation,:owner,:material])) |> Map.put(:action,1)
    assert {:ok,_}=World.tool_intent(c.w,Map.merge(c.actor,%{received_us: 2_000_000,clock_node: node()}),attack)
    assert row(c.w,{63,1,2}).hp<stone.hp
    :ok=GenServer.call(c.actor.player,{:eye,{62.5,2.0625,2.5}})
    phase=%{query | tool_id: 13,material: 21,direction: {1.0,0.0,0.0}}
    assert {:error,:no_target}=World.tool_intent(c.w,c.actor,phase)
    :ok=GenServer.call(c.actor.player,{:eye,{62.5,2.0+14/@capacity,2.5}})
    assert {:ok,water}=World.tool_intent(c.w,c.actor,phase)
    freeze=Map.merge(phase,Map.take(water,[:micro,:granularity,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 1,request_id: 3,client_intent_seq: 3})
    assert {:ok,_}=World.tool_intent(c.w,Map.merge(c.actor,%{received_us: 3_000_000,clock_node: node()}),freeze)
    assert row(c.w,{63,2,2}).material==20
    :ok=GenServer.call(c.actor.player,{:eye,{62.5,2.0625,2.5}})
    assert {:error,:no_target}=World.tool_intent(c.w,c.actor,%{phase | tool_id: 1,material: 20})
  end

  @tag :native_phase
  test "existing native thermal ambient exchange fills latent interval then melts in one quantity transaction",c do
    assert {:ok,_}=transfer(c,3,1,{63,1,2})
    freeze(c,2)
    # Test-only remaining latent sliver lets an ordinary ambient heat tick finish
    # melting without changing production heat capacities or calling a phase tool.
    :sys.replace_state(c.w,fn s->
      r=Enum.find(Map.values(s.damage),&(Damage.macro(&1)=={63,1,2}))
      r=%{r | phase_energy_j: 83_500_000.0-1.0}
      %{s | damage: Map.put(s.damage,Damage.key(r),r),
        thermal: %{s.thermal | config: Map.put(s.thermal.config,"environment_w_per_m2_k",10.0)}}
    end)
    send(c.w,:thermal_commit)
    next=:sys.get_state(c.w)
    water=row(c.w,{63,1,2})
    assert water.material==21 and water.phase_energy_j>=83_500_000.0
    assert next.liquid_units==%{{63,1,2}=>@quarter}
    assert_in_delta water.phase_energy_j,83_500_000.0-1.0+next.thermal.environment_j,0.01
    assert total(c.w)==@capacity
  end
end
