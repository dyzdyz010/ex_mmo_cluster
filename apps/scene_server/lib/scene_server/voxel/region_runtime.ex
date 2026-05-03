defmodule SceneServer.Voxel.RegionRuntime do
  @moduledoc """
  Scene-side lease cache and boundary-event guard for voxel regions.

  The scene server owns hot execution only for leases currently granted by
  WorldServer. This process records local leases, caches neighbor lease metadata,
  and rejects ordinary cross-boundary rule events that no longer match the
  current source or target lease after migration.
  """

  use GenServer

  alias SceneServer.CliObserve

  @doc "Starts the scene voxel region runtime."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Applies or replaces a local lease granted to this scene instance."
  def apply_lease(server \\ __MODULE__, lease) do
    GenServer.call(server, {:apply_lease, normalize_lease(lease)})
  end

  @doc "Caches a neighbor lease used to validate source-side boundary events."
  def cache_neighbor_lease(server \\ __MODULE__, lease) do
    GenServer.call(server, {:cache_neighbor_lease, normalize_lease(lease)})
  end

  @doc "Validates and accepts a cross-boundary voxel event if both sides are current."
  def accept_boundary_event(server \\ __MODULE__, event) do
    GenServer.call(server, {:accept_boundary_event, normalize_event(event)})
  end

  @doc "Returns local leases, cached neighbor leases, and seen event ids."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(_opts) do
    {:ok, %{leases: %{}, neighbor_leases: %{}, seen_boundary_events: MapSet.new()}}
  end

  @impl true
  def handle_call({:apply_lease, lease}, _from, state) do
    CliObserve.emit("voxel_lease_applied", fn ->
      Map.take(lease, [
        :logical_scene_id,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch
      ])
    end)

    {:reply, {:ok, lease}, put_in(state.leases[lease.region_id], lease)}
  end

  def handle_call({:cache_neighbor_lease, lease}, _from, state) do
    CliObserve.emit("voxel_neighbor_lease_cached", fn ->
      Map.take(lease, [
        :logical_scene_id,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch
      ])
    end)

    {:reply, {:ok, lease}, put_in(state.neighbor_leases[lease.region_id], lease)}
  end

  def handle_call({:accept_boundary_event, event}, _from, state) do
    case validate_boundary_event(state, event) do
      :ok ->
        next_state = %{
          state
          | seen_boundary_events: MapSet.put(state.seen_boundary_events, event.event_id)
        }

        CliObserve.emit("voxel_boundary_event_accepted", fn ->
          Map.take(event, [
            :event_id,
            :logical_scene_id,
            :source_region_id,
            :target_region_id,
            :event_kind
          ])
        end)

        {:reply, {:ok, :accepted}, next_state}

      {:ok, :duplicate} ->
        {:reply, {:ok, :duplicate}, state}

      {:error, reason} ->
        CliObserve.emit("voxel_boundary_event_rejected", fn ->
          %{
            event_id: event.event_id,
            logical_scene_id: event.logical_scene_id,
            source_region_id: event.source_region_id,
            target_region_id: event.target_region_id,
            reason: reason
          }
        end)

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  defp validate_boundary_event(state, event) do
    cond do
      MapSet.member?(state.seen_boundary_events, event.event_id) ->
        {:ok, :duplicate}

      true ->
        with {:ok, target_lease} <-
               fetch_lease(state.leases, event.target_region_id, :unknown_target_region),
             {:ok, source_lease} <-
               fetch_lease(state.neighbor_leases, event.source_region_id, :unknown_source_region),
             :ok <- validate_target_lease(target_lease, event),
             :ok <- validate_source_lease(source_lease, event) do
          :ok
        end
    end
  end

  defp fetch_lease(leases, region_id, error_reason) do
    case Map.fetch(leases, region_id) do
      {:ok, lease} -> {:ok, lease}
      :error -> {:error, error_reason}
    end
  end

  defp validate_target_lease(lease, event) do
    cond do
      lease.logical_scene_id != event.logical_scene_id ->
        {:error, :target_logical_scene_mismatch}

      lease.lease_id != event.target_lease_id ->
        {:error, :target_lease_mismatch}

      lease.owner_scene_instance_ref != event.target_scene_instance_ref ->
        {:error, :target_scene_mismatch}

      lease.owner_epoch != event.target_owner_epoch ->
        {:error, :target_owner_epoch_mismatch}

      true ->
        :ok
    end
  end

  defp validate_source_lease(lease, event) do
    cond do
      lease.logical_scene_id != event.logical_scene_id ->
        {:error, :source_logical_scene_mismatch}

      lease.lease_id != event.source_lease_id ->
        {:error, :source_lease_mismatch}

      lease.owner_scene_instance_ref != event.source_scene_instance_ref ->
        {:error, :source_scene_mismatch}

      lease.owner_epoch != event.source_owner_epoch ->
        {:error, :source_owner_epoch_mismatch}

      true ->
        :ok
    end
  end

  defp normalize_lease(%struct{} = lease) when is_atom(struct) do
    lease |> Map.from_struct() |> normalize_lease()
  end

  defp normalize_lease(attrs) when is_map(attrs) do
    %{
      logical_scene_id: fetch!(attrs, :logical_scene_id),
      region_id: fetch!(attrs, :region_id),
      lease_id: fetch!(attrs, :lease_id),
      owner_scene_instance_ref: fetch!(attrs, :owner_scene_instance_ref),
      owner_epoch: fetch!(attrs, :owner_epoch),
      bounds_chunk_min: coord!(fetch!(attrs, :bounds_chunk_min)),
      bounds_chunk_max: coord!(fetch!(attrs, :bounds_chunk_max)),
      expires_at_ms: fetch!(attrs, :expires_at_ms)
    }
  end

  defp normalize_event(%struct{} = event) when is_atom(struct) do
    event |> Map.from_struct() |> normalize_event()
  end

  defp normalize_event(attrs) when is_map(attrs) do
    %{
      event_id: fetch!(attrs, :event_id),
      logical_scene_id: fetch!(attrs, :logical_scene_id),
      source_region_id: fetch!(attrs, :source_region_id),
      target_region_id: fetch!(attrs, :target_region_id),
      source_lease_id: fetch!(attrs, :source_lease_id),
      target_lease_id: fetch!(attrs, :target_lease_id),
      source_scene_instance_ref: fetch!(attrs, :source_scene_instance_ref),
      target_scene_instance_ref: fetch!(attrs, :target_scene_instance_ref),
      source_owner_epoch: fetch!(attrs, :source_owner_epoch),
      target_owner_epoch: fetch!(attrs, :target_owner_epoch),
      boundary_chunks: Enum.map(fetch!(attrs, :boundary_chunks), &coord!/1),
      event_kind: fetch!(attrs, :event_kind),
      payload_hash: fetch!(attrs, :payload_hash),
      payload: fetch!(attrs, :payload)
    }
  end

  defp fetch!(attrs, key) do
    Map.fetch!(attrs, key)
  rescue
    KeyError ->
      raise ArgumentError, "missing required #{inspect(key)}"
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end
end
