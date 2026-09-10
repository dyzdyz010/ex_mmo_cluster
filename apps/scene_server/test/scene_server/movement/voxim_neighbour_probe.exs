defmodule SceneServer.Movement.VoximNeighbourNodesProbe do
  @moduledoc false
  alias SceneServer.Movement.Scene

  def boot(base, id, world \\ nil) do
    # 独立实验 World：真实 GeneratedStore/P1，磁盘日志不使用在线 DB。
    config = File.read!(base <> "/Voxim/Docs/M1/fixtures/demo-config.json") |> Jason.decode!()
    config = config
      |> Map.put("spawn_probes_m", [Enum.at(config["spawn_probes_m"], id - 1)])
      |> Map.update!(if(id == 1, do: "travel_max_exclusive_m", else: "travel_min_m"),
        fn [_, y, z] -> [41, y, z] end)
    # 共享源探针让 B 多取一列冷 region，不能靠 A 已生成的磁盘缓存掩盖跨节点调用。
    config = if world, do: Map.put(config, "l0_max_exclusive", [2, 9, 1]), else: config
    source = if world, do: [], else: [
      {VoxelRegion.World, [name: VoxelRegion.World, source: VoxelRegion.GeneratedStore,
        root: base <> "/world-#{id}", manifest_path: base <> "/Voxim/Docs/R6/runtime/s4_worldgen_manifest.json"]}
    ]
    children = source ++ [
      {Scene, [name: Scene, scene_id: id, scene_epoch: 1,
        world_ref: world || VoxelRegion.World, config: config]}
    ]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(sup)
    %{node: node(), os_pid: System.pid(), supervisor: sup, scene: Process.whereis(Scene),
      world: world || Process.whereis(VoxelRegion.World), config: config}
  end
end

