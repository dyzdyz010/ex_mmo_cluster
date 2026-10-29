# 只测试（Test-only）：M0 基准的 Windows 原生启动组合；沿用 prod runtime、正式迁移与各应用的正式启动图。
# 不启动 gate_server：quicer 只在 Linux 构建（apps/gate_server/mix.exs quic_deps），M0 不接客户端，
# 负载经 World 公共入口由 load.ex 驱动。代码就绪先于 World 创建，完整启动后才发布派生 ready。
migration_started_us = System.monotonic_time(:microsecond)
DataService.Release.migrate()
migration_completed_us = System.monotonic_time(:microsecond)

Code.require_file("code_ready.exs", __DIR__)
code_ready = VoxelRegion.Bench.M0CodeReady.prepare!()

# 只测试：首发布闸只延迟 PageWriter 的真实 publish；World 与物理继续按正式组合根运行。
case System.get_env("M0_Q5_SIDE") do
  nil -> :ok
  "B" -> :ok
  side when side in ["H", "A"] ->
    Code.require_file("equiv.ex", __DIR__)
    {:ok, _} = VoxelRegion.Bench.FirstPublication.start_link(timeout_ms: 3_600_000)
    Application.put_env(:voxel_region, :log_backend, VoxelRegion.Bench.FirstPublicationLog)
  other -> raise ArgumentError, "invalid M0_Q5_SIDE: #{inspect(other)}"
end

application_starts =
  for app <- [:data_service, :voxel_region, :world_server, :scene_server, :npc_server, :auth_server] do
    started_us = System.monotonic_time(:microsecond)
    {:ok, _} = Application.ensure_all_started(app)
    %{app: app, started_us: started_us, completed_us: System.monotonic_time(:microsecond)}
  end

ready = %{
  os_pid: code_ready.os_pid, node: code_ready.node,
  ready_utc: DateTime.to_iso8601(DateTime.utc_now()),
  startup_profile: code_ready.profile, code_mode: :code.get_mode(), code_ready: code_ready,
  startup_phases: %{migration_started_us: migration_started_us,
    migration_completed_us: migration_completed_us, application_starts: application_starts,
    ready_us: System.monotonic_time(:microsecond)}
}

# 同目录原子发布，控制端只会读到完整 JSON；启动权威仍是 World 前冻结的报告。
ready_path = System.fetch_env!("M0_READY_FILE")
File.write!(ready_path <> ".tmp", Jason.encode!(ready))
File.rename!(ready_path <> ".tmp", ready_path)
