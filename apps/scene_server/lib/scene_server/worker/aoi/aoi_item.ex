defmodule SceneServer.Aoi.AoiItem do
  use GenServer

  require Logger

  alias SceneServer.Native.CoordinateSystem

  @tick_interval 1000

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @impl true
  def init({cid, location, cpid, system}) do
    {:ok, item_ref} = add_item(cid, location, system)
    timer = make_timer()

    {:ok,
     %{
       cid: cid,
       character_pid: cpid,
       system_ref: system,
       item_ref: item_ref,
       subscribers: [],
       interest_radius: 500,
       timer: timer
     }}
  end

  defp add_item(cid, location, system) do
    {:ok, item_ref} = CoordinateSystem.add_item_to_system(system, cid, location)

    {:ok, item_ref}
  end

  @impl true
  def handle_call(:exit, _from, state) do
    {:stop, :normal, {:ok, ""}, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Logger.debug("AOI tick.")
    {:noreply, %{state | timer: make_timer()}}
  end

  @impl true
  def terminate(reason, %{cid: cid, system_ref: system, item_ref: item, timer: timer}) do
    {:ok, _} = CoordinateSystem.remove_item_from_system(system, item)
    Logger.debug("AOI item removed.")
    {:ok, _} = GenServer.call(SceneServer.PlayerManager, {:remove_player_index, cid})
    Logger.debug("Player index removed.")
    Process.cancel_timer(timer)
    Logger.debug("Timer stopped.")
    Logger.warn("Process exited. Reason: #{inspect(reason, pretty: true)}")
  end

  defp make_timer() do
    Process.send_after(self(), :tick, @tick_interval)
  end
end
