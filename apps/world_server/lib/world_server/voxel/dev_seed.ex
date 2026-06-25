defmodule WorldServer.Voxel.DevSeed do
  @moduledoc """
  Idempotent development **WorldGen prewarm** for browser/client voxel smoke runs.

  阶段1 起 DevSeed 不再定义任何 region 边界。世界的分区是隐式的(`RegionGrid`):
  region = f(chunk_coord),由 `MapLedger` 在路由 miss 时懒物化。DevSeed 退化为纯粹的
  **出生点地形预热**——把出生点周围一小片 footprint 的 chunk 经 `route_chunks_with_leases_ensuring`
  路由(顺带物化它们所在的 grid region + 取得各自 region 的 lease),再把起始地形写进去。
  Chunk truth 仍归 `SceneServer.Voxel.ChunkProcess`;写入走与客户端 `0x64 VoxelImpactIntent`
  完全相同的 `apply_intents` 权威路径。

  与旧版的关键差异:footprint 可能跨多个 grid region(默认 footprint 5×5,在 `Sx=Sz=8`
  下横跨 2×2 = 最多 4 个 region),因此每个 chunk 用**它所在 region 的 lease**写入,而非
  全 footprint 共用一个固定 region 的 lease。物化需要一个已注册的 Scene 节点
  (`SceneNodeRegistry`);没有时返回 `{:error, :scene_node_unassigned}`,由
  `DefaultRegionBootstrapper` 重试。

  Starter terrain layout:

  - A deterministic value-noise heightmap (rolling hills, `TerrainNoise`) over the
    footprint chunks. Each `(mx, mz)` column is filled solid from `y = 0` up to its
    noise height (clamped < 16 so it stays inside the `y = 0` chunk): surface layer
    dirt, everything below stone.

  The seed is idempotent: a second call re-routes (regions already materialized →
  same leases, no churn) and skips macros that already match the desired block
  (heights are a pure function of world coords).
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
  @default_chunk_directory :__dev_seed_default_chunk_directory__

  # Starter terrain footprint: a noise heightmap (rolling hills) over a block of
  # chunks centered on spawn. `@platform_chunk_min`/`@platform_chunk_max` are
  # half-open chunk-coord bounds. Default = 5×5 horizontal (chunk x,z ∈ -2..2,
  # y = 0) = 25 chunks — a multi-chunk terrain so the client exercises large-scale
  # chunk meshing/streaming with real relief, not a flat slab. These chunks are
  # routed/materialized on the implicit grid; the footprint is NOT a region.
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
  # seeded in batches of this size.
  @max_intents_per_call 256

  @doc """
  Ensures the spawn-area footprint is materialized on the implicit grid and the
  starter terrain is seeded.

  Routes every footprint chunk through `MapLedger.route_chunks_with_leases_ensuring/3`,
  which lazily materializes each chunk's grid region (assign Scene owner + monotonic
  epoch + lease) and returns the per-chunk `{assignment, lease}`. Terrain is then
  written per chunk through `apply_intents`, so the call is idempotent.

  Options: `:ledger`, `:logical_scene_id`, `:footprint_chunks` (list of chunk
  coords; defaults to the 5×5 platform), `:chunk_directory`, `:seed_terrain?`.
  """
  def ensure_default_region(opts \\ []) when is_list(opts) do
    ledger = Keyword.get(opts, :ledger, MapLedger)
    logical_scene_id = Keyword.get(opts, :logical_scene_id, @default_logical_scene_id)
    chunk_directory = Keyword.get(opts, :chunk_directory, @default_chunk_directory)
    seed_terrain? = Keyword.get(opts, :seed_terrain?, true)
    footprint = Keyword.get(opts, :footprint_chunks, platform_chunk_coords())

    case route_footprint(ledger, logical_scene_id, footprint) do
      {:ok, routes} ->
        terrain = maybe_seed_terrain(chunk_directory, logical_scene_id, routes, seed_terrain?)
        summary = build_summary(logical_scene_id, routes, terrain)
        emit_seed(summary)
        emit_terrain(summary, terrain)
        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Route (and lazily materialize) every footprint chunk's grid region in one
  # batch ledger call, returning %{chunk_coord => %{assignment, lease}}.
  defp route_footprint(ledger, logical_scene_id, footprint) do
    case safe_call(fn ->
           MapLedger.route_chunks_with_leases_ensuring(ledger, logical_scene_id, footprint)
         end) do
      {:ok, {:ok, routes}} -> {:ok, routes}
      {:ok, {:error, {_chunk_coord, reason}}} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # JSON-safe summary. Includes one entry per distinct materialized region so the
  # dev HTTP endpoint / CLI observer can see what was prepared. No tuples.
  defp build_summary(logical_scene_id, routes, terrain) do
    regions =
      routes
      |> Map.values()
      |> Enum.uniq_by(& &1.assignment.region_id)
      |> Enum.sort_by(& &1.assignment.region_id)
      |> Enum.map(fn %{assignment: assignment, lease: lease} ->
        %{
          region_id: assignment.region_id,
          bounds_chunk_min: Tuple.to_list(assignment.bounds_chunk_min),
          bounds_chunk_max: Tuple.to_list(assignment.bounds_chunk_max),
          assigned_scene_node: node_string(assignment.assigned_scene_node),
          owner_scene_instance_ref: lease.owner_scene_instance_ref,
          owner_epoch: lease.owner_epoch,
          lease_id: lease.lease_id
        }
      end)

    %{
      status: :ready,
      logical_scene_id: logical_scene_id,
      region_count: length(regions),
      chunk_count: map_size(routes),
      regions: regions,
      terrain: terrain
    }
  end

  defp node_string(nil), do: nil
  defp node_string(node) when is_atom(node), do: Atom.to_string(node)

  defp safe_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:error, {:ledger_unavailable, reason}}
  end

  defp emit_seed(summary) do
    CliObserve.emit("voxel_dev_seed_ready", %{
      logical_scene_id: summary.logical_scene_id,
      region_count: summary.region_count,
      chunk_count: summary.chunk_count,
      region_ids: Enum.map(summary.regions, & &1.region_id)
    })
  end

  defp emit_terrain(_summary, nil), do: :ok

  defp emit_terrain(summary, terrain) do
    CliObserve.emit("voxel_dev_seed_terrain_ready", %{
      logical_scene_id: summary.logical_scene_id,
      region_count: summary.region_count,
      chunk_coord: terrain.chunk_coord,
      attempted: terrain.attempted,
      written: terrain.written,
      skipped: terrain.skipped,
      errors: terrain.errors,
      max_chunk_version: terrain.max_chunk_version
    })
  end

  defp maybe_seed_terrain(_chunk_directory, _logical_scene_id, _routes, false), do: nil

  defp maybe_seed_terrain(chunk_directory, logical_scene_id, routes, true) do
    # Prepare each distinct region's lease on its owning Scene node once (apply_lease
    # + write token), then seed terrain per chunk using that chunk's region lease.
    routes
    |> Map.values()
    |> Enum.uniq_by(& &1.assignment.region_id)
    |> Enum.each(fn %{assignment: assignment, lease: lease} ->
      chunk_directory
      |> resolve_chunk_directory(assignment)
      |> prepare_scene_lease(lease)
    end)

    seed_starter_platform(chunk_directory, logical_scene_id, routes)
  catch
    :exit, reason ->
      %{
        chunk_coord: Tuple.to_list(@platform_chunk),
        attempted: 0,
        written: 0,
        skipped: 0,
        errors: 1,
        max_chunk_version: 0,
        chunk_count: 0,
        chunk_errors: [],
        error: inspect({:scene_unavailable, reason})
      }
  end

  # In single-node dev every region's assigned_scene_node is this node, so the
  # local ChunkDirectory is the target; a remote owner gets a `{Module, node}`
  # tuple. An explicit `:chunk_directory` opt (tests) overrides routing.
  defp resolve_chunk_directory(@default_chunk_directory, assignment) do
    case assignment.assigned_scene_node do
      nil -> SceneServer.Voxel.ChunkDirectory
      scene_node when scene_node == node() -> SceneServer.Voxel.ChunkDirectory
      scene_node -> {SceneServer.Voxel.ChunkDirectory, scene_node}
    end
  end

  defp resolve_chunk_directory(chunk_directory, _assignment), do: chunk_directory

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

  # Seeds the noise terrain across all footprint chunks. Each chunk is written
  # with its own batched `apply_intents` call (ChunkDirectory rejects cross-chunk
  # batches), reusing **that chunk's region lease**, and the results are aggregated
  # into one terrain summary.
  defp seed_starter_platform(chunk_directory, logical_scene_id, routes) do
    routes
    |> Enum.sort_by(fn {chunk_coord, _route} -> chunk_coord end)
    |> Enum.map(fn {chunk_coord, %{assignment: assignment, lease: lease}} ->
      target = resolve_chunk_directory(chunk_directory, assignment)

      # Fast path: a chunk already persisted with substantial terrain is skipped
      # via a cheap, decode-free DataService check. Fail-safe: any not-found /
      # too-small / error chunk still gets seeded.
      if already_seeded?(logical_scene_id, chunk_coord) do
        {chunk_coord, 0, {:ok, %{changed_count: 0, skipped_count: 0, chunk_version: 0}}}
      else
        intents = chunk_seed_intents(chunk_coord, logical_scene_id, lease)
        {chunk_coord, length(intents), apply_chunk_intents(target, intents)}
      end
    end)
    |> summarize_terrain()
  end

  # A persisted chunk whose snapshot payload is large enough to carry the seeded
  # terrain. Decode-free and fail-safe toward re-seeding.
  @seeded_chunk_min_bytes 85_000
  defp already_seeded?(logical_scene_id, chunk_coord) do
    case DataService.Voxel.ChunkSnapshotStore.get_snapshot(logical_scene_id, chunk_coord) do
      {:ok, %{data: data}} when is_binary(data) -> byte_size(data) >= @seeded_chunk_min_bytes
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  # Half-open chunk-coord bounds → the list of footprint chunk coords.
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

  # Folds per-chunk apply_intents results into one terrain summary (JSON-safe).
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
