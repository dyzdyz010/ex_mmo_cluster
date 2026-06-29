# Dev probe: heat the VoxiaGlow row blocks to white-hot via the scene field helper.
node = :"dev@DYZ-BAK"
true = Node.connect(node)

# Row placed on surface -153,135,-60 → blocks sit at Y = 136, X = -153,-151,-149,-147, Z = -60.
results =
  for x <- [-153, -151, -149, -147] do
    :rpc.call(node, SceneServer.Voxel.Field.DevFieldCreate, :set_temperature, [
      [
        world_macro: {x, 136, -60},
        target_temperature_celsius: 1700,
        logical_scene_id: 1,
        radius: 2,
        max_ticks: 600
      ]
    ])
  end

ok = Enum.count(results, &match?({:ok, _}, &1))
IO.puts("set_temperature: #{ok}/#{length(results)} ok")
