defmodule SceneServer.Movement.VoximImmutableNativeTest do
  use ExUnit.Case, async: false
  alias SceneServer.Native.VoximMovement, as: Native

  defp profile do
    root = Path.expand("../../../../../../Voxim", __DIR__)
    p = root |> Path.join("Docs/M0/fixtures/suite.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("profile")
    ~w(radius half_height speed acceleration braking air_braking friction braking_friction_factor air_control gravity jump_speed step_height snap_distance skin slope_radians)
    |> Enum.map(&(Map.fetch!(p, &1) / 1)) |> List.to_tuple()
  end

  test "published collision handle is unchanged by building its successor" do
    empty = Native.new_world()
    floor = Native.set_chunks(empty, [{:set, {0, 0, 0}, 2, 1.0,
      {0.0, 0.0, 0.0}, <<1, 1, 0, 0, 1, 1, 0, 0>>}])
    assert {0, 0, 0} == Native.world_stats(empty)
    assert {1, 1, 1} == Native.world_stats(floor)
    removed = Native.set_chunks(floor, [{:remove, {0, 0, 0}}])
    assert {1, 1, 1} == Native.world_stats(floor)
    assert {0, 0, 0} == Native.world_stats(removed)
  end

  test "two real NIF readers replay their original version while a successor is built" do
    p = profile()
    world = Native.set_chunks(Native.new_world(), [{:set, {0, 0, 0}, 2, 1.0,
      {0.0, 0.0, 0.0}, <<1, 1, 0, 0, 1, 1, 0, 0>>}])
    {:ok, start} = Native.find_spawn(world, p, {0.5, 8.0, 0.5}, -20.0)
    replay = fn handle, jump ->
      Enum.reduce(1..120, start, fn tick, s ->
        [{1, next}] = Native.step_characters(handle, p, [{1, s, {0.0, 0.0, if(tick == 1, do: jump, else: 0)}}])
        next
      end)
    end
    baseline = for jump <- [0, 1], do: replay.(world, jump)
    parent = self()
    readers = for jump <- [0, 1] do
      Task.async(fn ->
        send(parent, {:reader_ready, self()})
        receive do :go -> replay.(world, jump) end
      end)
    end
    for _ <- readers, do: assert_receive({:reader_ready, _})
    for task <- readers, do: send(task.pid, :go)
    next = Native.set_chunks(world, [{:remove, {0, 0, 0}}])
    assert Enum.map(readers, &Task.await/1) == baseline
    assert {{_, y, _}, _, 0} = replay.(next, 0)
    assert y < -10.0
    assert Native.find_spawn(world, p, {0.5, 8.0, 0.5}, -20.0) == {:ok, start}
  end
end
