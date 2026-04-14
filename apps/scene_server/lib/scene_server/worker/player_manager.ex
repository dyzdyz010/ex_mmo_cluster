defmodule SceneServer.PlayerManager do
  @moduledoc """
  Registry/entrypoint for active player actors.

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
    with {:ok, player_pid} <-
           DynamicSupervisor.start_child(
             SceneServer.PlayerCharacterSup,
             {SceneServer.PlayerCharacter,
              {cid, connection_pid, client_timestamp, character_profile}}
           ),
         :ok <- await_player_ready(player_pid) do
      new_players = players |> Map.put_new(cid, player_pid)

      {:reply, {:ok, player_pid}, %{state | players: new_players}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_player_index, cid}, _from, %{players: players} = state) do
    new_players = players |> Map.delete(cid)
    {:reply, {:ok, ""}, %{state | players: new_players}}
  end

  @impl true
  def handle_call(:get_all_players, _from, %{players: players} = state) do
    {:reply, {:ok, players}, state}
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
