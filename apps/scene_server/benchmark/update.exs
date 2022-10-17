make_inputs = fn input ->
  {:ok, system1} = SceneServer.Native.CoordinateSystem.new_system(1000, 100)
  cid = 0
  xpos = 50000.0
  ypos = 50000.0
  zpos = 50000.0
  {:ok, item1} = SceneServer.Native.CoordinateSystem.add_item_to_system(system1, cid, {xpos, ypos, zpos})

  for idx <- 1..100_000 do
    cid = idx
    xpos = Enum.random(0..100_000) / 100_000.0
    ypos = Enum.random(0..100_000) / 100_000.0
    zpos = Enum.random(0..100_000) / 100_000.0
    SceneServer.Native.CoordinateSystem.add_item_to_system(system1, cid, {xpos, ypos, zpos})
  end

  {:ok, system2} = SceneServer.Native.CoordinateSystem.new_system(100, 100)
  cid = 0
  xpos = 5000.0
  ypos = 5000.0
  zpos = 5000.0
  {:ok, item2} = SceneServer.Native.CoordinateSystem.add_item_to_system(system2, cid, {xpos, ypos, zpos})

  for idx <- 1..10_000 do
    cid = idx
    xpos = Enum.random(0..10_000) / 10_000.0
    ypos = Enum.random(0..10_000) / 10_000.0
    zpos = Enum.random(0..10_000) / 10_000.0
    SceneServer.Native.CoordinateSystem.add_item_to_system(system2, cid, {xpos, ypos, zpos})
  end

  {:ok, system3} = SceneServer.Native.CoordinateSystem.new_system(100, 50)
  cid = 0
  xpos = 2500.0
  ypos = 2500.0
  zpos = 2500.0
  {:ok, item3} = SceneServer.Native.CoordinateSystem.add_item_to_system(system3, cid, {xpos, ypos, zpos})

  for idx <- 1..5_000 do
    cid = idx
    xpos = Enum.random(0..5_000) / 5_000.0
    ypos = Enum.random(0..5_000) / 5_000.0
    zpos = Enum.random(0..5_000) / 5_000.0
    SceneServer.Native.CoordinateSystem.add_item_to_system(system3, cid, {xpos, ypos, zpos})
  end

  input
  |> Map.put("large", {system1, item1, 100_000})
  |> Map.put("medium", {system2, item2, 10_000})
  |> Map.put("small", {system3, item3, 5_000})
end

update_item = fn {system, item, size} ->
  # IO.inspect("Inputs: ")
  # IO.inspect(item, pretty: true)
  # system = inputs[:system]
  # item = inputs[:item]
  xpos = Enum.random(0..size) / size
  ypos = Enum.random(0..size) / size
  zpos = Enum.random(0..size) / size
  SceneServer.Native.CoordinateSystem.update_item_from_system(system, item, {xpos, ypos, zpos})
end

Benchee.run(
  %{
    "update_item" => update_item,
  },
  inputs: %{}
    |> make_inputs.()
)
