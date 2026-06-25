defmodule GateServer.Voxel.RouteCacheTest do
  use ExUnit.Case, async: true

  alias GateServer.Voxel.RouteCache

  @refresh_window 60_000

  defp route(region_id, min, max, expires_at_ms) do
    %{
      assignment: %{region_id: region_id, bounds_chunk_min: min, bounds_chunk_max: max},
      lease: %{region_id: region_id, expires_at_ms: expires_at_ms, lease_id: region_id * 10}
    }
  end

  test "miss on an empty cache" do
    assert RouteCache.lookup(RouteCache.new(), {0, 0, 0}, 1000, @refresh_window) == :miss
  end

  test "hit when a chunk falls in a cached region with a fresh lease" do
    now = 1_000_000
    cache = RouteCache.put(RouteCache.new(), route(7, {0, 0, 0}, {8, 64, 8}, now + 2_000_000), now)

    assert {:ok, %{lease: %{region_id: 7}}} =
             RouteCache.lookup(cache, {3, 10, 5}, now, @refresh_window)

    # A chunk outside the region's bounds misses.
    assert RouteCache.lookup(cache, {8, 0, 0}, now, @refresh_window) == :miss
  end

  test "a lease inside the refresh window is treated as a miss (forces a re-route → renewal)" do
    now = 1_000_000
    # expires only 30s out, refresh window is 60s → stale.
    cache = RouteCache.put(RouteCache.new(), route(7, {0, 0, 0}, {8, 64, 8}, now + 30_000), now)
    assert RouteCache.lookup(cache, {1, 0, 1}, now, @refresh_window) == :miss
  end

  test "put replaces the entry for the same region (no duplicate growth)" do
    now = 1_000_000
    cache =
      RouteCache.new()
      |> RouteCache.put(route(7, {0, 0, 0}, {8, 64, 8}, now + 2_000_000), now)
      |> RouteCache.put(route(7, {0, 0, 0}, {8, 64, 8}, now + 3_000_000), now)

    assert RouteCache.size(cache) == 1
  end

  test "put evicts already-expired entries as the player roams" do
    now = 1_000_000
    cache =
      RouteCache.new()
      |> RouteCache.put(route(1, {0, 0, 0}, {8, 64, 8}, now - 1_000), now - 5_000)
      |> RouteCache.put(route(2, {8, 0, 0}, {16, 64, 8}, now + 2_000_000), now)

    # Region 1's lease already expired → evicted on the second put.
    assert RouteCache.size(cache) == 1
    assert RouteCache.lookup(cache, {10, 0, 1}, now, @refresh_window) |> elem(0) == :ok
  end

  test "invalidate_region drops a migrated/invalidated region" do
    now = 1_000_000
    cache =
      RouteCache.new()
      |> RouteCache.put(route(7, {0, 0, 0}, {8, 64, 8}, now + 2_000_000), now)
      |> RouteCache.invalidate_region(7)

    assert RouteCache.size(cache) == 0
    assert RouteCache.lookup(cache, {1, 0, 1}, now, @refresh_window) == :miss
  end

  test "routes without bounds / expiry are not cached" do
    now = 1_000_000
    cache = RouteCache.put(RouteCache.new(), %{assignment: %{}, lease: %{}}, now)
    assert RouteCache.size(cache) == 0
  end
end
