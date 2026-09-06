# 远景资产包（决策稿 §6.2 / D-1）：L ≥ min_level 的全世界 region 载荷按 level 打成 `.vxpack`，输出到 <out_dir>/<content_version>/。
#   mix run --no-start apps/voxel_region/bench/pack.exs <manifest.json> <root> <out_dir> [min_level]
# 先跑就绪门（索引 + 文件齐全，已烘过只核对），再打包；最后随机抽样用 footer 读回核对与 store 逐字节相同。
{manifest_path, root, out_dir, min_level} =
  case System.argv() do
    [manifest_path, root, out_dir] -> {manifest_path, root, out_dir, 4}
    [manifest_path, root, out_dir, value] -> {manifest_path, root, out_dir, String.to_integer(value)}
    _ -> raise "usage: mix run --no-start apps/voxel_region/bench/pack.exs <manifest.json> <root> <out_dir> [min_level]"
  end

{:ok, store} = VoxelRegion.GeneratedStore.open(root: root, manifest_path: manifest_path)
{:ok, store, _stats} = VoxelRegion.Bake.run(store)
started = System.monotonic_time(:millisecond)
packs = VoxelRegion.AssetPack.build(store, out_dir, min_level)
elapsed = System.monotonic_time(:millisecond) - started

for pack <- packs do
  sample = pack.level |> then(&VoxelRegion.AssetPack.regions(store, &1)) |> Enum.shuffle() |> Enum.take(8)

  for region <- sample do
    {:ok, from_pack} = MmoContracts.WorldPackShard.fetch_file(pack.path, region)
    {:ok, from_store, _} = VoxelRegion.GeneratedStore.read(store, pack.level, region)
    if from_pack != from_store, do: raise("pack L#{pack.level} #{inspect(region)} differs from store")
  end

  IO.puts("voxel_region pack L#{pack.level} regions=#{pack.regions} ry=#{inspect(pack.ry_range)} bytes=#{pack.bytes} path=#{pack.path} verified=#{length(sample)}")
end

IO.puts("voxel_region pack #{VoxelRegion.GeneratedStore.hex(store.content_version)} min_level=#{min_level} elapsed_ms=#{elapsed}")
