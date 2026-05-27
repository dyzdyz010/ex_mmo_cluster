defmodule SceneServer.Aoi.RemoteMirrorLedger do
  @moduledoc """
  Runtime ledger for planned remote AOI mirror requests.

  The ledger is a control-plane index only. It records which local AOI items
  need future cross-node ghost/prewarm data for remote-owned halo routes, but it
  does not fetch actors, own remote snapshots, or place anything into live AOI
  fan-out. `AoiItem` remains the local subscription adapter;
  `SceneServer.Worker.Aoi.RemoteMirrorRunner` consumes this ledger as a bounded
  one-pass worker input.
  """

  use GenServer

  @type request_key :: {node(), non_neg_integer(), {integer(), integer(), integer()}}
  @type request_mode :: :ghost | :prewarm
  @type request_group_key :: {non_neg_integer(), request_mode(), request_key()}
  @type request :: %{required(:cid) => non_neg_integer(), required(:request_key) => request_key()}

  @doc "Starts the remote mirror request ledger."
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, %{})
      {:ok, name} -> GenServer.start_link(__MODULE__, %{}, name: name)
      :error -> GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    end
  end

  @doc """
  Replaces all active remote mirror requests for one AOI item CID.

  Requests are grouped by `{logical_scene_id, request_mode, request_key}` so
  cross-node workers can consume ghost and prewarm demand independently without
  treating chunk lease keys as globally unique.
  """
  @spec replace_requests(non_neg_integer(), [request()], GenServer.server()) ::
          map() | {:error, :not_started | {:invalid_request, String.t()}}
  def replace_requests(cid, requests, server \\ __MODULE__) do
    call_if_started(server, {:replace_requests, cid, requests})
  end

  @doc "Withdraws all remote mirror requests for one AOI item CID."
  @spec clear_requests(non_neg_integer(), GenServer.server()) :: map() | {:error, :not_started}
  def clear_requests(cid, server \\ __MODULE__) do
    replace_requests(cid, [], server)
  end

  @doc "Returns a deterministic snapshot of active remote mirror requests."
  @spec snapshot(GenServer.server()) :: map() | {:error, :not_started}
  def snapshot(server \\ __MODULE__) do
    call_if_started(server, :snapshot)
  end

  @doc "Clears the entire ledger. Intended for deterministic tests and CLI smokes."
  @spec reset(GenServer.server()) :: :ok | {:error, :not_started}
  def reset(server \\ __MODULE__) do
    call_if_started(server, :reset)
  end

  @impl true
  def init(_opts), do: {:ok, %{by_cid: %{}}}

  @impl true
  def handle_call({:replace_requests, cid, requests}, _from, state) do
    with {:ok, cid} <- non_negative_integer(cid, :cid),
         {:ok, next_requests} <- normalize_requests(cid, requests) do
      previous_by_key = Map.get(state.by_cid, cid, %{})
      next_by_key = Map.new(next_requests, &{request_group_key(&1), &1})

      next_by_cid =
        if map_size(next_by_key) == 0 do
          Map.delete(state.by_cid, cid)
        else
          Map.put(state.by_cid, cid, next_by_key)
        end

      next_state = %{state | by_cid: next_by_cid}
      summary = replace_summary(cid, previous_by_key, next_by_key, next_state)

      SceneServer.CliObserve.emit("scene_remote_mirror_ledger_updated", observe_summary(summary))
      {:reply, summary, next_state}
    else
      {:error, message} ->
        error = {:error, {:invalid_request, message}}
        SceneServer.CliObserve.emit("scene_remote_mirror_ledger_rejected", %{reason: message})
        {:reply, error, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{by_cid: %{}}}
  end

  defp call_if_started(server, message) when is_pid(server) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> {:error, :not_started}
  end

  defp call_if_started(server, message) when is_atom(server) do
    case Process.whereis(server) do
      nil -> {:error, :not_started}
      pid -> call_if_started(pid, message)
    end
  end

  defp normalize_requests(cid, requests) when is_list(requests) do
    Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, acc} ->
      case normalize_request(cid, request) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_requests(_cid, other) do
    {:error, "remote mirror requests must be a list, got: #{inspect(other)}"}
  end

  defp normalize_request(cid, request) when is_map(request) do
    with {:ok, request_cid} <- fetch_non_negative_integer(request, :cid, :request_cid),
         :ok <- cid_matches(request_cid, cid),
         {:ok, logical_scene_id} <-
           fetch_non_negative_integer(request, :logical_scene_id, :logical_scene_id),
         {:ok, request_key} <- fetch_request_key(request),
         :ok <- validate_owner_scene_node(request, request_key),
         :ok <- validate_request_key_fields(request, request_key),
         :ok <- validate_requester_scene_node(request),
         :ok <- require_value(request, :tier, :halo),
         :ok <- require_value(request, :query_scope, :halo_ghost),
         {:ok, request_mode} <- validate_request_mode(request),
         {:ok, center_chunk} <- fetch_chunk_coord(request, :center_chunk),
         {:ok, region_id} <- fetch_non_negative_integer(request, :region_id, :region_id),
         {:ok, priority_band} <- validate_priority_band(request),
         {:ok, delivery_interval} <- validate_delivery_interval(request),
         :ok <- require_value(request, :status, :planned),
         :ok <- require_value(request, :reason, :remote_halo_route) do
      {:ok,
       sanitized_request(
         request,
         logical_scene_id,
         center_chunk,
         region_id,
         priority_band,
         delivery_interval,
         request_key,
         request_mode
       )}
    end
  end

  defp normalize_request(_cid, other) do
    {:error, "remote mirror request must be a map, got: #{inspect(other)}"}
  end

  defp request_key({owner_scene_node, lease_id, chunk_coord})
       when is_atom(owner_scene_node) and not is_nil(owner_scene_node) and
              is_integer(lease_id) and lease_id >= 0 do
    case chunk_coord(chunk_coord) do
      {:ok, normalized_chunk_coord} -> {:ok, {owner_scene_node, lease_id, normalized_chunk_coord}}
      error -> error
    end
  end

  defp request_key(other) do
    {:error, "invalid remote mirror request_key: #{inspect(other)}"}
  end

  defp sanitized_request(
         request,
         logical_scene_id,
         center_chunk,
         region_id,
         priority_band,
         delivery_interval,
         request_key,
         request_mode
       ) do
    {owner_scene_node, lease_id, chunk_coord} = request_key

    %{
      cid: request.cid,
      logical_scene_id: logical_scene_id,
      center_chunk: center_chunk,
      requester_scene_node: request.requester_scene_node,
      owner_scene_node: owner_scene_node,
      chunk_coord: chunk_coord,
      tier: :halo,
      region_id: region_id,
      lease_id: lease_id,
      assigned_scene_node: owner_scene_node,
      query_scope: :halo_ghost,
      priority_band: priority_band,
      delivery_interval: delivery_interval,
      request_mode: request_mode,
      request_key: request_key,
      status: request.status,
      reason: request.reason
    }
  end

  defp replace_summary(cid, previous_by_key, next_by_key, next_state) do
    previous_keys = previous_by_key |> Map.keys() |> MapSet.new()
    next_keys = next_by_key |> Map.keys() |> MapSet.new()
    snapshot = snapshot_from_state(next_state)
    logical_scene_ids = logical_scene_ids(previous_by_key, next_by_key)

    %{
      cid: cid,
      logical_scene_id: single_logical_scene_id(logical_scene_ids),
      logical_scene_ids: logical_scene_ids,
      added_count: MapSet.size(MapSet.difference(next_keys, previous_keys)),
      removed_count: MapSet.size(MapSet.difference(previous_keys, next_keys)),
      retained_count: MapSet.size(MapSet.intersection(previous_keys, next_keys)),
      active_request_count: map_size(next_by_key),
      total_request_count: snapshot.total_request_count,
      cid_count: snapshot.cid_count,
      owner_scene_count: snapshot.owner_scene_count,
      group_count: snapshot.group_count
    }
  end

  defp observe_summary(summary) do
    Map.update!(summary, :logical_scene_ids, fn logical_scene_ids ->
      Enum.map(logical_scene_ids, &%{logical_scene_id: &1})
    end)
  end

  defp snapshot_from_state(state) do
    requests =
      state.by_cid
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.sort_by(&request_sort_key/1)

    %{
      total_request_count: length(requests),
      cid_count: map_size(state.by_cid),
      owner_scene_count: requests |> Enum.map(& &1.owner_scene_node) |> Enum.uniq() |> length(),
      group_count: requests |> request_groups() |> length(),
      by_cid: by_cid_snapshot(state.by_cid),
      request_groups: request_groups(requests),
      requests: requests
    }
  end

  defp request_groups(requests) do
    requests
    |> Enum.group_by(&request_group_key/1)
    |> Enum.map(fn {{logical_scene_id, request_mode,
                     {owner_scene_node, lease_id, chunk_coord} = request_key}, group_requests} ->
      sorted_requests = Enum.sort_by(group_requests, & &1.cid)

      %{
        logical_scene_id: logical_scene_id,
        request_mode: request_mode,
        request_key: request_key,
        owner_scene_node: owner_scene_node,
        lease_id: lease_id,
        chunk_coord: chunk_coord,
        request_cids: Enum.map(sorted_requests, & &1.cid),
        requester_scene_nodes:
          sorted_requests
          |> Enum.map(& &1.requester_scene_node)
          |> Enum.uniq()
          |> Enum.sort(),
        cid_count: length(sorted_requests),
        canonical_request: hd(sorted_requests)
      }
    end)
    |> Enum.sort_by(&group_sort_key/1)
  end

  defp by_cid_snapshot(by_cid) do
    Map.new(by_cid, fn {cid, by_group_key} ->
      {cid, by_group_key |> Map.values() |> Enum.sort_by(&request_sort_key/1)}
    end)
  end

  defp request_group_key(%{
         logical_scene_id: logical_scene_id,
         request_mode: request_mode,
         request_key: request_key
       }) do
    {logical_scene_id, request_mode, request_key}
  end

  defp request_sort_key(%{
         logical_scene_id: logical_scene_id,
         request_mode: request_mode,
         request_key: {owner_scene_node, lease_id, {x, y, z}},
         cid: cid
       }) do
    {logical_scene_id, owner_scene_node, lease_id, x, y, z, request_mode_rank(request_mode), cid}
  end

  defp group_sort_key(%{
         logical_scene_id: logical_scene_id,
         request_mode: request_mode,
         request_key: {owner_scene_node, lease_id, {x, y, z}}
       }) do
    {logical_scene_id, owner_scene_node, lease_id, x, y, z, request_mode_rank(request_mode)}
  end

  defp logical_scene_ids(previous_by_key, next_by_key) do
    [previous_by_key, next_by_key]
    |> Enum.flat_map(fn by_key -> by_key |> Map.values() |> Enum.map(& &1.logical_scene_id) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp single_logical_scene_id([logical_scene_id]), do: logical_scene_id
  defp single_logical_scene_id(_logical_scene_ids), do: nil

  defp fetch_non_negative_integer(request, key, field) do
    case Map.fetch(request, key) do
      {:ok, value} -> non_negative_integer(value, field)
      :error -> {:error, "missing #{field}"}
    end
  end

  defp non_negative_integer(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative_integer(value, field) do
    {:error, "expected #{field} as non-negative integer, got: #{inspect(value)}"}
  end

  defp cid_matches(cid, cid), do: :ok

  defp cid_matches(request_cid, cid) do
    {:error, "remote mirror request cid #{inspect(request_cid)} does not match #{inspect(cid)}"}
  end

  defp fetch_request_key(request) do
    case Map.fetch(request, :request_key) do
      {:ok, value} -> request_key(value)
      :error -> {:error, "missing request_key"}
    end
  end

  defp fetch_chunk_coord(request, key) do
    case Map.fetch(request, key) do
      {:ok, value} -> chunk_coord(value)
      :error -> {:error, "missing #{key}"}
    end
  end

  defp validate_owner_scene_node(request, {owner_scene_node, _lease_id, _chunk_coord}) do
    case Map.fetch(request, :owner_scene_node) do
      {:ok, ^owner_scene_node} ->
        :ok

      {:ok, other} ->
        {:error,
         "remote mirror request owner_scene_node #{inspect(other)} does not match request_key owner #{inspect(owner_scene_node)}"}

      :error ->
        {:error, "missing owner_scene_node"}
    end
  end

  defp validate_request_key_fields(request, {owner_scene_node, lease_id, chunk_coord}) do
    with :ok <- require_value(request, :assigned_scene_node, owner_scene_node),
         :ok <- require_value(request, :lease_id, lease_id),
         :ok <- require_value(request, :chunk_coord, chunk_coord) do
      :ok
    end
  end

  defp validate_requester_scene_node(request) do
    case Map.fetch(request, :requester_scene_node) do
      {:ok, requester_scene_node}
      when is_atom(requester_scene_node) and not is_nil(requester_scene_node) ->
        :ok

      {:ok, other} ->
        {:error, "expected requester_scene_node as non-nil node atom, got: #{inspect(other)}"}

      :error ->
        {:error, "missing requester_scene_node"}
    end
  end

  defp validate_request_mode(request) do
    case Map.fetch(request, :request_mode) do
      {:ok, mode} when mode in [:ghost, :prewarm] -> {:ok, mode}
      {:ok, other} -> {:error, "expected request_mode :ghost or :prewarm, got: #{inspect(other)}"}
      :error -> {:error, "missing request_mode"}
    end
  end

  defp validate_priority_band(request) do
    case Map.fetch(request, :priority_band) do
      {:ok, band} when band in [:high, :medium, :low] ->
        {:ok, band}

      {:ok, other} ->
        {:error, "expected priority_band :high, :medium, or :low, got: #{inspect(other)}"}

      :error ->
        {:error, "missing priority_band"}
    end
  end

  defp validate_delivery_interval(request) do
    case Map.fetch(request, :delivery_interval) do
      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, other} ->
        {:error, "expected delivery_interval as positive integer, got: #{inspect(other)}"}

      :error ->
        {:error, "missing delivery_interval"}
    end
  end

  defp require_value(request, key, expected) do
    case Map.fetch(request, key) do
      {:ok, ^expected} -> :ok
      {:ok, other} -> {:error, "expected #{key} #{inspect(expected)}, got: #{inspect(other)}"}
      :error -> {:error, "missing #{key}"}
    end
  end

  defp chunk_coord({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {:ok, {x, y, z}}

  defp chunk_coord(other) do
    {:error, "expected chunk coord as {x, y, z}, got: #{inspect(other)}"}
  end

  defp request_mode_rank(:ghost), do: 0
  defp request_mode_rank(:prewarm), do: 1
  defp request_mode_rank(_other), do: 2
end
