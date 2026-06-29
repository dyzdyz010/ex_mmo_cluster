defmodule WorldServer.Voxel.WorldPackReleaseVerifier do
  @moduledoc """
  Verifies a release-ready world-pack payload set against the compact authority index.

  This module is a deployment/launcher validation surface. It proves that every
  expected `.vxpack` shard for the authoritative index exists and matches the
  release manifest before it samples runtime-style sliding windows from the
  verified local files. It never generates missing chunks and is not a runtime
  fallback path for Gate or Scene subscription.
  """

  alias MmoContracts.WorldPackIndex
  alias MmoContracts.WorldPackShard

  @type shard_manifest :: %{
          required(:path) => String.t(),
          required(:size_bytes) => non_neg_integer(),
          required(:sha256) => String.t()
        }

  @type manifest :: %{
          required(:format) => String.t(),
          required(:logical_scene_id) => non_neg_integer(),
          required(:content_version) => String.t(),
          required(:expected_shards) => pos_integer(),
          required(:expected_chunks) => pos_integer(),
          required(:shards) => [shard_manifest()]
        }

  @doc """
  Builds an in-memory manifest for all expected payload shards under `pack_root`.

  Missing shard files are reported as `{:world_pack_release_invalid, summary}`.
  The manifest is intentionally plain data so CLI callers can JSON-encode it in
  their own observe output without coupling this module to a particular writer.
  """
  @spec build_manifest(WorldPackIndex.t(), String.t()) ::
          {:ok, manifest()} | {:error, term()}
  def build_manifest(%WorldPackIndex{} = index, pack_root) when is_binary(pack_root) do
    with {:ok, authority_summary} <- verify_authority_index(index),
         {:ok, expected_shards, grid} <- expected_shards(index),
         {:ok, shard_entries} <- read_expected_shards(index, pack_root, expected_shards, grid) do
      {:ok,
       %{
         format: "world_pack_release_manifest_v1",
         logical_scene_id: index.logical_scene_id,
         content_version: index.content_version,
         expected_shards: grid.shard_count,
         expected_chunks: authority_summary.expected_chunk_count,
         shards: shard_entries
       }}
    end
  end

  def build_manifest(_index, _pack_root), do: {:error, :invalid_world_pack_release_options}

  @doc """
  Verifies a complete local release payload and optional sliding-window samples.

  Options:

    * `:manifest` - preloaded manifest map. If absent, a manifest is built from
      files on disk.
    * `:window_centers` - ordered chunk centers to sample with runtime sliding
      window semantics.
    * `:radius` - L-infinity window radius, default `0`.
  """
  @spec verify(WorldPackIndex.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(index, pack_root, opts \\ [])

  def verify(%WorldPackIndex{} = index, pack_root, opts)
      when is_binary(pack_root) and is_list(opts) do
    with {:ok, authority_summary} <- verify_authority_index(index),
         {:ok, expected_shards, grid} <- expected_shards(index),
         {:ok, manifest} <- manifest_from_opts(index, pack_root, expected_shards, grid, opts),
         :ok <- validate_manifest(index, manifest, authority_summary, expected_shards, grid),
         {:ok, _entries} <-
           read_expected_shards(index, pack_root, expected_shards, grid, manifest),
         {:ok, window_summary} <- verify_window_samples(index, pack_root, opts) do
      {:ok,
       %{
         status: :ready,
         logical_scene_id: index.logical_scene_id,
         content_version: index.content_version,
         authority_expected_chunks: authority_summary.expected_chunk_count,
         authority_covered_chunks: authority_summary.covered_chunk_count,
         expected_shards: grid.shard_count,
         verified_shards: grid.shard_count,
         window_count: window_summary.window_count,
         window_planned_chunks: window_summary.window_planned_chunks,
         window_unique_chunks: window_summary.window_unique_chunks,
         windows: window_summary.windows
       }}
    end
  end

  def verify(_index, _pack_root, _opts), do: {:error, :invalid_world_pack_release_options}

  defp verify_authority_index(index) do
    case WorldPackIndex.verify(index) do
      {:ok, summary} -> {:ok, summary}
      {:error, summary} -> {:error, {:invalid_world_pack_index, summary}}
    end
  end

  defp expected_shards(index) do
    with {:ok, grid} <- WorldPackIndex.payload_shard_grid(index),
         {:ok, summaries} <- WorldPackIndex.payload_shard_summaries(index) do
      {:ok, summaries, grid}
    end
  end

  defp manifest_from_opts(index, pack_root, expected_shards, grid, opts) do
    case Keyword.fetch(opts, :manifest) do
      {:ok, manifest} ->
        {:ok, manifest}

      :error ->
        with {:ok, shard_entries} <- read_expected_shards(index, pack_root, expected_shards, grid),
             {:ok, authority_summary} <- verify_authority_index(index) do
          {:ok,
           %{
             format: "world_pack_release_manifest_v1",
             logical_scene_id: index.logical_scene_id,
             content_version: index.content_version,
             expected_shards: grid.shard_count,
             expected_chunks: authority_summary.expected_chunk_count,
             shards: shard_entries
           }}
        end
    end
  end

  defp read_expected_shards(index, pack_root, expected_shards, grid, manifest \\ nil) do
    manifest_by_path = manifest_by_path(manifest)

    if File.dir?(pack_root) do
      expected_shards
      |> Enum.reduce_while(
        {:ok, [], [], 0},
        fn expected, {:ok, entries, missing, verified} ->
          path = expected.path
          full_path = Path.join(pack_root, path)

          case shard_entry(path, full_path) do
            {:ok, entry} ->
              with :ok <- validate_shard_entry(entry, manifest_by_path),
                   :ok <- validate_shard_footer(index, expected, full_path) do
                {:cont, {:ok, [entry | entries], missing, verified + 1}}
              else
                {:error, summary} ->
                  {:halt, {:error, {:world_pack_release_invalid, summary}}}
              end

            {:error, _reason} ->
              {:cont, {:ok, entries, [path | missing], verified}}
          end
        end
      )
      |> case do
        {:ok, entries, [], _verified} ->
          {:ok, Enum.reverse(entries)}

        {:ok, _entries, missing, verified} ->
          missing_shards_error(grid, missing |> Enum.reverse(), verified)

        {:error, reason} ->
          {:error, reason}
      end
    else
      missing_shards_error(grid, Enum.map(expected_shards, & &1.path), 0)
    end
  end

  defp missing_shards_error(grid, missing, verified) do
    {:error,
     {:world_pack_release_invalid,
      %{
        status: :invalid,
        reason: :missing_pack_shards,
        expected_shards: grid.shard_count,
        verified_shards: verified,
        missing_shard_count: length(missing),
        first_missing_shards: Enum.take(missing, 8)
      }}}
  end

  defp shard_entry(path, full_path) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(full_path),
         {:ok, sha256} <- sha256_file(full_path) do
      {:ok, %{path: path, size_bytes: size, sha256: sha256}}
    else
      {:ok, _stat} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_shard_entry(_entry, nil), do: :ok

  defp validate_shard_entry(entry, manifest_by_path) do
    case Map.fetch(manifest_by_path, entry.path) do
      {:ok, manifest_entry} ->
        cond do
          manifest_value(manifest_entry, :size_bytes) != entry.size_bytes ->
            {:error,
             %{
               status: :invalid,
               reason: :shard_size_mismatch,
               path: entry.path,
               expected_size_bytes: manifest_value(manifest_entry, :size_bytes),
               actual_size_bytes: entry.size_bytes
             }}

          manifest_value(manifest_entry, :sha256) != entry.sha256 ->
            {:error,
             %{
               status: :invalid,
               reason: :shard_hash_mismatch,
               path: entry.path,
               expected_sha256: manifest_value(manifest_entry, :sha256),
               actual_sha256: entry.sha256
             }}

          true ->
            :ok
        end

      :error ->
        {:error,
         %{
           status: :invalid,
           reason: :manifest_shard_missing,
           path: entry.path
         }}
    end
  end

  defp validate_shard_footer(index, expected, full_path) do
    with {:ok, footer} <- WorldPackShard.footer_summary_file(full_path),
         :ok <- validate_shard_footer_count(expected, footer),
         :ok <- validate_shard_footer_local_coords(index, expected, footer) do
      :ok
    else
      {:error, summary} when is_map(summary) ->
        {:error, summary}

      {:error, reason} ->
        {:error,
         %{
           status: :invalid,
           reason: :shard_footer_invalid,
           path: expected.path,
           error: inspect(reason)
         }}
    end
  end

  defp validate_shard_footer_count(expected, footer) do
    if footer.entry_count == expected.chunk_count do
      :ok
    else
      {:error,
       %{
         status: :invalid,
         reason: :shard_footer_entry_count_mismatch,
         path: expected.path,
         expected_entries: expected.chunk_count,
         actual_entries: footer.entry_count
       }}
    end
  end

  defp validate_shard_footer_local_coords(index, expected, footer) do
    {local_min, local_max} = expected_local_bounds(index, expected)

    case Enum.find(footer.local_coords, &(not local_bounds_contains?(local_min, local_max, &1))) do
      nil ->
        :ok

      coord ->
        {:error,
         %{
           status: :invalid,
           reason: :shard_footer_local_coord_out_of_bounds,
           path: expected.path,
           local_coord: coord,
           expected_local_min: local_min,
           expected_local_max: local_max
         }}
    end
  end

  defp expected_local_bounds(%WorldPackIndex{payload_layout: payload_layout}, expected) do
    {expected_local_coord(payload_layout, expected.shard_coord, expected.chunk_min),
     expected_local_coord(payload_layout, expected.shard_coord, expected.chunk_max)}
  end

  defp expected_local_coord(
         payload_layout,
         {shard_x, shard_y, shard_z},
         {chunk_x, chunk_y, chunk_z}
       ) do
    {origin_x, origin_y, origin_z} = payload_layout.shard_origin
    {shape_x, shape_y, shape_z} = payload_layout.shard_chunk_shape

    {
      chunk_x - origin_x - shard_x * shape_x,
      chunk_y - origin_y - shard_y * shape_y,
      chunk_z - origin_z - shard_z * shape_z
    }
  end

  defp local_bounds_contains?(
         {min_x, min_y, min_z},
         {max_x, max_y, max_z},
         {x, y, z}
       ) do
    x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and z <= max_z
  end

  defp manifest_by_path(nil), do: nil

  defp manifest_by_path(manifest) when is_map(manifest) do
    case manifest_value(manifest, :shards) do
      shards when is_list(shards) ->
        Map.new(shards, fn shard -> {manifest_value(shard, :path), shard} end)

      _other ->
        %{}
    end
  end

  defp manifest_by_path(_manifest), do: %{}

  defp manifest_value(%{} = value, key) do
    Map.get(value, key) || Map.get(value, Atom.to_string(key))
  end

  defp manifest_value(_value, _key), do: nil

  defp validate_manifest(index, manifest, authority_summary, expected_shards, grid) do
    cond do
      not is_map(manifest) ->
        invalid_manifest(:invalid_manifest)

      manifest_value(manifest, :format) != "world_pack_release_manifest_v1" ->
        invalid_manifest(:invalid_manifest_format)

      manifest_value(manifest, :logical_scene_id) != index.logical_scene_id ->
        invalid_manifest(:manifest_scene_mismatch)

      manifest_value(manifest, :content_version) != index.content_version ->
        invalid_manifest(:manifest_content_version_mismatch)

      manifest_value(manifest, :expected_shards) != grid.shard_count ->
        invalid_manifest(:manifest_expected_shards_mismatch)

      manifest_value(manifest, :expected_chunks) != authority_summary.expected_chunk_count ->
        invalid_manifest(:manifest_expected_chunks_mismatch)

      not is_list(manifest_value(manifest, :shards)) ->
        invalid_manifest(:invalid_manifest_shards)

      true ->
        validate_manifest_shards(manifest_value(manifest, :shards), expected_shards)
    end
  end

  defp invalid_manifest(reason) do
    {:error, {:world_pack_release_invalid, %{status: :invalid, reason: reason}}}
  end

  defp validate_manifest_shards(shards, expected_shards) do
    expected_paths = expected_shards |> Enum.map(& &1.path) |> MapSet.new()
    paths = Enum.map(shards, &manifest_value(&1, :path))

    cond do
      Enum.any?(paths, &(not valid_manifest_path?(&1))) ->
        invalid_manifest(:invalid_manifest_shard_path)

      duplicate_paths(paths) != [] ->
        {:error,
         {:world_pack_release_invalid,
          %{
            status: :invalid,
            reason: :manifest_duplicate_shards,
            duplicate_shards: duplicate_paths(paths)
          }}}

      unexpected_paths(paths, expected_paths) != [] ->
        {:error,
         {:world_pack_release_invalid,
          %{
            status: :invalid,
            reason: :manifest_unexpected_shards,
            unexpected_shards: unexpected_paths(paths, expected_paths)
          }}}

      true ->
        :ok
    end
  end

  defp valid_manifest_path?(value), do: is_binary(value) and byte_size(value) > 0

  defp duplicate_paths(paths) do
    paths
    |> Enum.frequencies()
    |> Enum.filter(fn {_path, count} -> count > 1 end)
    |> Enum.map(fn {path, _count} -> path end)
    |> Enum.sort()
  end

  defp unexpected_paths(paths, expected_paths) do
    paths
    |> Enum.reject(&MapSet.member?(expected_paths, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp verify_window_samples(index, pack_root, opts) do
    centers = Keyword.get(opts, :window_centers, [])
    radius = Keyword.get(opts, :radius, 0)

    cond do
      not is_list(centers) ->
        {:error, :invalid_window_centers}

      not (is_integer(radius) and radius >= 0) ->
        {:error, :invalid_window_radius}

      true ->
        reduce_window_samples(index, pack_root, centers, radius)
    end
  end

  defp reduce_window_samples(index, pack_root, centers, radius) do
    centers
    |> Enum.reduce_while({:ok, [], MapSet.new(), 0}, fn center,
                                                        {:ok, windows, seen_chunks, planned_acc} ->
      case WorldPackIndex.window_payload_plan(index, center, radius) do
        {:ok, plan} ->
          case verify_window_plan(plan, pack_root, seen_chunks) do
            {:ok, window, next_seen_chunks} ->
              {:cont,
               {:ok, windows ++ [window], next_seen_chunks, planned_acc + plan.chunk_count}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt,
           {:error, {:world_pack_release_invalid, window_error_summary(center, radius, reason)}}}
      end
    end)
    |> case do
      {:ok, windows, seen_chunks, planned_chunks} ->
        {:ok,
         %{
           window_count: length(windows),
           window_planned_chunks: planned_chunks,
           window_unique_chunks: MapSet.size(seen_chunks),
           windows: windows
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_window_plan(plan, pack_root, seen_chunks) do
    refs = plan_refs(plan)

    refs
    |> Enum.reduce_while({:ok, seen_chunks, 0}, fn ref, {:ok, seen_acc, loaded} ->
      if MapSet.member?(seen_acc, ref.chunk_coord) do
        {:cont, {:ok, seen_acc, loaded}}
      else
        with {:ok, <<0x62, _payload::binary>>} <- fetch_window_payload(pack_root, ref) do
          {:cont, {:ok, MapSet.put(seen_acc, ref.chunk_coord), loaded + 1}}
        else
          {:ok, other} ->
            {:halt,
             {:error,
              {:world_pack_release_invalid,
               %{
                 status: :invalid,
                 reason: :invalid_chunk_payload_frame,
                 path: ref.path,
                 chunk_coord: ref.chunk_coord,
                 local_coord: ref.local_coord,
                 payload_size: byte_size(other)
               }}}}

          {:error, reason} ->
            {:halt,
             {:error,
              {:world_pack_release_invalid,
               %{
                 status: :invalid,
                 reason: :window_payload_missing,
                 path: ref.path,
                 chunk_coord: ref.chunk_coord,
                 local_coord: ref.local_coord,
                 error: inspect(reason)
               }}}}
        end
      end
    end)
    |> case do
      {:ok, next_seen_chunks, loaded_chunks} ->
        {:ok,
         %{
           center: plan.window.center,
           radius: plan.window.radius,
           planned_chunks: plan.chunk_count,
           loaded_chunks: loaded_chunks,
           held_chunks: plan.chunk_count - loaded_chunks,
           shard_count: length(plan.shards)
         }, next_seen_chunks}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_window_payload(pack_root, ref) do
    pack_root
    |> Path.join(ref.path)
    |> WorldPackShard.fetch_file(ref.local_coord)
  end

  defp plan_refs(plan) do
    plan.shards
    |> Enum.flat_map(& &1.chunks)
    |> Enum.sort_by(& &1.ordinal)
  end

  defp window_error_summary(center, radius, reason) do
    %{
      status: :invalid,
      reason: :window_plan_failed,
      center: center,
      radius: radius,
      error: reason
    }
  end

  defp sha256_file(full_path) do
    hash =
      full_path
      |> File.stream!(1_048_576, [:read, :binary])
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, context ->
        :crypto.hash_update(context, chunk)
      end)
      |> :crypto.hash_final()

    {:ok, "sha256:" <> Base.encode16(hash, case: :lower)}
  rescue
    exception -> {:error, {:file_hash_failed, Exception.message(exception)}}
  end
end
