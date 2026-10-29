defmodule VoxelRegion.World.Cache do
  @moduledoc """
  全局系统功能：payload 与原始 prefab 字节共用的纯有界 LRU。

  本模块只拥有可丢缓存。canonical truth、活动驻留与已捕获输入的在途生命周期归各自 owner。
  显式删除或替换退休旧条目及其 pin；pin 只阻止容量淘汰，不阻止权威内容失效。

  字节保留原引用，按 `:binary.referenced_byte_size/1` 计完整父对象。有限 typed
  key/version/metadata 与 pin 关系在构造时用 `:erlang.external_size/1 * wordsize`
  冻结保守声明权重，其中身份 binary 的父对象另计；共享对象允许重复计费。
  该权重不是整个 VM 或 RSS 上界，缓存索引与 allocator 余量须由根级测量覆盖。
  不复制、编码或扫描 canonical 数据来统计预算，不接受 compiled geometry 或 opaque metadata。
  """

  defmodule PayloadMetadata do
    @moduledoc "载荷 owner 的有限元信息：Codec 九字段纯标量头与当前条目的液体检查结论。"
    @enforce_keys [:header]
    defstruct [:header, liquid_checked: false]

    @type t :: %__MODULE__{header: map(), liquid_checked: boolean()}
  end

  defmodule Entry do
    @moduledoc "缓存返回的不可变字节、已接纳内容身份与有限 owner 元信息；权重不能由调用方填写。"
    @enforce_keys [:bytes, :version, :metadata]
    defstruct [:bytes, :version, :metadata]

    @type t :: %__MODULE__{
            bytes: binary(),
            version: VoxelRegion.World.Cache.version(),
            metadata: :none | PayloadMetadata.t()
          }
  end

  defmodule Stored do
    @moduledoc false
    @enforce_keys [:entry, :value_bytes, :metadata_bytes, :tick]
    defstruct [:entry, :value_bytes, :metadata_bytes, :tick, owners: %{}]
  end

  @type key :: {:payload, {0..5, {integer(), integer(), integer()}}} | {:prefab, <<_::256>>}
  @type version :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | <<_::256>>
  @type metadata :: :none | PayloadMetadata.t()
  @opaque t :: %__MODULE__{}

  defstruct limit_bytes: 0,
            entries: %{},
            owners: %{},
            lru: {0, nil},
            tick: 0,
            bytes: 0,
            value_bytes: 0,
            metadata_bytes: 0,
            pins: 0,
            pinned_entries: 0,
            namespaces: %{payload: %{entries: 0, value_bytes: 0}, prefab: %{entries: 0, value_bytes: 0}},
            hits: 0,
            misses: 0,
            evictions: 0

  @doc "建立显式非负字节预算的空缓存；零预算合法，不为条目提供免费元信息。"
  @spec new(non_neg_integer()) :: t()
  def new(limit_bytes) when is_integer(limit_bytes) and limit_bytes >= 0,
    do: %__MODULE__{limit_bytes: limit_bytes}

  def new(_limit_bytes),
    do: raise(ArgumentError, "cache limit_bytes must be a non-negative integer")

  @doc "命中返回 Entry 并更新最近使用与 hit；缺失返回 miss 并计数。"
  @spec get(t(), key()) :: {:ok, Entry.t(), t()} | {:miss, t()}
  def get(cache, key) do
    case Map.fetch(cache.entries, key) do
      {:ok, stored} ->
        next = touch(cache, key, stored)
        {:ok, stored.entry, %{next | hits: next.hits + 1}}

      :error ->
        {:miss, %{cache | misses: cache.misses + 1}}
    end
  end

  @doc "只读既有 Entry；不改变最近使用、pin 或统计，供冻结与准备入口检查。"
  @spec peek(t(), key()) :: {:ok, Entry.t()} | :miss
  def peek(cache, key) do
    case Map.fetch(cache.entries, key) do
      {:ok, stored} -> {:ok, stored.entry}
      :error -> :miss
    end
  end

  @doc "只读一个有限命名空间的逻辑键，供定向失效／冻结，不取得binary正文或改变LRU。"
  @spec keys(t(), :payload | :prefab) :: [key()]
  def keys(cache, namespace) when namespace in [:payload, :prefab],
    do: for({{^namespace, _} = key, _stored} <- cache.entries, do: key)

  @doc """
  接纳不可变字节及有限元信息，以 LRU 腾出空间后替换条目并退休旧 pin。

  过大返回 `:too_large`，可淘汰空间不足返回 `:pinned_capacity`；任何失败均返回原缓存，
  不提前丢旧条目、不改变 LRU、pin 或统计。输入的版本与字节内容不改写。
  """
  @spec put(t(), key(), binary(), version(), metadata()) :: {:ok, t()} | {:error, atom(), t()}
  def put(cache, key, bytes, version, metadata \\ :none) do
    with :ok <- validate_key(key),
         :ok <- validate_binary(bytes),
         :ok <- validate_version(version),
         :ok <- validate_metadata(key, metadata) do
      {value_bytes, metadata_bytes} = weight(key, bytes, version, metadata)
      required = value_bytes + metadata_bytes

      if required > cache.limit_bytes do
        {:error, :too_large, cache}
      else
        case make_room(delete(cache, key), required) do
          {:ok, next} ->
            tick = next.tick + 1
            entry = %Entry{bytes: bytes, version: version, metadata: metadata}

            stored = %Stored{
              entry: entry,
              value_bytes: value_bytes,
              metadata_bytes: metadata_bytes,
              tick: tick
            }

            {:ok,
             %{
               next
               | entries: Map.put(next.entries, key, stored),
                 lru: :gb_trees.insert({tick, key}, true, next.lru),
                 tick: tick,
                 bytes: next.bytes + required,
                 value_bytes: next.value_bytes + value_bytes,
                 namespaces: namespace_count(next, key, 1, value_bytes),
                 metadata_bytes: next.metadata_bytes + metadata_bytes
             }}

          :full ->
            {:error, :pinned_capacity, cache}
        end
      end
    else
      {:error, reason} -> {:error, reason, cache}
    end
  end

  @doc "显式失效条目及其全部 pin；不存在时幂等，不将删除计为容量淘汰。"
  @spec delete(t(), key()) :: t()
  def delete(cache, key) do
    case Map.pop(cache.entries, key) do
      {nil, _} ->
        cache

      {stored, entries} ->
        pinned = map_size(stored.owners) > 0
        lru = if pinned, do: cache.lru, else: :gb_trees.delete({stored.tick, key}, cache.lru)

        next = %{
          cache
          | entries: entries,
            lru: lru,
            bytes: cache.bytes - stored.value_bytes - stored.metadata_bytes,
            value_bytes: cache.value_bytes - stored.value_bytes,
            namespaces: namespace_count(cache, key, -1, -stored.value_bytes),
            metadata_bytes: cache.metadata_bytes - stored.metadata_bytes,
            pinned_entries: cache.pinned_entries - if(pinned, do: 1, else: 0)
        }

        Enum.reduce(stored.owners, next, fn {owner, cost}, next ->
          drop_owner_key(next, owner, key, cost)
        end)
    end
  end

  @doc """
  同一请求 reference token 原子 pin 全部既有 key；同 token/key 幂等，缺一不部分接纳。

  每个新关系也占元信息预算，空间不足返回 `:pinned_capacity`，不驱逐其他条目。
  本模块不监控 PID；请求完成、取消或失败时由请求 owner 调用 `release/2`。
  """
  @spec pin(t(), [key()], reference()) :: {:ok, t()} | {:error, term(), t()}
  def pin(cache, keys, owner) when is_list(keys) and is_reference(owner) do
    keys = Enum.uniq(keys)

    case Enum.find_value(keys, fn key ->
           if not Map.has_key?(cache.entries, key), do: {:missing, key}
         end) do
      nil ->
        additions =
          for key <- keys,
              not Map.has_key?(Map.fetch!(cache.entries, key).owners, owner),
              do: {key, term_weight({owner, key}) + identity_parent_bytes(key)}

        cost = Enum.reduce(additions, 0, fn {_, bytes}, sum -> sum + bytes end)

        if cache.bytes + cost <= cache.limit_bytes do
          {:ok,
           Enum.reduce(additions, cache, fn {key, bytes}, next ->
             add_pin(next, key, owner, bytes)
           end)}
        else
          {:error, :pinned_capacity, cache}
        end

      {:missing, missing} ->
        {:error, {:missing, missing}, cache}
    end
  end

  def pin(cache, _keys, owner) when not is_reference(owner), do: {:error, :invalid_owner, cache}
  def pin(cache, _keys, _owner), do: {:error, :invalid_keys, cache}

  @doc "释放此请求 token 的全部 pin 及其权重；重复释放幂等，恢复原最近使用次序。"
  @spec release(t(), reference()) :: t()
  def release(cache, owner) do
    case Map.fetch(cache.owners, owner) do
      :error ->
        cache

      {:ok, keys} ->
        Enum.reduce(keys, cache, fn key, next ->
          stored = Map.fetch!(next.entries, key)
          {cost, owners} = Map.pop!(stored.owners, owner)

          lru =
            if map_size(owners) == 0,
              do: :gb_trees.insert({stored.tick, key}, true, next.lru),
              else: next.lru

          next = %{
            next
            | entries: Map.put(next.entries, key, %{stored | owners: owners}),
              lru: lru,
              pinned_entries: next.pinned_entries - if(map_size(owners) == 0, do: 1, else: 0)
          }

          drop_owner_key(next, owner, key, cost)
        end)
    end
  end

  @doc "同条目只更新 typed 元信息，不改变 bytes/version/pin/LRU；增重超预算原子返回 capacity。"
  @spec update_metadata(t(), key(), metadata()) :: {:ok, t()} | {:error, atom(), t()}
  def update_metadata(cache, key, metadata) do
    with {:ok, stored} <- Map.fetch(cache.entries, key),
         :ok <- validate_metadata(key, metadata) do
      {_, metadata_bytes} = weight(key, stored.entry.bytes, stored.entry.version, metadata)
      delta = metadata_bytes - stored.metadata_bytes

      if cache.bytes + delta <= cache.limit_bytes do
        entry = %{stored.entry | metadata: metadata}
        next = %{stored | entry: entry, metadata_bytes: metadata_bytes}

        {:ok,
         %{
           cache
           | entries: Map.put(cache.entries, key, next),
             bytes: cache.bytes + delta,
             metadata_bytes: cache.metadata_bytes + delta
         }}
      else
        {:error, :capacity, cache}
      end
    else
      :error -> {:error, :missing, cache}
      {:error, reason} -> {:error, reason, cache}
    end
  end

  @doc "返回构造/释放时维护的 O(1) 计数，不扫描条目或重新编码数据；bytes 包含 pin 元信息。"
  @spec stats(t()) :: map()
  def stats(cache) do
    %{
      limit_bytes: cache.limit_bytes,
      bytes: cache.bytes,
      value_bytes: cache.value_bytes,
      namespaces: cache.namespaces,
      metadata_bytes: cache.metadata_bytes,
      entries: map_size(cache.entries),
      pins: cache.pins,
      pinned_entries: cache.pinned_entries,
      owners: map_size(cache.owners),
      hits: cache.hits,
      misses: cache.misses,
      evictions: cache.evictions
    }
  end

  defp namespace_count(cache, {namespace, _}, count, bytes),
    do: Map.update!(cache.namespaces, namespace, fn row -> %{entries: row.entries + count, value_bytes: row.value_bytes + bytes} end)

  defp touch(cache, key, stored) do
    tick = cache.tick + 1

    lru =
      if map_size(stored.owners) == 0 do
        :gb_trees.insert({tick, key}, true, :gb_trees.delete({stored.tick, key}, cache.lru))
      else
        cache.lru
      end

    %{cache | entries: Map.put(cache.entries, key, %{stored | tick: tick}), lru: lru, tick: tick}
  end

  defp make_room(cache, required) do
    cond do
      cache.bytes + required <= cache.limit_bytes ->
        {:ok, cache}

      :gb_trees.is_empty(cache.lru) ->
        :full

      true ->
        {{_, key}, _} = :gb_trees.smallest(cache.lru)
        next = delete(cache, key)
        make_room(%{next | evictions: next.evictions + 1}, required)
    end
  end

  defp add_pin(cache, key, owner, cost) do
    stored = Map.fetch!(cache.entries, key)
    first = map_size(stored.owners) == 0
    lru = if first, do: :gb_trees.delete({stored.tick, key}, cache.lru), else: cache.lru
    owned = MapSet.put(Map.get(cache.owners, owner, MapSet.new()), key)

    %{
      cache
      | entries:
          Map.put(cache.entries, key, %{stored | owners: Map.put(stored.owners, owner, cost)}),
        owners: Map.put(cache.owners, owner, owned),
        lru: lru,
        bytes: cache.bytes + cost,
        metadata_bytes: cache.metadata_bytes + cost,
        pins: cache.pins + 1,
        pinned_entries: cache.pinned_entries + if(first, do: 1, else: 0)
    }
  end

  defp drop_owner_key(cache, owner, key, cost) do
    keys = MapSet.delete(Map.fetch!(cache.owners, owner), key)

    owners =
      if MapSet.size(keys) == 0,
        do: Map.delete(cache.owners, owner),
        else: Map.put(cache.owners, owner, keys)

    %{
      cache
      | owners: owners,
        bytes: cache.bytes - cost,
        metadata_bytes: cache.metadata_bytes - cost,
        pins: cache.pins - 1
    }
  end

  defp weight(key, bytes, version, metadata) do
    {:binary.referenced_byte_size(bytes),
     term_weight({key, version, metadata}) + identity_parent_bytes(key) +
       identity_parent_bytes(version)}
  end

  # 只对接纳边界限定的有限小 term 计量；不产生 ETF 副本，也不接受任意嵌套容器。
  defp term_weight(term), do: :erlang.external_size(term) * :erlang.system_info(:wordsize)
  defp identity_parent_bytes({:prefab, id}), do: :binary.referenced_byte_size(id)
  defp identity_parent_bytes(id) when is_binary(id), do: :binary.referenced_byte_size(id)
  defp identity_parent_bytes(_), do: 0

  defp validate_key({:payload, {level, region}}) when level in 0..5 do
    if coordinate?(region), do: :ok, else: {:error, :invalid_key}
  end

  defp validate_key({:prefab, <<_::256>>}), do: :ok
  defp validate_key(_), do: {:error, :invalid_key}

  defp validate_binary(bytes) when is_binary(bytes), do: :ok
  defp validate_binary(_), do: {:error, :invalid_binary}

  defp validate_version({cv, seq, hash}) do
    if uint?(cv, 64) and uint?(seq, 64) and uint?(hash, 64),
      do: :ok,
      else: {:error, :invalid_version}
  end

  defp validate_version(<<_::256>>), do: :ok
  defp validate_version(_), do: {:error, :invalid_version}

  defp validate_metadata(_key, :none), do: :ok

  defp validate_metadata(
         {:payload, _},
         %PayloadMetadata{header: header, liquid_checked: checked} = metadata
       )
       when map_size(metadata) == 3 and is_boolean(checked) do
    if header?(header), do: :ok, else: {:error, :invalid_metadata}
  end

  defp validate_metadata(_key, _metadata), do: {:error, :invalid_metadata}

  defp header?(
         %{
           version: version,
           level: level,
           region: region,
           seq: seq,
           content_version: cv,
           hash: hash,
           encoding: encoding,
           raw_bytes: raw_bytes,
           body_bytes: body_bytes
         } = header
       )
       when map_size(header) == 9 do
    uint?(version, 32) and uint?(level, 8) and coordinate?(region) and
      uint?(seq, 64) and uint?(cv, 64) and uint?(hash, 64) and uint?(encoding, 8) and
      uint?(raw_bytes, 32) and uint?(body_bytes, 32)
  end

  defp header?(_), do: false

  defp coordinate?({x, y, z}), do: int32?(x) and int32?(y) and int32?(z)
  defp coordinate?(_), do: false
  defp int32?(n), do: is_integer(n) and n >= -2_147_483_648 and n <= 2_147_483_647
  defp uint?(n, bits), do: is_integer(n) and n >= 0 and n < :erlang.bsl(1, bits)
end
