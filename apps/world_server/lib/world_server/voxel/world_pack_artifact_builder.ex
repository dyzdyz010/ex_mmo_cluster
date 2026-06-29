defmodule WorldServer.Voxel.WorldPackArtifactBuilder do
  @moduledoc """
  从 canonical chunk snapshots 构建可随机读取的 `.vxpack` payload shard。

  这个模块只做离线/发布期 artifact 生成：输入必须已经是完整、可信的
  `WorldPackIndex` 与 canonical snapshot store。运行时订阅不能调用这里补缺包。
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias MmoContracts.WorldPackIndex
  alias MmoContracts.WorldPackShard
  alias WorldServer.Voxel.WorldPackReleaseVerifier

  @type chunk_coord :: {integer(), integer(), integer()}
  @type summary :: %{
          logical_scene_id: non_neg_integer(),
          center: chunk_coord(),
          radius: non_neg_integer(),
          planned_chunks: non_neg_integer(),
          written_chunks: non_neg_integer(),
          shard_count: non_neg_integer(),
          shard_paths: [String.t()],
          errors: non_neg_integer(),
          chunk_errors: [map()]
        }

  @doc """
  按 `world_pack_index_v1` 的 payload layout 构建一个滑动窗口所需 shard。

  `:output_dir` 必填。`:snapshot_store` 可传入 `fun(logical_scene_id, chunk_coord)`
  或实现 `get_snapshot/2` 的模块，默认使用 `DataService.Voxel.ChunkSnapshotStore`。
  """
  @spec build_window(WorldPackIndex.t(), chunk_coord(), non_neg_integer(), keyword()) ::
          {:ok, summary()} | {:error, term()}
  def build_window(%WorldPackIndex{} = index, center, radius, opts) when is_list(opts) do
    with {:ok, output_dir} <- fetch_output_dir(opts),
         {:ok, _authority_summary} <- verify_authority_index(index),
         {:ok, plan} <- WorldPackIndex.window_payload_plan(index, center, radius),
         {:ok, entries_by_path, written_chunks} <-
           collect_entries(
             index.logical_scene_id,
             plan,
             Keyword.get(opts, :snapshot_store, ChunkSnapshotStore)
           ) do
      write_shards(output_dir, index, plan, entries_by_path, written_chunks)
    else
      {:error, {:missing_world_pack_snapshots, summary}} ->
        {:error, {:missing_world_pack_snapshots, summary}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_window(_index, _center, _radius, _opts),
    do: {:error, :invalid_world_pack_artifact_options}

  @doc """
  按完整 world-pack index 构建一个 payload shard。

  这个入口是完整 32km pack 生产的基本单位：调用方应先拿
  `WorldPackIndex.payload_shard_grid/1`，再逐 shard 调用本函数。函数不会清空
  `:output_dir`，因此可以安全地连续写多个 shard。
  """
  @spec build_shard(WorldPackIndex.t(), chunk_coord(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_shard(%WorldPackIndex{} = index, shard_coord, opts) when is_list(opts) do
    with {:ok, output_dir} <- fetch_output_dir(opts),
         {:ok, authority_summary} <- verify_authority_index(index),
         snapshot_store <- Keyword.get(opts, :snapshot_store, ChunkSnapshotStore),
         :ok <- File.mkdir_p(output_dir) do
      build_payload_shard(index, shard_coord, output_dir, snapshot_store, authority_summary)
    end
  end

  def build_shard(_index, _shard_coord, _opts),
    do: {:error, :invalid_world_pack_artifact_options}

  @doc """
  按完整 payload shard grid 构建一个 release-ready world pack。

  这个入口会逐 shard 展开和写入 payload，不会一次性展开完整 32km chunk
  ref 集合。`:output_dir` 必填；`:snapshot_store` 语义与 `build_shard/3`
  相同。函数不会清空输出目录，因此可用于覆盖写入预期 shard，并保留外部
  管理的发布元数据。
  """
  @spec build_release(WorldPackIndex.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_release(%WorldPackIndex{} = index, opts) when is_list(opts) do
    with {:ok, output_dir} <- fetch_output_dir(opts),
         {:ok, authority_summary} <- verify_authority_index(index),
         {:ok, grid} <- WorldPackIndex.payload_shard_grid(index),
         {:ok, shard_coords} <- release_shard_coords(grid, opts),
         snapshot_store <- Keyword.get(opts, :snapshot_store, ChunkSnapshotStore),
         :ok <- File.mkdir_p(output_dir),
         {:ok, shard_summaries} <-
           build_release_shards(
             index,
             shard_coords,
             output_dir,
             snapshot_store,
             authority_summary
           ),
         complete? <- release_complete?(grid, shard_coords),
         {:ok, manifest} <- maybe_build_release_manifest(index, output_dir, complete?) do
      {:ok,
       %{
         logical_scene_id: index.logical_scene_id,
         status: if(complete?, do: :ready, else: :partial),
         content_version: index.content_version,
         authority_expected_chunks: authority_summary.expected_chunk_count,
         authority_covered_chunks: authority_summary.covered_chunk_count,
         expected_shards: grid.shard_count,
         built_shards: length(shard_summaries),
         remaining_shards: grid.shard_count - MapSet.size(MapSet.new(shard_coords)),
         planned_chunks: sum_summary_field(shard_summaries, :planned_chunks),
         written_chunks: sum_summary_field(shard_summaries, :written_chunks),
         shard_paths: shard_summaries |> Enum.flat_map(& &1.shard_paths) |> Enum.sort(),
         manifest: manifest,
         errors: 0,
         chunk_errors: []
       }}
    end
  end

  def build_release(_index, _opts), do: {:error, :invalid_world_pack_artifact_options}

  @doc """
  为一段 runtime 滑动窗口序列构建 union payload pack。

  权威性来自完整 `WorldPackIndex.verify/1`。函数不会把完整 32km payload
  展开到内存，只展开每个 requested window，并将重复 chunk 计为 held。
  """
  @spec build_window_sequence(WorldPackIndex.t(), [chunk_coord()], non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_window_sequence(%WorldPackIndex{} = index, centers, radius, opts)
      when is_list(centers) and is_list(opts) do
    with {:ok, output_dir} <- fetch_output_dir(opts),
         {:ok, authority_summary} <- verify_authority_index(index),
         {:ok, sequence} <- plan_window_sequence(index, centers, radius),
         snapshot_store <- Keyword.get(opts, :snapshot_store, ChunkSnapshotStore),
         {:ok, entries_by_path, written_chunks} <-
           collect_payload_refs(
             index.logical_scene_id,
             sequence.refs,
             snapshot_store,
             fn ref, count, reason ->
               missing_sequence_summary(
                 index,
                 sequence,
                 authority_summary,
                 ref,
                 count,
                 reason
               )
             end
           ),
         :ok <- File.rm_rf(output_dir) |> ignore_rm_rf_result(),
         :ok <- File.mkdir_p(output_dir),
         :ok <- write_shard_files(output_dir, sequence.shard_paths, entries_by_path) do
      {:ok,
       %{
         logical_scene_id: index.logical_scene_id,
         authority_expected_chunks: authority_summary.expected_chunk_count,
         authority_covered_chunks: authority_summary.covered_chunk_count,
         window_count: length(sequence.windows),
         windows: sequence.windows,
         planned_chunks: sequence.planned_chunks,
         written_chunks: written_chunks,
         shard_count: length(sequence.shard_paths),
         shard_paths: sequence.shard_paths,
         errors: 0,
         chunk_errors: []
       }}
    end
  end

  def build_window_sequence(_index, _centers, _radius, _opts),
    do: {:error, :invalid_world_pack_artifact_options}

  defp fetch_output_dir(opts) do
    case Keyword.fetch(opts, :output_dir) do
      {:ok, output_dir} when is_binary(output_dir) and byte_size(output_dir) > 0 ->
        {:ok, output_dir}

      {:ok, _other} ->
        {:error, :invalid_output_dir}

      :error ->
        {:error, :missing_output_dir}
    end
  end

  defp verify_authority_index(index) do
    case WorldPackIndex.verify(index) do
      {:ok, summary} -> {:ok, summary}
      {:error, summary} -> {:error, {:invalid_world_pack_index, summary}}
    end
  end

  defp plan_window_sequence(_index, [], _radius), do: {:error, :empty_window_sequence}

  defp plan_window_sequence(index, centers, radius) do
    centers
    |> Enum.reduce_while(
      {:ok, [], [], MapSet.new(), 0},
      fn center, {:ok, refs_acc, windows_acc, seen_chunks, planned_acc} ->
        case WorldPackIndex.window_payload_plan(index, center, radius) do
          {:ok, plan} ->
            refs = plan_refs(plan)

            {new_refs, next_seen_chunks} =
              Enum.reduce(refs, {[], seen_chunks}, fn ref, {new_acc, seen_acc} ->
                if MapSet.member?(seen_acc, ref.chunk_coord) do
                  {new_acc, seen_acc}
                else
                  {[ref | new_acc], MapSet.put(seen_acc, ref.chunk_coord)}
                end
              end)

            new_refs = Enum.reverse(new_refs)

            window_summary = %{
              center: center,
              radius: radius,
              planned_chunks: plan.chunk_count,
              new_chunks: length(new_refs),
              held_chunks: plan.chunk_count - length(new_refs),
              shard_count: length(plan.shards)
            }

            {:cont,
             {:ok, refs_acc ++ new_refs, windows_acc ++ [window_summary], next_seen_chunks,
              planned_acc + plan.chunk_count}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
    |> case do
      {:ok, refs, windows, _seen_chunks, planned_chunks} ->
        {:ok,
         %{
           refs: refs,
           windows: windows,
           planned_chunks: planned_chunks,
           shard_paths: refs |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_entries(logical_scene_id, plan, snapshot_store) do
    collect_payload_refs(logical_scene_id, plan_refs(plan), snapshot_store, fn ref,
                                                                               count,
                                                                               reason ->
      %{
        logical_scene_id: logical_scene_id,
        center: plan.window.center,
        radius: plan.window.radius,
        planned_chunks: plan.chunk_count,
        written_chunks: count,
        shard_count: length(plan.shards),
        shard_paths: Enum.map(plan.shards, & &1.path),
        errors: 1,
        chunk_errors: [
          %{chunk_coord: Tuple.to_list(ref.chunk_coord), error: inspect(reason)}
        ]
      }
    end)
  end

  defp collect_payload_refs(logical_scene_id, refs, snapshot_store, missing_summary) do
    Enum.reduce_while(refs, {:ok, %{}, 0}, fn ref, {:ok, entries_by_path, count} ->
      case fetch_snapshot_payload(snapshot_store, logical_scene_id, ref.chunk_coord) do
        {:ok, payload} ->
          entry = %{local_coord: ref.local_coord, payload: frame_payload(payload)}
          {:cont, {:ok, Map.update(entries_by_path, ref.path, [entry], &[entry | &1]), count + 1}}

        {:error, reason} ->
          {:halt, {:error, {:missing_world_pack_snapshots, missing_summary.(ref, count, reason)}}}
      end
    end)
  end

  defp build_release_shards(index, shard_coords, output_dir, snapshot_store, authority_summary) do
    shard_coords
    |> Enum.reduce_while({:ok, []}, fn shard_coord, {:ok, summaries} ->
      case build_payload_shard(index, shard_coord, output_dir, snapshot_store, authority_summary) do
        {:ok, summary} -> {:cont, {:ok, [summary | summaries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_shard_coords(grid, opts) do
    with {:ok, requested} <- requested_release_shard_coords(grid, opts),
         {:ok, limited} <- limit_release_shard_coords(requested, opts) do
      {:ok, Enum.uniq(limited)}
    end
  end

  defp requested_release_shard_coords(grid, opts) do
    case Keyword.get(opts, :shard_coords) do
      nil ->
        {:ok, grid.shard_coords}

      coords when is_list(coords) ->
        valid = MapSet.new(grid.shard_coords)

        if Enum.all?(coords, &MapSet.member?(valid, &1)) do
          {:ok, coords}
        else
          {:error, :release_shard_coord_out_of_bounds}
        end

      _other ->
        {:error, :invalid_release_shard_coords}
    end
  end

  defp limit_release_shard_coords(coords, opts) do
    case Keyword.get(opts, :max_shards) do
      nil -> {:ok, coords}
      max when is_integer(max) and max > 0 -> {:ok, Enum.take(coords, max)}
      _other -> {:error, :invalid_release_max_shards}
    end
  end

  defp release_complete?(grid, shard_coords) do
    MapSet.equal?(MapSet.new(grid.shard_coords), MapSet.new(shard_coords))
  end

  defp maybe_build_release_manifest(index, output_dir, true),
    do: WorldPackReleaseVerifier.build_manifest(index, output_dir)

  defp maybe_build_release_manifest(_index, _output_dir, false), do: {:ok, nil}

  defp build_payload_shard(index, shard_coord, output_dir, snapshot_store, authority_summary) do
    with {:ok, shard_plan} <- WorldPackIndex.payload_shard_plan(index, shard_coord),
         {:ok, entries_by_path, written_chunks} <-
           collect_payload_refs(
             index.logical_scene_id,
             shard_plan.chunks,
             snapshot_store,
             fn ref, count, reason ->
               missing_shard_summary(index, shard_plan, authority_summary, ref, count, reason)
             end
           ),
         :ok <- write_shard_files(output_dir, [shard_plan.path], entries_by_path) do
      {:ok,
       %{
         logical_scene_id: index.logical_scene_id,
         authority_expected_chunks: authority_summary.expected_chunk_count,
         authority_covered_chunks: authority_summary.covered_chunk_count,
         shard_coord: shard_plan.shard_coord,
         planned_chunks: shard_plan.chunk_count,
         written_chunks: written_chunks,
         shard_count: 1,
         shard_paths: [shard_plan.path],
         errors: 0,
         chunk_errors: []
       }}
    end
  end

  defp sum_summary_field(summaries, field) do
    Enum.reduce(summaries, 0, fn summary, acc -> acc + Map.fetch!(summary, field) end)
  end

  defp plan_refs(plan) do
    plan.shards
    |> Enum.flat_map(& &1.chunks)
    |> Enum.sort_by(& &1.ordinal)
  end

  defp fetch_snapshot_payload(snapshot_store, logical_scene_id, chunk_coord)
       when is_function(snapshot_store, 2) do
    normalize_snapshot_result(snapshot_store.(logical_scene_id, chunk_coord))
  end

  defp fetch_snapshot_payload(snapshot_store, logical_scene_id, chunk_coord)
       when is_atom(snapshot_store) do
    normalize_snapshot_result(snapshot_store.get_snapshot(logical_scene_id, chunk_coord))
  end

  defp fetch_snapshot_payload(_snapshot_store, _logical_scene_id, _chunk_coord),
    do: {:error, :invalid_snapshot_store}

  defp normalize_snapshot_result({:ok, %{data: data}})
       when is_binary(data) and byte_size(data) > 0,
       do: {:ok, data}

  defp normalize_snapshot_result({:ok, %{data: data}}),
    do: {:error, {:invalid_snapshot_data, data}}

  defp normalize_snapshot_result({:error, reason}), do: {:error, reason}
  defp normalize_snapshot_result(other), do: {:error, {:unexpected_snapshot_result, other}}

  defp frame_payload(<<0x62, _rest::binary>> = payload), do: payload
  defp frame_payload(payload) when is_binary(payload), do: <<0x62, payload::binary>>

  defp missing_shard_summary(index, shard_plan, authority_summary, ref, written_chunks, reason) do
    %{
      logical_scene_id: index.logical_scene_id,
      authority_expected_chunks: authority_summary.expected_chunk_count,
      authority_covered_chunks: authority_summary.covered_chunk_count,
      shard_coord: shard_plan.shard_coord,
      planned_chunks: shard_plan.chunk_count,
      written_chunks: written_chunks,
      shard_count: 1,
      shard_paths: [shard_plan.path],
      errors: 1,
      chunk_errors: [%{chunk_coord: Tuple.to_list(ref.chunk_coord), error: inspect(reason)}]
    }
  end

  defp missing_sequence_summary(index, sequence, authority_summary, ref, written_chunks, reason) do
    %{
      logical_scene_id: index.logical_scene_id,
      authority_expected_chunks: authority_summary.expected_chunk_count,
      authority_covered_chunks: authority_summary.covered_chunk_count,
      window_count: length(sequence.windows),
      windows: sequence.windows,
      planned_chunks: sequence.planned_chunks,
      written_chunks: written_chunks,
      shard_count: length(sequence.shard_paths),
      shard_paths: sequence.shard_paths,
      errors: 1,
      chunk_errors: [%{chunk_coord: Tuple.to_list(ref.chunk_coord), error: inspect(reason)}]
    }
  end

  defp write_shards(output_dir, index, plan, entries_by_path, written_chunks) do
    shard_paths = Enum.map(plan.shards, & &1.path)

    with :ok <- File.rm_rf(output_dir) |> ignore_rm_rf_result(),
         :ok <- File.mkdir_p(output_dir),
         :ok <- write_shard_files(output_dir, shard_paths, entries_by_path) do
      {:ok,
       %{
         logical_scene_id: index.logical_scene_id,
         center: plan.window.center,
         radius: plan.window.radius,
         planned_chunks: plan.chunk_count,
         written_chunks: written_chunks,
         shard_count: length(plan.shards),
         shard_paths: shard_paths,
         errors: 0,
         chunk_errors: []
       }}
    end
  end

  defp ignore_rm_rf_result({:ok, _paths}), do: :ok

  defp write_shard_files(output_dir, shard_paths, entries_by_path) do
    Enum.reduce_while(shard_paths, :ok, fn shard_path, :ok ->
      entries =
        entries_by_path
        |> Map.fetch!(shard_path)
        |> Enum.reverse()

      with {:ok, bytes} <- WorldPackShard.encode(entries),
           full_path <- Path.join(output_dir, shard_path),
           :ok <- File.mkdir_p(Path.dirname(full_path)),
           :ok <- File.write(full_path, bytes) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, {:world_pack_shard_write_failed, shard_path, reason}}}
      end
    end)
  end
end
