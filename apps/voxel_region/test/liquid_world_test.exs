defmodule VoxelRegion.LiquidWorldTest do
  @moduledoc "Test-only: finite water through actual World requests, canonical transactions and replay."
  use ExUnit.Case, async: false
  @moduletag :b7
  alias VoxelRegion.World
  alias VoxelRegion.DamageWorldTest.{Source,Actor,Log}
  alias MmoContracts.Voxel.Payload
  @capacity 2_097_152
  @transfer div(@capacity,4)

  defmodule LegacySource do
    defdelegate open(opts),to: Source
    defdelegate content_version(s),to: Source
    defdelegate world_dir(s),to: Source
    defdelegate generated(s),to: Source
    defdelegate ensure(s,level,region),to: Source
    def read(s,level,region) do
      {:ok,bytes,_}=Source.read(s,level,region)
      {:ok,p}=Payload.decode(bytes)
      local=Payload.local(region,{63,1,2})
      overrides=if level==0 and Payload.in_span?(local),do: %{local=>{21,MmoContracts.Voxel.Skins.uniform(21)}},else: %{}
      bytes=Payload.encode(p,overrides,0,123)
      {:ok,h}=MmoContracts.Voxel.Codec.decode_payload_header(bytes)
      {:ok,bytes,h}
    end
  end

  setup context do
    root=Path.join(System.tmp_dir!(),"b7_world_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    catalog=Path.join(root,"catalog.json")
    data=Jason.decode!(File.read!("Content/Voxel/Properties/Published/ade8e630274214b6d9abba77286d8a5d8625d485bd6018e92a9bf0a43d3231ba.json"))
    # Test-only deterministic clock: steps are manually delivered; production uses the published cadence.
    tools=for {id,action} <- [{11,"liquid.scoop"},{12,"liquid.pour"}],do:
      %{"tool_id"=>id,"id"=>action,"action"=>action,"power"=>1,"range_macro"=>8,"interval_seconds"=>0.1,"liquid_transfer_units"=>@transfer}
    data=data |> Map.update!("tools",&(&1++tools)) |> Map.update!("tags",&(&1++Enum.map(tools,fn t->%{"id"=>t["action"]} end)))
      |> Map.put("liquid",%{"step_seconds"=>3600,"gravity_units_per_step"=>@transfer,"side_units_per_step"=>div(@capacity,16)})
    File.write!(catalog,Jason.encode!(data))
    prefab=Path.join(root,"prefabs"); File.mkdir_p!(prefab)
    opts=[source: if(context[:legacy_water],do: LegacySource,else: Source),log: Log,root: root,observer: self(),property_catalog_path: catalog,
      prefab_catalog_path: prefab,name: nil,production_materials: [19,21],liquid_bounds: {{62,0,1},{66,4,4}}]
    w=start_supervised!({World,opts})
    actor=%{cid: 1001,gate: self(),identity: :b7,refresh: &Actor.tool_context/2,eye: {63.5,1.5,0.5},tick_us: 16_667}
    actor=Map.put(actor,:player,start_supervised!({Actor,actor}))
    # Finite experimental inventory; the first real pour persists its debit in the normal journal.
    :sys.replace_state(w,&%{&1 | material_balances: %{{1001,21}=>@capacity}})
    on_exit(fn->File.rm_rf!(root) end)
    %{w: w,opts: opts,actor: actor,root: root}
  end

  defp request(action,seq,coord),do: %{request_id: seq,client_intent_seq: seq,logical_scene_id: 1,
    action: action,material: 21,tool_id: if(action==2,do: 11,else: 12),coord: coord}
  defp transfer(c,action,seq,coord),do: World.production_intent(c.w,
    Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()}),request(action,seq,coord))
  defp balance(w),do: Enum.find(World.material_balances(w,1001),&(&1.material==21)).balance
  defp quantities(w),do: :sys.get_state(w).liquid_units
  defp total(w),do: Enum.sum(Map.values(quantities(w)))+balance(w)
  defp tick(w),do: (send(w,:liquid_commit); :sys.get_state(w))

  test "pour and scoop preserve finite inventory, dedupe and quantity-only region/ring commits",c do
    assert {:ok,seq}=transfer(c,3,10,{63,1,2})
    assert quantities(c.w)==%{{63,1,2}=>@transfer}
    assert total(c.w)==@capacity
    assert {:ok,^seq}=transfer(c,3,10,{63,1,2})
    assert total(c.w)==@capacity
    assert quantities(c.w)==%{{63,1,2}=>@transfer}
    assert {:error,:replayed_build}=transfer(c,3,9,{64,1,2})
    assert :ok=World.canonical_snapshot_and_subscribe(c.w,{{0,0,0},{2,1,1}},self(),:before,false)
    assert_receive {:canonical_snapshot,:before,_}
    prior=:sys.get_state(c.w)
    assert {:ok,next_seq}=transfer(c,3,11,{63,1,2})
    assert next_seq==seq+1
    next=:sys.get_state(c.w)
    assert next.epochs==prior.epochs
    assert next.damage==prior.damage
    assert_receive {:canonical_delta,delta}
    assert delta.transaction_seq==next_seq
    assert delta.chunks==[]
    [txn]=World.entries_after(c.w,seq)
    for region <- [{0,0,0},{1,0,0}] do
      p=Enum.find_value(txn.entries,fn
        %{payload: bytes}->{:ok,p}=Payload.decode(bytes); if p.level==0 and p.region==region,do: p
        _->nil
      end)
      assert p != nil
      assert p.liquid_units[Payload.cell_index(Payload.local(region,{63,1,2}))]==2*@transfer
    end
    assert {:ok,_}=transfer(c,2,12,{63,1,2})
    assert quantities(c.w)[{63,1,2}]==@transfer
    assert total(c.w)==@capacity
    assert :ok=World.compact(c.w)
    saved=quantities(c.w); saved_balance=balance(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert quantities(w)==saved
    assert balance(w)==saved_balance
    assert total(w)==@capacity
  end

  @tag :legacy_water
  test "legacy unsuffixed Water is a full finite macro, including a cold ring snapshot",c do
    assert quantities(c.w)==%{{63,1,2}=>@capacity}
    assert {:ok,_}=transfer(c,2,1,{63,1,2})
    assert quantities(c.w)==%{{63,1,2}=>@capacity-@transfer}
    assert total(c.w)==2*@capacity
    assert :ok=World.canonical_snapshot_and_subscribe(c.w,{{1,0,0},{2,1,1}},self(),:warm,false)
    assert_receive {:canonical_snapshot,:warm,warm}
    :sys.replace_state(c.w,fn s->%{s | payloads: %{},lru: :gb_trees.empty(),lru_ticks: %{},lru_bytes: 0,resident_bytes: 0,decoded: %{}} end)
    assert :ok=World.canonical_snapshot_and_subscribe(c.w,{{1,0,0},{2,1,1}},self(),:cold,false)
    assert_receive {:canonical_snapshot,:cold,cold}
    assert cold.regions==warm.regions
    [{{1,0,0},bytes}]=cold.regions
    {:ok,p}=Payload.decode(bytes)
    assert p.liquid_units[Payload.cell_index(Payload.local({1,0,0},{63,1,2}))]==@capacity-@transfer
    assert {:ok,_}=transfer(c,3,2,{63,1,2})
    assert quantities(c.w)==%{{63,1,2}=>@capacity}
    assert {:error,:no_liquid_transfer}=transfer(c,3,3,{63,1,2})
    assert total(c.w)==2*@capacity
  end

  @tag :legacy_water
  test "admitted legacy source flows immediately and never refills emptied source after replay",c do
    # This fixture supplies world water only, with no initial carried inventory.
    :sys.replace_state(c.w,&%{&1 | material_balances: %{}})
    assert quantities(c.w)==%{{63,1,2}=>@capacity}
    for n<-1..4, do: assert({:ok,_}=transfer(c,2,n,{63,1,2}))
    assert quantities(c.w)==%{}
    assert balance(c.w)==@capacity
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert quantities(w)==%{}
    assert balance(w)==@capacity
    tick(w)
    assert quantities(w)==%{}
    assert total(w)==@capacity
  end

  test "gravity and cross-region lateral flow conserve every quantum; walls contain then leak",c do
    # A one-cell-wide channel spans owner cores63/64; closed experimental boundaries are explicit.
    walls=for x<-62..65,y<-0..2,z<-1..3, y==0 or z != 2 or x in [62,65],do: {{x,y,z},19}
    assert {:ok,_}=World.apply_edits(c.w,walls)
    :ok=GenServer.call(c.actor.player,{:eye,{63.5,3.5,2.5}})
    assert {:ok,_}=transfer(c,3,1,{63,2,2})
    tick(c.w)
    assert quantities(c.w)[{63,1,2}]>0
    assert quantities(c.w)[{64,1,2}]>0
    assert total(c.w)==@capacity
    assert Enum.all?(quantities(c.w),fn {{x,y,z},_}->x in [63,64] and y>=1 and z==2 end)
    assert {:ok,_}=World.apply_edit(c.w,{64,0,2},0)
    tick(c.w)
    assert quantities(c.w)[{64,0,2}]>0
    assert total(c.w)==@capacity
    saved=quantities(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert quantities(w)==saved
    assert total(w)==@capacity
  end

  test "MCP-authored Test-only two-cubic-metre supply installs atomically and flows without a player pour",c do
    :sys.replace_state(c.w,&%{&1 | material_balances: %{}})
    fixture=Path.join(c.root,"basin.json")
    rows=for {coord,m} <- [{{63,2,2},21},{{64,2,2},21},{{63,0,2},11},{{64,0,2},11}],
      do: %{macro: Tuple.to_list(coord),material: m}
    File.write!(fixture,Jason.encode!(%{classification: "Test-only",deposits: rows}))
    assert {:ok,1}=World.liquid_experiment(c.w,fixture)
    assert quantities(c.w)==%{{63,2,2}=>@capacity,{64,2,2}=>@capacity}
    tick(c.w)
    assert quantities(c.w)[{63,1,2}]>0
    assert total(c.w)==2*@capacity
    saved=quantities(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert quantities(w)==saved
    assert total(w)==2*@capacity
  end

  test "journal failure rolls back both quantities and balance; raw water edit/build cannot duplicate",c do
    assert {:ok,_}=transfer(c,3,1,{63,1,2})
    before=:sys.get_state(c.w)
    {_,path}=before.log
    File.write!(path<>".reject","")
    assert {:error,:test_disk_failure}=transfer(c,2,2,{63,1,2})
    assert Map.take(:sys.get_state(c.w),[:seq,:liquid_units,:material_balances])==Map.take(before,[:seq,:liquid_units,:material_balances])
    File.rm!(path<>".reject")
    assert {:error,:use_liquid_tool}=World.apply_edit(c.w,{63,1,2},0)
    assert {:error,:use_liquid_tool}=World.apply_edits(c.w,[{{64,1,2},21}])
    assert {:error,:unknown_resource}=World.production_intent(c.w,c.actor,request(1,3,{64,1,2}))
    assert {:error,:invalid_liquid_operation}=transfer(c,3,4,{66,1,2})
    assert total(c.w)==@capacity
    # A regular pickaxe must not credit a full macro for partial Water21.
    :ok=GenServer.call(c.actor.player,{:eye,{63.5,1.0625,0.5}})
    query=%{request_id: 8,client_intent_seq: 8,logical_scene_id: 1,action: 0,granularity: 0,
      direction: {0.0,0.0,1.0},micro: {0,0,0},incarnation: 0,owner: {0,0},material: 21,tool_id: 1}
    {:ok,target}=World.tool_intent(c.w,c.actor,query)
    attack=Map.merge(query,Map.take(target,[:micro,:granularity,:incarnation,:owner,:material])) |> Map.put(:action,1)
    assert {:error,:use_liquid_tool}=World.tool_intent(c.w,Map.merge(c.actor,%{received_us: 1000000,clock_node: node()}),attack)
    assert total(c.w)==@capacity
  end

  test "solid sight, refreshed position, tool cooldown and duplicate closure are authority checked",c do
    assert {:ok,_}=World.apply_edit(c.w,{63,1,1},11)
    assert {:error,:occluded_liquid}=transfer(c,3,1,{63,1,2})
    assert quantities(c.w)==%{}
    assert {:ok,_}=World.apply_edit(c.w,{63,1,1},0)
    assert {:ok,seq}=transfer(c,3,2,{63,1,2})
    fast_actor=Map.merge(c.actor,%{received_us: 2_000_001,clock_node: node()})
    assert {:ok,^seq}=World.production_intent(c.w,fast_actor,request(3,2,{63,1,2}))
    assert {:error,:tool_cooldown}=World.production_intent(c.w,fast_actor,request(2,3,{63,1,2}))
    assert quantities(c.w)==%{{63,1,2}=>@transfer}
    assert {:ok,_}=World.apply_edit(c.w,{63,1,1},11)
    assert {:error,:occluded_liquid}=transfer(c,2,4,{63,1,2})
    :ok=GenServer.call(c.actor.player,{:eye,{63.5,3.5,2.5}})
    assert {:ok,_}=transfer(c,2,5,{63,1,2})
    assert quantities(c.w)==%{}
    assert total(c.w)==@capacity
  end
end
