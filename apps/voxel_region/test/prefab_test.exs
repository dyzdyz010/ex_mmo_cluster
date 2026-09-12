defmodule VoxelRegion.PrefabTest do
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, FileStore, Prefab, CollisionSource}
  alias MmoContracts.Voxel.{Codec, Payload}

  defmodule ObservedFileStore do
    # 记录真实文件源的预备请求；读路径仍直接使用 FileStore。
    def open(opts) do
      {:ok,store} = FileStore.open(opts)
      {:ok,Map.put(store,:observer,Keyword.fetch!(opts,:observer))}
    end
    defdelegate content_version(store), to: FileStore
    defdelegate world_dir(store), to: FileStore
    defdelegate read(store,level,region), to: FileStore
    defdelegate generated(store), to: FileStore
    def ensure(store,level,region) do
      send(store.observer,{:source_ensure,self(),{level,region}})
      FileStore.ensure(store,level,region)
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "r7_prefab_#{System.unique_integer([:positive])}")
    catalog = Path.join(root, "catalog")
    File.mkdir_p!(catalog)
    bytes = <<"VXPD", 1::32-little, 2::32-little, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little,
      1::signed-little-32, 0::signed-little-32, 0::signed-little-32, 19::16-little, 0::32-little>>
    File.write!(Path.join(catalog,"test.vxpd"),bytes)
    id = :crypto.hash(:sha256,bytes)
    for level <- 0..5, x <- -1..1, y <- -1..1, z <- -1..1 do
      path = FileStore.path(root,123,level,{x,y,z})
      File.mkdir_p!(Path.dirname(path))
      p = %Payload{level: level, region: {x,y,z}, cells: :binary.copy(<<0,0>>,66*66*66)}
      File.write!(path,Payload.encode(p,%{},0,123))
    end
    opts = [root: root, prefab_catalog_path: catalog, name: :r7_test_world]
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, id: id, opts: opts}
  end

  test "cross chunk placement, same macro owners, removal, checkpoint and restart", %{id: id, opts: opts} do
    {:ok, w} = World.start_link(opts)
    assert {:ok, 1} = World.place_prefab(w,id,{127,8,8},0)
    assert {:error, :occupied} = World.place_prefab(w,id,{127,8,8},0)
    assert World.seq(w) == 1
    assert {:ok, 2} = World.place_prefab(w,id,{127,8,9},0)
    assert {:error, :refined_cell} = World.apply_edit(w,{15,1,1},0)
    p = payload(w,{0,0,0})
    assert map_size(p.instances) == 2
    occupancy = CollisionSource.capture(p,{0,0,0})
    assert occupancy.n == 128 and occupancy.scale_m == 0.125
    assert :binary.at(occupancy.cells,127+128*(8+128*8)) == 1
    assert :binary.at(occupancy.cells,126+128*(8+128*8)) == 0
    assert :binary.at(occupancy.cells,127+128*(8+128*9)) == 1
    assert CollisionSource.capture(p,{1,0,0}).n == 128
    assert {:ok, 3} = World.remove_prefab(w,{1,0})
    p = payload(w,{0,0,0})
    assert Map.keys(p.instances) == [{2,0}]
    occupancy = CollisionSource.capture(p,{0,0,0})
    assert :binary.at(occupancy.cells,127+128*(8+128*8)) == 0
    assert :binary.at(occupancy.cells,127+128*(8+128*9)) == 1
    assert :ok = World.compact(w)
    GenServer.stop(w)
    {:ok, w} = World.start_link(opts)
    assert payload(w,{0,0,0}).refined == p.refined
    assert {:ok,4} = World.remove_prefab(w,{2,0})
    assert {:error,:instance_not_found} = World.remove_prefab(w,{2,0})
    assert :ok = World.compact(w)
    GenServer.stop(w)
    {:ok,w} = World.start_link(opts)
    assert payload(w,{0,0,0}).refined == %{}
    assert payload(w,{0,0,0}).instances == %{}
    assert CollisionSource.capture(payload(w,{0,0,0}),{0,0,0}).n == 16
    GenServer.stop(w)
  end

  test "neighbor ring has current occupancy and deletion", %{id: id, opts: opts} do
    {:ok,w} = World.start_link(opts)
    assert {:ok,1} = World.place_prefab(w,id,{0,8,8},0)
    neighbor = payload(w,{-1,0,0})
    assert map_size(neighbor.refined) == 1
    assert {:ok,2} = World.remove_prefab(w,{1,0})
    assert payload(w,{-1,0,0}).refined == %{}
    GenServer.stop(w)
  end

  @tag :r7a3
  test "cross region object stays one transaction and deletes after checkpoint without client residency", %{id: id, opts: opts} do
    {:ok, w} = World.start_link(opts)
    assert {:ok, 1} = World.place_prefab(w, id, {511, 8, 8}, 0)
    left = payload(w, {0, 0, 0})
    right = payload(w, {1, 0, 0})
    assert Map.keys(left.instances) == [{1, 0}]
    assert right.instances == left.instances
    assert {:ok, cells} = World.instance_cells(w, {1, 0})
    assert Enum.sort(cells) == [{63, 1, 1}, {64, 1, 1}]
    assert {:error, :occupied} = World.place_prefab(w, id, {512, 8, 8}, 0)
    assert World.seq(w) == 1
    assert :ok = World.compact(w)
    GenServer.stop(w)
    {:ok, w} = World.start_link(opts)
    # Delete by authoritative identity before loading either client region.
    assert {:ok, 2} = World.remove_prefab(w, {1, 0})
    for region <- [{0, 0, 0}, {1, 0, 0}] do
      p = payload(w, region)
      assert p.refined == %{} and p.instances == %{}
    end
    GenServer.stop(w)
    {:ok, w} = World.start_link(opts)
    assert World.seq(w) == 2
    assert {:error, :instance_not_found} = World.instance_cells(w, {1, 0})
    assert payload(w, {1, 0, 0}).refined == %{}
    GenServer.stop(w)
  end

  @tag :r7a3
  test "negative region boundary retains both owners and exact micro contact", %{id: id, opts: opts} do
    {:ok, w} = World.start_link(opts)
    assert {:ok, 1} = World.place_prefab(w, id, {-1, 8, 8}, 0)
    assert {:ok, 2} = World.place_prefab(w, id, {-1, 8, 9}, 0)
    assert {:ok, 3} = World.remove_prefab(w, {1, 0})
    for region <- [{-1, 0, 0}, {0, 0, 0}] do
      p = payload(w, region)
      assert Map.keys(p.instances) == [{2, 0}]
      assert Enum.all?(p.refined, fn {_, slots} -> Enum.all?(slots, fn {_, {_, owner}} -> owner == {2, 0} end) end)
    end
    GenServer.stop(w)
  end

  @tag :collision_projection
  test "canonical delta installs micro collision atomically and retains historical revision", %{id: id, opts: opts} do
    alias MmoContracts.Voxel.{CanonicalSnapshot,CanonicalDelta}
    alias SceneServer.Movement.CollisionUpdates
    alias SceneServer.Native.VoximMovement, as: Native
    {:ok,w} = World.start_link(opts)
    :ok = World.canonical_snapshot_and_subscribe(w,{{0,0,0},{1,1,1}},self(),:r7)
    assert_receive {:canonical_snapshot,:r7,%CanonicalSnapshot{}=snapshot}
    updates = CollisionUpdates.new(Native) |> CollisionUpdates.initialize(snapshot)
    assert {:ok,1} = World.place_prefab(w,id,{127,8,8},0)
    assert_receive {:canonical_delta,%CanonicalDelta{transaction_seq: 1,chunks: chunks}=placed}
    assert Enum.map(chunks,&{&1.coord,&1.n,&1.scale_m}) == [{{0,0,0},128,0.125},{{1,0,0},128,0.125}]
    {updates,events} = updates |> CollisionUpdates.enqueue(placed,0) |> CollisionUpdates.consume(0)
    updates = CollisionUpdates.record_tick(updates,10,events)
    {placed_world,2} = CollisionUpdates.at_tick(updates,10)
    assert {2,_,_} = Native.world_stats(placed_world)
    session = :trace.session_create(:canonical_without_wire,self(),[])
    try do
      :trace.function(session,{Payload,:decode,1},true,[:call_time])
      :trace.process(session,w,true,[:call])
      assert {:ok,2} = World.remove_prefab(w,{1,0})
      {:call_time,counters} = :trace.info(session,{Payload,:decode,1},:call_time)
      assert Enum.sum(for {^w,n,_,_} <- counters,do: n) == 0
    after
      :trace.session_destroy(session)
    end
    assert_receive {:canonical_delta,%CanonicalDelta{transaction_seq: 2}=removed}
    assert Enum.all?(removed.chunks,&(&1.n == 16))
    {updates,events} = updates |> CollisionUpdates.enqueue(removed,1) |> CollisionUpdates.consume(1)
    updates = CollisionUpdates.record_tick(updates,20,events)
    {empty_world,3} = CollisionUpdates.at_tick(updates,20)
    assert {0,0,0} = Native.world_stats(empty_world)
    assert {^placed_world,2} = CollisionUpdates.at_tick(updates,15)
    assert {2,_,_} = Native.world_stats(placed_world)
    GenServer.stop(w)
  end

  @tag :database
  test "database append and checkpoint restart retain occupancy and final deletion", %{id: id, opts: opts} do
    alias DataService.Voxel.OverlayLogStore
    :ok = OverlayLogStore.replace(123,[])
    opts = Keyword.put(opts,:log,VoxelRegion.OverlayLog.Db)
    {:ok,w} = World.start_link(opts)
    assert {:ok,1} = World.apply_edit(w,{20,1,1},11)
    assert {:ok,2} = World.place_prefab(w,id,{127,8,8},0)
    placed = payload(w,{0,0,0})
    GenServer.stop(w)
    {:ok,w} = World.start_link(opts)
    assert payload(w,{0,0,0}).refined == placed.refined
    assert payload(w,{0,0,0}).instances == placed.instances
    assert Payload.material(payload(w,{0,0,0}),{21,2,2}) == 11
    assert {:ok,3} = World.remove_prefab(w,{2,0})
    :ok = World.compact(w)
    GenServer.stop(w)
    {:ok,w} = World.start_link(opts)
    assert World.seq(w) == 3
    assert payload(w,{0,0,0}).refined == %{}
    assert payload(w,{0,0,0}).instances == %{}
    assert Payload.material(payload(w,{0,0,0}),{21,2,2}) == 11
    assert OverlayLogStore.read_all(123) != []
    GenServer.stop(w)
    :ok = OverlayLogStore.replace(123,[])
  end

  test "published golden 24 orientations", _ do
    golden = File.read!(Path.expand("../../../../Voxim/Docs/R7/golden.json",__DIR__)) |> Jason.decode!()
    bytes = Base.decode16!(golden["stair"]["vxpd_hex"],case: :lower)
    assert {:ok,definition} = Prefab.decode(bytes)
    assert Base.encode16(:crypto.hash(:sha256,bytes),case: :lower) == golden["stair"]["definition_id"]
    for sample <- golden["orientations"] do
      cells = Prefab.footprint(definition,List.to_tuple(golden["stair"]["anchor"]),sample["id"])
      assert Enum.sort(Enum.map(cells,fn {{x,y,z},m} -> [x,y,z,m] end)) == sample["cells"]
    end
  end

  @tag :r7a4
  @tag :prepare_regression
  test "warm subtree replacement does not recheck source files for every structure sample", %{opts: opts,id: id} do
    {:ok,w} = World.start_link(opts ++ [source: ObservedFileStore,observer: self()])
    on_exit(fn -> if Process.alive?(w),do: GenServer.stop(w) end)
    assert {:ok,1} = World.place_prefab(w,id,{15,8,8},0)
    ensure_events([])
    assert {:ok,2} = World.replace_prefab(w,{1,0},id)
    requests = ensure_events([]) |> Enum.filter(fn {pid,_}->pid==w end) |> Enum.map(&elem(&1,1))
    # 已驻留的源不能随着子采样数量反复做文件系统预备；输出 region 至多各一次。
    assert Enum.all?(Enum.frequencies(requests),fn {_,count}->count<=1 end),inspect(Enum.frequencies(requests))
    p = payload(w,{0,0,0})
    assert Map.keys(p.instances)==[{2,0}]
    assert map_size(p.refined)==2
  end

  defp ensure_events(events) do
    receive do
      {:source_ensure,pid,key} -> ensure_events([{pid,key}|events])
    after
      0 -> events
    end
  end

  @tag :subtree_wait
  test "same shape replica update reuses bytes and does not expand a region twice", %{opts: opts,id: id} do
    {:ok,w} = World.start_link(opts)
    on_exit(fn -> if Process.alive?(w),do: GenServer.stop(w) end)
    assert {:ok,1} = World.place_prefab(w,id,{127,8,8},0)
    assert {:ok,_} = World.replica_snapshot_and_subscribe(w,{{-1,0,0},{1,1,1}},self())
    mfa = {Payload,:decode,1}
    session = :trace.session_create(:prefab_replica_decode,self(),[])
    try do
      :trace.function(session,mfa,true,[:call_time])
      :trace.function(session,{Payload,:encode,4},true,[:call_time])
      :trace.process(session,w,true,[:call])
      assert {:ok,2} = World.replace_prefab(w,{1,0},id)
      assert_receive {:canonical_replica_delta,delta,regions}
      assert delta.chunks == []
      # 内部放置只改 region 0；region -1 的 ring 没有变化。
      assert Enum.map(regions,&elem(&1,0)) == [{0,0,0}]
      {:call_time,counters} = :trace.info(session,mfa,:call_time)
      assert Enum.sum(for {^w,n,_,_} <- counters,do: n) == 0
      {:call_time,encodes} = :trace.info(session,{Payload,:encode,4},:call_time)
      assert Enum.sum(for {^w,n,_,_} <- encodes,do: n) == 0
      [{_,bytes}] = regions
      assert {:ok,p} = Payload.decode(bytes)
      assert Map.keys(p.instances) == [{2,0}]
    after
      :trace.session_destroy(session)
    end
    # 稀疏宏格边界编辑仍必须更新左邻 ring。
    assert {:ok,3} = World.apply_edit(w,{0,1,1},19)
    assert_receive {:canonical_replica_delta,_,regions}
    assert Enum.map(regions,&elem(&1,0)) == [{-1,0,0},{0,0,0}]
    {:ok,left} = Payload.decode(regions |> List.first() |> elem(1))
    assert Payload.material(left,{65,2,2}) == 19
    assert {:ok,4} = World.replace_prefab(w,{2,0},id)
    assert Payload.material(payload(w,{0,0,0}),{1,2,2}) == 19
    assert {:ok,5} = World.remove_prefab(w,{4,0})
    assert Payload.material(payload(w,{0,0,0}),{1,2,2}) == 19
  end

  @tag :subtree_wait
  test "dense definition checks each macro coordinate once and still rejects invalid bounds", %{opts: opts} do
    cells = for x <- 0..7,y <- 0..7,z <- 0..7,into: <<>>,
      do: <<x::signed-little-32,y::signed-little-32,z::signed-little-32,11::16-little>>
    bytes = <<"VXPD",1::32-little,512::32-little,cells::binary,0::32-little>>
    id = :crypto.hash(:sha256,bytes)
    File.write!(Path.join(Keyword.fetch!(opts,:prefab_catalog_path),"dense.vxpd"),bytes)
    {:ok,w} = World.start_link(opts)
    on_exit(fn -> if Process.alive?(w),do: GenServer.stop(w) end)
    mfa = {World,:valid_edit_coord?,1}
    session = :trace.session_create(:prefab_range_checks,self(),[])
    try do
      :trace.function(session,mfa,true,[:call_time])
      :trace.process(session,w,true,[:call])
      assert {:ok,footprint} = World.prefab_cells(w,id,{-8,8,8},0)
      assert length(footprint) == 512
      {:call_time,counters} = :trace.info(session,mfa,:call_time)
      assert Enum.sum(for {^w,n,_,_} <- counters,do: n) == 1
    after
      :trace.session_destroy(session)
    end
    assert {:error,:invalid_coordinate} = World.prefab_cells(w,id,{17_179_869_184,8,8},0)
    assert {:error,:invalid_orientation} = World.prefab_cells(w,id,{0,8,8},24)
    assert {:ok,1} = World.place_prefab(w,id,{-8,8,8},0)
    assert {:error,:definition_not_found} = World.replace_prefab(w,{1,0},<<0::256>>)
    assert World.seq(w) == 1
    assert {:ok,2} = World.replace_prefab(w,{1,0},id)
    assert map_size(payload(w,{-1,0,0}).instances) == 1
  end

  @tag :r7a4
  @tag :replacement_regression
  test "same definition replacement restores damaged geometry and preserves other owners", %{opts: opts,id: leaf} do
    catalog = Keyword.fetch!(opts,:prefab_catalog_path)
    child = fn slot,x -> <<slot::32-little,leaf::binary,x::signed-little-32,0::signed-little-32,0::signed-little-32,0>> end
    bytes = <<"VXPD",1::32-little,0::32-little,2::32-little>> <> child.(1,0) <> child.(2,16)
    root = :crypto.hash(:sha256,bytes)
    File.write!(Path.join(catalog,"repair.vxpd"),bytes)
    {:ok,w} = World.start_link(opts)
    assert {:ok,1} = World.place_prefab(w,root,{15,8,8},0)
    assert {:ok,2} = World.place_prefab(w,leaf,{15,8,9},0)
    original = payload(w,{0,0,0})
    assert {:ok,3} = World.remove_prefab(w,{1,1})
    assert payload(w,{0,0,0}).refined != original.refined
    assert {:ok,4} = World.replace_prefab(w,{1,0},root)
    repaired = payload(w,{0,0,0})
    materials = fn p -> Map.new(p.refined,fn {cell,slots}->{cell,Map.new(slots,fn {slot,{m,_}}->{slot,m} end)} end) end
    assert materials.(repaired)==materials.(original)
    assert repaired.instances[{2,0}]==original.instances[{2,0}]
    assert Enum.sort(Map.keys(repaired.instances))==[{2,0},{4,0},{4,1},{4,2}]
    [txn] = World.entries_after(w,3)
    assert Enum.any?(txn.entries,fn e -> {:ok,h}=Codec.decode_payload_header(e.payload);h.level==1 end)
    # 未改 slot 数量也必须识别材质变化。
    recolored = <<"VXPD",1::32-little,2::32-little,0::signed-little-32,0::signed-little-32,0::signed-little-32,19::16-little,
      1::signed-little-32,0::signed-little-32,0::signed-little-32,11::16-little,0::32-little>>
    File.write!(Path.join(catalog,"recolored.vxpd"),recolored)
    :ok = World.publish_prefabs(w,catalog)
    assert {:ok,5} = World.replace_prefab(w,{4,1},:crypto.hash(:sha256,recolored))
    p = payload(w,{0,0,0})
    assert p.refined[Payload.cell_index({2,2,2})][7]=={19,{5,0}}
    assert p.refined[Payload.cell_index({3,2,2})][0]=={11,{5,0}}
    [recolor_txn] = World.entries_after(w,4)
    entry = Enum.find(recolor_txn.entries,fn e ->
      {:ok,h}=Codec.decode_payload_header(e.payload)
      h.level==1 and h.region=={0,0,0}
    end)
    {:ok,coarse} = Payload.decode(entry.payload)
    grid = coarse.structure[Payload.cell_index({1,1,1})]
    assert binary_part(grid,2*(15+16*(8+16*8)),2)==<<275::16-little>>
    GenServer.stop(w)
  end

  @tag :r7a4
  test "nested preorder, ancestor snapshots, actual subtree replace and replay", %{opts: opts, id: leaf} do
    nested_scenario(opts,leaf)
  end

  @tag :database
  test "nested DB append and checkpoint preserve actual hierarchy", %{opts: opts,id: leaf} do
    :ok = DataService.Voxel.OverlayLogStore.replace(123,[])
    nested_scenario(Keyword.put(opts,:log,VoxelRegion.OverlayLog.Db),leaf)
    :ok = DataService.Voxel.OverlayLogStore.replace(123,[])
  end

  defp nested_scenario(opts,leaf) do
    catalog = Keyword.fetch!(opts, :prefab_catalog_path)
    child = fn slot, id, x -> <<slot::32-little,id::binary, x::signed-little-32,0::signed-little-32,0::signed-little-32,0>> end
    part_bytes = <<"VXPD",1::32-little,0::32-little,2::32-little>> <> child.(3,leaf,0) <> child.(8,leaf,16)
    part = :crypto.hash(:sha256,part_bytes)
    File.write!(Path.join(catalog,"part.vxpd"),part_bytes)
    root_bytes = <<"VXPD",1::32-little,0::32-little,2::32-little>> <> child.(2,part,0) <> child.(7,part,32)
    root_id = :crypto.hash(:sha256,root_bytes)
    File.write!(Path.join(catalog,"root.vxpd"),root_bytes)
    {:ok,w} = World.start_link(opts)
    assert {:ok,1} = World.place_prefab(w,root_id,{503,8,8},0)
    assert {:ok,2} = World.place_prefab(w,leaf,{503,8,9},0)
    right = payload(w,{1,0,0})
    assert right.format_version == 7
    assert right.instances[{1,0}].definition_id == root_id
    assert right.instances[{1,1}].parent_id == {1,0}
    assert right.instances[{1,2}].parent_id == {1,1}
    assert right.instances[{1,3}].component_slot == 8
    assert {:ok,3} = World.remove_prefab(w,{1,2})
    assert {:ok,4} = World.replace_prefab(w,{1,3},leaf)
    assert {:error,:instance_not_found} = World.instance_cells(w,{1,2})
    assert not Map.has_key?(payload(w,{0,0,0}).instances,{1,2})
    assert {:ok,5} = World.replace_prefab(w,{1,1},leaf)
    p = payload(w,{0,0,0})
    assert p.instances[{5,0}].parent_id == {1,0}
    assert p.instances[{5,0}].component_slot == 2
    assert p.instances[{5,0}].anchor == {503,8,8}
    assert p.instances[{1,0}].definition_id == root_id
    assert {:error,:occupied} = World.replace_prefab(w,{5,0},root_id)
    assert World.seq(w) == 5
    assert payload(w,{0,0,0}).refined == p.refined
    GenServer.stop(w)
    {:ok,w} = World.start_link(opts)
    assert payload(w,{0,0,0}).instances == p.instances
    assert :ok = World.compact(w)
    GenServer.stop(w)
    {:ok,w} = World.start_link(opts)
    assert {:ok,6} = World.remove_prefab(w,{1,0})
    assert Map.keys(payload(w,{0,0,0}).instances) == [{2,0}]
    assert Map.keys(payload(w,{1,0,0}).instances) == [{2,0}]
    GenServer.stop(w)
  end

  defp payload(w,region) do
    req = Codec.encode_request(0,[%{level: 0,region: region,have_seq: 0,have_hash: 0}]) |> IO.iodata_to_binary()
    {:ok,reply} = World.serve(w,req)
    {:ok,123,[{:payload,0,^region,bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok,p} = Payload.decode(bytes)
    p
  end
end
