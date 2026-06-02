defmodule WorldServer.Voxel.DevSeed do
  @moduledoc """
  Idempotent development seeding for browser/client voxel smoke runs.

  The module both prepares the control-plane boundary (region + lease + write
  token) and seeds a small starter terrain footprint so the browser sees real
  server-authoritative voxels on the first subscription instead of an empty
  chunk. Chunk truth remains owned by `SceneServer.Voxel.ChunkProcess`; the
  browser can subscribe or submit intents through Gate without a GUI-only
  setup step. The default region is intentionally wider than the starter
  terrain so browser long-run movement can keep routing partition updates and
  empty authoritative voxel subscriptions instead of drifting after leaving the
  first platform.

  Starter terrain layout (all values fixed for v1):

  - 16 × 16 stone platform at chunk `(0, 0, 0)`, y macro layer 0.
  - Platform fills every macro cell `{mx, 0, mz}` for `mx,mz in 0..15`,
    covering browser world X/Z `[0, 128)` and vertical Y `[0, 8)`.
  - A small source-conductor-load demo circuit sits one macro above the
    platform so first browser load can verify automatic current overlays.

  All writes go through `SceneServer.Voxel.ChunkDirectory.apply_intents/2` —
  the exact same path used by `0x64 VoxelImpactIntent` from clients — using
  the lease that `MapLedger.route_chunk_with_lease/3` returned. The seed is
  idempotent: a second call simply re-issues the lease and skips macros that
  already match the desired stone block.
  """

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.LeaseWriteToken
  alias WorldServer.Voxel.MapLedger

  # Chunk size in macros along one axis. Mirrors
  # `SceneServer.Voxel.Types.chunk_size_in_macro/0` — duplicated locally because
  # `world_server` deliberately does not depend on `scene_server`.
  @chunk_size_in_macro 16

  @default_logical_scene_id 1
  @default_region_id 1_000_001
  @default_bounds_min {-32, -32, -32}
  @default_bounds_max {33, 33, 33}
  @default_owner_scene_instance_ref 1
  @default_owner_epoch 1
  @default_lease_ttl_ms :timer.hours(6)
  @default_chunk_directory :__dev_seed_default_chunk_directory__

  # v1 starter terrain footprint. Chunk (0,0,0) covers world-macro
  # [0,16)×[0,16)×[0,16); the browser renderer treats Y as vertical, so we fill
  # the bottom slab (y-macro 0) with stone. The demo circuit intentionally stays
  # away from the default avatar spawn around {7, 1, 7}; otherwise authoritative
  # collision treats the spawn volume as occupied and long movement appears stuck.
  @platform_chunk {0, 0, 0}
  @platform_y_macro 0
  @platform_material_id 1
  @demo_circuit_blocks [
    {{1, 1, 12}, 6},
    {{2, 1, 12}, 5},
    {{3, 1, 12}, 7},
    {{4, 1, 12}, 5},
    {{4, 1, 13}, 5},
    {{4, 1, 14}, 5},
    {{3, 1, 14}, 5},
    {{2, 1, 14}, 5},
    {{1, 1, 14}, 5},
    {{1, 1, 13}, 5}
  ]
  @legacy_spawn_blocking_demo_circuit_macros [
    {6, 1, 6},
    {7, 1, 6},
    {8, 1, 6},
    {9, 1, 6},
    {9, 1, 7},
    {9, 1, 8},
    {8, 1, 8},
    {7, 1, 8},
    {6, 1, 8},
    {6, 1, 7}
  ]

  @doc """
  Ensures the default browser-development region has a current lease and that
  the starter terrain is seeded for chunk `{0, 0, 0}`.

  If the target center chunk is already routed, the existing route is reused
  and the lease is re-issued. Bounds are half-open, matching
  `RegionAssignment.contains_chunk?/2`. The starter terrain is rewritten
  through `apply_intents` after the lease is current, so subsequent calls are
  idempotent (already-stone cells are skipped).
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
    assigned_scene_node = Keyword.get(opts, :assigned_scene_node)
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms)
    chunk_directory = Keyword.get(opts, :chunk_directory, @default_chunk_directory)
    seed_terrain? = Keyword.get(opts, :seed_terrain?, true)

    case safe_call(fn ->
           MapLedger.route_chunk_with_lease(ledger, logical_scene_id, center_chunk)
         end) do
      {:ok, {:ok, route}} ->
        renew_existing_route(
          ledger,
          route,
          region_id,
          bounds_min,
          bounds_max,
          owner_ref_opt,
          assigned_scene_node,
          lease_ttl_ms,
          center_chunk,
          chunk_directory,
          seed_terrain?
        )

      _missing ->
        attrs = %{
          logical_scene_id: logical_scene_id,
          region_id: region_id,
          bounds_chunk_min: bounds_min,
          bounds_chunk_max: bounds_max,
          owner_scene_instance_ref: owner_ref,
          owner_epoch: owner_epoch,
          assigned_scene_node: assigned_scene_node
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
          terrain = maybe_seed_terrain(chunk_directory, route, seed_terrain?)
          summary = Map.put(summary, :terrain, terrain)
          emit_terrain(summary, terrain)
          {:ok, summary}
        else
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_seed_result, other}}
        end
    end
  end

  defp renew_existing_route(
         ledger,
         route,
         desired_region_id,
         desired_bounds_min,
         desired_bounds_max,
         owner_ref_opt,
         assigned_scene_node,
         lease_ttl_ms,
         center_chunk,
         chunk_directory,
         seed_terrain?
       ) do
    owner_ref = owner_ref_opt || route.lease.owner_scene_instance_ref
    region_id = route.assignment.region_id
    logical_scene_id = route.assignment.logical_scene_id

    with {:ok, _route} <-
           ensure_existing_region_shape(
             ledger,
             route,
             desired_region_id,
             desired_bounds_min,
             desired_bounds_max,
             owner_ref,
             assigned_scene_node
           ),
         {:ok, {:ok, _lease}} <-
           safe_call(fn ->
             MapLedger.issue_lease(ledger, region_id, owner_ref, ttl_ms: lease_ttl_ms)
           end),
         {:ok, {:ok, renewed_route}} <-
           safe_call(fn ->
             MapLedger.route_chunk_with_lease(ledger, logical_scene_id, center_chunk)
           end) do
      summary = summarize_route(renewed_route, :renewed)
      emit_seed(summary)
      terrain = maybe_seed_terrain(chunk_directory, renewed_route, seed_terrain?)
      summary = Map.put(summary, :terrain, terrain)
      emit_terrain(summary, terrain)
      {:ok, summary}
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_seed_renewal_result, other}}
    end
  end

  defp ensure_existing_region_shape(
         ledger,
         route,
         desired_region_id,
         desired_bounds_min,
         desired_bounds_max,
         owner_ref,
         assigned_scene_node
       ) do
    assignment = route.assignment
    desired_scene_node = assigned_scene_node || assignment.assigned_scene_node

    cond do
      assignment.region_id != desired_region_id ->
        {:ok, route}

      assignment.bounds_chunk_min == desired_bounds_min and
        assignment.bounds_chunk_max == desired_bounds_max and
          assignment.assigned_scene_node == desired_scene_node ->
        {:ok, route}

      true ->
        attrs = %{
          logical_scene_id: assignment.logical_scene_id,
          region_id: assignment.region_id,
          bounds_chunk_min: desired_bounds_min,
          bounds_chunk_max: desired_bounds_max,
          owner_scene_instance_ref: owner_ref,
          owner_epoch: assignment.owner_epoch,
          assigned_scene_node: desired_scene_node,
          state: assignment.state,
          summary_hash: assignment.summary_hash,
          version: assignment.version
        }

        case safe_call(fn -> MapLedger.put_region(ledger, attrs) end) do
          {:ok, {:ok, upgraded_assignment}} -> {:ok, %{route | assignment: upgraded_assignment}}
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_seed_region_upgrade_result, other}}
        end
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

  defp emit_terrain(_summary, nil), do: :ok

  defp emit_terrain(summary, terrain) do
    CliObserve.emit("voxel_dev_seed_terrain_ready", %{
      logical_scene_id: summary.logical_scene_id,
      region_id: summary.region_id,
      chunk_coord: terrain.chunk_coord,
      attempted: terrain.attempted,
      written: terrain.written,
      skipped: terrain.skipped,
      errors: terrain.errors,
      max_chunk_version: terrain.max_chunk_version
    })
  end

  defp maybe_seed_terrain(_chunk_directory, _route, false), do: nil

  defp maybe_seed_terrain(chunk_directory, route, true) do
    chunk_directory = chunk_directory_target(route, chunk_directory)

    _ = prepare_scene_lease(chunk_directory, route.lease)

    seed_starter_platform(chunk_directory, route)
  catch
    :exit, reason ->
      %{
        chunk_coord: Tuple.to_list(@platform_chunk),
        attempted: 0,
        written: 0,
        skipped: 0,
        errors: 1,
        max_chunk_version: 0,
        error: inspect({:scene_unavailable, reason})
      }
  end

  defp chunk_directory_target(route, @default_chunk_directory) do
    case route.assignment.assigned_scene_node do
      nil ->
        SceneServer.Voxel.ChunkDirectory

      scene_node when scene_node == node() ->
        SceneServer.Voxel.ChunkDirectory

      scene_node ->
        {SceneServer.Voxel.ChunkDirectory, scene_node}
    end
  end

  defp chunk_directory_target(_route, chunk_directory), do: chunk_directory

  defp prepare_scene_lease({_chunk_directory, scene_node}, lease) when scene_node != node() do
    token = lease |> LeaseWriteToken.from_lease(lease.owner_epoch) |> LeaseWriteToken.to_map()

    _ = :rpc.call(scene_node, SceneServer.Voxel.RegionRuntime, :apply_lease, [lease], 5_000)
    _ = :rpc.call(scene_node, DataService.Voxel.WriteTokenStore, :upsert_token, [token], 5_000)

    :ok
  end

  defp prepare_scene_lease(_chunk_directory, lease) do
    token = lease |> LeaseWriteToken.from_lease(lease.owner_epoch) |> LeaseWriteToken.to_map()

    _ =
      safe_prepare_call(fn ->
        GenServer.call(SceneServer.Voxel.RegionRuntime, {:apply_lease, lease})
      end)

    _ = safe_prepare_call(fn -> DataService.Voxel.WriteTokenStore.upsert_token(token) end)

    :ok
  end

  defp safe_prepare_call(fun) when is_function(fun, 0) do
    fun.()
  catch
    :exit, _reason -> :ok
  end

  # Seeds the 16×16 stone platform on chunk (0,0,0), y macro 0 with one batched
  # `apply_intents` call. This keeps first-login bootstrap from waiting on 256
  # per-cell DataService persists while still using the same Scene-owned
  # authority path as Gate voxel writes.
  defp seed_starter_platform(chunk_directory, route) do
    lease = Map.fetch!(route, :lease)
    logical_scene_id = route.assignment.logical_scene_id
    # `ChunkProcess.normalize_apply_intent` accepts a plain map and runs it
    # through `NormalBlockData.normalize!/1`. We pass the map directly instead
    # of constructing a struct so this module stays decoupled from
    # `SceneServer.Voxel.NormalBlockData`.
    chunk_coord = @platform_chunk

    platform_intents =
      for mx <- 0..(@chunk_size_in_macro - 1),
          mz <- 0..(@chunk_size_in_macro - 1) do
        local_macro = {mx, @platform_y_macro, mz}

        %{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord,
          lease: lease,
          operation: :put_solid_block,
          macro: local_macro,
          block: %{material_id: @platform_material_id, health: 100}
        }
      end

    circuit_intents =
      Enum.map(@demo_circuit_blocks, fn {local_macro, material_id} ->
        %{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord,
          lease: lease,
          operation: :put_solid_block,
          macro: local_macro,
          block: %{material_id: material_id, health: 100}
        }
      end)

    cleanup_intents =
      Enum.map(@legacy_spawn_blocking_demo_circuit_macros, fn local_macro ->
        %{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord,
          lease: lease,
          operation: :break_block,
          macro: local_macro
        }
      end)

    intents = cleanup_intents ++ platform_intents ++ circuit_intents

    case GenServer.call(chunk_directory, {:apply_intents, intents}, 30_000) do
      {:ok, reply} ->
        %{
          written: Map.get(reply, :changed_count, 0),
          skipped: Map.get(reply, :skipped_count, 0),
          errors: 0,
          max_chunk_version: Map.get(reply, :chunk_version, 0),
          attempted: length(intents),
          cleanup_attempted: length(cleanup_intents),
          platform_attempted: length(platform_intents),
          demo_circuit_attempted: length(circuit_intents),
          chunk_coord: Tuple.to_list(chunk_coord)
        }

      {:error, reason} ->
        %{
          written: 0,
          skipped: 0,
          errors: 1,
          max_chunk_version: 0,
          attempted: length(intents),
          cleanup_attempted: length(cleanup_intents),
          platform_attempted: length(platform_intents),
          demo_circuit_attempted: length(circuit_intents),
          chunk_coord: Tuple.to_list(chunk_coord),
          error: inspect(reason)
        }
    end
  end
end
