defmodule SceneServer.PlayerManagerTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 10_000

  setup do
    ensure_started(SceneServer.PhysicsManager, {SceneServer.PhysicsSup, name: PhysicsSupTest})
    ensure_started(SceneServer.AoiManager, {SceneServer.AoiSup, name: AoiSupTest})
    ensure_started(SceneServer.PlayerManager, {SceneServer.PlayerSup, name: PlayerSupTest})

    :ok
  end

  test "add_player refreshes a stale native physics reference before entering scene" do
    :sys.replace_state(SceneServer.PhysicsManager, fn _state ->
      %{physys_ref: make_ref()}
    end)

    cid = System.unique_integer([:positive])
    profile = %{name: "native-refresh-#{cid}", position: {750.0, 750.0, 185.0}}

    assert {:ok, player_pid} =
             GenServer.call(
               SceneServer.PlayerManager,
               {:add_player, cid, self(), :os.system_time(:millisecond), profile},
               8_000
             )

    assert :ok = GenServer.call(player_pid, :await_ready)

    assert {:ok, players} = GenServer.call(SceneServer.PlayerManager, :get_all_players)
    assert players[cid] == player_pid

    on_exit(fn ->
      if Process.alive?(player_pid) do
        try do
          GenServer.call(player_pid, :exit, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  test "add_player replaces an existing cid actor and ignores stale cleanup" do
    cid = System.unique_integer([:positive])
    profile = %{name: "replace-#{cid}", position: {750.0, 750.0, 185.0}}

    assert {:ok, first_pid} =
             GenServer.call(
               SceneServer.PlayerManager,
               {:add_player, cid, self(), :os.system_time(:millisecond), profile},
               8_000
             )

    first_ref = Process.monitor(first_pid)

    assert {:ok, second_pid} =
             GenServer.call(
               SceneServer.PlayerManager,
               {:add_player, cid, self(), :os.system_time(:millisecond), profile},
               8_000
             )

    assert first_pid != second_pid
    assert_receive {:DOWN, ^first_ref, :process, ^first_pid, :normal}, 2_000

    GenServer.cast(SceneServer.PlayerManager, {:remove_player_index, cid, first_pid})
    _ = :sys.get_state(SceneServer.PlayerManager)

    assert {:ok, players} = GenServer.call(SceneServer.PlayerManager, :get_all_players)
    assert players[cid] == second_pid

    on_exit(fn ->
      try do
        GenServer.call(second_pid, :exit, 2_000)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp ensure_started(name_to_check, spec) do
    case Process.whereis(name_to_check) do
      nil ->
        case start_supervised(spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end
end
