defmodule SceneServer.Aoi.AoiItem do
  use GenServer, restart: :transient

  require Logger

  alias SceneServer.Native.CoordinateSystem

  @tick_interval 1000

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @impl true
  def init({cid, location, cpid, system}) do
    timer = make_timer()

    {:ok,
     %{
       cid: cid,
       character_pid: cpid,
       system_ref: system,
       item_ref: nil,
       subscribers: [],
       interest_radius: 500,
       timer: timer
     }, {:continue, {:load, location}}}
  end

  @impl true
  def handle_continue({:load, location}, %{cid: cid, system_ref: system} = state) do
    {:ok, item_ref} = add_item(cid, location, system)
    Logger.debug("Item added to the system.")

    {:noreply, %{state | item_ref: item_ref}}
  end

  @impl true
  def handle_cast({:movement, location, _velocity}, %{system_ref: system, item_ref: item} = state) do
    {:ok, _} = CoordinateSystem.update_item_from_system(system, item, location)

    {:noreply, state}
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
  def handle_info(:tick, %{system_ref: _system, item_ref: item} = state) do
    item_raw = CoordinateSystem.get_item_raw(item)
    Logger.debug("AOI tick. #{inspect(item_raw, pretty: true)}", ansi_color: :yellow)
    {:noreply, %{state | timer: make_timer()}}
    # {:noreply, state}
  end

  @impl true
  def terminate(reason, %{cid: cid, system_ref: system, item_ref: item, timer: timer}) do
    {:ok, _} = CoordinateSystem.remove_item_from_system(system, item)
    Logger.debug("AOI system item removed.")
    {:ok, _} = GenServer.call(SceneServer.AoiManager, {:remove_aoi_item, cid})
    Logger.debug("Aoi index removed.")
    result = Process.cancel_timer(timer)
    Logger.debug("Time cancelation result: #{inspect(result, pretty: true)}")
    Logger.debug("Timer stopped.")
    Logger.warn("AoiItem process #{inspect(self(), pretty: true)} exited successfully. Reason: #{inspect(reason, pretty: true)}", ansi_color: :green)
  end

  defp add_item(cid, location, system) do
    {:ok, item_ref} = CoordinateSystem.add_item_to_system(system, cid, location)

    {:ok, item_ref}
  end

  defp make_timer() do
    Process.send_after(self(), :tick, @tick_interval)
  end
end
