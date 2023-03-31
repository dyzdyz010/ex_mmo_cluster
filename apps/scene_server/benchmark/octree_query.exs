make_inputs = fn input ->
  tree = SceneServer.Native.Octree.new_tree({0.0, 0.0, 0.0}, {1000.0, 1000.0, 1000.0})

  input
  |> Map.put("large", {tree, 1_000_000})
end


Benchee.run(
  %{
    "add_item" => fn {tree, _size} ->
      cid = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
      x = Enum.random(-100000..100000) / 100
      y = Enum.random(-100000..100000) / 100
      z = Enum.random(-100000..100000) / 100
      # GenServer.call(SceneServer.Aoi, {:add_player, cid, {x, y, z}})
      # SceneServer.Native.CoordinateSystem.add_item_to_system(tree, cid, {x, y, z})
      item = SceneServer.Native.Octree.new_item(cid, {x, y, z})
      require Logger
      # Logger.debug("#{inspect(item)}")
      SceneServer.Native.Octree.add_item(tree, item)
      []
    end
  },
  inputs: %{}
  |> make_inputs.(),
  parallel: 8
)
