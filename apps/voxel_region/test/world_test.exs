defmodule VoxelRegion.WorldTest do
  use ExUnit.Case, async: false

  alias VoxelRegion.{Codec, FileStore, Payload, Reducer, World}

  @cv 0x1122_3344_5566_7788
  @extent 66
  @cells @extent * @extent * @extent

  # 合成世界：L0 region (0,0,0)…(1,1,1) 全是石头(11)、上面一层 y 的 region 全空气；L1 (0,0,0) 由 reduce 得出（这里直接按同一规则写：下半实心上半空气）。
  defp write_world(root) do
    world = Path.join(root, FileStore.hex(@cv))

    for level <- 0..2, do: File.mkdir_p!(Path.join(world, "L#{level}"))

    solid = :binary.copy(<<11::16-little>>, @cells)
    air = :binary.copy(<<0::16-little>>, @cells)
    empty_skins = <<@extent::32-little, @extent::32-little, @extent::32-little, 1::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little>>

    for x <- -1..1, z <- -1..1 do
      File.write!(FileStore.path(root, @cv, 0, {x, 0, z}), Codec.encode_payload(0, {x, 0, z}, 0, @cv, <<@cells::32-little, solid::binary, empty_skins::binary>>))
      File.write!(FileStore.path(root, @cv, 0, {x, 1, z}), Codec.encode_payload(0, {x, 1, z}, 0, @cv, <<@cells::32-little, air::binary, empty_skins::binary>>))
    end

    # L1 (0,0,0)：y < 32 实心（children 在 L0 y-region 0）、y ≥ 32 空气；ring 也按同一规则（L1 cell y=-1 → 实心，y=64 → 空气）。
    l1 = for lz <- 0..(@extent - 1), ly <- 0..(@extent - 1), lx <- 0..(@extent - 1), into: <<>>, do: <<if(ly - 1 < 32, do: 11, else: 0)::16-little>>
    File.write!(FileStore.path(root, @cv, 1, {0, 0, 0}), Codec.encode_payload(1, {0, 0, 0}, 0, @cv, <<@cells::32-little, l1::binary, @extent::32-little, @extent::32-little, @extent::32-little, 2::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little>>))
    l2 = for lz <- 0..(@extent - 1), ly <- 0..(@extent - 1), lx <- 0..(@extent - 1), into: <<>>, do: <<if(ly - 1 < 16, do: 11, else: 0)::16-little>>
    File.write!(FileStore.path(root, @cv, 2, {0, 0, 0}), Codec.encode_payload(2, {0, 0, 0}, 0, @cv, <<@cells::32-little, l2::binary, @extent::32-little, @extent::32-little, @extent::32-little, 4::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little>>))
    world
  end

  setup do
    root = Path.join(System.tmp_dir!(), "voxel_region_world_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    write_world(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp request(items, cv), do: IO.iodata_to_binary(Codec.encode_request(cv, items))

  test "edit at the surface flips L1 (material + skin) and stops where nothing changes; payloads are re-materialized", %{root: root} do
    {:ok, world} = World.start_link(root: root, name: :w1)
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
    {:ok, _} = World.start_link(root: root, name: :w2)
    assert World.seq(:w2) == 5
    {:ok, reply} = World.serve(:w2, request([%{level: 0, region: {0, 0, 0}, have_seq: h1.seq, have_hash: h1.hash}], @cv))
    assert {:ok, _, [{:unchanged, 0, {0, 0, 0}}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
  end

  test "subscribe replays the backlog after have_seq, filters by box (+1 ring) and coarse level, and fans out new entries", %{root: root} do
    {:ok, _} = World.start_link(root: root, name: :w3)
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

end
