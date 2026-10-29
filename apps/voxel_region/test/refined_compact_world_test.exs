defmodule VoxelRegion.RefinedCompactWorldTest do
  @moduledoc """
  只测试：作者发布并放置有限混合微格，经真实 File 页发布和三个独立冷读取恢复。
  Source 仅提供空气基底；World、页读写、Feed、Replica、碰撞和材料结算均使用真实模块。
  玩家不补余额：先由作者建立样本，再经正常移除回收其实际材料。此例不证明 Gate 或 UE。
  """
  use ExUnit.Case, async: false
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.{CollisionSource, OverlayLog, Prefab, Replica, World}
  alias VoxelRegion.TestSupport.{Actor, Source}

  @region {-1, 1, 2}
  @box {{-1, 1, 2}, {0, 2, 3}}
  @cell {-63, 65, 130}
  @anchor {-504, 520, 1040}

  setup do
    root = Path.join(System.tmp_dir!(), "refined_compact_#{System.pid()}_#{System.unique_integer([:positive])}")
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}],
      tools: [%{id: "pick", tool_id: 1, action: "damage", power: 30, range_macro: 6, interval_seconds: 0.5}], definitions: [],
      materials: for(id <- 0..23, do: %{material_id: id, max_hp_per_macro: if(id == 0, do: 0, else: 100),
        defense: 0, tags: [], responses: [%{action: "damage", multiplier: 1}]})}))
    cells = for slot <- 0..32, do: {Prefab.micro_coord({0, 0, 0}, slot), if(rem(slot, 2) == 0, do: 11, else: 19)}
    bytes = Prefab.encode(%{cells: cells, children: [], attachments: [], macro_cells: []})
    File.write!(Path.join(prefabs, "sample.vxpd"), bytes)
    opts = [source: Source, log: OverlayLog.File, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, prefab_catalog_path: prefabs, production_materials: [11, 19]]
    world = start_supervised!({World, opts})
    actor = %{cid: 1001, gate: self(), identity: :compact_reader,
      refresh: &Actor.tool_context/2, eye: {-63.0, 65.0, 129.0}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world, opts: opts, root: root, actor: actor, id: :crypto.hash(:sha256, bytes)}
  end

  test "format2 冷恢复的 HTTP、Replica、Feed 首读相同；换身份无碰撞差额，正常移除准确回收", c do
    assert {:ok, 1} = World.place_prefab(c.world, c.id, @anchor, 0)
    before = serve(c.world)
    assert {:ok, old_payload} = Payload.decode(before)
    assert :ok = World.compact(c.world)

    %{rows: rows} = OverlayLog.File.read_pages(Path.join(c.root, "overlay.log"), [{0, @region}], [])
    stored = for %{segment: 2, payload: bytes} <- rows,
      {cell, slots} <- VoxelRegion.World.Pages.decode(bytes), into: %{}, do: {cell, slots}
    assert is_map(stored[@cell]) and not is_struct(stored[@cell])
    assert map_size(stored[@cell]) == 33

    world = Enum.reduce([:http, :replica, :feed], c.world, fn reader, _world ->
      stop_supervised!(World)
      world = start_supervised!({World, c.opts})
      assert World.stats(world).resident_pages == 0
      assert read_first(world, reader) == before
      world
    end)

    assert :ok = World.canonical_snapshot_and_subscribe(world, @box, self(), :collision, true)
    assert_receive {:canonical_snapshot, :collision, %{transaction_seq: 1, chunks: chunks}}, 30_000
    coord = CollisionSource.chunk_coord(@cell)
    old_chunk = Enum.find(chunks, &(&1.coord == coord))
    assert old_chunk == CollisionSource.capture(old_payload, coord)
    assert old_chunk.n == 128

    assert {:ok, 2} = World.replace_prefab(world, {1, 0}, c.id)
    assert_receive {:canonical_delta, %{transaction_seq: 2, chunks: []}}, 30_000
    assert [%{slots: slots}] = World.material_snapshot(world, [], [@cell]).probe_occupancy
    assert Enum.sort(Enum.map(slots, &{&1.material, &1.count, &1.instance})) ==
      [{11, 17, [2, 0]}, {19, 16, [2, 0]}]

    assert {:ok, 3} = World.prefab_intent(world, c.actor, :voxel_prefab_remove_v1,
      %{instance_id: {2, 0}, client_intent_seq: 1})
    assert_receive {:canonical_delta, %{transaction_seq: 3, chunks: [new_chunk]}}, 30_000
    assert new_chunk.coord == coord
    assert new_chunk.n == 16
    assert new_chunk.cells == :binary.copy(<<0>>, 16 * 16 * 16)
    assert old_chunk.cells != new_chunk.cells
    assert Enum.sort(Enum.map(World.material_balances(world, 1001), &{&1.material, &1.balance})) ==
      [{11, 17}, {19, 16}]
    assert [%{refined: false, material: 0, slots: []}] =
      World.material_snapshot(world, [], [@cell]).probe_occupancy
  end

  test "33 槽地块导出仍是 format1 map，序列化后安装到独立世界并从 format2 冷恢复", c do
    assert {:ok, 1} = World.place_prefab(c.world, c.id, @anchor, 0)
    assert {:ok, parcel} = World.parcel_export(c.world, {@cell, {-62, 66, 131}})
    assert parcel.format == 1
    assert is_map(parcel.refined[@cell]) and not is_struct(parcel.refined[@cell])
    assert map_size(parcel.refined[@cell]) == 33
    copied = parcel |> :erlang.term_to_binary() |> :erlang.binary_to_term([:safe])
    root = Path.join(c.root, "parcel-target")
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    opts = Keyword.merge(c.opts, root: root, prefab_catalog_path: prefabs)
    target = start_supervised!({World, opts}, id: :parcel_target)
    assert {:ok, %{seq: 1, cells: 1, instances: 1, units: %{11 => 17, 19 => 16}}} =
      World.parcel_install(target, "compact-format1", copied, {63, -65, -130})
    payload = VoxelRegion.TestSupport.payload(target, 0, {0, 0, 0})
    assert payload.refined[4423] == copied.refined[@cell]
    assert :ok = World.compact(target)
    stop_supervised!(:parcel_target)
    restored = start_supervised!({World, opts}, id: :parcel_target)
    assert World.stats(restored).resident_pages == 0
    current = VoxelRegion.TestSupport.payload(restored, 0, {0, 0, 0})
    assert current.refined == payload.refined
    assert current.instances == payload.instances
  end

  defp read_first(world, :http), do: serve(world)
  defp read_first(world, :replica) do
    replica = start_supervised!({Replica, authority_ref: world, l0_box: @box, name: nil})
    assert :ok = Replica.canonical_snapshot_and_subscribe(replica, @box, self(), :replica, false)
    assert_receive {:canonical_snapshot, :replica, %{transaction_seq: 1, regions: [{@region, bytes}]}}, 30_000
    stop_supervised!(Replica)
    bytes
  end
  defp read_first(world, :feed) do
    assert :ok = World.canonical_snapshot_and_subscribe(world, @box, self(), :feed, false)
    assert_receive {:canonical_snapshot, :feed, %{transaction_seq: 1, regions: [{@region, bytes}]}}, 30_000
    bytes
  end
  defp serve(world) do
    request = Codec.encode_request(123, [%{level: 0, region: @region, have_seq: 0, have_hash: 0}])
      |> IO.iodata_to_binary()
    assert {:ok, reply} = World.serve(world, request)
    assert {:ok, _, [{:payload, 0, @region, bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    bytes
  end
end
