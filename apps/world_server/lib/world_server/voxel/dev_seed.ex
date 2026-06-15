defmodule WorldServer.Voxel.DevSeed do
  @moduledoc """
  Idempotent development seeding for browser/client voxel smoke runs.

  The module both prepares the control-plane boundary (region + lease + write
  token) and seeds a small starter terrain footprint so the browser sees real
  server-authoritative voxels on the first subscription instead of an empty
  chunk. Chunk truth remains owned by `SceneServer.Voxel.ChunkProcess`; the
  browser can subscribe or submit intents through Gate without a GUI-only
  setup step.

  Starter terrain layout:

  - A deterministic value-noise heightmap (rolling hills, `TerrainNoise`) spanning
    a block of chunks (`@platform_chunk_min`..`@platform_chunk_max`, half-open;
    default 5×5 horizontal = chunk x,z ∈ -2..2, y = 0 = 25 chunks). Each `(mx, mz)`
    column is filled solid from `y = 0` up to its noise height (clamped < 16 so it
    stays inside the `y = 0` chunk): surface layer dirt, everything below stone.

  All terrain chunks live in one region (the default region holds 5×5×5 = 125
  chunks), so they share the region lease. `ChunkDirectory.apply_intents/2`
  rejects cross-chunk batches (`:batch_cross_chunk_unsupported`), so each chunk
  is seeded with its own `apply_intents` call, reusing the same lease/route.
  Writes go through the exact same path as `0x64 VoxelImpactIntent` from clients.
  The seed is idempotent: a second call re-issues the lease and skips macros that
  already match the desired block (heights are a pure function of world coords).
  """

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.LeaseWriteToken
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.TerrainNoise

  # Chunk size in macros along one axis. Mirrors
  # `SceneServer.Voxel.Types.chunk_size_in_macro/0` — duplicated locally because
  # `world_server` deliberately does not depend on `scene_server`.
  @chunk_size_in_macro 16

  @default_logical_scene_id 1
  @default_region_id 1_000_001
  @default_bounds_min {-2, -2, -2}
  @default_bounds_max {3, 3, 3}
  @default_owner_scene_instance_ref 1
  @default_owner_epoch 1
  @default_lease_ttl_ms :timer.hours(6)
  @default_chunk_directory :__dev_seed_default_chunk_directory__

  # Starter terrain footprint: a noise heightmap (rolling hills) spanning a block
  # of chunks, each column filled solid from `y = 0` up to its noise height.
  # `@platform_chunk_min`/`@platform_chunk_max` are half-open chunk-coord bounds
  # (matching `RegionAssignment.contains_chunk?/2`) and MUST stay inside the
  # region bounds so every chunk shares the region lease. Default = 5×5 horizontal
  # (chunk x,z ∈ -2..2, y = 0) = 25 chunks, fitting the default region
  # {-2,-2,-2}..{3,3,3} — a multi-chunk terrain so the client exercises
  # large-scale chunk meshing/streaming with real relief, not a flat slab.
  @platform_chunk {0, 0, 0}
  @platform_chunk_min {-2, 0, -2}
  @platform_chunk_max {3, 1, 3}

  # Terrain noise: heights are clamped to [min, max] macro layers. Max is kept
  # < chunk_size_in_macro (16) so each column stays inside its `y = 0` chunk.
  # Surface layer is dirt, everything below is stone, for visible layering.
  @terrain_seed 1337
  @terrain_min_height 2
  @terrain_max_height 8
  @surface_material_id 1
  @subsurface_material_id 2

  # Max intents per `apply_intents` call. The ChunkProcess apply path runs a
  # simulation tick + snapshot encode/persist per call and its cost grows
  # super-linearly with batch size (a few thousand cells in one call hits the
  # 30s GenServer timeout). Terrain (hundreds–thousands of cells per chunk) is
  # seeded in batches of this size — the same size the flat platform used safely.
  @max_intents_per_call 256

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
          owner_ref_opt,
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
         owner_ref_opt,
         lease_ttl_ms,
         center_chunk,
         chunk_directory,
         seed_terrain?
       ) do
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

  # Seeds the flat stone platform across all platform chunks. Each chunk is
  # written with its own batched `apply_intents` call (ChunkDirectory rejects
  # cross-chunk batches), reusing the region lease/route, and the results are
  # aggregated into one terrain summary. This keeps bootstrap off per-cell
  # DataService persists while still using the same Scene-owned authority path
  # as Gate voxel writes.
  defp seed_starter_platform(chunk_directory, route) do
    lease = Map.fetch!(route, :lease)
    logical_scene_id = route.assignment.logical_scene_id

    platform_chunk_coords()
    |> Enum.map(fn chunk_coord ->
      intents = chunk_seed_intents(chunk_coord, logical_scene_id, lease)
      {chunk_coord, length(intents), apply_chunk_intents(chunk_directory, intents)}
    end)
    |> summarize_terrain()
  end

  # Half-open chunk-coord bounds → the list of platform chunk coords.
  defp platform_chunk_coords do
    {min_x, min_y, min_z} = @platform_chunk_min
    {max_x, max_y, max_z} = @platform_chunk_max

    for cx <- min_x..(max_x - 1),
        cy <- min_y..(max_y - 1),
        cz <- min_z..(max_z - 1) do
      {cx, cy, cz}
    end
  end

  # The seed intents for one chunk: each (mx, mz) column filled solid from y=0 up
  # to its noise height (surface = dirt, below = stone). Heights are clamped < 16
  # so every column stays inside this `y = 0` chunk.
  # `ChunkProcess.normalize_apply_intent` accepts a plain map (run through
  # `NormalBlockData.normalize!/1`), so we pass maps directly to stay decoupled
  # from `SceneServer.Voxel.NormalBlockData`.
  defp chunk_seed_intents({cx, _cy, cz} = chunk_coord, logical_scene_id, lease) do
    for mx <- 0..(@chunk_size_in_macro - 1),
        mz <- 0..(@chunk_size_in_macro - 1),
        height = column_height(cx, cz, mx, mz),
        my <- 0..(height - 1),
        my < @chunk_size_in_macro do
      material_id =
        if my == height - 1, do: @surface_material_id, else: @subsurface_material_id

      %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord,
        lease: lease,
        operation: :put_solid_block,
        macro: {mx, my, mz},
        block: %{material_id: material_id, health: 100}
      }
    end
  end

  # Noise surface height (count of solid macro layers) at the world-macro column
  # of local (mx, mz) within chunk (cx, _, cz).
  defp column_height(cx, cz, mx, mz) do
    wx = cx * @chunk_size_in_macro + mx
    wz = cz * @chunk_size_in_macro + mz

    TerrainNoise.height(wx, wz,
      seed: @terrain_seed,
      min_height: @terrain_min_height,
      max_height: @terrain_max_height
    )
  end

  # Per-chunk apply_intents, split into bounded sub-batches (see
  # @max_intents_per_call) and aggregated, isolating a scene exit so one bad
  # chunk does not abort the whole terrain seed.
  defp apply_chunk_intents(_chunk_directory, []),
    do: {:ok, %{changed_count: 0, skipped_count: 0, chunk_version: 0}}

  defp apply_chunk_intents(chunk_directory, intents) do
    intents
    |> Enum.chunk_every(@max_intents_per_call)
    |> Enum.reduce_while(
      {:ok, %{changed_count: 0, skipped_count: 0, chunk_version: 0}},
      fn batch, {:ok, agg} ->
        case apply_intents_batch(chunk_directory, batch) do
          {:ok, reply} ->
            merged = %{
              changed_count: agg.changed_count + Map.get(reply, :changed_count, 0),
              skipped_count: agg.skipped_count + Map.get(reply, :skipped_count, 0),
              chunk_version: max(agg.chunk_version, Map.get(reply, :chunk_version, 0))
            }

            {:cont, {:ok, merged}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end
    )
  end

  defp apply_intents_batch(chunk_directory, batch) do
    GenServer.call(chunk_directory, {:apply_intents, batch}, 30_000)
  catch
    :exit, reason -> {:error, {:scene_unavailable, reason}}
  end

  # Folds per-chunk apply_intents results into one terrain summary. Keeps the
  # keys `emit_terrain/2` and the dev HTTP response consume (chunk_coord points
  # at the center chunk for back-compat), adding chunk_count / chunk_errors.
  defp summarize_terrain(results) do
    base =
      Enum.reduce(
        results,
        %{written: 0, skipped: 0, errors: 0, max_chunk_version: 0, chunk_errors: []},
        fn
          {_chunk_coord, _attempted, {:ok, reply}}, acc ->
            %{
              acc
              | written: acc.written + Map.get(reply, :changed_count, 0),
                skipped: acc.skipped + Map.get(reply, :skipped_count, 0),
                max_chunk_version: max(acc.max_chunk_version, Map.get(reply, :chunk_version, 0))
            }

          {chunk_coord, _attempted, {:error, reason}}, acc ->
            %{
              acc
              | errors: acc.errors + 1,
                chunk_errors: [
                  %{chunk_coord: Tuple.to_list(chunk_coord), error: inspect(reason)}
                  | acc.chunk_errors
                ]
            }
        end
      )

    chunk_count = length(results)
    attempted = Enum.reduce(results, 0, fn {_c, n, _r}, acc -> acc + n end)

    %{
      attempted: attempted,
      written: base.written,
      skipped: base.skipped,
      errors: base.errors,
      max_chunk_version: base.max_chunk_version,
      chunk_count: chunk_count,
      chunk_coord: Tuple.to_list(@platform_chunk),
      chunk_errors: Enum.reverse(base.chunk_errors)
    }
  end
end
