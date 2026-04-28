defmodule SceneServer.AoiItemTest do
  use ExUnit.Case, async: false

  alias SceneServer.AoiManager
  alias SceneServer.Movement.RemoteSnapshot

  setup do
    ensure_started(SceneServer.AoiManager, {SceneServer.AoiManager, name: SceneServer.AoiManager})
    ensure_started(SceneServer.AoiItemSup, {SceneServer.AoiItemSup, name: SceneServer.AoiItemSup})
    :ok
  end

  test "players outside the interest radius are not included in AOI" do
    cid = unique_cid()
    other_cid = unique_cid()

    observer = add_aoi_item(cid, {0.0, 0.0, 0.0}, self())
    other = add_aoi_item(other_cid, {800.0, 0.0, 0.0}, spawn_connection())

    on_exit(fn ->
      exit_aoi_item(observer)
      exit_aoi_item(other)
    end)

    send(other, :get_aoi_tick)

    refute_receive {:"$gen_cast", {:player_enter, ^other_cid, _location}}, 150
  end

  test "self_move updates octree placement and AOI visibility" do
    cid = unique_cid()
    other_cid = unique_cid()

    observer = add_aoi_item(cid, {0.0, 0.0, 0.0}, self())
    mover = add_aoi_item(other_cid, {800.0, 0.0, 0.0}, spawn_connection())

    on_exit(fn ->
      exit_aoi_item(observer)
      exit_aoi_item(mover)
    end)

    send(mover, :get_aoi_tick)
    refute_receive {:"$gen_cast", {:player_enter, ^other_cid, _location}}, 150

    initial_item_ref = :sys.get_state(mover).item_ref

    GenServer.cast(
      mover,
      {:self_move,
       %RemoteSnapshot{
         cid: other_cid,
         server_tick: 1,
         position: {100.0, 0.0, 0.0},
         velocity: {0.0, 0.0, 0.0},
         acceleration: {0.0, 0.0, 0.0},
         movement_mode: :grounded
       }}
    )

    wait_until(fn ->
      state = :sys.get_state(mover)
      state.location == {100.0, 0.0, 0.0} and state.item_ref != initial_item_ref
    end)

    send(mover, :get_aoi_tick)

    assert_receive {:"$gen_cast", {:player_enter, ^other_cid, enter_location}}, 300
    assert enter_location == {100.0, 0.0, 0.0}
    assert_receive {:"$gen_cast", {:actor_identity, ^other_cid, :player, _name}}, 300

    GenServer.cast(
      mover,
      {:self_move,
       %RemoteSnapshot{
         cid: other_cid,
         server_tick: 2,
         position: {900.0, 0.0, 0.0},
         velocity: {0.0, 0.0, 0.0},
         acceleration: {0.0, 0.0, 0.0},
         movement_mode: :grounded
       }}
    )

    wait_until(fn ->
      state = :sys.get_state(mover)
      state.location == {900.0, 0.0, 0.0}
    end)

    send(mover, :get_aoi_tick)
    assert_receive {:"$gen_cast", {:player_leave, ^other_cid}}, 300
  end

  test "movement snapshots are decorated and throttled by AOI priority" do
    mover_cid = unique_cid()
    high_cid = unique_cid()
    low_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    high_observer = add_aoi_item(high_cid, {50.0, 0.0, 0.0}, self())
    low_observer = add_aoi_item(low_cid, {450.0, 0.0, 0.0}, self())

    on_exit(fn ->
      exit_aoi_item(mover)
      exit_aoi_item(high_observer)
      exit_aoi_item(low_observer)
    end)

    send(mover, :get_aoi_tick)
    assert_receive {:"$gen_cast", {:player_enter, ^mover_cid, _location}}, 300
    assert_receive {:"$gen_cast", {:actor_identity, ^mover_cid, :player, _name}}, 300
    assert_receive {:"$gen_cast", {:player_enter, ^mover_cid, _location}}, 300
    assert_receive {:"$gen_cast", {:actor_identity, ^mover_cid, :player, _name}}, 300

    GenServer.cast(mover, {:self_move, moving_snapshot(mover_cid, 1)})

    assert_receive {:"$gen_cast", {:player_move, %RemoteSnapshot{} = high_snapshot}}, 300
    assert high_snapshot.priority_band == :high
    assert high_snapshot.delivery_interval == 1
    refute_receive {:"$gen_cast", {:player_move, %RemoteSnapshot{priority_band: :low}}}, 150

    GenServer.cast(mover, {:self_move, moving_snapshot(mover_cid, 5)})

    delivered =
      2
      |> collect_player_moves(300)
      |> Enum.map(& &1.priority_band)
      |> Enum.sort()

    assert delivered == [:high, :low]
  end

  defp add_aoi_item(cid, location, connection_pid) do
    {:ok, pid} =
      AoiManager.add_aoi_item(
        cid,
        0,
        location,
        connection_pid,
        self(),
        %{kind: :player, name: "test-#{cid}"}
      )

    wait_until(fn ->
      case :sys.get_state(pid) do
        %{item_ref: item_ref} when not is_nil(item_ref) -> true
        _ -> false
      end
    end)

    pid
  end

  defp exit_aoi_item(nil), do: :ok

  defp exit_aoi_item(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :exit)
      wait_until(fn -> not Process.alive?(pid) end)
    end
  end

  defp spawn_connection do
    spawn(fn -> connection_loop() end)
  end

  defp moving_snapshot(cid, tick) do
    %RemoteSnapshot{
      cid: cid,
      server_tick: tick,
      position: {0.0, 0.0, 0.0},
      velocity: {10.0, 0.0, 0.0},
      acceleration: {0.0, 0.0, 0.0},
      movement_mode: :grounded
    }
  end

  defp collect_player_moves(count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_player_moves_loop(count, deadline, [])
  end

  defp collect_player_moves_loop(0, _deadline, acc), do: Enum.reverse(acc)

  defp collect_player_moves_loop(count, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:"$gen_cast", {:player_move, %RemoteSnapshot{} = snapshot}} ->
          collect_player_moves_loop(count - 1, deadline, [snapshot | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp connection_loop do
    receive do
      _ -> connection_loop()
    end
  end

  defp unique_cid do
    System.unique_integer([:positive])
  end

  defp ensure_started(name, spec) do
    case Process.whereis(name) do
      nil -> start_supervised!(spec)
      pid -> pid
    end
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0) do
    flunk("condition not met before timeout")
  end
end
