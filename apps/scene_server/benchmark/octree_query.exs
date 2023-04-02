make_inputs = fn input ->
  tree = SceneServer.Native.Octree.new_tree({0.0, 0.0, 0.0}, {5_000.0, 5_000.0, 5_000.0})

  for idx <- 1..10_000 do
    cid = idx
    xpos = Enum.random(-1_000..1_000) * 1.0
    ypos = Enum.random(-1_000..1_000) * 1.0
    zpos = Enum.random(-1_000..1_000) * 1.0
    item = SceneServer.Native.Octree.new_item(cid, {xpos, ypos, zpos})
    SceneServer.Native.Octree.add_item(tree, item)
  end

  input
  |> Map.put("large", {tree, 100_000})
end

query_items = fn {tree, _size} ->
  cx = Enum.random(-400..400) * 1.0
  cy = Enum.random(-400..400) * 1.0
  cz = Enum.random(-400..400) * 1.0
  sx = Enum.random(50..100) * 1.0
  sy = Enum.random(50..100) * 1.0
  sz = Enum.random(50..100) * 1.0
  SceneServer.Native.Octree.get_in_bound(tree, {cx, cy, cz}, {sx, sy, sz})
end

Benchee.run(
  %{
    "query_items" => query_items,
  },
  inputs: %{}
  |> make_inputs.(),
  parallel: 8
)
