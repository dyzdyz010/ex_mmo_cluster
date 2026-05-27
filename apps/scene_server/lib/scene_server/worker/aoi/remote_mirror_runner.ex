defmodule SceneServer.Worker.Aoi.RemoteMirrorRunner do
  @moduledoc """
  One-pass remote AOI mirror/prewarm runner.

  `SceneServer.Aoi.RemoteMirrorLedger` records local AOI demand for remote-owned
  halo chunks. This runner consumes a point-in-time ledger snapshot by group and
  calls injected functions once per remote routing identity. It records only
  ghost/prewarm summaries; it does not insert remote actors into local AOI
  subscribees and owns no long-lived state.
  """

  alias SceneServer.Aoi.RemoteMirrorLedger
  alias SceneServer.CliObserve

  @doc """
  Runs one remote mirror pass from a ledger server or ledger snapshot.

  Options:

    * `:fetch_fun` - one-arity function called for `:ghost` groups.
    * `:prewarm_fun` - one-arity function called for `:prewarm` groups.
    * `:observe_fun` - two-arity observe sink. Defaults to
      `SceneServer.CliObserve.emit/2`.
    * `:run_id` - caller supplied run id for logs.
  """
  def run_once(source, opts \\ []) do
    fetch_fun = Keyword.get(opts, :fetch_fun, &default_fetch/1)
    prewarm_fun = Keyword.get(opts, :prewarm_fun, &default_prewarm/1)
    observe_fun = Keyword.get(opts, :observe_fun, &CliObserve.emit/2)
    run_id = Keyword.get(opts, :run_id, new_run_id())
    started_at_ms = System.monotonic_time(:millisecond)

    case snapshot(source) do
      {:ok, snapshot} ->
        observe_fun.(
          "scene_remote_mirror_runner_started",
          observe_started(run_id, snapshot, started_at_ms)
        )

        do_run_once(snapshot, fetch_fun, prewarm_fun, observe_fun, run_id, started_at_ms)

      {:error, reason} ->
        summary =
          empty_summary(:failed, run_id, started_at_ms)
          |> finish_summary(started_at_ms)
          |> Map.put(:reason, reason)

        observe_fun.("scene_remote_mirror_runner_completed", observe_summary(summary))
        summary
    end
  end

  defp do_run_once(snapshot, fetch_fun, prewarm_fun, observe_fun, run_id, started_at_ms) do
    groups =
      snapshot
      |> Map.get(:request_groups, [])
      |> Enum.map(&run_group(&1, fetch_fun, prewarm_fun, observe_fun, run_id))

    summary =
      groups
      |> Enum.reduce(
        empty_summary(summary_status(groups), run_id, started_at_ms),
        &accumulate_group/2
      )
      |> Map.put(:groups, groups)
      |> finish_summary(started_at_ms)

    observe_fun.("scene_remote_mirror_runner_completed", observe_summary(summary))
    summary
  end

  defp snapshot(%{request_groups: _groups} = snapshot), do: {:ok, snapshot}

  defp snapshot(server) do
    case RemoteMirrorLedger.snapshot(server) do
      %{request_groups: _groups} = snapshot -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_snapshot, other}}
    end
  end

  defp run_group(group, fetch_fun, prewarm_fun, observe_fun, run_id) do
    result =
      case group_mode(group) do
        :prewarm ->
          call_group(group, prewarm_fun, :prewarmed)

        :ghost ->
          call_group(group, fetch_fun, :mirrored)
      end

    result = Map.put(result, :run_id, run_id)
    observe_fun.("scene_remote_mirror_group_completed", observe_group(result))
    result
  end

  defp call_group(group, fun, success_status) do
    case safe_call(fun, group) do
      {:ok, payload} ->
        case normalize_payload(payload) do
          {:ok, normalized_payload} ->
            group
            |> group_base()
            |> Map.put(:status, success_status)
            |> Map.put(:payload, normalized_payload)

          {:error, reason} ->
            group
            |> group_base()
            |> Map.put(:status, :failed)
            |> Map.put(:reason, reason)
            |> Map.put(:payload, empty_payload())
        end

      {:error, reason} ->
        group
        |> group_base()
        |> Map.put(:status, :failed)
        |> Map.put(:reason, reason)
        |> Map.put(:payload, empty_payload())
    end
  end

  defp safe_call(fun, group) do
    case fun.(group) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_return, other}}
    end
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp group_base(group) do
    request_cids = Enum.sort(Map.get(group, :request_cids, []))

    %{
      logical_scene_id: Map.get(group, :logical_scene_id),
      request_mode: group_mode(group),
      request_key: Map.get(group, :request_key),
      owner_scene_node: Map.get(group, :owner_scene_node),
      lease_id: Map.get(group, :lease_id),
      chunk_coord: Map.get(group, :chunk_coord),
      request_cids: request_cids,
      cid_count: Map.get(group, :cid_count, length(request_cids)),
      requester_scene_nodes: Enum.sort(Map.get(group, :requester_scene_nodes, [])),
      live_fanout_count: 0
    }
  end

  defp group_mode(%{request_mode: mode}) when mode in [:ghost, :prewarm], do: mode

  defp group_mode(%{canonical_request: %{request_mode: mode}}) when mode in [:ghost, :prewarm],
    do: mode

  defp group_mode(_group), do: :ghost

  defp normalize_payload(payload) when is_map(payload) do
    with {:ok, payload_bytes} <- payload_counter(payload, :payload_bytes),
         {:ok, actor_summary_count} <- payload_counter(payload, :actor_summary_count),
         {:ok, field_summary_count} <- payload_counter(payload, :field_summary_count) do
      {:ok,
       %{
         payload_bytes: payload_bytes,
         actor_summary_count: actor_summary_count,
         field_summary_count: field_summary_count,
         voxel_summary_version: Map.get(payload, :voxel_summary_version),
         source: Map.get(payload, :source, :remote_owner)
       }}
    end
  end

  defp normalize_payload(payload), do: {:error, {:invalid_payload, payload}}

  defp empty_payload do
    %{
      payload_bytes: 0,
      actor_summary_count: 0,
      field_summary_count: 0,
      voxel_summary_version: nil,
      source: :none
    }
  end

  defp empty_summary(status, run_id, started_at_ms) do
    %{
      run_id: run_id,
      status: status,
      started_at_ms: started_at_ms,
      finished_at_ms: nil,
      duration_ms: nil,
      group_count: 0,
      ghost_group_count: 0,
      prewarm_group_count: 0,
      mirrored_group_count: 0,
      prewarmed_group_count: 0,
      failed_group_count: 0,
      demand_cid_count: 0,
      payload_bytes: 0,
      actor_summary_count: 0,
      field_summary_count: 0,
      live_fanout_count: 0,
      groups: []
    }
  end

  defp summary_status([]), do: :idle

  defp summary_status(groups) do
    if Enum.any?(groups, &(&1.status == :failed)), do: :degraded, else: :ok
  end

  defp accumulate_group(group, summary) do
    payload = Map.get(group, :payload, empty_payload())

    summary
    |> Map.update!(:group_count, &(&1 + 1))
    |> Map.update!(:ghost_group_count, &(&1 + if(group.request_mode == :ghost, do: 1, else: 0)))
    |> Map.update!(
      :prewarm_group_count,
      &(&1 + if(group.request_mode == :prewarm, do: 1, else: 0))
    )
    |> Map.update!(:mirrored_group_count, &(&1 + if(group.status == :mirrored, do: 1, else: 0)))
    |> Map.update!(:prewarmed_group_count, &(&1 + if(group.status == :prewarmed, do: 1, else: 0)))
    |> Map.update!(:failed_group_count, &(&1 + if(group.status == :failed, do: 1, else: 0)))
    |> Map.update!(:demand_cid_count, &(&1 + group.cid_count))
    |> Map.update!(:payload_bytes, &(&1 + payload.payload_bytes))
    |> Map.update!(:actor_summary_count, &(&1 + payload.actor_summary_count))
    |> Map.update!(:field_summary_count, &(&1 + payload.field_summary_count))
    |> Map.update!(:live_fanout_count, &(&1 + Map.get(group, :live_fanout_count, 0)))
  end

  defp finish_summary(summary, started_at_ms) do
    finished_at_ms = System.monotonic_time(:millisecond)

    summary
    |> Map.put(:finished_at_ms, finished_at_ms)
    |> Map.put(:duration_ms, max(finished_at_ms - started_at_ms, 0))
  end

  defp observe_started(run_id, snapshot, started_at_ms) do
    %{
      run_id: run_id,
      started_at_ms: started_at_ms,
      snapshot_group_count: length(Map.get(snapshot, :request_groups, [])),
      snapshot_request_count: Map.get(snapshot, :total_request_count, 0),
      owner_scene_count: Map.get(snapshot, :owner_scene_count, 0)
    }
  end

  defp observe_summary(summary) do
    summary
    |> Map.take([
      :run_id,
      :status,
      :started_at_ms,
      :finished_at_ms,
      :duration_ms,
      :group_count,
      :ghost_group_count,
      :prewarm_group_count,
      :mirrored_group_count,
      :prewarmed_group_count,
      :failed_group_count,
      :demand_cid_count,
      :payload_bytes,
      :actor_summary_count,
      :field_summary_count,
      :live_fanout_count,
      :reason
    ])
    |> Map.put(:groups, Enum.map(summary.groups, &observe_group/1))
  end

  defp observe_group(group) do
    group
    |> Map.take([
      :run_id,
      :status,
      :logical_scene_id,
      :request_mode,
      :request_key,
      :owner_scene_node,
      :lease_id,
      :chunk_coord,
      :cid_count,
      :requester_scene_nodes,
      :payload,
      :live_fanout_count,
      :reason
    ])
    |> Map.put(:request_cids, Enum.map(group.request_cids, &%{cid: &1}))
  end

  defp payload_counter(payload, key) do
    case Map.get(payload, key, 0) do
      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      _other ->
        {:error, {:invalid_payload_field, key, "expected non-negative integer"}}
    end
  end

  defp default_fetch(_group), do: {:ok, empty_payload()}
  defp default_prewarm(group), do: default_fetch(group)

  defp new_run_id do
    "remote-mirror-#{System.unique_integer([:positive])}"
  end
end
