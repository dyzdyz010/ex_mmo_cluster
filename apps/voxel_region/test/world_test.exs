defmodule VoxelRegion.WorldTest do
  use ExUnit.Case, async: false

  alias DataService.Voxel.OverlayLogStore
  alias VoxelRegion.{FileStore, OverlayLog, Reducer, World}
  alias MmoContracts.Voxel.{Codec, Payload}

  @cv 0x1122_3344_5566_7788
  @extent 66
  @cells @extent * @extent * @extent

  # 合成世界：L0 region (0,0,0)…(1,1,1) 全是石头(11)、上面一层 y 的 region 全空气；L1 (0,0,0) 由 reduce 得出（这里直接按同一规则写：下半实心上半空气）。
  defp write_world(root) do
    world = Path.join(root, FileStore.hex(@cv))

    for level <- 0..2, do: File.mkdir_p!(Path.join(world, "L#{level}"))

    solid = for _z <- 0..65, y <- 0..65, _x <- 0..65, into: <<>>, do: <<if(y < 65, do: 11, else: 0)::16-little>>
    air = for _z <- 0..65, y <- 0..65, _x <- 0..65, into: <<>>, do: <<if(y == 0, do: 11, else: 0)::16-little>>
    empty_skins = <<@extent::32-little, @extent::32-little, @extent::32-little, 1::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little>>

    for x <- -1..1, z <- -1..1 do
      File.write!(FileStore.path(root, @cv, 0, {x, 0, z}), Codec.encode_payload(0, {x, 0, z}, 0, @cv, <<@cells::32-little, solid::binary, empty_skins::binary>>))
      File.write!(FileStore.path(root, @cv, 0, {x, 1, z}), Codec.encode_payload(0, {x, 1, z}, 0, @cv, <<@cells::32-little, air::binary, empty_skins::binary>>))
    end

    # L1 (0,0,0)：y < 32 实心（children 在 L0 y-region 0）、y ≥ 32 空气；ring 也按同一规则（L1 cell y=-1 → 实心，y=64 → 空气）。
    l1 = for lz <- 0..(@extent - 1), ly <- 0..(@extent - 1), lx <- 0..(@extent - 1), into: <<>>, do: <<if(ly - 1 < 32, do: 11, else: 0)::16-little>>
    File.write!(FileStore.path(root, @cv, 1, {0, 0, 0}), Codec.encode_payload(1, {0, 0, 0}, 0, @cv, <<@cells::32-little, l1::binary, @extent::32-little, @extent::32-little, @extent::32-little, 2::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little>>))
    l2 = for lz <- 0..(@extent - 1), ly <- 0..(@extent - 1), lx <- 0..(@extent - 1), into: <<>>, do: <<if(ly - 1 < 16, do: 11, else: 0)::16-little>>
    File.write!(FileStore.path(root, @cv, 2, {0, 0, 0}), Codec.encode_payload(2, {0, 0, 0}, 0, @cv, <<@cells::32-little, l2::binary, @extent::32-little, @extent::32-little, @extent::32-little, 4::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little>>))
    world
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "voxel_region_world_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    write_world(root)
    unless context[:replica], do: OverlayLogStore.reset()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp request(items, cv), do: IO.iodata_to_binary(Codec.encode_request(cv, items))

  @tag :replica
  test "region replica serves local snapshots and ordered canonical updates without a writer", %{root: root} do
    alias VoxelRegion.Replica
    world = start_supervised!({World, root: root, name: :replica_authority})
    box = {{0, 0, 0}, {1, 2, 1}}
    replica = start_supervised!({Replica, authority_ref: world, l0_box: box, name: :region_replica})
    assert Replica.authority_ref(replica) == World.authority_ref(world)
    request = make_ref()
    assert :ok = Replica.canonical_snapshot_and_subscribe(replica, box, self(), request)
    assert_receive {:canonical_snapshot, ^request, snapshot}
    assert snapshot.transaction_seq == 0
    assert length(snapshot.regions) == 2
    assert length(snapshot.chunks) == 128

    assert {:ok, 1} = World.apply_edit(world, {5, 63, 5}, 0)
    assert_receive {:canonical_delta, delta}, 5_000
    assert delta.transaction_seq == 1
    assert delta.chunks != []
    assert {:ok, 2} = World.apply_edit(world, {6, 63, 5}, 12)
    assert_receive {:canonical_delta, material_delta}, 5_000
    assert material_delta.transaction_seq == 2
    assert material_delta.chunks == []
    assert Replica.canonical_deltas_after(replica, 0) == [delta, material_delta]
    assert Replica.canonical_deltas_after(replica, 1) == [material_delta]
    assert Replica.canonical_deltas_after(replica, 2) == []
    later = start_supervised!(Supervisor.child_spec(
      {Replica, authority_ref: world, l0_box: box, name: :later_replica}, id: :later_replica))
    assert Replica.authority_ref(later) == world
    assert Replica.canonical_deltas_after(later, 1) == {:error, :before_replica_snapshot}
    assert Replica.canonical_deltas_after(later, 2) == []

    # 暂停上游后仍可读取最新区域，证明这里确实提供本地数据服务。
    :ok = :sys.suspend(world)
    try do
      marker = make_ref()
      assert :ok = Replica.canonical_snapshot_and_subscribe(replica, box, self(), marker, false)
      assert_receive {:canonical_snapshot, ^marker, current}
      assert current.transaction_seq == 2
      assert current.chunks == []
      for {region, bytes} <- current.regions do
        assert {:ok, payload} = Payload.decode(bytes)
        assert payload.seq == 2
        assert Payload.material(payload, Payload.local(region, {5, 63, 5})) == 0
        assert Payload.material(payload, Payload.local(region, {6, 63, 5})) == 12
      end
      assert %{regions: 2, chunks: 128, transaction_seq: 2, authority_ref: ^world} = Replica.stats(replica)
      assert {:error, :read_only_replica} = GenServer.call(replica, {:apply_edits, [{{5, 63, 5}, 11}]})
      assert {:error, :outside_replica_region} =
        Replica.canonical_snapshot_and_subscribe(replica, {{-1, 0, 0}, {1, 2, 1}}, self(), make_ref())
    after
      :sys.resume(world)
    end

    monitor = Process.monitor(replica)
    :ok = stop_supervised(World)
    assert_receive {:DOWN, ^monitor, :process, ^replica, {:authority_down, :shutdown}}, 5_000
  end

  test "join barrier returns the same canonical regions without rebuilding scene collision", %{root: root} do
    world = start_supervised!({World, [root: root, name: :join_marker_world]})
    box = {{0, 0, 0}, {1, 2, 1}}
    initial = make_ref()
    assert :ok = World.canonical_snapshot_and_subscribe(world, box, self(), initial)
    assert_receive {:canonical_snapshot, ^initial, baseline}
    assert length(baseline.chunks) == 128

    join = make_ref()
    assert :ok = World.canonical_snapshot_and_subscribe(world, box, self(), join, false)
    assert_receive {:canonical_snapshot, ^join, marker}
    assert marker.chunks == []
    assert marker.regions == baseline.regions
    assert marker.transaction_seq == baseline.transaction_seq
    assert {:ok, _} = World.apply_edit(world, {5, 63, 5}, 0)
    assert_receive {:canonical_delta, delta}
    assert delta.transaction_seq == marker.transaction_seq + 1
    assert delta.chunks != []
  end

  test "edit at the surface flips L1 (material + skin) and stops where nothing changes; payloads are re-materialized", %{root: root} do
    {:ok, world} = World.start_link(root: root, log: OverlayLog.Db, name: :w1)
    assert World.content_version(:w1) == @cv
    assert World.seq(:w1) == 0

    # 首拉：文件原样。
    {:ok, reply} = World.serve(:w1, request([%{level: 0, region: {0, 0, 0}, have_seq: 0, have_hash: 0}], 0))
    {:ok, @cv, [{:payload, 0, {0, 0, 0}, bytes0}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok, h0} = Codec.decode_payload_header(bytes0)
    {:ok, reply} = World.serve(:w1, request([%{level: 0, region: {0, 0, 0}, have_seq: h0.seq, have_hash: h0.hash}], @cv))
    assert {:ok, _, [{:unchanged, 0, {0, 0, 0}}]} = Codec.decode_reply(IO.iodata_to_binary(reply))

    # 地表 (5, 63, 5) 的石头挖成空气：L0 变；L1 cell (2,31,2) 的 8 个子格 7 实心 → 仍实心、材质不变、表皮 +Y 面从 11 变 … 仍 11（外层子格空气 → 取内层 11）→ L1 不变 → 链停在 L1。
    assert {:ok, 1} = World.apply_edit(:w1, {5, 63, 5}, 0)
    [entry] = World.entries_after(:w1, 0)
    assert entry.coord == {5, 63, 5} and entry.material == 0
    assert entry.coarse == []

    # 挖掉一个 2×2×2 块的 5 个 → L1 (2,31,2) 翻成空气（4:4 → 空气）→ L2 (1,15,1) 8 个子格里 7 个实心 → 不翻。
    for {x, y, z} <- [{4, 63, 4}, {5, 63, 4}, {4, 63, 5}, {4, 62, 4}], do: assert({:ok, _} = World.apply_edit(:w1, {x, y, z}, 0))
    entries = World.entries_after(:w1, 1)
    last = List.last(entries)
    assert World.seq(:w1) == 5
    assert [%{level: 1, cell: {2, 31, 2}, material: 0}] = last.coarse
    # 表皮：空气父格从 +Y 看进去：外层 y=63 全空 → 取内层 y=62，(4,62,4) 也空 → 一列是 0、三列是 11 → id 11、贴图非均匀 → ext 2。
    {2, faces} = last.coarse |> hd() |> Map.fetch!(:skins)
    assert {11, <<_, _, _, _>>} = elem(faces, 3)
    assert elem(elem(faces, 2), 0) == 11

    # 载荷物化：L0 (0,0,0) 的 seq 变成 5，hash 变了，cells 里那 5 格是空气；L1 (0,0,0) 也物化（cell (2,31,2) 空气）。
    {:ok, reply} = World.serve(:w1, request([%{level: 0, region: {0, 0, 0}, have_seq: h0.seq, have_hash: h0.hash}, %{level: 1, region: {0, 0, 0}, have_seq: 0, have_hash: 0}], @cv))
    {:ok, _, [{:payload, 0, {0, 0, 0}, bytes1}, {:payload, 1, {0, 0, 0}, l1bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok, h1} = Codec.decode_payload_header(bytes1)
    assert h1.seq == 5 and h1.hash != h0.hash
    {:ok, p1} = Payload.decode(bytes1)
    assert Payload.material(p1, Payload.local({0, 0, 0}, {5, 63, 5})) == 0
    assert Payload.material(p1, Payload.local({0, 0, 0}, {6, 63, 5})) == 11
    {:ok, l1p} = Payload.decode(l1bytes)
    assert Payload.material(l1p, Payload.local({0, 0, 0}, {2, 31, 2})) == 0
    assert Payload.material(l1p, Payload.local({0, 0, 0}, {3, 31, 2})) == 11
    # 邻 region 的 ring 也含这一格：L0 (-1,0,0)… 不含 (5,63,5)（x=5 离边 59 格）；L0 (0,1,0) 的 ring 含 y=63 → 它也被物化。
    {:ok, reply} = World.serve(:w1, request([%{level: 0, region: {0, 1, 0}, have_seq: 0, have_hash: 0}], @cv))
    {:ok, _, [{:payload, 0, {0, 1, 0}, up}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok, upp} = Payload.decode(up)
    assert Payload.material(upp, Payload.local({0, 1, 0}, {5, 63, 5})) == 0

    # 同一格再挖一次 = no-op：seq 不动。
    assert {:ok, 5} = World.apply_edit(:w1, {5, 63, 5}, 0)
    # 没烘的 region：拒绝。
    assert {:error, :missing_region} = World.apply_edit(:w1, {500, 0, 0}, 0)

    # 重启重放：seq、overlay、载荷都一样。
    GenServer.stop(world)
    {:ok, _} = World.start_link(root: root, log: OverlayLog.Db, name: :w2)
    assert World.seq(:w2) == 5
    {:ok, reply} = World.serve(:w2, request([%{level: 0, region: {0, 0, 0}, have_seq: h1.seq, have_hash: h1.hash}], @cv))
    assert {:ok, _, [{:unchanged, 0, {0, 0, 0}}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
  end

  test "batch is atomic, deduplicates parents, chooses exact bytes and compacts replay across rings and restart", %{root: root} do
    {:ok, world} = World.start_link(root: root, log: OverlayLog.Db, name: :batch)
    assert {:ok, 1} = World.apply_edit(:batch, {70, 63, 2}, 0)
    before = fetch_payload(:batch, 0, {0, 0, 0})
    assert {:error, :missing_region} = World.apply_edits(:batch, [{{3,63,3},0}, {{1000,0,0},0}])
    assert World.seq(:batch) == 1
    assert fetch_payload(:batch, 0, {0,0,0}) == before
    :ok = World.subscribe(:batch, self(), 1, {{0,0,0},{0,0,0}}, 4)
    edits = for x <- 0..10, y <- 55..63, z <- 0..10, do: {{x,y,z},0}
    assert {:ok, 2} = World.apply_edits(:batch, edits ++ [{{5,60,5},11},{{5,60,5},0}])
    assert_receive {:voxel_log_transaction_payload, wire}, 5_000
    assert {:ok, txn} = Codec.decode_transaction(wire)
    assert txn.seq == 2
    assert IO.iodata_to_binary(Codec.encode_transaction(txn)) == wire
    regions = Enum.filter(txn.entries, &Map.has_key?(&1, :payload))
    assert regions != []
    # near 订阅即使世界级门槛是 L4，也必须收到相交的 L1/L2。
    assert [0,1,2] == Enum.map(regions,fn e -> {:ok,h}=Codec.decode_payload_header(e.payload);h.level end)
    for e <- regions do
      {:ok, h} = Codec.decode_payload_header(e.payload)
      if h.level == 0, do: assert(13 + byte_size(e.payload) < length(edits) * 28)
    end
    assert length(txn.coarse) == length(Enum.uniq_by(txn.coarse, &{&1.level,&1.cell}))
    for {{level,region},values} <- Enum.group_by(:sys.get_state(:batch).overlay,fn {{lv,{x,y,z}},_} ->
      {lv,{Integer.floor_div(x,64),Integer.floor_div(y,64),Integer.floor_div(z,64)}}
    end), region == {0,0,0} do
      sparse_bytes=Enum.reduce(values,0,fn {{lv,cell},{m,skins}},n ->
        n+if(lv==0,do: 28,else: IO.iodata_length(Codec.encode_coarse(%{level: lv,cell: cell,material: m,skins: skins})))
      end)
      bytes=fetch_payload(:batch,level,region)
      selected=Enum.any?(regions,fn e -> {:ok,h}=Codec.decode_payload_header(e.payload); {h.level,h.region}=={level,region} end)
      assert selected == (sparse_bytes > 13+byte_size(bytes))
    end
    expected = for level <- 0..2, region <- [{0,0,0}], into: %{}, do: {{level,region},fetch_payload(:batch,level,region)}
    ring = fetch_payload(:batch,0,{0,1,0})
    other = fetch_payload(:batch,0,{1,0,0})
    {:ok, rp} = Payload.decode(ring)
    assert Payload.material(rp,Payload.local({0,1,0},{5,63,5})) == 0
    # 任意旧游标收到同一个完整检查点；同 seq 没有重复。
    for have <- 0..1 do
      [checkpoint] = World.entries_after(:batch,have)
      assert checkpoint.seq == 2
      assert Enum.any?(checkpoint.entries,&Map.has_key?(&1,:payload))
      assert Enum.any?(checkpoint.entries, &match?(%{coord: {70,63,2},material: 0}, &1))
      {:ok,base}=Payload.decode(before)
      replayed=apply_client_transaction(base,checkpoint)
      {:ok,expected_payload}=Payload.decode(Map.fetch!(expected,{0,{0,0,0}}))
      assert replayed.cells == expected_payload.cells
    end
    assert [] == World.entries_after(:batch,2)
    :ok=World.subscribe(:batch,self(),0,{{20,20,20},{20,20,20}},4)
    refute_receive {:voxel_log_transaction_payload,_},100
    GenServer.stop(world)
    {:ok, world} = World.start_link(root: root, log: OverlayLog.Db, name: :batch)
    for {{level,region},bytes} <- expected, do: assert(fetch_payload(:batch,level,region) == bytes)
    assert fetch_payload(:batch,0,{0,1,0}) == ring
    assert fetch_payload(:batch,0,{1,0,0}) == other
    assert {:ok,3} = World.apply_edits(:batch,[{{5,63,5},11}])
    [sparse] = World.entries_after(:batch,2)
    assert [%{coord: {5,63,5},material: 11}] = sparse.entries
    assert :ok = World.compact(:batch)
    final = fetch_payload(:batch,0,{0,0,0})
    final_ring = fetch_payload(:batch,0,{0,1,0})
    GenServer.stop(world)
    {:ok,_} = World.start_link(root: root, log: OverlayLog.Db, name: :batch)
    assert fetch_payload(:batch,0,{0,0,0}) == final
    assert fetch_payload(:batch,0,{0,1,0}) == final_ring
    # 完整 L0 终态：全部 66³ 格，包括 owned 与 ring。
    {:ok,p} = Payload.decode(final)
    {:ok,base} = Payload.decode(before)
    changed = Map.new(edits) |> Map.put({5,63,5},11)
    for z <- -1..64,y <- -1..64,x <- -1..64 do
      local = Payload.local({0,0,0},{x,y,z})
      assert Payload.material(p,local) == Map.get(changed,{x,y,z},Payload.material(base,local))
    end
  end

  defp fetch_payload(server,level,region) do
    {:ok,reply}=World.serve(server,request([%{level: level,region: region,have_seq: 0,have_hash: 0}],0))
    {:ok,_,[{:payload,^level,^region,bytes}]}=Codec.decode_reply(IO.iodata_to_binary(reply))
    bytes
  end

  # 独立消费端模型：region 只复制 owned 64³ 的交集，稀疏值只写当前 66³。
  defp apply_client_transaction(payload,txn) do
    {ox,oy,oz}=Payload.origin(payload.region)
    overrides=Enum.reduce(txn.entries,%{},fn
      %{payload: bytes},acc ->
        {:ok,source}=Payload.decode(bytes)
        {rx,ry,rz}=source.region
        if source.level==payload.level and rx*64 <= ox+65 and rx*64+63 >= ox and
             ry*64 <= oy+65 and ry*64+63 >= oy and rz*64 <= oz+65 and rz*64+63 >= oz do
          for z <- max(oz,rz*64)..min(oz+65,rz*64+63),
              y <- max(oy,ry*64)..min(oy+65,ry*64+63),
              x <- max(ox,rx*64)..min(ox+65,rx*64+63),
              Payload.in_span?(Payload.local(source.region,{x,y,z})),reduce: acc do
            a -> Map.put(a,Payload.local(payload.region,{x,y,z}),Payload.value(source,Payload.local(source.region,{x,y,z})))
          end
        else
          acc
        end
      e,acc ->
        local=Payload.local(payload.region,e.coord)
        if payload.level==0 and Payload.in_span?(local),do: Map.put(acc,local,{e.material,MmoContracts.Voxel.Skins.uniform(e.material)}),else: acc
    end)
    overrides=Enum.reduce(txn.coarse,overrides,fn e,acc ->
      local=Payload.local(payload.region,e.cell)
      if e.level==payload.level and Payload.in_span?(local),do: Map.put(acc,local,{e.material,e.skins}),else: acc
    end)
    {:ok,replayed}=Payload.decode(Payload.encode(payload,overrides,txn.seq,@cv))
    replayed
  end

  test "HTTP sparse entries verify the served base and reconstruct cells and skins; old or replaced bases use payload", %{root: root} do
    {:ok,_}=World.start_link(root: root, log: OverlayLog.Db, name: :http_entries)
    assert {:ok,1}=World.apply_edit(:http_entries,{5,63,5},7)
    bases=for level <- 0..2, into: %{} do
      bytes=fetch_payload(:http_entries,level,{0,0,0})
      {:ok,h}=Codec.decode_payload_header(bytes)
      {level,{bytes,h}}
    end
    assert {:ok,2}=World.apply_edits(:http_entries,[{{4,63,4},7}])
    for {level,{base,h}} <- bases do
      item=%{level: level,region: {0,0,0},have_seq: h.seq,have_hash: h.hash}
      {:ok,reply}=World.serve(:http_entries,request([item],@cv))
      {:ok,_,decoded}=Codec.decode_reply(IO.iodata_to_binary(reply))
      if match?([{:entries,_,_,_}],decoded) do
        [{:entries,^level,{0,0,0},txns}]=decoded
        {:ok,repeat}=World.serve(:http_entries,request([item],@cv))
        assert IO.iodata_to_binary(repeat)==IO.iodata_to_binary(reply)
        {:ok,p}=Payload.decode(base)
        overrides=Enum.reduce(txns,%{},fn txn,acc ->
          acc=Enum.reduce(txn.entries,acc,fn e,a -> Map.put(a,Payload.local({0,0,0},e.coord),{e.material,MmoContracts.Voxel.Skins.uniform(e.material)}) end)
          Enum.reduce(txn.coarse,acc,fn e,a -> Map.put(a,Payload.local({0,0,0},e.cell),{e.material,e.skins}) end)
        end)
        reconstructed=Payload.encode(p,overrides,List.last(txns).seq,@cv)
        expected=fetch_payload(:http_entries,level,{0,0,0})
        assert {:ok,_,raw}=Codec.decode_payload_body(reconstructed)
        assert {:ok,_,^raw}=Codec.decode_payload_body(expected)
      end
      {:ok,forged}=World.serve(:http_entries,request([%{item | have_hash: h.hash+1}],@cv))
      assert {:ok,_,[{:payload,_,_,_}]}=Codec.decode_reply(IO.iodata_to_binary(forged))
    end
    # 稀疏 L0 的已知版本应确实走 entries，不能让全载荷分支掩盖缺实现。
    bytes=fetch_payload(:http_entries,0,{0,0,0})
    {:ok,h}=Codec.decode_payload_header(bytes)
    assert {:ok,3}=World.apply_edits(:http_entries,[{{8,63,8},0}])
    req=request([%{level: 0,region: {0,0,0},have_seq: h.seq,have_hash: h.hash}],@cv)
    {:ok,reply}=World.serve(:http_entries,req)
    assert {:ok,_,[{:entries,0,{0,0,0},[_]}]}=Codec.decode_reply(IO.iodata_to_binary(reply))
    assert :ok=World.compact(:http_entries)
    # 检查点只含 cell 时仍可用；跨过 region 替换必须整载荷。
    dense=for x <- 0..10,y <- 50..63,z <- 0..10,do: {{x,y,z},0}
    assert {:ok,4}=World.apply_edits(:http_entries,dense)
    {:ok,reply}=World.serve(:http_entries,req)
    assert {:ok,_,[{:payload,0,{0,0,0},_}]}=Codec.decode_reply(IO.iodata_to_binary(reply))
  end

  test "compaction stamps reused region snapshots with the new checkpoint sequence", %{root: root} do
    {:ok,world}=World.start_link(root: root, log: OverlayLog.Db, name: :stamp)
    edits=for x <- 0..10,y <- 55..63,z <- 0..10,do: {{x,y,z},0}
    assert {:ok,1}=World.apply_edits(:stamp,edits)
    [first]=World.entries_after(:stamp,0)
    first_headers=Map.new(Enum.filter(first.entries,&Map.has_key?(&1,:payload)),fn e ->
      {:ok,h}=Codec.decode_payload_header(e.payload)
      {{h.level,h.region},h}
    end)
    assert map_size(first_headers)>0
    assert {:ok,2}=World.apply_edit(:stamp,{70,63,5},0)
    assert :ok=World.compact(:stamp)
    [checkpoint]=World.entries_after(:stamp,1)
    assert checkpoint.seq==2
    # 跨端 fixture（Voxim `Docs/R6/runtime/s3_server_checkpoint_seq2.bin`，C++ `Voxim.Net.DenseTransactionAndBatchFramesRoundTrip` 解码）：线格式变了就带 VOXIM_CHECKPOINT_FIXTURE=<path> 重跑本测试重出。
    if path=System.get_env("VOXIM_CHECKPOINT_FIXTURE"), do: File.write!(path,IO.iodata_to_binary(Codec.encode_transaction(checkpoint)))
    for entry <- checkpoint.entries, Map.has_key?(entry,:payload) do
      {:ok,h}=Codec.decode_payload_header(entry.payload)
      assert h.seq==checkpoint.seq and entry.seq==checkpoint.seq
      if old=Map.get(first_headers,{h.level,h.region}), do: assert(h.hash==old.hash)
    end
    GenServer.stop(world)
    {:ok,_}=World.start_link(root: root, log: OverlayLog.Db, name: :stamp)
    assert [checkpoint]==World.entries_after(:stamp,0)
  end

  test "subscription box must include visible intermediate levels beyond the L0 window", %{root: root} do
    # viewer=0：L0 active [-2,2]；L1 region x=2 仍驻留，其 canonical x=[256,384)。
    for {level,region} <- [{0,{4,0,0}},{1,{2,0,0}},{2,{1,0,0}}] do
      {:ok,bytes,_}=FileStore.read(root,@cv,level,{0,0,0})
      {:ok,_,raw}=Codec.decode_payload_body(bytes)
      File.write!(FileStore.path(root,@cv,level,region),Codec.encode_payload(level,region,0,@cv,raw))
    end
    {:ok,_}=World.start_link(root: root, log: OverlayLog.Db, name: :intermediate_subscription)
    :ok=World.subscribe(:intermediate_subscription,self(),0,{{-2,-2,-2},{2,2,2}},4)
    edits=for x <- 300..301,y <- 10..11,z <- 10..11,do: {{x,y,z},0}
    assert {:ok,1}=World.apply_edits(:intermediate_subscription,edits)
    refute_receive {:voxel_log_transaction_payload,_},100
    [txn]=World.entries_after(:intermediate_subscription,0)
    assert [%{level: 1,cell: {150,5,5},material: 0}]=txn.coarse
    # 把 L1 active [-2,2] 投影成 L0 region 单位 [-4,5]，门槛仍是 L4。
    :ok=World.subscribe(:intermediate_subscription,self(),0,{{-4,-4,-4},{5,5,5}},4)
    assert_receive {:voxel_log_transaction_payload,wire},500
    assert {:ok,^txn}=Codec.decode_transaction(wire)
  end

  test "no-op confirms the initiating subscriber beyond its filtered cursor without journaling or broadcasting", %{root: root} do
    {:ok,_}=World.start_link(root: root, log: OverlayLog.Db, name: :noop_cursor)
    parent=self()
    observer=spawn_link(fn ->
      :ok=World.subscribe(:noop_cursor,self(),0,{{0,0,0},{0,0,0}},4)
      send(parent,:observer_ready)
      receive do
        :inspect ->
          messages=Process.info(self(),:messages) |> elem(1)
          send(parent,{:observer_messages,messages})
      end
    end)
    assert_receive :observer_ready
    # 发起方只订远处，故当前seq=1的普通编辑被过滤，账本游标仍是0。
    :ok=World.subscribe(:noop_cursor,self(),0,{{20,20,20},{20,20,20}},4)
    assert {:ok,1}=World.apply_edits(:noop_cursor,[{{5,63,5},0}])
    refute_receive {:voxel_log_transaction_payload,_},100
    log=OverlayLogStore.read_all(@cv)
    assert {:ok,1}=World.apply_edits(:noop_cursor,[{{5,63,5},0}])
    assert_receive {:voxel_log_transaction_payload,bytes},500
    assert {:ok,%{seq: 1,entries: [],coarse: []}}=Codec.decode_transaction(bytes)
    assert World.seq(:noop_cursor)==1
    assert OverlayLogStore.read_all(@cv)==log
    assert length(World.entries_after(:noop_cursor,0))==1
    # 原单格入口同样能确认no-op。
    assert {:ok,1}=World.apply_edit(:noop_cursor,{5,63,5},0)
    assert_receive {:voxel_log_transaction_payload,^bytes},500
    # 观察者只收到真实事务一次，不收到发起方两次no-op确认。
    send(observer,:inspect)
    assert_receive {:observer_messages,[{:voxel_log_transaction_payload,normal}]},500
    assert {:ok,%{seq: 1,entries: [_],coarse: []}}=Codec.decode_transaction(normal)
    refute_receive {:voxel_log_transaction_payload,_},100
    # 同一发送者保证backlog在no-op确认之前，正常事务不被重复确认。
    :ok=World.subscribe(:noop_cursor,self(),0,{{0,0,0},{0,0,0}},4)
    assert {:ok,1}=World.apply_edits(:noop_cursor,[{{5,63,5},0}])
    assert_receive {:voxel_log_transaction_payload,^normal},500
    assert_receive {:voxel_log_transaction_payload,^bytes},500
  end

  test "subscribe replays the backlog after have_seq, filters by box (+1 ring) and coarse level, and fans out new entries", %{root: root} do
    {:ok, _} = World.start_link(root: root, log: OverlayLog.Db, name: :w3)
    assert {:ok, 1} = World.apply_edit(:w3, {5, 63, 5}, 0)
    assert {:ok, 2} = World.apply_edit(:w3, {70, 63, 5}, 0)

    # box 只含 region (0,0,0)：(70,63,5) 在 region (1,0,0)，在外扩 1 之内 → 两条都来。
    :ok = World.subscribe(:w3, self(), 0, {{0, 0, 0}, {0, 0, 0}}, 4)
    assert_receive {:voxel_log_entry_payload, b1}, 500
    assert_receive {:voxel_log_entry_payload, b2}, 500
    {:ok, e1} = Codec.decode_entry(b1)
    {:ok, e2} = Codec.decode_entry(b2)
    assert e1.seq == 1 and e2.seq == 2 and e2.coord == {70, 63, 5}

    # have_seq = 2：没有积压；新条目实时来。
    :ok = World.subscribe(:w3, self(), 2, {{0, 0, 0}, {0, 0, 0}}, 4)
    refute_receive {:voxel_log_entry_payload, _}, 100
    assert {:ok, 3} = World.apply_edit(:w3, {6, 63, 5}, 0)
    assert_receive {:voxel_log_entry_payload, b3}, 500
    assert {:ok, %{seq: 3, coord: {6, 63, 5}}} = Codec.decode_entry(b3)

    # box 在别处、coarse 门槛高：远处的 L0 条目不来。
    :ok = World.subscribe(:w3, self(), 3, {{5, 5, 5}, {5, 5, 5}}, 4)
    assert {:ok, 4} = World.apply_edit(:w3, {7, 63, 5}, 0)
    refute_receive {:voxel_log_entry_payload, _}, 100
  end

  test "payload cache evicts L0-L3 by least recent use within the byte limit, keeps L4+ resident and invalidates edited regions", %{root: root} do
    # 合成 L4 (0,0,0)：全实心；只用来证明常驻层不进 LRU。
    l4 = for _ <- 1..@cells, into: <<>>, do: <<11::16-little>>
    skins = <<@extent::32-little, @extent::32-little, @extent::32-little, 16::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little>>
    File.mkdir_p!(Path.join([root, FileStore.hex(@cv), "L4"]))
    File.write!(FileStore.path(root, @cv, 4, {0, 0, 0}), Codec.encode_payload(4, {0, 0, 0}, 0, @cv, <<@cells::32-little, l4::binary, skins::binary>>))

    a = fetch_size(:lru_probe, root, 0, {0, 0, 0})
    # 上限装得下两份 L0，装不下三份。
    {:ok, _} = World.start_link(root: root, log: OverlayLog.Db, name: :lru, payload_cache_bytes: a * 2 + 16)
    first = fetch_payload(:lru, 0, {0, 0, 0})
    second = fetch_payload(:lru, 0, {1, 0, 0})
    resident = fetch_payload(:lru, 4, {0, 0, 0})
    assert %{entries: 3, evictions: 0, hits: 0, misses: 3, lru_bytes: lru_bytes, resident_bytes: resident_bytes} = World.stats(:lru)
    assert lru_bytes == byte_size(first) + byte_size(second) and resident_bytes == byte_size(resident)

    # 命中刷新最近使用：先摸 first，再放第三份 → 淘汰的是 second。
    assert fetch_payload(:lru, 0, {0, 0, 0}) == first
    third = fetch_payload(:lru, 0, {-1, 0, 0})
    assert %{entries: 3, evictions: 1, hits: 1, misses: 4} = World.stats(:lru)
    assert fetch_payload(:lru, 0, {1, 0, 0}) == second
    assert %{entries: 3, evictions: 2, hits: 1, misses: 5} = World.stats(:lru)
    # first 是最久未用的：被挤掉；常驻 L4 仍在缓存里、命中不读盘。
    assert fetch_payload(:lru, 4, {0, 0, 0}) == resident
    assert %{hits: 2} = World.stats(:lru)
    assert fetch_payload(:lru, 0, {-1, 0, 0}) == third
    assert %{entries: 3, evictions: 2, hits: 3, misses: 5} = World.stats(:lru)

    # 编辑碰到的 region 立即失效：命中的物化载荷 seq=1，且再次命中不重编码。
    assert {:ok, 1} = World.apply_edit(:lru, {5, 63, 5}, 0)
    edited = fetch_payload(:lru, 0, {0, 0, 0})
    {:ok, h} = Codec.decode_payload_header(edited)
    assert h.seq == 1
    assert fetch_payload(:lru, 0, {0, 0, 0}) == edited
    %{hits: hits} = World.stats(:lru)
    assert hits >= 4
  end

  defp fetch_size(name, root, level, region) do
    {:ok, pid} = World.start_link(root: root, log: OverlayLog.Db, name: name)
    size = byte_size(fetch_payload(name, level, region))
    GenServer.stop(pid)
    size
  end
end
