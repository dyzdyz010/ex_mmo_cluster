defmodule VoxelRegion.GeneratedStore do
  @moduledoc """
  Voxim region 的显式在线 baseline 来源。

  JSON manifest 指定 kernel、材质目录与完整八项生成配置。规范字节生成世界
  `content_version`；与 payload body hash 一样，MD5 前 64 bit 按小端解释。
  `baseline/` 下的 VXR3 是可丢弃磁盘缓存。overlay 日志与它位于同一版本目录，
  不从旧烘焙目录推断，也不与旧世界共用。
  """

  alias VoxelRegion.{Codec, Native, Payload}

  @schema "voxim-worldgen-v1"
  @identity_schema "voxim-content-version-md5-64-v1"
  @fields ~w(seed min_height sea_level max_height soil_depth lowland_amplitude mountain_amplitude cave_max_depth)

  @spec open(keyword()) :: {:ok, map()}
  def open(opts) do
    root = Keyword.fetch!(opts, :root)
    manifest_path = Keyword.fetch!(opts, :manifest_path)
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    @schema = Map.fetch!(manifest, "schema")

    config =
      manifest
      |> Map.take(@fields)
      |> then(fn values ->
        {
          Map.fetch!(values, "seed"),
          Map.fetch!(values, "min_height"),
          Map.fetch!(values, "sea_level"),
          Map.fetch!(values, "max_height"),
          Map.fetch!(values, "soil_depth"),
          Map.fetch!(values, "lowland_amplitude") * 1.0,
          Map.fetch!(values, "mountain_amplitude") * 1.0,
          Map.fetch!(values, "cave_max_depth")
        }
      end)

    kernel_name = Map.fetch!(manifest, "kernel")
    kernel = Native.kernel_identity()
    true = String.starts_with?(kernel, kernel_name <> "+sha256:")
    materials = Map.fetch!(manifest, "materials")
    version = content_version(kernel, materials, config)
    world_dir = Path.join(root, hex(version))
    File.mkdir_p!(world_dir)

    {:ok, %{root: root, content_version: version, world_dir: world_dir, config: config}}
  end

  def content_version(store), do: store.content_version
  def world_dir(store), do: store.world_dir

  @doc "读取生成的 VXR3；首次访问时在线生成并写入缓存。"
  def read(store, level, {_, _, _} = region) do
    path = path(store, level, region)

    case File.read(path) do
      {:ok, bytes} -> read_cached(bytes, store.content_version, level, region)
      {:error, :enoent} -> generate(store, path, level, region)
      {:error, reason} -> {:error, {:cache_read_failed, reason}}
    end
  end

  def path(store, level, {x, y, z}) do
    Path.join([store.world_dir, "baseline", "L#{level}", "r_#{x}_#{y}_#{z}.vxr"])
  end

  def hex(version), do: Base.encode16(<<version::64>>, case: :lower)

  @doc """
  MD5-64 v1 输入是三段以 NUL 分隔的 identity 字符串，随后依次为：
  seed i64 LE；min/sea/max/soil i32 LE；lowland/mountain IEEE754 f64 LE；
  cave depth i32 LE。
  """
  def content_version(kernel, materials, {seed, min, sea, max, soil, lowland, mountain, cave}) do
    bytes =
      IO.iodata_to_binary([
        @identity_schema,
        <<0>>,
        kernel,
        <<0>>,
        materials,
        <<0>>,
        <<seed::64-little-signed, min::32-little-signed, sea::32-little-signed,
          max::32-little-signed, soil::32-little-signed, lowland::float-64-little,
          mountain::float-64-little, cave::32-little-signed>>
      ])

    <<version::64-little, _::binary>> = :crypto.hash(:md5, bytes)
    version
  end

  defp generate(store, path, level, region) do
    raw = Native.generate_region(level, region, store.config)
    {:ok, _payload} = Payload.decode_body(raw)
    bytes = Codec.encode_payload(level, region, 0, store.content_version, raw)
    File.mkdir_p!(Path.dirname(path))

    temporary =
      path <>
        ".#{System.pid()}.#{System.unique_integer([:positive, :monotonic])}.tmp"

    File.write!(temporary, bytes)

    case File.ln(temporary, path) do
      :ok ->
        File.rm!(temporary)
        {:ok, header} = Codec.decode_payload_header(bytes)
        {:ok, bytes, header}

      {:error, :eexist} ->
        File.rm!(temporary)

        case File.read(path) do
          {:ok, published} -> read_cached(published, store.content_version, level, region)
          {:error, reason} -> {:error, {:cache_read_failed, reason}}
        end

      {:error, reason} ->
        File.rm(temporary)
        {:error, {:cache_publish_failed, reason}}
    end
  end

  defp read_cached(bytes, version, level, region) do
    try do
      with {:ok, header, _raw} <- Codec.decode_payload_body(bytes),
           true <-
             header.level == level and header.region == region and
               header.content_version == version do
        {:ok, bytes, header}
      else
        _ -> {:error, :invalid_cache}
      end
    rescue
      ErlangError -> {:error, :invalid_cache}
    end
  end
end
