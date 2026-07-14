defmodule LegacyXzSvoSourceMaterializeProbe do
  @moduledoc """
  已归档 XZ SVO source 的显式离线 coverage/materialization probe。

  Usage:

      mix run --no-start scripts/legacy/legacy_xz_svo_source_materialize.exs --allow-legacy-xz --dry-run
      mix run --no-start scripts/legacy/legacy_xz_svo_source_materialize.exs --allow-legacy-xz --radius-tiles 0 --near-skip-radius-tiles -1 --max-chunks 400

  该入口不是现役部署链；缺少 `--allow-legacy-xz` 时拒绝运行。
  """

  alias DataService.Repo
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.SceneNodeRegistry
  alias WorldServer.Voxel.WorldPackBootstrapper
  alias WorldServer.Voxel.Legacy.XzSvoSourceMaterializer

  def main(argv) do
    opts = parse_opts(argv)
    require_legacy_offline!(opts)
    Logger.configure(level: :warning)
    ensure_apps!(opts)

    observe_dir = Path.expand(opts.observe_dir, File.cwd!())
    File.mkdir_p!(observe_dir)

    started_ms = System.monotonic_time(:millisecond)
    result = run_probe(opts)
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    report = %{
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      mode: if(opts.dry_run, do: "dry_run", else: "materialize"),
      note:
        "LEGACY/OFFLINE XZ SVO source audit only; not a current launcher or runtime contract.",
      request: request_summary(opts),
      duration_ms: duration_ms,
      result: result_report(result)
    }

    output_path =
      Path.join(
        observe_dir,
        "legacy_xz_svo_source_#{if(opts.dry_run, do: "coverage", else: "materialize")}_#{timestamp_for_path()}.json"
      )

    File.write!(output_path, Jason.encode!(json_safe(report), pretty: true))

    IO.puts(
      Jason.encode!(json_safe(Map.put(report, :output_path, normalize_path(output_path))),
        pretty: true
      )
    )

    case result do
      {:ok, %{status: :ready}} -> System.halt(0)
      {:ok, _summary} -> System.halt(1)
      {:error, _reason} -> System.halt(1)
    end
  end

  defp parse_opts(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv,
        switches: [
          logical_scene_id: :integer,
          center_tile: :string,
          radius_tiles: :integer,
          near_skip_radius_tiles: :integer,
          macro_cell_tiles: :integer,
          max_chunks: :integer,
          batch_size: :integer,
          seed: :integer,
          content_version: :string,
          observe_dir: :string,
          dry_run: :boolean,
          migrate: :boolean,
          allow_legacy_xz: :boolean
        ]
      )

    if invalid != [] do
      raise ArgumentError, "invalid options: #{inspect(invalid)}"
    end

    %{
      logical_scene_id: Keyword.get(opts, :logical_scene_id, 91_015),
      center_tile: opts |> Keyword.get(:center_tile, "0,0,0") |> parse_coord!(),
      radius_tiles: Keyword.get(opts, :radius_tiles, 72),
      near_skip_radius_tiles: Keyword.get(opts, :near_skip_radius_tiles, 1),
      macro_cell_tiles: Keyword.get(opts, :macro_cell_tiles, 1),
      max_chunks: Keyword.get(opts, :max_chunks, 100_000),
      batch_size: Keyword.get(opts, :batch_size, 64),
      seed: Keyword.get(opts, :seed, 1337),
      content_version: Keyword.get(opts, :content_version, "legacy-xz-svo-source@1"),
      observe_dir: Keyword.get(opts, :observe_dir, ".demo/observe/legacy-xz-svo-source"),
      dry_run: Keyword.get(opts, :dry_run, false),
      migrate: Keyword.get(opts, :migrate, true),
      allow_legacy_xz: Keyword.get(opts, :allow_legacy_xz, false)
    }
  end

  defp run_probe(%{dry_run: true} = opts) do
    opts
    |> materializer_opts()
    |> XzSvoSourceMaterializer.coverage()
  rescue
    exception ->
      {:error,
       {:world_pack_svo_source_coverage_exception,
        %{exception: inspect(exception.__struct__), message: Exception.message(exception)}}}
  catch
    kind, reason ->
      {:error,
       {:world_pack_svo_source_coverage_exit, %{kind: inspect(kind), reason: inspect(reason)}}}
  end

  defp run_probe(opts) do
    {:ok, registry} = SceneNodeRegistry.start_link(name: unique_name(:svo_source_registry))
    :ok = SceneNodeRegistry.register_scene_node(registry, node())

    {:ok, ledger} =
      MapLedger.start_link(
        name: unique_name(:svo_source_ledger),
        write_token_store: DataService.Voxel.WriteTokenStore,
        scene_node_registry: registry,
        region_directory: DataService.Voxel.RegionDirectoryStore
      )

    materializer = fn materializer_opts ->
      materializer_opts
      |> Keyword.put(:ledger, ledger)
      |> WorldPackBootstrapper.materialize_once()
    end

    opts
    |> materializer_opts()
    |> Keyword.put(:materializer, materializer)
    |> XzSvoSourceMaterializer.materialize()
  rescue
    exception ->
      {:error,
       {:world_pack_svo_source_materialize_exception,
        %{exception: inspect(exception.__struct__), message: Exception.message(exception)}}}
  catch
    kind, reason ->
      {:error,
       {:world_pack_svo_source_materialize_exit, %{kind: inspect(kind), reason: inspect(reason)}}}
  end

  defp materializer_opts(opts) do
    [
      logical_scene_id: opts.logical_scene_id,
      center_tile: opts.center_tile,
      radius_tiles: opts.radius_tiles,
      near_skip_radius_tiles: opts.near_skip_radius_tiles,
      macro_cell_tiles: opts.macro_cell_tiles,
      max_chunks: opts.max_chunks,
      batch_size: opts.batch_size,
      seed: opts.seed,
      content_version: opts.content_version,
      legacy_offline?: true
    ]
  end

  defp require_legacy_offline!(%{allow_legacy_xz: true}), do: :ok

  defp require_legacy_offline!(_opts) do
    raise ArgumentError,
          "legacy XZ SVO source tooling is archived; pass --allow-legacy-xz for an explicit offline audit"
  end

  defp ensure_apps!(opts) do
    apps =
      if opts.dry_run do
        [:postgrex, :ecto_sql, :data_service]
      else
        [:postgrex, :ecto_sql, :data_service, :scene_server]
      end

    Enum.each(apps, fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> :ok
        {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
      end
    end)

    if opts.migrate do
      migrations_path = Path.expand("../../apps/data_service/priv/repo/migrations", __DIR__)

      {:ok, _repo, migrated} =
        Ecto.Migrator.with_repo(Repo, fn repo ->
          Ecto.Migrator.run(repo, migrations_path, :up, all: true)
        end)

      IO.puts("data_service migrations checked; newly migrated=#{length(migrated)}")
    end
  end

  defp request_summary(opts) do
    %{
      logical_scene_id: opts.logical_scene_id,
      center_tile: Tuple.to_list(opts.center_tile),
      radius_tiles: opts.radius_tiles,
      near_skip_radius_tiles: opts.near_skip_radius_tiles,
      macro_cell_tiles: opts.macro_cell_tiles,
      max_chunks: opts.max_chunks,
      batch_size: opts.batch_size,
      content_version: opts.content_version,
      contract: "legacy_xz_svo_source"
    }
  end

  defp parse_coord!(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&parse_integer!/1) do
      [x, y, z] -> {x, y, z}
      _other -> raise ArgumentError, "invalid coord #{inspect(value)}"
    end
  end

  defp parse_integer!(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> raise ArgumentError, "invalid integer #{inspect(value)}"
    end
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
  defp result_report({:ok, summary}), do: %{status: "ok", summary: summary}
  defp result_report({:error, reason}), do: %{status: "error", reason: reason}

  defp timestamp_for_path do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9T]/, "")
  end

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

LegacyXzSvoSourceMaterializeProbe.main(System.argv())
