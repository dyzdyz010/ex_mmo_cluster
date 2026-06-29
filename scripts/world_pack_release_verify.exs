defmodule WorldPackReleaseVerifyProbe do
  @moduledoc """
  CLI probe for complete world-pack release validation plus sliding-window samples.

  Usage:

      mix run --no-start scripts/world_pack_release_verify.exs --pack-root output/world-pack/full32km
      mix run --no-start scripts/world_pack_release_verify.exs --index small-release-test --build-small-fixture
      mix run --no-start scripts/world_pack_release_verify.exs --pack-root output/world-pack/full32km --window-centers "0,0,0;1,0,0;2,0,0"

  The full32km path validates every expected payload shard on disk before it
  samples runtime-style sliding windows. Missing shards return a non-zero exit
  code and a structured JSON report under `.demo/observe/world-pack-release/`.
  """

  alias MmoContracts.WorldPackIndex
  alias WorldServer.Voxel.WorldPackArtifactBuilder
  alias WorldServer.Voxel.WorldPackReleaseVerifier

  def main(argv) do
    opts = parse_opts(argv)
    Logger.configure(level: :warning)

    index = index!(opts.index)
    pack_root = Path.expand(opts.pack_root || default_pack_root(opts.index), File.cwd!())
    observe_dir = Path.expand(opts.observe_dir, File.cwd!())
    File.mkdir_p!(observe_dir)

    if opts.build_small_fixture do
      build_small_fixture!(index, pack_root)
    end

    manifest = load_manifest(opts.manifest)
    centers = opts.window_centers || default_window_centers(opts.index)
    radius = opts.radius || default_radius(opts.index)
    verify_opts = [window_centers: centers, radius: radius] ++ manifest_opts(manifest)

    started_ms = System.monotonic_time(:millisecond)
    result = WorldPackReleaseVerifier.verify(index, pack_root, verify_opts)
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    manifest_write =
      if opts.write_manifest and match?({:ok, _summary}, result) do
        write_manifest!(index, pack_root, observe_dir)
      end

    report =
      %{
        schema_version: 1,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        note:
          "Authority data must be the complete pack. Window checks sample normal sliding-window loading only.",
        index: index_summary(opts.index, index),
        pack_root: normalize_path(pack_root),
        window_centers: Enum.map(centers, &Tuple.to_list/1),
        radius: radius,
        duration_ms: duration_ms,
        manifest_source: manifest_source(opts.manifest),
        manifest_written: manifest_write,
        result: result_report(result)
      }

    output_path =
      Path.join(
        observe_dir,
        "world_pack_release_#{safe_name(opts.index)}_#{timestamp_for_path()}.json"
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
          manifest: :string,
          window_centers: :string,
          radius: :integer,
          write_manifest: :boolean,
          build_small_fixture: :boolean
        ]
      )

    if invalid != [] do
      raise ArgumentError, "invalid options: #{inspect(invalid)}"
    end

    %{
      index: Keyword.get(opts, :index, "full32km"),
      pack_root: Keyword.get(opts, :pack_root),
      observe_dir: Keyword.get(opts, :observe_dir, ".demo/observe/world-pack-release"),
      manifest: Keyword.get(opts, :manifest),
      window_centers: parse_window_centers(Keyword.get(opts, :window_centers)),
      radius: Keyword.get(opts, :radius),
      write_manifest: Keyword.get(opts, :write_manifest, false),
      build_small_fixture: Keyword.get(opts, :build_small_fixture, false)
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

  defp build_small_fixture!(%WorldPackIndex{logical_scene_id: 91_016} = index, pack_root) do
    File.mkdir_p!(pack_root)
    {:ok, grid} = WorldPackIndex.payload_shard_grid(index)

    snapshot_store = fn 91_016, chunk_coord ->
      {:ok, %{data: :erlang.term_to_binary(chunk_coord)}}
    end

    Enum.each(grid.shard_coords, fn shard_coord ->
      {:ok, _summary} =
        WorldPackArtifactBuilder.build_shard(index, shard_coord,
          output_dir: pack_root,
          snapshot_store: snapshot_store
        )
    end)
  end

  defp build_small_fixture!(_index, _pack_root) do
    raise ArgumentError, "--build-small-fixture requires --index small-release-test"
  end

  defp load_manifest(nil), do: nil

  defp load_manifest(path) do
    path
    |> Path.expand(File.cwd!())
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_manifest!(index, pack_root, observe_dir) do
    {:ok, manifest} = WorldPackReleaseVerifier.build_manifest(index, pack_root)

    manifest_path =
      Path.join(observe_dir, "world_pack_release_manifest_#{timestamp_for_path()}.json")

    File.write!(manifest_path, Jason.encode!(json_safe(manifest), pretty: true))
    normalize_path(manifest_path)
  end

  defp manifest_opts(nil), do: []
  defp manifest_opts(manifest), do: [manifest: manifest]

  defp manifest_source(nil), do: "built_from_pack_root"
  defp manifest_source(path), do: normalize_path(Path.expand(path, File.cwd!()))

  defp default_pack_root(index_name) do
    Path.join([".demo", "observe", "world-pack-release", "#{safe_name(index_name)}-pack"])
  end

  defp default_window_centers("small-release-test"), do: [{0, 0, 0}, {1, 0, 0}]
  defp default_window_centers(_index_name), do: [{0, 0, 0}, {1, 0, 0}, {2, 0, 0}]

  defp default_radius("small-release-test"), do: 1
  defp default_radius(_index_name), do: 3

  defp parse_window_centers(nil), do: nil

  defp parse_window_centers(value) do
    value
    |> String.split(";", trim: true)
    |> Enum.map(fn token ->
      case token |> String.split(",", trim: true) |> Enum.map(&parse_integer!/1) do
        [x, y, z] -> {x, y, z}
        _other -> raise ArgumentError, "invalid --window-centers token #{inspect(token)}"
      end
    end)
  end

  defp parse_integer!(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> raise ArgumentError, "invalid integer #{inspect(value)}"
    end
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

WorldPackReleaseVerifyProbe.main(System.argv())
