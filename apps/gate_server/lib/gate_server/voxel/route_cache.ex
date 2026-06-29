defmodule GateServer.Voxel.RouteCache do
  @moduledoc """
  Per-connection cache of voxel region routes (阶段2-bis,评审 F5)。

  Region ownership is **stable** (a region's owner/lease changes only on migration
  or lease renewal), but Gate previously called the World control plane
  (`WorldServer.Voxel.MapLedger`) **once per chunk** on every subscribe / edit —
  funnelling every player's per-chunk traffic through one GenServer. This cache
  lets Gate answer a chunk's route locally when the chunk falls inside an
  already-routed region whose lease is still fresh, hitting the control plane only
  when **entering a new region** or when the cached lease nears expiry (so the
  re-route triggers a World-side renewal before it actually expires).

  Pure data structure (a list of region entries — a player's live AOI spans only a
  handful of regions). Matching is by the route's own `assignment` bounds, so Gate
  never needs to know the `RegionGrid` partition.
  """

  @typedoc "One cached region route: half-open chunk AABB + the route payload + lease expiry."
  @type entry :: %{
          region_id: term(),
          bounds_chunk_min: {integer(), integer(), integer()},
          bounds_chunk_max: {integer(), integer(), integer()},
          expires_at_ms: integer(),
          route: map()
        }

  @type t :: %{entries: [entry()]}

  @doc "An empty cache."
  @spec new() :: t()
  def new, do: %{entries: []}

  @doc """
  Looks up a chunk's route. Returns `{:ok, route}` when a cached region contains
  the chunk and its lease is still fresh past `refresh_window_ms` (so a fresh
  result is never about to expire), otherwise `:miss`.
  """
  @spec lookup(t(), {integer(), integer(), integer()}, integer(), integer()) ::
          {:ok, map()} | :miss
  def lookup(%{entries: entries}, chunk_coord, now_ms, refresh_window_ms) do
    case Enum.find(entries, fn entry ->
           fresh?(entry, now_ms, refresh_window_ms) and contains?(entry, chunk_coord)
         end) do
      nil -> :miss
      %{route: route} -> {:ok, route}
    end
  end

  @doc """
  Caches a freshly-fetched route (replacing any prior entry for the same region),
  and drops entries whose lease has already expired so the cache cannot grow
  without bound as a player roams.
  """
  @spec put(t(), map(), integer()) :: t()
  def put(%{entries: entries}, route, now_ms) do
    case entry_from_route(route) do
      nil ->
        %{entries: entries}

      entry ->
        kept =
          Enum.reject(entries, fn existing ->
            existing.region_id == entry.region_id or expired?(existing, now_ms)
          end)

        %{entries: [entry | kept]}
    end
  end

  @doc "Drops the cached entry for a region (e.g. on a `ChunkInvalidate` / migration)."
  @spec invalidate_region(t(), term()) :: t()
  def invalidate_region(%{entries: entries}, region_id) do
    %{entries: Enum.reject(entries, &(&1.region_id == region_id))}
  end

  @doc "Number of cached regions (for tests / debug)."
  @spec size(t()) :: non_neg_integer()
  def size(%{entries: entries}), do: length(entries)

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp entry_from_route(%{assignment: assignment, lease: lease}) do
    with min when not is_nil(min) <- Map.get(assignment, :bounds_chunk_min),
         max when not is_nil(max) <- Map.get(assignment, :bounds_chunk_max),
         expires when is_integer(expires) <- Map.get(lease, :expires_at_ms) do
      %{
        region_id: Map.get(assignment, :region_id),
        bounds_chunk_min: min,
        bounds_chunk_max: max,
        expires_at_ms: expires,
        route: %{assignment: assignment, lease: lease}
      }
    else
      _ -> nil
    end
  end

  defp entry_from_route(_route), do: nil

  defp fresh?(entry, now_ms, refresh_window_ms) do
    entry.expires_at_ms > now_ms + refresh_window_ms
  end

  defp expired?(entry, now_ms), do: entry.expires_at_ms <= now_ms

  defp contains?(
         %{bounds_chunk_min: {minx, miny, minz}, bounds_chunk_max: {maxx, maxy, maxz}},
         {cx, cy, cz}
       ) do
    cx >= minx and cx < maxx and cy >= miny and cy < maxy and cz >= minz and cz < maxz
  end
end
