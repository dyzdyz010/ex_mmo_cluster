defmodule SceneServer.AoiItemTest do
  use ExUnit.Case, async: false

  alias SceneServer.AoiManager

  setup do
    start_supervised!({SceneServer.AoiManager, name: SceneServer.AoiManager})
    start_supervised!({SceneServer.AoiItemSup, name: SceneServer.AoiItemSup})
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
    GenServer.cast(mover, {:self_move, {100.0, 0.0, 0.0}})

    wait_until(fn ->
      state = :sys.get_state(mover)
      state.location == {100.0, 0.0, 0.0} and state.item_ref != initial_item_ref
    end)

    send(mover, :get_aoi_tick)

    assert_receive {:"$gen_cast", {:player_enter, ^other_cid, enter_location}}, 300
    assert enter_location == {100.0, 0.0, 0.0}

    GenServer.cast(mover, {:self_move, {900.0, 0.0, 0.0}})

    wait_until(fn ->
      state = :sys.get_state(mover)
      state.location == {900.0, 0.0, 0.0}
    end)

    send(mover, :get_aoi_tick)
    assert_receive {:"$gen_cast", {:player_leave, ^other_cid}}, 300
  end

  defp add_aoi_item(cid, location, connection_pid) do
    {:ok, pid} = AoiManager.add_aoi_item(cid, 0, location, connection_pid, self())

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

  defp connection_loop do
    receive do
      _ -> connection_loop()
    end
  end

  defp unique_cid do
    System.unique_integer([:positive])
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
