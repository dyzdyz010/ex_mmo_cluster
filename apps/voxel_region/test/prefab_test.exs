defmodule VoxelRegion.PrefabTest do
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, FileStore, Prefab, CollisionSource}
  alias MmoContracts.Voxel.{Codec, Payload}

  setup do
    root = Path.join(System.tmp_dir!(), "r7_prefab_#{System.unique_integer([:positive])}")
    catalog = Path.join(root, "catalog")
    File.mkdir_p!(catalog)
    bytes = <<"VXPD", 1::32-little, 2::32-little, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little,
      1::signed-little-32, 0::signed-little-32, 0::signed-little-32, 19::16-little, 0::32-little>>
    File.write!(Path.join(catalog,"test.vxpd"),bytes)
    id = :crypto.hash(:sha256,bytes)
    for x <- -1..1, z <- -1..1 do
      path = FileStore.path(root,123,0,{x,0,z})
      File.mkdir_p!(Path.dirname(path))
      p = %Payload{region: {x,0,z}, cells: :binary.copy(<<0,0>>,66*66*66)}
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
    assert {:ok,2} = World.remove_prefab(w,{1,0})
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

  defp payload(w,region) do
    req = Codec.encode_request(0,[%{level: 0,region: region,have_seq: 0,have_hash: 0}]) |> IO.iodata_to_binary()
    {:ok,reply} = World.serve(w,req)
    {:ok,123,[{:payload,0,^region,bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok,p} = Payload.decode(bytes)
    p
  end
end
