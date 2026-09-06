defmodule VoxelRegion.AssetPack do
  @moduledoc """
  远景资产包（决策稿 §6.2 / D-1；R6 S4 第五切片）：L ≥ min_level 的全世界 region 载荷按 level 各打成一个 `.vxpack`，
  复用 `MmoContracts.WorldPackShard` 的 footer-table 布局——条目 local_coord = region 坐标，payload = 完整 VXR4 字节，
  与线上应答 / 客户端磁盘缓存逐字节相同。客户端只读 footer 建索引，按 offset / size 随机读一份。

  范围：世界 XZ 列 × [该级最低 mixed ry − 1, 最高 mixed ry + 1]；盒内的均匀 region 也打进去（常量载荷约 0.6 KB），
  客户端在这个盒子里的 L ≥ min_level 请求就不需要网络（断网也能画地平线）。盒外的 ry 仍走网络（服务端合成常量载荷）。

  输出 `<out_dir>/<content_version hex>/L<n>.vxpack`，随 content_version 换代。只在离线 / 发布期跑（`bench/pack.exs`），不在服务路径上。
  """

  alias MmoContracts.WorldPackShard
  alias VoxelRegion.{GeneratedStore, Native}

  @doc "为 min_level..max_level 各写一个包；返回每级的 `%{level, path, regions, bytes, ry_range}`。store 必须已过就绪门（索引 + 文件齐全）。"
  def build(store, out_dir, min_level \\ 4, max_level \\ 5) do
    dir = Path.join(out_dir, GeneratedStore.hex(store.content_version))
    File.mkdir_p!(dir)

    for level <- min_level..max_level do
      {ry_lo, ry_hi} = ry_range(store, level)
      regions = for {rx, rz} <- GeneratedStore.columns(store, level), ry <- ry_lo..ry_hi, do: {rx, ry, rz}

      entries =
        Enum.map(regions, fn region ->
          {:ok, bytes, _header} = GeneratedStore.read(store, level, region)
          %{local_coord: region, payload: bytes}
        end)

      {:ok, pack} = WorldPackShard.encode(entries)
      path = Path.join(dir, "L#{level}.vxpack")
      File.write!(path, pack)
      %{level: level, path: path, regions: length(regions), bytes: byte_size(pack), ry_range: {ry_lo, ry_hi}}
    end
  end

  @doc "包里应有的 region 集合（与 build 同一枚举）。"
  def regions(store, level) do
    {ry_lo, ry_hi} = ry_range(store, level)
    for {rx, rz} <- GeneratedStore.columns(store, level), ry <- ry_lo..ry_hi, do: {rx, ry, rz}
  end

  defp ry_range(store, level) do
    rows =
      for {{l, _rx, _rz}, bounds} <- store.index.bounds,
          l == level,
          ry <- Native.mixed_rows(level, bounds, store.config),
          do: ry

    {Enum.min(rows) - 1, Enum.max(rows) + 1}
  end
end
