Code.require_file("../../../../voxel_region/test/support/prefab_fixture.exs", __DIR__)

defmodule SceneServer.Movement.PrefabCollisionTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias MmoContracts.Voxel.Payload
  setup do
    VoxelRegion.PrefabFixture.prepare()
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

end
