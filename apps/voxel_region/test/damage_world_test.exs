defmodule VoxelRegion.DamageWorldTest do
  use ExUnit.Case, async: false
  alias VoxelRegion.{World,OverlayLog}
  alias MmoContracts.Voxel.{Payload,Codec}

  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  # 只测试：每例独占 World；窗口覆盖作者样本与热/液体传播区，角色仅 1001。
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], {{-1,-1,-1},{9,2,2}})

  defp payload(w,level \\ 0), do: VoxelRegion.TestSupport.payload(w,level,{0,0,0})
  defp refined(w,cell) do
    p=payload(w)
    Map.get(p.refined,Payload.cell_index(Payload.local(p.region,cell)),%{})
  end
  defp structures(w),do: Map.new(1..5,&{&1,payload(w,&1).structure})

  setup context do
    root=Path.join(System.tmp_dir!(),"b1_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    catalog=Path.join(root,"properties.json")
    materials=for id <- 0..23,do: %{material_id: id,max_hp_per_macro: if(id==0,do: 0.0,else: 100.0),
      defense: 2.0,tags: [],responses: [%{action: "damage",multiplier: 1.0}]}
    # 只测试：花草样本——罂粟一击即碎，必掉自身 64、几乎不可能掉木头；矮草半概率掉自身 8。
    materials=if context[:flora] do
      materials ++ for id <- 24..39 do
        extra=case id do
          35 -> %{max_hp_per_macro: 10.0,place_units: 64,drops: [%{material_id: 35,units: 64,probability: 1.0},%{material_id: 19,units: 8,probability: 1.0e-12}]}
          32 -> %{max_hp_per_macro: 10.0,place_units: 8,drops: [%{material_id: 32,units: 8,probability: 0.5}]}
          _ -> %{}
        end
        Map.merge(%{material_id: id,max_hp_per_macro: 100.0,defense: 2.0,tags: [],responses: [%{action: "damage",multiplier: 1.0}]},extra)
      end
    else
      materials
    end
    data=%{schema_version: 1,tags: [%{id: "damage"}],materials: materials,
      tools: [%{id: "pickaxe",tool_id: 1,action: "damage",power: 30.0,range_macro: 6.0,interval_seconds: 0.5}],definitions: []}
    data=if context[:physical_units] do
      Map.merge(data,%{schema_version: 2,attachments: %{material_units_per_micro: 4096,
        face_thickness_m: 1/512,line_section_m2: 1/(512*512),line_display_width_m: 0.0075}})
    else
      data
    end
    File.write!(catalog,Jason.encode!(data))
    prefab=Path.join(root,"prefabs")
    File.mkdir_p!(prefab)
    bytes=<<"VXPD",1::32-little,2::32-little,
      0::signed-little-32,0::signed-little-32,0::signed-little-32,11::16-little,
      1::signed-little-32,0::signed-little-32,0::signed-little-32,19::16-little,0::32-little>>
    File.write!(Path.join(prefab,"test.vxpd"),bytes)
    opts=[source: Source,log: Log,root: root,observer: self(),property_catalog_path: catalog,prefab_catalog_path: prefab,name: nil,production_materials: [19,11] ++ if(context[:flora],do: [32,35],else: [])]
    opts=if context[:thermal_environment] do
      environment=Path.join(root,"environment.json")
      File.write!(environment,Jason.encode!(%{ambient_kelvin: 293.15,environment_w_per_m2_k: 0.0,tolerance_kelvin: 0.01}))
      Keyword.put(opts,:thermal_environment_path,environment)
    else
      opts
    end
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

  # 溯源：花材料放下的格记着是谁放的；作者入口写的格、天然地形无主；被挖掉就清掉；重启与压实检查点之后仍在。
  @tag :b2
  test "a paid build records who placed the cell; authoring and removal leave none; it survives restart and compaction", c do
    placer = fn w, cell -> hd(World.material_snapshot(w, [], [cell]).probe_occupancy).placed_by end
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},19)
    assert nil == placer.(c.w,{1,1,2})
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    for seq <- 1..4, do: assert {:ok,_}=b2_hit(c,c.actor,target,seq)
    assert nil == placer.(c.w,{1,1,2})

    build=%{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 1,coord: {1,1,2},tool_id: 1,material: 19}
    assert {:ok,6}=World.production_intent(c.w,c.actor,build)
    assert 1001 == placer.(c.w,{1,1,2})
    assert nil == placer.(c.w,{2,1,2})

    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert 1001 == placer.(w,{1,1,2})
    assert :ok == World.compact(w)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert 1001 == placer.(w,{1,1,2})

    # 再挖掉：那一格不再属于任何人；重启后也不会“复活”。
    assert {:ok,target}=World.tool_intent(w,c.actor,Map.merge(c.request,%{request_id: 20,client_intent_seq: 20}))
    for seq <- 21..24, do: assert {:ok,_}=b2_hit(%{c | w: w},c.actor,target,seq)
    assert nil == placer.(w,{1,1,2})
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert nil == placer.(w,{1,1,2})
  end

  defp strike(c,seq) do
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    actor=Map.merge(c.actor,%{received_us: seq*500_000,clock_node: node()})
    request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material])) |> Map.merge(%{action: 1,client_intent_seq: seq})
    assert {:ok,_}=World.tool_intent(c.w,actor,request)
    target
  end

  defp cell(w,coord), do: payload(w) |> Payload.material(Payload.local({0,0,0},coord))

  @tag :flora
  test "a destroyed flower pays its drop table to the attacker, and planting costs place_units on soil only", c do
    assert {:ok,1}=World.apply_edits(c.w,[{{1,0,2},1},{{1,1,2},35}])
    assert %{material: 35}=strike(c,1)
    assert cell(c.w,{1,1,2}) == 0
    # 必掉项入账，1e-12 项不入账；不是整格 512。
    assert balance(c.w,1001,35).balance == 64 and balance(c.w,1001,35).cost == 64
    assert balance(c.w,1001,19).balance == 0
    build=%{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 1,coord: {1,1,2},tool_id: 1,material: 35}
    assert {:ok,_}=World.production_intent(c.w,c.actor,build)
    assert balance(c.w,1001,35).balance == 0
    assert cell(c.w,{1,1,2}) == 35
    # 石头上不能种。
    assert {:ok,_}=World.apply_edits(c.w,[{{2,0,2},11}])
    assert {:ok,_}=World.material_supply(c.w,1001,"flora-test",%{35=>64})
    assert {:error,:unsupported}=World.production_intent(c.w,c.actor,%{build | request_id: 11,client_intent_seq: 11,coord: {2,1,2}})
  end

  @tag :flora
  test "digging the support pays the flower's drops to the digger in the same transaction", c do
    assert {:ok,1}=World.apply_edits(c.w,[{{1,1,2},1},{{1,2,2},35}])
    assert %{material: 1}=strike(c,1)
    for seq <- 2..4, do: strike(c,seq)
    assert cell(c.w,{1,1,2}) == 0 and cell(c.w,{1,2,2}) == 0
    assert balance(c.w,1001,35).balance == 64
    assert [%{material_balances: %{{1001,35}=>64}}]=World.entries_after(c.w,World.seq(c.w)-1)
  end

  @tag :flora
  test "a half-probability drop lands near half, identically on every run", c do
    cells=for x <- 0..19, z <- 3..12, do: {x,1,z}
    assert {:ok,1}=World.apply_edits(c.w,Enum.flat_map(cells,fn {x,y,z} -> [{{x,y-1,z},1},{{x,y,z},32}] end))
    # 作者入口没有操作者：销毁不发放。
    assert {:ok,2}=World.apply_edits(c.w,[{hd(cells),0}])
    assert balance(c.w,1001,32).balance == 0
    hits=for {{x,_,z},i} <- Enum.with_index(tl(cells)), reduce: 0 do
      n ->
        before=balance(c.w,1001,32).balance
        eye={x+0.5,3.5,z+0.5}
        :ok=GenServer.call(c.actor.player,{:eye,eye})
        actor=Map.merge(c.actor,%{eye: eye,received_us: (i+1)*500_000,clock_node: node()})
        request=%{c.request | direction: {0.0,-1.0,0.0}}
        assert {:ok,target}=World.tool_intent(c.w,actor,request)
        assert target.material == 32
        request=Map.merge(request,Map.take(target,[:micro,:incarnation,:owner,:material])) |> Map.merge(%{action: 1,client_intent_seq: i+1})
        assert {:ok,_}=World.tool_intent(c.w,actor,request)
        gained=balance(c.w,1001,32).balance-before
        assert gained in [0,8]
        n+div(gained,8)
    end
    # 199 次独立半概率：均值 99.5、σ≈7；±5σ 之外说明骰子有偏。
    assert hits in 64..135
  end

  defp balance(w,cid,material \\ 19), do: Enum.find(World.material_balances(w,cid), &(&1.material==material))

  defp b2_hit(c,actor,target,seq) do
    actor=Map.merge(actor,%{received_us: seq*500_000,clock_node: node()})
    request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 1,client_intent_seq: seq})
    World.tool_intent(c.w,actor,request)
  end

  @tag :region_read_history
  test "区域首次读取、版本不符、未知基线和 unchanged 不投影历史", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    request=fn cv,seq,hash ->
      Codec.encode_request(cv,[%{level: 0,region: {0,0,0},have_seq: seq,have_hash: hash}])
      |> IO.iodata_to_binary()
    end
    # 只测试读取算法工作量：真实提交建立历史，只计投影调用，不复制或修改 World state。
    mfa={VoxelRegion.LogProjection,:region,3}
    :erlang.trace_pattern(mfa,true,[:call_count])
    try do
      assert {:ok,first}=World.serve(c.w,request.(123,0,0))
      assert {:ok,123,[{:payload,0,{0,0,0},bytes}]}=Codec.decode_reply(IO.iodata_to_binary(first))
      {:ok,header}=Codec.decode_payload_header(bytes)
      for {cv,hash} <- [{999,header.hash},{123,header.hash+1}] do
        assert {:ok,full}=World.serve(c.w,request.(cv,header.seq,hash))
        assert {:ok,123,[{:payload,0,{0,0,0},^bytes}]}=Codec.decode_reply(IO.iodata_to_binary(full))
      end
      assert {:ok,unchanged}=World.serve(c.w,request.(123,header.seq,header.hash))
      assert {:ok,123,[{:unchanged,0,{0,0,0}}]}=Codec.decode_reply(IO.iodata_to_binary(unchanged))
      assert {:call_count,0}=:erlang.trace_info(mfa,:call_count)
    after
      :erlang.trace_pattern(mfa,false,[:call_count])
    end
  end

  @tag :region_read_history
  test "区域增量只投影游标之后相关事务，重复读取与冷恢复仍保留同一结果", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    request=fn seq,hash -> Codec.encode_request(123,[%{level: 0,region: {0,0,0},have_seq: seq,have_hash: hash}]) |> IO.iodata_to_binary() end
    {:ok,reply}=World.serve(c.w,request.(0,0))
    {:ok,123,[{:payload,0,{0,0,0},base}]}=Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok,header}=Codec.decode_payload_header(base)
    for seq<-2..7,do: assert({:ok,^seq}=World.apply_edit(c.w,{257,1,2},if(rem(seq,2)==0,do: 11,else: 19)))
    assert {:ok,8}=World.apply_edits(c.w,[{{2,1,2},19}])
    mfa={VoxelRegion.LogProjection,:region,3}
    :erlang.trace_pattern(mfa,true,[:call_count])
    try do
      assert {:ok,delta}=World.serve(c.w,request.(header.seq,header.hash))
      assert {:ok,123,[{:entries,0,{0,0,0},[%{seq: 8,entries: [%{coord: {2,1,2},material: 19}]}]}]}=
        Codec.decode_reply(IO.iodata_to_binary(delta))
      assert {:call_count,1}=:erlang.trace_info(mfa,:call_count)
      assert {:ok,^delta}=World.serve(c.w,request.(header.seq,header.hash))
    after
      :erlang.trace_pattern(mfa,false,[:call_count])
    end
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    # 重启未曾下发旧头，照现行协议先返完整载荷；再产生真实编辑检查重建索引。
    assert {:ok,recovered}=World.serve(w,request.(header.seq,header.hash))
    assert {:ok,123,[{:payload,0,{0,0,0},bytes}]}=Codec.decode_reply(IO.iodata_to_binary(recovered))
    {:ok,current}=Codec.decode_payload_header(bytes)
    assert {:ok,9}=World.apply_edits(w,[{{3,1,2},11}])
    assert {:ok,next}=World.serve(w,request.(current.seq,current.hash))
    assert {:ok,123,[{:entries,0,{0,0,0},[%{seq: 9}]}]}=Codec.decode_reply(IO.iodata_to_binary(next))
    # 正常恢复后继续将无关历史增长十倍；同一个旧基线仍只需投影那一笔相关事务。
    for seq<-10..69,do: assert({:ok,^seq}=World.apply_edit(w,{257,1,2},if(rem(seq,2)==0,do: 11,else: 19)))
    :erlang.trace_pattern(mfa,true,[:call_count])
    try do
      assert {:ok,^next}=World.serve(w,request.(current.seq,current.hash))
      assert {:call_count,1}=:erlang.trace_info(mfa,:call_count)
    after
      :erlang.trace_pattern(mfa,false,[:call_count])
    end
  end

  @tag :observation
  test "限定模拟观察不启动空子系统，不泄漏窗口外目标或其他角色", c do
    initial=World.simulation_snapshot(c.w,[1001],{{0,0,0},{1,1,1}})
    assert initial.seq==0 and initial.thermal_accounting==nil
    assert initial.liquid_quantities==%{} and initial.phase_inventory==%{}
    assert World.seq(c.w)==0
    assert {:ok,_}=World.apply_edits(c.w,[{{1,1,2},19},{{65,1,2},19}])
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    assert {:ok,_}=b2_hit(c,c.actor,target,1)
    assert :ok=VoxelRegion.TestSupport.mine_authored(c.w,1001,{1,1,2})
    assert :ok=VoxelRegion.TestSupport.mine_authored(c.w,1002,{65,1,2})
    assert {:ok,_}=World.apply_edit(c.w,{65,1,2},19)
    foreign=%{c.actor | eye: {65.0625,1.0625,0.0625}}
    GenServer.call(c.actor.player,{:eye,foreign.eye})
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    assert {:ok,_}=b2_hit(c,c.actor,target,20)
    seq=World.seq(c.w)
    snapshot=World.simulation_snapshot(c.w,[1001],{{0,0,0},{1,1,1}})
    assert snapshot.seq==seq and World.seq(c.w)==seq
    assert snapshot.property_states==[]
    assert [%{character: 1001,material: 19,units: 512}]=snapshot.material_balances
    assert snapshot.thermal_accounting==nil
    assert Map.keys(snapshot)|>Enum.sort()==Enum.sort([:seq,:property_states,:property_context,:epochs,
      :material_balances,:liquid_quantities,:phase_inventory,:thermal_accounting])
    assert [_]=World.simulation_snapshot(c.w,[],{{1,0,0},{2,1,1}}).property_states
  end

  @tag :observation
  test "完整附近属性快照在同一提交点声明默认值并排除远处状态", c do
    assert {:ok, _} = World.apply_edit(c.w, {1,1,2}, 19)
    assert {:ok, target} = World.tool_intent(c.w,c.actor,c.request)
    assert {:ok, _} = b2_hit(c,c.actor,target,1)
    ref = make_ref()
    assert :ok = World.canonical_snapshot_and_subscribe(c.w,{{0,0,0},{1,1,1}},self(),ref,false)
    assert_receive {:canonical_snapshot,^ref,snapshot}
    assert snapshot.property_context.digest == target.digest
    assert snapshot.property_context.hp_enabled
    assert [%{hp: 72.0,seq: seq}] = snapshot.property_states
    assert seq == snapshot.transaction_seq
    assert snapshot.epochs[{1,1,2}] == target.incarnation
    ref = make_ref()
    assert :ok = World.canonical_snapshot_and_subscribe(c.w,{{2,0,0},{3,1,1}},self(),ref,false)
    assert_receive {:canonical_snapshot,^ref,far}
    assert far.property_states == []
    assert far.epochs == %{}
    assert {:ok,_} = b2_hit(c,c.actor,target,2)
    assert_receive {:canonical_delta,delta}
    assert delta.transaction.property_states == []
    assert delta.transaction_seq == World.seq(c.w)
  end

  @tag :b3
  test "完整载荷命中不重复预备源，丢弃缓存后仍从来源重建相同确认快照", %{w: world} do
    box = {{0,0,0},{1,1,1}}
    first = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(world,box,self(),first)
    assert_receive {:prepared,0,{0,0,0}}
    assert_receive {:canonical_snapshot,^first,snapshot}
    second = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(world,box,self(),second)
    assert_receive {:canonical_snapshot,^second,^snapshot}
    refute_received {:prepared,_,_}

    # 只测试：丢弃派生载荷，不改 baseline、overlay 或持久历史。
    :sys.replace_state(world,fn state -> %{state | payloads: %{}} end)
    third = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(world,box,self(),third)
    assert_receive {:prepared,0,{0,0,0}}
    assert_receive {:canonical_snapshot,^third,^snapshot}
  end

  @tag :observation
  test "跨区域叶子使用完整权威汇总，删除仍通知只看到另一半的观察者", c do
    assert {:ok,1} = World.place_prefab(c.w,c.id,{511,8,16},0)
    for {ref,box} <- [{:left,{{0,0,0},{1,1,1}}},{:right,{{1,0,0},{2,1,1}}}] do
      assert :ok = World.canonical_snapshot_and_subscribe(c.w,box,self(),ref,false)
      assert_receive {:canonical_snapshot,^ref,snapshot}
      assert [%{owner: {1,0},hp: hp,max_hp: hp}] = snapshot.property_states
      assert hp == 200.0/512
    end
    assert {:ok,2} = World.remove_prefab(c.w,{1,0})
    assert_receive {:canonical_delta,delta}
    assert [%{owner: {1,0},flags: 1,hp: 0.0}] = delta.transaction.property_states
    assert :ok = World.canonical_snapshot_and_subscribe(c.w,{{1,0,0},{2,1,1}},self(),:empty,false)
    assert_receive {:canonical_snapshot,:empty,%{property_states: []}}
  end

  @tag :b3
  test "B3 authority contact heating persists temperature with the B1 target and HP", c do
    data=Jason.decode!(File.read!(c.catalog))
    materials=Enum.map(data["materials"],fn m ->
      if m["material_id"]==19,do: Map.merge(m,%{"heat_capacity_per_macro"=>1000.0,"thermal_conductivity"=>1000.0,"heat_resistance_kelvin"=>294.0}),else: m
    end)
    File.write!(c.catalog,Jason.encode!(%{data | "materials"=>materials}))
    assert :ok=World.publish_properties(c.w,c.catalog)
    assert {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,_}=World.apply_edit(c.w,{2,1,2},19)
    assert {:ok,_}=World.apply_edit(c.w,{4,1,2},19)
    experiment=Path.join(Keyword.fetch!(c.opts,:root),"thermal.json")
    File.write!(experiment,Jason.encode!(%{classification: "Test-only",source_macro: [1,1,2],ambient_kelvin: 293.15,
      environment_w_per_m2_k: 10.0,tolerance_kelvin: 0.01,power_w: 10000.0,energy_j: 10000.0}))
    assert :ok=World.thermal_experiment(c.w,experiment)
    Process.sleep(650)
    assert {:ok,a}=World.tool_intent(c.w,c.actor,c.request)
    assert a.temperature_kelvin>293.15 and a.hp<a.max_hp
    rows=World.entries_after(c.w,3) |> Enum.flat_map(&Map.get(&1,:property_states,[]))
    b=Enum.find(rows,&(&1.micro=={16,8,16}))
    assert b.temperature_kelvin>293.15
    refute Enum.any?(rows,&(&1.micro=={32,8,16}))
    seq=World.seq(c.w)
    thermal=observe(c.w).thermal
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.seq(w)==seq
    assert {:ok,recovered}=World.tool_intent(w,c.actor,c.request)
    assert recovered.temperature_kelvin==a.temperature_kelvin
    assert recovered.hp==a.hp
    assert recovered.incarnation==a.incarnation
    assert observe(w).thermal==thermal
  end

  defp b3_experiment(c,energy,power,cell \\ {1,1,2}) do
    data=Jason.decode!(File.read!(c.catalog))
    materials=Enum.map(data["materials"],fn m ->
      if m["material_id"]==19,do: Map.merge(m,%{"heat_capacity_per_macro"=>1000.0,"thermal_conductivity"=>1000.0,"heat_resistance_kelvin"=>294.0}),else: m
    end)
    File.write!(c.catalog,Jason.encode!(%{data | "materials"=>materials}))
    :ok=World.publish_properties(c.w,c.catalog)
    {:ok,_}=World.apply_edit(c.w,cell,19)
    path=Path.join(Keyword.fetch!(c.opts,:root),"thermal.json")
    File.write!(path,Jason.encode!(%{classification: "Test-only",source_macro: Tuple.to_list(cell),ambient_kelvin: 293.15,
      environment_w_per_m2_k: 10.0,tolerance_kelvin: 0.01,power_w: power,energy_j: energy}))
    :ok=World.thermal_experiment(c.w,path)
  end

  defp b3_tick(w) do
    send(w,:thermal_commit)
    observe(w)
  end

  # 只测试白盒：仅几何工作集复用/冷恢复算法用例调用。
  defp cache_tick(w) do
    send(w,:thermal_commit)
    :sys.get_state(w)
  end

  @tag :thermal_batch
  test "无新前沿或冷板的半秒提交至多两次进入热 NIF", c do
    b3_experiment(c, 10000.0, 100.0)
    state = observe(c.w)
    assert VoxelRegion.Circuit.devices(state.damage) == %{}
    # 只读计数，不启用会复制完整 World 实参的调用消息。
    mfa = {VoxelRegion.ThermalNative, :advance, 6}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      next = b3_tick(c.w)
      {:call_count, calls} = :erlang.trace_info(mfa, :call_count)
      IO.puts("THERMAL_BATCH calls=#{calls} simulated_s=#{next.thermal.elapsed_s - state.thermal.elapsed_s}")
      assert_in_delta next.thermal.elapsed_s - state.thermal.elapsed_s, 0.5, 1.0e-12
      assert calls <= 2
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  @tag :b3_heater
  test "global thermal environment starts without a test source or free energy", c do
    path=Path.join(Keyword.fetch!(c.opts,:root),"environment.json")
    File.write!(path,Jason.encode!(%{ambient_kelvin: 293.15,environment_w_per_m2_k: 10.0,tolerance_kelvin: 0.01}))
    stop_supervised!(World)
    w=start_supervised!({World,Keyword.put(c.opts,:thermal_environment_path,path)})
    state=observe(w)
    assert state.thermal.sources==%{} and state.thermal.supplied_j==0.0
    refute state.thermal.active
    assert state.seq==0
    assert state.damage==%{}
  end

  @tag :b3_heater
  test "a restart takes the equilibrium tolerance from the environment asset, not from the replayed thermal ledger", c do
    path=Path.join(Keyword.fetch!(c.opts,:root),"environment.json")
    File.write!(path,Jason.encode!(%{ambient_kelvin: 293.15,environment_w_per_m2_k: 10.0,tolerance_kelvin: 0.01}))
    stop_supervised!(World)
    w=start_supervised!({World,Keyword.put(c.opts,:thermal_environment_path,path)})
    # Any committed transaction carries the thermal ledger (and its config) into the log.
    assert {:ok,seq}=World.material_supply(w,1001,"tolerance-restart",%{19=>512})
    File.write!(path,Jason.encode!(%{ambient_kelvin: 293.15,environment_w_per_m2_k: 10.0,tolerance_kelvin: 1.0}))
    stop_supervised!(World)
    w=start_supervised!({World,Keyword.put(c.opts,:thermal_environment_path,path)})
    assert observe(w).seq==seq
    # The config is internal solver state; the public snapshot carries only the ledger.
    assert :sys.get_state(w).thermal.config==%{"ambient_kelvin"=>293.15,"environment_w_per_m2_k"=>10.0,"tolerance_kelvin"=>1.0}
  end

  @tag :b3_heater
  test "paid heater fuel and energy commit together, reject duplicates and survive restart", c do
    data=Jason.decode!(File.read!(c.catalog))
    data=Map.update!(data,"tags",&(&1++[%{"id"=>"heat"},%{"id"=>"heat.receiver"}]))
    data=Map.update!(data,"materials",fn rows -> Enum.map(rows,fn row ->
      if row["material_id"]==19,do: Map.put(row,"tags",["heat.receiver"]),else: row
    end) end)
    tool=%{"id"=>"heater","tool_id"=>2,"action"=>"heat","power"=>1.0,"range_macro"=>6.0,
      "interval_seconds"=>0.5,"fuel_material_id"=>19,"fuel_units"=>256,"heat_energy_j"=>1000.0,"heat_power_w"=>200.0}
    File.write!(c.catalog,Jason.encode!(Map.update!(data,"tools",&(&1++[tool]))))
    b3_experiment(c,1.0,1.0)
    assert {:ok,_}=World.apply_edit(c.w,{-6,1,-4},19)
    assert :ok=VoxelRegion.TestSupport.mine_authored(c.w,1001)
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 1,tool_id: 2,client_intent_seq: 1})
    actor=Map.merge(c.actor,%{received_us: 500_000,clock_node: node()})
    before=observe(c.w)
    assert {:ok,seq}=World.tool_intent(c.w,actor,request)
    after_feed=observe(c.w)
    assert after_feed.material_balances[{1001,19}]==256
    assert after_feed.thermal.sources[{1,1,2}].remaining_j==before.thermal.sources[{1,1,2}].remaining_j+1000.0
    [txn]=World.entries_after(c.w,before.seq)
    assert txn.entries==[] and txn.material_balances==%{{1001,19}=>256}
    assert Map.take(txn.thermal,Map.keys(after_feed.thermal)) |> Map.delete(:sources)==Map.delete(after_feed.thermal,:sources)
    assert Map.take(txn.thermal.sources[{1,1,2}],[:remaining_j,:power_w])==after_feed.thermal.sources[{1,1,2}]
    assert {:error,:replayed_attack}=World.tool_intent(c.w,actor,request)
    assert World.seq(c.w)==seq
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    restored=observe(w)
    assert restored.thermal==after_feed.thermal
    assert restored.material_balances==after_feed.material_balances
    path=Log.open(c.opts[:root],World.content_version(w))
    File.write!(path<>".reject","")
    assert {:error,:test_disk_failure}=World.tool_intent(w,%{actor | received_us: 1_000_000},%{request | client_intent_seq: 2})
    assert Map.take(observe(w),[:thermal,:material_balances,:seq])==Map.take(restored,[:thermal,:material_balances,:seq])
    File.rm!(path<>".reject")
    assert {:ok,_}=World.tool_intent(w,%{actor | received_us: 1_000_000},%{request | client_intent_seq: 2})
    assert {:error,:insufficient_material}=World.tool_intent(w,%{actor | received_us: 1_500_000},%{request | client_intent_seq: 3})
    assert {:ok,_}=World.apply_edit(w,{1,1,2},0)
    assert {:ok,_}=World.apply_edit(w,{1,1,2},19)
    assert b3_tick(w).thermal.sources==%{}
    assert observe(w).material_balances[{1001,19}]==0
  end

  @tag :b3_heater
  test "adding unused thermal materials rebinds saved state without changing HP or temperature", c do
    b3_experiment(c,1000.0,100.0)
    before=b3_tick(c.w)
    data=Jason.decode!(File.read!(c.catalog))
    materials=Enum.map(data["materials"],fn m -> if m["material_id"]==16,
      do: Map.merge(m,%{"heat_capacity_per_macro"=>500.0,"thermal_conductivity"=>1.0,"heat_resistance_kelvin"=>600.0}),else: m end)
    File.write!(c.catalog,Jason.encode!(%{data | "materials"=>materials}))
    assert :ok=World.publish_properties(c.w,c.catalog)
    after_publish=observe(c.w)
    assert after_publish.seq==before.seq+1
    assert after_publish.thermal==before.thermal
    assert Map.new(after_publish.damage,fn {key,t}->{key,Map.drop(t,[:seq,:digest])} end)==
      Map.new(before.damage,fn {key,t}->{key,Map.drop(t,[:seq,:digest])} end)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert observe(w).damage==after_publish.damage
    assert observe(w).thermal==after_publish.thermal
    changed=Enum.map(materials,fn m -> if m["material_id"]==19,do: Map.put(m,"heat_capacity_per_macro",2.0),else: m end)
    File.write!(c.catalog,Jason.encode!(%{data | "materials"=>changed}))
    assert {:error,:property_version_in_use}=World.publish_properties(w,c.catalog)
  end

  @tag :b3
  # 只测试白盒：派生工作集几何/边复用。
  test "B3 reuses geometry but reads current HP; deleting contact invalidates exposed faces", c do
    b3_experiment(c,10000.0,1000.0)
    {:ok,_}=World.apply_edit(c.w,{2,1,2},19)
    first=cache_tick(c.w)
    assert elem(hd(first.thermal_work.geometry[{1,1,2}]),1).exposed_faces==5
    second=cache_tick(c.w)
    assert second.thermal_work.builds==0
    assert second.thermal_work.edges==[{{0,{8,8,16}},{0,{16,8,16}},1000.0}]
    {:ok,_}=World.apply_edit(c.w,{2,1,2},0)
    after_edit=cache_tick(c.w)
    assert after_edit.thermal_work.builds>0
    assert elem(hd(after_edit.thermal_work.geometry[{1,1,2}]),1).exposed_faces==6
    assert after_edit.thermal_work.edges==[]
    assert Enum.all?(after_edit.damage,fn {_,t}->t.micro=={8,8,16} end)
  end

  @tag :b3
  test "fine temperatures remain separate from shared leaf HP and survive replay and removal", c do
    data=Jason.decode!(File.read!(c.catalog))
    materials=Enum.map(data["materials"],fn m ->
      if m["material_id"]==11,do: Map.merge(m,%{"heat_capacity_per_macro"=>1000.0,
        "thermal_conductivity"=>1000.0,"heat_resistance_kelvin"=>294.0}),else: m
    end)
    File.write!(c.catalog,Jason.encode!(%{data | "materials"=>materials}))
    :ok=World.publish_properties(c.w,c.catalog)
    b3_experiment(c,10000.0,10000.0)
    {:ok,_}=World.place_prefab(c.w,c.id,{16,8,16},0)
    before=b3_tick(c.w)
    fine=for {_,t}<-before.damage,t.granularity==1,do: t
    assert length(fine)==2
    assert Enum.all?(fine,&(&1.temperature_kelvin>293.15 and &1.max_hp==100.0/512))
    assert Enum.at(fine,0).temperature_kelvin != Enum.at(fine,1).temperature_kelvin
    [leaf]=for {_,t}<-before.damage,t.granularity==2,do: t
    assert leaf.max_hp==200.0/512 and leaf.hp<leaf.max_hp
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert observe(w).damage==before.damage
    assert observe(w).thermal==before.thermal
    # 只测试：提高热输入使同一正常结算路径到达叶子归零，不逐微格删占用。
    path=Path.join(c.opts[:root],"strong-heat.json")
    config=Jason.decode!(File.read!(Path.join(c.opts[:root],"thermal.json"))) |> Map.merge(%{"power_w"=>1.0e8,"energy_j"=>1.0e8})
    File.write!(path,Jason.encode!(config))
    assert :ok=World.thermal_experiment(w,path)
    seq=World.seq(w)
    after_heat=b3_tick(w)
    assert World.stats(w).refined_macros==0
    assert after_heat.material_balances==%{}
    assert after_heat.thermal.removed_j>0
    assert after_heat.thermal.discarded_source_j>0
    assert not Enum.any?(after_heat.damage,fn {_,t}->t.owner==leaf.owner end)
    txns=World.entries_after(w,seq)
    assert length(txns)==1
    assert Enum.any?(hd(txns).property_states,&(&1.owner==leaf.owner and &1.flags==1))
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert World.stats(w).refined_macros==0
    assert observe(w).damage==after_heat.damage
  end


  @tag :b3
  test "B3 删除源立即使能源失效，不再计算低于阈值的邻格", c do
    b3_experiment(c,5.0,10.0)
    {:ok,_}=World.apply_edit(c.w,{2,1,2},19)
    warmed=b3_tick(c.w)
    row=Enum.find(Map.values(warmed.damage),&(&1.micro=={16,8,16}))
    assert row.temperature_kelvin>293.15 and row.temperature_kelvin<293.16
    {:ok,_}=World.apply_edit(c.w,{1,1,2},0)
    key=VoxelRegion.Damage.key(row)
    next=b3_tick(c.w)
    # 已删除的源不会再提供活动种子；低于阈值的温度作为已保存状态保留。
    assert next.damage[key].temperature_kelvin==row.temperature_kelvin
    assert next.thermal.sources==%{}
    assert not next.thermal.active
  end

  @tag :b3
  # 只测试白盒：故障注入仅清除可重建几何，比较对外属性与热账。
  test "B3 cached and rebuilt topology produce the same evolving front and damage", c do
    b3_experiment(c,10000.0,10000.0,{63,1,2})
    {:ok,_}=World.apply_edits(c.w,(for x<-64..68,do: {{x,1,2},19}))
    b3_tick(c.w)
    stop_supervised!(World)
    # 两个隔离 owner 从同一份正常日志恢复；只丢弃对照侧的可重建几何缓存。
    cold_root=Keyword.fetch!(c.opts,:root)<>"_cold"
    File.cp_r!(Keyword.fetch!(c.opts,:root),cold_root)
    on_exit(fn -> File.rm_rf!(cold_root) end)
    warm_world=start_supervised!({World,c.opts})
    cold_world=start_supervised!(Supervisor.child_spec(
      {World,Keyword.put(c.opts,:root,cold_root)},id: :cold_world))
    for _ <- 1..8 do
      :sys.replace_state(cold_world,fn s -> put_in(s.thermal_work.geometry,%{}) end)
      warm=b3_tick(warm_world)
      cold=b3_tick(cold_world)
      assert warm.damage==cold.damage
      assert warm.thermal==cold.thermal
    end
  end

  @tag :b3
  # 只测试白盒：冷恢复重建 hot 索引且不保留几何缓存。
  test "B3 replay rebuilds the active index and discards all geometry summaries", c do
    b3_experiment(c,10000.0,1000.0)
    before=cache_tick(c.w)
    assert MapSet.size(before.thermal_work.hot)>0
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    recovered=:sys.get_state(w)
    assert recovered.damage==before.damage
    assert recovered.thermal_work.hot==before.thermal_work.hot
    assert recovered.thermal_work.geometry==%{}
    assert cache_tick(w).thermal_work.builds>0
  end

  @tag :b3
  test "B3 canonical contact crosses region 63 to 64 with state-only transactions", c do
    b3_experiment(c,10000.0,10000.0,{63,1,2})
    {:ok,_}=World.apply_edit(c.w,{64,1,2},19)
    seq=World.seq(c.w)
    state=b3_tick(c.w)
    assert Enum.any?(state.damage,fn {_,t}->t.micro=={512,8,16} and t.temperature_kelvin>293.15 end)
    assert Enum.all?(World.entries_after(c.w,seq),&(&1.entries==[] and &1.coarse==[]))
  end

  @tag :b3
  test "B3 equilibrium retains sparse temperature and contact edit reactivates it", c do
    b3_experiment(c,1.0,100.0)
    state=b3_tick(c.w)
    refute state.thermal.active
    assert map_size(state.damage)==1
    assert hd(Map.values(state.damage)).temperature_kelvin>293.15
    assert b3_tick(c.w).seq==state.seq
    assert {:ok,_}=World.apply_edit(c.w,{2,1,2},19)
    assert observe(c.w).thermal.active
    assert map_size(observe(c.w).damage)==1
  end

  @tag :b3
  test "B3 replacement invalidates the finite source token and never inherits temperature", c do
    b3_experiment(c,10000.0,10000.0)
    assert {:ok,_}=World.apply_edit(c.w,{1,1,2},0)
    assert {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    state=b3_tick(c.w)
    assert state.thermal.sources==%{} and state.thermal.supplied_j==0.0
    assert state.damage==%{}
  end

  @tag :b3
  test "B3 lethal temperature and canonical removal commit together without material rewards", c do
    b3_experiment(c,1.0e7,1.0e7)
    seq=World.seq(c.w)
    state=b3_tick(c.w)
    assert state.damage==%{} and state.material_balances==%{}
    [txn]=World.entries_after(c.w,seq)
    assert txn.entries != []
    assert Enum.all?(txn.property_states,&(&1.hp==0.0 and &1.flags==1))
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert observe(w).damage==%{}
    assert {:error,:no_target}=World.tool_intent(w,c.actor,c.request)
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

  @tag :anchor_hit
  test "同一叶子从相反方向命中不同材料仍用权威命中，错误实例被拒", c do
    assert {:ok,1}=full_component(c,{8,8,16})
    assert {:ok,front}=World.tool_intent(c.w,c.actor,c.request)
    assert front.granularity==2
    request=Map.merge(c.request,Map.take(front,[:micro,:granularity,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 1,client_intent_seq: 1})
    GenServer.call(c.actor.player,{:eye,{3.0,1.0625,2.0625}})
    request=%{request | direction: {-1.0,0.0,0.0}}
    actor=Map.merge(c.actor,%{received_us: 1_000_000,clock_node: node()})
    assert {:ok,_}=World.tool_intent(c.w,actor,request)
    assert {:ok,result}=World.tool_intent(c.w,actor,%{request | action: 0})
    assert result.owner==front.owner
    assert result.material==19
    refute result.micro==front.micro
    assert result.hp==72.0
    assert {:error,:stale_target}=World.tool_intent(c.w,%{actor | received_us: 2_000_000},
      %{request | client_intent_seq: 2,owner: {999,0}})
  end

  test "component health follows the leaf across hit positions and lethal damage removes all its materials", c do
    assert {:ok,1}=full_component(c,{8,8,16})
    assert {:ok,2}=full_component(c,{8,8,24})
    assert {:ok,stone}=World.tool_intent(c.w,c.actor,c.request)
    assert stone.granularity==2 and stone.hp==100.0
    for seq<-1..3 do
      assert {:ok,_}=b2_hit(c,c.actor,stone,seq)
      assert map_size(refined(c.w,{1,1,2}))==512
      assert balance(c.w,1001,11).balance==0
    end
    GenServer.call(c.actor.player,{:eye,{1.8125,1.0625,0.0625}})
    assert {:ok,wood}=World.tool_intent(c.w,c.actor,c.request)
    assert wood.material==19 and wood.hp==16.0 and wood.owner==stone.owner
    assert {:ok,6}=b2_hit(c,c.actor,wood,4)
    assert refined(c.w,{1,1,2})==%{}
    assert map_size(refined(c.w,{1,1,3}))==512
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
    remaining_refined=payload(c.w).refined
    assert refined(c.w,{1,1,2})==%{}
    assert map_size(refined(c.w,{1,1,3}))==2
    assert balance(c.w,1001).balance==256
    assert balance(c.w,1001,11).balance==256
    assert {:error,:stale_target}=World.tool_intent(c.w,actor,request)
    assert World.seq(c.w)==4
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert balance(w,1001).balance==256
    assert balance(w,1001,11).balance==256
    assert payload(w).refined==remaining_refined
  end

  @tag :b2
  # 只测试白盒：停止 owner 后构造旧格式存档，验证迁移内部表示。
  test "B2 legacy holes and micro damage migrate without healing or paying already harvested slots", c do
    assert {:ok,1}=full_component(c,{8,8,16})
    assert {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    assert :ok=World.compact(c.w)
    before=:sys.get_state(c.w)
    stop_supervised(World)
    # 只测试旧微格存档：离线修改旧格式载荷，迁移必须由 World 启动重放完成。
    {backend,path}=before.log
    [checkpoint]=backend.replay(path)
    a=%{target | granularity: 1,micro: {8,8,16},max_hp: 100.0/512,hp: 72.0/512}
    b=%{a | micro: {9,8,16},hp: 44.0/512}
    slots=Map.delete(before.refined[{1,1,2}],2)
    entries=Enum.map(checkpoint.entries,fn
      %{payload: bytes}=entry ->
        {:ok,p}=Payload.decode(bytes)
        index=Payload.cell_index(Payload.local(p.region,{1,1,2}))
        if p.level==0 and Map.has_key?(p.refined,index) do
          p=%{p | refined: Map.put(p.refined,index,slots)}
          %{entry | payload: Payload.encode(p,%{},p.seq,p.content_version)}
        else
          entry
        end
      entry -> entry
    end)
    assert :ok=backend.checkpoint(path,%{checkpoint | entries: entries,property_states: [a,b],material_balances: %{{1001,11}=>1}})
    before=%{before | refined: Map.put(before.refined,{1,1,2},slots),material_balances: %{{1001,11}=>1}}
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
    before=observe(c.w)
    geometry=Map.take(payload(c.w),[:refined,:instances])
    path=Log.open(c.opts[:root],World.content_version(c.w))
    File.write!(path<>".reject","")
    request=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 2,client_intent_seq: 2})
    actor=Map.merge(c.actor,%{received_us: 1_000_000,clock_node: node()})
    assert {:error,:test_disk_failure}=World.tool_intent(c.w,actor,request)
    after_state=observe(c.w)
    assert Map.take(payload(c.w),[:refined,:instances])==geometry
    assert Map.take(after_state,[:seq,:damage,:material_balances])==
      Map.take(before,[:seq,:damage,:material_balances])
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
    assert World.stats(c.w).refined_macros==0 and observe(c.w).damage==%{}
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
    assert World.stats(c.w).refined_macros==0
    assert [%{property_states: [%{granularity: 2,flags: 1,hp: +0.0}]}]=World.entries_after(c.w,1)
    assert :ok=World.compact(c.w)
    [checkpoint]=World.entries_after(c.w,0)
    assert [restored]=checkpoint |> OverlayLog.rows() |> OverlayLog.transactions()
    assert restored.material_balances==%{{1001,19}=>1,{1001,11}=>1}
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert balance(w,1001).balance==1
    assert balance(w,1002).balance==0
    assert World.stats(w).refined_macros==0
  end

  @tag :b2
  test "B2 contested builds, occupancy, failed append and session fencing preserve balances", c do
    other=b2_actor(c,1002)
    b2_harvest(c,c.actor)
    b2_harvest(c,other)
    build=%{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 1,coord: {2,1,2},tool_id: 1,material: 19}
    path=Log.open(c.opts[:root],World.content_version(c.w))
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
    path=Log.open(c.opts[:root],World.content_version(c.w))
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

  test "HTTP materialization preserves reduced textures after editing an empty coarse region", c do
    assert {:ok,1}=World.apply_edits(c.w,[{{1,1,2},11},{{0,1,2},19}])
    [txn]=World.entries_after(c.w,0)
    expected=for %{level: level,cell: cell,material: material,skins: skins} <- txn.coarse,
      level in [1,2],into: %{},do: {{level,cell},{material,skins}}
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
    # 只测试：两个真实非空窗口，属性范围与碰撞范围遵守同一合同。
    assert :ok=World.canonical_snapshot_and_subscribe(c.w,{{0,0,0},{1,1,1}},parent,:owner,false)
    assert :ok=World.canonical_snapshot_and_subscribe(c.w,{{0,0,0},{1,1,1}},observer,:observer,false)
    assert_receive {:canonical_snapshot,:owner,_}
    assert_receive {:observer,{:canonical_snapshot,:observer,_}}
    for seq <- 1..4 do
      if seq>1,do: Process.sleep(510)
      assert {:ok,n}=attack(c.w,c.actor,c.request,t,seq)
      assert n==seq+1
    end
    assert {:error,:no_target}=World.tool_intent(c.w,c.actor,c.request)
    assert_receive {:canonical_delta,%{transaction: %{property_states: [%{hp: 72.0}]},chunks: []}}
    assert_receive {:canonical_delta,%{transaction: %{property_states: [%{flags: 1,hp: +0.0}]}}}
    assert_receive {:observer,{:canonical_delta,%{transaction: %{property_states: [%{hp: 72.0}]}}}}
    assert observe(c.w).damage==%{}
    Process.exit(observer,:kill)
    # A legal catalog switch must not reject tombstoned historical damage during replay.
    File.write!(c.catalog," ",[:append])
    assert :ok=World.publish_properties(c.w,c.catalog)
    # 只测试：四次伤害后是 seq 5，目录发布本身再提交一笔无伤害状态的事务。
    assert World.seq(c.w)==6
    assert [%{seq: 6,property_states: []}]=World.entries_after(c.w,5)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.seq(w)==6
    assert observe(w).damage==%{}
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
    assert refined(c.w,{1,1,2})==%{}
    assert map_size(refined(c.w,{1,1,3}))==2
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
    assert observe(w).damage |> map_size()==1
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
    path=Log.open(c.opts[:root],World.content_version(c.w))
    File.write!(path<>".reject","")
    Process.sleep(510)
    assert {:error,:test_disk_failure}=attack(c.w,c.actor,c.request,t,4)
    assert World.seq(c.w)==4
    assert {:ok,current}=World.tool_intent(c.w,c.actor,c.request)
    assert current.hp==16.0
    assert map_size(refined(c.w,{1,1,2}))==512
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
  test "prefab structure updates publish changed cells and survive replay", c do
    assert {:ok,1}=World.place_prefab(c.w,c.id,{8,8,16},0)
    [txn]=World.entries_after(c.w,0)
    levels=for %{payload: b}<-txn.entries,do: ( {:ok,h}=Codec.decode_payload_header(b); h.level )
    assert levels == [0]
    structure=Enum.filter(txn.entries,&Map.has_key?(&1,:structure))
    assert structure != []
    assert {:ok,decoded}=Codec.decode_transaction(IO.iodata_to_binary(Codec.encode_transaction(txn)))
    assert decoded.entries == txn.entries
    assert hd(OverlayLog.transactions(OverlayLog.rows(txn))).entries == txn.entries
    before=structures(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert structures(w) == before
    assert {:ok,2}=World.remove_prefab(w,{1,0})
    [removed]=World.entries_after(w,1)
    assert Enum.any?(removed.entries,fn e -> Map.get(e,:structure)==<<>> end)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert World.stats(w).refined_macros == 0
    assert Enum.all?(structures(w),fn {_,grid}->grid==%{} end)
  end

  @tag :interaction_latency
  test "durable geometry append returns without a full-world checkpoint", c do
    assert {:ok,1}=World.place_prefab(c.w,c.id,{8,8,16},0)
    assert {:ok,2}=World.apply_edit(c.w,{1,1,3},11)
    path=Log.open(c.opts[:root],World.content_version(c.w))
    refute File.exists?(path<>".checkpoint_calls")
    # 最后一个 region 事务在回执前已追加，重启重放不依赖在线检查点。
    txns=OverlayLog.File.replay(path)
    assert List.last(txns).seq==2
    assert Enum.any?(List.last(txns).entries,&(Map.get(&1,:coord)=={1,1,3} and Map.get(&1,:material)==11))
    assert Enum.any?(List.last(txns).entries,&Map.has_key?(&1,:structure))
    structure=structures(c.w)
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
    assert structures(w)==structure
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
  # 只测试白盒：物化缓存冷重建逐字节等价。
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
    # 只测试：混合地形/结构改动使用各自增量，不再要求结构触发完整粗层区域。
    assert map_size(afterimages)==0
    assert Enum.any?(txn.entries,&Map.has_key?(&1,:structure))
    assert Enum.any?(txn.entries,&(Map.get(&1,:coord)=={1,63,3} and Map.get(&1,:material)==0))
    expected=Map.merge(expected,afterimages)
    # 对结构格覆盖的所有边环取最终快照，后续与冷日志重放逐字节对照。
    keys=for %{structure: _,level: l,cell: {x,y,z}} <- txn.entries,
      rx <- Integer.floor_div(x-1,64)..Integer.floor_div(x+1,64),
      ry <- Integer.floor_div(y-1,64)..Integer.floor_div(y+1,64),
      rz <- Integer.floor_div(z-1,64)..Integer.floor_div(z+1,64),do: {l,{rx,ry,rz}}
    expected=Enum.reduce(Enum.uniq(keys),expected,fn {level,region}=key,acc ->
      request=Codec.encode_request(0,[%{level: level,region: region,have_seq: 0,have_hash: 0}]) |> IO.iodata_to_binary()
      assert {:ok,reply}=World.serve(c.w,request)
      assert {:ok,_,[{:payload,^level,^region,bytes}]}=Codec.decode_reply(IO.iodata_to_binary(reply))
      Map.put(acc,key,bytes)
    end)
    # 可丢弃缓存不得改变世界；强制冷物化须与增量构造逐字节相同。
    :sys.replace_state(c.w,fn s -> %{s | payloads: %{},lru: :gb_trees.empty(),lru_ticks: %{},
      lru_bytes: 0,resident_bytes: 0} end)
    for {{level,region},bytes} <- expected do
      request=Codec.encode_request(0,[%{level: level,region: region,have_seq: 0,have_hash: 0}])
        |> IO.iodata_to_binary()
      assert {:ok,reply}=World.serve(c.w,request)
      assert {:ok,_,[{:payload,^level,^region,^bytes}]}=Codec.decode_reply(IO.iodata_to_binary(reply))
    end
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    for {{level,region},bytes} <- expected do
      request=Codec.encode_request(0,[%{level: level,region: region,have_seq: 0,have_hash: 0}]) |> IO.iodata_to_binary()
      assert {:ok,reply}=World.serve(w,request)
      assert {:ok,_,[{:payload,^level,^region,^bytes}]}=Codec.decode_reply(IO.iodata_to_binary(reply))
    end
  end

  @tag :cadence
  test "one authoritative tick of early arrival borrows against the next interval", c do
    assert {:ok,1}=World.apply_edit(c.w,{1,1,2},11)
    assert {:ok,t}=World.tool_intent(c.w,c.actor,c.request)
    request=Map.merge(c.request,Map.take(t,[:micro,:incarnation,:owner,:material])) |> Map.put(:action,1)
    actor=Map.merge(c.actor,%{received_us: 500_000,clock_node: node()})
    assert {:ok,2}=World.tool_intent(c.w,actor,request)
    deadline=1_000_000
    actor=%{actor | received_us: deadline-15_000}
    assert {:ok,3}=World.tool_intent(c.w,actor,%{request | client_intent_seq: 2})
    # 提前借用不得缩短下一周期：在新期限前超过一个权威 tick 仍拒绝，期限处接受。
    assert {:error,:tool_cooldown}=World.tool_intent(c.w,%{actor | received_us: deadline+480_000},%{request | client_intent_seq: 3})
    assert {:ok,4}=World.tool_intent(c.w,%{actor | received_us: deadline+500_000},%{request | client_intent_seq: 4})
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

  @tag :b4
  @tag :physical_units
  test "B4 physical quantity survives damage partial support prefab settlement and restart",c do
    r=b4_funded(c)
    assert balance(c.w,1001).balance==2_097_152
    assert balance(c.w,1001).cost==2_097_152
    assert {:ok,id}=World.attachment_intent(c.w,c.actor,r)
    assert balance(c.w,1001).balance==2_097_152-4096
    request=Map.merge(c.request,%{granularity: 3,micro: r.anchor,owner: {id,2},incarnation: id,material: 19})
    assert {:ok,full}=World.tool_intent(c.w,c.actor,request)
    assert full.max_hp==100/512
    actor=Map.merge(c.actor,%{received_us: 10_000_000,clock_node: node()})
    assert {:ok,_}=World.tool_intent(c.w,actor,%{request | action: 1,client_intent_seq: 20})
    assert {:ok,hurt}=World.tool_intent(c.w,c.actor,request)
    assert_in_delta hurt.hp/full.max_hp,0.72,1.0e-9
    assert {:ok,birth}=World.place_prefab(c.w,c.id,{8,8,15},0)
    # 正常采掘宿主，剩余两个槽由另一侧实际 Prefab 支撑。
    GenServer.call(c.actor.player,{:eye,{1.0625,1.0625,3.5}})
    host_query=%{c.request | direction: {0.0,0.0,-1.0}}
    assert {:ok,host}=World.tool_intent(c.w,c.actor,host_query)
    for seq<-21..24 do
      a=Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()})
      hit=Map.merge(host_query,Map.take(host,[:micro,:incarnation,:owner,:material])) |> Map.merge(%{action: 1,client_intent_seq: seq})
      assert {:ok,_}=World.tool_intent(c.w,a,hit)
    end
    assert World.stats(c.w).attachment_slots==2
    assert balance(c.w,1001).balance==2_097_152-128
    assert balance(c.w,1001,11).balance==2_097_152
    assert {:ok,partial}=World.tool_intent(c.w,c.actor,request)
    assert partial.incarnation==id
    assert_in_delta partial.hp/partial.max_hp,0.72,1.0e-9
    assert :ok=World.compact(c.w)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert {:ok,%{hp: hp}}=World.tool_intent(w,c.actor,request)
    assert hp==partial.hp
    delete=%{r | action: 1,id: id,request_id: 30,client_intent_seq: 30}
    assert {:ok,removed}=World.attachment_intent(w,c.actor,delete)
    assert {:ok,^removed}=World.attachment_intent(w,c.actor,delete)
    assert balance(w,1001).balance==2_097_152
    assert {:ok,_}=World.remove_prefab(w,{birth,0})
    # 带面/线的同一微格 Prefab：只收一次实际体积，删除/替换按差額。
    GenServer.call(c.actor.player,{:eye,{1.0625,1.0625,0.0625}})
    cell=<<0::signed-little-32,0::signed-little-32,0::signed-little-32,19::16-little>>
    group=fn slot,kind,axis -> <<slot::32-little,kind,axis,0::signed-little-32,0::signed-little-32,0::signed-little-32,1,19::16-little>> end
    bytes=<<"VXPD",2::32-little,1::32-little>><>cell<><<0::32-little,2::32-little>><>group.(1,0,2)<>group.(2,1,0)
    definition=:crypto.hash(:sha256,bytes)
    File.write!(Path.join(c.opts[:prefab_catalog_path],"physical.vxpd"),bytes)
    :ok=World.publish_prefabs(w,c.opts[:prefab_catalog_path])
    place=%{request_id: 40,client_intent_seq: 40,logical_scene_id: 1,definition_id: definition,anchor: {8,8,12},orientation: 0}
    assert {:ok,new_birth}=World.prefab_intent(w,c.actor,:voxel_prefab_place_v1,place)
    assert balance(w,1001).balance==2_097_152-4096-64-1
    remove=%{request_id: 41,client_intent_seq: 41,logical_scene_id: 1,instance_id: {new_birth,0}}
    assert {:ok,_}=World.prefab_intent(w,c.actor,:voxel_prefab_remove_v1,remove)
    assert balance(w,1001).balance==2_097_152
  end

  defp b4_funded(c) do
    {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    for seq<-1..4 do
      actor=Map.merge(c.actor,%{received_us: seq*500_000,clock_node: node()})
      r=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
        |> Map.merge(%{action: 1,client_intent_seq: seq})
      {:ok,_}=World.tool_intent(c.w,actor,r)
    end
    {:ok,_}=World.apply_edit(c.w,{1,1,2},11)
    %{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 0,
      kind: 0,axis: 2,size: 8,anchor: {8,8,16},id: 0,material: 19,tool_id: 1}
  end

  @tag :b4
  test "B4 authoritative placement, overlap, stale delete, balance and restart",c do
    r=b4_funded(c)
    assert {:ok,seq}=World.attachment_intent(c.w,c.actor,r)
    assert balance(c.w,1001).balance==448
    assert World.stats(c.w).attachment_slots==64
    assert {:ok,^seq}=World.attachment_intent(c.w,c.actor,r)
    assert {:error,:occupied}=World.attachment_intent(c.w,c.actor,%{r | client_intent_seq: 11,request_id: 11})
    assert {:error,:replayed_build}=World.attachment_intent(c.w,c.actor,r)
    [txn]=World.entries_after(c.w,seq-1)
    projected=Enum.find(txn.coarse,&(&1.level==1 and &1.cell=={0,0,1}))
    assert VoxelRegion.Reducer.texel(projected.skins,4,1,1)==19
    assert projected.material==0
    assert Enum.any?(txn.entries,fn %{payload: bytes}->
      {:ok,p}=Payload.decode(bytes)
      p.format_version==8 and map_size(p.attachments)==64
    end)
    World.compact(c.w)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.stats(w).attachment_slots==64
    assert balance(w,1001).balance==448
    remove=%{r | action: 1,id: seq,client_intent_seq: 12,request_id: 12}
    assert {:ok,_}=World.attachment_intent(w,c.actor,remove)
    assert World.stats(w).attachment_slots==0
    assert balance(w,1001).balance==512
    assert {:ok,_}=World.attachment_intent(w,c.actor,%{r | client_intent_seq: 13,request_id: 13})
    assert {:error,:stale_target}=World.attachment_intent(w,c.actor,%{remove | client_intent_seq: 14,request_id: 14})
    assert World.stats(w).attachment_slots==64
  end

  @tag :b4
  test "B4 shared edge survives one support, last support removal is same transaction",c do
    r=b4_funded(c)
    {:ok,_}=World.apply_edit(c.w,{0,1,2},11)
    r=%{r | kind: 1,axis: 1}
    assert {:ok,_}=World.attachment_intent(c.w,c.actor,r)
    assert World.stats(c.w).attachment_slots==8
    {:ok,_}=World.apply_edit(c.w,{1,1,2},0)
    assert World.stats(c.w).attachment_slots==8
    # 移除最后支撑；Water 已要求液体工具，不能用普通编辑制造液体。
    {:ok,seq}=World.apply_edit(c.w,{0,1,2},0)
    assert World.stats(c.w).attachment_slots==0
    [txn]=World.entries_after(c.w,seq-1)
    assert Enum.all?(txn.entries,fn %{payload: bytes}->
      {:ok,p}=Payload.decode(bytes); map_size(p.attachments)==0
    end)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.stats(w).attachment_slots==0
  end

  @tag :b4
  test "B4 log failure rolls back slots and inventory",c do
    r=b4_funded(c)
    File.write!(Path.join(c.opts[:root],"overlay.log.reject"),"")
    assert {:error,:test_disk_failure}=World.attachment_intent(c.w,c.actor,r)
    assert World.stats(c.w).attachment_slots==0
    assert balance(c.w,1001).balance==512
  end

  @tag :b4
  test "B4 cannot select the back face through the same macro host",c do
    r=b4_funded(c)
    assert {:error,:occluded_attachment}=World.attachment_intent(c.w,c.actor,%{r | anchor: {8,8,24}})
    assert World.stats(c.w).attachment_slots==0
    assert balance(c.w,1001).balance==512
    assert {:ok,_}=World.attachment_intent(c.w,c.actor,%{r | client_intent_seq: 11,request_id: 11})
  end

  @tag :b4
  test "B4 neighbor in another coarse parent hides and reveals surviving coating",c do
    r=b4_funded(c)
    assert {:ok,_}=World.attachment_intent(c.w,c.actor,r)
    assert {:ok,seq}=World.apply_edit(c.w,{1,1,1},11)
    [txn]=World.entries_after(c.w,seq-1)
    cell=Enum.find(txn.coarse,&(&1.level==1 and &1.cell=={0,0,1}))
    assert VoxelRegion.Reducer.texel(cell.skins,4,1,1)==11
    assert World.stats(c.w).attachment_slots==64
    assert {:ok,seq}=World.apply_edit(c.w,{1,1,1},0)
    [txn]=World.entries_after(c.w,seq-1)
    cell=Enum.find(txn.coarse,&(&1.level==1 and &1.cell=={0,0,1}))
    assert VoxelRegion.Reducer.texel(cell.skins,4,1,1)==19
    assert World.stats(c.w).attachment_slots==64
  end

  @tag :b4
  test "B4 oblique view of a shared boundary uses the attachment plane, not a support center",c do
    r=b4_funded(c)
    {:ok,_}=World.apply_edits(c.w,[{{63,1,2},11},{{64,1,2},11}])
    GenServer.call(c.actor.player,{:eye,{60.0,1.51,0.5}})
    r=%{r | anchor: {512,8,16}}
    assert {:ok,_}=World.attachment_intent(c.w,c.actor,r)
    assert {:ok,_}=World.attachment_intent(c.w,c.actor,%{r | kind: 1,axis: 1,client_intent_seq: 11,request_id: 11})
    assert World.stats(c.w).attachment_slots==72
  end

  @tag :b4
  test "B4 partial macro coating keeps only the slots supported by a neighboring prefab",c do
    r=b4_funded(c)
    assert {:ok,id}=World.attachment_intent(c.w,c.actor,r)
    assert {:ok,_}=World.place_prefab(c.w,c.id,{8,8,15},0)
    assert {:ok,_}=World.apply_edit(c.w,{1,1,2},0)
    assert World.stats(c.w).attachment_slots==2
    World.compact(c.w)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.stats(w).attachment_slots==2
    GenServer.call(c.actor.player,{:eye,{1.0625,1.0625,3.0}})
    assert {:ok,_}=World.attachment_intent(w,c.actor,%{r | action: 1,id: id,client_intent_seq: 11,request_id: 11})
    assert World.stats(w).attachment_slots==0
    assert balance(w,1001).balance==450
  end

  @tag :b4
  test "B4 boundary rings, concurrent slot ownership, stale session and host replacement",c do
    r=b4_funded(c)
    {:ok,_}=World.apply_edits(c.w,[{{63,1,2},11},{{64,1,2},11}])
    GenServer.call(c.actor.player,{:eye,{63.9,1.5,0.5}})
    r=%{r | kind: 1,axis: 1,anchor: {512,8,16}}
    {:ok,p2}=Actor.start_link(%{c.actor | eye: {63.9,1.5,0.5},gate: c.actor.player})
    actor2=%{c.actor | player: p2}
    tasks=for a<-[c.actor,actor2],do: Task.async(fn -> World.attachment_intent(c.w,a,r) end)
    results=Enum.map(tasks,&Task.await(&1,300_000))
    assert Enum.count(results,&match?({:ok,_},&1))==1
    assert Enum.count(results,&(&1=={:error,:occupied}))==1
    assert World.stats(c.w).attachment_slots==8
    assert balance(c.w,1001).balance==504
    txn=World.entries_after(c.w,World.seq(c.w)-1) |> hd()
    regions=for %{payload: bytes}<-txn.entries do
      {:ok,p}=Payload.decode(bytes)
      assert map_size(p.attachments)==8
      p.region
    end
    assert {0,0,0} in regions and {1,0,0} in regions
    {:ok,_}=World.apply_edit(c.w,{63,1,2},19)
    assert World.stats(c.w).attachment_slots==8
    {:ok,_}=World.apply_edit(c.w,{63,1,2},0)
    assert World.stats(c.w).attachment_slots==8
    GenServer.call(c.actor.player,:seal)
    assert {:error,:invalid_state}=World.attachment_intent(c.w,c.actor,%{r | client_intent_seq: 99})
    {:ok,_}=World.apply_edit(c.w,{64,1,2},0)
    assert World.stats(c.w).attachment_slots==0
    GenServer.stop(p2)
  end

  @tag :b4
  test "B4 host harvest refunds lost attachment slots once in the host transaction",c do
    r=b4_funded(c)
    assert {:ok,_}=World.attachment_intent(c.w,c.actor,r)
    {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    for seq<-20..23 do
      actor=Map.merge(c.actor,%{received_us: seq*500_000,clock_node: node()})
      req=Map.merge(c.request,Map.take(target,[:micro,:incarnation,:owner,:material]))
        |> Map.merge(%{action: 1,client_intent_seq: seq})
      assert {:ok,_}=World.tool_intent(c.w,actor,req)
    end
    assert World.stats(c.w).attachment_slots==0
    assert balance(c.w,1001).balance==512
    last=World.entries_after(c.w,World.seq(c.w)-1) |> hd()
    assert last.material_balances[{1001,19}]==512
    assert last.material_balances[{1001,11}]==512
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.stats(w).attachment_slots==0
    assert balance(w,1001).balance==512
  end

  @tag :b4
  test "B4 prefab attachments settle actual slots once and never regrow after reload",c do
    r=b4_funded(c)
    cell=fn x -> <<x::signed-little-32,0::signed-little-32,0::signed-little-32,19::16-little>> end
    group=fn slot,kind,axis -> <<slot::32-little,kind,axis,0::signed-little-32,0::signed-little-32,0::signed-little-32,1,19::16-little>> end
    bytes=<<"VXPD",2::32-little,2::32-little>><>cell.(0)<>cell.(1)<><<0::32-little,2::32-little>><>group.(7,0,2)<>group.(8,1,0)
    id=:crypto.hash(:sha256,bytes)
    File.write!(Path.join(c.opts[:prefab_catalog_path],"attached.vxpd"),bytes)
    :ok=World.publish_prefabs(c.w,c.opts[:prefab_catalog_path])
    place=%{request_id: 20,client_intent_seq: 20,logical_scene_id: 1,definition_id: id,anchor: {8,8,12},orientation: 0}
    assert {:ok,birth}=World.prefab_intent(c.w,c.actor,:voxel_prefab_place_v1,place)
    assert balance(c.w,1001).balance==508
    assert {:ok,^birth}=World.prefab_intent(c.w,c.actor,:voxel_prefab_place_v1,place)
    assert balance(c.w,1001).balance==508
    {face_id,19}=Map.fetch!(payload(c.w).attachments,{0,2,{8,8,12}})
    assert byte_size(payload(c.w,1).structure[Payload.cell_index({1,1,1})])==4096*14
    delete=%{r | request_id: 21,client_intent_seq: 21,action: 1,id: face_id,anchor: {8,8,12},size: 1}
    assert {:ok,_}=World.attachment_intent(c.w,c.actor,delete)
    # 独立删除未改 refined 体素，也必须刷新粗层皮肤。
    assert byte_size(payload(c.w,1).structure[Payload.cell_index({1,1,1})])==4096*2
    assert balance(c.w,1001).balance==509
    assert :ok=World.compact(c.w)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.stats(w).attachment_slots==1
    assert not Map.has_key?(payload(w).attachments,{0,2,{8,8,12}})
    replace=%{request_id: 22,client_intent_seq: 22,logical_scene_id: 1,instance_id: {birth,0},definition_id: id}
    assert {:ok,new_birth}=World.prefab_intent(w,c.actor,:voxel_prefab_replace_v1,replace)
    assert balance(w,1001).balance==508
    assert World.stats(w).attachment_slots==2
    {new_face_id,19}=payload(w).attachments[{0,2,{8,8,12}}]
    assert new_face_id>face_id
    assert {:error,:stale_target}=World.attachment_intent(w,c.actor,%{delete | request_id: 23,client_intent_seq: 23})
    remove=%{request_id: 24,client_intent_seq: 24,logical_scene_id: 1,instance_id: {new_birth,0}}
    assert {:ok,removed}=World.prefab_intent(w,c.actor,:voxel_prefab_remove_v1,remove)
    assert {:ok,^removed}=World.prefab_intent(w,c.actor,:voxel_prefab_remove_v1,remove)
    assert balance(w,1001).balance==512
    assert World.stats(w).attachment_slots==0
  end

  for load_kind <- [3,5] do
  @tag :circuit_material_update
  @tag :cold_coverage
  @tag :b5
  @tag :physical_units
  @tag :thermal_environment
  test "设备kind#{load_kind}安装投料开关与热结算同笔恢复，重新安装和旧身份不得补充能源",c do
    load_kind=unquote(load_kind)
    r=b4_funded(c)
    data=Jason.decode!(File.read!(c.catalog))
    materials=Enum.map(data["materials"],fn m->if m["material_id"]==19,do: Map.merge(m,%{
      "heat_capacity_per_macro"=>if(load_kind==5,do: 1.0e7,else: 1000.0),"thermal_conductivity"=>0.0,"heat_resistance_kelvin"=>1000.0,"electrical_conductivity"=>58.0e6}),else: m end)
    devices=for {id,kind,resistance,voltage,light}<-[{3,1,1.0,12.0,0.0},{4,2,0.01,0.0,0.0},{5,load_kind,12.0,0.0,if(load_kind==3,do: 0.2,else: 0.0)}],do:
      %{"id"=>"device#{id}","tool_id"=>id,"action"=>"circuit.install","power"=>1.0,"range_macro"=>6.0,"interval_seconds"=>0.5,
        "circuit_kind"=>kind,"circuit_resistance_ohm"=>resistance,"circuit_voltage_v"=>voltage,"circuit_light_fraction"=>light,"circuit_cooling_cop"=>2.0,"circuit_min_kelvin"=>250.0}
    toggle=%{"id"=>"toggle","tool_id"=>7,"action"=>"circuit.toggle","power"=>1.0,"range_macro"=>6.0,"interval_seconds"=>0.5}
    feed=Map.merge(toggle,%{"id"=>"feed","tool_id"=>8,"action"=>"circuit.feed","fuel_material_id"=>19,"fuel_units"=>16,"circuit_energy_j"=>60.0})
    data=%{data | "materials"=>materials,"tools"=>data["tools"]++devices++[toggle,feed],
      "tags"=>data["tags"]++Enum.map(~w(circuit.install circuit.toggle circuit.feed),&%{"id"=>&1})}
    File.write!(c.catalog,Jason.encode!(data))
    assert :ok=World.publish_properties(c.w,c.catalog)
    assert {:ok,_}=World.apply_edits(c.w,[{{2,1,2},11},{{3,1,2},11}])
    ids=for x<-1..3 do
      assert {:ok,id}=World.attachment_intent(c.w,c.actor,%{r | anchor: {x*8,8,16},request_id: x+20,client_intent_seq: x+20})
      id
    end
    for {{axis,p},i}<-Enum.with_index([{1,{8,8,16}},{1,{32,8,16}},{0,{8,16,16}},{0,{16,16,16}},{0,{24,16,16}}]) do
      assert {:ok,_}=World.attachment_intent(c.w,c.actor,%{r | kind: 1,axis: axis,anchor: p,request_id: 30+i,client_intent_seq: 30+i})
    end
    use=fn w,index,tool,seq->
      id=Enum.at(ids,index)
      request=Map.merge(c.request,%{granularity: 3,micro: {(index+1)*8,8,16},owner: {id,2},incarnation: id,material: 19,
        action: 1,tool_id: tool,request_id: seq,client_intent_seq: seq})
      World.tool_intent(w,Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()}),request)
    end
    for index<-0..2,do: assert({:ok,_}=use.(c.w,index,index+3,40+index))
    assert {:error,:invalid_circuit_operation}=use.(c.w,0,3,44)
    prior=balance(c.w,1001).balance
    assert {:ok,_}=use.(c.w,0,8,45)
    assert balance(c.w,1001).balance==prior-16*4096
    warm=b3_tick(c.w)
    assert warm.damage[{3,Enum.at(ids,2)}].circuit.power_w>1.0
    assert warm.thermal.circuit_supplied_j>0
    assert_in_delta warm.thermal.circuit_supplied_j,warm.thermal.supplied_j+warm.thermal.circuit_light_j+warm.thermal.circuit_rejected_j,1.0e-7
    assert Enum.any?(warm.damage,fn {_,t}->t.granularity==4 and t.temperature_kelvin>293.15 end)
    if load_kind==5 do
      assert warm.thermal.circuit_cooling_j>0
      assert warm.thermal.circuit_rejected_j>warm.thermal.circuit_cooling_j
      assert Enum.any?(warm.damage,fn {_,t}->t.granularity==4 and t.temperature_kelvin<293.15 end)
    end
    assert {:ok,_}=use.(c.w,1,7,46)
    off=b3_tick(c.w)
    assert_in_delta off.damage[{3,Enum.at(ids,2)}].circuit.power_w,0.0,1.0e-9
    assert_in_delta off.thermal.circuit_supplied_j,warm.thermal.circuit_supplied_j,1.0e-8
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    restored=observe(w)
    assert restored.damage==off.damage
    assert restored.thermal==off.thermal
    assert restored.material_balances==off.material_balances
    # 已安装设备的参数不能借目录发布改变；扩充其他内容仍沿既有发布路径。
    changed=update_in(data["tools"],&Enum.map(&1,fn t->if t["tool_id"]==3,do: Map.put(t,"circuit_voltage_v",24.0),else: t end))
    File.write!(c.catalog,Jason.encode!(changed))
    assert {:error,:property_version_in_use}=World.publish_properties(w,c.catalog)
    File.write!(c.catalog,Jason.encode!(data))
    assert {:ok,_}=use.(w,1,7,47)
    for _<-1..20,do: b3_tick(w)
    depleted=observe(w)
    assert depleted.damage[{3,hd(ids)}].circuit.remaining_j==0.0
    assert depleted.damage[{3,Enum.at(ids,2)}].circuit.power_w==0.0
    assert_in_delta depleted.thermal.circuit_supplied_j,60.0,1.0e-7
    assert_in_delta depleted.thermal.circuit_supplied_j,depleted.thermal.supplied_j+depleted.thermal.circuit_light_j+depleted.thermal.circuit_rejected_j,1.0e-7
    # 目录失导只影响原料导线和新安装；已有设备仍按安装参数工作并正常付费投料。
    nonconductive=update_in(data["materials"],&Enum.map(&1,fn m->Map.delete(m,"electrical_conductivity") end))
    File.write!(c.catalog,Jason.encode!(nonconductive))
    assert :ok=World.publish_parameters(w,c.catalog,observe(w).property_digest)
    before_feed=balance(w,1001).balance
    assert {:ok,_}=use.(w,0,8,48)
    assert balance(w,1001).balance==before_feed-16*4096
    assert observe(w).damage[{3,hd(ids)}].circuit.remaining_j==60.0
    funded=balance(w,1001).balance
    # 删除源的最后支撑会丢弃储能，既不返燃料，也不把储能转成热。
    assert {:ok,_}=World.apply_edit(w,{1,1,2},0)
    removed=observe(w)
    assert_in_delta removed.thermal.circuit_removed_j,60.0,1.0e-7
    assert balance(w,1001).balance==funded
    assert {:ok,_}=World.apply_edit(w,{1,1,2},11)
    assert {:ok,new_id}=World.attachment_intent(w,c.actor,%{r | request_id: 49,client_intent_seq: 49})
    assert new_id>hd(ids)
    request=Map.merge(c.request,%{granularity: 3,micro: {8,8,16},owner: {new_id,2},incarnation: new_id,material: 19,
      action: 1,tool_id: 3,request_id: 50,client_intent_seq: 50})
    assert {:error,:not_a_circuit_face}=World.tool_intent(w,Map.merge(c.actor,%{received_us: 50_000_000,clock_node: node()}),request)
    File.write!(c.catalog,Jason.encode!(data))
    assert :ok=World.publish_parameters(w,c.catalog,observe(w).property_digest)
    request=%{request | request_id: 51,client_intent_seq: 51}
    assert {:ok,_}=World.tool_intent(w,Map.merge(c.actor,%{received_us: 51_000_000,clock_node: node()}),request)
    assert observe(w).damage[{3,new_id}].circuit.remaining_j==0.0
  end
  end

  @tag :b5
  @tag :physical_units
  test "附件逐槽温度接入权威步进、附近观察、删除能量账和真实日志恢复",c do
    r=b4_funded(c)
    assert {:ok,id}=World.attachment_intent(c.w,c.actor,%{r | kind: 1,axis: 1})
    b3_experiment(c,1000.0,1000.0)
    warm=b3_tick(c.w)
    temps=for {_,t}<-warm.damage,t.granularity==4,do: t
    assert length(temps)==8
    assert Enum.all?(temps,&(&1.incarnation==id and &1.temperature_kelvin>293.15))
    ref=make_ref()
    assert :ok=World.canonical_snapshot_and_subscribe(c.w,{{0,0,0},{1,1,1}},self(),ref,false)
    assert_receive {:canonical_snapshot,^ref,snapshot}
    assert Enum.count(snapshot.property_states,&(&1.granularity==4))==8
    assert Enum.any?(snapshot.property_states,&(&1.granularity==3 and &1.incarnation==id))
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    restored=observe(w)
    assert restored.damage==warm.damage
    assert restored.thermal==warm.thermal
    # 只测试白盒：冷恢复不得持久化派生几何，状态恢复仍由上述公开观察证明。
    assert :sys.get_state(w).thermal_work.geometry==%{}
    # 最后一份支撑消失，温度与附件同笔移除，旧槽显热计入移除账。
    assert {:ok,_}=World.apply_edit(w,{1,1,2},0)
    removed=observe(w)
    assert World.stats(w).attachment_slots==0
    refute Enum.any?(removed.damage,fn {_,t}->t.granularity==4 end)
    slot_energy=Enum.reduce(temps,0.0,fn t,sum -> sum+1000.0/2097152*(t.temperature_kelvin-293.15) end)
    host_energy=Enum.reduce(warm.damage,0.0,fn {_,t},sum -> sum+if(t.granularity==0,
      do: 1000.0*(t.temperature_kelvin-293.15),else: 0.0) end)
    assert_in_delta removed.thermal.removed_j,slot_energy+host_energy,1.0e-7
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert observe(w).damage==removed.damage
    assert observe(w).thermal==removed.thermal
  end

  @tag :b5
  @tag :physical_units
  test "附件过热只归零自己的共享 HP，删除温度同笔保存且不发采矿奖励",c do
    r=b4_funded(c)
    assert {:ok,id}=World.attachment_intent(c.w,c.actor,%{r | kind: 1,axis: 1})
    # 只测试：耐热石材支撑持有有限作者热源，附件经真实接触升温后归零。
    data=Jason.decode!(File.read!(c.catalog))
    materials=Enum.map(data["materials"],fn m -> if m["material_id"] in [11,19],
      do: Map.merge(m,%{"heat_capacity_per_macro"=>1000.0,"thermal_conductivity"=>1000.0,
        "heat_resistance_kelvin"=>if(m["material_id"]==11,do: 1.0e9,else: 294.0)}),else: m end)
    File.write!(c.catalog,Jason.encode!(%{data | "materials"=>materials}))
    assert :ok=World.publish_properties(c.w,c.catalog)
    path=Path.join(c.opts[:root],"attachment-heat.json")
    File.write!(path,Jason.encode!(%{classification: "Test-only",source_macro: [1,1,2],
      ambient_kelvin: 293.15,environment_w_per_m2_k: 0.01,tolerance_kelvin: 0.01,power_w: 1.0e6,energy_j: 1.0e6}))
    assert :ok=World.thermal_experiment(c.w,path)
    state=observe(c.w)
    removed=Enum.reduce_while(1..10,state,fn _,_ ->
      next=b3_tick(c.w)
      if World.stats(c.w).attachment_slots==0,do: {:halt,next},else: {:cont,next}
    end)
    assert World.stats(c.w).attachment_slots==0
    refute Enum.any?(removed.damage,fn {_,t}->t.granularity in [3,4] end)
    assert removed.material_balances==state.material_balances
    assert removed.thermal.removed_j>0
    [txn]=World.entries_after(c.w,removed.seq-1)
    assert Enum.any?(txn.property_states,&(&1.granularity==3 and &1.incarnation==id and &1.flags==1))
    assert Enum.count(txn.property_states,&(&1.granularity==4 and &1.flags==1))==8
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert World.stats(w).attachment_slots==0
    refute Enum.any?(observe(w).damage,fn {_,t}->t.granularity in [3,4] end)
    assert observe(w).material_balances==removed.material_balances
  end

  @tag :b4
  test "B4 attachment damage stays independent, survives partial support and restart, rejects old identity",c do
    r=b4_funded(c)
    assert {:ok,id}=World.attachment_intent(c.w,c.actor,r)
    request=Map.merge(c.request,%{granularity: 3,micro: r.anchor,owner: {id,2},incarnation: id,material: 19})
    assert {:ok,full}=World.tool_intent(c.w,c.actor,request)
    assert full.max_hp==12.5
    actor=Map.merge(c.actor,%{received_us: 10_000_000,clock_node: node()})
    assert {:ok,_}=World.tool_intent(c.w,actor,%{request | action: 1,client_intent_seq: 20})
    assert {:ok,hurt}=World.tool_intent(c.w,c.actor,request)
    assert_in_delta hurt.hp,9.0,1.0e-9
    assert {:ok,%{material: 11,hp: 100.0}}=World.tool_intent(c.w,c.actor,c.request)
    # 两个 refined 槽保留共享支撑；宿主删除后不得免费回血或重发整面材料。
    assert {:ok,prefab_birth}=World.place_prefab(c.w,c.id,{8,8,15},0)
    assert {:ok,_}=World.apply_edit(c.w,{1,1,2},0)
    assert World.stats(c.w).attachment_slots==2
    GenServer.call(c.actor.player,{:eye,{1.0625,1.0625,3.0}})
    assert {:ok,partial}=World.tool_intent(c.w,c.actor,request)
    assert partial.incarnation==id
    assert_in_delta partial.max_hp,12.5*2/64,1.0e-9
    assert_in_delta partial.hp,9.0*2/64,1.0e-9
    assert :ok=World.compact(c.w)
    stop_supervised(World)
    w=start_supervised!({World,c.opts})
    assert {:ok,restored}=World.tool_intent(w,c.actor,request)
    assert restored.hp==partial.hp
    for seq<-21..23 do
      a=Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()})
      assert {:ok,_}=World.tool_intent(w,a,%{request | action: 1,client_intent_seq: seq})
    end
    assert World.stats(w).attachment_slots==0
    assert balance(w,1001).balance==450
    assert {:ok,_}=World.remove_prefab(w,{prefab_birth,0})
    GenServer.call(c.actor.player,{:eye,{1.0625,1.0625,0.0625}})
    assert {:ok,_}=World.apply_edit(w,{1,1,2},11)
    assert {:ok,new_id}=World.attachment_intent(w,c.actor,%{r | client_intent_seq: 30,request_id: 30})
    assert new_id != id
    assert {:error,:stale_target}=World.tool_intent(w,c.actor,%{request | action: 1,client_intent_seq: 31})
    assert World.stats(w).attachment_slots==64
  end

end
