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
  def handle_call({:add_player, cid, pid}, _from, %{players: players} = state) do
    {:ok, ppid} =
      DynamicSupervisor.start_child(
        SceneServer.PlayerCharacterSup,
        {SceneServer.PlayerCharacter, {cid, pid}}
      )

    new_players = players |> Map.put_new(cid, ppid)

    {:reply, {:ok, ppid}, %{state | players: new_players}}
  end

  @impl true
  def handle_call({:remove_player_index, cid}, _from, %{players: players} = state) do
    new_players = players |> Map.delete(cid)
    {:reply, {:ok, ""}, %{state | players: new_players}}
  end
end
