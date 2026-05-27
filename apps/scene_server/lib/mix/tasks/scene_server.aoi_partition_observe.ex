defmodule Mix.Tasks.SceneServer.AoiPartitionObserve do
  @moduledoc """
  Runs a scene-side AOI partition-interest planner observe smoke.

      mix scene_server.aoi_partition_observe --logical-scene-id 1 --cid 42 --center 0,0,0

  The task consumes a World partition-window shaped sample and proves that AOI
  can derive near/halo query and remote mirror request intent without trusting
  client region hints.
  """

  use Mix.Task

  alias SceneServer.Aoi.PartitionInterest
  alias SceneServer.CliObserve

  @shortdoc "Runs AOI partition-interest CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    cid: :integer,
    center: :string,
    observe_dir: :string,
    observe_log: :string
  ]
  @aliases [h: :help, s: :logical_scene_id, c: :cid, o: :observe_dir, l: :observe_log]

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
    {:ok, _apps} = Application.ensure_all_started(:scene_server)

    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)
    cid = Keyword.get(opts, :cid, 42)
    center_chunk = parse_center!(Keyword.get(opts, :center, "0,0,0"))
    observe_log = observe_path(opts, logical_scene_id)
    previous_log = Application.fetch_env(:scene_server, :cli_observe_log)

    try do
      File.mkdir_p!(Path.dirname(observe_log))
      File.rm(observe_log)
      Application.put_env(:scene_server, :cli_observe_log, observe_log)

      plan =
        PartitionInterest.plan(%{
          cid: cid,
          client_region_id: 999,
          local_scene_node: :"scene-a@local",
          partition_window: sample_partition_window(logical_scene_id, center_chunk)
        })

      summary = summary(plan, observe_log)
      CliObserve.emit("scene_aoi_partition_interest_planned", summary)
      CliObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      CliObserve.flush()
      restore_observe_log(previous_log)
    end
  end

  defp sample_partition_window(logical_scene_id, {x, y, z} = center_chunk) do
    %{
      logical_scene_id: logical_scene_id,
      center_chunk: center_chunk,
      near_radius: 0,
      halo_radius: 1,
      route_entries: [
        %{
          chunk_coord: center_chunk,
          tier: :near,
          status: :assigned,
          region_id: 10,
          lease_id: 100,
          assigned_scene_node: :"scene-a@local"
        },
        %{
          chunk_coord: {x + 1, y, z},
          tier: :halo,
          status: :assigned,
          region_id: 20,
          lease_id: 200,
          assigned_scene_node: :"scene-b@local"
        },
        %{
          chunk_coord: {x - 1, y, z},
          tier: :halo,
          status: :region_without_lease,
          region_id: 30,
          lease_id: nil,
          assigned_scene_node: :"scene-c@local"
        },
        %{
          chunk_coord: {x, y + 1, z},
          tier: :halo,
          status: :missing,
          region_id: nil,
          lease_id: nil,
          assigned_scene_node: nil
        }
      ]
    }
  end

  defp summary(plan, observe_log) do
    %{
      cid: plan.cid,
      logical_scene_id: plan.logical_scene_id,
      local_scene_node: plan.local_scene_node,
      center_chunk: Tuple.to_list(plan.center_chunk),
      near_radius: plan.near_radius,
      halo_radius: plan.halo_radius,
      near_query_count: plan.near_query_count,
      halo_query_count: plan.halo_query_count,
      remote_mirror_request_count: plan.remote_mirror_request_count,
      skipped_count: plan.skipped_count,
      missing_count: plan.missing_count,
      unleased_count: plan.unleased_count,
      region_query_count: length(plan.region_query_summaries),
      region_query_summaries: Enum.map(plan.region_query_summaries, &summarize_region/1),
      query_entries: Enum.map(plan.query_entries, &summarize_query/1),
      remote_mirror_requests:
        Enum.map(plan.remote_mirror_requests, &summarize_remote_mirror_request/1),
      skipped_entries: Enum.map(plan.skipped_entries, &summarize_skip/1),
      observe_log: observe_log
    }
  end

  defp summarize_region(summary) do
    %{
      region_id: summary.region_id,
      assigned_scene_node: summary.assigned_scene_node,
      near_count: summary.near_count,
      halo_count: summary.halo_count
    }
  end

  defp summarize_query(entry) do
    %{
      chunk_coord: Tuple.to_list(entry.chunk_coord),
      tier: entry.tier,
      region_id: entry.region_id,
      lease_id: entry.lease_id,
      assigned_scene_node: entry.assigned_scene_node,
      query_scope: entry.query_scope,
      priority_band: entry.priority_band,
      delivery_interval: entry.delivery_interval
    }
  end

  defp summarize_remote_mirror_request(entry) do
    %{
      cid: entry.cid,
      logical_scene_id: entry.logical_scene_id,
      center_chunk: Tuple.to_list(entry.center_chunk),
      requester_scene_node: entry.requester_scene_node,
      owner_scene_node: entry.owner_scene_node,
      chunk_coord: Tuple.to_list(entry.chunk_coord),
      tier: entry.tier,
      region_id: entry.region_id,
      lease_id: entry.lease_id,
      assigned_scene_node: entry.assigned_scene_node,
      query_scope: entry.query_scope,
      priority_band: entry.priority_band,
      delivery_interval: entry.delivery_interval,
      request_mode: entry.request_mode,
      request_key: request_key_summary(entry.request_key),
      status: entry.status,
      reason: entry.reason
    }
  end

  defp request_key_summary({owner_scene_node, lease_id, chunk_coord}) do
    %{
      owner_scene_node: owner_scene_node,
      lease_id: lease_id,
      chunk_coord: Tuple.to_list(chunk_coord)
    }
  end

  defp summarize_skip(entry) do
    %{
      chunk_coord: Tuple.to_list(entry.chunk_coord),
      tier: entry.tier,
      status: entry.status,
      reason: entry.reason
    }
  end

  defp summary_line(summary) do
    [
      "scene_aoi_partition_interest=ok",
      "logical_scene_id=#{summary.logical_scene_id}",
      "cid=#{summary.cid}",
      "center=#{Enum.join(summary.center_chunk, ",")}",
      "near_queries=#{summary.near_query_count}",
      "halo_queries=#{summary.halo_query_count}",
      "remote_mirror_requests=#{summary.remote_mirror_request_count}",
      "skipped=#{summary.skipped_count}",
      "missing=#{summary.missing_count}",
      "unleased=#{summary.unleased_count}",
      "regions=#{summary.region_query_count}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp observe_path(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "scene-aoi-partition-interest-#{logical_scene_id}.log")
    )
  end

  defp parse_center!(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [x, y, z] -> {String.to_integer(x), String.to_integer(y), String.to_integer(z)}
      _other -> Mix.raise("center must be formatted as x,y,z")
    end
  rescue
    ArgumentError -> Mix.raise("center must be formatted as x,y,z")
  end

  defp restore_observe_log({:ok, value}),
    do: Application.put_env(:scene_server, :cli_observe_log, value)

  defp restore_observe_log(:error), do: Application.delete_env(:scene_server, :cli_observe_log)
end
