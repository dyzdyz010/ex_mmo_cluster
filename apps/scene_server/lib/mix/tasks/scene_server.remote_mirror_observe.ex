defmodule Mix.Tasks.SceneServer.RemoteMirrorObserve do
  @moduledoc """
  Runs a scene-side remote AOI mirror-request ledger observe smoke.

      mix scene_server.remote_mirror_observe --logical-scene-id 1 --cid 42 --center 0,0,0

  The task builds the same partition-window shaped sample used by AOI planning,
  publishes the remote halo request into a private temporary ledger, and writes
  a deterministic snapshot for CLI/headless debugging without mutating live
  Scene runtime demand.
  """

  use Mix.Task

  alias SceneServer.Aoi.PartitionInterest
  alias SceneServer.Aoi.RemoteMirrorLedger
  alias SceneServer.CliObserve
  alias SceneServer.Worker.Aoi.RemoteMirrorRunner

  @shortdoc "Runs remote AOI mirror-request ledger CLI observe smoke"
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
    {:ok, ledger} = RemoteMirrorLedger.start_link(name: nil)

    try do
      File.mkdir_p!(Path.dirname(observe_log))
      File.rm(observe_log)
      Application.put_env(:scene_server, :cli_observe_log, observe_log)

      partition_window = sample_partition_window(logical_scene_id, center_chunk)
      plan = plan_requests(cid, partition_window)
      second_plan = plan_requests(cid + 1, partition_window)

      replace_summary =
        RemoteMirrorLedger.replace_requests(cid, plan.remote_mirror_requests, ledger)

      second_replace_summary =
        RemoteMirrorLedger.replace_requests(cid + 1, second_plan.remote_mirror_requests, ledger)

      snapshot = RemoteMirrorLedger.snapshot(ledger)

      mirror_summary =
        RemoteMirrorRunner.run_once(snapshot,
          fetch_fun: &sample_remote_fetch/1,
          prewarm_fun: &sample_remote_prewarm/1
        )

      summary =
        summary(
          plan,
          [replace_summary, second_replace_summary],
          snapshot,
          mirror_summary,
          observe_log
        )

      CliObserve.emit("scene_remote_mirror_ledger_snapshot", summary)
      CliObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      CliObserve.flush()
      stop_private_ledger(ledger)
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
        }
      ]
    }
  end

  defp plan_requests(cid, partition_window) do
    PartitionInterest.plan(%{
      cid: cid,
      local_scene_node: :"scene-a@local",
      partition_window: partition_window
    })
  end

  defp summary(plan, replace_summaries, snapshot, mirror_summary, observe_log) do
    %{
      cid: plan.cid,
      logical_scene_id: plan.logical_scene_id,
      center_chunk: Tuple.to_list(plan.center_chunk),
      active_requests: snapshot.total_request_count,
      added_count: sum_summary_count(replace_summaries, :added_count),
      retained_count: sum_summary_count(replace_summaries, :retained_count),
      removed_count: sum_summary_count(replace_summaries, :removed_count),
      total_request_count: snapshot.total_request_count,
      cid_count: snapshot.cid_count,
      owner_scene_count: snapshot.owner_scene_count,
      group_count: snapshot.group_count,
      mirror_status: mirror_summary.status,
      mirror_ghost_group_count: mirror_summary.ghost_group_count,
      mirror_prewarm_group_count: mirror_summary.prewarm_group_count,
      mirrored_group_count: mirror_summary.mirrored_group_count,
      prewarmed_group_count: mirror_summary.prewarmed_group_count,
      failed_group_count: mirror_summary.failed_group_count,
      mirror_live_fanout_count: mirror_summary.live_fanout_count,
      mirror_payload_bytes: mirror_summary.payload_bytes,
      mirror_actor_summary_count: mirror_summary.actor_summary_count,
      mirror_field_summary_count: mirror_summary.field_summary_count,
      mirror_groups: Enum.map(mirror_summary.groups, &summarize_mirror_group/1),
      request_groups: Enum.map(snapshot.request_groups, &summarize_group/1),
      requests: Enum.map(snapshot.requests, &summarize_request/1),
      observe_log: observe_log
    }
  end

  defp sample_remote_fetch(group) do
    {:ok,
     %{
       payload_bytes: 128,
       actor_summary_count: group.cid_count,
       field_summary_count: 1,
       voxel_summary_version: group.lease_id,
       source: :cli_sample
     }}
  end

  defp sample_remote_prewarm(group) do
    {:ok,
     %{
       payload_bytes: 64,
       actor_summary_count: group.cid_count,
       field_summary_count: 0,
       voxel_summary_version: group.lease_id,
       source: :cli_sample
     }}
  end

  defp sum_summary_count(summaries, key) do
    summaries
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.get(&1, key, 0))
    |> Enum.sum()
  end

  defp summarize_group(group) do
    %{
      logical_scene_id: group.logical_scene_id,
      request_key: request_key_summary(group.request_key),
      owner_scene_node: group.owner_scene_node,
      lease_id: group.lease_id,
      chunk_coord: Tuple.to_list(group.chunk_coord),
      request_mode: group.request_mode,
      request_cids: Enum.map(group.request_cids, &%{cid: &1}),
      cid_count: group.cid_count
    }
  end

  defp summarize_request(request) do
    %{
      cid: request.cid,
      logical_scene_id: request.logical_scene_id,
      center_chunk: Tuple.to_list(request.center_chunk),
      requester_scene_node: request.requester_scene_node,
      owner_scene_node: request.owner_scene_node,
      chunk_coord: Tuple.to_list(request.chunk_coord),
      tier: request.tier,
      region_id: request.region_id,
      lease_id: request.lease_id,
      query_scope: request.query_scope,
      request_mode: request.request_mode,
      request_key: request_key_summary(request.request_key),
      status: request.status,
      reason: request.reason
    }
  end

  defp summarize_mirror_group(group) do
    %{
      status: group.status,
      logical_scene_id: group.logical_scene_id,
      request_mode: group.request_mode,
      request_key: request_key_summary(group.request_key),
      owner_scene_node: group.owner_scene_node,
      lease_id: group.lease_id,
      chunk_coord: Tuple.to_list(group.chunk_coord),
      request_cids: Enum.map(group.request_cids, &%{cid: &1}),
      cid_count: group.cid_count,
      live_fanout_count: group.live_fanout_count,
      payload: group.payload
    }
  end

  defp request_key_summary({owner_scene_node, lease_id, chunk_coord}) do
    %{
      owner_scene_node: owner_scene_node,
      lease_id: lease_id,
      chunk_coord: Tuple.to_list(chunk_coord)
    }
  end

  defp summary_line(summary) do
    [
      "scene_remote_mirror_ledger=ok",
      "scene_remote_mirror_runner=#{summary.mirror_status}",
      "logical_scene_id=#{summary.logical_scene_id}",
      "cid=#{summary.cid}",
      "active_requests=#{summary.active_requests}",
      "ghost_groups=#{summary.mirror_ghost_group_count}",
      "prewarm_groups=#{summary.mirror_prewarm_group_count}",
      "mirrored_groups=#{summary.mirrored_group_count}",
      "prewarmed_groups=#{summary.prewarmed_group_count}",
      "failed_groups=#{summary.failed_group_count}",
      "live_fanout=#{summary.mirror_live_fanout_count}",
      "mirror_payload_bytes=#{summary.mirror_payload_bytes}",
      "owners=#{summary.owner_scene_count}",
      "groups=#{summary.group_count}",
      "cids=#{summary.cid_count}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp observe_path(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "scene-remote-mirror-ledger-#{logical_scene_id}.log")
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

  defp stop_private_ledger(ledger) when is_pid(ledger) do
    if Process.alive?(ledger), do: GenServer.stop(ledger)
  catch
    :exit, _reason -> :ok
  end
end
