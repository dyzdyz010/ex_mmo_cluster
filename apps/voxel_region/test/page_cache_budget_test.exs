defmodule VoxelRegion.PageCacheBudgetTest do
  @moduledoc "只测试：纯有界缓存的命名空间竞争、不可变输入、请求 pin 与原子失败；不启动 World、数据库或网络。"
  use ExUnit.Case, async: true

  alias VoxelRegion.World.Cache

  test "namespace 计数和 keys 随插入替换删除维护，payload 与 prefab 不串用" do
    payload = payload(1)
    prefab = {:prefab, <<7::256>>}
    {:ok, cache} = Cache.put(Cache.new(100_000), payload, <<1, 2, 3>>, version())
    {:ok, cache} = Cache.put(cache, prefab, <<4, 5, 6, 7, 8>>, <<7::256>>)

    assert Cache.stats(cache).namespaces == %{
             payload: %{entries: 1, value_bytes: 3},
             prefab: %{entries: 1, value_bytes: 5}
           }

    assert Cache.keys(cache, :payload) == [payload]
    assert Cache.keys(cache, :prefab) == [prefab]
    {:ok, cache} = Cache.put(cache, payload, <<1, 2, 3, 4, 5, 6, 7>>, {7, 10, 12})

    assert Cache.stats(cache).namespaces == %{
             payload: %{entries: 1, value_bytes: 7},
             prefab: %{entries: 1, value_bytes: 5}
           }

    cache = Cache.delete(cache, prefab)
    assert Cache.stats(cache).namespaces == %{
             payload: %{entries: 1, value_bytes: 7},
             prefab: %{entries: 0, value_bytes: 0}
           }

    assert Cache.keys(cache, :payload) == [payload]
    assert Cache.keys(cache, :prefab) == []
  end

  test "payload 与 prefab 共用预算，旧的高层 payload 也会被最近使用淘汰" do
    high = {:payload, {5, {-1, 2, 3}}}
    low = {:payload, {0, {4, -5, 6}}}
    prefab = {:prefab, <<7::256>>}
    bytes = :binary.copy(<<41>>, 1024)
    version = {7, 9, 11}
    probe = Cache.new(100_000)
    {:ok, probe} = Cache.put(probe, high, bytes, version)
    {:ok, probe} = Cache.put(probe, low, bytes, version)
    {:ok, probe} = Cache.put(probe, prefab, bytes, <<7::256>>)
    probe = Cache.delete(probe, high)
    limit = Cache.stats(probe).bytes
    cache = Cache.new(limit)
    {:ok, cache} = Cache.put(cache, high, bytes, version)
    {:ok, cache} = Cache.put(cache, low, bytes, version)
    {:ok, cache} = Cache.put(cache, prefab, bytes, <<7::256>>)

    assert :miss = Cache.peek(cache, high)
    assert {:ok, %{bytes: ^bytes, version: ^version}} = Cache.peek(cache, low)
    assert {:ok, %{bytes: ^bytes, version: <<7::256>>}} = Cache.peek(cache, prefab)
    assert Cache.stats(cache).bytes <= limit
    assert Cache.stats(cache).evictions == 1
    assert Cache.stats(cache).namespaces == %{
             payload: %{entries: 1, value_bytes: 1024},
             prefab: %{entries: 1, value_bytes: 1024}
           }

    assert Cache.keys(cache, :payload) == [low]
    assert Cache.keys(cache, :prefab) == [prefab]
  end

  test "get 更新最近使用而 peek 不改变淘汰次序，miss 只计一次" do
    [a, b, c, d] = Enum.map(1..4, &payload/1)
    bytes = :binary.copy(<<42>>, 1024)
    limit = footprint([{a, bytes}, {b, bytes}])
    cache = Cache.new(limit)
    {:ok, cache} = Cache.put(cache, a, bytes, version())
    {:ok, cache} = Cache.put(cache, b, bytes, version())
    assert {:ok, _} = Cache.peek(cache, a)
    {:ok, cache} = Cache.put(cache, c, bytes, version())
    assert :miss = Cache.peek(cache, a)
    assert {:ok, _, cache} = Cache.get(cache, b)
    {:ok, cache} = Cache.put(cache, d, bytes, version())
    assert :miss = Cache.peek(cache, c)
    assert {:ok, _} = Cache.peek(cache, b)
    assert {:miss, cache} = Cache.get(cache, a)
    assert %{hits: 1, misses: 1, evictions: 2} = Cache.stats(cache)
  end

  test "替换退休旧 pin 与检查标记，已捕获字节和版本仍保持原输入" do
    key = payload(1)
    owner = make_ref()
    old = :binary.copy(<<43>>, 1024)
    fresh = :binary.copy(<<44>>, 512)
    checked = metadata(true)
    {:ok, cache} = Cache.put(Cache.new(100_000), key, old, version(), checked)
    {:ok, captured} = Cache.peek(cache, key)
    {:ok, cache} = Cache.pin(cache, [key], owner)
    next_version = {7, 10, 12}
    {:ok, cache} = Cache.put(cache, key, fresh, next_version, metadata(false))

    assert {:ok, %{bytes: ^fresh, version: ^next_version, metadata: %{liquid_checked: false}}} =
             Cache.peek(cache, key)

    assert %{pins: 0, pinned_entries: 0, entries: 1, value_bytes: 512} = Cache.stats(cache)
    assert Cache.release(cache, owner) == cache
    assert captured.bytes == old
    assert captured.version == version()
    assert captured.metadata == checked
  end

  test "delete 同时释放各 owner 的关系与权重，重复 delete 和 release 幂等" do
    [a, b] = Enum.map(1..2, &payload/1)
    owner = make_ref()
    other = make_ref()
    {:ok, cache} = Cache.put(Cache.new(100_000), a, <<1>>, version())
    {:ok, cache} = Cache.put(cache, b, <<2>>, version())
    {:ok, cache} = Cache.pin(cache, [a, b], owner)
    {:ok, cache} = Cache.pin(cache, [a], other)
    cache = Cache.delete(cache, a)
    assert %{pins: 1, pinned_entries: 1, entries: 1} = Cache.stats(cache)
    assert Cache.delete(cache, a) == cache
    assert Cache.release(cache, other) == cache
    cache = Cache.delete(cache, b)

    assert %{
             bytes: 0,
             value_bytes: 0,
             metadata_bytes: 0,
             pins: 0,
             pinned_entries: 0,
             entries: 0,
             evictions: 0
           } = Cache.stats(cache)

    assert Cache.release(cache, owner) == cache
  end

  test "pin 保护旧条目，最后 owner 释放后仍按原最近使用次序淘汰" do
    [a, b, c, d] = Enum.map(1..4, &payload/1)
    bytes = :binary.copy(<<45>>, 1024)
    owner = make_ref()
    limit = footprint([{a, bytes}, {b, bytes}], [a], owner)
    {:ok, cache} = Cache.put(Cache.new(limit), a, bytes, version())
    {:ok, cache} = Cache.put(cache, b, bytes, version())
    {:ok, cache} = Cache.pin(cache, [a], owner)
    same = cache
    assert {:ok, ^same} = Cache.pin(cache, [a, a], owner)
    {:ok, cache} = Cache.put(cache, c, bytes, version())
    assert {:ok, _} = Cache.peek(cache, a)
    assert :miss = Cache.peek(cache, b)
    cache = Cache.release(cache, owner)
    {:ok, cache} = Cache.put(cache, d, bytes, version())
    assert :miss = Cache.peek(cache, a)
    assert {:ok, _} = Cache.peek(cache, c)
    assert %{pins: 0, pinned_entries: 0} = Cache.stats(cache)
  end

  test "全部 pin 时 put 容量不足及超大替换均原子失败，不破坏旧输入或 LRU" do
    [a, b, c] = Enum.map(1..3, &payload/1)
    bytes = :binary.copy(<<46>>, 1024)
    owner = make_ref()
    limit = footprint([{a, bytes}, {b, bytes}], [a, b], owner)
    {:ok, cache} = Cache.put(Cache.new(limit), a, bytes, version())
    {:ok, cache} = Cache.put(cache, b, bytes, version())
    {:ok, cache} = Cache.pin(cache, [a, b], owner)
    original = cache
    assert {:error, :pinned_capacity, ^original} = Cache.put(cache, c, bytes, version())

    assert {:error, :too_large, ^original} =
             Cache.put(cache, a, :binary.copy(<<1>>, 100_000), {7, 10, 12})

    assert {:ok, %{bytes: ^bytes}} = Cache.peek(cache, a)
  end

  test "pin 缺一个 key 不部分接纳，新增关系本身也不能绕过预算" do
    key = payload(1)
    absent = payload(2)
    owner = make_ref()
    {:ok, probe} = Cache.put(Cache.new(100_000), key, <<1>>, version())
    {:ok, cache} = Cache.put(Cache.new(Cache.stats(probe).bytes), key, <<1>>, version())
    original = cache
    assert {:error, {:missing, ^absent}, ^original} = Cache.pin(cache, [key, absent], owner)
    assert {:error, :pinned_capacity, ^original} = Cache.pin(cache, [key], owner)
    assert {:error, :invalid_owner, ^original} = Cache.pin(cache, [key], self())
    assert Cache.release(cache, owner) == cache
  end

  test "pin 的缺失 key 即使是 nil 仍显式失败，不被当作查找完成的哨兵" do
    cache = Cache.new(100_000)
    assert {:error, {:missing, nil}, ^cache} = Cache.pin(cache, [nil], make_ref())
    assert {:error, :invalid_keys, ^cache} = Cache.pin(cache, :not_a_list, make_ref())
  end

  test "试淘汰过未 pin 条目后仍容量不足时，整个 put 回滚且旧 LRU 可继续使用" do
    [a, c, d] = Enum.map([1, 3, 4], &payload/1)
    b = {:prefab, <<8::256>>}
    bytes = :binary.copy(<<49>>, 1024)
    owner = make_ref()
    {:ok, probe} = Cache.put(Cache.new(100_000), a, bytes, version())
    {:ok, probe} = Cache.put(probe, b, bytes, <<8::256>>)
    {:ok, probe} = Cache.pin(probe, [a], owner)
    limit = Cache.stats(probe).bytes
    {:ok, cache} = Cache.put(Cache.new(limit), a, bytes, version())
    {:ok, cache} = Cache.put(cache, b, bytes, <<8::256>>)
    {:ok, cache} = Cache.pin(cache, [a], owner)
    original = cache

    assert {:error, :pinned_capacity, ^original} =
             Cache.put(cache, c, :binary.copy(<<50>>, 2048), version())

    assert Cache.stats(cache).namespaces == %{
             payload: %{entries: 1, value_bytes: 1024},
             prefab: %{entries: 1, value_bytes: 1024}
           }

    assert Cache.keys(cache, :payload) == [a]
    assert Cache.keys(cache, :prefab) == [b]
    assert {:ok, _} = Cache.peek(cache, b)
    cache = Cache.release(cache, owner)
    {:ok, cache} = Cache.put(cache, d, bytes, version())
    assert :miss = Cache.peek(cache, a)
    assert {:ok, _} = Cache.peek(cache, b)
    assert Cache.stats(cache).evictions == 1
  end

  test "一个 owner 释放不解除另一个请求的 pin，最后 owner 释放才解除关系" do
    [a, b] = Enum.map(1..2, &payload/1)
    owner = make_ref()
    other = make_ref()
    {:ok, cache} = Cache.put(Cache.new(100_000), a, <<1>>, version())
    {:ok, cache} = Cache.put(cache, b, <<2>>, version())
    {:ok, cache} = Cache.pin(cache, [a], owner)
    {:ok, cache} = Cache.pin(cache, [a], other)
    {:ok, _, cache} = Cache.get(cache, a)
    cache = Cache.release(cache, owner)
    assert %{pins: 1, owners: 1, pinned_entries: 1} = Cache.stats(cache)
    cache = Cache.release(cache, other)
    assert %{pins: 0, owners: 0, pinned_entries: 0, hits: 1} = Cache.stats(cache)
    assert Cache.release(cache, other) == cache
    assert {:ok, _} = Cache.peek(cache, a)
  end

  test "零预算只保留空缓存，超大插入不会先删已有条目" do
    cache = Cache.new(0)
    assert %{bytes: 0, entries: 0, limit_bytes: 0} = Cache.stats(cache)
    assert {:error, :too_large, ^cache} = Cache.put(cache, payload(1), <<1>>, version())
    assert {:ok, ^cache} = Cache.pin(cache, [], make_ref())
    assert_raise ArgumentError, fn -> Cache.new(-1) end
  end

  test "元信息更新保留同一字节版本 pin 与最近使用，不将检查结果继承到新内容" do
    key = payload(1)
    owner = make_ref()
    bytes = :binary.copy(<<47>>, 256)
    {:ok, cache} = Cache.put(Cache.new(100_000), key, bytes, version(), metadata(false))
    {:ok, cache} = Cache.pin(cache, [key], owner)
    before = Cache.stats(cache)
    {:ok, cache} = Cache.update_metadata(cache, key, metadata(true))

    assert {:ok, %{bytes: ^bytes, version: {7, 9, 11}, metadata: %{liquid_checked: true}}} =
             Cache.peek(cache, key)

    assert Cache.stats(cache).pins == before.pins
    assert Cache.stats(cache).pinned_entries == before.pinned_entries
    assert Cache.stats(cache).hits == before.hits
    cache = Cache.release(cache, owner)
    {:ok, cache} = Cache.put(cache, key, bytes, version(), metadata(false))
    assert {:ok, %{metadata: %{liquid_checked: false}}} = Cache.peek(cache, key)
  end

  test "元信息增重超预算保持条目及 pin 原样，未知条目显式 missing" do
    key = payload(1)
    owner = make_ref()
    {:ok, probe} = Cache.put(Cache.new(100_000), key, <<1>>, version(), metadata(true))
    {:ok, probe} = Cache.pin(probe, [key], owner)

    {:ok, cache} =
      Cache.put(Cache.new(Cache.stats(probe).bytes), key, <<1>>, version(), metadata(true))

    {:ok, cache} = Cache.pin(cache, [key], owner)
    original = cache
    assert {:error, :capacity, ^original} = Cache.update_metadata(cache, key, metadata(false))

    assert {:error, :missing, ^original} =
             Cache.update_metadata(cache, payload(2), metadata(true))
  end

  test "保留 sub-binary 的完整父对象收费，不复制输入来制造廉价切片" do
    parent = :binary.copy(<<48>>, 8192)
    slice = binary_part(parent, 100, 1024)
    assert :binary.referenced_byte_size(slice) == 8192
    small = Cache.new(4096)
    assert {:error, :too_large, ^small} = Cache.put(small, payload(1), slice, version())
    {:ok, cache} = Cache.put(Cache.new(100_000), payload(1), slice, version())
    assert Cache.stats(cache).value_bytes == 8192
    assert {:ok, %{bytes: returned}} = Cache.peek(cache, payload(1))
    assert returned == slice
    assert :binary.referenced_byte_size(returned) == 8192
  end

  test "小 typed 元信息权重覆盖最大协议标量夹具的独立 heap 测量" do
    key = {:payload, {5, {-2_147_483_648, 2_147_483_647, -1}}}
    max = 18_446_744_073_709_551_615
    version = {max, max, max}

    header = %{
      version: 13,
      level: 5,
      region: elem(elem(key, 1), 1),
      seq: max,
      content_version: max,
      hash: max,
      encoding: 255,
      raw_bytes: 4_294_967_295,
      body_bytes: 4_294_967_295
    }

    meta = struct(Cache.PayloadMetadata, header: header, liquid_checked: false)
    {:ok, cache} = Cache.put(Cache.new(100_000), key, <<1>>, version, meta)

    independent_heap =
      :erts_debug.flat_size({key, version, meta}) * :erlang.system_info(:wordsize)

    assert Cache.stats(cache).metadata_bytes >= independent_heap

    assert Cache.stats(cache).bytes ==
             Cache.stats(cache).value_bytes + Cache.stats(cache).metadata_bytes

    assert {:ok, %{version: ^version, metadata: ^meta}} = Cache.peek(cache, key)
  end

  test "接纳边界拒绝无界 key version 与伪装 typed metadata 的几何，失败不保留输入" do
    cache = Cache.new(100_000)
    meta = metadata(false)

    invalid = [
      {{:payload, {6, {0, 0, 0}}}, <<1>>, version(), :none, :invalid_key},
      {{:payload, {0, {2_147_483_648, 0, 0}}}, <<1>>, version(), :none, :invalid_key},
      {{:prefab, <<0::264>>}, <<1>>, version(), :none, :invalid_key},
      {payload(1), [1], version(), :none, :invalid_binary},
      {payload(1), <<1>>, [1, 2, 3], :none, :invalid_version},
      {payload(1), <<1>>, {-1, 0, 0}, :none, :invalid_version},
      {payload(1), <<1>>, version(), %{compiled: Enum.to_list(1..100)}, :invalid_metadata},
      {payload(1), <<1>>, version(), Map.put(meta, :compiled, <<0::1024>>), :invalid_metadata},
      {payload(1), <<1>>, version(),
       %{meta | header: Map.put(meta.header, :compiled, <<0::1024>>)}, :invalid_metadata},
      {{:prefab, <<1::256>>}, <<1>>, <<1::256>>, meta, :invalid_metadata}
    ]

    for {key, bytes, version, metadata, reason} <- invalid do
      assert {:error, ^reason, ^cache} = Cache.put(cache, key, bytes, version, metadata)
    end
  end

  defp payload(x), do: {:payload, {0, {x, -2, 3}}}
  defp version, do: {7, 9, 11}

  defp metadata(checked) do
    header = %{
      version: 13,
      level: 0,
      region: {1, -2, 3},
      seq: 9,
      content_version: 7,
      hash: 11,
      encoding: 1,
      raw_bytes: 1,
      body_bytes: 1
    }

    struct(Cache.PayloadMetadata, header: header, liquid_checked: checked)
  end

  # 只用公开计量为夹具设置可容纳的组合；淘汰次序与身份期望由上方手写动作确定。
  defp footprint(items, pinned \\ [], owner \\ nil) do
    cache =
      Enum.reduce(items, Cache.new(100_000), fn {key, bytes}, cache ->
        {:ok, cache} = Cache.put(cache, key, bytes, version())
        cache
      end)

    cache = if pinned == [], do: cache, else: elem(Cache.pin(cache, pinned, owner), 1)
    Cache.stats(cache).bytes
  end
end
