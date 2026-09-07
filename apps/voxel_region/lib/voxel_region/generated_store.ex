defmodule VoxelRegion.GeneratedStore do
  @moduledoc """
  Voxim region 的显式在线 baseline 来源。

  JSON manifest 指定 kernel、材质目录与完整八项生成配置。规范字节生成世界
  `content_version`；与 payload body hash 一样，MD5 前 64 bit 按小端解释。
  `baseline/` 下的 VXR4 是可丢弃磁盘缓存：L1–L5 由 `VoxelRegion.Bake` 在开放连接前烘齐（就绪门），
  L0 按需在线生成。能由列边界证明均匀（纯空气 / 纯岩石）的 region 不落盘，读取时合成常量载荷；
  列边界在 `baseline/index.etf`。overlay 日志与它位于同一版本目录，不从旧烘焙目录推断，也不与旧世界共用。

  同一 BEAM 内对同一 region 的并发生成只跑一次：生成者在 ETS 锁表登记，其余请求者轮询到锁释放后读已发布的文件；
  跨 OS 进程（在线服务 ⊕ 独立预热）仍靠硬链接发布保证只发布一份完整文件。
  """

  import Bitwise
  alias VoxelRegion.{Native}
  alias MmoContracts.Voxel.{Codec, Payload}
  alias MmoContracts.VoxelMaterialCatalog

  @schema "voxim-worldgen-v1"
  @identity_schema "voxim-content-version-md5-64-v2"
  @fields ~w(seed min_height sea_level max_height soil_depth lowland_amplitude mountain_amplitude cave_max_depth)
  @lock_table :voxel_region_generation

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

    extent = Map.fetch!(manifest, "world_half_extent_m")
    true = is_integer(extent) and extent > 0
    kernel_name = Map.fetch!(manifest, "kernel")
    kernel = Native.kernel_identity()
    true = String.starts_with?(kernel, kernel_name <> "+sha256:")
    materials = Map.fetch!(manifest, "materials")
    true = materials == VoxelMaterialCatalog.table()
    version = content_version(kernel, VoxelMaterialCatalog.identity_bytes(), config)
    world_dir = Path.join(root, hex(version))
    File.mkdir_p!(world_dir)
    ensure_lock_table()
    index_path = Path.join([world_dir, "baseline", "index.etf"])

    {:ok,
     %{
       root: root,
       content_version: version,
       world_dir: world_dir,
       config: config,
       extent: extent,
       index_path: index_path,
       index: load_index(index_path, extent),
       generations: :counters.new(1, [])
     }}
  end

  defp load_index(path, extent) do
    case File.read(path) do
      {:ok, bytes} ->
        case :erlang.binary_to_term(bytes, [:safe]) do
          %{extent: ^extent, bounds: bounds} -> %{extent: extent, bounds: bounds}
          _ -> nil
        end

      {:error, :enoent} ->
        nil
    end
  end

  @doc "列边界索引落盘（同目录临时文件 + rename；只有 Bake 一个 writer）。"
  def write_index(store) do
    File.mkdir_p!(Path.dirname(store.index_path))
    temporary = store.index_path <> ".#{System.pid()}.tmp"
    File.write!(temporary, :erlang.term_to_binary(store.index))
    File.rename!(temporary, store.index_path)
    store
  end

  @doc "level 上落在世界范围内的所有 XZ 列 `{rx, rz}`（世界 = 以原点为中心、半边长 extent 米）。"
  def columns(store, level) do
    size = 64 <<< level
    lo = Integer.floor_div(-store.extent, size)
    hi = Integer.floor_div(store.extent - 1, size)
    for rx <- lo..hi, rz <- lo..hi, do: {rx, rz}
  end

  @doc "列的折叠边界：索引里有就用索引，否则现算（世界范围之外的列）。"
  def bounds(store, level, {rx, rz}) do
    case store.index && Map.fetch(store.index.bounds, {level, rx, rz}) do
      {:ok, bounds} -> bounds
      _ -> Native.column_bounds(level, {rx, rz}, store.config)
    end
  end

  @doc "`{:uniform, material}` / `:mixed`。"
  def classify(store, level, {rx, ry, rz}),
    do: Native.classify_region(level, ry, bounds(store, level, {rx, rz}), store.config)

  @doc "本 store 打开以来实际执行的 NIF 生成次数。"
  def generated(store), do: :counters.get(store.generations, 1)

  def content_version(store), do: store.content_version
  def world_dir(store), do: store.world_dir

  @doc """
  读取 region 的 VXR4：均匀 region 合成常量载荷；mixed 的 L0 缺文件时在线生成；mixed 的 L1+ 必须已由 Bake 落盘，
  否则 `{:error, :not_baked}`——就绪门之后这不该发生。
  """
  def read(store, level, {_, _, _} = region) do
    case classify(store, level, region) do
      {:uniform, material} ->
        bytes =
          Codec.encode_payload(
            level,
            region,
            0,
            store.content_version,
            Native.uniform_body(level, material)
          )

        {:ok, header} = Codec.decode_payload_header(bytes)
        {:ok, bytes, header}

      :mixed ->
        path = path(store, level, region)

        case File.read(path) do
          {:ok, bytes} -> read_cached(bytes, store.content_version, level, region)
          {:error, :enoent} when level == 0 -> generate(store, path, level, region)
          {:error, :enoent} -> {:error, :not_baked}
          {:error, reason} -> {:error, {:cache_read_failed, reason}}
        end
    end
  end

  @doc "只保证能读（L0 缺则生成），不读回字节；World 之外的并发预备用它。"
  def ensure(store, level, {_, _, _} = region) do
    case classify(store, level, region) do
      {:uniform, _} -> :ok
      :mixed -> materialize(store, level, region, level == 0)
    end
  end

  @doc "Bake 用：mixed region 缺文件就生成，任何 level。"
  def bake_region(store, level, {_, _, _} = region), do: materialize(store, level, region, true)

  defp materialize(store, level, region, generate?) do
    path = path(store, level, region)

    cond do
      File.exists?(path) -> :ok
      generate? -> with {:ok, _bytes, _header} <- generate(store, path, level, region), do: :ok
      true -> {:error, :not_baked}
    end
  end

  def path(store, level, region),
    do: Path.join([store.world_dir, "baseline", "L#{level}", file_name(region)])

  def file_name({x, y, z}), do: "r_#{x}_#{y}_#{z}.vxr"

  @doc "level 目录里已发布的文件名集合（一次 ls；目录不存在 = 空）。"
  def present(store, level) do
    case File.ls(Path.join([store.world_dir, "baseline", "L#{level}"])) do
      {:ok, names} -> names |> Enum.filter(&String.ends_with?(&1, ".vxr")) |> MapSet.new()
      {:error, :enoent} -> MapSet.new()
    end
  end

  def hex(version), do: Base.encode16(<<version::64>>, case: :lower)

  @doc """
  MD5-64 v2 输入是规则名、kernel identity、材质有序 pair JSON 三段，以 NUL 分隔，随后依次为：
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

  defp ensure_lock_table do
    if :ets.whereis(@lock_table) == :undefined do
      try do
        :ets.new(@lock_table, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # 同一 region 同时只有一个生成者；其余轮询锁释放后读取发布结果。生成者被外部杀死时锁随其 pid 失效，由下一个请求者接手。
  defp generate(store, path, level, region) do
    key = {store.world_dir, level, region}

    if :ets.insert_new(@lock_table, {key, self()}) do
      try do
        generate_locked(store, path, level, region)
      after
        :ets.delete(@lock_table, key)
      end
    else
      await_generation(key)
      read(store, level, region)
    end
  end

  defp await_generation(key) do
    case :ets.lookup(@lock_table, key) do
      [] ->
        :ok

      [{_, pid}] ->
        if Process.alive?(pid) do
          receive do
          after
            25 -> :ok
          end
        else
          :ets.delete_object(@lock_table, {key, pid})
        end

        await_generation(key)
    end
  end

  defp generate_locked(store, path, level, region) do
    :counters.add(store.generations, 1, 1)
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
