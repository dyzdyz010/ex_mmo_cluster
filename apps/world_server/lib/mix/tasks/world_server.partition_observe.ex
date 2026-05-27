defmodule Mix.Tasks.WorldServer.PartitionObserve do
  @moduledoc """
  Runs a world-side partition-window observe smoke.

      mix world_server.partition_observe --logical-scene-id 1 --center 1,0,0

  The task writes structured observe logs to
  `.demo/observe/world-partition-window-<logical_scene_id>.log` by default.
  Use `--observe-dir` or `--observe-log` to choose another destination.
  """

  use Mix.Task

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.MapLedger

  @shortdoc "Runs world partition-window CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    center: :string,
    near_radius: :integer,
    halo_radius: :integer,
    near_vertical_radius: :integer,
    halo_vertical_radius: :integer,
    observe_dir: :string,
    observe_log: :string
  ]
  @aliases [
    h: :help,
    s: :logical_scene_id,
    c: :center,
    n: :near_radius,
    a: :halo_radius,
    o: :observe_dir,
    l: :observe_log
  ]

  @doc false
  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      true ->
        run_smoke(opts)
    end
  end

  defp run_smoke(opts) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)
    center_chunk = parse_center!(Keyword.get(opts, :center, "1,0,0"))
    near_radius = Keyword.get(opts, :near_radius, 0)
    halo_radius = Keyword.get(opts, :halo_radius, 1)
    near_vertical_radius = Keyword.get(opts, :near_vertical_radius, near_radius)
    halo_vertical_radius = Keyword.get(opts, :halo_vertical_radius, halo_radius)
    observe_log = observe_log(opts, logical_scene_id)
    previous_log = Application.fetch_env(:world_server, :cli_observe_log)

    {:ok, ledger} = MapLedger.start_link([])

    try do
      File.mkdir_p!(Path.dirname(observe_log))
      File.rm(observe_log)
      Application.put_env(:world_server, :cli_observe_log, observe_log)

      validate_window_options!(
        near_radius,
        halo_radius,
        near_vertical_radius,
        halo_vertical_radius
      )

      seed_partition_sample!(ledger, logical_scene_id)

      window =
        MapLedger.route_window_with_leases(ledger, logical_scene_id, center_chunk,
          near_radius: near_radius,
          halo_radius: halo_radius,
          near_vertical_radius: near_vertical_radius,
          halo_vertical_radius: halo_vertical_radius
        )

      route_index_stats = MapLedger.route_index_stats(ledger)
      summary = summary(window, route_index_stats, observe_log)
      CliObserve.emit("world_partition_window", summary)
      CliObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      CliObserve.flush()
      restore_observe_log(previous_log)
    end
  end

  defp seed_partition_sample!(ledger, logical_scene_id) do
    future_ms = System.system_time(:millisecond) + :timer.minutes(10)

    {:ok, _assignment} =
      MapLedger.put_region(ledger, %{
        logical_scene_id: logical_scene_id,
        region_id: 10,
        bounds_chunk_min: {0, -1, -1},
        bounds_chunk_max: {1, 2, 2},
        owner_scene_instance_ref: 1_000,
        owner_epoch: 0,
        assigned_scene_node: :scene_a@local
      })

    {:ok, _lease} =
      MapLedger.issue_lease(ledger, 10, 1_000,
        lease_id: 100,
        owner_epoch: 1,
        expires_at_ms: future_ms,
        token_version: 1
      )

    {:ok, _assignment} =
      MapLedger.put_region(ledger, %{
        logical_scene_id: logical_scene_id,
        region_id: 20,
        bounds_chunk_min: {1, -1, -1},
        bounds_chunk_max: {2, 2, 2},
        owner_scene_instance_ref: 2_000,
        owner_epoch: 0,
        assigned_scene_node: :scene_b@local
      })

    {:ok, _lease} =
      MapLedger.issue_lease(ledger, 20, 2_000,
        lease_id: 200,
        owner_epoch: 1,
        expires_at_ms: future_ms,
        token_version: 1
      )

    :ok
  end

  defp summary(window, route_index_stats, observe_log) do
    %{
      logical_scene_id: window.logical_scene_id,
      center_chunk: Tuple.to_list(window.center_chunk),
      near_radius: window.near_radius,
      halo_radius: window.halo_radius,
      near_vertical_radius: window.near_vertical_radius,
      halo_vertical_radius: window.halo_vertical_radius,
      near_count: length(window.near_chunks),
      halo_count: length(window.halo_chunks),
      routed_count: Enum.count(window.route_entries, &(&1.status != :missing)),
      missing_count: length(window.missing_chunks),
      region_count: length(window.region_summaries),
      regions: window.region_summaries,
      route_entries: Enum.map(window.route_entries, &route_entry_summary/1),
      route_index_source: :map_ledger,
      route_index_stats: route_index_stats,
      observe_log: observe_log
    }
  end

  defp route_entry_summary(entry) do
    %{
      chunk_coord: Tuple.to_list(entry.chunk_coord),
      tier: entry.tier,
      status: entry.status,
      region_id: entry.region_id,
      lease_id: entry.lease_id,
      assigned_scene_node: entry.assigned_scene_node
    }
  end

  defp summary_line(summary) do
    [
      "world_partition_window=ok",
      "logical_scene_id=#{summary.logical_scene_id}",
      "center=#{Enum.join(summary.center_chunk, ",")}",
      "near_radius=#{summary.near_radius}",
      "halo_radius=#{summary.halo_radius}",
      "near_vertical_radius=#{summary.near_vertical_radius}",
      "halo_vertical_radius=#{summary.halo_vertical_radius}",
      "near=#{summary.near_count}",
      "halo=#{summary.halo_count}",
      "routed=#{summary.routed_count}",
      "missing=#{summary.missing_count}",
      "regions=#{summary.region_count}",
      "route_index_source=#{summary.route_index_source}",
      "route_index_strategy=#{summary.route_index_stats.strategy}",
      "route_index_scenes=#{summary.route_index_stats.scene_count}",
      "route_index_regions=#{summary.route_index_stats.region_count}",
      "route_index_buckets=#{summary.route_index_stats.bucket_count}",
      "route_index_entries=#{summary.route_index_stats.entry_count}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp observe_log(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "world-partition-window-#{logical_scene_id}.log")
    )
  end

  defp validate_window_options!(
         near_radius,
         halo_radius,
         near_vertical_radius,
         halo_vertical_radius
       ) do
    cond do
      not is_integer(near_radius) or near_radius < 0 ->
        Mix.raise("near_radius must be a non-negative integer")

      not is_integer(halo_radius) or halo_radius < near_radius ->
        Mix.raise("halo_radius must be greater than or equal to near_radius")

      not is_integer(near_vertical_radius) or near_vertical_radius < 0 ->
        Mix.raise("near_vertical_radius must be a non-negative integer")

      not is_integer(halo_vertical_radius) or halo_vertical_radius < near_vertical_radius ->
        Mix.raise("halo_vertical_radius must be greater than or equal to near_vertical_radius")

      true ->
        :ok
    end
  end

  defp parse_center!(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [x, y, z] ->
        {String.to_integer(x), String.to_integer(y), String.to_integer(z)}

      _other ->
        Mix.raise("center must be formatted as x,y,z")
    end
  rescue
    ArgumentError -> Mix.raise("center must be formatted as x,y,z")
  end

  defp restore_observe_log({:ok, value}),
    do: Application.put_env(:world_server, :cli_observe_log, value)

  defp restore_observe_log(:error), do: Application.delete_env(:world_server, :cli_observe_log)
end
