defmodule WorldPackMaterializeShardsProbe do
  @moduledoc """
  CLI probe for resumable full-authority world-pack materialization.

  Usage:

      mix run --no-start scripts/world_pack_materialize_shards.exs --index full32km --max-shards 1
      mix run --no-start scripts/world_pack_materialize_shards.exs --index full32km --shard-coords "64,0,64"
      mix run --no-start scripts/world_pack_materialize_shards.exs --index full32km --all-shards

  By default this uses deferred LOD projection (`lod_projection?: false`) so
  full-pack import writes canonical chunks first. Re-run the same command with
  `--max-shards N`: already-ready shards are skipped and do not consume the
  materialization limit.
  """

  alias DataService.Repo
  alias MmoContracts.WorldPackIndex
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.SceneNodeRegistry
  alias WorldServer.Voxel.WorldPackBootstrapper
  alias WorldServer.Voxel.WorldPackShardMaterializer

  def main(argv) do
    opts = parse_opts(argv)
    Logger.configure(level: :warning)
    validate_run_scope!(opts)
    ensure_apps!(opts)

    index = index!(opts.index)
    observe_dir = Path.expand(opts.observe_dir, File.cwd!())
    File.mkdir_p!(observe_dir)

    {:ok, registry} = SceneNodeRegistry.start_link(name: unique_name(:world_pack_shard_registry))
    :ok = SceneNodeRegistry.register_scene_node(registry, node())

    {:ok, ledger} =
      MapLedger.start_link(
        name: unique_name(:world_pack_shard_ledger),
        write_token_store: DataService.Voxel.WriteTokenStore,
        scene_node_registry: registry,
        region_directory: DataService.Voxel.RegionDirectoryStore
      )

    materializer = fn materializer_opts ->
      materializer_opts
      |> Keyword.put(:ledger, ledger)
      |> WorldPackBootstrapper.materialize_once()
    end

    materialize_opts =
      [
        materializer: materializer,
        batch_size: opts.batch_size,
        seed: opts.seed,
        materializer_opts: materializer_opts(opts)
      ]
      |> maybe_put(:max_shards, opts.max_shards)
      |> maybe_put(:shard_coords, opts.shard_coords)

    started_ms = System.monotonic_time(:millisecond)
    result = run_materialize(index, materialize_opts)
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    report = %{
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      note:
        "Canonical authority materialization only. Runtime loading remains sliding-window pack reads plus online diff.",
      index: index_summary(opts.index, index),
      requested_max_shards: opts.max_shards,
      requested_all_shards: opts.all_shards,
      requested_shard_coords: Enum.map(opts.shard_coords || [], &Tuple.to_list/1),
      batch_size: opts.batch_size,
      lod_projection_mode: if(opts.inline_lod_projection, do: "inline", else: "deferred"),
      duration_ms: duration_ms,
      result: result_report(result)
    }

    output_path =
      Path.join(
        observe_dir,
        "world_pack_materialize_shards_#{safe_name(opts.index)}_#{timestamp_for_path()}.json"
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
          observe_dir: :string,
          max_shards: :integer,
          shard_coords: :string,
          all_shards: :boolean,
          batch_size: :integer,
          seed: :integer,
          migrate: :boolean,
          inline_lod_projection: :boolean
        ]
      )

    if invalid != [] do
      raise ArgumentError, "invalid options: #{inspect(invalid)}"
    end

    %{
      index: Keyword.get(opts, :index, "full32km"),
      observe_dir: Keyword.get(opts, :observe_dir, ".demo/observe/world-pack-materialize"),
      max_shards: Keyword.get(opts, :max_shards),
      shard_coords: parse_optional_coords(Keyword.get(opts, :shard_coords)),
      all_shards: Keyword.get(opts, :all_shards, false),
      batch_size: Keyword.get(opts, :batch_size, 64),
      seed: Keyword.get(opts, :seed, 1337),
      migrate: Keyword.get(opts, :migrate, true),
      inline_lod_projection: Keyword.get(opts, :inline_lod_projection, false)
    }
  end

  defp validate_run_scope!(%{all_shards: true}), do: :ok
  defp validate_run_scope!(%{max_shards: max}) when is_integer(max) and max > 0, do: :ok
  defp validate_run_scope!(%{shard_coords: coords}) when is_list(coords) and coords != [], do: :ok

  defp validate_run_scope!(_opts) do
    raise ArgumentError,
          "refusing to materialize without --max-shards, --shard-coords, or --all-shards"
  end

  defp materializer_opts(%{inline_lod_projection: true}), do: []
  defp materializer_opts(_opts), do: [lod_projection?: false]

  defp ensure_apps!(opts) do
    Enum.each([:postgrex, :ecto_sql, :data_service, :scene_server], fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> :ok
        {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
      end
    end)

    if opts.migrate do
      migrations_path = Path.expand("../apps/data_service/priv/repo/migrations", __DIR__)

      {:ok, _repo, migrated} =
        Ecto.Migrator.with_repo(Repo, fn repo ->
          Ecto.Migrator.run(repo, migrations_path, :up, all: true)
        end)

      IO.puts("data_service migrations checked; newly migrated=#{length(migrated)}")
    end
  end

  defp run_materialize(index, opts) do
    WorldPackShardMaterializer.materialize(index, opts)
  rescue
    exception ->
      {:error,
       {:world_pack_shard_materialize_exception,
        %{
          exception: inspect(exception.__struct__),
          message: Exception.message(exception)
        }}}
  catch
    kind, reason ->
      {:error,
       {:world_pack_shard_materialize_exit,
        %{
          kind: inspect(kind),
          reason: inspect(reason)
        }}}
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

  defp parse_optional_coords(nil), do: nil

  defp parse_optional_coords(value) do
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

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
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

WorldPackMaterializeShardsProbe.main(System.argv())
