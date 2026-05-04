defmodule WorldServer.Voxel.DevSeed do
  @moduledoc """
  Idempotent development seeding for browser/client voxel smoke runs.

  The module only prepares the control-plane boundary: it creates or reuses a
  world region, issues the current scene lease, and publishes the DataService
  write token through `WorldServer.Voxel.MapLedger`. Chunk truth remains owned
  by `SceneServer.Voxel.ChunkProcess`; the browser can then subscribe or submit
  intents through Gate without a GUI-only setup step.
  """

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.MapLedger

  @default_logical_scene_id 1
  @default_region_id 1_000_001
  @default_bounds_min {-2, -2, -2}
  @default_bounds_max {3, 3, 3}
  @default_owner_scene_instance_ref 1
  @default_owner_epoch 1
  @default_lease_ttl_ms :timer.hours(6)

  @doc """
  Ensures the default browser-development region has a current lease.

  If the target center chunk is already routed, the existing route is returned.
  Otherwise a region is inserted and leased. Bounds are half-open, matching
  `RegionAssignment.contains_chunk?/2`.
  """
  def ensure_default_region(opts \\ []) when is_list(opts) do
    ledger = Keyword.get(opts, :ledger, MapLedger)
    logical_scene_id = Keyword.get(opts, :logical_scene_id, @default_logical_scene_id)
    region_id = Keyword.get(opts, :region_id, default_region_id(logical_scene_id))
    bounds_min = Keyword.get(opts, :bounds_chunk_min, @default_bounds_min)
    bounds_max = Keyword.get(opts, :bounds_chunk_max, @default_bounds_max)
    center_chunk = Keyword.get(opts, :center_chunk, {0, 0, 0})
    owner_ref_opt = Keyword.get(opts, :owner_scene_instance_ref)
    owner_ref = owner_ref_opt || @default_owner_scene_instance_ref
    owner_epoch = Keyword.get(opts, :owner_epoch, @default_owner_epoch)
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms)

    case safe_call(fn ->
           MapLedger.route_chunk_with_lease(ledger, logical_scene_id, center_chunk)
         end) do
      {:ok, {:ok, route}} ->
        renew_existing_route(ledger, route, owner_ref_opt, lease_ttl_ms, center_chunk)

      _missing ->
        attrs = %{
          logical_scene_id: logical_scene_id,
          region_id: region_id,
          bounds_chunk_min: bounds_min,
          bounds_chunk_max: bounds_max,
          owner_scene_instance_ref: owner_ref,
          owner_epoch: owner_epoch
        }

        with {:ok, {:ok, _assignment}} <- safe_call(fn -> MapLedger.put_region(ledger, attrs) end),
             {:ok, {:ok, _lease}} <-
               safe_call(fn ->
                 MapLedger.issue_lease(ledger, region_id, owner_ref,
                   owner_epoch: owner_epoch,
                   ttl_ms: lease_ttl_ms
                 )
               end),
             {:ok, {:ok, route}} <-
               safe_call(fn ->
                 MapLedger.route_chunk_with_lease(ledger, logical_scene_id, center_chunk)
               end) do
          summary = summarize_route(route, :created)
          emit_seed(summary)
          {:ok, summary}
        else
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_seed_result, other}}
        end
    end
  end

  defp renew_existing_route(ledger, route, owner_ref_opt, lease_ttl_ms, center_chunk) do
    owner_ref = owner_ref_opt || route.lease.owner_scene_instance_ref
    region_id = route.assignment.region_id
    logical_scene_id = route.assignment.logical_scene_id

    with {:ok, {:ok, _lease}} <-
           safe_call(fn ->
             MapLedger.issue_lease(ledger, region_id, owner_ref, ttl_ms: lease_ttl_ms)
           end),
         {:ok, {:ok, renewed_route}} <-
           safe_call(fn ->
             MapLedger.route_chunk_with_lease(ledger, logical_scene_id, center_chunk)
           end) do
      summary = summarize_route(renewed_route, :renewed)
      emit_seed(summary)
      {:ok, summary}
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_seed_renewal_result, other}}
    end
  end

  defp default_region_id(logical_scene_id) do
    if logical_scene_id == @default_logical_scene_id do
      @default_region_id
    else
      logical_scene_id * 1_000_000 + 1
    end
  end

  defp summarize_route(%{assignment: assignment, lease: lease}, status) do
    %{
      status: status,
      logical_scene_id: assignment.logical_scene_id,
      region_id: assignment.region_id,
      bounds_chunk_min: Tuple.to_list(assignment.bounds_chunk_min),
      bounds_chunk_max: Tuple.to_list(assignment.bounds_chunk_max),
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch,
      lease_id: lease.lease_id,
      expires_at_ms: lease.expires_at_ms
    }
  end

  defp safe_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:error, {:ledger_unavailable, reason}}
  end

  defp emit_seed(summary) do
    CliObserve.emit("voxel_dev_seed_ready", summary)
  end
end
