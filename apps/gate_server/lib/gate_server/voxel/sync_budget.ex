defmodule GateServer.Voxel.SyncBudget do
  @moduledoc """
  Pure Gate-side planner for per-client voxel stream budgets.

  Gate owns per-client stream budget planning. World owns partition and routing
  truth, while Scene owns hot chunk truth. This module does not call World,
  Scene, or DataService, and it owns no process state.
  """

  @default_stream_caps %{
    reliable_control: 1_024,
    voxel_snapshot: 64 * 1_024,
    voxel_delta: 32 * 1_024,
    field_state: 16 * 1_024,
    recovery: 32 * 1_024
  }

  @stream_keys [:reliable_control, :voxel_snapshot, :voxel_delta, :field_state, :recovery]
  @chunk_stream_keys [:recovery, :voxel_snapshot, :voxel_delta, :field_state]
  @counter_keys [
    :last_server_seq,
    :last_client_ack_seq,
    :reliable_pending_bytes,
    :fast_lane_pending_bytes,
    :recovery_request_count,
    :resync_request_count
  ]
  @empty_chunk_backlog %{
    snapshot_bytes: 0,
    delta_bytes: 0,
    field_bytes: 0,
    recovery_bytes: 0,
    known_version: 0,
    server_version: 0
  }

  @doc """
  Builds one deterministic per-client sync budget plan from Gate-local counters
  and a World-provided partition window.
  """
  def plan(attrs) do
    attrs = normalize_input(attrs, "attrs")
    cid = fetch_required!(attrs, :cid)
    window = normalize_partition_window(fetch_required!(attrs, :partition_window))
    stream_caps = normalize_stream_caps(Map.get(attrs, :stream_caps, %{}))
    counters = normalize_counters(attrs)
    ordered_entries = ordered_route_entries(window.route_entries)
    chunk_backlogs = normalize_chunk_backlogs(Map.get(attrs, :chunk_backlogs, %{}))
    requested_totals = requested_totals(ordered_entries, chunk_backlogs, counters)
    pressure = pressure(counters, stream_caps, requested_totals)
    chunk_plans = build_chunk_plans(ordered_entries, chunk_backlogs, stream_caps, pressure)

    %{
      cid: cid,
      counters: counters,
      stream_caps: stream_caps,
      pressure: pressure,
      window_summary: window_summary(window, ordered_entries),
      chunk_plans: chunk_plans,
      budget_usage: budget_usage(stream_caps, counters, chunk_plans)
    }
  end

  defp normalize_partition_window(window) do
    window = mapify(window)

    %{
      logical_scene_id: Map.get(window, :logical_scene_id),
      center_chunk: optional_coord(Map.get(window, :center_chunk)),
      near_radius: Map.get(window, :near_radius),
      halo_radius: Map.get(window, :halo_radius),
      near_vertical_radius: Map.get(window, :near_vertical_radius),
      halo_vertical_radius: Map.get(window, :halo_vertical_radius),
      near_chunks: normalize_coord_list(Map.get(window, :near_chunks, []), :near_chunks),
      halo_chunks: normalize_coord_list(Map.get(window, :halo_chunks, []), :halo_chunks),
      route_entries: normalize_route_entries(Map.get(window, :route_entries, [])),
      region_summaries: normalize_region_summaries(Map.get(window, :region_summaries, []))
    }
  end

  defp normalize_stream_caps(stream_caps) do
    stream_caps =
      @default_stream_caps
      |> Map.merge(normalize_input(stream_caps, "stream_caps"))

    Map.new(@stream_keys, fn key ->
      {key, validate_non_negative_integer!(Map.fetch!(stream_caps, key), key)}
    end)
  end

  defp normalize_counters(attrs) do
    counters =
      Map.new(@counter_keys, fn key ->
        {key, validate_non_negative_integer!(Map.get(attrs, key, 0), key)}
      end)

    Map.put(
      counters,
      :seq_gap,
      max(counters.last_server_seq - counters.last_client_ack_seq, 0)
    )
  end

  defp normalize_chunk_backlogs(backlogs) when backlogs == nil, do: %{}

  defp normalize_chunk_backlogs(backlogs) do
    backlogs
    |> normalize_chunk_backlog_entries()
    |> normalize_chunk_backlog_map()
  end

  defp normalize_chunk_backlog_entries(backlogs) when is_map(backlogs), do: Map.to_list(backlogs)

  defp normalize_chunk_backlog_entries(backlogs) when is_list(backlogs) do
    Enum.map(backlogs, fn
      {chunk_coord, attrs} ->
        {chunk_coord, attrs}

      attrs when is_map(attrs) or is_list(attrs) ->
        attrs = normalize_input(attrs, "chunk backlog")
        {fetch_required!(attrs, :chunk_coord), Map.delete(attrs, :chunk_coord)}

      other ->
        raise ArgumentError,
              "expected chunk backlog entry keyed by chunk coord, got: #{inspect(other)}"
    end)
  end

  defp normalize_chunk_backlog_entries(other) do
    raise ArgumentError, "expected chunk_backlogs as map or list, got: #{inspect(other)}"
  end

  defp normalize_chunk_backlog_map(entries) do
    Enum.reduce(entries, %{}, fn {chunk_coord, attrs}, acc ->
      chunk_coord = coord!(chunk_coord)

      if Map.has_key?(acc, chunk_coord) do
        raise ArgumentError, "duplicate chunk backlog for #{inspect(chunk_coord)}"
      end

      Map.put(acc, chunk_coord, normalize_chunk_backlog(attrs))
    end)
  end

  defp normalize_chunk_backlog(backlog) do
    backlog = normalize_input(backlog, "chunk backlog")

    %{
      snapshot_bytes:
        validate_non_negative_integer!(Map.get(backlog, :snapshot_bytes, 0), :snapshot_bytes),
      delta_bytes:
        validate_non_negative_integer!(Map.get(backlog, :delta_bytes, 0), :delta_bytes),
      field_bytes:
        validate_non_negative_integer!(Map.get(backlog, :field_bytes, 0), :field_bytes),
      recovery_bytes:
        validate_non_negative_integer!(Map.get(backlog, :recovery_bytes, 0), :recovery_bytes),
      known_version:
        validate_non_negative_integer!(Map.get(backlog, :known_version, 0), :known_version),
      server_version:
        validate_non_negative_integer!(Map.get(backlog, :server_version, 0), :server_version)
    }
  end

  defp normalize_route_entries(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      entry = mapify(entry)
      tier = normalize_tier!(Map.get(entry, :tier))
      status = normalize_status!(Map.get(entry, :status))

      %{
        chunk_coord: coord!(Map.get(entry, :chunk_coord)),
        tier: tier,
        status: status,
        region_id: Map.get(entry, :region_id),
        lease_id: Map.get(entry, :lease_id),
        assigned_scene_node: Map.get(entry, :assigned_scene_node)
      }
    end)
  end

  defp normalize_route_entries(other) do
    raise ArgumentError, "partition_window.route_entries must be a list, got: #{inspect(other)}"
  end

  defp normalize_region_summaries(summaries) when is_list(summaries) do
    summaries
    |> Enum.map(fn summary ->
      summary = mapify(summary)

      %{
        region_id: Map.get(summary, :region_id),
        near_count: validate_non_negative_integer!(Map.get(summary, :near_count, 0), :near_count),
        halo_count: validate_non_negative_integer!(Map.get(summary, :halo_count, 0), :halo_count),
        lease_id: Map.get(summary, :lease_id),
        assigned_scene_node: Map.get(summary, :assigned_scene_node)
      }
    end)
    |> Enum.sort_by(& &1.region_id)
  end

  defp normalize_region_summaries(other) do
    raise ArgumentError,
          "partition_window.region_summaries must be a list, got: #{inspect(other)}"
  end

  defp ordered_route_entries(route_entries) do
    Enum.sort_by(route_entries, fn entry ->
      {tier_rank(entry.tier), entry.chunk_coord}
    end)
  end

  defp requested_totals(route_entries, chunk_backlogs, counters) do
    recovery_needed? = recovery_needed?(counters)

    Enum.reduce(route_entries, zero_budget_bytes(), fn entry, acc ->
      backlog = Map.get(chunk_backlogs, entry.chunk_coord, @empty_chunk_backlog)

      requested =
        if entry.status == :assigned do
          requested_bytes(backlog, recovery_needed?)
        else
          zero_budget_bytes()
        end

      add_budget_bytes(acc, requested)
    end)
  end

  defp pressure(counters, stream_caps, requested_totals) do
    cond do
      recovery_needed?(counters) ->
        :recovery

      counters.reliable_pending_bytes > stream_caps.reliable_control ->
        :congested

      counters.fast_lane_pending_bytes > fast_lane_cap(stream_caps) ->
        :congested

      Enum.any?(@chunk_stream_keys, fn stream ->
        Map.fetch!(requested_totals, stream) > Map.fetch!(stream_caps, stream)
      end) ->
        :congested

      true ->
        :normal
    end
  end

  defp build_chunk_plans(route_entries, chunk_backlogs, stream_caps, pressure) do
    recovery_needed? = pressure == :recovery
    remaining = Map.take(stream_caps, @chunk_stream_keys)

    {chunk_plans, _remaining} =
      Enum.map_reduce(route_entries, remaining, fn entry, acc ->
        backlog = Map.get(chunk_backlogs, entry.chunk_coord, @empty_chunk_backlog)
        requested = route_requested_bytes(entry, backlog, recovery_needed?)
        {budget, next_acc, reason} = allocate_budget(entry, requested, acc, recovery_needed?)

        plan = %{
          chunk_coord: entry.chunk_coord,
          tier: entry.tier,
          priority: priority(entry),
          status: entry.status,
          region_id: entry.region_id,
          lease_id: entry.lease_id,
          assigned_scene_node: entry.assigned_scene_node,
          known_version: backlog.known_version,
          server_version: backlog.server_version,
          requested_bytes: requested,
          budget_bytes: budget,
          total_requested_bytes: total_budget_bytes(requested),
          total_allocated_bytes: total_budget_bytes(budget),
          reason: reason
        }

        {plan, next_acc}
      end)

    chunk_plans
  end

  defp allocate_budget(%{status: :missing}, _requested, remaining, _recovery_needed?) do
    {zero_budget_bytes(), remaining, :missing_route}
  end

  defp allocate_budget(%{status: :region_without_lease}, _requested, remaining, _recovery_needed?) do
    {zero_budget_bytes(), remaining, :missing_lease}
  end

  defp allocate_budget(_entry, requested, remaining, recovery_needed?) do
    order =
      if recovery_needed? do
        [:recovery, :voxel_snapshot, :voxel_delta, :field_state]
      else
        [:voxel_snapshot, :voxel_delta, :field_state, :recovery]
      end

    {budget, next_remaining} =
      Enum.reduce(order, {zero_budget_bytes(), remaining}, fn stream,
                                                              {budget_acc, remaining_acc} ->
        requested_bytes = Map.fetch!(requested, stream)
        stream_remaining = Map.fetch!(remaining_acc, stream)
        granted = min(requested_bytes, stream_remaining)

        {
          Map.put(budget_acc, stream, granted),
          Map.put(remaining_acc, stream, stream_remaining - granted)
        }
      end)

    reason =
      cond do
        total_budget_bytes(requested) == 0 -> :up_to_date
        total_budget_bytes(budget) == 0 -> :stream_cap_exhausted
        true -> nil
      end

    {budget, next_remaining, reason}
  end

  defp route_requested_bytes(%{status: :assigned}, backlog, recovery_needed?),
    do: requested_bytes(backlog, recovery_needed?)

  defp route_requested_bytes(_entry, _backlog, _recovery_needed?), do: zero_budget_bytes()

  defp priority(%{status: status}) when status != :assigned, do: :none
  defp priority(%{tier: :near}), do: :critical
  defp priority(%{tier: :halo}), do: :opportunistic

  defp requested_bytes(backlog, recovery_needed?) do
    {voxel_snapshot, voxel_delta} = snapshot_and_delta_request(backlog)

    %{
      recovery: if(recovery_needed?, do: backlog.recovery_bytes, else: 0),
      voxel_snapshot: voxel_snapshot,
      voxel_delta: voxel_delta,
      field_state: backlog.field_bytes
    }
  end

  defp snapshot_and_delta_request(backlog) do
    cond do
      backlog.server_version == backlog.known_version ->
        {0, 0}

      backlog.known_version == 0 ->
        {backlog.snapshot_bytes, 0}

      backlog.server_version > backlog.known_version and backlog.delta_bytes > 0 ->
        {0, backlog.delta_bytes}

      backlog.snapshot_bytes > 0 ->
        {backlog.snapshot_bytes, 0}

      true ->
        {0, backlog.delta_bytes}
    end
  end

  defp budget_usage(stream_caps, counters, chunk_plans) do
    chunk_requested =
      Enum.reduce(chunk_plans, zero_budget_bytes(), fn plan, acc ->
        add_budget_bytes(acc, plan.requested_bytes)
      end)

    chunk_allocated =
      Enum.reduce(chunk_plans, zero_budget_bytes(), fn plan, acc ->
        add_budget_bytes(acc, plan.budget_bytes)
      end)

    reliable_allocated = min(counters.reliable_pending_bytes, stream_caps.reliable_control)

    %{
      reliable_control: %{
        cap: stream_caps.reliable_control,
        requested_bytes: counters.reliable_pending_bytes,
        allocated_bytes: reliable_allocated,
        remaining_bytes: max(stream_caps.reliable_control - reliable_allocated, 0)
      },
      voxel_snapshot:
        stream_budget_usage(stream_caps, chunk_requested, chunk_allocated, :voxel_snapshot),
      voxel_delta:
        stream_budget_usage(stream_caps, chunk_requested, chunk_allocated, :voxel_delta),
      field_state:
        stream_budget_usage(stream_caps, chunk_requested, chunk_allocated, :field_state),
      recovery: stream_budget_usage(stream_caps, chunk_requested, chunk_allocated, :recovery)
    }
  end

  defp stream_budget_usage(stream_caps, chunk_requested, chunk_allocated, stream) do
    allocated = Map.fetch!(chunk_allocated, stream)
    cap = Map.fetch!(stream_caps, stream)

    %{
      cap: cap,
      requested_bytes: Map.fetch!(chunk_requested, stream),
      allocated_bytes: allocated,
      remaining_bytes: max(cap - allocated, 0)
    }
  end

  defp window_summary(window, ordered_entries) do
    near_radius = Map.get(window, :near_radius) || 0
    halo_radius = Map.get(window, :halo_radius) || 0
    near_vertical_radius = Map.get(window, :near_vertical_radius) || near_radius
    halo_vertical_radius = Map.get(window, :halo_vertical_radius) || halo_radius

    %{
      logical_scene_id: window.logical_scene_id,
      center_chunk: window.center_chunk,
      near_radius: near_radius,
      halo_radius: halo_radius,
      near_vertical_radius: near_vertical_radius,
      halo_vertical_radius: halo_vertical_radius,
      near_chunk_count: length(window.near_chunks),
      halo_chunk_count: length(window.halo_chunks),
      route_entry_count: length(ordered_entries),
      assigned_chunk_count: Enum.count(ordered_entries, &(&1.status == :assigned)),
      unleased_chunk_count: Enum.count(ordered_entries, &(&1.status == :region_without_lease)),
      missing_chunk_count: Enum.count(ordered_entries, &(&1.status == :missing)),
      region_summaries: window.region_summaries
    }
  end

  defp add_budget_bytes(left, right) do
    Enum.reduce(@chunk_stream_keys, %{}, fn key, acc ->
      Map.put(acc, key, Map.fetch!(left, key) + Map.fetch!(right, key))
    end)
  end

  defp total_budget_bytes(bytes) do
    Enum.reduce(@chunk_stream_keys, 0, fn key, acc ->
      acc + Map.fetch!(bytes, key)
    end)
  end

  defp zero_budget_bytes do
    %{
      recovery: 0,
      voxel_snapshot: 0,
      voxel_delta: 0,
      field_state: 0
    }
  end

  defp recovery_needed?(counters) do
    counters.recovery_request_count > 0 or
      counters.resync_request_count > 0 or
      counters.seq_gap > 0
  end

  defp fast_lane_cap(stream_caps) do
    stream_caps.voxel_snapshot +
      stream_caps.voxel_delta +
      stream_caps.field_state +
      stream_caps.recovery
  end

  defp normalize_input(attrs, _label) when is_map(attrs), do: mapify(attrs)
  defp normalize_input(attrs, _label) when is_list(attrs), do: Map.new(attrs)

  defp normalize_input(other, label) do
    raise ArgumentError, "expected #{label} as map or keyword list, got: #{inspect(other)}"
  end

  defp mapify(%_struct{} = value), do: Map.from_struct(value)
  defp mapify(value) when is_map(value), do: value

  defp fetch_required!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required key #{inspect(key)}"
    end
  end

  defp normalize_coord_list(coords, _label) when is_list(coords), do: Enum.map(coords, &coord!/1)

  defp normalize_coord_list(other, label) do
    raise ArgumentError, "#{label} must be a list of chunk coords, got: #{inspect(other)}"
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(other) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(other)}"
  end

  defp optional_coord(nil), do: nil
  defp optional_coord(coord), do: coord!(coord)

  defp normalize_tier!(:near), do: :near
  defp normalize_tier!(:halo), do: :halo

  defp normalize_tier!(other) do
    raise ArgumentError, "route entry tier must be :near or :halo, got: #{inspect(other)}"
  end

  defp normalize_status!(:assigned), do: :assigned
  defp normalize_status!(:region_without_lease), do: :region_without_lease
  defp normalize_status!(:missing), do: :missing

  defp normalize_status!(other) do
    raise ArgumentError,
          "route entry status must be :assigned, :region_without_lease, or :missing, got: #{inspect(other)}"
  end

  defp validate_non_negative_integer!(value, _key) when is_integer(value) and value >= 0,
    do: value

  defp validate_non_negative_integer!(value, key) do
    raise ArgumentError, "#{inspect(key)} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp tier_rank(:near), do: 0
  defp tier_rank(:halo), do: 1
end
