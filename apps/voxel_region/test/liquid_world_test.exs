defmodule VoxelRegion.LiquidWorldTest do
  @moduledoc "Test-only: finite water through actual World requests, canonical transactions and replay."
  use ExUnit.Case, async: false
  @moduletag :b7
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source,Actor,Log}
  alias MmoContracts.Voxel.Payload
  @capacity 2_097_152
  @transfer div(@capacity,4)

  defmodule LegacySource do
    def open(opts) do
      {:ok,s}=Source.open(opts)
      {:ok,Map.put(s,:missing,Keyword.get(opts,:missing,false))}
    end
    defdelegate content_version(s),to: Source
    defdelegate world_dir(s),to: Source
    defdelegate generated(s),to: Source
    defdelegate ensure(s,level,region),to: Source
    def read(%{missing: true},0,{1,0,0}),do: {:error,:missing}
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
    if context[:database], do: MmoTest.Database.start!()
    root=Path.join(System.tmp_dir!(),"b7_world_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    catalog=Path.join(root,"catalog.json")
    data=Jason.decode!(File.read!(VoxelRegion.TestSupport.catalog()))
    # Test-only deterministic clock: steps are manually delivered; production uses the published cadence.
    tools=for {id,action} <- [{11,"liquid.scoop"},{12,"liquid.pour"}],do:
      %{"tool_id"=>id,"id"=>action,"action"=>action,"power"=>1,"range_macro"=>8,"interval_seconds"=>0.1,"liquid_transfer_units"=>@transfer}
    data=data |> Map.update!("tools",&(&1++tools)) |> Map.update!("tags",&(&1++Enum.map(tools,fn t->%{"id"=>t["action"]} end)))
      |> Map.put("liquid",%{"step_seconds"=>context[:cadence] || 3600,"gravity_units_per_step"=>@transfer,"side_units_per_step"=>div(@capacity,16),"side_threshold_units"=>context[:head] || 0})
    File.write!(catalog,Jason.encode!(data))
    prefab=Path.join(root,"prefabs"); File.mkdir_p!(prefab)
    opts=[source: if(context[:legacy_water],do: LegacySource,else: Source),missing: context[:missing] || false,log: if(context[:database], do: VoxelRegion.OverlayLog.Db, else: Log),root: root,observer: self(),property_catalog_path: catalog,
      prefab_catalog_path: prefab,name: nil,production_materials: [19,21],liquid_bounds: context[:bounds] || {{62,0,1},{66,4,4}}]
    w=start_supervised!({World,opts})
    actor=%{cid: 1001,gate: self(),identity: :b7,refresh: &Actor.tool_context/2,eye: {63.5,1.5,0.5},tick_us: 16_667}
    actor=Map.put(actor,:player,start_supervised!({Actor,actor}))
    unless context[:empty_inventory] do
      # 只测试：作者放置一格有限水源，独立会话正常舀取；余额和后续冷恢复都走正式日志。
      supply=Path.join(root,"inventory-source.json")
      File.write!(supply,Jason.encode!(%{classification: "Test-only",
        deposits: [%{macro: [65,1,3],material: 21}]}))
      {:ok,_}=World.liquid_experiment(w,supply)
      gate=spawn_link(fn -> receive do :stop -> :ok end end)
      supplier=%{actor | gate: gate,identity: :supply,eye: {65.5,1.5,1.5}}
      {:ok,player}=Actor.start_link(supplier)
      supplier=%{supplier | player: player}
      for seq<-1..4 do
        {:ok,_}=World.production_intent(w,
          Map.merge(supplier,%{received_us: seq*1_000_000,clock_node: node()}),request(2,seq,{65,1,3}))
      end
      GenServer.stop(player)
      send(gate,:stop)
    end
    on_exit(fn->File.rm_rf!(root) end)
    %{w: w,opts: opts,actor: actor,root: root}
  end

  defp request(action,seq,coord),do: %{request_id: seq,client_intent_seq: seq,logical_scene_id: 1,
    action: action,material: 21,tool_id: if(action==2,do: 11,else: 12),coord: coord}
  defp transfer(c,action,seq,coord),do: World.production_intent(c.w,
    Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()}),request(action,seq,coord))
  defp balance(w),do: Enum.find(World.material_balances(w,1001),&(&1.material==21)).balance
  defp quantities(w),do: World.simulation_snapshot(w,[1001],{{0,0,0},{2,1,1}}).liquid_quantities
  defp total(w),do: Enum.sum(Map.values(quantities(w)))+balance(w)
  defp tick(w),do: (send(w,:liquid_commit); World.seq(w))

  @tag :empty_inventory
  @tag head: @capacity
  @tag :database
  test "committed falling frames clear exactly once, conserve quantity and never replay", c do
    supply = Path.join(c.root, "fall-source.json")
    File.write!(supply, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [63,1,2], material: 21}]}))
    assert {:ok, _} = World.liquid_experiment(c.w, supply)
    assert :ok = World.canonical_snapshot_and_subscribe(c.w, {{0,0,0},{2,1,1}}, self(), :fall, false)
    assert_receive {:canonical_snapshot, :fall, snapshot}
    replica = start_supervised!({VoxelRegion.Replica, authority_ref: c.w, l0_box: {{0,0,0},{2,1,1}}, name: nil})
    assert :ok = VoxelRegion.Replica.canonical_snapshot_and_subscribe(replica, {{0,0,0},{1,1,1}}, self(), :replica_fall, false)
    assert_receive {:canonical_snapshot, :replica_fall, _}
    for _ <- 1..4 do
      tick(c.w)
      assert_receive {:canonical_delta, delta}
      assert delta.transaction.liquid_falls == %{material: 21, transfers: [{{63,0,2},@transfer}]}
      assert_receive {:canonical_delta, replica_delta}
      assert replica_delta.transaction_seq == delta.transaction_seq
      assert replica_delta.transaction.liquid_falls == delta.transaction.liquid_falls
      assert Enum.sum(Map.values(quantities(c.w))) == @capacity
    end
    before = World.seq(c.w)
    tick(c.w)
    assert_receive {:canonical_delta, clear}
    assert clear.transaction_seq == before + 1
    assert clear.transaction.entries == []
    assert clear.chunks == []
    assert clear.transaction.liquid_falls == %{material: 21, transfers: []}
    assert_receive {:canonical_delta, replica_clear}
    assert replica_clear.transaction.liquid_falls == clear.transaction.liquid_falls
    assert Enum.all?(VoxelRegion.Replica.canonical_deltas_after(replica, snapshot.transaction_seq),
      &(not Map.has_key?(&1.transaction, :liquid_falls)))
    assert World.liquid_activity(c.w) == %{active_cells: 0, scheduled: false}
    tick(c.w)
    assert World.seq(c.w) == before + 1
    refute_receive {:canonical_delta, _}
    assert Enum.all?(World.entries_after(c.w, 0), &(not Map.has_key?(&1, :liquid_falls)))
    stop_supervised!(VoxelRegion.Replica)
    stop_supervised!(World)
    w = start_supervised!({World, c.opts})
    assert World.seq(w) == before + 1
    assert Enum.all?(World.entries_after(w, 0), &(not Map.has_key?(&1, :liquid_falls)))
    assert World.liquid_activity(w) == %{active_cells: 0, scheduled: false}
  end

  @tag :empty_inventory
  @tag cadence: 0.01
  test "an actual scheduled liquid tick retires and is not periodically requeued",c do
    :erlang.trace(c.w,true,[:receive])
    assert {:ok,_}=World.apply_edits(c.w,[{{63,0,2},19}])
    pid=c.w
    assert_receive {:trace,^pid,:receive,:liquid_commit},1000
    assert World.liquid_activity(c.w)==%{active_cells: 0,scheduled: false}
    refute_receive {:trace,^pid,:receive,:liquid_commit},100
    :erlang.trace(c.w,false,[:receive])
  end

  @tag :empty_inventory
  @tag :legacy_water
  @tag :missing
  test "liquid admission preserves the missing region response and the world owner",c do
    alias MmoContracts.Voxel.Codec
    request=Codec.encode_request(0,[%{level: 0,region: {1,0,0},have_seq: 0,have_hash: 0}]) |> IO.iodata_to_binary()
    assert {:ok,reply}=World.serve(c.w,request)
    assert {:ok,123,[{:missing,0,{1,0,0}}]}=Codec.decode_reply(IO.iodata_to_binary(reply))
    assert World.seq(c.w)==0
  end

  @tag :empty_inventory
  @tag :legacy_water
  @tag bounds: {{-8192,-8192,-8192},{8192,8192,8192}}
  test "full map starts idle, admits only loaded XYZ regions and supports first scoop",c do
    refute_receive {:prepared, _, _}
    VoxelRegion.TestSupport.payload(c.w,0,{-2,3,-4})
    assert_receive {:prepared,0,{-2,3,-4}}
    refute_receive {:prepared,_,_}
    assert quantities(c.w)==%{}
    assert {:ok,_}=transfer(c,2,1,{63,1,2})
    assert quantities(c.w)==%{{63,1,2}=>@capacity-@transfer}
    assert balance(c.w)==@transfer
    assert total(c.w)==@capacity
  end

  @tag :empty_inventory
  @tag :legacy_water
  test "undisturbed canonical source water is admitted without starting simulation",c do
    refute_receive {:prepared, _, _}
    VoxelRegion.TestSupport.payload(c.w,0,{1,0,0})
    assert quantities(c.w)==%{{63,1,2}=>@capacity}
    assert World.liquid_activity(c.w)==%{active_cells: 0,scheduled: false}
    assert :ok=World.compact(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert World.liquid_activity(w)==%{active_cells: 0,scheduled: false}
  end

  @tag :empty_inventory
  test "idle world has no liquid timer; geometry and finite author input wake it and a settled basin sleeps", c do
    assert World.liquid_activity(c.w) == %{active_cells: 0, scheduled: false}
    walls=for x<-62..65,y<-0..2,z<-1..3, y==0 or z != 2 or x in [62,65],do: {{x,y,z},19}
    assert {:ok,_}=World.apply_edits(c.w,walls)
    tick(c.w)
    assert World.liquid_activity(c.w) == %{active_cells: 0, scheduled: false}
    supply=Path.join(c.root,"sleep-source.json")
    File.write!(supply,Jason.encode!(%{classification: "Test-only",deposits: [%{macro: [63,1,2],material: 21}]}))
    assert {:ok,_}=World.liquid_experiment(c.w,supply)
    assert World.liquid_activity(c.w).scheduled
    for _<-1..100, do: tick(c.w)
    assert World.liquid_activity(c.w) == %{active_cells: 0, scheduled: false}
    prior=quantities(c.w)
    assert {:ok,_}=World.apply_edits(c.w,[{{63,0,2},0}])
    assert World.liquid_activity(c.w).scheduled
    tick(c.w)
    assert quantities(c.w)[{63,0,2}] > 0
    assert Enum.sum(Map.values(quantities(c.w))) == Enum.sum(Map.values(prior))
    assert :ok=World.compact(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert World.liquid_activity(w).scheduled
  end

  # 只测试：隔离水槽中的在线参数发布；真实 World 数量、休眠/唤醒与日志回放，
  # 仅世界基底和玩家使用替身。
  @tag head: @capacity
  test "lowering the published side threshold wakes sleeping liquid and survives compact",c do
    walls=for x<-62..65,y<-0..2,z<-1..3, y==0 or z != 2 or x in [62,65],do: {{x,y,z},19}
    assert {:ok,_}=World.apply_edits(c.w,walls)
    :ok=GenServer.call(c.actor.player,{:eye,{63.5,2.5,2.5}})
    assert {:ok,_}=transfer(c,3,1,{63,1,2})
    for _<-1..3, do: tick(c.w)
    assert World.liquid_activity(c.w)==%{active_cells: 0,scheduled: false}
    assert quantities(c.w)==%{{63,1,2}=>@transfer}
    catalog=c.opts[:property_catalog_path]
    old=VoxelRegion.Damage.load(catalog)
    data=Jason.decode!(File.read!(catalog))
    next=Path.join(c.root,"next.json")
    # 缺失字段代表原有零阈值，其余约束不变。
    File.write!(next,Jason.encode!(Map.update!(data,"liquid",&Map.delete(&1,"side_threshold_units"))))
    assert :ok=World.publish_parameters(c.w,next,old.digest)
    assert World.liquid_activity(c.w).scheduled
    assert :ok=World.compact(c.w)
    stop_supervised!(World)
    File.cp!(next,catalog)
    w=start_supervised!({World,c.opts})
    assert World.liquid_activity(w).scheduled
    before=quantities(w)
    tick(w)
    assert quantities(w)[{64,1,2}]>0
    assert Enum.sum(Map.values(quantities(w)))==Enum.sum(Map.values(before))
    current=VoxelRegion.Damage.load(catalog)
    bad=Map.update!(data,"liquid",&Map.update!(&1,"gravity_units_per_step",fn n->n-1 end))
    File.write!(next,Jason.encode!(bad))
    assert {:error,:property_version_in_use}=World.publish_parameters(w,next,current.digest)
    assert World.simulation_snapshot(w,[],{{0,0,0},{2,1,1}}).property_context.digest==current.digest
  end

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
    prior=World.simulation_snapshot(c.w,[1001],{{0,0,0},{2,1,1}})
    assert {:ok,next_seq}=transfer(c,3,11,{63,1,2})
    assert next_seq==seq+1
    next=World.simulation_snapshot(c.w,[1001],{{0,0,0},{2,1,1}})
    assert next.epochs==prior.epochs
    assert next.property_states==prior.property_states
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
    VoxelRegion.TestSupport.payload(c.w,0,{1,0,0})
    assert quantities(c.w)==%{{63,1,2}=>@capacity}
    assert {:ok,_}=transfer(c,2,1,{63,1,2})
    assert quantities(c.w)==%{{63,1,2}=>@capacity-@transfer}
    assert total(c.w)==2*@capacity
    assert :ok=World.canonical_snapshot_and_subscribe(c.w,{{1,0,0},{2,1,1}},self(),:warm,false)
    assert_receive {:canonical_snapshot,:warm,warm}
    # 只测试缓存失效：丢弃可重建载荷，不改变水量、身份或余额。
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
  @tag :empty_inventory
  test "admitted legacy source flows immediately and never refills emptied source after replay",c do
    # 只测试：仅由 legacy source 提供世界水，角色初始库存为空。
    VoxelRegion.TestSupport.payload(c.w,0,{0,0,0})
    assert quantities(c.w)==%{{63,1,2}=>@capacity}
    for n<-1..4, do: assert({:ok,_}=transfer(c,2,n,{63,1,2}))
    assert quantities(c.w)==%{}
    assert balance(c.w)==@capacity
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    VoxelRegion.TestSupport.payload(w,0,{0,0,0})
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

  @tag :empty_inventory
  test "MCP-authored Test-only two-cubic-metre supply installs atomically and flows without a player pour",c do
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
    before={World.seq(c.w),quantities(c.w),balance(c.w)}
    path=Log.open(c.root,World.content_version(c.w))
    File.write!(path<>".reject","")
    assert {:error,:test_disk_failure}=transfer(c,2,2,{63,1,2})
    assert {World.seq(c.w),quantities(c.w),balance(c.w)}==before
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
