# 离线烘焙 / 核对 L1–L5 全世界 baseline，与服务启动时的就绪门是同一段代码。
#   mix run --no-start apps/voxel_region/bench/bake.exs <manifest.json> <root> [concurrency]
{manifest_path, root, concurrency} =
  case System.argv() do
    [manifest_path, root] -> {manifest_path, root, System.schedulers_online()}
    [manifest_path, root, value] -> {manifest_path, root, String.to_integer(value)}
    _ -> raise "usage: mix run --no-start apps/voxel_region/bench/bake.exs <manifest.json> <root> [concurrency]"
  end

{:ok, store} = VoxelRegion.GeneratedStore.open(root: root, manifest_path: manifest_path)
{:ok, _store, stats} = VoxelRegion.Bake.run(store, concurrency: concurrency)
IO.puts("voxel_region bake #{VoxelRegion.GeneratedStore.hex(store.content_version)} #{inspect(stats)}")
