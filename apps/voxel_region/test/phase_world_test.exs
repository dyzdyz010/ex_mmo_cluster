defmodule VoxelRegion.PhaseWorldTest do
  @moduledoc "Test-only: phase uses real tool, thermal, quantity, collision and journal seams."
  use ExUnit.Case, async: false
  @moduletag :b7
  alias VoxelRegion.{World,Phase,Damage,CollisionSource}
  alias VoxelRegion.TestSupport.{Source,Actor,Log}
  @capacity 2_097_152
  @quarter div(@capacity,4)

  defmodule DatabaseMetadataLog do
    @moduledoc "只测试：经过正式数据库行编码，再以独立文件模拟持久存储和冷恢复。"
    defdelegate open(path,version),to: Log
    defdelegate replay(path),to: Log
    def append(path,txn),do: Log.append(path,roundtrip(txn))
    def checkpoint(path,txn),do: Log.checkpoint(path,roundtrip(txn))
    defp roundtrip(txn) do
      [restored]=txn |> VoxelRegion.OverlayLog.rows() |> VoxelRegion.OverlayLog.transactions()
      restored
    end
  end

  setup context do
    root=Path.join(System.tmp_dir!(),"b7_phase_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    catalog=Path.join(root,"catalog.json")
    data=Jason.decode!(File.read!(VoxelRegion.TestSupport.catalog()))
    materials=Enum.map(data["materials"],fn m->
      if m["material_id"] in [20,21],do: Map.merge(m,%{
        "phase_peer_material_id"=>if(m["material_id"]==20,do: 21,else: 20),
        "phase_transition_kelvin"=>273.15,"latent_heat_per_macro_j"=>334_000_000.0,
        "heat_capacity_per_macro"=>if(m["material_id"]==20,do: 1_930_000.0,else: 4_180_000.0),
        "thermal_conductivity"=>if(m["material_id"]==20,do: 2.2,else: 0.6),"heat_resistance_kelvin"=>1_000_000.0}),else: m
    end)
    tools=for {id,action} <- [{11,"liquid.scoop"},{12,"liquid.pour"},{13,"phase.cool"},{14,"phase.heat"}],do:
      %{"tool_id"=>id,"id"=>action,"action"=>action,"power"=>1,"range_macro"=>8,"interval_seconds"=>0.1,
        "liquid_transfer_units"=>if(id==12,do: Map.get(context,:water_units,@quarter),else: @quarter),"fuel_material_id"=>15,"fuel_units"=>1,
        "cooling_energy_j"=>60_000_000.0,"heat_energy_j"=>if(context[:native_phase],do: 83_499_999.0,else: 1_000_000_000.0)}
    supply_tool = %{hd(tools) | "tool_id" => 18, "id" => "fixture.scoop",
      "liquid_transfer_units" => Map.get(context, :water_units, @capacity)}
    impact_tool = data["tools"] |> Enum.find(&(&1["tool_id"] == 1))
      |> Map.merge(%{"tool_id" => 19, "id" => "fixture.impact", "action" => "damage.impact"})
    data=data |> Map.put("materials",materials) |> Map.update!("tools",&(&1++tools++[supply_tool,impact_tool]))
      |> Map.update!("tags",&(&1++Enum.map(tools,fn t->%{"id"=>t["action"]} end)))
      |> Map.put("liquid",%{"step_seconds"=>3600,"gravity_units_per_step"=>@quarter,"side_units_per_step"=>div(@capacity,16)})
    File.write!(catalog,Jason.encode!(data))
    environment=Path.join(root,"environment.json")
    File.write!(environment,Jason.encode!(%{ambient_kelvin: 293.15,
      environment_w_per_m2_k: if(context[:native_phase],do: 10.0,else: 0.0),tolerance_kelvin: 0.00001}))
    prefab=Path.join(root,"prefabs"); File.mkdir_p!(prefab)
    opts=[source: Source,log: Log,root: root,observer: self(),property_catalog_path: catalog,
      thermal_environment_path: environment,prefab_catalog_path: prefab,name: nil,
      production_materials: [4,13,15,16,20,21,22],liquid_bounds: {{62,0,1},{66,4,4}}]
    w=start_supervised!({World,opts})
    actor=%{cid: 1001,gate: self(),identity: :b7phase,refresh: &Actor.tool_context/2,eye: {63.5,1.0625,0.5},tick_us: 16_667}
    actor=Map.put(actor,:player,start_supervised!({Actor,actor}))
    # 只测试：一格作者水样，经正常舀取入账；余量由另一个角色收走。
    unless context[:empty_inventory] do
    supply=Path.join(root,"inventory-source.json")
    File.write!(supply,Jason.encode!(%{classification: "Test-only",deposits: [%{macro: [65,1,3],material: 21}]}))
    {:ok,_}=World.liquid_experiment(w,supply)
    gate=spawn_link(fn -> receive do :stop -> :ok end end)
    supplier=%{actor | gate: gate,identity: :supply,eye: {65.5,1.0625,1.5}}
    {:ok,player}=Actor.start_link(supplier)
    supplier=%{supplier | player: player}
    {:ok,_}=World.production_intent(w,Map.merge(supplier,%{received_us: 1_000_000,clock_node: node()}),
      %{request_id: 1,client_intent_seq: 1,logical_scene_id: 1,action: 2,material: 21,tool_id: 18,coord: {65,1,3}})
    GenServer.stop(player)
    if context[:water_units] do
      remainder=%{supplier | cid: 1002,identity: :remainder}
      {:ok,player}=Actor.start_link(remainder)
      remainder=%{remainder | player: player}
      for seq<-2..5 do
        {:ok,_}=World.production_intent(w,Map.merge(remainder,%{received_us: seq*1_000_000,clock_node: node()}),
          %{request_id: seq,client_intent_seq: seq,logical_scene_id: 1,action: 2,material: 21,tool_id: 11,coord: {65,1,3}})
      end
      GenServer.stop(player)
    end
    send(gate,:stop)
    {:ok,_}=World.apply_edit(w,{-6,1,-4},15)
    :ok=VoxelRegion.TestSupport.mine_authored(w,1001)
    end
    on_exit(fn->File.rm_rf!(root) end)
    %{w: w,opts: opts,actor: actor,root: root,catalog: catalog}
  end

  defp transfer(c,action,seq,cell) do
    World.production_intent(c.w,Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()}),
      %{request_id: seq,client_intent_seq: seq,logical_scene_id: 1,action: action,material: 21,
        tool_id: if(action==2,do: 11,else: 12),coord: cell})
  end
  defp row(w,cell),do: Enum.find(Map.values(:sys.get_state(w).damage),&(&1.granularity==0 and Damage.macro(&1)==cell))
  defp operate(c,tool,seq,cell \\ {63,1,2},action \\ 1) do
    eye=:sys.get_state(c.actor.player).eye
    delta=Enum.zip_with(Tuple.to_list(cell),Tuple.to_list(eye),&(&1+0.0625-&2))
    length=:math.sqrt(Enum.sum(Enum.map(delta,&(&1*&1))))
    direction=delta |> Enum.map(&(&1/length)) |> List.to_tuple()
    query=%{request_id: seq,client_intent_seq: seq,logical_scene_id: 1,action: 0,
      tool_id: tool,direction: direction,micro: {0,0,0},granularity: 0,incarnation: 0,owner: {0,0},material: 0}
    {:ok,t}=World.tool_intent(c.w,c.actor,query)
    refute Map.has_key?(t,:pick_baseline_hp)
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
    :ok=GenServer.call(c.actor.player,{:eye,{63.5,2.0625,2.5}})
    assert {:ok,_}=operate(c,13,4,{63,2,2})
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

  @tag :empty_inventory
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

  defp expanded_phase_catalog(c) do
    data=Jason.decode!(File.read!(c.catalog))
    data=Map.update!(data,"materials",fn materials->Enum.map(materials,fn m->
      case m["material_id"] do
        4 -> Map.merge(m,Map.take(Enum.find(materials,&(&1["material_id"]==20)),
          ~w(phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j heat_capacity_per_macro thermal_conductivity heat_resistance_kelvin)))
        id when id in [13,22] -> Map.merge(m,%{"phase_peer_material_id"=>if(id==13,do: 22,else: 13),
          "phase_transition_kelvin"=>1268.15,"latent_heat_per_macro_j"=>10_150_000.0,
          "heat_capacity_per_macro"=>31_900.0,"thermal_conductivity"=>23.88,"heat_resistance_kelvin"=>1_000_000.0})
        _ -> m
      end
    end) end)
    File.write!(c.catalog,Jason.encode!(data))
    assert :ok=World.publish_parameters(c.w,c.catalog,:sys.get_state(c.w).properties.digest)
  end

  for material <- [13,4,20], {action,attacks} <- [{1,0},{1,2},{2,0},{2,2},{2,5}] do
    @tag :phase_coverage
    test "相族固体 #{material} 经 #{attacks} 次真实攻击后动作 #{action} 保留完整度和焓",c do
      expanded_phase_catalog(c)
      material=unquote(material); action=unquote(action); attacks=unquote(attacks)
      cell={63,1,2}
      deposits=Path.join(c.root,"harvest-deposit.json")
      File.write!(deposits,Jason.encode!(%{deposits: [%{macro: Tuple.to_list(cell),material: material}]}))
      assert {:ok,_}=World.liquid_experiment(c.w,deposits)
      authored=row(c.w,cell)
      if attacks>0,do: Enum.each(1..attacks,fn seq -> assert {:ok,_}=operate(c,19,seq,cell) end)
      initial=row(c.w,cell)
      hp=if initial,do: initial.hp,else: 0.0
      hits=if hp==0,do: 0,else: if(action==2,do: 1,else: ceil(hp/22))
      if hits>0,do: Enum.each(1..hits,fn seq -> assert {:ok,_}=operate(c,1,attacks+seq,cell,action) end)
      mined=:sys.get_state(c.w)
      assert mined.material_balances[{1001,material}]==@capacity
      {energy,integrity}=Map.fetch!(mined.phase_inventory,{1001,material})
      assert energy==authored.phase_energy_j
      assert integrity==@capacity*hp/authored.max_hp
      refute Map.has_key?(mined.liquid_units,cell)
      refute Enum.any?(mined.damage,fn {_,r}->Map.has_key?(r,:pick_baseline_hp) end)
      build=%{request_id: attacks+hits+1,client_intent_seq: attacks+hits+1,logical_scene_id: 1,
        action: 1,material: material,tool_id: 1,coord: cell}
      if hp==0.0 do
        assert {:error,:broken_material}=World.production_intent(c.w,c.actor,build)
      else
        assert {:ok,_}=World.production_intent(c.w,c.actor,build)
        rebuilt=row(c.w,cell)
        assert rebuilt.hp==hp
        assert rebuilt.phase_energy_j==energy
        refute Map.has_key?(rebuilt,:pick_baseline_hp)
      end
    end
  end

  @tag :phase_coverage
  test "采掘基准只在服务端日志持久化，重启继续采回且不进入属性观察和wire",c do
    expanded_phase_catalog(c)
    cell={63,1,2}
    deposits=Path.join(c.root,"harvest-deposit.json")
    File.write!(deposits,Jason.encode!(%{deposits: [%{macro: [63,1,2],material: 13}]}))
    assert {:ok,_}=World.liquid_experiment(c.w,deposits)
    assert :ok=World.canonical_snapshot_and_subscribe(c.w,{{0,0,0},{2,1,1}},self(),:pick,false)
    assert_receive {:canonical_snapshot,:pick,_}
    before=:sys.get_state(c.w)
    reject=elem(before.log,1)<>".reject"
    File.write!(reject,"")
    assert {:error,:test_disk_failure}=operate(c,1,1)
    assert :sys.get_state(c.w).damage==before.damage
    File.rm!(reject)
    assert {:ok,_}=operate(c,1,1)
    assert_receive {:canonical_delta,%{transaction: %{property_states: rows}}}
    refute Enum.any?(rows,&Map.has_key?(&1,:pick_baseline_hp))
    picked=row(c.w,cell)
    assert picked.pick_baseline_hp==100.0
    assert picked.hp==78.0
    assert MmoContracts.Voxel.Codec.encode({:voxel_property_state,picked})==
      MmoContracts.Voxel.Codec.encode({:voxel_property_state,Map.delete(picked,:pick_baseline_hp)})
    # 正式DB元数据与测试文件日志均承载原始内部属性，不依赖客户端或额外存储。
    txn=%{seq: picked.seq,entries: [],coarse: [],property_states: [picked]}
    assert [%{property_states: [^picked]}]=txn |> VoxelRegion.OverlayLog.rows() |> VoxelRegion.OverlayLog.transactions()
    assert :ok=World.compact(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    c=%{c | w: w}
    assert row(w,cell).pick_baseline_hp==100.0
    assert :ok=World.canonical_snapshot_and_subscribe(w,{{0,0,0},{2,1,1}},self(),:restored_pick,false)
    assert_receive {:canonical_snapshot,:restored_pick,%{property_states: rows}}
    refute Enum.any?(rows,&Map.has_key?(&1,:pick_baseline_hp))
    for seq<-2..5,do: assert({:ok,_}=operate(c,1,seq))
    assert elem(:sys.get_state(w).phase_inventory[{1001,13}],1)==@capacity
  end

  for checkpoint <- [false,true] do
    @tag :basalt_persistence
    @tag :empty_inventory
    test "相族库存经数据库元数据#{if checkpoint,do: "压实",else: "追加"}冷恢复逐字段相等",c do
      expanded_phase_catalog(c)
      inventory=Map.new([{4,17.25,0.5},{13,-31_102_505.653152462,0.25},
        {20,-123.5,0.75},{21,104_400_000.0,0.625},{22,10_150_001.125,0.0}],
        fn {m,e,ratio}->{{1001,m},{e,@capacity*ratio}} end)
      balances=Map.new(inventory,fn {key,_}->{key,@capacity} end)
      # 只测试历史存档编码：停止 owner 后写夹具，重启后使用真实 compact 路径。
      s=:sys.get_state(c.w)
      stop_supervised!(World)
      txn=%{seq: s.seq+1,entries: [],coarse: [],phase_inventory: inventory,material_balances: balances,
        material_units_per_micro: s.material_units_per_micro}
      assert :ok=DatabaseMetadataLog.append(elem(s.log,1),txn)
      w=start_supervised!({World,Keyword.put(c.opts,:log,DatabaseMetadataLog)})
      w=if unquote(checkpoint) do
        assert :ok=World.compact(w)
        stop_supervised!(World)
        start_supervised!({World,Keyword.put(c.opts,:log,DatabaseMetadataLog)})
      else
        w
      end
      restored=:sys.get_state(w)
      assert restored.material_balances==balances
      assert restored.phase_inventory==inventory
    end
  end

  @tag :phase_coverage
  test "采掘途中真实热损伤和非Pick攻击扣减基准，零HP不能借基准修复",c do
    expanded_phase_catalog(c)
    deposits=Path.join(c.root,"harvest-deposit.json")
    File.write!(deposits,Jason.encode!(%{deposits: [%{macro: [63,1,2],material: 13}]}))
    assert {:ok,_}=World.liquid_experiment(c.w,deposits)
    assert {:ok,_}=operate(c,1,1)
    # 只测试：降低夹具耐热阈值，保留相族焓/温度一致并沿真实NIF路径产生HP损失。
    data=Jason.decode!(File.read!(c.catalog)) |> Map.update!("materials",fn materials ->
      Enum.map(materials,fn m -> if m["material_id"]==13,do: Map.put(m,"heat_resistance_kelvin",293.0),else: m end)
    end)
    File.write!(c.catalog,Jason.encode!(data))
    assert :ok=World.publish_parameters(c.w,c.catalog,:sys.get_state(c.w).properties.digest)
    heat=Path.join(c.root,"pick-heat.json")
    File.write!(heat,Jason.encode!(%{classification: "Test-only",source_macro: [63,1,2],
      ambient_kelvin: 293.15,environment_w_per_m2_k: 0.01,tolerance_kelvin: 0.00001,power_w: 1.0,energy_j: 1.0}))
    assert :ok=World.thermal_experiment(c.w,heat)
    send(c.w,:thermal_commit)
    heated=row(c.w,{63,1,2})
    assert heated.hp<78.0
    assert heated.pick_baseline_hp==100.0-(78.0-heated.hp)
    assert {:ok,_}=operate(c,19,2)
    attacked=row(c.w,{63,1,2})
    assert attacked.pick_baseline_hp==heated.pick_baseline_hp-(heated.hp-attacked.hp)
    for seq<-3..5,do: assert({:ok,_}=operate(c,19,seq))
    assert elem(:sys.get_state(c.w).phase_inventory[{1001,13}],1)==0.0
    build=%{request_id: 6,client_intent_seq: 6,logical_scene_id: 1,action: 1,material: 13,tool_id: 1,coord: {63,1,2}}
    assert {:error,:broken_material}=World.production_intent(c.w,c.actor,build)
  end

  @tag :phase_coverage
  test "新增雪和玄武岩由同一作者事务初始化，付费熔岩搬运与冷恢复不补焓",c do
    expanded_phase_catalog(c)
    deposits=Path.join(c.root,"phase-deposits.json")
    File.write!(deposits,Jason.encode!(%{deposits: [%{macro: [63,1,2],material: 13},%{macro: [65,1,2],material: 4}]}))
    assert {:ok,_}=World.liquid_experiment(c.w,deposits)
    initial=row(c.w,{63,1,2})
    assert initial.material==13 and initial.hp==100.0
    assert_in_delta initial.phase_energy_j,-31_102_500.0,1.0e-6
    assert :sys.get_state(c.w).liquid_units[{65,1,2}]==@capacity
    assert {:ok,_}=operate(c,14,1,{63,1,2})
    lava=row(c.w,{63,1,2})
    assert lava.material==22
    actor=Map.merge(c.actor,%{received_us: 2_000_000,clock_node: node()})
    assert {:ok,_}=World.production_intent(c.w,actor,%{request_id: 2,client_intent_seq: 2,
      logical_scene_id: 1,action: 2,material: 22,tool_id: 11,coord: {63,1,2}})
    saved=:sys.get_state(c.w)
    assert saved.material_balances[{1001,22}]==@quarter
    assert_in_delta elem(saved.phase_inventory[{1001,22}],0),lava.phase_energy_j/4,1.0e-6
    assert {:ok,_}=operate(c,14,3,{65,1,2})
    assert row(c.w,{65,1,2}).material==21
    for seq<-4..9,do: assert({:ok,_}=operate(c,13,seq,{65,1,2}))
    assert row(c.w,{65,1,2}).material==20
    assert :sys.get_state(c.w).liquid_units[{65,1,2}]==@capacity
    # 普通倒入另一格并凝固，量与携带焓沿同一库存SSOT结算。
    actor=Map.merge(c.actor,%{received_us: 10_000_000,clock_node: node()})
    assert {:ok,_}=World.production_intent(c.w,actor,%{request_id: 10,client_intent_seq: 10,
      logical_scene_id: 1,action: 3,material: 22,tool_id: 12,coord: {64,1,2}})
    assert row(c.w,{64,1,2}).material==22
    assert_in_delta row(c.w,{64,1,2}).phase_energy_j,lava.phase_energy_j/4,1.0e-6
    assert {:ok,_}=operate(c,13,11,{64,1,2})
    assert row(c.w,{64,1,2}).material==13
    assert :sys.get_state(c.w).liquid_units[{64,1,2}]==@quarter
    saved=:sys.get_state(c.w)
    assert :ok=World.compact(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,Keyword.put(c.opts,:production_materials,[4,13,15,20,21,22])})
    recovered=:sys.get_state(w)
    assert recovered.phase_inventory==saved.phase_inventory
    assert recovered.liquid_units==saved.liquid_units
    assert recovered.thermal.phase_authored_units==3*@capacity
  end

  test "fully broken Ice stays finite carried fragments and cannot build a zero-HP collider",c do
    for batch<-0..3 do
      seq=batch*10+1
      assert {:ok,_}=transfer(c,3,seq,{63,1,2})
      freeze(c,seq+1)
      Enum.reduce_while((seq+3)..(seq+8),nil,fn attack,_ ->
        if row(c.w,{63,1,2})==nil,do: {:halt,nil},else: (assert {:ok,_}=operate(c,19,attack); {:cont,nil})
      end)
    end
    s=:sys.get_state(c.w)
    assert s.liquid_units==%{}
    assert s.material_balances[{1001,20}]==@capacity
    assert elem(s.phase_inventory[{1001,20}],1)==0.0
    before=:sys.get_state(c.w)
    build=%{request_id: 40,client_intent_seq: 40,logical_scene_id: 1,action: 1,material: 20,tool_id: 1,coord: {64,1,2}}
    assert {:error,:broken_material}=World.production_intent(c.w,c.actor,build)
    after_reject=:sys.get_state(c.w)
    assert after_reject.material_balances==before.material_balances
    assert after_reject.phase_inventory==before.phase_inventory
    assert after_reject.liquid_units==%{}
  end

  @tag water_units: 28
  test "real thin-water mining seam skips water for stone and phase ray uses exact height",c do
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
    assert {:ok,_}=operate(c,14,4)
    before=:sys.get_state(c.w)
    energy=row(c.w,{63,1,2}).phase_energy_j
    assert row(c.w,{63,1,2}).material==20
    send(c.w,:thermal_commit)
    next=:sys.get_state(c.w)
    water=row(c.w,{63,1,2})
    assert water.material==21 and water.phase_energy_j>=83_500_000.0
    assert next.liquid_units==%{{63,1,2}=>@quarter}
    assert_in_delta water.phase_energy_j,energy+next.thermal.environment_j-before.thermal.environment_j,0.01
    assert total(c.w)==@capacity
  end

  @tag :cold_coverage
  @tag :realtime
  @tag water_units: 4096
  @tag timeout: 240_000
  test "普通冷板投料通过真实接触冻结水，不调用相变工具或改写目标温度",c do
    # 只测试：小样数量与有限电源由夹具给出；水的焓只由正常倒水/接触生成。
    data=Jason.decode!(File.read!(c.catalog))
    materials=Enum.map(data["materials"],fn m->
      case m["material_id"] do
        11 -> Map.merge(m,%{"heat_capacity_per_macro"=>21360.0,"thermal_conductivity"=>25.0,
          "heat_resistance_kelvin"=>1000.0})
        16 -> Map.merge(m,%{"heat_capacity_per_macro"=>34500.0,"thermal_conductivity"=>4000.0,
          "heat_resistance_kelvin"=>1000.0,"electrical_conductivity"=>58.0e6})
        _ -> m
      end
    end)
    devices=for {id,kind,r,v}<-[{15,1,1.0,240.0},{16,2,0.01,0.0},{17,5,1.0,0.0}],do:
      %{"tool_id"=>id,"id"=>"cold_test_#{id}","action"=>"circuit.install","power"=>1.0,
        "range_macro"=>8.0,"interval_seconds"=>0.1,"circuit_kind"=>kind,
        "circuit_resistance_ohm"=>r,"circuit_voltage_v"=>v,"circuit_light_fraction"=>0.0,
        "circuit_cooling_cop"=>3.0,"circuit_min_kelvin"=>250.0}
    tools=Enum.map(data["tools"],fn t->if t["tool_id"]==8,do: Map.merge(t,%{
      "fuel_material_id"=>15,"fuel_units"=>4,"circuit_energy_j"=>6_250_000.0}),else: t end)
    File.write!(c.catalog,Jason.encode!(%{data | "materials"=>materials,"tools"=>tools++devices}))
    assert :ok=World.publish_properties(c.w,c.catalog)
    assert {:ok,_}=World.apply_edit(c.w,{-6,1,-4},16)
    assert :ok=VoxelRegion.TestSupport.mine_authored(c.w,1001)
    assert {:ok,_}=World.apply_edits(c.w,for(x<-61..63,do: {{x,0,2},11}))
    base=%{request_id: 1,client_intent_seq: 1,logical_scene_id: 1,action: 0,
      kind: 0,axis: 1,size: 8,anchor: {488,8,16},id: 0,material: 16,tool_id: 1}
    ids=for x<-61..63 do
      assert {:ok,id}=World.attachment_intent(c.w,c.actor,%{base | anchor: {x*8,8,16},request_id: x,client_intent_seq: x})
      id
    end
    for {{axis,p},i}<-Enum.with_index([{2,{488,8,16}},{2,{512,8,16}},{0,{488,8,24}},{0,{496,8,24}},{0,{504,8,24}}]) do
      assert {:ok,_}=World.attachment_intent(c.w,c.actor,%{base | kind: 1,axis: axis,anchor: p,request_id: 70+i,client_intent_seq: 70+i})
    end
    use=fn index,tool,seq->
      id=Enum.at(ids,index)
      request=%{request_id: seq,client_intent_seq: seq,logical_scene_id: 1,action: 1,tool_id: tool,
        direction: {0.0,-1.0,0.0},micro: {(61+index)*8,8,16},granularity: 3,
        owner: {id,1},incarnation: id,material: 16}
      World.tool_intent(c.w,Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()}),request)
    end
    for index<-0..2,do: assert({:ok,_}=use.(index,15+index,80+index))
    assert {:ok,_}=transfer(c,3,90,{63,1,2})
    assert row(c.w,{63,1,2}).material==21
    initial=row(c.w,{63,1,2}).phase_energy_j
    assert_in_delta initial,815625.0,0.001
    coal_before=:sys.get_state(c.w).material_balances[{1001,15}]
    assert {:ok,_}=use.(0,8,91)
    assert :sys.get_state(c.w).material_balances[{1001,15}]==coal_before-16384
    frozen=Enum.reduce_while(1..400,nil,fn tick,_->
      # Let the real World timer advance. Manually injecting each commit also
      # schedules another timer and creates an ever-growing test-only backlog.
      receive do after 500 -> :ok end
      state=:sys.get_state(c.w)
      if tick<=10 or rem(tick,10)==0 do
        source=Map.get(state.damage,{3,hd(ids)})
        temperatures=for {_,r}<-state.damage,r.granularity==4 and r.incarnation==hd(ids),do: r.temperature_kelvin
        IO.puts("COLD_PROGRESS #{inspect(%{tick: tick,water: Map.take(row(c.w,{63,1,2}),[:material,:temperature_kelvin,:phase_energy_j]),source: source && source.circuit,
          source_max_kelvin: Enum.max(temperatures,fn->0 end),cooling_j: state.thermal.circuit_cooling_j})}")
      end
      if row(c.w,{63,1,2}).material==20,do: {:halt,state},else: {:cont,state}
    end)
    assert row(c.w,{63,1,2}).material==20
    assert frozen.liquid_units==%{{63,1,2}=>4096}
    assert row(c.w,{63,1,2}).hp==row(c.w,{63,1,2}).max_hp
    assert frozen.thermal.circuit_cooling_j>initial
    assert frozen.damage[{3,hd(ids)}].circuit.remaining_j<6_250_000.0
    assert_in_delta frozen.thermal.supplied_j+frozen.thermal.circuit_rejected_j+
      frozen.thermal.circuit_light_j,frozen.thermal.circuit_supplied_j,0.001
    assert :ok=World.compact(c.w)
    # 只测试：冻结采样与停止边界，比较最后实际持久化状态。
    :ok=:sys.suspend(c.w)
    persisted=:sys.get_state(c.w)
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    :ok=:sys.suspend(w)
    restored=:sys.get_state(w)
    assert restored.damage==persisted.damage
    assert restored.liquid_units==persisted.liquid_units
    assert restored.thermal==persisted.thermal
  end
end
