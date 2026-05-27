defmodule SceneServer.Aoi.PartitionInterest do
  @moduledoc """
  Pure AOI interest planning from a server-authoritative partition window.

  World owns partition windows and leases. Scene AOI owns actor fan-out. This
  module is the policy bridge between those boundaries: it consumes the
  partition-window shape and returns the near/halo AOI query plan a runtime can
  apply without inventing a second spatial truth.
  """

  alias SceneServer.Aoi.Priority

  @type chunk_coord :: {integer(), integer(), integer()}
  @type query_scope :: :authoritative | :halo_ghost

  @type query_entry :: %{
          required(:chunk_coord) => chunk_coord(),
          required(:tier) => :near | :halo,
          required(:region_id) => non_neg_integer(),
          required(:lease_id) => non_neg_integer(),
          required(:assigned_scene_node) => node(),
          required(:query_scope) => query_scope(),
          required(:priority_band) => Priority.band(),
          required(:delivery_interval) => pos_integer()
        }

  @type remote_mirror_request :: %{
          required(:cid) => non_neg_integer(),
          required(:logical_scene_id) => non_neg_integer(),
          required(:center_chunk) => chunk_coord(),
          required(:requester_scene_node) => node(),
          required(:owner_scene_node) => node(),
          required(:chunk_coord) => chunk_coord(),
          required(:tier) => :halo,
          required(:region_id) => non_neg_integer(),
          required(:lease_id) => non_neg_integer(),
          required(:assigned_scene_node) => node(),
          required(:query_scope) => :halo_ghost,
          required(:priority_band) => Priority.band(),
          required(:delivery_interval) => pos_integer(),
          required(:request_mode) => :ghost,
          required(:request_key) => {node(), non_neg_integer(), chunk_coord()},
          required(:status) => :planned,
          required(:reason) => :remote_halo_route
        }

  @type skipped_entry :: %{
          required(:chunk_coord) => chunk_coord(),
          required(:tier) => :near | :halo,
          required(:status) => :region_without_lease | :missing,
          required(:reason) => :missing_lease | :missing_route
        }

  @doc """
  Builds an AOI query plan from a World partition-window shaped map.

  The function deliberately ignores client region hints. Region membership comes
  only from `partition_window.route_entries`.
  """
  @spec plan(map() | keyword()) :: map()
  def plan(attrs) do
    attrs = normalize_input(attrs, "attrs")
    cid = non_negative_integer!(Map.fetch!(attrs, :cid), :cid)
    local_scene_node = local_scene_node!(Map.get(attrs, :local_scene_node, node()))
    window = normalize_window(Map.fetch!(attrs, :partition_window))

    {query_entries, skipped_entries} =
      window.route_entries
      |> Enum.sort_by(&route_sort_key/1)
      |> Enum.split_with(&(&1.status == :assigned))

    query_entries = Enum.map(query_entries, &query_entry/1)
    skipped_entries = Enum.map(skipped_entries, &skipped_entry/1)

    remote_mirror_requests =
      remote_mirror_requests(
        cid,
        window.logical_scene_id,
        window.center_chunk,
        local_scene_node,
        query_entries
      )

    %{
      cid: cid,
      logical_scene_id: window.logical_scene_id,
      local_scene_node: local_scene_node,
      center_chunk: window.center_chunk,
      near_radius: window.near_radius,
      halo_radius: window.halo_radius,
      query_entries: query_entries,
      skipped_entries: skipped_entries,
      remote_mirror_requests: remote_mirror_requests,
      region_query_summaries: region_query_summaries(query_entries),
      near_query_count: Enum.count(query_entries, &(&1.tier == :near)),
      halo_query_count: Enum.count(query_entries, &(&1.tier == :halo)),
      remote_mirror_request_count: length(remote_mirror_requests),
      skipped_count: length(skipped_entries),
      missing_count: Enum.count(skipped_entries, &(&1.reason == :missing_route)),
      unleased_count: Enum.count(skipped_entries, &(&1.reason == :missing_lease))
    }
  end

  defp normalize_window(window) do
    window = normalize_input(window, "partition_window")

    %{
      logical_scene_id:
        non_negative_integer!(Map.fetch!(window, :logical_scene_id), :logical_scene_id),
      center_chunk: coord!(Map.fetch!(window, :center_chunk)),
      near_radius: non_negative_integer!(Map.get(window, :near_radius, 0), :near_radius),
      halo_radius: non_negative_integer!(Map.get(window, :halo_radius, 0), :halo_radius),
      route_entries:
        window
        |> Map.get(:route_entries, [])
        |> Enum.map(&normalize_route_entry/1)
    }
  end

  defp normalize_route_entry(entry) do
    entry = normalize_input(entry, "route entry")
    status = route_status!(Map.fetch!(entry, :status))

    %{
      chunk_coord: coord!(Map.fetch!(entry, :chunk_coord)),
      tier: tier!(Map.fetch!(entry, :tier)),
      status: status,
      region_id: route_region_id(status, entry),
      lease_id: route_lease_id(status, entry),
      assigned_scene_node: route_scene_node(status, entry)
    }
  end

  defp query_entry(route) do
    band = priority_band(route.tier)

    %{
      chunk_coord: route.chunk_coord,
      tier: route.tier,
      region_id: route.region_id,
      lease_id: route.lease_id,
      assigned_scene_node: route.assigned_scene_node,
      query_scope: query_scope(route.tier),
      priority_band: band,
      delivery_interval: Priority.delivery_interval(band)
    }
  end

  defp skipped_entry(route) do
    %{
      chunk_coord: route.chunk_coord,
      tier: route.tier,
      status: route.status,
      reason: skip_reason(route.status)
    }
  end

  defp region_query_summaries(query_entries) do
    query_entries
    |> Enum.group_by(& &1.region_id)
    |> Enum.map(fn {region_id, entries} ->
      anchor = hd(entries)

      %{
        region_id: region_id,
        assigned_scene_node: anchor.assigned_scene_node,
        near_count: Enum.count(entries, &(&1.tier == :near)),
        halo_count: Enum.count(entries, &(&1.tier == :halo))
      }
    end)
    |> Enum.sort_by(& &1.region_id)
  end

  defp remote_mirror_requests(
         cid,
         logical_scene_id,
         center_chunk,
         local_scene_node,
         query_entries
       ) do
    query_entries
    |> Enum.filter(&remote_halo_route?(&1, local_scene_node))
    |> Enum.map(fn entry ->
      entry
      |> Map.take([
        :chunk_coord,
        :tier,
        :region_id,
        :lease_id,
        :assigned_scene_node,
        :query_scope,
        :priority_band,
        :delivery_interval
      ])
      |> Map.merge(%{
        cid: cid,
        logical_scene_id: logical_scene_id,
        center_chunk: center_chunk,
        requester_scene_node: local_scene_node,
        owner_scene_node: entry.assigned_scene_node,
        request_mode: :ghost,
        request_key: {entry.assigned_scene_node, entry.lease_id, entry.chunk_coord},
        status: :planned,
        reason: :remote_halo_route
      })
    end)
  end

  defp remote_halo_route?(
         %{tier: :halo, assigned_scene_node: assigned_scene_node},
         local_scene_node
       ) do
    assigned_scene_node != local_scene_node
  end

  defp remote_halo_route?(_entry, _local_scene_node), do: false

  defp route_sort_key(%{tier: tier, chunk_coord: {x, y, z}}), do: {tier_rank(tier), x, y, z}

  defp priority_band(:near), do: :high
  defp priority_band(:halo), do: :low

  defp query_scope(:near), do: :authoritative
  defp query_scope(:halo), do: :halo_ghost

  defp skip_reason(:region_without_lease), do: :missing_lease
  defp skip_reason(:missing), do: :missing_route

  defp route_region_id(:missing, _entry), do: nil

  defp route_region_id(status, entry) when status in [:assigned, :region_without_lease] do
    case Map.get(entry, :region_id) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError, "#{status} AOI route is missing region_id, got: #{inspect(value)}"
    end
  end

  defp route_lease_id(:assigned, entry) do
    case Map.get(entry, :lease_id) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError, "assigned AOI route is missing lease_id, got: #{inspect(value)}"
    end
  end

  defp route_lease_id(_status, _entry), do: nil

  defp route_scene_node(:assigned, entry) do
    case Map.get(entry, :assigned_scene_node) do
      value when is_atom(value) and not is_nil(value) ->
        value

      value ->
        raise ArgumentError,
              "assigned AOI route is missing assigned_scene_node, got: #{inspect(value)}"
    end
  end

  defp route_scene_node(_status, _entry), do: nil

  defp route_status!(:assigned), do: :assigned
  defp route_status!(:region_without_lease), do: :region_without_lease
  defp route_status!(:missing), do: :missing

  defp route_status!(other) do
    raise ArgumentError, "invalid AOI route status: #{inspect(other)}"
  end

  defp tier!(:near), do: :near
  defp tier!(:halo), do: :halo

  defp tier!(other) do
    raise ArgumentError, "invalid AOI route tier: #{inspect(other)}"
  end

  defp tier_rank(:near), do: 0
  defp tier_rank(:halo), do: 1

  defp normalize_input(%_struct{} = value, _label), do: Map.from_struct(value)
  defp normalize_input(value, _label) when is_map(value), do: value
  defp normalize_input(value, _label) when is_list(value), do: Map.new(value)

  defp normalize_input(value, label) do
    raise ArgumentError, "expected #{label} as map or keyword list, got: #{inspect(value)}"
  end

  defp local_scene_node!(value) when is_atom(value) and not is_nil(value), do: value

  defp local_scene_node!(value) do
    raise ArgumentError, "expected local_scene_node as node atom, got: #{inspect(value)}"
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp non_negative_integer!(value, _field) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer!(value, field) do
    raise ArgumentError, "expected #{field} as non-negative integer, got: #{inspect(value)}"
  end
end
