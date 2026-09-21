defmodule VoxelRegion.PrefabRuntimeCompileTest do
  @moduledoc "只测试：运行时定义信任边界，使用独立小例与正式纯编译入口。"
  use ExUnit.Case, async: true
  alias VoxelRegion.Prefab

  defp definition(fields), do: Map.merge(%{cells: [], macro_cells: [], children: [], attachments: []}, Map.new(fields))
  defp compile(d, catalog \\ %{}), do: Prefab.compile(Prefab.encode(d),catalog)
  defp child(id, slot, anchor \\ {0,0,0}, orientation \\ 0),
    do: %{definition_id: id, slot: slot, anchor: anchor, orientation: orientation}

  test "v3 encoding is deterministic and equals the frozen little endian definition" do
    d = definition(cells: [{{1,2,3},11}], macro_cells: [{{-1,0,0},19}])
    bytes = <<"VXPD",3::32-little,1::32-little,1::signed-little-32,2::signed-little-32,3::signed-little-32,11::16-little,
      0::32-little,0::32-little,1::32-little,-1::signed-little-32,0::signed-little-32,0::signed-little-32,19::16-little>>
    assert Prefab.encode(d) == bytes
    assert {:ok,id,compiled} = Prefab.compile(bytes,%{})
    assert id == :crypto.hash(:sha256,bytes)
    assert compiled.definition == d
    assert compiled.summary == %{macro_cells: 1,micro_cells: 1,nodes: 1,depth: 1,
      bounds: {{-8,0,0},{2,8,8}},attachment_slots: 0}
  end

  test "macro and micro counts reject the first excessive cell before expansion" do
    macros = for n <- 0..511, do: {{rem(n,16),div(n,16),0},11}
    # 16 x 16 x 2，所有轴均在16m内。
    macros = Enum.map(macros,fn {{x,y,_},m} -> {{x,rem(y,16),div(y,16)},m} end)
    assert {:ok,_,_} = compile(definition(macro_cells: macros))
    assert {:error,:macro_cell_limit} = compile(definition(macro_cells: [{{0,0,2},11}|macros]))
    micro = for x <- 0..127, y <- 0..63, do: {{x,y,0},11}
    assert {:ok,_,_} = compile(definition(cells: micro))
    assert {:error,:micro_cell_limit} = compile(definition(cells: [{{0,64,0},11}|micro]))
    assert {:ok,_} = Prefab.publish(%{author: definition(macro_cells: [{{0,0,2},11}|macros])})
  end

  test "expanded node and cell budgets count each occurrence of a shared definition" do
    assert {:ok,id,leaf} = compile(definition(cells: [{{0,0,0},11}]))
    refs = for n <- 0..62, do: child(id,n,{n,0,0})
    assert {:ok,_,root} = compile(definition(children: refs),%{id=>leaf})
    assert root.summary.nodes == 64 and root.summary.micro_cells == 63
    assert {:error,:node_limit} = compile(definition(children: refs ++ [child(id,63,{63,0,0})]),%{id=>leaf})
    big = definition(macro_cells: for(x <- 0..7,y <- 0..7,z <- 0..3,do: {{x,y,z},11}))
    assert {:ok,big_id,big_leaf} = compile(big)
    catalog = %{big_id=>big_leaf}
    assert {:ok,_,two} = compile(definition(children: [child(big_id,0),child(big_id,1,{64,0,0})]),catalog)
    assert two.summary.macro_cells == 512
    assert {:error,:macro_cell_limit} = compile(definition(children: [child(big_id,0),child(big_id,1),child(big_id,2)]),catalog)
  end

  test "depth includes the root and fails at nine without expanding the chain" do
    assert {:ok,id,leaf} = compile(definition(cells: [{{0,0,0},11}]))
    {id,catalog} = Enum.reduce(2..8,{id,%{id=>leaf}},fn depth,{id,catalog} ->
      assert {:ok,next,compiled} = compile(definition(children: [child(id,1)]),catalog)
      assert compiled.summary.depth == depth
      {next,Map.put(catalog,next,compiled)}
    end)
    assert {:error,:depth_limit} = compile(definition(children: [child(id,1)]),catalog)
  end

  test "bounding box includes volume endpoints on all axes and rotated child bounds" do
    for axis <- 0..2 do
      d = definition(cells: [{put_elem({0,0,0},axis,-64),11},{put_elem({0,0,0},axis,63),11}])
      assert {:ok,id,compiled} = compile(d)
      assert {:error,:bounds_limit} = compile(%{d | cells: [{put_elem({0,0,0},axis,-64),11},{put_elem({0,0,0},axis,64),11}]})
      if axis == 0 do
        assert {:ok,_,rotated} = compile(definition(children: [child(id,1,{0,0,0},1)]),%{id=>compiled})
        assert rotated.summary.bounds == {{-1,0,-64},{0,1,64}}
        assert {:error,:bounds_limit} = compile(definition(cells: [{{-1,0,64},19}],children: [child(id,1,{0,0,0},1)]),%{id=>compiled})
      end
    end
  end

  test "attachment budget counts size-eight face expansion rather than group count" do
    macro = for x <- 0..7,z <- 0..15,do: {{x,0,z},11}
    groups = for {{x,_,z},_} <- macro,do: %{slot: x*16+z,kind: 0,axis: 1,anchor: {x*8,8,z*8},size: 8,material: 19}
    assert {:ok,_,compiled} = compile(definition(macro_cells: macro,attachments: groups))
    assert compiled.summary.attachment_slots == 8192
    extra = %{slot: 128,kind: 0,axis: 1,anchor: {64,8,0},size: 8,material: 19}
    assert {:error,:attachment_slot_limit} = compile(definition(macro_cells: [{{8,0,0},11}|macro],attachments: groups++[extra]))
  end

  test "runtime rejects oversized raw bytes and still applies definition geometry rules" do
    assert {:error,:definition_bytes_limit} = Prefab.compile(:binary.copy(<<0>>,400_000),%{})
    assert {:error,:invalid_definition} = compile(definition([]))
    assert {:error,:definition_not_found} = compile(definition(children: [child(<<0::256>>,1)]))
    assert {:error,:overlapping_definition} = compile(definition(cells: [{{7,7,7},11}],macro_cells: [{{0,0,0},19}]))
    assert {:ok,id,leaf} = compile(definition(macro_cells: [{{0,0,0},11}]))
    assert {:error,:misaligned} = compile(definition(children: [child(id,1,{1,0,0})]),%{id=>leaf})
  end
end

defmodule VoxelRegion.PrefabRuntimePublishTest do
  @moduledoc "只测试：真实World接纳、原子文件持久化、付费放置及重启；不启动网络或客户端。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World,Prefab}
  alias VoxelRegion.TestSupport.{Source,Actor}

  setup do
    root=Path.join(System.tmp_dir!(),"prefab_publish_#{System.pid()}_#{System.unique_integer([:positive])}")
    static=Path.join(root,"static")
    File.mkdir_p!(static)
    # 冻结v1作者子件：一个木制micro。
    bytes=<<"VXPD",1::32-little,1::32-little,0::96,19::16-little,0::32-little>>
    id=:crypto.hash(:sha256,bytes)
    File.write!(Path.join(static,"leaf.vxpd"),bytes)
    opts=[source: Source,root: root,observer: self(),name: nil,prefab_catalog_path: static,
      property_catalog_path: VoxelRegion.TestSupport.catalog(),production_materials: [11,19]]
    world=start_supervised!({World,opts})
    actor=%{cid: 1001,gate: self(),identity: make_ref(),refresh: &Actor.tool_context/2,
      eye: {1.0625,1.0625,0.0625},tick_us: 16_667}
    actor=Map.put(actor,:player,start_supervised!({Actor,actor}))
    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world,root: root,opts: opts,actor: actor,child_id: id}
  end

  defp draft(c), do: %{cells: [],macro_cells: [{{0,0,0},11}],attachments: [],
    children: [%{slot: 1,definition_id: c.child_id,anchor: {8,0,0},orientation: 0}]}

  test "runtime publish is durable and immediately placeable with a static catalog child",c do
    bytes=Prefab.encode(draft(c))
    assert {:ok,id}=World.publish_prefab(c.world,c.actor,bytes)
    assert World.seq(c.world)==0
    assert id==:crypto.hash(:sha256,bytes)
    assert File.read!(Path.join([c.root,"prefabs",Base.encode16(id,case: :lower)<>".vxpd"]))==bytes
    assert World.prefab_catalog(c.world)[id].definition==draft(c)
    assert {:ok,^id}=World.publish_prefab(c.world,c.actor,bytes)
    assert {:ok,1}=World.material_supply(c.world,1001,"runtime-publish",%{11=>512*4096,19=>4096})
    assert {:ok,2}=World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,
      %{definition_id: id,anchor: {8,8,16},orientation: 0,client_intent_seq: 1})
    stop_supervised(World)
    world=start_supervised!({World,c.opts})
    assert World.prefab_catalog(world)[id].summary.macro_cells==1
    assert Enum.sort(elem(World.instance_cells(world,{2,0}),1))==[{1,1,2},{2,1,2}]
    assert {:ok,3}=World.prefab_intent(world,c.actor,:voxel_prefab_remove_v1,%{instance_id: {2,0},client_intent_seq: 2})
    assert {:ok,4}=World.prefab_intent(world,c.actor,:voxel_prefab_place_v1,
      %{definition_id: id,anchor: {8,8,16},orientation: 0,client_intent_seq: 3})
  end

  test "stale actor, invalid definition and failed disk write never enter the live catalog",c do
    bytes=Prefab.encode(draft(c))
    assert {:error,:invalid_state}=World.publish_prefab(c.world,%{c.actor | identity: :wrong},bytes)
    assert {:error,:invalid_definition}=World.publish_prefab(c.world,c.actor,<<"VXPD">>)
    assert map_size(World.prefab_catalog(c.world))==1
    # 合法写入被真实文件冲突拒绝，不改在线World内部状态。
    File.write!(Path.join(c.root,"prefabs"),"not a directory")
    assert {:error,{:prefab_persist,_}}=World.publish_prefab(c.world,c.actor,bytes)
    assert map_size(World.prefab_catalog(c.world))==1
    assert World.seq(c.world)==0
  end

  test "runtime republishing an existing author definition persists its original bytes",c do
    author_dir=Path.join(c.root,"dynamic_author")
    File.mkdir_p!(author_dir)
    bytes=<<"VXPD",1::32-little,1::32-little,1::signed-little-32,0::64,19::16-little,0::32-little>>
    File.write!(Path.join(author_dir,"leaf.vxpd"),bytes)
    assert :ok=World.publish_prefabs(c.world,author_dir)
    assert {:ok,id}=World.publish_prefab(c.world,c.actor,bytes)
    assert id==:crypto.hash(:sha256,bytes)
    target=Path.join([c.root,"prefabs",Base.encode16(id,case: :lower)<>".vxpd"])
    assert File.exists?(target)
    assert File.read!(target)==bytes
    stop_supervised(World)
    world=start_supervised!({World,Keyword.put(c.opts,:prefab_catalog_path,nil)})
    assert World.prefab_catalog(world)[id].definition.cells==[{{1,0,0},19}]
    assert World.seq(world)==0
  end

  @tag :benchmark
  @tag timeout: 300_000
  test "combined runtime limits publish place checkpoint and restart",c do
    # 一次组合样本：左半8m立方512宏；右半x/y平面8192微。
    # 根 + 五层单子包装 + 一层57子件包装 + 57叶 = 64节点，最深8层。
    empty=%{cells: [],macro_cells: [],children: [],attachments: []}
    publish=fn d ->
      bytes=Prefab.encode(d)
      assert {:ok,id}=World.publish_prefab(c.world,c.actor,bytes)
      id
    end
    unit=publish.(%{empty | cells: [{{0,0,0},19}]})
    all_micro=for x<-64..127,y<-0..127,do: {{x,y,0},19}
    singles=for x<-64..119,do: {{x,0,0},19}
    bulk=publish.(%{empty | cells: all_micro--singles})
    refs=for x<-64..119,do: %{slot: x-64,definition_id: unit,anchor: {x,0,0},orientation: 0}
    parent=publish.(%{empty | children: refs++[%{slot: 56,definition_id: bulk,anchor: {0,0,0},orientation: 0}]})
    parent=Enum.reduce(1..5,parent,fn _,id ->
      publish.(%{empty | children: [%{slot: 0,definition_id: id,anchor: {0,0,0},orientation: 0}]})
    end)
    root=%{empty | macro_cells: for(x<-0..7,y<-0..7,z<-0..7,do: {{x,y,if(z==7,do: 15,else: z)},11}),
      children: [%{slot: 0,definition_id: parent,anchor: {0,0,0},orientation: 0}]}
    bytes=Prefab.encode(root)
    catalog=World.prefab_catalog(c.world)
    {compile_us,{:ok,id,compiled}}=:timer.tc(fn -> Prefab.compile(bytes,catalog) end)
    assert compiled.summary == %{macro_cells: 512,micro_cells: 8192,nodes: 64,depth: 8,
      bounds: {{0,0,0},{128,128,128}},attachment_slots: 0}
    if artifact=System.get_env("D1_COMBINED_ARTIFACT"),do: File.write!(artifact,:erlang.term_to_binary(compiled))
    {publish_us,{:ok,^id}}=:timer.tc(fn -> World.publish_prefab(c.world,c.actor,bytes) end)
    assert {:ok,1}=World.material_supply(c.world,1001,"combined-runtime-limits",%{11=>512*512*4096,19=>8192*4096})
    {place_us,{:ok,2}}=:timer.tc(fn -> World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,
      %{definition_id: id,anchor: {8,8,16},orientation: 0,client_intent_seq: 1}) end)
    assert Enum.all?(World.material_balances(c.world,1001),&(&1.balance==0))
    {:ok,cells}=World.instance_cells(c.world,{2,0})
    assert length(cells)==512+128
    assert :ok=World.compact(c.world)
    checkpoint_bytes=File.stat!(Path.join(c.root,"overlay.log")).size
    definition_dir=Path.join(c.root,"prefabs")
    definition_files=File.ls!(definition_dir) |> Enum.filter(&(Path.extname(&1)==".vxpd"))
    assert length(definition_files)==9
    definition_bytes=Enum.sum(Enum.map(definition_files,&File.stat!(Path.join(definition_dir,&1)).size))
    stop_supervised(World)
    {restart_us,world}=:timer.tc(fn -> start_supervised!({World,c.opts}) end)
    assert World.seq(world)==2
    assert World.prefab_catalog(world)[id].summary==compiled.summary
    assert {:ok,^cells}=World.instance_cells(world,{2,0})
    payload=VoxelRegion.TestSupport.payload(world,0,{0,0,0})
    # 8192个micro在128个refined宏格；64个实例身份包括空包装父节点均恢复。
    assert map_size(payload.refined)==128
    assert map_size(payload.instances)==64
    IO.puts("D1_COMBINED macro=512 micro=8192 nodes=64 depth=8 bbox_micro=128,128,128 root_bytes=#{byte_size(bytes)} catalog_bytes=#{definition_bytes} compile_us=#{compile_us} publish_us=#{publish_us} place_us=#{place_us} checkpoint_bytes=#{checkpoint_bytes} restart_us=#{restart_us}")
  end
end
