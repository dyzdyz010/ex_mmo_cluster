defmodule WorldPackReleaseBuildProbe do
  @moduledoc """
  CLI probe for building `.vxpack` world-pack release payloads.

  Usage:

      mix run --no-start scripts/world_pack_release_build.exs --index small-release-test --snapshot-mode synthetic-term
      mix run --no-start scripts/world_pack_release_build.exs --pack-root output/world-pack/full32km --max-shards 1
      mix run --no-start scripts/world_pack_release_build.exs --pack-root output/world-pack/full32km --shard-coords "64,0,64;65,0,64"

  `status: "partial"` means the requested batch was written, not that the
  release is ready. Run `world_pack_release_verify.exs` against the same
  `--pack-root` to prove full release readiness and sliding-window loading.
  """

  alias MmoContracts.WorldPackIndex
  alias WorldServer.Voxel.WorldPackArtifactBuilder

  def main(argv) do
    opts = parse_opts(argv)
    Logger.configure(level: :warning)

    index = index!(opts.index)
    pack_root = Path.expand(opts.pack_root || default_pack_root(opts.index), File.cwd!())
    observe_dir = Path.expand(opts.observe_dir, File.cwd!())
    File.mkdir_p!(observe_dir)

    build_opts =
      [output_dir: pack_root]
      |> maybe_put(:max_shards, opts.max_shards)
      |> maybe_put(:shard_coords, opts.shard_coords)
      |> Keyword.merge(snapshot_store_opts!(opts.snapshot_mode, index))

    started_ms = System.monotonic_time(:millisecond)
    result = run_build(index, build_opts, opts.snapshot_mode)
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    report = %{
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      note:
        "Build status partial is progress only. Full release readiness still requires verifier success.",
      index: index_summary(opts.index, index),
      pack_root: normalize_path(pack_root),
      snapshot_mode: opts.snapshot_mode,
      requested_max_shards: opts.max_shards,
      requested_shard_coords: Enum.map(opts.shard_coords || [], &Tuple.to_list/1),
      duration_ms: duration_ms,
      result: result_report(result)
    }

    output_path =
      Path.join(
        observe_dir,
        "world_pack_release_build_#{safe_name(opts.index)}_#{timestamp_for_path()}.json"
      )

    File.write!(output_path, Jason.encode!(json_safe(report), pretty: true))

    IO.puts(
      Jason.encode!(json_safe(Map.put(report, :output_path, normalize_path(output_path))),
        pretty: true
      )
    )

    case result do
      {:ok, _summary} -> System.halt(0)
      {:error, _reason} -> System.halt(1)
    end
  end

  defp parse_opts(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv,
        switches: [
          index: :string,
          pack_root: :string,
          observe_dir: :string,
          max_shards: :integer,
          shard_coords: :string,
          snapshot_mode: :string
        ]
      )

    if invalid != [] do
      raise ArgumentError, "invalid options: #{inspect(invalid)}"
    end

    %{
      index: Keyword.get(opts, :index, "full32km"),
      pack_root: Keyword.get(opts, :pack_root),
      observe_dir: Keyword.get(opts, :observe_dir, ".demo/observe/world-pack-release-build"),
      max_shards: Keyword.get(opts, :max_shards),
      shard_coords: parse_shard_coords(Keyword.get(opts, :shard_coords)),
      snapshot_mode: Keyword.get(opts, :snapshot_mode, "data-service")
    }
  end

  defp index!("full32km") do
    WorldPackIndex.new!(
      logical_scene_id: 91_015,
      content_version: "worldgen-32km-index-pack@1",
      chunk_min: {-1024, -3, -1024},
      chunk_max: {1023, 102, 1023},
      payload_layout: %{
        layout: "regular_shard_grid_v1",
        chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
        shard_chunk_shape: {16, 106, 16},
        shard_origin: {-1024, -3, -1024},
        file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
        footer_format: "chunk_offset_table_v1",
        compression: "none"
      },
      regions: [
        %{
          id: "full-32km",
          chunk_min: {-1024, -3, -1024},
          chunk_max: {1023, 102, 1023},
          chunk_count: 444_596_224,
          hash: "sha256:full-32km"
        }
      ]
    )
  end

  defp index!("small-release-test") do
    WorldPackIndex.new!(
      logical_scene_id: 91_016,
      content_version: "worldgen-release-test@1",
      chunk_min: {-1, -1, -1},
      chunk_max: {2, 1, 1},
      payload_layout: %{
        layout: "regular_shard_grid_v1",
        chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
        shard_chunk_shape: {2, 3, 3},
        shard_origin: {-1, -1, -1},
        file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
        footer_format: "chunk_offset_table_v1",
        compression: "none"
      },
      regions: [
        %{
          id: "small-full",
          chunk_min: {-1, -1, -1},
          chunk_max: {2, 1, 1},
          chunk_count: 36,
          hash: "sha256:small-full"
        }
      ]
    )
  end

  defp index!(other) do
    raise ArgumentError,
          "unknown index #{inspect(other)}; expected full32km or small-release-test"
  end

  defp snapshot_store_opts!("data-service", _index), do: []

  defp snapshot_store_opts!("synthetic-term", %WorldPackIndex{logical_scene_id: 91_016}) do
    [
      snapshot_store: fn 91_016, chunk_coord ->
        {:ok, %{data: :erlang.term_to_binary(chunk_coord)}}
      end
    ]
  end

  defp snapshot_store_opts!("synthetic-term", _index) do
    raise ArgumentError, "--snapshot-mode synthetic-term is only allowed with small-release-test"
  end

  defp snapshot_store_opts!(other, _index) do
    raise ArgumentError, "unknown --snapshot-mode #{inspect(other)}"
  end

  defp run_build(index, build_opts, snapshot_mode) do
    ensure_snapshot_mode_started!(snapshot_mode)
    WorldPackArtifactBuilder.build_release(index, build_opts)
  rescue
    exception ->
      {:error,
       {:world_pack_release_build_exception,
        %{
          exception: inspect(exception.__struct__),
          message: Exception.message(exception)
        }}}
  catch
    kind, reason ->
      {:error,
       {:world_pack_release_build_exit,
        %{
          kind: inspect(kind),
          reason: inspect(reason)
        }}}
  end

  defp ensure_snapshot_mode_started!("data-service") do
    Enum.each([:postgrex, :ecto_sql, :data_service], fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> :ok
        {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
      end
    end)
  end

  defp ensure_snapshot_mode_started!(_snapshot_mode), do: :ok

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_shard_coords(nil), do: nil

  defp parse_shard_coords(value) do
    value
    |> String.split(";", trim: true)
    |> Enum.map(fn token ->
      case token |> String.split(",", trim: true) |> Enum.map(&parse_integer!/1) do
        [x, y, z] -> {x, y, z}
        _other -> raise ArgumentError, "invalid --shard-coords token #{inspect(token)}"
      end
    end)
  end

  defp parse_integer!(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> raise ArgumentError, "invalid integer #{inspect(value)}"
    end
  end

  defp default_pack_root(index_name) do
    Path.join([".demo", "observe", "world-pack-release", "#{safe_name(index_name)}-pack"])
  end

  defp index_summary(index_name, index) do
    {:ok, grid} = WorldPackIndex.payload_shard_grid(index)

    %{
      name: index_name,
      logical_scene_id: index.logical_scene_id,
      content_version: index.content_version,
      chunk_min: Tuple.to_list(index.chunk_min),
      chunk_max: Tuple.to_list(index.chunk_max),
      chunk_count: WorldPackIndex.chunk_count(index),
      payload_layout: json_safe(index.payload_layout),
      expected_payload_shards: grid.shard_count,
      shard_min: Tuple.to_list(grid.shard_min),
      shard_max: Tuple.to_list(grid.shard_max)
    }
  end

  defp result_report({:ok, summary}), do: %{status: "ok", summary: summary}
  defp result_report({:error, reason}), do: %{status: "error", reason: reason}

  defp timestamp_for_path do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9T]/, "")
  end

  defp safe_name(value), do: String.replace(value, ~r/[^A-Za-z0-9_-]/, "_")
  defp normalize_path(path), do: String.replace(path, "\\", "/")

  defp json_safe(nil), do: nil

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {json_safe_key(key), json_safe(val)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key), do: key
end

WorldPackReleaseBuildProbe.main(System.argv())
