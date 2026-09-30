defmodule WorldServer.Topology do
  @moduledoc """
  全局系统功能：按拓扑文件启动 Voxim 的 Scene，并登记路由、连接相邻 Scene。

  World（`VoxelRegion.World`）与 Auth / Gate 由本节点唯一拥有；每个 Scene 的节点、配置和是否消费本地只读
  Replica 写在拓扑文件里（`VOXIM_TOPOLOGY`）：

      {"scenes": [
         {"scene_id": 1, "config": "/srv/voxim/m4a/scene-1.json", "node": "local", "replica": true},
         {"scene_id": 2, "config": "/srv/voxim/m4a/scene-2.json", "node": "peer", "schedulers": "1:1"}],
       "neighbours": [[1, 2]],
       "report": "/srv/voxim/m4a/topology.json"}

  `node: "local"` 的 Scene 与 World 同节点（第一个用进程名 `SceneServer.Movement.Scene`，其余按 scene_id 命名）；
  `"peer"` 用 `:peer` 在本机另起一个 BEAM 节点，只运行该 Scene 及其 Replica，World 仍在本节点。peer 节点随本进程退出。启动在 `init/1` 里阻塞完成，所以 world_server 应用
  （以及依赖它的 Auth / Gate）在全部 Scene 就绪、路由写好之后才启动完毕。
  """

  use GenServer
  require Logger

  alias SceneServer.Movement.Scene
  alias VoxelRegion.Replica

  @ready_attempts 3000

  def start_link(path), do: GenServer.start_link(__MODULE__, path, name: __MODULE__)

  @impl true
  def init(path) do
    topology = path |> File.read!() |> Jason.decode!()
    world = Process.whereis(VoxelRegion.World) || raise "VoxelRegion.World is not running"
    {local, peers} = Enum.split_with(topology["scenes"], &(&1["node"] == "local"))

    # 所有 Scene 共用第一个 Scene 的时间线原点（跨 Scene 移交比较 origin_us）。
    {started, origin_us} =
      Enum.reduce(Enum.with_index(local), {[], nil}, fn {scene, index}, {acc, origin_us} ->
        {id, route, info} = start_local(scene, world, index, origin_us)
        {acc ++ [{id, route, info}], origin_us || ready!(route.scene_ref).origin_us}
      end)

    started = started ++ Enum.map(peers, &start_peer(&1, world, origin_us))

    routes = Map.new(started, fn {id, route, _} -> {id, route} end)
    Application.put_env(:world_server, :movement_routes, routes)
    Enum.each(routes, fn {_, route} -> ready!(route.scene_ref) end)

    for [a, b] <- Map.get(topology, "neighbours", []),
        do: :ok = WorldServer.Movement.connect_neighbours(a, b)

    report =
      Enum.map(started, fn {id, route, info} ->
        info |> Map.delete(:peer) |> Map.merge(%{scene_id: id, node: node_of(route)})
      end)

    if file = topology["report"],
      do: File.write!(file, Jason.encode!(%{world_node: node(), scenes: report}))

    Logger.info("voxim_topology_ready scenes=#{inspect(Map.keys(routes))} world_node=#{node()}")
    {:ok, %{routes: routes, peers: for({_, _, %{peer: peer}} <- started, do: peer)}}
  end

  defp start_local(scene, world, index, origin_us) do
    config = Scene.load_config!(scene["config"])
    {world_ref, world_api} = region(scene, world, config)
    name = if index == 0, do: Scene, else: :"voxim_scene#{scene["scene_id"]}"

    {:ok, _} =
      Supervisor.start_child(
        SceneServer.Supervisor,
        Supervisor.child_spec(
          {Scene,
           name: name,
           scene_id: scene["scene_id"],
           scene_epoch: 1,
           world_ref: world_ref,
           world_api: world_api,
           timeline_origin_us: origin_us,
           config_path: scene["config"]},
          id: name
        )
      )

    {scene["scene_id"], route({name, node()}, world), %{os_pid: System.pid()}}
  end

  # 本地只读区域：Scene 从本节点 Replica 读取碰撞与增量，编辑与权威仍在 World。
  defp region(%{"replica" => true}, world, config) do
    {:ok, replica} =
      Supervisor.start_child(
        VoxelRegion.Supervisor,
        {Replica,
         authority_ref: world,
         l0_box: config.l0,
         name: :"voxim_replica_#{System.unique_integer([:positive])}"}
      )

    {replica, Replica}
  end

  defp region(_scene, world, _config), do: {world, VoxelRegion.World}

  # 另一个 BEAM 节点：同一份代码路径与应用配置，本地 Replica 消费 World；时间线原点与本地 Scene 对齐。
  defp start_peer(scene, world, origin_us) do
    config = Scene.load_config!(scene["config"])
    [_, host] = node() |> Atom.to_string() |> String.split("@")

    {:ok, peer, peer_node} =
      :peer.start_link(%{
        name: :"voxim_scene#{scene["scene_id"]}",
        host: String.to_charlist(host),
        longnames: String.contains?(host, "."),
        connection: :standard_io,
        exec: peer_exec(),
        args:
          [
            ~c"+S",
            String.to_charlist(Map.get(scene, "schedulers", "1:1")),
            ~c"-setcookie",
            Atom.to_charlist(Node.get_cookie())
          ] ++ release_boot()
      })

    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

    for app <- [:elixir, :logger],
        do: {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [app])

    :ok = :peer.call(peer, Logger, :configure, [[level: Logger.level()]])

    for app <- [:data_service, :voxel_region, :scene_server],
        {key, value} <- Application.get_all_env(app),
        do: :ok = :peer.call(peer, Application, :put_env, [app, key, value])

    :ok =
      :peer.call(peer, Application, :put_env, [
        :voxel_region,
        :replica,
        [authority_ref: world, l0_box: config.l0]
      ])

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:voxel_region], 300_000)
    replica = :peer.call(peer, Process, :whereis, [Replica])

    :ok =
      :peer.call(peer, Application, :put_env, [
        :scene_server,
        Scene,
        [
          name: Scene,
          scene_id: scene["scene_id"],
          scene_epoch: 1,
          world_ref: replica,
          world_api: Replica,
          timeline_origin_us: origin_us,
          config_path: scene["config"]
        ]
      ])

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:scene_server], 300_000)
    true = Node.connect(peer_node)
    info = %{peer: peer, os_pid: :peer.call(peer, System, :pid, [])}
    {scene["scene_id"], route({Scene, peer_node}, world), info}
  end

  # release 里用本发布自带 erts 的启动器与 start_clean 引导（代码路径随后从本节点复制）；Mix 运行时直接用 PATH 上的 erl。
  defp peer_exec do
    case System.get_env("RELEASE_ROOT") do
      nil -> System.find_executable("erl")
      root -> Path.join([root, "erts-#{:erlang.system_info(:version)}", "bin", "erl"])
    end
    |> String.to_charlist()
  end

  defp release_boot do
    case System.get_env("RELEASE_ROOT") do
      nil ->
        []

      root ->
        boot = Path.join([root, "releases", System.fetch_env!("RELEASE_VSN"), "start_clean"])

        [
          ~c"-boot",
          String.to_charlist(boot),
          ~c"-boot_var",
          ~c"RELEASE_LIB",
          String.to_charlist(Path.join(root, "lib"))
        ]
    end
  end

  defp route(scene_ref, world), do: %{scene_ref: scene_ref, world_ref: world, scene_epoch: 1}

  defp node_of(%{scene_ref: {_, node}}), do: node

  defp ready!(scene_ref) do
    Enum.find_value(1..@ready_attempts, fn _ ->
      case Scene.neighbour_endpoint(scene_ref) do
        {:ok, endpoint} -> endpoint
        {:error, :scene_not_ready} -> Process.sleep(100) && nil
      end
    end) || raise "scene #{inspect(scene_ref)} not ready"
  end
end
