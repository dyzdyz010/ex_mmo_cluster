# 只测试（Test-only）：M0 基准的 Windows 原生启动组合；沿用 prod runtime、正式迁移与各应用的正式启动图。
# 不启动 gate_server：quicer 只在 Linux 构建（apps/gate_server/mix.exs quic_deps），M0 不接客户端，
# 负载经 World 公共入口由 load.ex 驱动。就绪后写 M0_READY_FILE（含 OS pid 与节点名），供 m0.py 判定。
DataService.Release.migrate()

for app <- [:data_service, :voxel_region, :world_server, :scene_server, :npc_server, :auth_server],
    do: {:ok, _} = Application.ensure_all_started(app)

File.write!(
  System.fetch_env!("M0_READY_FILE"),
  Jason.encode!(%{
    os_pid: :os.getpid() |> to_string() |> String.to_integer(),
    node: Atom.to_string(node()),
    ready_utc: DateTime.to_iso8601(DateTime.utc_now())
  })
)
