defmodule VoxelRegion.CombustionWorldTest do
  @moduledoc "只测试：正式B6目录与World意图、热事务、回放接缝。"
  use ExUnit.Case, async: false
  @moduletag :b6
  alias VoxelRegion.{World, Damage}
  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  setup do
    root=Path.join(System.tmp_dir!(),"b6_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    source=System.get_env("B6_CATALOG") || VoxelRegion.TestSupport.catalog()
    catalog=Path.join(root,"properties.json")
    File.cp!(source,catalog)
    env=Path.join(root,"environment.json")
    File.write!(env,Jason.encode!(%{ambient_kelvin: 293.15,environment_w_per_m2_k: 10.0,tolerance_kelvin: 0.01}))
    prefab=Path.join(root,"prefabs")
    File.mkdir_p!(prefab)
    bytes=<<"VXPD",1::32-little,1::32-little,0::signed-little-32,0::signed-little-32,0::signed-little-32,19::16-little,0::32-little>>
    File.write!(Path.join(prefab,"wood.vxpd"),bytes)
    opts=[source: Source,log: Log,root: root,observer: self(),property_catalog_path: catalog,
      thermal_environment_path: env,prefab_catalog_path: prefab,name: nil,production_materials: [8,15,19,11]]
    w=start_supervised!({World,opts})
    actor=%{cid: 1001,gate: self(),identity: :test_session,refresh: &Actor.tool_context/2,eye: {1.0625,1.0625,0.0625},tick_us: 16_667}
    actor=Map.put(actor,:player,start_supervised!({Actor,actor}))
    request=%{request_id: 1,client_intent_seq: 1,logical_scene_id: 1,action: 0,granularity: 0,
      direction: {0.0,0.0,1.0},micro: {0,0,0},incarnation: 0,owner: {0,0},material: 0,tool_id: 9}
    # 只测试：一次作者样本，再正常挖采获取燃料与冷却材料；不写库存真值。
    for material <- [15,8] do
      {:ok,_}=World.apply_edit(w,{-6,1,-4},material)
      :ok=VoxelRegion.TestSupport.mine_authored(w,1001)
    end
    on_exit(fn->File.rm_rf!(root) end)
    %{w: w,actor: actor,request: request,opts: opts,catalog: catalog,id: :crypto.hash(:sha256,bytes)}
  end

  defp operate(c,tool,seq) do
    {:ok,target}=World.tool_intent(c.w,c.actor,c.request)
    r=Map.merge(c.request,Map.take(target,[:micro,:granularity,:incarnation,:owner,:material]))
      |> Map.merge(%{action: 1,tool_id: tool,client_intent_seq: seq,request_id: seq})
    World.tool_intent(c.w,Map.merge(c.actor,%{received_us: seq*1_000_000,clock_node: node()}),r)
  end
  defp tick(w) do
    send(w,:thermal_commit)
    :sys.get_state(w)
  end
  defp row(w,micro),do: Enum.find(Map.values(:sys.get_state(w).damage),&(&1.micro==micro and &1.granularity in [0,1,4]))

  # 只测试：缩短燃料寿命以验证真正耗尽，保持热容量、功率和结算入口不变。
  defp short_fuel(c) do
    data=Jason.decode!(File.read!(c.catalog))
    data=Map.update!(data,"materials",&Enum.map(&1,fn m ->
      if m["material_id"]==19,do: Map.put(m,"fuel_energy_per_macro_j",900.0),else: m
    end))
    File.write!(c.catalog,Jason.encode!(data))
    :ok=World.publish_properties(c.w,c.catalog)
  end

  defp wood_balance(w),do: Map.get(:sys.get_state(w).material_balances,{1001,19},0)

  test "自然耗尽同笔删除宏格，燃料账闭合且冷恢复不复活",c do
    short_fuel(c)
    {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,_}=operate(c,9,1)
    tick(c.w)
    before=:sys.get_state(c.w)
    assert row(c.w,{8,8,16}).remaining_fuel_j>0
    saved=tick(c.w)
    assert row(c.w,{8,8,16})==nil
    assert elem(saved.overlay[{0,{1,1,2}}],0)==0
    assert saved.material_balances==before.material_balances
    assert_in_delta saved.thermal.combustion_j,900.0,1.0e-7
    assert_in_delta saved.thermal.fuel_initialized_j,saved.thermal.combustion_j+saved.thermal.discarded_fuel_j,1.0e-7
    [txn]=World.entries_after(c.w,before.seq)
    assert Enum.any?(txn.property_states,&(&1.micro=={8,8,16} and &1.flags==1 and &1.request_id==0))
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert :sys.get_state(w).damage==saved.damage
    assert :sys.get_state(w).thermal==saved.thermal
    assert elem(:sys.get_state(w).overlay[{0,{1,1,2}}],0)==0
  end

  test "部分燃料宏格采掘只回收余量，不能原价重建补满燃料",c do
    short_fuel(c)
    {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,_}=operate(c,9,1)
    tick(c.w)
    assert {:ok,_}=operate(c,10,2)
    fuel=row(c.w,{8,8,16}).remaining_fuel_j
    assert fuel>0 and fuel<900.0
    Enum.reduce_while(3..20,nil,fn seq,_ ->
      if row(c.w,{8,8,16})==nil,do: {:halt,nil},else: (
        assert {:ok,_}=operate(c,1,seq)
        {:cont,nil})
    end)
    assert wood_balance(c.w)==floor(2_097_152*fuel/900.0)
    build=%{request_id: 30,client_intent_seq: 30,logical_scene_id: 1,action: 1,coord: {1,1,2},tool_id: 1,material: 19}
    assert {:error,:insufficient_material}=World.production_intent(c.w,c.actor,build)
  end

  for x <- [8, 512, 1024] do
  @tag :tail_structure
  test "精确微格燃尽删除所属叶子且不产生材料奖励 x=#{x}",c do
    x = unquote(x)
    micro = {x,8,16}
    GenServer.call(c.actor.player,{:eye,{x/8+0.0625,1.0625,0.0625}})
    short_fuel(c)
    {:ok,birth}=World.place_prefab(c.w,c.id,micro,0)
    assert {:ok,_}=operate(c,9,1)
    tick(c.w)
    before=:sys.get_state(c.w)
    saved=tick(c.w)
    refute Map.has_key?(saved.instances,{birth,0})
    assert saved.refined==%{}
    assert row(c.w,micro)==nil
    assert wood_balance(c.w)==0
    assert_in_delta saved.thermal.combustion_j,900.0/512,1.0e-8
    # 只测试：烧毁走 apply_batch，粗层只发布空结构；跨区 L0 owner/ring 仍完整。
    txn=saved.entries[saved.seq]
    alias MmoContracts.Voxel.{Codec,Payload}
    payloads=for %{payload: bytes} <- txn.entries,do: ( {:ok,p}=Payload.decode(bytes); p )
    assert payloads != []
    assert Enum.all?(payloads,&(&1.level==0 and &1.refined==%{}))
    if x==512,do: assert(Enum.sort(Enum.map(payloads,& &1.region))==[{0,0,0},{1,0,0}])
    structures=for %{structure: grid,level: l,cell: cell} <- txn.entries,into: %{},do: {{l,cell},grid}
    assert structures==Map.new(before.structure,fn {key,_}->{key,<<>>} end)
    assert map_size(structures)==5
    assert {:ok,decoded}=Codec.decode_transaction(IO.iodata_to_binary(Codec.encode_transaction(txn)))
    assert decoded.entries==txn.entries
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert :sys.get_state(w).damage==saved.damage
    assert :sys.get_state(w).refined==%{}
    assert :sys.get_state(w).structure==%{}
  end
  end

  test "木面槽按实际体积点燃与耗尽，删除附件而不删除宿主",c do
    short_fuel(c)
    {:ok,_}=World.apply_edit(c.w,{1,1,2},11)
    {:ok,_}=World.place_prefab(c.w,c.id,{-48,8,-32},0)
    :ok=VoxelRegion.TestSupport.mine_authored(c.w,1001)
    r=%{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 0,
      kind: 0,axis: 2,size: 1,anchor: {8,8,16},id: 0,material: 19,tool_id: 1}
    assert {:ok,id}=World.attachment_intent(c.w,c.actor,r)
    request=Map.merge(c.request,%{granularity: 3,micro: r.anchor,owner: {id,2},incarnation: id,material: 19})
    ctx=%{c | request: request}
    balances=:sys.get_state(c.w).material_balances
    assert {:ok,_}=operate(ctx,9,11)
    lit=row(c.w,{8,8,16})
    assert lit.granularity==4
    assert_in_delta lit.remaining_fuel_j,900.0*64/2_097_152,1.0e-9
    assert balances[{1001,15}]-:sys.get_state(c.w).material_balances[{1001,15}]==8
    tick(c.w)
    saved=tick(c.w)
    assert saved.attachments==%{}
    assert elem(saved.overlay[{0,{1,1,2}}],0)==11
    assert wood_balance(c.w)==4096-64
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert :sys.get_state(w).damage==saved.damage
    assert :sys.get_state(w).attachments==%{}
  end

  test "旧版已耗尽但保留占用的冷存档醒来结算，不虚构初始化燃料",c do
    {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,_}=operate(c,9,1)
    assert :ok=World.compact(c.w)
    {backend,path}=:sys.get_state(c.w).log
    stop_supervised!(World)
    [checkpoint]=backend.replay(path)
    # 只测试旧版本存档：离线制造旧格式，重启必须自行识别耗尽记录。
    rows=Enum.map(checkpoint.property_states,&Map.merge(&1,%{remaining_fuel_j: 0.0,burning: false,power_w: 0.0,temperature_kelvin: 293.15}))
    thermal=checkpoint.thermal |> Map.put(:active,false) |> Map.put(:combustion_j,90_000.0) |> Map.delete(:fuel_initialized_j)
    assert :ok=backend.checkpoint(path,%{checkpoint | property_states: rows,thermal: thermal})
    w=start_supervised!({World,c.opts})
    assert :sys.get_state(w).thermal.active
    saved=tick(w)
    assert elem(saved.overlay[{0,{1,1,2}}],0)==0
    assert Map.get(saved.thermal,:fuel_initialized_j,0.0)==0.0
    assert saved.thermal.combustion_j==90_000.0
    assert wood_balance(w)==0
  end

  test "B3受控有限热源达到阈值即可点燃，不要求先存在火种",c do
    {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    path=Path.join(c.opts[:root],"heat-ignition.json")
    File.write!(path,Jason.encode!(%{classification: "Test-only",source_macro: [1,1,2],
      ambient_kelvin: 293.15,environment_w_per_m2_k: 10.0,tolerance_kelvin: 0.01,
      power_w: 60_000.0,energy_j: 30_000.0}))
    assert :ok=World.thermal_experiment(c.w,path)
    tick(c.w)
    assert row(c.w,{8,8,16}).temperature_kelvin>=300.0
    assert row(c.w,{8,8,16}).burning
    assert :sys.get_state(c.w).thermal.combustion_j>0
  end

  test "熄灭微格后拆卸叶子只回收剩余化学燃料比例",c do
    short_fuel(c)
    {:ok,_}=World.place_prefab(c.w,c.id,{8,8,16},0)
    assert {:ok,_}=operate(c,9,1)
    tick(c.w)
    assert {:ok,_}=operate(c,10,2)
    fuel=row(c.w,{8,8,16}).remaining_fuel_j
    assert {:ok,_}=operate(c,1,3)
    assert :sys.get_state(c.w).refined==%{}
    assert wood_balance(c.w)==floor(4096*fuel/(900.0/512))
  end

  test "熄灭附件后拆卸只回收槽余料且保留宿主",c do
    short_fuel(c)
    {:ok,_}=World.apply_edit(c.w,{1,1,2},11)
    {:ok,_}=World.place_prefab(c.w,c.id,{-48,8,-32},0)
    :ok=VoxelRegion.TestSupport.mine_authored(c.w,1001)
    r=%{request_id: 10,client_intent_seq: 10,logical_scene_id: 1,action: 0,
      kind: 0,axis: 2,size: 1,anchor: {8,8,16},id: 0,material: 19,tool_id: 1}
    assert {:ok,id}=World.attachment_intent(c.w,c.actor,r)
    request=Map.merge(c.request,%{granularity: 3,micro: r.anchor,owner: {id,2},incarnation: id,material: 19})
    ctx=%{c | request: request}
    assert {:ok,_}=operate(ctx,9,11)
    tick(c.w)
    assert {:ok,_}=operate(ctx,10,12)
    fuel=:sys.get_state(c.w).damage[Damage.key(%{request | granularity: 4})].remaining_fuel_j
    assert {:ok,_}=World.attachment_intent(c.w,c.actor,%{r | action: 1,id: id,request_id: 13,client_intent_seq: 13})
    assert :sys.get_state(c.w).attachments==%{}
    assert wood_balance(c.w)==4096-64+floor(64*fuel/(900.0*64/2_097_152))
  end

  test "无电路点火激活有限燃烧，冷却保留余料，失败回滚且可回放",c do
    {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    before=:sys.get_state(c.w)
    assert {:ok,seq}=operate(c,9,1)
    lit=row(c.w,{8,8,16})
    assert lit.seq==seq and lit.request_id==0 and lit.burning
    assert lit.remaining_fuel_j==90_000.0 and lit.power_w==900.0
    state=:sys.get_state(c.w)
    assert state.thermal.active and state.thermal.supplied_j==30_000.0
    assert before.material_balances[{1001,15}]-state.material_balances[{1001,15}]==64*4096
    state=tick(c.w)
    burning=row(c.w,{8,8,16})
    assert burning.remaining_fuel_j<90_000.0
    assert_in_delta state.thermal.combustion_j,90_000.0-burning.remaining_fuel_j,1.0e-5
    {_,path}=state.log
    File.write!(path<>".reject","")
    assert {:error,:test_disk_failure}=operate(c,10,2)
    assert Map.take(:sys.get_state(c.w),[:damage,:thermal,:material_balances,:seq])==Map.take(state,[:damage,:thermal,:material_balances,:seq])
    File.rm!(path<>".reject")
    assert {:ok,_}=operate(c,10,2)
    cooled=row(c.w,{8,8,16})
    refute cooled.burning
    assert cooled.power_w==0.0 and cooled.temperature_kelvin==293.15
    assert cooled.remaining_fuel_j==burning.remaining_fuel_j
    saved=:sys.get_state(c.w)
    assert saved.thermal.combustion_removed_j>0
    stop_supervised!(World)
    w=start_supervised!({World,c.opts})
    assert :sys.get_state(w).damage==saved.damage
    assert :sys.get_state(w).material_balances==saved.material_balances
    assert :sys.get_state(w).thermal==saved.thermal
    assert {:ok,_}=operate(%{c | w: w},9,3)
    assert row(w,{8,8,16}).remaining_fuel_j==cooled.remaining_fuel_j
  end

  test "真实订阅的点火、热演进与熄灭批次保持广播请求号零",c do
    {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    :ok=World.canonical_snapshot_and_subscribe(c.w,{{0,0,0},{1,1,1}},self(),:combustion,false)
    assert_receive {:canonical_snapshot,:combustion,_}
    assert {:ok,_}=operate(c,9,10)
    assert_broadcast_batch()
    tick(c.w)
    assert_broadcast_batch()
    assert {:ok,_}=operate(c,10,11)
    assert_broadcast_batch()
  end

  defp assert_broadcast_batch do
    assert_receive {:canonical_delta,delta}
    assert delta.transaction.property_states != []
    packets=Enum.map(delta.transaction.property_states,fn row ->
      {:ok,packet}=MmoContracts.Voxel.Codec.encode({:voxel_property_state,row})
      bytes=IO.iodata_to_binary(packet)
      assert <<0x7E,0::64,seq::64,_::binary>>=bytes
      assert seq==delta.transaction_seq
      bytes
    end)
    batch=%MmoContracts.Voxel.PropertyBatch{
      identity: %MmoContracts.Session.Identity{session_epoch: 1,scene_id: 1,scene_epoch: 1},
      transaction_seq: delta.transaction_seq,l0_min: {0,0,0},l0_max_exclusive: {1,1,1},
      complete: 0,hp_enabled: 1,digest: hd(delta.transaction.property_states).digest,
      thermal_enabled: 1,ambient_kelvin: 293.15,epochs: <<>>,states: packets}
    assert {:ok,encoded}=MmoContracts.Voxel.Codec.encode_m1(batch)
    assert {:ok,^batch}=MmoContracts.Voxel.Codec.decode_m1(encoded)
  end

  test "接触链传播，空气与黏土隔断，非热材料点火拒绝",c do
    {:ok,_}=World.apply_edits(c.w,[{{1,1,2},19},{{1,1,3},19},{{1,1,4},19},{{2,1,2},8},{{3,1,2},19},{{-1,1,2},19}])
    assert {:ok,_}=operate(c,9,1)
    Enum.each(1..8,fn _->tick(c.w) end)
    assert row(c.w,{8,8,24}).burning
    assert row(c.w,{8,8,32}).burning
    refute Map.get(row(c.w,{24,8,16}) || %{},:burning,false)
    refute Map.get(row(c.w,{-8,8,16}) || %{},:burning,false)
    {:ok,_}=World.apply_edit(c.w,{1,1,2},11)
    assert {:error,:not_combustible}=operate(c,9,2)
    assert Process.alive?(c.w)
  end

  test "精确refined命中用真实微格体积收费、供热与余料",c do
    {:ok,_}=World.place_prefab(c.w,c.id,{8,8,16},0)
    before=:sys.get_state(c.w)
    assert {:ok,_}=operate(c,9,1)
    lit=row(c.w,{8,8,16})
    assert lit.granularity==1
    assert lit.remaining_fuel_j==90_000.0/512 and lit.power_w==900.0/512
    assert before.material_balances[{1001,15}]-:sys.get_state(c.w).material_balances[{1001,15}]==512
    tick(c.w)
    assert row(c.w,{8,8,16}).remaining_fuel_j<lit.remaining_fuel_j
    assert {:ok,_}=operate(c,10,2)
    refute row(c.w,{8,8,16}).burning
    assert row(c.w,{8,8,16}).power_w==0
  end

  test "旧目录新增三字段保留全部状态，已有参数改值仍拒绝",c do
    full=Jason.decode!(File.read!(c.catalog))
    fields = ~w(ignition_kelvin fuel_energy_per_macro_j burn_power_per_macro_w)
    old=Map.update!(full,"materials",&Enum.map(&1,fn m->Map.drop(m,fields) end))
    File.write!(c.catalog,Jason.encode!(old))
    assert :ok=World.publish_properties(c.w,c.catalog)
    {:ok,_}=World.apply_edit(c.w,{1,1,2},19)
    assert {:ok,_}=operate(c,1,1)
    before=:sys.get_state(c.w)
    File.write!(c.catalog,Jason.encode!(full))
    assert :ok=World.publish_properties(c.w,c.catalog)
    after_publish=:sys.get_state(c.w)
    assert Map.take(after_publish,[:overlay,:refined,:attachments,:thermal,:material_balances])==Map.take(before,[:overlay,:refined,:attachments,:thermal,:material_balances])
    clean=fn rows->Map.new(rows,fn {k,t}->{k,Map.drop(t,[:seq,:digest,:request_id])} end) end
    assert clean.(before.damage)==clean.(after_publish.damage)
    changed=Map.update!(full,"materials",&Enum.map(&1,fn m->if m["material_id"]==19,do: Map.put(m,"fuel_energy_per_macro_j",180_000.0),else: m end))
    File.write!(c.catalog,Jason.encode!(changed))
    assert {:error,:property_version_in_use}=World.publish_properties(c.w,c.catalog)
  end
end
