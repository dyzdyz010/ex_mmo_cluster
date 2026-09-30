Code.require_file("../support/movement_fixture.exs", __DIR__)

defmodule WorldServer.TopologyTest do
  @moduledoc "只测试：拓扑文件在本节点启动两个 Scene（一个经本地 Replica、一个直连 World），写路由并连接相邻 Scene。"
  use ExUnit.Case, async: false
  alias SceneServer.Movement.Scene

  setup do
    base = WorldServer.MovementFixture.prepare()

    for {id, name} <- [voxel: VoxelRegion.Supervisor, scene: SceneServer.Supervisor] do
      start_supervised!(%{
        id: id,
        type: :supervisor,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one, name: name]]}
      })
    end

    start_supervised!(
      {VoxelRegion.World,
       [
         name: VoxelRegion.World,
         source: VoxelRegion.GeneratedStore,
         root: base <> "/world",
         manifest_path: base <> "/Voxim/Docs/R6/runtime/s4_worldgen_manifest.json"
       ]}
    )

    previous = Application.get_env(:world_server, :movement_routes)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:world_server, :movement_routes, previous),
        else: Application.delete_env(:world_server, :movement_routes)
    end)

    {:ok, base: base}
  end

  @tag timeout: 120_000
  test "topology file starts both Scenes, routes them to the World and aligns their timelines", %{
    base: base
  } do
    raw = File.read!(base <> "/Voxim/Docs/M1/fixtures/demo-config.json") |> Jason.decode!()

    # 两个 Scene 在 X = 41 m 分界，各自一个出生点（同 M4a 移交用例）。
    configs =
      for id <- 1..2 do
        bound = if id == 1, do: "travel_max_exclusive_m", else: "travel_min_m"

        config =
          raw
          |> Map.put("spawn_probes_m", [Enum.at(raw["spawn_probes_m"], id - 1)])
          |> Map.update!(bound, fn [_, y, z] -> [41, y, z] end)

        path = Path.join(base, "scene-#{id}.json")
        File.write!(path, Jason.encode!(config))
        path
      end

    report = Path.join(base, "topology-state.json")
    path = Path.join(base, "topology.json")

    File.write!(
      path,
      Jason.encode!(%{
        scenes: [
          %{scene_id: 1, config: Enum.at(configs, 0), node: "local", replica: true},
          %{scene_id: 2, config: Enum.at(configs, 1), node: "local"}
        ],
        neighbours: [[1, 2]],
        report: report
      })
    )

    start_supervised!({WorldServer.Topology, path})
    world = Process.whereis(VoxelRegion.World)

    assert Application.fetch_env!(:world_server, :movement_routes) == %{
             1 => %{scene_ref: {Scene, node()}, world_ref: world, scene_epoch: 1},
             2 => %{scene_ref: {:voxim_scene2, node()}, world_ref: world, scene_epoch: 1}
           }

    {:ok, a} = Scene.neighbour_endpoint({Scene, node()})
    {:ok, b} = Scene.neighbour_endpoint({:voxim_scene2, node()})
    assert a.origin_us == b.origin_us

    # Scene 1 消费本地 Replica：它的权威上游是同一个 World。
    assert [{_, replica, _, [VoxelRegion.Replica]}] =
             Supervisor.which_children(VoxelRegion.Supervisor)

    assert VoxelRegion.Replica.authority_ref(replica) == world

    assert %{"scenes" => [%{"scene_id" => 1}, %{"scene_id" => 2}]} =
             report |> File.read!() |> Jason.decode!()
  end
end
