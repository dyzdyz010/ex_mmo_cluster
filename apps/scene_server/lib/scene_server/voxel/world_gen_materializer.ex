defmodule SceneServer.Voxel.WorldGenMaterializer do
  @moduledoc """
  显式的 WorldGen 到权威存储物化边界。

  本模块不是 runtime fallback，只供场景进入前的 import/migration 或受控修复工具使用：
  生成确定性的 canonical XYZ `Storage`，编码为 snapshot，并携带调用方的 World-issued
  lease fence 写入 `DataService.Voxel.ChunkSnapshotStore`。

  本模块只写 canonical XYZ chunk truth。旧 XZ heightmap projection 已退出在线链路；
  如需处理历史数据，只能显式运行 `SceneServer.Voxel.LodProjection.Rebuilder` 离线迁移工具。
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.WorldGen

  @doc """
  从 WorldGen 生成一个 chunk，并持久化为权威 truth。

  `lease` 必须是 `chunk_coord` 当前有效的 World-issued region lease；缺失或过期 token
  由 DataService 返回显式错误。

  选项：

    * `:seed` - 确定性 WorldGen seed。
    * `:expected_algorithm_version` - 可选的 world-pack 构建门禁；与当前算法身份不一致时
      在 snapshot 写入前硬失败。

  历史调用者传入的 `:lod_projection?` / `:lod_projection_opts` 不再参与写入；
  canonical snapshot 永远不携带 XZ projection cells。
  """
  @spec put_snapshot(non_neg_integer(), {integer(), integer(), integer()}, map(), keyword()) ::
          {:ok, :inserted | :updated | :unchanged} | {:error, term()}
  def put_snapshot(logical_scene_id, chunk_coord, lease, opts \\ [])

  def put_snapshot(logical_scene_id, chunk_coord, lease, opts)
      when is_integer(logical_scene_id) and logical_scene_id >= 0 and is_tuple(chunk_coord) and
             tuple_size(chunk_coord) == 3 and is_map(lease) and is_list(opts) do
    case normalize_options(opts) do
      {:ok, seed, expected_algorithm_version} ->
        do_put_snapshot(
          logical_scene_id,
          chunk_coord,
          lease,
          seed,
          expected_algorithm_version
        )

      {:error, reason} ->
        emit_failure(logical_scene_id, chunk_coord, :unavailable, reason)
        {:error, reason}
    end
  end

  def put_snapshot(_logical_scene_id, _chunk_coord, _lease, _opts),
    do: {:error, :invalid_worldgen_materialization_request}

  defp do_put_snapshot(
         logical_scene_id,
         chunk_coord,
         lease,
         seed,
         expected_algorithm_version
       ) do
    try do
      with {:ok, storage, observation} <-
             WorldGen.generate_chunk(logical_scene_id, chunk_coord, seed: seed),
           :ok <- verify_algorithm_version(expected_algorithm_version, observation),
           storage <- Storage.normalize!(storage),
           payload <- Codec.encode_chunk_snapshot_payload(%{request_id: 0, storage: storage}),
           chunk_hash <- Hash.encode64(Codec.chunk_hash(storage)),
           attrs <- snapshot_attrs(lease, chunk_coord, storage, payload, chunk_hash),
           {:ok, result} <- ChunkSnapshotStore.put_snapshot(attrs) do
        CliObserve.emit("voxel_worldgen_materialized", fn ->
          Map.merge(observation, %{
            logical_scene_id: logical_scene_id,
            chunk_version: storage.chunk_version,
            result: result,
            snapshot_bytes: byte_size(payload)
          })
        end)

        {:ok, result}
      else
        {:error, reason} ->
          emit_failure(logical_scene_id, chunk_coord, seed, reason)
          {:error, reason}
      end
    rescue
      exception ->
        reason = {:worldgen_materializer_exception, Exception.message(exception)}
        emit_failure(logical_scene_id, chunk_coord, seed, reason)
        {:error, reason}
    catch
      :exit, caught_reason ->
        reason = {:worldgen_materializer_exit, caught_reason}
        emit_failure(logical_scene_id, chunk_coord, seed, reason)
        {:error, reason}

      kind, caught_reason ->
        reason = {:worldgen_materializer_catch, kind, caught_reason}
        emit_failure(logical_scene_id, chunk_coord, seed, reason)
        {:error, reason}
    end
  end

  defp normalize_options(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, expected_algorithm_version} <-
             normalize_expected_algorithm_version(Keyword.get(opts, :expected_algorithm_version)) do
        {:ok, Keyword.get(opts, :seed, WorldGen.default_seed()), expected_algorithm_version}
      end
    else
      {:error, :invalid_worldgen_materialization_options}
    end
  end

  defp normalize_expected_algorithm_version(nil), do: {:ok, nil}

  defp normalize_expected_algorithm_version(value)
       when is_binary(value) and byte_size(value) > 0,
       do: {:ok, value}

  defp normalize_expected_algorithm_version(_value),
    do: {:error, :invalid_expected_worldgen_algorithm_version}

  defp verify_algorithm_version(nil, _observation), do: :ok

  defp verify_algorithm_version(expected, %{algorithm_version: expected})
       when is_binary(expected),
       do: :ok

  defp verify_algorithm_version(expected, %{algorithm_version: actual}) when is_binary(expected),
    do: {:error, {:worldgen_algorithm_version_mismatch, expected, actual}}

  defp verify_algorithm_version(_expected, _observation),
    do: {:error, :invalid_expected_worldgen_algorithm_version}

  defp emit_failure(logical_scene_id, chunk_coord, seed, reason) do
    CliObserve.emit("voxel_worldgen_materialization_failed", fn ->
      %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord,
        seed: seed,
        algorithm_version: safe_algorithm_version(),
        reason: inspect(reason)
      }
    end)
  end

  defp safe_algorithm_version do
    WorldGen.algorithm_version()
  rescue
    _exception -> "unavailable"
  catch
    _kind, _reason -> "unavailable"
  end

  defp snapshot_attrs(lease, chunk_coord, %Storage{} = storage, payload, chunk_hash) do
    lease
    |> Map.take([
      :logical_scene_id,
      :region_id,
      :lease_id,
      :owner_scene_instance_ref,
      :owner_epoch
    ])
    |> Map.merge(%{
      chunk_coord: chunk_coord,
      schema_version: storage.schema_version,
      chunk_size_in_macro: storage.chunk_size_in_macro,
      micro_resolution: storage.micro_resolution,
      chunk_version: storage.chunk_version,
      chunk_hash: chunk_hash,
      data: payload
    })
  end
end
