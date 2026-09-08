defmodule SceneServer.Movement.VoximNativeTest do
  use ExUnit.Case, async: false
  alias SceneServer.Native.VoximMovement, as: Native

  defp profile do
    path = Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
    p = path |> File.read!() |> Jason.decode!() |> Map.fetch!("profile")
    ~w(radius half_height speed acceleration braking air_braking friction braking_friction_factor air_control gravity jump_speed step_height snap_distance skin slope_radians)
    |> Enum.map(&(Map.fetch!(p, &1) / 1)) |> List.to_tuple()
  end

  defp floor_op(x), do: {:set, {x, 0, 0}, 2, 1.0, {x * 2.0, 0.0, 0.0}, <<1, 1, 0, 0, 1, 1, 0, 0>>}
  defp step(world, p, state), do: Native.step_characters(world, p, [{1, state, {0.0, 0.0, 0}}]) |> hd() |> elem(1)

  test "actual NIF shares world, restores states, and removes all-air/BVH support" do
    p = profile()
    world = Native.new_world()
    assert {0, 0, 0} = Native.world_stats(world)
    assert :ok = Native.set_chunks(world, [floor_op(0), floor_op(1)])
    assert {2, 2, 2} = Native.world_stats(world)
    assert {:ok, a} = Native.find_spawn(world, p, {0.5, 8.0, 0.5}, -2.0)
    assert {:ok, b} = Native.find_spawn(world, p, {2.5, 8.0, 0.5}, -2.0)
    chars = [{1, a, {0.0, 0.0, 1}}, {2, b, {0.0, 0.0, 0}}]
    assert [{1, {_, {_, vy, _}, _}}, {2, {_, _, 1}}] = result = Native.step_characters(world, p, chars)
    assert vy > 0
    assert result == Native.step_characters(world, p, chars)
    assert :ok = Native.set_chunks(world, [{:set, {0, 0, 0}, 2, 1.0, {0.0, 0.0, 0.0}, <<0::64>>}, {:remove, {1, 0, 0}}])
    assert :ok = Native.set_chunks(world, [{:remove, {1, 0, 0}}])
    assert {0, 0, 0} = Native.world_stats(world)
    for start <- [a, b] do
      assert {{_, y, _}, {_, vy, _}, 0} = Enum.reduce(1..30, start, fn _, s -> step(world, p, s) end)
      assert y < 1.0 and vy < -4.0
    end
    assert :not_found = Native.find_spawn(world, p, {0.5, 8.0, 0.5}, -2.0)
    assert :ok = Native.set_chunks(world, [floor_op(0)])
    assert {:ok, _} = Native.find_spawn(world, p, {0.5, 8.0, 0.5}, -2.0)
    assert :not_found = Native.find_spawn(world, p, {0.5, 0.5, 0.5}, -2.0)
  end

  test "boundary rejects a whole malformed batch without partial mutation" do
    p = profile()
    world = Native.new_world()
    for ops <- [[floor_op(1), floor_op(0)], [floor_op(0), floor_op(0)], [floor_op(0), {:set, {1, 0, 0}, 2, 1.0, {2.0, 0.0, 0.0}, <<1>>}]] do
      assert_raise ArgumentError, fn -> Native.set_chunks(world, ops) end
      assert :not_found = Native.find_spawn(world, p, {0.5, 8.0, 0.5}, -2.0)
    end
    s = {{-0.0, -2.0, 0.0}, {0.0, -0.0, -1.0}, 0}
    assert {{a, b, c}, {d, e, f}} = Native.query_bounds(p, s)
    assert a < d and b < e and c < f
    assert_raise ArgumentError, fn -> Native.step_characters(world, p, [{1, s, {0.0, 0.0, 2}}]) end
    assert_raise ArgumentError, fn -> Native.step_characters(world, p, [{2, s, {0.0, 0.0, 0}}, {1, s, {0.0, 0.0, 0}}]) end
    assert_raise ArgumentError, fn -> Native.query_bounds(p, put_elem(s, 2, 2)) end
  end

  test "two-character dirty CPU call cost is measured online" do
    p = profile()
    world = Native.new_world()
    # 合成 512 个 16³ core 测试输入，真实 R6 地形构建由 D1 另行验收。
    cells = :binary.copy(:binary.copy(<<1>>, 16) <> :binary.copy(<<0>>, 240), 16)
    operations = for x <- 0..7, y <- 0..7, z <- 0..7, do:
      {:set, {x, y, z}, 16, 1.0, {x * 16.0, y * 16.0, z * 16.0}, cells}
    {build_us, :ok} = :timer.tc(fn -> Native.set_chunks(world, operations) end)
    {:ok, a} = Native.find_spawn(world, p, {0.5, 120.0, 0.5}, -2.0)
    {:ok, b} = Native.find_spawn(world, p, {16.5, 120.0, 0.5}, -2.0)
    {us, states} = :timer.tc(fn -> Enum.reduce(1..600, [{1, a}, {2, b}], fn _, states ->
      Native.step_characters(world, p, Enum.map(states, fn {id, s} -> {id, s, {0.0, 0.0, 0}} end))
    end) end)
    IO.puts("P1_NIF synthetic_chunks=512 cells_bytes=#{512 * byte_size(cells)} build_us=#{build_us} two_characters=2 steps=600 total_us=#{us} us_per_call=#{us / 600} final=#{inspect(states)}")
    assert Enum.all?(states, fn {_, {_, _, grounded}} -> grounded == 1 end)
  end

  test "online input and edit replay exports bit-exact two-character states" do
    p = profile()
    world = Native.new_world()
    :ok = Native.set_chunks(world, [floor_op(0), floor_op(1)])
    {:ok, a} = Native.find_spawn(world, p, {0.5, 8.0, 0.5}, -20.0)
    {:ok, b} = Native.find_spawn(world, p, {2.5, 8.0, 0.5}, -20.0)
    {_, trace} = Enum.reduce(1..240, {[{1, a}, {2, b}], []}, fn tick, {states, trace} ->
      if tick == 90, do: Native.set_chunks(world, [{:remove, {0, 0, 0}}, {:remove, {1, 0, 0}}])
      if tick == 150, do: Native.set_chunks(world, [floor_op(0), floor_op(1)])
      characters = Enum.map(states, fn {id, state} ->
        axis = if tick < 35, do: (if id == 1, do: -0.25, else: 0.25), else: 0.0
        {id, state, {axis, 0.0, if(tick == 20, do: 1, else: 0)}}
      end)
      next = Native.step_characters(world, p, characters)
      assert next == Native.step_characters(world, p, characters)
      {next, [Enum.map(next, fn {id, {{x, y, z}, {vx, vy, vz}, grounded}} ->
        <<tick::32, id::64, x::float-64, y::float-64, z::float-64, vx::float-64, vy::float-64, vz::float-64, grounded::32>>
      end) | trace]}
    end)
    bytes = trace |> Enum.reverse() |> IO.iodata_to_binary()
    if path = System.get_env("P1_TRACE_PATH"), do: File.write!(path, bytes)
    IO.puts("P1_REPLAY ticks=240 characters=2 bytes=#{byte_size(bytes)} sha256=#{Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}")
    assert byte_size(bytes) == 240 * 2 * 64
  end
end
