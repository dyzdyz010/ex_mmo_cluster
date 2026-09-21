defmodule VoxelRegion.PrefabMacroWorldTest do
  # Test-only: real World, author definitions, player payment and durable logs.
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.TestSupport.{Source, Actor}

  setup context do
    if context[:database], do: MmoTest.Database.start!()
    root = Path.join(System.tmp_dir!(), "prefab_macro_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    properties = Path.join(root, "properties.json")
    File.write!(properties, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}],
      materials: for(m <- 0..23, do: %{material_id: m, max_hp_per_macro: if(m == 0, do: 0, else: 100),
        defense: 2, tags: [], responses: [%{action: "damage", multiplier: 1}]}),
      tools: [%{id: "pick", tool_id: 1, action: "damage", power: 30, range_macro: 6,
        interval_seconds: 0.5}], definitions: []}))
    opts = [source: Source, root: root, observer: self(), name: nil,
      property_catalog_path: properties, prefab_catalog_path: nil, production_materials: [11,19]]
    opts = if context[:database] do
      :ok = DataService.Voxel.OverlayLogStore.replace(123,[])
      on_exit(fn -> DataService.Voxel.OverlayLogStore.replace(123,[]) end)
      Keyword.put(opts,:log,OverlayLog.Db)
    else
      opts
    end
    world = start_supervised!({World, opts})
    actor = %{cid: 1001, gate: self(), identity: :macro_test, refresh: &Actor.tool_context/2,
      eye: {1.0625,1.0625,0.0625}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world, root: root, opts: opts, actor: actor}
  end

  defp define(c, macros, micro \\ [], children \\ [], version \\ 3, attachments \\ []) do
    cells = fn xs -> for {{x,y,z},m} <- Enum.sort(xs), into: <<>>,
      do: <<x::signed-little-32,y::signed-little-32,z::signed-little-32,m::16-little>> end
    refs = for {id,{x,y,z},slot} <- children, into: <<>>,
      do: <<slot::32-little,id::binary-size(32),x::signed-little-32,y::signed-little-32,z::signed-little-32,0>>
    groups = for {slot,kind,axis,{x,y,z},size,m} <- attachments, into: <<>>,
      do: <<slot::32-little,kind,axis,x::signed-little-32,y::signed-little-32,z::signed-little-32,size,m::16-little>>
    tail = if version == 3, do: <<length(attachments)::32-little,groups::binary,length(macros)::32-little,cells.(macros)::binary>>, else: <<>>
    bytes = <<"VXPD",version::32-little,length(micro)::32-little,cells.(micro)::binary,
      length(children)::32-little,refs::binary,tail::binary>>
    id = :crypto.hash(:sha256, bytes)
    File.write!(Path.join([c.root,"prefabs",Base.encode16(id)<>".vxpd"]), bytes)
    id
  end

  defp publish(c), do: World.publish_prefabs(c.world, Path.join(c.root,"prefabs"))
  defp place(c, id, seq \\ 1, anchor \\ {8,8,16}) do
    World.prefab_intent(c.world, c.actor, :voxel_prefab_place_v1,
      %{definition_id: id, anchor: anchor, orientation: 0, client_intent_seq: seq})
  end
  defp balance(c, m), do: Enum.find(World.material_balances(c.world,1001),&(&1.material == m)).balance
  defp snapshot(c, cells), do: World.material_snapshot(c.world,[1001],cells)
  defp query(c), do: World.tool_intent(c.world,c.actor,%{request_id: 1,client_intent_seq: 1,
    logical_scene_id: 1,action: 0,direction: {0.0,0.0,1.0},micro: {0,0,0},incarnation: 0,
    owner: {0,0},material: 0,tool_id: 1})

  @tag :macro_provenance
  test "new legacy micro instances retain placer through log replay and checkpoint", c do
    id = define(c,[],[{{0,0,0},11}],[],1)
    assert :ok = publish(c)
    assert {:ok,1} = World.material_supply(c.world,1001,"one-micro",%{11=>1})
    assert {:ok,2} = place(c,id)
    [txn] = OverlayLog.File.replay(Path.join(c.root,"overlay.log")) |> Enum.filter(&(&1.seq == 2))
    assert get_in(txn,[:prefab_instances,{2,0},:placed_by]) == 1001
    stop_supervised(World)
    c = %{c | world: start_supervised!({World,c.opts})}
    assert :ok = World.compact(c.world)
    [checkpoint] = OverlayLog.File.replay(Path.join(c.root,"overlay.log"))
    assert get_in(checkpoint,[:prefab_instances,{2,0},:placed_by]) == 1001
  end

  test "mixed placement pays 512 per macro plus actual micro, with one owner per node", c do
    id = define(c,[{{0,0,0},11},{{1,0,0},19}],[{{16,0,0},19}])
    assert :ok = publish(c)
    assert {:ok,1} = World.material_supply(c.world,1001,"mixed",%{11=>512,19=>513})
    assert {:ok,2} = place(c,id)
    assert balance(c,11) == 0 and balance(c,19) == 0
    assert {:ok,%{granularity: 0,owner: {2,0},material: 11,hp: 100.0}} = query(c)
    rows = snapshot(c,[{1,1,2},{2,1,2},{3,1,2}]).probe_occupancy
    assert [%{material: 11,placed_by: 1001},%{material: 19,placed_by: 1001},%{material: 0,slots: [%{count: 1}]}] = rows
    assert {:ok,cells} = World.instance_cells(c.world,{2,0})
    assert Enum.sort(cells) == [{1,1,2},{2,1,2},{3,1,2}]
    assert World.stats(c.world).instances == 1
    properties = World.simulation_snapshot(c.world,[1001],{{0,0,0},{1,1,1}}).property_states
    owned = Enum.filter(properties,&(&1.granularity == 0 and &1.owner == {2,0}))
    assert Enum.sort(Enum.map(owned,&{&1.micro,&1.material,&1.hp})) == [{{8,8,16},11,100.0},{{16,8,16},19,100.0}]
    assert {:ok,3} = World.prefab_intent(c.world,c.actor,:voxel_prefab_remove_v1,%{instance_id: {2,0},client_intent_seq: 2})
    assert balance(c,11) == 512 and balance(c,19) == 513
    assert Enum.all?(snapshot(c,cells).probe_occupancy,&(&1.material == 0 and &1.slots == [] and &1.placed_by == nil))
    assert World.stats(c.world).instances == 0
  end

  test "macro alignment, refined occupancy and insufficient payment reject without mutation", c do
    id = define(c,[{{0,0,0},11}])
    old = define(c,[],[{{0,0,0},19}],[],1)
    assert :ok = publish(c)
    assert {:error,:misaligned} = World.place_prefab(c.world,id,{9,8,16},0)
    assert {:error,:insufficient_material} = place(c,id)
    assert World.seq(c.world) == 0
    assert {:ok,1} = World.place_prefab(c.world,old,{8,8,16},0)
    assert {:error,:occupied} = World.place_prefab(c.world,id,{8,8,16},0)
    assert {:ok,2} = World.apply_edit(c.world,{2,1,2},19)
    assert {:error,:occupied} = World.place_prefab(c.world,id,{16,8,16},0)
    assert World.seq(c.world) == 2
  end

  test "owned macro is an implicit leaf even while its node has a child", c do
    child = define(c,[{{0,0,0},19}])
    id = define(c,[{{0,0,0},11}],[],[{child,{0,8,0},1}])
    assert :ok = publish(c)
    assert {:ok,1} = World.material_supply(c.world,1001,"tree",%{11=>512,19=>512})
    assert {:ok,2} = place(c,id)
    assert {:ok,target} = query(c)
    assert target.owner == {2,0} and target.granularity == 0
    request = Map.merge(Map.take(target,[:micro,:incarnation,:owner,:material]),%{request_id: 9,
      client_intent_seq: 9,logical_scene_id: 1,action: 2,direction: {0.0,0.0,1.0},tool_id: 1})
    actor = Map.merge(c.actor,%{received_us: 500_000,clock_node: node()})
    assert {:ok,3} = World.tool_intent(c.world,actor,request)
    assert balance(c,11) == 512 and balance(c,19) == 0
    assert {:ok,[{1,2,2}]} = World.instance_cells(c.world,{2,0})
    assert World.stats(c.world).instances == 2
    assert {:ok,4} = World.prefab_intent(c.world,c.actor,:voxel_prefab_remove_v1,%{instance_id: {2,0},client_intent_seq: 10})
    assert balance(c,19) == 512 and World.stats(c.world).instances == 0
  end

  test "macro owner survives replay and compaction and clears only on a real edit", c do
    id = define(c,[{{0,0,0},11}])
    assert :ok = publish(c)
    assert {:ok,1} = World.material_supply(c.world,1001,"durable",%{11=>512})
    assert {:ok,2} = place(c,id)
    w = Enum.reduce([false,true],c.world,fn compact,w ->
      if compact, do: assert(:ok == World.compact(w))
      stop_supervised(World)
      w = start_supervised!({World,c.opts})
      assert {:ok,%{owner: {2,0},hp: 100.0}} = query(%{c | world: w})
      assert [%{placed_by: 1001}] = snapshot(%{c | world: w},[{1,1,2}]).probe_occupancy
      # Same material is a no-op; it must retain the macro's identity and provenance.
      assert {:ok,2} = World.apply_edit(w,{1,1,2},11)
      assert {:ok,%{owner: {2,0}}} = query(%{c | world: w})
      assert [%{placed_by: 1001}] = snapshot(%{c | world: w},[{1,1,2}]).probe_occupancy
      w
    end)
    assert {:ok,3} = World.apply_edit(w,{1,1,2},0)
    assert [%{placed_by: nil,material: 0}] = snapshot(%{c | world: w},[{1,1,2}]).probe_occupancy
    assert {:error,:instance_not_found} = World.instance_cells(w,{2,0})
    assert World.stats(w).instances == 0
  end

  for action <- [1,2] do
    @tag :mixed_micro
    test "mixed node micro action #{action} removes only the micro leaf", c do
      id = define(c,[{{0,0,0},11}],[{{8,0,0},19}])
      assert :ok = publish(c)
      assert {:ok,1} = World.material_supply(c.world,1001,"mixed-leaf",%{11=>512,19=>1})
      assert {:ok,2} = place(c,id)
      :ok = GenServer.call(c.actor.player,{:eye,{2.0625,1.0625,0.0625}})
      assert {:ok,target} = query(c)
      assert target.granularity == 2 and target.owner == {2,0}
      assert target.hp == 0.1953125 # one micro / 512 * material HP 100
      request = Map.merge(Map.take(target,[:micro,:incarnation,:owner,:material]),%{request_id: 9,
        client_intent_seq: 9,logical_scene_id: 1,action: unquote(action),direction: {0.0,0.0,1.0},tool_id: 1})
      actor = Map.merge(c.actor,%{received_us: 500_000,clock_node: node()})
      assert {:ok,3} = World.tool_intent(c.world,actor,request)
      assert balance(c,11) == 0 and balance(c,19) == 1
      assert [%{material: 11,placed_by: 1001},%{material: 0,slots: []}] = snapshot(c,[{1,1,2},{2,1,2}]).probe_occupancy
      assert {:ok,[{1,1,2}]} = World.instance_cells(c.world,{2,0})
      assert World.stats(c.world).instances == 1
      assert {:ok,4} = World.prefab_intent(c.world,c.actor,:voxel_prefab_remove_v1,%{instance_id: {2,0},client_intent_seq: 10})
      assert balance(c,11) == 512 and balance(c,19) == 1
    end
  end

  @tag :database
  test "database macro ownership and placer survive append, checkpoint and final deletion", c do
    id = define(c,[{{0,0,0},11}])
    assert :ok = publish(c)
    assert {:ok,1} = World.material_supply(c.world,1001,"db-macro",%{11=>512})
    assert {:ok,2} = place(c,id)
    c = Enum.reduce([false,true],c,fn compact,c ->
      if compact, do: assert(:ok == World.compact(c.world))
      stop_supervised(World)
      c = %{c | world: start_supervised!({World,c.opts})}
      assert {:ok,%{owner: {2,0},hp: 100.0}} = query(c)
      assert [%{material: 11,placed_by: 1001}] = snapshot(c,[{1,1,2}]).probe_occupancy
      assert [txn] = OverlayLog.Db.replay(123) |> Enum.filter(&(&1.seq == 2))
      assert txn.macro_owners == %{{1,1,2}=>{2,0}}
      assert txn.prefab_instances[{2,0}].placed_by == 1001
      c
    end)
    assert {:ok,3} = World.apply_edit(c.world,{1,1,2},0)
    stop_supervised(World)
    c = %{c | world: start_supervised!({World,c.opts})}
    assert World.stats(c.world).instances == 0
    assert [%{material: 0,placed_by: nil}] = snapshot(c,[{1,1,2}]).probe_occupancy
  end

  test "four material hits kill one owned macro and refund exactly once", c do
    id = define(c,[{{0,0,0},11},{{1,0,0},19}])
    assert :ok = publish(c)
    assert {:ok,1} = World.material_supply(c.world,1001,"hit-macro",%{11=>512,19=>512})
    assert {:ok,2} = place(c,id)
    assert {:ok,target} = query(c)
    # power 30 - defense 2 = 28, independent of the instance's second macro.
    for {hit,hp} <- [{1,72.0},{2,44.0},{3,16.0},{4,0.0}] do
      actor = Map.merge(c.actor,%{received_us: hit*500_000,clock_node: node()})
      request = Map.merge(Map.take(target,[:micro,:incarnation,:owner,:material]),%{request_id: hit,
        client_intent_seq: hit,logical_scene_id: 1,action: 1,direction: {0.0,0.0,1.0},tool_id: 1})
      assert {:ok,seq} = World.tool_intent(c.world,actor,request)
      assert seq == hit+2
      [txn] = World.entries_after(c.world,seq-1)
      rows = Enum.filter(txn.property_states,&(&1.granularity == 0 and &1.micro == {8,8,16}))
      assert [%{hp: ^hp}] = rows
      assert balance(c,11) == if(hit == 4,do: 512,else: 0)
    end
    assert balance(c,19) == 0
    assert {:ok,[{2,1,2}]} = World.instance_cells(c.world,{2,0})
    assert [%{material: 0,placed_by: nil},%{material: 19,placed_by: 1001}] = snapshot(c,[{1,1,2},{2,1,2}]).probe_occupancy
  end

  test "mixed canonical collision has 512 solid voxels per macro and one per micro", c do
    id = define(c,[{{0,0,0},11},{{1,0,0},19}],[{{16,0,0},19}])
    assert :ok = publish(c)
    assert {:ok,1} = World.place_prefab(c.world,id,{8,8,16},0)
    payload = VoxelRegion.TestSupport.payload(c.world,0,{0,0,0})
    chunk = VoxelRegion.CollisionSource.capture(payload,{0,0,0})
    assert chunk.n == 128
    assert Enum.sum(:binary.bin_to_list(chunk.cells)) == 1025
    assert map_size(payload.instances) == 1
    assert map_size(payload.refined) == 1
    assert {:ok,2} = World.remove_prefab(c.world,{1,0})
    empty = VoxelRegion.TestSupport.payload(c.world,0,{0,0,0})
    assert empty.instances == %{} and empty.refined == %{}
    assert VoxelRegion.CollisionSource.capture(empty,{0,0,0}).n == 16
  end

  test "replacement settles macro and micro costs from the actual old tree", c do
    macro = define(c,[{{0,0,0},11}])
    micro = define(c,[],[{{0,0,0},19}],[],1)
    assert :ok = publish(c)
    assert {:ok,1} = World.material_supply(c.world,1001,"replace",%{11=>512,19=>1})
    assert {:ok,2} = place(c,macro)
    assert {:ok,3} = World.prefab_intent(c.world,c.actor,:voxel_prefab_replace_v1,
      %{instance_id: {2,0},definition_id: micro,client_intent_seq: 2})
    assert balance(c,11) == 512 and balance(c,19) == 0
    assert [%{material: 0,slots: [%{material: 19,count: 1}]}] = snapshot(c,[{1,1,2}]).probe_occupancy
    assert {:ok,4} = World.prefab_intent(c.world,c.actor,:voxel_prefab_replace_v1,
      %{instance_id: {3,0},definition_id: macro,client_intent_seq: 3})
    assert balance(c,11) == 0 and balance(c,19) == 1
    assert {:ok,%{owner: {4,0},granularity: 0,hp: 100.0}} = query(c)
    assert {:error,:instance_not_found} = World.instance_cells(c.world,{2,0})
    assert {:error,:instance_not_found} = World.instance_cells(c.world,{3,0})
    assert World.stats(c.world).instances == 1
  end


  @tag :replace_last_child
  test "replacing the last child preserves its empty parent until the commit", c do
    child = define(c,[{{0,0,0},11}])
    next = define(c,[{{0,0,0},19}])
    root = define(c,[],[],[{child,{0,0,0},1}])
    assert :ok = publish(c)
    assert {:ok,1} = World.material_supply(c.world,1001,"replace-child",%{11=>512,19=>512})
    assert {:ok,2} = place(c,root)
    assert {:ok,3} = World.prefab_intent(c.world,c.actor,:voxel_prefab_replace_v1,
      %{instance_id: {2,1},definition_id: next,client_intent_seq: 2})
    assert balance(c,11) == 512 and balance(c,19) == 0
    assert {:ok,[{1,1,2}]} = World.instance_cells(c.world,{2,0})
    assert World.stats(c.world).instances == 2
    assert {:ok,4} = World.prefab_intent(c.world,c.actor,:voxel_prefab_remove_v1,
      %{instance_id: {2,0},client_intent_seq: 3})
    assert balance(c,19) == 512 and World.stats(c.world).instances == 0
  end


  @tag :macro_attachment_refund
  test "dismantling an owned macro refunds its unsupported initial attachment", c do
    id = define(c,[{{0,0,0},11}],[],[],3,[{1,0,1,{0,8,0},8,19}])
    assert :ok = publish(c)
    # A macro is 512 units; an 8 by 8 face is 64 attachment slots, one unit each.
    assert {:ok,1} = World.material_supply(c.world,1001,"macro-face",%{11=>512,19=>64})
    assert {:ok,2} = place(c,id)
    assert balance(c,11) == 0 and balance(c,19) == 0
    assert World.stats(c.world).attachment_slots == 64
    assert {:ok,target} = query(c)
    request = Map.merge(Map.take(target,[:micro,:incarnation,:owner,:material]),%{request_id: 9,
      client_intent_seq: 9,logical_scene_id: 1,action: 2,direction: {0.0,0.0,1.0},tool_id: 1})
    actor = Map.merge(c.actor,%{received_us: 500_000,clock_node: node()})
    assert {:ok,3} = World.tool_intent(c.world,actor,request)
    assert World.stats(c.world).attachment_slots == 0
    assert World.stats(c.world).instances == 0
    assert balance(c,11) == 512 and balance(c,19) == 64
  end


  test "historical v1 payload with no new metadata replays without inventing a placer", c do
    id = define(c,[],[{{0,0,0},11}],[],1)
    assert :ok = publish(c)
    assert {:ok,1} = World.place_prefab(c.world,id,{8,8,16},0)
    assert :ok = World.compact(c.world)
    stop_supervised(World)
    path = Path.join(c.root,"overlay.log")
    [checkpoint] = OverlayLog.File.replay(path)
    # Freeze the historical persisted shape: instances exist solely in the unchanged region bytes.
    historical = Map.drop(checkpoint,[:macro_owners,:prefab_instances,:placed_by])
    assert :ok = OverlayLog.File.checkpoint(path,historical)
    c = %{c | world: start_supervised!({World,c.opts})}
    assert {:ok,%{owner: {1,0},granularity: 2,hp: 0.1953125}} = query(c)
    assert {:ok,[{1,1,2}]} = World.instance_cells(c.world,{1,0})
    assert :ok = World.compact(c.world)
    [rewritten] = OverlayLog.File.replay(path)
    assert Map.get(rewritten.prefab_instances[{1,0}],:placed_by) == nil
    assert rewritten.macro_owners == %{}
    assert {:ok,2} = World.remove_prefab(c.world,{1,0})
    assert World.stats(c.world).instances == 0
  end

end
