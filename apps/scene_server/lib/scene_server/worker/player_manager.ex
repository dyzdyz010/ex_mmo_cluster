defmodule SceneServer.PlayerManager do
  @moduledoc """
  Registry/entrypoint for active player actors.

  Reconnects for the same CID replace the old actor before publishing the new
  PID, and terminate cleanup is PID-guarded so stale actors cannot delete a
  newer session index.

  `PlayerManager` mirrors `Npc.Manager` on the player side: it starts one
  `PlayerCharacter` per active character and keeps the CID → PID index used by
  the gate stdio interface and scene-side targeting helpers.
  """

  use GenServer

  require Logger

  @player_ready_attempts 40
  @player_ready_sleep_ms 25

  @doc "Starts the active player registry."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{players: %{}}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(
        {:add_player, cid, connection_pid, client_timestamp, character_profile},
        _from,
        %{players: players} = state
      ) do
    {stale_player_pid, players} = Map.pop(players, cid)
    stop_stale_player(cid, stale_player_pid)

    with {:ok, player_pid} <-
           DynamicSupervisor.start_child(
             SceneServer.PlayerCharacterSup,
             {SceneServer.PlayerCharacter,
              {cid, connection_pid, client_timestamp, character_profile}}
           ),
         :ok <- await_player_ready(player_pid) do
      new_players = Map.put(players, cid, player_pid)

      if is_pid(stale_player_pid) do
        SceneServer.CliObserve.emit("player_index_replaced", %{
          cid: cid,
          old_pid: inspect(stale_player_pid),
          new_pid: inspect(player_pid)
        })
      end

      {:reply, {:ok, player_pid}, %{state | players: new_players}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, %{state | players: players}}
    end
  end

  @impl true
  def handle_call({:remove_player_index, cid}, _from, %{players: players} = state) do
    new_players = players |> Map.delete(cid)
    {:reply, {:ok, ""}, %{state | players: new_players}}
  end

  @impl true
  def handle_call({:remove_player_index, cid, player_pid}, _from, %{players: players} = state) do
    {:reply, {:ok, ""}, %{state | players: remove_player_if_current(players, cid, player_pid)}}
  end

  @impl true
  def handle_call(:get_all_players, _from, %{players: players} = state) do
    {:reply, {:ok, players}, state}
  end

  @impl true
  def handle_cast({:remove_player_index, cid}, %{players: players} = state) do
    {:noreply, %{state | players: Map.delete(players, cid)}}
  end

  @impl true
  def handle_cast({:remove_player_index, cid, player_pid}, %{players: players} = state) do
    {:noreply, %{state | players: remove_player_if_current(players, cid, player_pid)}}
  end

  defp stop_stale_player(_cid, nil), do: :ok

  defp stop_stale_player(cid, player_pid) when is_pid(player_pid) do
    SceneServer.CliObserve.emit("player_index_replace_requested", %{
      cid: cid,
      old_pid: inspect(player_pid)
    })

    GenServer.stop(player_pid, :normal, 2_000)
  catch
    :exit, reason ->
      Logger.debug(
        "Ignoring stale player stop failure for cid=#{inspect(cid)}: #{inspect(reason)}"
      )

      :ok
  end

  defp remove_player_if_current(players, cid, player_pid) do
    case Map.get(players, cid) do
      ^player_pid ->
        Map.delete(players, cid)

      current_pid ->
        SceneServer.CliObserve.emit("player_index_remove_ignored", %{
          cid: cid,
          stale_pid: inspect(player_pid),
          current_pid: inspect(current_pid)
        })

        players
    end
  end

  defp await_player_ready(player_pid, attempts \\ @player_ready_attempts)

  defp await_player_ready(_player_pid, 0), do: {:error, :player_not_ready}

  defp await_player_ready(player_pid, attempts) do
    try do
      case GenServer.call(player_pid, :await_ready) do
        :ok ->
          :ok

        {:error, :not_ready} ->
          Process.sleep(@player_ready_sleep_ms)
          await_player_ready(player_pid, attempts - 1)

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end
end
