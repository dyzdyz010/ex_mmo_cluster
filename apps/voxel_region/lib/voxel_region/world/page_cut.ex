defmodule VoxelRegion.World.PageCut do
  @moduledoc """
  全局系统功能（M2a 切点，`m2a-page-store.md` §5–§6）：取代整世界检查点。由 World 进程调用，读写 World 状态。

  - **开切点**：在合法提交边界（`thermal_run == nil`）且有新提交（`seq` 高于已发布前缀）时，冻结持久字段的引用（`Pages.frozen/1`，
    同进程零拷贝）、取出攒下的脏单元，交写回进程开始一次尝试。
  - **抽取**：每个回合最多抽一批、只从冻结引用抽取；写回进程每写完一批还一个信用，World 最多领先 `@window` 批（不往 mailbox 堆）。
  - **发布**：全部批确认后发全局行与发布请求；“已发布”后才回复 `compact` 的等待者、退休保留历史并通知 Replica。
  - **写回进程死亡**：与 World 链接，World 一起重启，从持久前缀恢复（启动清掉未发布残留；已发布的切点按前缀可见）。
  - **积压接纳**（§5.3）：积压量 = 日志后缀事务数（`seq − 已发布前缀`）与攒下的脏单元数，二者都只随提交增长、只因发布回落，
    所以只在提交与发布时重算级别。软上限：立即排切点、停发布后的按区压实；中上限：不开始新的热 / 液体 / 投射物步进
    （进行中的走到提交边界）；硬上限：World 在会产生新提交的入口处拒绝（`{:error, :persist_backlog}`）。
    回落到中上限以下时由本模块恢复被延后的调度，不等新输入；各物理owner的due与剩余步始终保留。
  - **Replica 退休**（§6.3）：只通知单调推进、确认已满 `replica_retain_s` 的最新前缀，无新切点时由定时器收尾。
  """
  require Logger

  alias VoxelRegion.LogProjection
  alias VoxelRegion.World.{Liquids, Log, Pages, PageWriter, Projectiles, Thermal}

  # 发布后压实 core 稀疏格达到这个数的区域（`Log.rebase_overlay/2`）。
  @rebase_cells 4096

  @interval_ms 30_000
  @retry_ms 200
  @batch 64
  @window 4

  # 积压三级上限 {软, 中, 硬}，按 M0 负载保守取值（m2a §5.3）：4 份如园 8 窗口约 8 笔/s、常规切点 30 s 一次，
  # 后缀常态几百笔、脏单元几十；迁移切点期间尚无前缀，不计积压。
  @limits %{suffix_txns: {2_000, 10_000, 50_000}, dirty_units: {20_000, 100_000, 400_000}}
  @levels [:ok, :soft, :mid, :hard]
  @replica_retain_s 60

  @doc """
  离线维护（`CoarseRebuild`）的同步切点：没有写回进程与订阅者，在调用进程里写出全部脏单元并发布当前 seq。
  发布前失败即无前缀推进，维护整体重跑（m2a §4.3）。返回发布的单元数。
  """
  def publish_now(%{log: {backend, handle}} = state) do
    prefix = backend.prefix(handle)
    true = prefix == nil or state.seq > prefix
    :ok = backend.clear_unpublished(handle, prefix)
    rows = for unit <- Pages.with_activity(MapSet.to_list(state.page_dirty)), row = Pages.row(unit, Pages.extract(state, unit)), row != nil, do: row
    :ok = backend.publish(handle, state.seq, rows, Pages.globals(state))
    length(rows)
  end

  @doc """
  World 构造时的空状态；`published` 由恢复路径给出。上限与 Replica 保留秒数可由 World 启动选项
  `persist_backlog`（同 `@limits` 形状，可只给部分键）与 `replica_retain_s` 覆盖，缺省读应用环境。
  """
  def new(published, opts \\ []) do
    limits = Map.merge(@limits, Keyword.get(opts, :persist_backlog, Application.get_env(:voxel_region, :persist_backlog, %{})))
    retain_s = Keyword.get(opts, :replica_retain_s, Application.get_env(:voxel_region, :replica_retain_s, @replica_retain_s))

    %{writer: nil, published: published, cut: nil, waiters: [], timer: nil, wanted: false,
      limits: limits, level: :ok, paused: false, dirty_since: nil,
      replica_retain_ms: round(retain_s * 1000), replica_pending: [], replica_sent: nil, replica_timer: nil}
  end

  @doc "启动写回进程（与 World 链接）。"
  def start_writer(state) do
    {:ok, pid} = PageWriter.start_link(self(), state.log)
    put_in(state.page_store.writer, pid)
  end

  @doc "World 正常停止时同步停掉写回进程（被关停时由链接带走）。"
  def stop_writer(%{page_store: %{writer: pid}}) when is_pid(pid), do: GenServer.stop(pid)
  def stop_writer(_state), do: :ok

  @doc "有新提交时排一次切点（已排、进行中都不重复排；超软上限时短延迟）并重算积压级别。"
  def schedule(state) do
    state = put_in(state.page_store.dirty_since, state.page_store.dirty_since || System.monotonic_time(:millisecond))
    state = assess(state)

    case state.page_store do
      %{timer: nil, cut: nil, level: level} ->
        put_in(state.page_store.timer, :erlang.start_timer(if(level == :ok, do: @interval_ms, else: @retry_ms), self(), :page_cut))

      _ ->
        state
    end
  end

  @doc """
  按当前积压量定级（只在提交与发布时调用，见模块说明）。升到软上限时把已排的长间隔切点提前；
  回落到中上限以下时恢复被暂停的热 / 液体 / 投射物调度。
  """
  def assess(%{page_store: store} = state) do
    level = level(state)

    if level != store.level do
      Logger.info("voxel_persist_backlog level=#{level} from=#{store.level} " <>
        Enum.map_join(backlog(state), " ", fn {k, v} -> "#{k}=#{v}" end))
    end

    state = put_in(state.page_store.level, level)

    state =
      if store.level == :ok and level != :ok and store.timer != nil and store.cut == nil do
        :erlang.cancel_timer(store.timer)
        put_in(state.page_store.timer, :erlang.start_timer(@retry_ms, self(), :page_cut))
      else
        state
      end

    if store.paused and not at_least?(level, :mid) do
      Logger.info("voxel_persist_backlog_resume seq=#{state.seq} published=#{store.published}")
      put_in(state.page_store.paused, false) |> Thermal.wake() |> Liquids.schedule_liquid() |> Projectiles.wake()
    else
      state
    end
  end

  defp level(%{page_store: %{published: nil}}), do: :ok

  defp level(%{page_store: store} = state) do
    measured = %{suffix_txns: state.seq - store.published, dirty_units: MapSet.size(state.page_dirty)}

    Enum.reduce(store.limits, :ok, fn {key, {soft, mid, hard}}, acc ->
      value = Map.fetch!(measured, key)
      level = cond do
        value >= hard -> :hard
        value >= mid -> :mid
        value >= soft -> :soft
        true -> :ok
      end
      if at_least?(level, acc), do: level, else: acc
    end)
  end

  @doc "积压级别不低于 `floor`（`:soft` / `:mid` / `:hard`）。"
  def at_least?(%{page_store: %{level: level}}, floor), do: at_least?(level, floor)
  def at_least?(level, floor), do: Enum.find_index(@levels, &(&1 == level)) >= Enum.find_index(@levels, &(&1 == floor))

  @doc "写回使自然步暂不能开始；只记录等待事实，不清物理进度，回落时由assess恢复原欠账。"
  def pause(state) do
    if not state.page_store.paused do
      Logger.warning("voxel_simulation_wait reason=writeback seq=#{state.seq} thermal_due_ms=#{inspect(state.thermal_due)} liquid_due_ms=#{inspect(state.liquid_due)}")
    end
    put_in(state.page_store.paused, true)
  end

  @doc "积压计量（`World.stats`）：级别、后缀事务数、脏单元数、冻结存活、在途批与字节、最老未持久提交的年龄。"
  def backlog(%{page_store: store} = state) do
    now = System.monotonic_time(:millisecond)
    cut = store.cut
    since = (cut && cut.dirty_since) || store.dirty_since

    %{persist_level: store.level, persist_paused: store.paused,
      suffix_txns: if(store.published, do: state.seq - store.published, else: state.seq),
      dirty_units: MapSet.size(state.page_dirty),
      cut_units_left: if(cut, do: length(cut.todo), else: 0),
      frozen_ms: if(cut, do: div(System.monotonic_time(:microsecond) - cut.started, 1000), else: 0),
      inflight_batches: if(cut, do: length(cut.inflight), else: 0),
      inflight_bytes: if(cut, do: Enum.sum(cut.inflight), else: 0),
      oldest_dirty_ms: if(since, do: now - since, else: 0)}
  end

  @doc "切点定时器到期或 `compact` 请求：想要一次切点。"
  def want(state) do
    store = state.page_store
    if store.timer, do: :erlang.cancel_timer(store.timer)
    maybe_open(%{state | page_store: %{store | wanted: true, timer: nil}})
  end

  @doc "`compact/1`：调用时的 seq 已发布就立即回复，否则等覆盖它的切点发布。"
  def compact(state, from) do
    # 显式压实先把全部稀疏格并入基底（维护操作）。换基底只改表示、不改真值：变脏的基底页随下一个有新提交的切点写出，
    # 不单独要求持久（切点 seq 必须高于已发布前缀）。
    state = Log.rebase_overlay(state, 1)

    if covered?(state, state.seq) do
      GenServer.reply(from, :ok)
      state
    else
      want(update_in(state.page_store.waiters, &[{from, state.seq} | &1]))
    end
  end

  @doc "合法提交边界（热提交结束等）上若有待开的切点就开。"
  def maybe_open(%{page_store: %{wanted: false}} = state), do: state
  def maybe_open(%{page_store: %{cut: cut}} = state) when cut != nil, do: state

  def maybe_open(%{thermal_run: run} = state) when run != nil do
    store = state.page_store
    if store.timer, do: state, else: put_in(state.page_store.timer, :erlang.start_timer(@retry_ms, self(), :page_cut))
  end

  def maybe_open(state) do
    store = state.page_store

    if covered?(state, state.seq) do
      %{state | page_store: %{store | wanted: false}}
    else
      # 活动单元（M2b 活动索引）按本批涉及的页补入，值在抽取时按冻结状态判。
      units = Pages.with_activity(MapSet.to_list(state.page_dirty))
      attempt = make_ref()
      cut = %{attempt: attempt, seq: state.seq, frozen: Pages.frozen(state), units: units, todo: units, credits: @window,
        begun: false, publishing: false, started: System.monotonic_time(:microsecond), dirty_since: store.dirty_since, inflight: []}
      GenServer.cast(store.writer, {:begin, attempt, state.seq})
      %{state | page_dirty: MapSet.new(), page_store: %{store | cut: cut, wanted: false, dirty_since: nil}}
    end
  end

  defp covered?(state, seq), do: state.page_store.published != nil and seq <= state.page_store.published

  @doc "写回进程的回复。旧尝试的迟到结果丢弃。"
  def handle(state, {:page_begun, attempt}) do
    with_cut(state, attempt, fn cut -> pump(%{state | page_store: %{state.page_store | cut: %{cut | begun: true}}}) end)
  end

  def handle(state, {:page_ack, attempt}) do
    with_cut(state, attempt, fn cut ->
      pump(%{state | page_store: %{state.page_store | cut: %{cut | credits: cut.credits + 1, inflight: tl(cut.inflight)}}})
    end)
  end

  def handle(state, :page_pump) do
    case state.page_store.cut do
      %{begun: true} -> pump(state)
      _ -> state
    end
  end

  def handle(state, {:page_published, attempt, seq}) do
    with_cut(state, attempt, fn cut -> published(state, cut, seq) end)
  end

  def handle(state, {:page_failed, attempt, reason}) do
    with_cut(state, attempt, fn cut -> raise "page publish of seq #{cut.seq} failed: #{inspect(reason)}" end)
  end

  defp with_cut(%{page_store: %{cut: %{attempt: attempt} = cut}}, attempt, fun), do: fun.(cut)
  defp with_cut(state, _attempt, _fun), do: state

  defp pump(%{page_store: %{cut: cut}} = state) do
    cond do
      cut.publishing ->
        state

      cut.todo != [] and cut.credits > 0 ->
        {batch, todo} = Enum.split(cut.todo, @batch)
        units = Enum.map(batch, &{&1, Pages.extract(cut.frozen, &1)})
        GenServer.cast(state.page_store.writer, {:batch, cut.attempt, cut.seq, units})
        # 每个回合一批：其余批经自发消息排在其他提交之后。
        if todo != [], do: send(self(), :page_pump)
        put_in(state.page_store.cut, %{cut | todo: todo, credits: cut.credits - 1, inflight: cut.inflight ++ [:erlang.external_size(units)]})

      cut.todo == [] and cut.credits == @window ->
        globals = Pages.globals(cut.frozen)
        GenServer.cast(state.page_store.writer, {:publish, cut.attempt, cut.seq, [], globals})
        put_in(state.page_store.cut, %{cut | publishing: true, inflight: [byte_size(globals)]})

      true ->
        state
    end
  end

  defp published(state, cut, seq) do
    store = state.page_store
    {done, waiting} = Enum.split_with(store.waiters, fn {_, s} -> s <= seq end)

    # 已发布前缀之前的历史退休（订阅补发与分区增量只读其后的后缀）；Replica 等保留窗口满后再退休（`retire_replicas/1`）。
    entries = Map.filter(state.entries, fn {s, _} -> s > seq end)

    Logger.info(
      "voxel_page_cut seq=#{seq} current_seq=#{state.seq} units=#{length(cut.units)} retained=#{map_size(entries)} " <>
        "elapsed_us=#{System.monotonic_time(:microsecond) - cut.started}"
    )

    state = %{state | entries: entries, entry_regions: Enum.reduce(entries, %{}, fn {_, txn}, acc -> LogProjection.index(acc, txn) end),
      checkpoints: state.checkpoints + 1,
      page_store: %{store | published: seq, cut: nil, waiters: waiting, wanted: waiting != [],
        replica_pending: store.replica_pending ++ [{seq, System.monotonic_time(:millisecond)}]}}

    # 到期的 Replica 通知先于 compact 回复发出：调用方收到回复时，同节点 Replica 的邮箱里已排着它。
    state = retire_replicas(state)
    Enum.each(done, fn {from, _} -> GenServer.reply(from, :ok) end)
    state = assess(state)
    # 按区压实是非必要的后台维护：超软上限时不做（§5.3）。
    state = if at_least?(state, :soft), do: state, else: Log.rebase_overlay(state, @rebase_cells)
    state = maybe_open(state)
    if state.seq > seq, do: schedule(state), else: state
  end

  @doc """
  Replica 退休通知（§6.3）：在已确认的前缀里取确认时间距今满保留窗口的最新一个，只在它高于上次通知时发
  `{:canonical_replica_checkpoint, P}`；其余等窗口满，由定时器 `:replica_retire` 收尾（无新切点也会发出）。
  Replica 按“上一次通知的前缀”裁剪自己的增量，所以任何保留窗口内曾是当前的 seq 之后的增量都还在。
  """
  def retire_replicas(%{page_store: store} = state) do
    now = System.monotonic_time(:millisecond)
    {due, waiting} = Enum.split_with(store.replica_pending, fn {_, at} -> now - at >= store.replica_retain_ms end)

    sent =
      case List.last(due) do
        {prefix, _} when store.replica_sent == nil or prefix > store.replica_sent ->
          Enum.each(Map.keys(state.replica_subs), &send(&1, {:canonical_replica_checkpoint, prefix}))
          prefix

        _ ->
          store.replica_sent
      end

    timer =
      case {store.replica_timer, waiting} do
        {nil, [{_, at} | _]} -> :erlang.start_timer(at + store.replica_retain_ms - now, self(), :replica_retire)
        {timer, _} -> timer
      end

    %{state | page_store: %{store | replica_pending: waiting, replica_sent: sent, replica_timer: timer}}
  end
end
