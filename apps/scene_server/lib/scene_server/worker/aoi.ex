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
    # {:ok, item} = SceneServer.Native.SortedSet.new_item(123, self(), {1.0, 2.0, 3.0})
    # {:ok, bucket} = SceneServer.Native.SortedSet.new_bucket()
    {:ok, set} = SceneServer.Native.SortedSet.new_set(10000, 4)
    Logger.debug("Set ref: #{inspect(set, pretty: true)}")
    # # item = SceneServer.Native.SortedSet.add(1, 2)
    # Logger.debug("Bucket ref: #{inspect(bucket, pretty: true)}")
    # bk1 = SceneServer.Native.SortedSet.get_bucket_raw(bucket)
    # Logger.debug("Bucket raw: #{inspect(bk1, pretty: true)}")
    # # {:ok, item_raw} = SceneServer.Native.SortedSet.get_item_raw(item)
    # SceneServer.Native.SortedSet.add_item_to_bucket(bucket, 3, {1.0, 2.0, 7.0})
    # SceneServer.Native.SortedSet.add_item_to_bucket(bucket, 1, {1.0, 2.0, 3.0})
    # SceneServer.Native.SortedSet.add_item_to_bucket(bucket, 2, {1.0, 2.0, 5.0})
    # SceneServer.Native.SortedSet.add_item_to_bucket(bucket, 5, {1.0, 2.0, 11.0})
    # SceneServer.Native.SortedSet.add_item_to_bucket(bucket, 4, {1.0, 2.0, 9.0})
    # # Logger.debug("Bucket add item result: #{inspect(result, pretty: true)}")

    SceneServer.Native.SortedSet.add_item_to_set(set, 1, {1.0, 2.0, 7.0})
    SceneServer.Native.SortedSet.add_item_to_set(set, 2, {1.0, 2.0, 3.0})
    SceneServer.Native.SortedSet.add_item_to_set(set, 3, {1.0, 2.0, 5.0})
    SceneServer.Native.SortedSet.add_item_to_set(set, 4, {1.0, 2.0, 11.0})
    SceneServer.Native.SortedSet.add_item_to_set(set, 5, {1.0, 2.0, 9.0})
    SceneServer.Native.SortedSet.add_item_to_set(set, 6, {1.0, 2.0, 8.0})
    SceneServer.Native.SortedSet.add_item_to_set(set, 7, {1.0, 2.0, 6.0})

    # # bk2 = SceneServer.Native.SortedSet.get_bucket_raw(bucket)
    # # Logger.debug("Bucket raw: #{inspect(bk2, pretty: true)}")

    # SceneServer.Native.SortedSet.add_item_to_bucket(bucket, 6, {1.0, 2.0, 8.0})
    # SceneServer.Native.SortedSet.add_item_to_bucket(bucket, 7, {1.0, 2.0, 6.0})
    # SceneServer.Native.SortedSet.add_item_to_bucket(bucket, 8, {1.0, 2.0, 2.0})
    # bk3 = SceneServer.Native.SortedSet.get_bucket_raw(bucket)
    # Logger.debug("Bucket raw: #{inspect(bk3, pretty: true)}")
    ss = SceneServer.Native.SortedSet.get_set_raw(set)
    Logger.debug("Bucket raw: #{inspect(ss, pretty: true)}")
    # TODO: Create SortedSet

    {nil, nil, nil}
  end
end
