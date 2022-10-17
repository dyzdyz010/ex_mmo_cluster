{:ok, system_insert} = SceneServer.Native.CoordinateSystem.new_system(5000, 100)

Benchee.run(%{
  "add_item" => fn ->
    cid = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
    xpos = Enum.random(0..100000) / 100000
    ypos = Enum.random(0..100000) / 100000
    zpos = Enum.random(0..100000) / 100000
    SceneServer.Native.CoordinateSystem.add_item_to_system(system_empty, cid, {xpos, ypos, zpos})
    []
  end,
})
