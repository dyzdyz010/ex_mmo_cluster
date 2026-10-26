defmodule VoxelRegion.World.PageLoad do
  @moduledoc """
  全局系统功能（M2b 按需装页，`m2b-on-demand-pages.md` §2.1；父稿 P4 装页令牌与意图准备）：World 不在回合内读库。

  - **闸**（`gate/3`）：入口裁决前按当前状态求读取闭包（`Closure.needs/2`，区域键扩同级 26 邻页）；全部驻留即放行，
    否则把 `{:call, message, from}` / `{:info, message}` 挂起、起一个装页任务（World 监控），World 继续处理别的消息。
  - **装页任务**（`run/3`，在任务进程里）：向 World 要令牌（`{:page_need, ...}`，令牌 = 页键的代数，本步不淘汰恒为 0）→ 读 PG
    （`read_pages` / `locate`）→ `{:page_adopt, ...}` 由 World 接纳（只收令牌匹配且仍未驻留的页，`Pages.adopt/4`）→ World 按驻留闭合
    回后续页与要定位的身份 → 循环到无缺。正常结束后 World 重放挂起的消息（重新过闸：接纳时按当前状态复核；第二次起不再为
    查无此身份的 id 等待）；任务异常退出时对挂起的 call 显式回 `{:error, {:page_load_failed, reason}}`（I4，不当空气）。
  - **模拟**（`request/2`）：热 / 液体 / 投射物步前发现种子页未驻留时只起任务、不挂消息，装完唤醒调度（父稿 P4“该步暂停”）。
  - **维护入口**（`:all`）：装全部有行的页后驻留集切为 `:all`。
  """
  require Logger
  alias VoxelRegion.World.{Closure, Pages}

  @batch 1024

  @doc "World 构造时的空状态。"
  def new, do: %{tasks: %{}, sim: nil, held: %{}, paused: nil, pending: %{}}

  @doc """
  同序键：同一动作（施法 / 信标的准备、授权、取消，动作键 `{身份, client_intent_seq}`）或同一身体（接触、摘离、死亡，按 cid）的消息
  必须按到达顺序处理。前一条因装页挂起时，后到的排在它后面（`hold/2` 起排、`enqueue/3` 排队、`release/2` 取下）；其他消息 nil。
  """
  def order_key({tag, key, _, _, _}) when tag == :prepare_cast, do: {:action, key}
  def order_key({tag, key, _, _}) when tag in [:authorize_cast, :prepare_beacon, :commit_beacon], do: {:action, key}
  def order_key({:cancel_cast, key, _reason}), do: {:action, key}
  def order_key({tag, cid, _, _}) when tag in [:body_contact, :body_detach], do: {:body, cid}
  def order_key({:body_death, cid, _feet}), do: {:body, cid}
  def order_key(_message), do: nil

  @doc "该序列是否有挂起的前一条。"
  def held?(_state, nil), do: false
  def held?(state, key), do: Map.has_key?(state.page_load.held, key)

  @doc "消息被挂起：其序列开始排队（已在排队则不变）。"
  def hold(state, nil), do: state
  def hold(state, key), do: update_in(state.page_load.held, &Map.put_new(&1, key, []))

  @doc "排在挂起消息之后。"
  def enqueue(state, key, entry), do: update_in(state.page_load.held[key], &(&1 ++ [entry]))

  @doc "挂起的消息装完要重放：取下排在它后面的消息（按到达顺序）并结束排队。"
  def release(state, nil), do: {[], state}
  def release(state, key) do
    {queued, held} = Map.pop(state.page_load.held, key, [])
    {queued, put_in(state.page_load.held, held)}
  end

  @doc "入口闸：`{:ready, state}` 或 `{:deferred, state}`（已挂起）。`attempt` 为重放次数。"
  def gate(%{resident: :all} = state, _entry, _attempt), do: {:ready, state}

  def gate(state, entry, attempt) do
    case Closure.needs(state, message(entry)) do
      :none ->
        {:ready, state}

      :all ->
        {:deferred, start(state, [entry], :all, attempt)}

      {keys, exact, ids} ->
        pages = missing(state, Enum.uniq(Pages.expand(keys) ++ exact))
        # 未闭合的身份要定位补根；重放（attempt > 0）时只跳过定位后内存里仍没有记录的 id（查无此身份，不无限挂起）。
        # 内存里有记录而树未闭合的（让出 / 撤销暂存留下的半棵树）继续定位（评审 Fable §2.3）。
        ids = Enum.reject(Enum.uniq(ids), &(Pages.tree_complete?(state, &1) or (attempt > 0 and not known?(state, &1))))
        if pages == [] and ids == [], do: {:ready, state}, else: {:deferred, start(state, [entry], {keys, exact, ids}, attempt)}
    end
  end

  @doc "裁决中途发现的闭包（刷新姿态后的射线、动态洪泛）：未驻留的页；空即可以继续裁决。"
  def missing_keys(state, {keys, exact, _ids}), do: missing(state, Enum.uniq(Pages.expand(keys) ++ exact))
  def missing_keys(_state, _needs), do: []

  @doc "把消息挂起，装 `keys`（只装这些页本身）后重放（重放时重新过闸、重新裁决）。"
  def defer(state, entry, keys), do: hold(start(state, [entry], {[], keys, []}, 1), order_key(message(entry)))

  @doc """
  定时模拟的种子页（L0 区域键，或按 state 求键的函数——`:all` 时不求）未驻留：起一个装页任务（同一时刻至多一个），装完唤醒模拟。
  返回 `{:ready | :loading, state}`。
  """
  def request(%{resident: :all} = state, _keys), do: {:ready, state}

  def request(state, keys) when is_function(keys, 1), do: request(state, keys.(state))

  def request(state, keys) do
    cond do
      missing(state, Pages.expand(keys)) == [] -> {:ready, state}
      state.page_load.sim != nil -> {:loading, state}
      true ->
        state = start(state, [:wake], {keys, [], []}, 0)
        {:loading, put_in(state.page_load.sim, :loading)}
    end
  end

  defp message({:call, message, _from}), do: message
  defp message({:info, message}), do: message

  defp missing(state, keys), do: Enum.reject(keys, &Pages.resident?(state, &1))

  defp known?(state, {:aid, aid}), do: Map.has_key?(state.attachment_owners, aid)
  defp known?(state, id), do: Map.has_key?(state.instances, id)

  defp start(state, entries, request, attempt) do
    world = self()
    log = state.log
    {pid, ref} = spawn_monitor(fn -> run(world, log, request) end)
    put_in(state.page_load.tasks[ref], %{pid: pid, entries: entries, attempt: attempt, started: System.monotonic_time(:microsecond)})
  end

  @doc """
  World 的 `{:page_need, keys, exact, ids}`：未驻留页的令牌与内存里没有闭合的身份；都没有即 `:ready`。`task` 为发问的装页任务（pid）：
  需要的页正由别的任务分批暂存时回 `{:conflict, ref}`——发问的任务把挂起条目交给那个任务、自己退出（一页只由一个任务暂存，无互等）。
  """
  def need(state, keys, exact, ids, task \\ nil) do
    pages = missing(state, Enum.uniq(Pages.expand(keys) ++ exact))
    owner = owner(state, task)

    case Enum.find_value(pages, fn key -> (by = state.page_load.pending[key]) != nil and by != owner and by end) do
      nil ->
        pages = Enum.reject(pages, &(state.page_load.pending[&1] == owner and owner != nil))
        # 已在内存但整树未闭合的身份（孤儿）仍要定位补根。
        ids = Enum.reject(Enum.uniq(ids), &Pages.tree_complete?(state, &1))
        if pages == [] and ids == [], do: :ready, else: {:load, Enum.map(pages, &{&1, Map.get(state.page_generation, &1, 0)}), ids}

      other ->
        {:conflict, other}
    end
  end

  defp owner(_state, nil), do: nil
  defp owner(state, pid), do: Enum.find_value(state.page_load.tasks, fn {ref, t} -> t.pid == pid and ref end)

  @doc """
  World 的 `{:page_stage, task, keys, units, ready}`：分批装入一个任务暂存的页，`keys` 记为该任务暂存；`ready`（粗层页与不带树身份 /
  引用的 L0 页，单元已全部装完）随本批标驻留、不再占住（`Pages.ready_batches/2`）。返回 `{state, 装入的属性行, 标驻留的页}`。
  """
  def stage(state, task, keys, units, ready) do
    ref = owner(state, task)
    keys = for key <- keys, not Pages.resident?(state, key), Map.get(state.page_load.pending, key, ref) == ref, do: key
    state = update_in(state.page_load.pending, &Enum.reduce(keys, &1, fn key, acc -> Map.put(acc, key, ref) end))
    mine = for {key, ^ref} <- state.page_load.pending, into: MapSet.new(), do: key
    {state, loaded} = Pages.stage(state, mine, units)
    ready = Enum.filter(ready, &MapSet.member?(mine, &1))
    {state |> Pages.mark_resident(ready) |> update_in([:page_load, :pending], &Map.drop(&1, ready)), loaded, ready}
  end

  @doc "World 的 `{:page_commit, task}`：整树闭合即把该任务暂存的页一次标为驻留（回 `:ok`）；覆盖页还缺就回 `{:more, 页}`、不标驻留。"
  def commit(state, task) do
    ref = owner(state, task)
    keys = for {key, ^ref} <- state.page_load.pending, do: key

    case Pages.commit_missing(state, keys) do
      [] ->
        state = state |> Pages.mark_resident(keys) |> update_in([:page_load, :pending], &Map.drop(&1, keys))
        {:ok, state}

      more ->
        {{:more, more}, state}
    end
  end

  @doc "World 的 `{:page_yield, task, other}`：发问的任务撞上别的任务暂存的页，把自己的挂起条目交给它（它结束时一起重放）。"
  def yield(state, task, other) do
    ref = owner(state, task)

    case {state.page_load.tasks[ref], state.page_load.tasks[other]} do
      {%{} = mine, %{} = theirs} ->
        state = put_in(state.page_load.tasks[other], %{theirs | entries: theirs.entries ++ mine.entries})
        put_in(state.page_load.tasks[ref], %{mine | entries: []})

      _ ->
        state
    end
  end

  @doc "World 的 `{:page_adopt, ...}`：接纳并返回 `{state, 后续 {页, 身份}, 装入的属性行}`。"
  def adopt(state, tokens, rows, located), do: Pages.adopt(state, tokens, rows, located)

  @doc "任务进程 `DOWN`：`{挂起的条目, attempt, state}`；不是装页任务返回 `:unknown`。"
  def finish(state, ref, reason) do
    case Map.pop(state.page_load.tasks, ref) do
      {nil, _} ->
        :unknown

      {task, tasks} ->
        # 任务结束（正常提交后已清；失败 / 让出时）：它暂存而未标驻留的页撤销暂存，之后别的任务可以重新暂存（数据与 PG 相同，重装幂等）。
        pending = Map.reject(state.page_load.pending, fn {_, by} -> by == ref end)
        state = put_in(state.page_load, %{state.page_load | tasks: tasks, pending: pending})
        state = if :wake in task.entries, do: put_in(state.page_load.sim, nil), else: state
        Logger.info("voxel_page_load entries=#{length(task.entries)} attempt=#{task.attempt} reason=#{inspect(reason)} " <>
          "elapsed_us=#{System.monotonic_time(:microsecond) - task.started}")
        {task.entries, task.attempt, state}
    end
  end

  # ---- 任务进程

  @doc "装页任务主体（在任务进程里运行；只读 PG、经 World 调用接纳，不读写 World 状态）。"
  def run(world, {backend, handle}, :all) do
    keys =
      handle
      |> backend.page_keys()
      |> Enum.map(fn {level, region, segment} ->
        if segment in Pages.fragment_codes(), do: {0, region}, else: {level, region}
      end)
      |> Enum.uniq()

    batched(world, backend, handle, [], keys, [])
    :ok = GenServer.call(world, :page_resident_all, :infinity)
  end

  def run(world, {backend, handle}, {keys, exact, ids}), do: loop(world, backend, handle, keys, exact, ids, empty())

  # 维护入口装全部页：分批接纳（结束即切为 `:all`）。
  defp batched(world, backend, handle, keys, exact, ids) do
    case GenServer.call(world, {:page_need, keys, exact, ids}, :infinity) do
      :ready ->
        :ok

      {:load, tokens, ids} ->
        located = backend.locate(handle, Enum.map(ids, &Pages.locator_key/1))
        {batch, rest} = Enum.split(tokens, @batch)
        %{rows: rows} = backend.read_pages(handle, Enum.map(batch, &elem(&1, 0)), Pages.fragment_codes())
        {more, ids} = GenServer.call(world, {:page_adopt, batch, rows, located}, :infinity)
        batched(world, backend, handle, [], Enum.map(rest, &elem(&1, 0)) ++ more, ids)
    end
  end

  # 闭包在任务里按 PG 行闭合（评审 A1 / F2）：每轮读页、在任务里解码、增量求闭包（`Pages.closure_add/2`），并把解码结果按固定规模分批
  # 交 World 暂存（`:page_stage`，每批一个 World 回合，回合有上界）；整树闭合后一次 `:page_commit` 标记驻留。暂存页在此之前不驻留，
  # 别的请求过闸时仍要等，看不到半棵树。撞上别的任务正在暂存的页即让出（`:page_yield`）。
  # 每批：解码后单元的压缩字节与行数上限（一个 World 接纳回合 ≲ 百毫秒级）。
  @stage_bytes 64 * 1024
  @stage_rows 16

  defp empty, do: %{pages: MapSet.new(), located: %{}, asked: MapSet.new(), closure: Pages.closure_new()}

  defp loop(world, backend, handle, keys, exact, ids, acc) do
    exact = Enum.reject(exact, &MapSet.member?(acc.pages, &1))
    ids = Enum.reject(ids, &MapSet.member?(acc.asked, &1))

    case GenServer.call(world, {:page_need, keys, exact, ids, self()}, :infinity) do
      :ready ->
        commit(world, backend, handle, acc)

      {:conflict, other} ->
        :ok = GenServer.call(world, {:page_yield, self(), other}, :infinity)

      {:load, tokens, ids} ->
        t0 = System.monotonic_time(:microsecond)
        tokens = Enum.reject(tokens, fn {key, _} -> MapSet.member?(acc.pages, key) end)
        located = backend.locate(handle, Enum.map(ids, &Pages.locator_key/1))
        t1 = System.monotonic_time(:microsecond)
        rows = tokens |> Enum.map(&elem(&1, 0)) |> Enum.chunk_every(@batch)
          |> Enum.flat_map(&backend.read_pages(handle, &1, Pages.fragment_codes()).rows)
        t2 = System.monotonic_time(:microsecond)
        # 解码（解压 + binary_to_term）只在任务里做一次，按行并行（不占 World 回合）。
        units =
          rows
          |> Task.async_stream(&{Pages.unit_value(&1), byte_size(&1.payload)}, ordered: true, timeout: :infinity)
          |> Enum.map(fn {:ok, unit} -> unit end)
        t3 = System.monotonic_time(:microsecond)
        closure = Pages.closure_add(acc.closure, Enum.map(units, &elem(&1, 0)))
        acc = %{acc | closure: closure, pages: Enum.into(Enum.map(tokens, &elem(&1, 0)), acc.pages), asked: Enum.into(ids, acc.asked),
          located: Map.merge(acc.located, located)}
        {exact, ids} = Pages.closure_next(closure, acc.located, acc.pages, acc.asked)
        t4 = System.monotonic_time(:microsecond)
        stages = stage(world, Enum.map(tokens, &elem(&1, 0)), units)
        # 装页任务每轮的耗时拆分（定位 / 读段 / 解码 / 求闭包 / 分批暂存），World 回合另见 `voxel_page_stage`。
        Logger.info("voxel_page_load_round pages=#{length(tokens)} ids=#{map_size(located)} rows=#{length(rows)} " <>
          "bytes=#{Enum.sum(Enum.map(rows, &byte_size(&1.payload)))} locate_us=#{t1 - t0} read_us=#{t2 - t1} decode_us=#{t3 - t2} " <>
          "closure_us=#{t4 - t3} stage_us=#{System.monotonic_time(:microsecond) - t4} stages=#{stages} next_pages=#{length(exact)} next_ids=#{length(ids)}")
        loop(world, backend, handle, [], exact, ids, acc)
    end
  end

  # 分批暂存：第一批带上本轮全部页键（空页也记为暂存）；按压缩字节与行数切批，每批一次 World 调用；平凡页随其最后一批标驻留。
  defp stage(world, keys, units) do
    batches = chunk(units, [], 0, [])
    batches = if batches == [], do: [[]], else: batches

    batches
    |> Enum.zip(Pages.ready_batches(keys, batches))
    |> Enum.with_index()
    |> Enum.each(fn {{batch, ready}, i} ->
      {:ok, _} = GenServer.call(world, {:page_stage, self(), if(i == 0, do: keys, else: []), batch, ready}, :infinity)
    end)

    length(batches)
  end

  defp chunk([], [], _bytes, out), do: Enum.reverse(out)
  defp chunk([], cur, _bytes, out), do: Enum.reverse([Enum.reverse(cur) | out])

  defp chunk([{unit, size} | rest], cur, bytes, out) do
    if cur != [] and (bytes + size > @stage_bytes or length(cur) >= @stage_rows),
      do: chunk(rest, [unit], size, [Enum.reverse(cur) | out]),
      else: chunk(rest, [unit | cur], bytes + size, out)
  end

  defp commit(world, backend, handle, acc) do
    if MapSet.size(acc.pages) == 0 do
      :ok
    else
      case GenServer.call(world, {:page_commit, self()}, :infinity) do
        :ok -> :ok
        {:more, pages} -> loop(world, backend, handle, [], pages, [], acc)
      end
    end
  end

  @doc "World 构造时的同步装页（启动后缀 / 活动页）：同一循环，直接读后端、在本进程接纳。"
  def load_sync(%{log: {backend, handle}} = state, keys, exact, ids) do
    case need(state, keys, exact, ids) do
      :ready ->
        state

      {:load, tokens, ids} ->
        located = backend.locate(handle, Enum.map(ids, &Pages.locator_key/1))
        {batch, rest} = Enum.split(tokens, @batch)
        %{rows: rows} = backend.read_pages(handle, Enum.map(batch, &elem(&1, 0)), Pages.fragment_codes())
        {state, {more, ids}, _rows} = adopt(state, batch, rows, located)
        load_sync(state, [], Enum.map(rest, &elem(&1, 0)) ++ more, ids)
    end
  end
end
