defmodule SceneServer.Aoi do
  use GenServer

  require Logger

  # APIs

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  def add_player({:player, _player}) do
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{coordinate_system: nil}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("Aoi process created.")
    system = create_system()
    {:noreply, %{state | coordinate_system: system}}
  end

  # Internal functions

  @spec create_system() :: SceneServer.Native.CoordinateSystem.Types.coordinate_system()
  defp create_system() do
    # {:ok, item} = SceneServer.Native.CoordinateSystem.new_item(123, self(), {1.0, 2.0, 3.0})
    # {:ok, bucket} = SceneServer.Native.CoordinateSystem.new_bucket()
    # {:ok, set} = SceneServer.Native.CoordinateSystem.new_set(10000, 4)
    # Logger.debug("Set ref: #{inspect(set, pretty: true)}")

    {:ok, system} = SceneServer.Native.CoordinateSystem.new_system(10000, 5)

    system
  end
end
