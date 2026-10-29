defmodule VoxelRegion.World.PageLoad do
  @moduledoc """
  全局系统功能（M2b 按需装页，`m2b-on-demand-pages.md` §2.1；父稿 P4 装页令牌与意图准备）：World 不在回合内读库。

  - **闸**（`gate/3`）：入口裁决前按当前状态求读取闭包（`Closure.needs/2`，区域键扩同级 26 邻页）；全部驻留即放行，
    否则把 `{:call, message, from}` / `{:info, message}` 挂起、起一个装页任务（World 监控），World 继续处理别的消息。
  - **装页任务**（`run/3`，在任务进程里）：向 World 要令牌并登记页 owner（`{:page_need, ...}`，令牌 = 页键的当前代数）→ 读 PG
    （`read_pages` / `locate`）→ `{:page_stage, ...}` 由 World 暂存 → `{:page_commit, ...}` 在整树闭合后标驻留；其他请求共享该 owner，按自身闭包
    回后续页与要定位的身份 → 循环到无缺。正常结束后 World 重放挂起的消息（重新过闸：接纳时按当前状态复核；第二次起不再为
    查无此身份的 id 等待）；任务异常退出时对挂起的 call 显式回 `{:error, {:page_load_failed, reason}}`（I4，不当空气）。
  - **模拟**（`request/2`）：热 / 液体 / 投射物步前发现种子页未驻留时只起任务、不挂消息，装完唤醒调度（父稿 P4“该步暂停”）。
  - **维护入口**（`:all`）：装全部有行的页供该次维护使用；完成后仍按真实需求退休，不授予永久驻留。
  - **等待生命周期**：只监控挂起的同步 caller；退出或公共 `call/3` 显式报告超时后删其 entry。共享业务 / `:wake` 仍需求的任务继续，已接纳事务不回滚。
  - **接纳上下文**：`{:input, context, entry}` 沿页任务和 held 原样运输；arrival／request／ready 轮次与切点由 World 构造，
    PageLoad 不刷新时间、不维护物理 ready 队列，页完成也不代替 World 的真实接纳。
    动态裁决已发现的页附在同一不可变输入的 `page_dependencies`，保持到真实使用／取消，防止多轮洪泛重放丢失前段页。
  """
  require Logger
  alias VoxelRegion.World.{Admission, Closure, Pages}

  @batch 1024

  @typedoc "由 World 接纳 owner 构造的不可变输入上下文；PageLoad 只负责运输。"
  @type input_context :: %{optional(:waiter) => GenServer.from(), id: reference(), arrival_ms: integer(), request_ref: reference() | nil,
    ready_round: non_neg_integer(), ready_cutoff_ms: integer() | nil, page_dependencies: [tuple()]}

  @typedoc "原同步调用或异步业务条目；包裹后仍使用原 PageLoad 闸与任务生命周期。"
  @type input_entry :: {:input, input_context(), {:call, term(), GenServer.from()} | {:info, term()}}

  @doc "World 构造时的空状态。"
  def new, do: %{tasks: %{}, sim: nil, held: %{}, paused: nil, pending: %{}, staged: MapSet.new(), callers: %{}, preparations: %{}}

  @doc "准备完成至实际使用结束的唯一owner；外部baseline生成期间仍持有当前canonical读取闭包。"
  def prepare(state, token, caller, keys) do
    {:input, context, _} = state.input_current
    request = context.request_ref
    put_in(state.page_load.preparations[token], %{caller: caller, monitor: Process.monitor(caller),
      request: request, needs: {Pages.with_ancestors(keys), [], []}})
  end

  @doc "准备作用域结束显式释放；owner退出由同一释放函数收尾，不靠TTL。"
  def release_preparation(state, token, caller) do
    case state.page_load.preparations[token] do
      %{caller: ^caller, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        update_in(state.page_load.preparations, &Map.delete(&1, token))
      _ -> state
    end
  end

  @doc "调用方DOWN释放它尚未完成的所有准备作用域。"
  def release_preparations(state, caller) do
    Enum.reduce(state.page_load.preparations, state, fn
      {token, %{caller: ^caller}}, acc -> release_preparation(acc, token, caller)
      _, acc -> acc
    end)
  end

  @doc "页任务、caller输入、held序列、模拟IO和外部准备的当前读取闭包；沿用Closure的自然单元。"
  def residency_dependencies(state) do
    tasks = for {_, task} <- state.page_load.tasks, entry <- task.entries, entry != :wake, do: input_dependencies(state, entry)
    held = for {_, entries} <- state.page_load.held, entry <- entries, do: input_dependencies(state, entry)
    requests = for {_, task} <- state.page_load.tasks, do: Map.get(task, :request, :none)
    prepare = for {_, entry} <- state.page_load.preparations, do: entry.needs
    sim = if state.page_load.sim, do: [state.page_load.sim.request], else: []
    needs = tasks ++ held ++ requests ++ prepare ++ sim ++ [{[], Map.keys(state.page_load.pending), []}]
    if :all in needs, do: {:ok, :all}, else: {:ok, Enum.reduce(needs, {[], [], []}, fn
      :none, acc -> acc
      {keys, exact, ids}, {k, e, i} -> {keys ++ k, exact ++ e, ids ++ i}
    end)}
  end

  @doc "同一输入当前闭包与此前动态裁决已经发现的页；运输/重放不能丢掉下一轮仍会重读的前段。"
  def input_dependencies(state, {:input, context, _} = input) do
    exact = context.page_dependencies
    case Closure.needs(state, message(input)) do
      :all -> :all
      :none when exact == [] -> :none
      :none -> {[], exact, []}
      {keys, precise, ids} -> {keys, Enum.uniq(precise ++ exact), ids}
    end
  end
  def input_dependencies(state, entry), do: Closure.needs(state, message(entry))

  @doc "公共调用的等待边界：超时显式取消尚未接纳的挂起请求，原超时退出（结果未知）保持。"
  def call(server, message, timeout \\ 5000) do
    request = make_ref()

    try do
      GenServer.call(server, {:page_request, request, message}, timeout)
    catch
      :exit, {:timeout, _} = reason ->
        GenServer.cast(server, {:page_cancel, request})
        exit(reason)
    end
  end

  @doc "公共 wrapper 返回挂起时，关联其取消身份；立即接纳的调用不保留生命周期。"
  def identify(state, _from, nil), do: state

  def identify(state, from, request) do
    case state.page_load.callers[from] do
      nil -> state
      caller -> put_in(state.page_load.callers[from], %{caller | request: request})
    end
  end

  @doc "重放跨越接纳边界时保留同一调用的取消身份。"
  def request_id(state, from), do: get_in(state.page_load.callers, [from, :request])

  @doc "同步调用或Player受管异步输入确需等待时登记唯一owner；ready与页等待复用monitor，空身份不覆盖原请求。"
  def track(state, {pid, _} = from, request) do
    case state.page_load.callers[from] do
      nil -> put_in(state.page_load.callers[from], %{monitor: Process.monitor(pid), request: request})
      %{request: nil} = caller when request != nil ->
        put_in(state.page_load.callers[from], %{caller | request: request})
      _caller -> state
    end
  end

  defp watch(state, {:input, %{request_ref: request}, _} = input) do
    if from = Admission.from(input), do: track(state, from, request), else: state
  end
  defp watch(state, {:call, _, from}), do: track(state, from, nil)
  defp watch(state, _entry), do: state

  @doc "World 确认输入已离开等待边界：释放唯一 caller 监控；不会撤销已接纳的事务。"
  def accepted(state, from) do
    case Map.pop(state.page_load.callers, from) do
      {nil, _} -> state
      {caller, callers} ->
        Process.demonitor(caller.monitor, [:flush])
        put_in(state.page_load.callers, callers)
    end
  end

  @doc "caller DOWN 或 wrapper 超时：返回 `{取消的 from | nil, 页等待后继, state}`，World 同回合退休自己的 ready 输入。"
  def cancel(state, identity) do
    state = Enum.reduce(state.page_load.preparations, state, fn
      {token, %{request: ^identity, caller: caller}}, acc -> release_preparation(acc, token, caller)
      _, acc -> acc
    end)
    case Enum.find(state.page_load.callers, fn {_from, c} -> c.monitor == identity or c.request == identity end) do
      nil -> {nil, [], state}
      {from, _caller} ->
        state = accepted(state, from)
        {removed, tasks} = Enum.reduce(state.page_load.tasks, {[], %{}}, fn {ref, task}, {removed, tasks} ->
          {gone, entries} = Enum.split_with(task.entries, &caller_entry?(&1, from))
          {gone ++ removed, Map.put(tasks, ref, %{task | entries: entries})}
        end)
        held = Map.new(state.page_load.held, fn {key, entries} -> {key, Enum.reject(entries, &caller_entry?(&1, from))} end)
        state = put_in(state.page_load, %{state.page_load | tasks: tasks, held: held})
        {queued, state} = Enum.reduce(removed, {[], state}, fn entry, {queued, state} ->
          {next, state} = release(state, order_key(message(entry)))
          {queued ++ next, state}
        end)
        # 没有其他 caller / 异步业务 / 模拟需求的读任务可终止；共享任务继续，驻留页不回滚。
        state = Enum.reduce(state.page_load.tasks, state, fn
          {ref, %{entries: [], pid: pid}}, state ->
            Process.exit(pid, :kill)
            Process.demonitor(ref, [:flush])
            drop_task(state, ref)
          _, state -> state
        end)
        Logger.info("voxel_page_cancel reason=caller_cancelled entries=#{length(removed)}")
        {from, queued, state}
    end
  end

  defp caller_entry?({:input, _context, _entry} = input, from), do: Admission.from(input) == from
  defp caller_entry?({:call, _, from}, from), do: true
  defp caller_entry?(_, _), do: false

  @doc "该 DOWN 是否属于尚在等待的 caller。"
  def caller?(state, ref), do: Enum.any?(state.page_load.callers, fn {_, c} -> c.monitor == ref end)

  defp drop_task(state, ref) do
    update_in(state.page_load, fn load ->
      %{load | tasks: Map.delete(load.tasks, ref), pending: Map.reject(load.pending, fn {_, by} -> by == ref end)}
    end)
  end

  @doc """
  同序键：同一动作（施法 / 信标的准备、授权、取消，动作键 `{身份, client_intent_seq}`）或同一身体（接触、摘离、死亡，按 cid）的消息
  必须按到达顺序处理。前一条因装页挂起时，后到的排在它后面（`hold/2` 起排、`enqueue/3` 排队、`release/2` 取下）；其他消息 nil。
  """
  def order_key({:input, _context, entry}), do: order_key(message(entry))
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
  def enqueue(state, key, entry), do: state |> watch(entry) |> update_in([:page_load, :held, key], &(&1 ++ [entry]))

  @doc "World 在真实接纳、失败或取消边界取出同序后继并结束排队；页任务完成本身不释放此屏障。"
  def release(state, nil), do: {[], state}
  def release(state, key) do
    {queued, held} = Map.pop(state.page_load.held, key, [])
    {queued, put_in(state.page_load.held, held)}
  end

  @doc "入口闸：`{:ready, state}` 或 `{:deferred, state}`（已挂起）。`attempt` 为重放次数。"
  def gate(%{resident: :all} = state, _entry, _attempt), do: {:ready, state}

  def gate(state, entry, attempt) do
    case input_dependencies(state, entry) do
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
  def defer(state, entry, keys) do
    entry = case entry do
      {:input, context, original} -> {:input, %{context | page_dependencies:
        Enum.uniq(context.page_dependencies ++ keys)}, original}
      original -> original
    end
    hold(start(state, [entry], {[], keys, []}, 1), order_key(message(entry)))
  end

  @doc """
  定时模拟的种子页（L0 区域键，或按 state 求键的函数——`:all` 时不求）未驻留：起一个装页任务（同一时刻至多一个），装完唤醒模拟。
  返回 `{:ready | :loading, state}` 或 `{:failed, failure, state}`；真实失败必须由显式 retry 开启下一尝试。
  """
  def request(%{page_load: %{sim: %{status: :failed} = failure}} = state, _keys), do: {:failed, failure, state}
  def request(%{page_load: %{sim: %{status: :loading}}} = state, _keys), do: {:loading, state}
  def request(%{resident: :all} = state, _keys), do: {:ready, state}

  def request(state, keys) when is_function(keys, 1), do: request(state, keys.(state))

  def request(state, keys) do
    cond do
      missing(state, Pages.expand(keys)) == [] -> {:ready, state}
      true -> {:loading, start_simulation(state, {Enum.uniq(keys), [], []})}
    end
  end

  @doc "显式开始一次模拟依赖恢复；loading 重入只返回同一尝试，不新起任务，不伪称已经恢复。"
  def retry(%{page_load: %{sim: %{status: :loading, attempt_id: id}}} = state), do: {{:loading, id}, state}
  def retry(%{page_load: %{sim: %{status: :failed, request: request}}} = state) do
    state = start_simulation(state, request)
    {{:loading, state.page_load.sim.attempt_id}, state}
  end
  def retry(state), do: {{:error, :simulation_io_not_failed}, state}

  @doc "接纳／调度分支读取唯一失败事实，不构造CLI页诊断投影。"
  def failure(%{page_load: %{sim: %{status: :failed} = failure}}), do: failure
  def failure(_state), do: nil

  @doc "模拟依赖的唯一故障／读取事实；CLI投影不复制due、run或页内容。"
  def observe(%{page_load: %{sim: nil}}), do: %{status: :idle}
  def observe(%{page_load: %{sim: sim}}) do
    {keys, exact, _ids} = sim.request
    view = %{status: sim.status, attempt_id: inspect(sim.attempt_id), requested_keys: page_coordinates(Enum.uniq(keys ++ exact))}
    if sim.status == :failed do
      Map.merge(view, %{reason: inspect(sim.reason), failed_at_ms: sim.failed_at_ms,
        required_pages: page_coordinates(sim.required_pages)})
    else
      view
    end
  end

  defp page_coordinates(keys), do: Enum.map(keys, fn {level, {x, y, z}} -> %{level: level, x: x, y: y, z: z} end)

  defp start_simulation(state, request) do
    sim = %{status: :loading, attempt_id: make_ref(), request: request}
    Logger.info("voxel_simulation_io_started attempt=#{inspect(sim.attempt_id)}")
    state |> put_in([:page_load, :sim], sim) |> start([:wake], request, 0)
  end

  defp simulation_missing(state, {keys, exact, _ids}), do: missing(state, Enum.uniq(Pages.expand(keys) ++ exact))

  defp message({:input, _context, entry}), do: message(entry)
  defp message({:call, message, _from}), do: message
  defp message({:info, message}), do: message

  defp missing(state, keys), do: Enum.reject(keys, &Pages.resident?(state, &1))

  defp known?(state, {:aid, aid}), do: Map.has_key?(state.attachment_owners, aid)
  defp known?(state, id), do: Map.has_key?(state.instances, id)

  defp start(state, entries, request, attempt) do
    state = Enum.reduce(entries, state, &watch(&2, &1))
    other = case request do
      {keys, exact, _ids} -> pending_owner(state, Enum.uniq(Pages.expand(keys) ++ exact), nil)
      :all -> nil
    end

    if other do
      # 入闸时已有页读 owner 即挂到它；后续按自身闭包重放，不能让取消夹在新任务发令牌之前误杀共享读。
      update_in(state.page_load.tasks[other].entries, &(&1 ++ entries))
    else
      world = self()
      log = state.log
      {pid, ref} = spawn_monitor(fn -> run(world, log, request) end)
      put_in(state.page_load.tasks[ref], %{pid: pid, entries: entries, request: request, attempt: attempt, started: System.monotonic_time(:microsecond)})
    end
  end

  defp pending_owner(state, pages, owner),
    do: Enum.find_value(pages, fn key -> (by = state.page_load.pending[key]) != nil and by != owner and by end)

  @doc """
  World 的 `{:page_need, keys, exact, ids}`：未驻留页的令牌与内存里没有闭合的身份；都没有即 `:ready`。`task` 为发问的装页任务（pid）：
  需要的页已发给别的任务（含正在读取与分批暂存）时回 `{:conflict, ref}`——发问的任务把挂起条目交给那个任务、自己退出，无互等。
  """
  def need(state, keys, exact, ids, task \\ nil) do
    pages = missing(state, Enum.uniq(Pages.expand(keys) ++ exact))
    owner = owner(state, task)

    case pending_owner(state, pages, owner) do
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

  @doc "发出读取令牌的同一 World 回合登记唯一 owner；读取期间就共享，不等暂存后认领。"
  def reserve(state, task, {:load, tokens, _ids}) do
    case owner(state, task) do
      nil -> state
      ref -> update_in(state.page_load.pending, &Enum.reduce(tokens, &1, fn {key, _generation}, pending -> Map.put(pending, key, ref) end))
    end
  end

  def reserve(state, _task, _reply), do: state

  @doc """
  World 的 `{:page_stage, task, keys, units, ready}`：只装入发令牌时已归该任务的页；`keys` 保留批次观测接口。`ready`（粗层页与不带树身份 /
  引用的 L0 页，单元已全部装完）随本批标驻留、不再占住（`Pages.ready_batches/2`）。返回 `{state, 装入的属性行, 标驻留的页}`。
  """
  def stage(state, task, _keys, units, ready) do
    ref = owner(state, task)
    mine = for {key, ^ref} <- state.page_load.pending, into: MapSet.new(), do: key
    {state, loaded} = Pages.stage(state, mine, units)
    ready = Enum.filter(ready, &MapSet.member?(mine, &1))
    state = update_in(state.page_load.staged, &MapSet.difference(MapSet.union(&1, mine), MapSet.new(ready)))
    {state |> Pages.mark_resident(ready) |> update_in([:page_load, :pending], &Map.drop(&1, ready)), loaded, ready}
  end

  @doc "World 的 `{:page_commit, task}`：整树闭合即把该任务暂存的页一次标为驻留（回 `:ok`）；覆盖页还缺就回 `{:more, 页}`、不标驻留。"
  def commit(state, task) do
    ref = owner(state, task)
    keys = for {key, ^ref} <- state.page_load.pending, do: key

    case Pages.commit_missing(state, keys) do
      [] ->
        state = state |> Pages.mark_resident(keys) |> update_in([:page_load, :pending], &Map.drop(&1, keys))
          |> update_in([:page_load, :staged], &MapSet.difference(&1, MapSet.new(keys)))
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
        {entries, state} = if :wake in task.entries,
          do: finish_simulation(state, task.entries, reason), else: {task.entries, state}
        Logger.info("voxel_page_load entries=#{length(task.entries)} attempt=#{task.attempt} reason=#{inspect(reason)} " <>
          "elapsed_us=#{System.monotonic_time(:microsecond) - task.started}")
        {entries, task.attempt, state}
    end
  end

  defp finish_simulation(state, entries, :normal) do
    sim = state.page_load.sim
    case simulation_missing(state, sim.request) do
      [] ->
        Logger.info("voxel_simulation_io_dependencies_ready attempt=#{inspect(sim.attempt_id)}")
        {entries, put_in(state.page_load.sim, nil)}
      _more ->
        # 共享owner可能只完成相交部分；继续同一请求闭包，不把它当完整恢复，也不创建新attempt。
        {Enum.reject(entries, &(&1 == :wake)), start(state, [:wake], sim.request, 0)}
    end
  end

  defp finish_simulation(state, entries, reason) do
    sim = state.page_load.sim
    failure = Map.merge(sim, %{status: :failed, reason: reason, failed_at_ms: System.monotonic_time(:millisecond),
      required_pages: simulation_missing(state, sim.request)})
    Logger.error("voxel_simulation_io_failed attempt=#{inspect(sim.attempt_id)} required_pages=#{length(failure.required_pages)} reason=#{inspect(reason)}")
    {entries, put_in(state.page_load.sim, failure)}
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

    case loop(world, backend, handle, [], keys, [], empty()) do
      :ok -> :ok = GenServer.call(world, :page_resident_all, :infinity)
      :yielded -> :ok
    end
  end

  def run(world, {backend, handle}, {keys, exact, ids}), do: loop(world, backend, handle, keys, exact, ids, empty())

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
        :yielded

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
