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
    {:ok, %{x: nil, y: nil, z: nil}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("Aoi process created.")
    {xlist, ylist, zlist} = create_lists()
    {:noreply, %{state | x: xlist, y: ylist, z: zlist}}
  end

  # Internal functions

  defp create_lists() do
    # {:ok, item} = SceneServer.Native.CoordinateSystem.new_item(123, self(), {1.0, 2.0, 3.0})
    # {:ok, bucket} = SceneServer.Native.CoordinateSystem.new_bucket()
    # {:ok, set} = SceneServer.Native.CoordinateSystem.new_set(10000, 4)
    # Logger.debug("Set ref: #{inspect(set, pretty: true)}")

    {:ok, system} = SceneServer.Native.CoordinateSystem.new_system(10000, 4)
    Logger.debug("Set ref: #{inspect(system, pretty: true)}")

    # # item = SceneServer.Native.CoordinateSystem.add(1, 2)
    # Logger.debug("Bucket ref: #{inspect(bucket, pretty: true)}")
    # bk1 = SceneServer.Native.CoordinateSystem.get_bucket_raw(bucket)
    # Logger.debug("Bucket raw: #{inspect(bk1, pretty: true)}")
    # # {:ok, item_raw} = SceneServer.Native.CoordinateSystem.get_item_raw(item)
    # SceneServer.Native.CoordinateSystem.add_item_to_bucket(bucket, 3, {1.0, 2.0, 7.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_bucket(bucket, 1, {1.0, 2.0, 3.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_bucket(bucket, 2, {1.0, 2.0, 5.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_bucket(bucket, 5, {1.0, 2.0, 11.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_bucket(bucket, 4, {1.0, 2.0, 9.0})
    # # Logger.debug("Bucket add item result: #{inspect(result, pretty: true)}")

    # SceneServer.Native.CoordinateSystem.add_item_to_set(set, 1, {1.0, 2.0, 7.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_set(set, 2, {1.0, 2.0, 3.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_set(set, 3, {1.0, 2.0, 5.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_set(set, 4, {1.0, 2.0, 11.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_set(set, 5, {1.0, 2.0, 9.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_set(set, 6, {1.0, 2.0, 8.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_set(set, 7, {1.0, 2.0, 6.0})

    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 1, {50.0, 15.0, 7.0})
    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 2, {79.0, 41.0, 3.0})
    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 3, {66.0, 33.0, 5.0})
    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 4, {32.0, 99.0, 11.0})
    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 5, {35.0, 77.0, 9.0})
    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 6, {11.0, 1.0, 8.0})
    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 7, {6.0, 90.0, 65.0})
    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 5, {67.0, 75.0, 1.0})
    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 6, {99.0, 55.0, 23.0})
    SceneServer.Native.CoordinateSystem.add_item_to_system(system, 7, {80.0, 32.0, 44.0})

    # # bk2 = SceneServer.Native.CoordinateSystem.get_bucket_raw(bucket)
    # # Logger.debug("Bucket raw: #{inspect(bk2, pretty: true)}")

    # SceneServer.Native.CoordinateSystem.add_item_to_bucket(bucket, 6, {1.0, 2.0, 8.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_bucket(bucket, 7, {1.0, 2.0, 6.0})
    # SceneServer.Native.CoordinateSystem.add_item_to_bucket(bucket, 8, {1.0, 2.0, 2.0})

    # bk3 = SceneServer.Native.CoordinateSystem.get_bucket_raw(bucket)
    # Logger.debug("Bucket raw: #{inspect(bk3, pretty: true)}")

    # s1 = SceneServer.Native.CoordinateSystem.get_set_raw(set)
    # Logger.debug("Bucket raw: #{inspect(s1, pretty: true)}")

    cs = SceneServer.Native.CoordinateSystem.get_system_raw(system)
    Logger.debug("Bucket raw: #{inspect(cs, pretty: true)}")
    # TODO: Create CoordinateSystem

    {nil, nil, nil}
  end
end
