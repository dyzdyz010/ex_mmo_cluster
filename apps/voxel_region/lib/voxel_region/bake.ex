defmodule VoxelRegion.Bake do
  @moduledoc """
  就绪门：L1–L5 全世界 baseline 在开放连接前烘好。

  世界是以原点为中心、半边长 `world_half_extent_m` 的正方形；每级枚举所有 XZ 列，用 kernel 的折叠边界
  （`Native.column_bounds`）判断哪些 ry 不能证明均匀（`Native.mixed_rows`），只有这些 region 需要生成并落盘；
  纯空气 / 纯岩石的 region 不落盘，读取时按同一分类合成常量载荷。列边界写进 `baseline/index.etf`，
  之后的启动只核对文件是否齐全。L0 不在门内：它按玩家位置在线生成，单块几十毫秒。

  同一 content_version 下 baseline 不可变；kernel 或配置一变，版本目录换新，这里重新烘一次。
  """

  require Logger
  alias VoxelRegion.{GeneratedStore, Native}

  @levels 1..5

  @doc "烘焙或核对；返回 `{:ok, store, stats}`，`store` 带上列边界索引。"
  def run(store, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    started = System.monotonic_time(:millisecond)

    store =
      case store.index do
        nil ->
          columns = for level <- @levels, column <- GeneratedStore.columns(store, level), do: {level, column}

          bounds =
            columns
            |> Task.async_stream(
              fn {level, {rx, rz}} -> {{level, rx, rz}, Native.column_bounds(level, {rx, rz}, store.config)} end,
              max_concurrency: concurrency,
              ordered: false,
              timeout: :infinity
            )
            |> Map.new(fn {:ok, entry} -> entry end)

          Logger.info("voxel_region bake: #{map_size(bounds)} columns bounded in #{System.monotonic_time(:millisecond) - started} ms")
          GeneratedStore.write_index(%{store | index: %{extent: store.extent, bounds: bounds}})

        _ ->
          store
      end

    mixed =
      for {{level, rx, rz}, bounds} <- store.index.bounds,
          ry <- Native.mixed_rows(level, bounds, store.config),
          do: {level, {rx, ry, rz}}

    # 每级列一次目录代替逐文件 stat：十万级文件的核对从分钟级降到秒级。
    present = Map.new(@levels, fn level -> {level, GeneratedStore.present(store, level)} end)
    missing = Enum.reject(mixed, fn {level, region} -> MapSet.member?(present[level], GeneratedStore.file_name(region)) end)
    before = GeneratedStore.generated(store)
    total = length(missing)

    missing
    |> Task.async_stream(
      fn {level, region} -> :ok = GeneratedStore.bake_region(store, level, region) end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.with_index(1)
    |> Enum.each(fn {{:ok, :ok}, n} ->
      if rem(n, 5000) == 0 do
        Logger.info("voxel_region bake: #{n}/#{total} missing regions generated, #{System.monotonic_time(:millisecond) - started} ms")
      end
    end)

    stats = %{
      columns: map_size(store.index.bounds),
      mixed: length(mixed),
      missing: total,
      generated: GeneratedStore.generated(store) - before,
      elapsed_ms: System.monotonic_time(:millisecond) - started
    }

    Logger.info(
      "voxel_region bake ready #{GeneratedStore.hex(store.content_version)} extent=#{store.extent} columns=#{stats.columns} mixed=#{stats.mixed} missing=#{stats.missing} generated=#{stats.generated} elapsed_ms=#{stats.elapsed_ms} concurrency=#{concurrency}"
    )

    {:ok, store, stats}
  end
end
