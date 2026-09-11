# 独立 VM 编译当前源码；不连接在线节点，不启动 World 应用或写在线数据库。
Code.compiler_options(ignore_module_conflict: true)
for file <- [
  "apps/mmo_contracts/lib/mmo_contracts/voxel/refined.ex",
  "apps/mmo_contracts/lib/mmo_contracts/voxel/structure.ex",
  "apps/mmo_contracts/lib/mmo_contracts/voxel/codec.ex",
  "apps/mmo_contracts/lib/mmo_contracts/voxel/payload.ex",
  "apps/voxel_region/lib/voxel_region/spatial.ex",
  "apps/voxel_region/lib/voxel_region/structure.ex",
  "apps/voxel_region/lib/voxel_region/collision_source.ex",
  "apps/voxel_region/lib/voxel_region/prefab.ex",
  "apps/voxel_region/lib/voxel_region/world.ex",
  "apps/gate_server/lib/gate_server/session/dispatch.ex",
  "apps/gate_server/lib/gate_server/session/quic_connection.ex"
], do: Code.compile_file(file)
if "--db" in System.argv() do
  Application.ensure_all_started(:ecto_sql)
  config = [database: "mmo_a4_test",hostname: System.get_env("MMO_DB_HOST","host.docker.internal"),
    port: String.to_integer(System.get_env("MMO_DB_PORT","5433")),username: "postgres",password: "postgres",pool_size: 2]
  Application.put_env(:data_service,DataService.Repo,config)
  case Ecto.Adapters.Postgres.storage_up(config) do
    :ok -> :ok
    {:error,:already_up} -> :ok
  end
  {:ok,_} = DataService.Repo.start_link()
  [{migration,_}] = Code.compile_file("apps/data_service/priv/repo/migrations/20260907000001_create_voxel_overlay_log.exs")
  Ecto.Migrator.up(DataService.Repo,20260907000001,migration,log: false)
  Logger.configure(level: :warning)
  ExUnit.start(autorun: false,exclude: [:test],include: [:database],timeout: 300_000)
else
  ExUnit.start(autorun: false,exclude: [:database], timeout: 300_000)
end
Code.require_file("apps/mmo_contracts/test/mmo_contracts/r7_prefab_test.exs")
Code.require_file("apps/voxel_region/test/prefab_definition_test.exs")
Code.require_file("apps/voxel_region/test/prefab_test.exs")

result = ExUnit.run()
System.halt(if result.failures > 0,do: 1,else: 0)
