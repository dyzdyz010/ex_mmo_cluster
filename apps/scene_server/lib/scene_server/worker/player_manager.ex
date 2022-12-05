defmodule SceneServer.PlayerManager do
  use GenServer

  require Logger

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
  def handle_call({:add_player, cid, connection_pid, client_timestamp}, _from, %{players: players} = state) do
    {:ok, player_pid} =
      DynamicSupervisor.start_child(
        SceneServer.PlayerCharacterSup,
        {SceneServer.PlayerCharacter, {cid, connection_pid, client_timestamp}}
      )

    new_players = players |> Map.put_new(cid, player_pid)

    {:reply, {:ok, player_pid}, %{state | players: new_players}}
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
end
