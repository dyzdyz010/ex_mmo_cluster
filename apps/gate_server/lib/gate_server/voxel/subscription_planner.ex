defmodule GateServer.Voxel.SubscriptionPlanner do
  @moduledoc """
  Converts a World partition window into a Gate-executable subscription plan.

  The planner is pure: it does not call World or Scene and owns no connection
  state. Gate connection processes use the result to keep near chunks ahead of
  halo chunks, skip unroutable chunks with explicit reasons, and emit one
  CLI-visible plan summary before subscribing to Scene chunk processes.
  """

  alias GateServer.Voxel.SyncBudget

  @default_snapshot_estimate_bytes 128
  @default_delta_estimate_bytes 32
  @default_field_estimate_bytes 0
  @default_recovery_estimate_bytes 0

  @doc """
  Builds a subscription plan from a World partition window.

  Byte values are reservation estimates for planning and observability. Scene
  remains the authority for actual chunk version truth and payload contents.
  """
  def plan(attrs) do
    attrs = normalize_input(attrs, "attrs")
    cid = fetch_required!(attrs, :cid)
    request_id = fetch_required!(attrs, :request_id)
    window = normalize_window(fetch_required!(attrs, :partition_window))
    known_versions = normalize_known_versions(Map.get(attrs, :known_versions, %{}))
    estimates = normalize_estimates(attrs)
    chunk_backlogs = chunk_backlogs(window.route_entries, known_versions, estimates)

    sync_budget =
      attrs
      |> Map.take([
        :last_server_seq,
        :last_client_ack_seq,
        :reliable_pending_bytes,
        :fast_lane_pending_bytes,
        :recovery_request_count,
        :resync_request_count,
        :stream_caps
      ])
      |> Map.merge(%{
        cid: cid,
        partition_window: window,
        chunk_backlogs: chunk_backlogs
      })
      |> SyncBudget.plan()

    budget_by_chunk = Map.new(sync_budget.chunk_plans, &{&1.chunk_coord, &1})

    subscribe_entries =
      subscribe_entries(sync_budget.chunk_plans, window.route_entries, known_versions)

    skipped_entries = skipped_entries(sync_budget.chunk_plans)

    %{
      cid: cid,
      request_id: request_id,
      partition_window: window,
      sync_budget: sync_budget,
      subscribe_entries: subscribe_entries,
      skipped_entries: skipped_entries,
      budget_by_chunk: budget_by_chunk,
      summary: summary(cid, request_id, window, sync_budget, subscribe_entries, skipped_entries)
    }
  end

  defp normalize_window(window) do
    window = mapify(window)
    near_radius = Map.get(window, :near_radius, 0)
    halo_radius = Map.get(window, :halo_radius, near_radius)
    near_vertical_radius = Map.get(window, :near_vertical_radius, near_radius)
    halo_vertical_radius = Map.get(window, :halo_vertical_radius, halo_radius)

    %{
      logical_scene_id: Map.fetch!(window, :logical_scene_id),
      center_chunk: coord!(Map.fetch!(window, :center_chunk)),
      near_radius: near_radius,
      halo_radius: halo_radius,
      near_vertical_radius: near_vertical_radius,
      halo_vertical_radius: halo_vertical_radius,
      near_chunks: Map.get(window, :near_chunks, []),
      halo_chunks: Map.get(window, :halo_chunks, []),
      route_entries: normalize_route_entries(Map.get(window, :route_entries, [])),
      region_summaries: Map.get(window, :region_summaries, [])
    }
  end

  defp normalize_route_entries(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      entry = mapify(entry)

      %{
        chunk_coord: coord!(Map.fetch!(entry, :chunk_coord)),
        tier: Map.fetch!(entry, :tier),
        status: Map.fetch!(entry, :status),
        region_id: Map.get(entry, :region_id),
        lease_id: Map.get(entry, :lease_id),
        lease: Map.get(entry, :lease),
        assigned_scene_node: Map.get(entry, :assigned_scene_node)
      }
    end)
  end

  defp normalize_estimates(attrs) do
    %{
      snapshot_bytes:
        non_negative_integer!(
          Map.get(attrs, :snapshot_estimate_bytes, @default_snapshot_estimate_bytes),
          :snapshot_estimate_bytes
        ),
      delta_bytes:
        non_negative_integer!(
          Map.get(attrs, :delta_estimate_bytes, @default_delta_estimate_bytes),
          :delta_estimate_bytes
        ),
      field_bytes:
        non_negative_integer!(
          Map.get(attrs, :field_estimate_bytes, @default_field_estimate_bytes),
          :field_estimate_bytes
        ),
      recovery_bytes:
        non_negative_integer!(
          Map.get(attrs, :recovery_estimate_bytes, @default_recovery_estimate_bytes),
          :recovery_estimate_bytes
        )
    }
  end

  defp chunk_backlogs(route_entries, known_versions, estimates) do
    Map.new(route_entries, fn entry ->
      known_version = Map.get(known_versions, entry.chunk_coord, 0)

      backlog =
        if entry.status == :assigned do
          %{
            snapshot_bytes: estimates.snapshot_bytes,
            delta_bytes: estimates.delta_bytes,
            field_bytes: estimates.field_bytes,
            recovery_bytes: estimates.recovery_bytes,
            known_version: known_version,
            server_version: known_version + 1
          }
        else
          %{
            snapshot_bytes: 0,
            delta_bytes: 0,
            field_bytes: 0,
            recovery_bytes: 0,
            known_version: known_version,
            server_version: known_version
          }
        end

      {entry.chunk_coord, backlog}
    end)
  end

  defp subscribe_entries(chunk_plans, route_entries, known_versions) do
    routes_by_chunk = Map.new(route_entries, &{&1.chunk_coord, &1})

    chunk_plans
    |> Enum.filter(&(&1.status == :assigned))
    |> Enum.map(fn chunk_plan ->
      route = Map.fetch!(routes_by_chunk, chunk_plan.chunk_coord)
      lease = required_lease!(route)

      %{
        chunk_coord: chunk_plan.chunk_coord,
        tier: chunk_plan.tier,
        priority: chunk_plan.priority,
        region_id: chunk_plan.region_id,
        lease_id: chunk_plan.lease_id,
        lease: lease,
        assigned_scene_node: route.assigned_scene_node,
        known_version: chunk_plan.known_version,
        known_version_for_scene: Map.get(known_versions, chunk_plan.chunk_coord),
        requested_bytes: chunk_plan.requested_bytes,
        budget_bytes: chunk_plan.budget_bytes,
        send_snapshot?: send_initial_snapshot?(chunk_plan),
        initial_delivery_mode: initial_delivery_mode(chunk_plan),
        snapshot_defer_reason: snapshot_defer_reason(chunk_plan),
        reason: chunk_plan.reason
      }
    end)
  end

  defp skipped_entries(chunk_plans) do
    chunk_plans
    |> Enum.reject(&(&1.status == :assigned))
    |> Enum.map(fn chunk_plan ->
      %{
        chunk_coord: chunk_plan.chunk_coord,
        tier: chunk_plan.tier,
        priority: chunk_plan.priority,
        status: chunk_plan.status,
        region_id: chunk_plan.region_id,
        lease_id: chunk_plan.lease_id,
        reason: chunk_plan.reason
      }
    end)
  end

  defp summary(cid, request_id, window, sync_budget, subscribe_entries, skipped_entries) do
    window_summary = sync_budget.window_summary

    %{
      cid: cid,
      request_id: request_id,
      logical_scene_id: window.logical_scene_id,
      center_chunk: window.center_chunk,
      near_radius: window.near_radius,
      halo_radius: window.halo_radius,
      near_vertical_radius: Map.get(window, :near_vertical_radius, window.near_radius),
      halo_vertical_radius: Map.get(window, :halo_vertical_radius, window.halo_radius),
      pressure: sync_budget.pressure,
      requested_chunk_count: window_summary.route_entry_count,
      assigned_chunk_count: window_summary.assigned_chunk_count,
      unleased_chunk_count: window_summary.unleased_chunk_count,
      missing_chunk_count: window_summary.missing_chunk_count,
      subscribe_count: length(subscribe_entries),
      skipped_count: length(skipped_entries),
      initial_snapshot_count: Enum.count(subscribe_entries, &Map.get(&1, :send_snapshot?)),
      ghost_subscription_count:
        Enum.count(subscribe_entries, &(Map.get(&1, :initial_delivery_mode) == :halo_ghost))
    }
  end

  defp send_initial_snapshot?(%{tier: :near}), do: true

  defp send_initial_snapshot?(chunk_plan) do
    requested_snapshot = chunk_plan.requested_bytes.voxel_snapshot

    requested_snapshot > 0 and chunk_plan.budget_bytes.voxel_snapshot >= requested_snapshot
  end

  defp initial_delivery_mode(%{tier: :halo} = chunk_plan) do
    if send_initial_snapshot?(chunk_plan) do
      :authoritative_snapshot
    else
      :halo_ghost
    end
  end

  defp initial_delivery_mode(_chunk_plan), do: :authoritative_snapshot

  defp snapshot_defer_reason(chunk_plan) do
    cond do
      send_initial_snapshot?(chunk_plan) ->
        nil

      chunk_plan.requested_bytes.voxel_snapshot > chunk_plan.budget_bytes.voxel_snapshot ->
        :snapshot_budget_exhausted

      chunk_plan.requested_bytes.voxel_delta > 0 ->
        :delta_budget_only

      true ->
        :snapshot_not_required
    end
  end

  defp required_lease!(%{lease: nil} = route) do
    raise ArgumentError,
          "assigned route #{inspect(route.chunk_coord)} is missing a lease token"
  end

  defp required_lease!(%{lease: lease}), do: lease

  defp normalize_known_versions(nil), do: %{}

  defp normalize_known_versions(known_versions) when is_map(known_versions) do
    Map.new(known_versions, fn {chunk_coord, version} ->
      {coord!(chunk_coord), non_negative_integer!(version, :known_version)}
    end)
  end

  defp normalize_known_versions(known_versions) when is_list(known_versions) do
    Map.new(known_versions, fn
      %{chunk_coord: chunk_coord, chunk_version: chunk_version} ->
        {coord!(chunk_coord), non_negative_integer!(chunk_version, :known_version)}

      {chunk_coord, chunk_version} ->
        {coord!(chunk_coord), non_negative_integer!(chunk_version, :known_version)}
    end)
  end

  defp normalize_input(attrs, _label) when is_map(attrs), do: mapify(attrs)
  defp normalize_input(attrs, _label) when is_list(attrs), do: Map.new(attrs)

  defp fetch_required!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required key #{inspect(key)}"
    end
  end

  defp mapify(%_struct{} = value), do: Map.from_struct(value)
  defp mapify(value) when is_map(value), do: value

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp non_negative_integer!(value, _key) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer!(value, key) do
    raise ArgumentError, "#{inspect(key)} must be a non-negative integer, got: #{inspect(value)}"
  end
end
