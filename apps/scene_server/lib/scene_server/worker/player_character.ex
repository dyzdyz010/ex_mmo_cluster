defmodule SceneServer.PlayerCharacter do
  use GenServer, restart: :temporary

  require Logger

  alias SceneServer.Aoi

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @impl true
  def init({cid, pid}) do
    # :pg.start_link(@scope)
    # :pg.join(@scope, @topic, self())
    {:ok, aoi_ref} = enter_scene(cid, {1000.0, 1000.0, 1000.0})
    Logger.debug("New player created.")
    {:ok, %{cid: cid, pid: pid, aoi_ref: aoi_ref, character_info: %{nickname: "Demo Player"}, status: :in_scene}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:exit, _from, state) do
    {:stop, :normal, {:ok, ""}, state}
  end

  @impl true
  def terminate(reason, %{aoi_ref: aoi_item, cid: cid}) do
    {:ok, _} = Aoi.remove_player(aoi_item)
    Logger.debug("AOI item removed.")
    {:ok, _} = GenServer.call(SceneServer.PlayerManager, {:remove_player_index, cid})
    Logger.debug("Player index removed.")
    Logger.warn("Process exited. Reason: #{inspect(reason, pretty: true)}")
  end

  defp enter_scene(cid, position) do
    {:ok, aoi_ref} = Aoi.add_player(cid, position)
    Logger.debug("Character added to Coordinate System: #{inspect(aoi_ref, pretty: true)}")

    {:ok, aoi_ref}
  end
end
