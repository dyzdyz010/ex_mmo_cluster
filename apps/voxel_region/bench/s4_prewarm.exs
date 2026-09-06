alias VoxelRegion.GeneratedStore

usage =
  "mix run --no-start apps/voxel_region/bench/s4_prewarm.exs <manifest.json> <root> <regions.json> [max_concurrency]"

{manifest_path, root, regions_path, max_concurrency} =
  case System.argv() do
    [manifest_path, root, regions_path] ->
      {manifest_path, root, regions_path, 4}

    [manifest_path, root, regions_path, value] ->
      {manifest_path, root, regions_path, String.to_integer(value)}

    _ ->
      raise usage
  end

regions = regions_path |> File.read!() |> Jason.decode!()
true = is_list(regions)
regions = Enum.uniq_by(regions, &{Map.fetch!(&1, "level"), Map.fetch!(&1, "coord")})
{:ok, store} = GeneratedStore.open(root: root, manifest_path: manifest_path)
started = System.monotonic_time(:millisecond)

results =
  regions
  |> Task.async_stream(
    fn %{"level" => level, "coord" => [x, y, z]} ->
      item_started = System.monotonic_time(:millisecond)
      {:ok, bytes, _header} = GeneratedStore.read(store, level, {x, y, z})

      %{
        level: level,
        coord: {x, y, z},
        bytes: byte_size(bytes),
        elapsed_ms: System.monotonic_time(:millisecond) - item_started
      }
    end,
    ordered: false,
    max_concurrency: max_concurrency,
    timeout: :infinity
  )
  |> Enum.map(fn
    {:ok, result} -> result
    {:exit, reason} -> raise "prewarm worker failed: #{inspect(reason)}"
  end)

Enum.each(results, fn result ->
  IO.puts(
    "voxel_region prewarm L#{result.level} #{inspect(result.coord)} bytes=#{result.bytes} elapsed_ms=#{result.elapsed_ms}"
  )
end)

IO.puts(
  "voxel_region prewarm complete content_version=#{GeneratedStore.hex(GeneratedStore.content_version(store))} regions=#{length(results)} elapsed_ms=#{System.monotonic_time(:millisecond) - started} max_concurrency=#{max_concurrency}"
)
