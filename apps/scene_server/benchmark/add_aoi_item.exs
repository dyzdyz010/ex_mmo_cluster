make_inputs = fn input ->
  {:ok, system1} = SceneServer.Native.CoordinateSystem.new_system(1000, 100)

  input
  |> Map.put("large", {system1, 100_000})
end


Benchee.run(
  %{
    "add_item" => fn {system, _size} ->
      cid = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
      x = Enum.random(0..100000) / 100000
      y = Enum.random(0..100000) / 100000
      z = Enum.random(0..100000) / 100000
      # GenServer.call(SceneServer.Aoi, {:add_player, cid, {x, y, z}})
      SceneServer.Native.CoordinateSystem.add_item_to_system(system, cid, {x, y, z})
      []
    end
  },
  inputs: %{}
  |> make_inputs.(),
  parallel: 4
)
