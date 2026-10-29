defmodule VoxelRegion.PayloadCacheEntryTest do
  @moduledoc "只测试：实际缓存owner维护条目检查结论的替换、删除、LRU生命周期，外部仍只运输字节与纯协议头。"
  use ExUnit.Case, async: true
  alias VoxelRegion.World.{Cache, Payloads}

  test "检查结论不跨替换或淘汰，导出导入也不带标记" do
    {:ok, bytes, header} = VoxelRegion.TestSupport.Source.read(%{root: "unused", observer: self()}, 0, {0,0,0})
    {:ok, next_bytes, next_header} = VoxelRegion.TestSupport.Source.read(%{root: "unused", observer: self()}, 0, {1,0,0})
    key = {0, {0,0,0}}
    probe = %{cache: Cache.new(1_000_000)}
    first = Payloads.cache_put(probe, key, bytes, header)
    second = Payloads.cache_put(probe, {0, {1,0,0}}, next_bytes, next_header)
    # 上限能容纳任一完整条目的声明重量，但不能同时容纳两份；包含 typed 元信息。
    limit = max(Cache.stats(first.cache).bytes, Cache.stats(second.cache).bytes)
    state = %{cache: Cache.new(limit)}
    checked = state |> Payloads.cache_put(key, bytes, header) |> Payloads.mark_liquid_checked({0,0,0})
    assert {:checked, _} = Payloads.checked_liquid(checked, {0,0,0})
    assert Payloads.export_cached(checked) == %{key => {bytes, header}}
    replaced = Payloads.cache_put(checked, key, bytes, header)
    assert :unchecked = Payloads.checked_liquid(replaced, {0,0,0})
    assert :unchecked = checked |> Payloads.cache_delete(key) |> Payloads.checked_liquid({0,0,0})
    evicted = Payloads.cache_put(checked, {0, {1,0,0}}, next_bytes, next_header)
    assert :unchecked = Payloads.checked_liquid(evicted, {0,0,0})
    refute Payloads.cached?(evicted, key)
    assert Payloads.cached?(evicted, {0, {1,0,0}})
    assert Cache.stats(evicted.cache).evictions == 1
  end
end
