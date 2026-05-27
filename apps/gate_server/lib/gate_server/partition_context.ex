defmodule GateServer.PartitionContext do
  @moduledoc """
  Pure connection-level partition context planner.

  Gate owns transport/session state, but World owns routing and leases. This
  module bridges those boundaries without calling World, Scene, or Chat: it
  consumes a server-authoritative movement position plus a World partition
  window and returns the subscription diff and chat-presence metadata that a
  connection process can apply.
  """

  alias GateServer.Voxel.SubscriptionPlanner
  alias SceneServer.Voxel.Types

  @empty_diff %{subscribe_chunks: [], unsubscribe_chunks: [], retained_chunks: []}

  @doc """
  Resolves the next authoritative partition context for one connection.

  When the authoritative position remains in the previous chunk, no World
  window is required and the result intentionally returns no subscription or
  chat-presence changes. When the chunk changes, callers must provide a World
  partition window centered on the new chunk.
  """
  def resolve(attrs) when is_map(attrs) do
    cid = fetch_required!(attrs, :cid)
    logical_scene_id = fetch_required!(attrs, :logical_scene_id)
    location = location!(fetch_required!(attrs, :authoritative_location))
    chunk_coord = Types.chunk_from_world_cm!(location)
    previous_context = Map.get(attrs, :previous_context, %{})
    previous_chunk = Map.get(previous_context, :chunk_coord)
    previous_region_id = Map.get(previous_context, :region_id)

    if previous_chunk == chunk_coord do
      {:ok,
       %{
         cid: cid,
         logical_scene_id: logical_scene_id,
         authoritative_location: location,
         previous_chunk_coord: previous_chunk,
         chunk_coord: chunk_coord,
         previous_region_id: previous_region_id,
         region_id: previous_region_id,
         boundary_kind: :none,
         previous_context: previous_context,
         subscription_plan: nil,
         subscription_diff: @empty_diff,
         chat_presence: nil,
         summary: summary(:none, previous_region_id, previous_region_id, @empty_diff)
       }}
    else
      resolve_changed_chunk(attrs, cid, logical_scene_id, location, chunk_coord, previous_context)
    end
  end

  defp resolve_changed_chunk(
         attrs,
         cid,
         logical_scene_id,
         location,
         chunk_coord,
         previous_context
       ) do
    window = fetch_required!(attrs, :partition_window)
    previous_region_id = Map.get(previous_context, :region_id)

    with {:ok, center_route} <- assigned_center_route(window, chunk_coord),
         {:ok, plan} <- subscription_plan(attrs, cid, logical_scene_id, window),
         diff <-
           subscription_diff(plan, logical_scene_id, Map.get(attrs, :current_subscriptions, %{})) do
      region_id = center_route.region_id
      boundary_kind = if region_id == previous_region_id, do: :chunk, else: :region

      result = %{
        cid: cid,
        logical_scene_id: logical_scene_id,
        authoritative_location: location,
        previous_chunk_coord: Map.get(previous_context, :chunk_coord),
        chunk_coord: chunk_coord,
        previous_region_id: previous_region_id,
        region_id: region_id,
        boundary_kind: boundary_kind,
        previous_context: previous_context,
        center_route: center_route,
        subscription_plan: plan,
        subscription_diff: diff,
        chat_presence: %{
          logical_scene_id: logical_scene_id,
          region_id: region_id,
          chunk_coord: chunk_coord,
          location: location
        },
        summary: summary(boundary_kind, previous_region_id, region_id, diff)
      }

      {:ok, result}
    else
      {:error, :unroutable_center} ->
        {:error, :unroutable_center,
         %{
           cid: cid,
           logical_scene_id: logical_scene_id,
           authoritative_location: location,
           previous_chunk_coord: Map.get(previous_context, :chunk_coord),
           chunk_coord: chunk_coord,
           previous_region_id: previous_region_id,
           region_id: previous_region_id,
           boundary_kind: :unroutable,
           previous_context: previous_context,
           subscription_plan: nil,
           subscription_diff: @empty_diff,
           chat_presence: nil,
           summary: summary(:unroutable, previous_region_id, previous_region_id, @empty_diff)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assigned_center_route(window, chunk_coord) do
    window
    |> map_field!(:route_entries)
    |> Enum.find(&(&1.chunk_coord == chunk_coord))
    |> case do
      %{status: :assigned} = route -> {:ok, route}
      _other -> {:error, :unroutable_center}
    end
  end

  defp subscription_plan(attrs, cid, _logical_scene_id, window) do
    plan_attrs =
      %{
        cid: cid,
        request_id: Map.get(attrs, :request_id, 0),
        partition_window: window,
        known_versions: Map.get(attrs, :known_versions, %{}),
        stream_caps: Map.get(attrs, :stream_caps, %{})
      }
      |> Map.merge(subscription_budget_attrs(attrs))

    {:ok, SubscriptionPlanner.plan(plan_attrs)}
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_subscription_window}
  end

  defp subscription_budget_attrs(attrs) do
    attrs
    |> Map.take([
      :last_server_seq,
      :last_client_ack_seq,
      :reliable_pending_bytes,
      :fast_lane_pending_bytes,
      :recovery_request_count,
      :resync_request_count,
      :snapshot_estimate_bytes,
      :delta_estimate_bytes,
      :field_estimate_bytes,
      :recovery_estimate_bytes
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp subscription_diff(plan, logical_scene_id, current_subscriptions) do
    current_chunks = current_subscription_chunks(current_subscriptions, logical_scene_id)
    target_chunks = plan.subscribe_entries |> Enum.map(& &1.chunk_coord) |> MapSet.new()

    %{
      subscribe_chunks: sorted_chunks(MapSet.difference(target_chunks, current_chunks)),
      unsubscribe_chunks: sorted_chunks(MapSet.difference(current_chunks, target_chunks)),
      retained_chunks: sorted_chunks(MapSet.intersection(current_chunks, target_chunks))
    }
  end

  defp current_subscription_chunks(current_subscriptions, logical_scene_id)
       when is_map(current_subscriptions) do
    current_subscriptions
    |> Enum.flat_map(fn
      {{^logical_scene_id, chunk_coord}, _value} ->
        [coord!(chunk_coord)]

      {_key, %{logical_scene_id: ^logical_scene_id, chunk_coord: chunk_coord}} ->
        [coord!(chunk_coord)]

      {_key, _value} ->
        []
    end)
    |> MapSet.new()
  end

  defp current_subscription_chunks(current_subscriptions, logical_scene_id)
       when is_list(current_subscriptions) do
    current_subscriptions
    |> Enum.flat_map(fn
      {^logical_scene_id, chunk_coord} -> [coord!(chunk_coord)]
      %{logical_scene_id: ^logical_scene_id, chunk_coord: chunk_coord} -> [coord!(chunk_coord)]
      _other -> []
    end)
    |> MapSet.new()
  end

  defp current_subscription_chunks(_current_subscriptions, _logical_scene_id), do: MapSet.new()

  defp summary(boundary_kind, previous_region_id, region_id, diff) do
    %{
      boundary_kind: boundary_kind,
      previous_region_id: previous_region_id,
      region_id: region_id,
      subscribe_count: length(diff.subscribe_chunks),
      unsubscribe_count: length(diff.unsubscribe_chunks),
      retained_count: length(diff.retained_chunks)
    }
  end

  defp sorted_chunks(chunks) do
    chunks
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp map_field!(map, key) when is_map(map), do: Map.fetch!(map, key)

  defp fetch_required!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required key #{inspect(key)}"
    end
  end

  defp location!({x, y, z}) when is_number(x) and is_number(y) and is_number(z), do: {x, y, z}
  defp location!([x, y, z]) when is_number(x) and is_number(y) and is_number(z), do: {x, y, z}

  defp location!(value) do
    raise ArgumentError, "expected authoritative_location as {x, y, z}, got: #{inspect(value)}"
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end
end
