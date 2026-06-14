defmodule GateServer.Replication.Egress do
  @moduledoc """
  统一 Replicator · per-observer 出口控制器(梯队3 step3.10a,REPL-2/4/6、NET-3/4/5、LOAD-5)。

  规范要求**所有客户端可见状态必须经 per-observer Replicator**(REPL-2),且禁止发布高于
  `visibility_watermark` 的权威结果(AUTH-8;本系统由 durable-before-ack 满足,见 step3.9)。
  gate 连接是某客户端**全部下行的唯一汇聚点**且不随权威迁移(CELL-8),故 Replicator 落在连接侧、
  做成**逻辑层纯函数核**(MOD-1 [v2.0.2] 放宽:逻辑层即可,不强制独立进程/app);本模块无进程状态,
  状态嵌入连接 state。

  ## 职责
  - **可靠性四分类(REPL-4 / NET-1)**:`reliable_ordered`(控制,禁丢禁合并、最先发、不受预算)/
    `reliable_unordered`(delta 链,保序不合并、受预算)/ `unreliable_snapshot`(自包含快照,同 key 合并到
    最新、受预算)/ `bulk_stream`(大块,独立队列、剩余预算最后发、合并到最新)。
  - **per-observer 出口预算(REPL-2 / LOAD-5)**:token bucket,按单调时间**惰性补充**(无定时器);
    `enqueue/2` + `flush/2` 即 LOAD-5 day-1 出口预算接口。
  - **聚合(REPL-6)**:snapshot / bulk 类按 `{forward_tag, cell_id}` 合并到最新(整快照淘汰旧帧)。
  - **背压 + 大流隔离(NET-3/4/5)**:bulk 独立队列、reliable 排空后用剩余预算发;reliable_unordered 队列
    超 `max_queue_depth` 时**丢最旧并登记 resync**(显式,非静默——delta 链断口客户端需重取快照)。

  ## 0 回归关键不变量(D3.10-6)
  子预算(正常负载)下 `flush/2` 把所有排队帧即时发完、顺序与"逐条 `send`"完全一致(token 充足→无憋帧
  →无合并);Replicator **仅在出口压力下**改变行为(REPL-2 本旨)。

  `enqueue/2` 接受梯队0 `MmoContracts.Envelope.ReplicationOut` 信封;`payload` 字段约定为
  `{forward_tag, binary}`,`forward_tag` 是连接侧下行 kind(决定 `send_encoded` 还是裸 `send`),
  对本模块不透明。
  """

  alias MmoContracts.Envelope.ReplicationOut

  @default_capacity_bytes 131_072
  @default_window_ms 100
  @default_max_queue_depth 256

  @type forward_tag :: atom()
  @type cell_id :: term()
  @type coalesce_key :: {forward_tag(), cell_id()}

  @type t :: %__MODULE__{
          observer_id: term(),
          capacity_bytes: pos_integer(),
          tokens: float(),
          refill_per_ms: float(),
          last_refill_ms: integer() | nil,
          max_queue_depth: pos_integer(),
          control: [ReplicationOut.t()],
          reliable: [ReplicationOut.t()],
          snapshot: {[coalesce_key()], %{coalesce_key() => ReplicationOut.t()}},
          bulk: {[coalesce_key()], %{coalesce_key() => ReplicationOut.t()}},
          stats: map()
        }

  defstruct observer_id: nil,
            capacity_bytes: @default_capacity_bytes,
            tokens: @default_capacity_bytes * 1.0,
            refill_per_ms: @default_capacity_bytes / @default_window_ms,
            last_refill_ms: nil,
            max_queue_depth: @default_max_queue_depth,
            control: [],
            reliable: [],
            snapshot: {[], %{}},
            bulk: {[], %{}},
            stats: %{
              sent: 0,
              bytes_sent: 0,
              coalesced: 0,
              dropped_reliable: 0,
              deferred_bulk: 0,
              resync_cells: MapSet.new()
            }

  @doc """
  新建 per-observer 出口控制器。

  opts:`:observer_id`、`:capacity_bytes`(预算桶容量,默认 #{@default_capacity_bytes})、
  `:window_ms`(满桶补充窗,默认 #{@default_window_ms}ms)、`:max_queue_depth`(reliable 队列上限)、
  `:now_ms`(初始单调时间锚,缺省 nil = 首次 flush 锚定)。
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    capacity = Keyword.get(opts, :capacity_bytes, @default_capacity_bytes)
    window_ms = max(Keyword.get(opts, :window_ms, @default_window_ms), 1)

    %__MODULE__{
      observer_id: Keyword.get(opts, :observer_id),
      capacity_bytes: capacity,
      tokens: capacity * 1.0,
      refill_per_ms: capacity / window_ms,
      last_refill_ms: Keyword.get(opts, :now_ms),
      max_queue_depth: max(Keyword.get(opts, :max_queue_depth, @default_max_queue_depth), 1)
    }
  end

  @doc """
  按 `forward_tag` + `cell_id` 分类并入队一个预编码下行二进制(策略集中在本模块)。

  `opts`:`:priority_score`、`:snapshot_seq`、`:delta_base`、`:visibility_watermark`。
  """
  @spec enqueue_payload(t(), forward_tag(), cell_id(), binary(), keyword()) :: t()
  def enqueue_payload(%__MODULE__{} = egress, forward_tag, cell_id, binary, opts \\ [])
      when is_atom(forward_tag) and is_binary(binary) do
    reliability_class = reliability_class(forward_tag)

    env =
      ReplicationOut.new!(
        observer_id: egress.observer_id,
        cell_id: cell_id,
        snapshot_seq: Keyword.get(opts, :snapshot_seq, 0),
        delta_base: Keyword.get(opts, :delta_base),
        budget_class: budget_class(reliability_class),
        priority_score: Keyword.get(opts, :priority_score),
        reliability_class: reliability_class,
        visibility_watermark: Keyword.get(opts, :visibility_watermark),
        payload: {forward_tag, binary}
      )

    enqueue(egress, env)
  end

  @doc """
  入队一个已构造的 `ReplicationOut` 信封,按其 `reliability_class` 路由 + 聚合 / 溢出处理。
  """
  @spec enqueue(t(), ReplicationOut.t()) :: t()
  def enqueue(%__MODULE__{} = egress, %ReplicationOut{reliability_class: rc} = env) do
    case rc do
      :reliable_ordered -> %{egress | control: [env | egress.control]}
      :reliable_unordered -> enqueue_reliable(egress, env)
      :unreliable_snapshot -> %{egress | snapshot: coalesce_put(egress.snapshot, env)}
      :bulk_stream -> %{egress | bulk: coalesce_put(egress.bulk, env)}
    end
  end

  @doc """
  排空队列到出口预算上限,返回 `{outbound, egress}`。

  `outbound` 是按发送顺序的 `[{forward_tag, binary}]`(连接侧据 forward_tag 决定 send 方式)。
  优先级:控制(不受预算)→ reliable_unordered → unreliable_snapshot → bulk_stream(各受剩余预算闸门)。
  `now_ms` 为单调时间(ms),用于 token bucket 惰性补充。
  """
  @spec flush(t(), integer()) :: {[{forward_tag(), binary()}], t()}
  def flush(%__MODULE__{} = egress, now_ms) when is_integer(now_ms) do
    egress = refill(egress, now_ms)

    # 1) 控制类:保序、必达、不受预算(REPL-4 reliable_ordered)。
    control_out = Enum.reverse(egress.control)
    egress = %{egress | control: []}

    # 2) reliable_unordered(delta 链):FIFO、保序、受预算。
    {reliable_out, reliable_rest, egress} =
      drain_ordered(Enum.reverse(egress.reliable), egress)

    egress = %{egress | reliable: Enum.reverse(reliable_rest)}

    # 3) unreliable_snapshot:合并后按插入序、受剩余预算。
    {snapshot_out, snapshot_rest, egress} = drain_coalesced(egress.snapshot, egress)
    egress = %{egress | snapshot: snapshot_rest}

    # 4) bulk_stream:独立队列、最后用剩余预算发(NET-3/4 大流隔离)。
    {bulk_out, bulk_rest, egress} = drain_coalesced(egress.bulk, egress)
    deferred = elem(bulk_rest, 0) |> length()
    egress = %{egress | bulk: bulk_rest}

    egress =
      if deferred > 0 do
        update_in(egress.stats.deferred_bulk, &(&1 + deferred))
      else
        egress
      end

    all_sent = control_out ++ reliable_out ++ snapshot_out ++ bulk_out
    egress = account(egress, all_sent)
    outbound = Enum.map(all_sent, & &1.payload)

    {outbound, egress}
  end

  @doc "队列中待发帧总数(控制 + reliable + snapshot + bulk)。"
  @spec pending_count(t()) :: non_neg_integer()
  def pending_count(%__MODULE__{} = egress) do
    length(egress.control) + length(egress.reliable) +
      length(elem(egress.snapshot, 0)) + length(elem(egress.bulk, 0))
  end

  @doc "是否有待发帧。"
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{} = egress), do: pending_count(egress) > 0

  @doc "当前可用预算字节(惰性补充前的快照值)。"
  @spec available_tokens(t()) :: float()
  def available_tokens(%__MODULE__{tokens: tokens}), do: tokens

  @doc "本控制器累计统计(sent / bytes_sent / coalesced / dropped_reliable / deferred_bulk / resync_cells)。"
  @spec stats(t()) :: map()
  def stats(%__MODULE__{stats: stats}), do: stats

  @doc "需要重取快照的 cell 集合(delta 链因溢出被截断,客户端需 resync)。"
  @spec resync_cells(t()) :: MapSet.t()
  def resync_cells(%__MODULE__{stats: %{resync_cells: cells}}), do: cells

  @doc "清空已登记的 resync cell 集合(连接侧消费后调用)。"
  @spec clear_resync_cells(t()) :: t()
  def clear_resync_cells(%__MODULE__{} = egress),
    do: put_in(egress.stats.resync_cells, MapSet.new())

  # --- reliability 分类策略(REPL-4) ---

  @doc "下行 kind → 可靠性类别(REPL-4 / NET-1)。"
  @spec reliability_class(forward_tag()) :: ReplicationOut.reliability_class()
  def reliability_class(:voxel_chunk_delta_payload), do: :reliable_unordered
  def reliability_class(:voxel_object_state_delta_payload), do: :reliable_unordered
  def reliability_class(:voxel_field_region_snapshot_payload), do: :unreliable_snapshot
  def reliability_class(:voxel_chunk_snapshot_payload), do: :bulk_stream
  def reliability_class(:voxel_field_region_destroyed_payload), do: :reliable_ordered
  def reliability_class(:voxel_chunk_invalidate_payload), do: :reliable_ordered
  def reliability_class(_other), do: :reliable_ordered

  defp budget_class(:reliable_ordered), do: :control
  defp budget_class(:reliable_unordered), do: :state
  defp budget_class(:unreliable_snapshot), do: :snapshot
  defp budget_class(:bulk_stream), do: :bulk

  # --- 队列操作 ---

  defp enqueue_reliable(%__MODULE__{} = egress, env) do
    reliable = [env | egress.reliable]

    if length(reliable) > egress.max_queue_depth do
      # 溢出:丢最旧(列表尾,= 最早入队),登记 resync(delta 链断口,显式非静默)。
      {dropped, kept_rev} = drop_oldest(reliable)

      egress
      |> Map.put(:reliable, kept_rev)
      |> update_in([Access.key(:stats), :dropped_reliable], &(&1 + 1))
      |> update_in(
        [Access.key(:stats), :resync_cells],
        &MapSet.put(&1, dropped.cell_id)
      )
    else
      %{egress | reliable: reliable}
    end
  end

  defp drop_oldest([single]), do: {single, []}

  defp drop_oldest([newest | rest]) do
    [oldest | mid_rev] = Enum.reverse(rest)
    {oldest, [newest | Enum.reverse(mid_rev)]}
  end

  defp coalesce_put({order, by_key}, %ReplicationOut{} = env) do
    {forward_tag, _binary} = env.payload
    key = {forward_tag, env.cell_id}

    if Map.has_key?(by_key, key) do
      {order, Map.put(by_key, key, env)}
    else
      {order ++ [key], Map.put(by_key, key, env)}
    end
  end

  # --- 排空 ---

  defp drain_ordered(envs, egress), do: drain_ordered(envs, egress, [])

  defp drain_ordered([], egress, acc), do: {Enum.reverse(acc), [], egress}

  defp drain_ordered([env | rest], egress, acc) do
    bytes = payload_bytes(env)

    if affordable?(egress, bytes) do
      egress = spend(egress, bytes)
      drain_ordered(rest, egress, [env | acc])
    else
      {Enum.reverse(acc), [env | rest], egress}
    end
  end

  defp drain_coalesced({order, by_key}, egress),
    do: drain_coalesced(order, by_key, egress, [])

  defp drain_coalesced([], by_key, egress, acc) do
    {Enum.reverse(acc), {[], by_key}, egress}
  end

  defp drain_coalesced([key | rest], by_key, egress, acc) do
    env = Map.fetch!(by_key, key)
    bytes = payload_bytes(env)

    if affordable?(egress, bytes) do
      egress = spend(egress, bytes)
      drain_coalesced(rest, Map.delete(by_key, key), egress, [env | acc])
    else
      {Enum.reverse(acc), {[key | rest], by_key}, egress}
    end
  end

  # --- token bucket ---

  defp refill(%__MODULE__{last_refill_ms: nil} = egress, now_ms) do
    %{egress | last_refill_ms: now_ms}
  end

  defp refill(%__MODULE__{} = egress, now_ms) do
    elapsed = max(now_ms - egress.last_refill_ms, 0)
    refilled = min(egress.capacity_bytes * 1.0, egress.tokens + elapsed * egress.refill_per_ms)
    %{egress | tokens: refilled, last_refill_ms: now_ms}
  end

  # 单帧若超过整桶容量,容量满时仍放行一次(避免大快照永久卡死;计入预算到负也接受)。
  defp affordable?(%__MODULE__{tokens: tokens, capacity_bytes: cap}, bytes) do
    tokens >= bytes or (tokens >= cap * 1.0 and bytes > cap)
  end

  defp spend(%__MODULE__{} = egress, bytes), do: %{egress | tokens: egress.tokens - bytes}

  defp account(%__MODULE__{} = egress, envs) do
    {count, bytes} =
      Enum.reduce(envs, {0, 0}, fn env, {c, b} -> {c + 1, b + payload_bytes(env)} end)

    egress
    |> update_in([Access.key(:stats), :sent], &(&1 + count))
    |> update_in([Access.key(:stats), :bytes_sent], &(&1 + bytes))
  end

  defp payload_bytes(%ReplicationOut{payload: {_tag, binary}}), do: byte_size(binary)
end
