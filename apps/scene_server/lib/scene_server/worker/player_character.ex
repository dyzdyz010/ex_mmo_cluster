defmodule SceneServer.PlayerCharacter do
  use GenServer, restart: :temporary

  require Logger

  alias SceneServer.AoiManager

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @impl true
  def init({cid, pid}) do
    # :pg.start_link(@scope)
    # :pg.join(@scope, @topic, self())
    Logger.debug("New player created.")

    {:ok,
     %{
       cid: cid,
       pid: pid,
       aoi_ref: nil,
       character_info: %{nickname: "Demo Player"},
       status: :in_scene,
       old_timestamp: nil,
       net_delay: 0
     }, 0}
  end

  @impl true
  def handle_info(:timeout, %{cid: cid} = state) do
    {:ok, aoi_ref} = enter_scene(cid, {1000.0, 1000.0, 1000.0})
    {:noreply, %{state | aoi_ref: aoi_ref}}
  end

  @impl true
  def handle_call(:exit, _from, state) do
    {:stop, :normal, {:ok, ""}, state}
  end

  @impl true
  def handle_call(
        {:time_sync, _},
        _from,
        %{old_timestamp: old_timestamp, net_delay: old_delay} = state
      ) do
    new_timestamp = :os.system_time(:millisecond)

    new_state =
      case old_timestamp do
        nil ->
          %{state | old_timestamp: new_timestamp}

        _ ->
          Logger.debug("CS延迟: #{(new_timestamp - old_timestamp) / 2}")

          new_delay =
            if old_delay != 0 do
              ((new_timestamp - old_timestamp) / 2 + old_delay) / 2
            else
              (new_timestamp - old_timestamp) / 2
            end

          %{state | old_timestamp: nil, net_delay: new_delay}
      end

    {:reply, {:ok, new_timestamp}, new_state}
  end

  @impl true
  def terminate(reason, %{aoi_ref: aoi_item, cid: cid}) do
    {:ok, _} = AoiManager.remove_aoi_item(aoi_item)
    Logger.debug("AOI item removed.")
    {:ok, _} = GenServer.call(SceneServer.PlayerManager, {:remove_player_index, cid})
    Logger.debug("Player index removed.")
    Logger.warn("Process exited. Reason: #{inspect(reason, pretty: true)}")
  end

  defp enter_scene(cid, position) do
    {:ok, aoi_ref} = AoiManager.add_aoi_item(cid, position, self())
    Logger.debug("Character added to Coordinate System: #{inspect(aoi_ref, pretty: true)}")

    {:ok, aoi_ref}
  end
end
