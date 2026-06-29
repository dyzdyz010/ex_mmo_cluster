defmodule WorldPackAuthorityCoverageProbe do
  @moduledoc """
  CLI probe for canonical world-pack authority coverage.

  Usage:

      mix run --no-start scripts/world_pack_authority_coverage.exs
      mix run --no-start scripts/world_pack_authority_coverage.exs --window-centers "0,0,0;1,0,0;2,0,0"
      mix run --no-start scripts/world_pack_authority_coverage.exs --shard-coords "0,0,0;64,0,64;127,0,127"

  The probe is read-only: it reports current canonical snapshot coverage and
  sampled sliding-window/shard gaps. It never materializes missing chunks.
  """

  alias MmoContracts.WorldPackIndex
  alias WorldServer.Voxel.WorldPackAuthorityCoverage

  def main(argv) do
    opts = parse_opts(argv)
    Logger.configure(level: :warning)
    ensure_apps!()

    index = index!(opts.index)
    observe_dir = Path.expand(opts.observe_dir, File.cwd!())
    File.mkdir_p!(observe_dir)

    verify_opts =
      [
        radius: opts.radius,
        window_centers: opts.window_centers
      ]
      |> maybe_put(:shard_coords, opts.shard_coords)

    started_ms = System.monotonic_time(:millisecond)
    result = run_verify(index, verify_opts)
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    report = %{
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      note:
        "Authority coverage is read-only. Runtime loading remains normal sliding-window pack reads plus online diff.",
      index: index_summary(opts.index, index),
      duration_ms: duration_ms,
      result: result_report(result)
    }

    output_path =
      Path.join(
        observe_dir,
        "world_pack_authority_coverage_#{safe_name(opts.index)}_#{timestamp_for_path()}.json"
      )

    File.write!(output_path, Jason.encode!(json_safe(report), pretty: true))

    IO.puts(
      Jason.encode!(json_safe(Map.put(report, :output_path, normalize_path(output_path))),
        pretty: true
      )
    )

    case result do
      {:ok, %{status: :ready}} -> System.halt(0)
      {:ok, %{status: :incomplete}} -> System.halt(1)
      {:error, _reason} -> System.halt(1)
    end
  end

  defp parse_opts(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv,
        switches: [
          index: :string,
          observe_dir: :string,
          radius: :integer,
          window_centers: :string,
          shard_coords: :string
        ]
      )

    if invalid != [] do
      raise ArgumentError, "invalid options: #{inspect(invalid)}"
    end

    %{
      index: Keyword.get(opts, :index, "full32km"),
      observe_dir: Keyword.get(opts, :observe_dir, ".demo/observe/world-pack-authority-coverage"),
      radius: Keyword.get(opts, :radius, 3),
      window_centers:
        opts
        |> Keyword.get(:window_centers, "0,0,0;1,0,0;2,0,0")
        |> parse_coords(),
      shard_coords: parse_optional_coords(Keyword.get(opts, :shard_coords))
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

  defp run_verify(index, verify_opts) do
    WorldPackAuthorityCoverage.verify(index, verify_opts)
  rescue
    exception ->
      {:error,
       {:world_pack_authority_coverage_exception,
        %{
          exception: inspect(exception.__struct__),
          message: Exception.message(exception)
        }}}
  catch
    kind, reason ->
      {:error,
       {:world_pack_authority_coverage_exit,
        %{
          kind: inspect(kind),
          reason: inspect(reason)
        }}}
  end

  defp ensure_apps! do
    Enum.each([:postgrex, :ecto_sql, :data_service], fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> :ok
        {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
      end
    end)
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
      expected_payload_shards: grid.shard_count,
      shard_min: Tuple.to_list(grid.shard_min),
      shard_max: Tuple.to_list(grid.shard_max)
    }
  end

  defp result_report({:ok, report}), do: %{status: "ok", report: report}
  defp result_report({:error, reason}), do: %{status: "error", reason: reason}

  defp parse_optional_coords(nil), do: nil
  defp parse_optional_coords(value), do: parse_coords(value)

  defp parse_coords(value) do
    value
    |> String.split(";", trim: true)
    |> Enum.map(fn token ->
      case token |> String.split(",", trim: true) |> Enum.map(&parse_integer!/1) do
        [x, y, z] -> {x, y, z}
        _other -> raise ArgumentError, "invalid coord token #{inspect(token)}"
      end
    end)
  end

  defp parse_integer!(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> raise ArgumentError, "invalid integer #{inspect(value)}"
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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

WorldPackAuthorityCoverageProbe.main(System.argv())
