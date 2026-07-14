defmodule LegacyXzLodProjectionPressureProbe do
  @moduledoc """
  已归档 XZ heightmap projection 的可复现离线压力探针。

  该脚本先写 canonical XYZ snapshots，再显式调用旧
  `LodProjection.Rebuilder` 测量历史 projection 放大。它不是现役 world-pack、
  launcher 或 runtime 验收入口；缺少 `--allow-legacy-xz` 时拒绝运行。

  Usage:

      mix run scripts/legacy/legacy_xz_lod_projection_pressure_probe.exs --allow-legacy-xz
      mix run scripts/legacy/legacy_xz_lod_projection_pressure_probe.exs --allow-legacy-xz --cases single,tile343_canonical --cleanup-after
  """

  alias DataService.Repo
  alias MmoContracts.VoxelSpatialContract
  alias SceneServer.Voxel.LodProjection.Rebuilder
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.SceneNodeRegistry
  alias WorldServer.Voxel.WorldPackBootstrapper

  @full_32km %{
    chunk_min: VoxelSpatialContract.full32km_chunk_min(),
    chunk_max: VoxelSpatialContract.full32km_chunk_max(),
    chunk_count: 444_596_224,
    horizontal_chunk_count: 4_194_304,
    vertical_chunk_layers: 106,
    chunk_edge_m: 16
  }

  @lod_cells_per_horizontal_chunk 85
  @radius VoxelSpatialContract.near_chunk_radius()

  def main(argv) do
    opts = parse_opts(argv)
    require_legacy_offline!(opts)
    Logger.configure(level: :warning)
    ensure_apps!(opts)

    output_dir = Path.expand(opts.output_dir, File.cwd!())
    File.mkdir_p!(output_dir)

    scene_base = opts.scene_base

    cases =
      opts.cases
      |> Enum.with_index()
      |> Enum.map(fn {name, index} ->
        spec = case_spec!(name)
        run_case(spec, scene_base + index, opts)
      end)

    report = %{
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      note:
        "LEGACY/OFFLINE XZ heightmap projection pressure audit; not a current world-pack acceptance result.",
      full_32km: full_world_summary(),
      sliding_window: sliding_window_summary(),
      cases: cases,
      extrapolations: Enum.map(cases, &extrapolate_case/1)
    }

    output_path =
      Path.join(output_dir, "legacy_xz_lod_projection_pressure_#{timestamp_for_path()}.json")

    File.write!(output_path, Jason.encode!(report, pretty: true))

    IO.puts(
      Jason.encode!(Map.put(report, :output_path, normalize_path(output_path)), pretty: true)
    )
  end

  defp parse_opts(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv,
        switches: [
          cases: :string,
          scene_base: :integer,
          output_dir: :string,
          cleanup_after: :boolean,
          migrate: :boolean,
          seed: :integer,
          allow_legacy_xz: :boolean
        ]
      )

    if invalid != [] do
      raise ArgumentError, "invalid options: #{inspect(invalid)}"
    end

    %{
      cases:
        opts
        |> Keyword.get(:cases, "single,cube64,plane256,vertical100")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1),
      scene_base: Keyword.get(opts, :scene_base, default_scene_base()),
      output_dir: Keyword.get(opts, :output_dir, ".demo/observe/legacy-xz-lod-pressure"),
      cleanup_after: Keyword.get(opts, :cleanup_after, false),
      migrate: Keyword.get(opts, :migrate, true),
      seed: Keyword.get(opts, :seed, 1337),
      allow_legacy_xz: Keyword.get(opts, :allow_legacy_xz, false)
    }
  end

  defp default_scene_base do
    970_000 + rem(System.unique_integer([:positive]), 10_000)
  end

  defp ensure_apps!(opts) do
    Enum.each([:postgrex, :ecto_sql, :data_service, :scene_server], fn app ->
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

  defp case_spec!("single") do
    %{name: "single", chunk_min: {0, 0, 0}, chunk_max: {0, 0, 0}}
  end

  defp case_spec!("cube64") do
    %{name: "cube64", chunk_min: {0, 0, 0}, chunk_max: {3, 3, 3}}
  end

  defp case_spec!("plane256") do
    %{name: "plane256", chunk_min: {0, 0, 0}, chunk_max: {15, 0, 15}}
  end

  defp case_spec!("vertical100") do
    %{name: "vertical100", chunk_min: {0, -7, 0}, chunk_max: {0, 92, 0}}
  end

  defp case_spec!("tile343_canonical") do
    %{name: "tile343_canonical", chunk_min: {0, 0, 0}, chunk_max: {6, 6, 6}}
  end

  defp case_spec!(other) do
    raise ArgumentError,
          "unknown pressure case #{inspect(other)}; expected single,cube64,plane256,vertical100,tile343_canonical"
  end

  defp run_case(spec, scene_id, opts) do
    cleanup_scene!(scene_id)

    {:ok, registry} =
      SceneNodeRegistry.start_link(name: unique_name(:world_pack_pressure_scene_registry))

    :ok = SceneNodeRegistry.register_scene_node(registry, node())

    {:ok, ledger} =
      MapLedger.start_link(
        name: unique_name(:world_pack_pressure_ledger),
        write_token_store: DataService.Voxel.WriteTokenStore,
        scene_node_registry: registry,
        region_directory: DataService.Voxel.RegionDirectoryStore
      )

    before_metrics = db_metrics(scene_id)
    chunk_count = chunk_count(spec.chunk_min, spec.chunk_max)

    started = System.monotonic_time(:millisecond)

    canonical_result =
      WorldPackBootstrapper.materialize_once(
        logical_scene_id: scene_id,
        chunk_min: spec.chunk_min,
        chunk_max: spec.chunk_max,
        max_chunks: chunk_count,
        batch_size: 64,
        ledger: ledger,
        seed: opts.seed,
        version: "pressure-#{spec.name}",
        content_version: "pressure-#{spec.name}-scene-#{scene_id}",
        publish_auth_pack?: false
      )

    result = rebuild_legacy_projection(scene_id, canonical_result)

    duration_ms = System.monotonic_time(:millisecond) - started
    after_metrics = db_metrics(scene_id)

    case result do
      {:ok, summary} ->
        case_report =
          %{
            name: spec.name,
            logical_scene_id: scene_id,
            chunk_min: Tuple.to_list(spec.chunk_min),
            chunk_max: Tuple.to_list(spec.chunk_max),
            planned_chunk_count: chunk_count,
            legacy_projection_mode: "explicit_offline_rebuild",
            duration_ms: duration_ms,
            chunks_per_second: per_second(chunk_count, duration_ms),
            summary: json_safe(summary),
            before: before_metrics,
            after: after_metrics,
            delta: metric_delta(before_metrics, after_metrics)
          }

        if opts.cleanup_after do
          cleanup_scene!(scene_id)
          Map.put(case_report, :cleanup_after, true)
        else
          Map.put(case_report, :cleanup_after, false)
        end

      {:error, reason} ->
        %{
          name: spec.name,
          logical_scene_id: scene_id,
          chunk_min: Tuple.to_list(spec.chunk_min),
          chunk_max: Tuple.to_list(spec.chunk_max),
          planned_chunk_count: chunk_count,
          legacy_projection_mode: "explicit_offline_rebuild",
          duration_ms: duration_ms,
          error: inspect(reason),
          before: before_metrics,
          after: after_metrics,
          delta: metric_delta(before_metrics, after_metrics)
        }
    end
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp rebuild_legacy_projection(scene_id, {:ok, canonical_summary}) do
    case Rebuilder.rebuild_scene(scene_id) do
      {:ok, projection_summary} ->
        {:ok,
         %{
           canonical: canonical_summary,
           legacy_xz_projection: projection_summary
         }}

      {:error, reason} ->
        {:error, {:legacy_xz_lod_projection_rebuild_failed, reason}}
    end
  end

  defp rebuild_legacy_projection(_scene_id, {:error, reason}), do: {:error, reason}

  defp require_legacy_offline!(%{allow_legacy_xz: true}), do: :ok

  defp require_legacy_offline!(_opts) do
    raise ArgumentError,
          "XZ LOD projection is archived; pass --allow-legacy-xz for an explicit offline audit"
  end

  defp cleanup_scene!(scene_id) do
    Enum.each(cleanup_tables(), fn table ->
      Repo.query!("DELETE FROM #{table} WHERE logical_scene_id = $1", [scene_id])
    end)
  end

  defp cleanup_tables do
    [
      "voxel_outbox",
      "voxel_command_log",
      "voxel_lod_heightmap_cells",
      "voxel_chunks",
      "voxel_write_tokens",
      "voxel_region_epochs",
      "voxel_region_directory"
    ]
  end

  defp db_metrics(scene_id) do
    %{
      snapshot: scene_snapshot_metrics(scene_id),
      lod: scene_lod_metrics(scene_id),
      relation_bytes: relation_bytes()
    }
  end

  defp scene_snapshot_metrics(scene_id) do
    %Postgrex.Result{rows: [[count, payload_bytes, avg_payload_bytes, min_payload, max_payload]]} =
      Repo.query!(
        """
        SELECT
          count(*),
          COALESCE(sum(octet_length(data)), 0),
          COALESCE(avg(octet_length(data)), 0),
          COALESCE(min(octet_length(data)), 0),
          COALESCE(max(octet_length(data)), 0)
        FROM voxel_chunks
        WHERE logical_scene_id = $1
        """,
        [scene_id]
      )

    %{
      chunk_count: count,
      payload_bytes: decimal_to_float_or_integer(payload_bytes),
      avg_payload_bytes: decimal_to_float_or_integer(avg_payload_bytes),
      min_payload_bytes: min_payload,
      max_payload_bytes: max_payload
    }
  end

  defp scene_lod_metrics(scene_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT stride, count(*)
        FROM voxel_lod_heightmap_cells
        WHERE logical_scene_id = $1
        GROUP BY stride
        ORDER BY stride
        """,
        [scene_id]
      )

    by_stride =
      Map.new(rows, fn [stride, count] ->
        {Integer.to_string(stride), count}
      end)

    %{
      total_cell_count: Enum.reduce(by_stride, 0, fn {_stride, count}, acc -> acc + count end),
      by_stride: by_stride
    }
  end

  defp relation_bytes do
    Map.new(cleanup_tables(), fn table ->
      %Postgrex.Result{rows: [[bytes]]} =
        Repo.query!("SELECT COALESCE(pg_total_relation_size(to_regclass($1)), 0)", [table])

      {table, bytes}
    end)
  end

  defp metric_delta(before_metrics, after_metrics) do
    %{
      snapshot_chunk_count:
        after_metrics.snapshot.chunk_count - before_metrics.snapshot.chunk_count,
      snapshot_payload_bytes:
        after_metrics.snapshot.payload_bytes - before_metrics.snapshot.payload_bytes,
      lod_cell_count: after_metrics.lod.total_cell_count - before_metrics.lod.total_cell_count,
      relation_bytes:
        Map.new(after_metrics.relation_bytes, fn {table, after_bytes} ->
          before_bytes = Map.get(before_metrics.relation_bytes, table, 0)
          {table, after_bytes - before_bytes}
        end)
    }
  end

  defp full_world_summary do
    Map.merge(@full_32km, %{
      chunk_min: Tuple.to_list(@full_32km.chunk_min),
      chunk_max: Tuple.to_list(@full_32km.chunk_max),
      final_lod_cell_count: @full_32km.horizontal_chunk_count * @lod_cells_per_horizontal_chunk,
      archived_inline_lod_upsert_attempts:
        @full_32km.chunk_count * @lod_cells_per_horizontal_chunk,
      archived_rebuild_lod_upsert_attempts:
        @full_32km.horizontal_chunk_count * @lod_cells_per_horizontal_chunk,
      current_per_chunk_file_count: @full_32km.chunk_count,
      note:
        "XYZ chunk counts are current; all LOD cell estimates in this legacy report describe the archived XZ projection only."
    })
  end

  defp sliding_window_summary do
    centers = [
      {3, 3, 3},
      {10, 3, 3},
      {17, 3, 3},
      {1011, 3, 3},
      {1011, 3, 1011},
      {-1012, 3, -1012}
    ]

    windows =
      centers
      |> Enum.map(fn center ->
        chunks = window_chunks(center, @radius)

        %{
          center: Tuple.to_list(center),
          radius: @radius,
          chunk_count: length(chunks),
          within_full_32km_bounds?: Enum.all?(chunks, &inside_bounds?(&1, @full_32km))
        }
      end)

    transitions =
      centers
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] ->
        from_chunks = MapSet.new(window_chunks(from, @radius))
        to_chunks = MapSet.new(window_chunks(to, @radius))

        %{
          from: Tuple.to_list(from),
          to: Tuple.to_list(to),
          entering_chunks: MapSet.size(MapSet.difference(to_chunks, from_chunks)),
          leaving_chunks: MapSet.size(MapSet.difference(from_chunks, to_chunks)),
          kept_chunks: MapSet.size(MapSet.intersection(from_chunks, to_chunks))
        }
      end)

    %{
      radius: @radius,
      per_window_chunk_count: cube(@radius * 2 + 1),
      expected_one_tile_slab_chunks:
        (@radius * 2 + 1) * (@radius * 2 + 1) *
          VoxelSpatialContract.tile_size_chunks(),
      two_x_tile_moves_required_x_bounds: [-7, 27],
      windows: windows,
      transitions: transitions
    }
  end

  defp window_chunks({cx, cy, cz}, radius) do
    for x <- (cx - radius)..(cx + radius),
        y <- (cy - radius)..(cy + radius),
        z <- (cz - radius)..(cz + radius) do
      {x, y, z}
    end
  end

  defp inside_bounds?({x, y, z}, %{
         chunk_min: {min_x, min_y, min_z},
         chunk_max: {max_x, max_y, max_z}
       }) do
    x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and z <= max_z
  end

  defp extrapolate_case(%{error: _} = case_report) do
    %{case: case_report.name, status: "not_extrapolated", reason: "case_failed"}
  end

  defp extrapolate_case(case_report) do
    chunk_count = max(case_report.delta.snapshot_chunk_count, 1)
    duration_per_chunk_ms = case_report.duration_ms / chunk_count
    payload_per_chunk = case_report.delta.snapshot_payload_bytes / chunk_count

    %{
      case: case_report.name,
      basis_chunk_count: chunk_count,
      duration_per_chunk_ms: duration_per_chunk_ms,
      projected_full_duration_seconds: duration_per_chunk_ms * @full_32km.chunk_count / 1_000,
      projected_snapshot_payload_bytes: payload_per_chunk * @full_32km.chunk_count,
      projected_local_vcsnap_payload_bytes: (payload_per_chunk + 1) * @full_32km.chunk_count,
      projected_final_lod_cell_count:
        @full_32km.horizontal_chunk_count * @lod_cells_per_horizontal_chunk,
      projected_archived_inline_lod_upsert_attempts:
        @full_32km.chunk_count * @lod_cells_per_horizontal_chunk,
      projected_archived_rebuild_lod_upsert_attempts:
        @full_32km.horizontal_chunk_count * @lod_cells_per_horizontal_chunk,
      projected_per_chunk_file_count: @full_32km.chunk_count
    }
  end

  defp chunk_count({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    (max_x - min_x + 1) * (max_y - min_y + 1) * (max_z - min_z + 1)
  end

  defp per_second(_count, 0), do: nil
  defp per_second(count, duration_ms), do: count * 1_000 / duration_ms

  defp cube(value), do: value * value * value

  defp decimal_to_float_or_integer(%Decimal{} = value) do
    rounded = Decimal.round(value, 0)

    if Decimal.equal?(value, rounded) do
      Decimal.to_integer(value)
    else
      Decimal.to_float(value)
    end
  end

  defp decimal_to_float_or_integer(value), do: value

  defp timestamp_for_path do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9T]/, "")
  end

  defp normalize_path(path), do: String.replace(path, "\\", "/")

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {json_safe_key(key), json_safe(val)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: Tuple.to_list(value)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key), do: key
end

LegacyXzLodProjectionPressureProbe.main(System.argv())
