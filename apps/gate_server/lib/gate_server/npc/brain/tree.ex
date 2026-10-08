defmodule GateServer.Npc.Brain.Tree do
  @moduledoc """
  全局系统功能：最小行为树后端（角色能力函数库设计稿 docs/10-active/cross-cutting/2026-10-07-character-capability-library.md §8.2）。
  纯函数 Brain，同 Patrol：不起进程、不读时钟，时间只看 Observation 的 `self.tick`（1 tick = 1/60 s）。
  叶子 `act` 经 `GateServer.Npc.Abilities.command/4` 构造命令，与 LLM 共用同一份能力定义（名字、参数规格、
  经 Abilities 的目标句柄只允许 granularity 0..3）；命令形状见 `GateServer.Npc.Brain`。

  profile：`%{tree: fn profile -> {树, 黑板初值} end, ...}`，其余键（`tools`、`skills`、`groups`…）就是 Abilities 的 profile。
  `init/1` 调 `tree.(profile)`，再经 `new/2` 校验。树的定义放在 `GateServer.Npc.Trees`。

  | 节点 | 形状 | 语义 |
  |---|---|---|
  | seq | `{:seq, [子]}` | 依次执行，带记忆（RUNNING 的子节点下次从它继续）；任一 FAILURE 即 FAILURE |
  | sel | `{:sel, [子]}` | 依次尝试，带记忆；任一 SUCCESS 即 SUCCESS；全 FAILURE 为 FAILURE |
  | act | `{:act, 名字, 参数, opts}` / `{:act, 名字, 参数}`（opts 缺省 `[]`） | 一条能力命令（见下）；发出后 RUNNING，直到同 id 的 Outcome |
  | cond | `{:cond, fun}` | `fun.(黑板, 观察) :: boolean`，立即 SUCCESS / FAILURE |
  | wait | `{:wait, ticks \\| fun}` | 首次 tick 记下 `until = tick + n`（fun 形 `n = fun.(黑板)`），观察的 tick 到了 SUCCESS |
  | repeat | `{:repeat, n \\| :forever, 子}` | 子 SUCCESS 就再来，直到 n 次；子 FAILURE 即 FAILURE。每轮结束先 RUNNING，下一个事件再开下一轮 |
  | each | `{:each, 键, as, 子}` | 遍历黑板 `键` 的列表，每项写进黑板 `as` 再执行子节点；行为同 seq |
  | succeed / fail | `{:succeed, 子, opts}` / `{:fail, 子}` | 子结束后强制 SUCCESS / FAILURE；`succeed` 带 `log: 标签` 时子 FAILURE 记一行 `标签 entity= act= reason=`（取黑板 `:last_failure`），带 `context: 键` 时追加 `context=` 该黑板值 |

  `act`：参数是 JSON 形 map（字符串键、数组，与 LLM 工具参数同形），或纯函数 `fn 黑板 -> map end`（tick 时求值）。
  id 由树单调分配（1, 2, …）。done → SUCCESS（`store: 键` 时把 `data` 写进黑板）；rejected / superseded → FAILURE，
  并把 `%{act: 名字, reason: 原因}` 写进黑板 `:last_failure`（superseded 的原因记 `:superseded`）。构造结果是
  `unknown_tool` / `invalid_tool_arguments` 时本地 FAILURE、不发给 Body。`retry: ticks`：被拒且原因是
  `:invalid_session` / `:dead` / `:session_lost`（`transient/0`：命令没被执行或角色暂时不能行动）时不判失败，`ticks` 后用
  新 id 原样重发同一命令。原样重发只适合与位置无关、重发也不会多做的命令（只读、`move_to`；放置重发得 occupied）：
  死亡复活与重新 claim 后身体在出生点，参数取自会变的世界状态（如 gather 的缺额，中途失败时已挖的格已入账），
  这类步骤不要用 retry，在树里从上游重来（`GateServer.Npc.Trees.settler/1` 的工地重来）。

  构造期校验（typed ports）：`new/2` 要求每个 `act` 的名字都在 `Abilities.entries(profile)` 里，静态 map 参数当场译码一次；
  节点形状不对、名字未知或静态参数不合法都 raise（作者配置错误，启动即失败，不降级）。技能叶子的参数原样透传
  （Abilities 不译码技能参数），建树时不校验，由技能在运行时以 `invalid_skill_arguments` 拒绝。函数形参数在 tick 时译码。

  黑板是普通 map，只由 `act` 的 `store:`、`each` 的 `as` 与 `act` 的失败写入；节点状态只有 SUCCESS / FAILURE / RUNNING。

  事件：`{:observation, o}` 更新最新观察并 tick 根（推进 wait 与 retry）；`{:outcome, o}` 只交给 id 匹配的 RUNNING 叶子，
  然后 tick 根；`{:heard, _}` 忽略。首个 Observation 到达后才 tick 根；根结束后不再发命令。

  halt（`halt/1`）：放弃整棵树在途的叶子——RUNNING 的技能叶子发 `%{verb: :cancel_skill, call: 叶子 id}`，RUNNING 的移动叶子
  发 `%{verb: :stop}`，RUNNING 的世界事务不撤销（已提交不可顶替）；被 halt 的 id 进入 draining，其 Outcome 丢弃；
  draining 里有技能 id 时不启动新的技能叶子（结构上避免 `skill_busy`），技能终态到达后移出。之后的下一个事件从根重新开始。
  本模块的节点都带记忆、没有 reactive 节点，运行时不会自己放弃子节点。
  """
  @behaviour GateServer.Npc.Brain
  require Logger
  alias GateServer.Npc.Abilities

  # 命令没被执行、或角色暂时不能行动：retry 只对这些原因重发。
  @transient [:invalid_session, :dead, :session_lost]

  @doc "瞬态原因（`retry:` 只对它们重发）：命令没被执行，或角色暂时不能行动。"
  def transient, do: @transient

  @doc """
  校验树并返回初始状态（空黑板）；名字未知、静态参数不合法或节点形状不对时 raise。技能叶子的参数不在这里校验
  （原样透传给技能）。
  """
  def new(tree, profile) do
    names = MapSet.new(Abilities.entries(profile), & &1.name)
    check!(tree, names, profile)

    %{
      tree: tree,
      profile: profile,
      node: nil,
      blackboard: %{},
      observation: nil,
      next_id: 1,
      # 在途叶子：id => :skill | :move | :world。
      pending: %{},
      # 被 halt 的 id：其 Outcome 丢弃。
      draining: %{},
      finished: nil
    }
  end

  @impl true
  def init(%{tree: build} = profile) do
    {tree, blackboard} = build.(profile)
    %{new(tree, profile) | blackboard: blackboard}
  end

  @impl true
  def handle_event({:observation, observation}, state),
    do: run(%{state | observation: observation}, nil)

  def handle_event({:outcome, %{id: id} = outcome}, state) do
    cond do
      Map.has_key?(state.pending, id) -> run(state, outcome)
      Map.has_key?(state.draining, id) -> {[], %{state | draining: Map.delete(state.draining, id)}}
      true -> {[], state}
    end
  end

  def handle_event(_event, state), do: {[], state}

  @doc """
  放弃整棵树在途的叶子，返回 `{命令, 状态}`：技能叶子 → `cancel_skill`，移动叶子 → `stop`，世界事务不撤销；
  这些 id 进入 draining。下一个事件从根重新开始。
  """
  def halt(state) do
    {commands, next_id} =
      Enum.flat_map_reduce(Enum.sort(state.pending), state.next_id, fn
        {id, :skill}, next -> {[%{id: next, verb: :cancel_skill, call: id}], next + 1}
        {_id, :move}, next -> {[%{id: next, verb: :stop}], next + 1}
        {_id, :world}, next -> {[], next}
      end)

    {commands,
     %{
       state
       | node: nil,
         pending: %{},
         draining: Map.merge(state.draining, state.pending),
         next_id: next_id
     }}
  end

  # —— tick ——

  defp run(%{finished: nil, observation: observation} = state, outcome) when observation != nil do
    ctx = %{
      blackboard: state.blackboard,
      observation: observation,
      tick: observation.self.tick,
      outcome: outcome,
      profile: state.profile,
      commands: [],
      next_id: state.next_id,
      pending: state.pending,
      draining: state.draining
    }

    {status, node, ctx} = tick(state.tree, state.node, ctx)

    {Enum.reverse(ctx.commands),
     %{
       state
       | node: node,
         blackboard: ctx.blackboard,
         next_id: ctx.next_id,
         pending: ctx.pending,
         finished: if(status != :running, do: status)
     }}
  end

  defp run(state, _outcome), do: {[], state}

  # 每个节点：tick(节点, 节点状态, ctx) → {:success | :failure | :running, 节点状态, ctx}；节点状态 nil = 未开始。
  defp tick({:seq, children}, node, ctx), do: sequence(children, node || {0, nil}, ctx, :success)
  defp tick({:sel, children}, node, ctx), do: sequence(children, node || {0, nil}, ctx, :failure)

  defp tick({:cond, fun}, _node, ctx),
    do: {if(fun.(ctx.blackboard, ctx.observation), do: :success, else: :failure), nil, ctx}

  defp tick({:wait, n}, nil, ctx),
    do: wait(ctx.tick + if(is_function(n, 1), do: n.(ctx.blackboard), else: n), ctx)

  defp tick({:wait, _}, until, ctx), do: wait(until, ctx)

  defp tick({:repeat, n, child}, node, ctx) do
    {count, child_node} = node || {0, nil}
    child_node = if child_node == :next, do: nil, else: child_node

    case tick(child, child_node, ctx) do
      {:running, child_node, ctx} -> {:running, {count, child_node}, ctx}
      {:failure, _, ctx} -> {:failure, nil, ctx}
      {:success, _, ctx} when n != :forever and count + 1 >= n -> {:success, nil, ctx}
      # 每轮结束先 RUNNING，下一个事件再开下一轮（防同一事件内空转）。
      {:success, _, ctx} -> {:running, {count + 1, :next}, ctx}
    end
  end

  defp tick({:each, key, _, _} = each, nil, ctx),
    do: each(each, {Map.fetch!(ctx.blackboard, key), nil}, ctx)

  defp tick({:each, _, _, _} = each, node, ctx), do: each(each, node, ctx)

  defp tick({:succeed, child, opts}, node, ctx) do
    case tick(child, node, ctx) do
      {:running, node, ctx} ->
        {:running, node, ctx}

      {:success, _, ctx} ->
        {:success, nil, ctx}

      {:failure, _, ctx} ->
        if tag = opts[:log], do: log(tag, opts[:context], ctx)
        {:success, nil, ctx}
    end
  end

  defp tick({:fail, child}, node, ctx) do
    case tick(child, node, ctx) do
      {:running, node, ctx} -> {:running, node, ctx}
      {_, _, ctx} -> {:failure, nil, ctx}
    end
  end

  defp tick({:act, name, args}, node, ctx), do: tick({:act, name, args, []}, node, ctx)

  # 未开始：构造命令并发出（构造失败本地 FAILURE，不发给 Body）。
  defp tick({:act, name, args, _opts}, nil, ctx) do
    args = if is_function(args, 1), do: args.(ctx.blackboard), else: args

    case Abilities.command(name, args, ctx.next_id, ctx.profile) do
      %{verb: verb} when verb in [:unknown_tool, :invalid_tool_arguments] -> failed(name, verb, ctx)
      command -> start(Map.delete(command, :id), nil, ctx)
    end
  end

  # 在途：只认同 id 的 Outcome。
  defp tick({:act, name, _, opts}, %{id: id} = leaf, %{outcome: %{id: id} = outcome} = ctx) do
    ctx = %{ctx | outcome: nil, pending: Map.delete(ctx.pending, id)}

    cond do
      outcome.status == :done ->
        {:success, nil, store(ctx, opts[:store], outcome.data)}

      outcome.status == :rejected and outcome.reason in @transient and opts[:retry] != nil ->
        {:running, %{retry_at: ctx.tick + opts[:retry], command: leaf.command}, ctx}

      true ->
        failed(name, outcome.reason || outcome.status, ctx)
    end
  end

  # 瞬态拒绝之后：到点用新 id 重发同一命令。
  defp tick({:act, _, _, _}, %{retry_at: at, command: command} = leaf, %{tick: tick} = ctx)
       when tick >= at,
       do: start(command, leaf, ctx)

  defp tick({:act, _, _, _}, leaf, ctx), do: {:running, leaf, ctx}

  # seq 与 sel 同一骨架：子节点得到 `go_on` 就继续下一个（seq 是 SUCCESS，sel 是 FAILURE），全部如此即以它结束。
  defp sequence(children, {index, child_node}, ctx, go_on) do
    case Enum.at(children, index) do
      nil ->
        {go_on, nil, ctx}

      child ->
        case tick(child, child_node, ctx) do
          {:running, child_node, ctx} -> {:running, {index, child_node}, ctx}
          {^go_on, _, ctx} -> sequence(children, {index + 1, nil}, ctx, go_on)
          {status, _, ctx} -> {status, nil, ctx}
        end
    end
  end

  defp each(_each, {[], _}, ctx), do: {:success, nil, ctx}

  defp each({:each, _, as, child} = each, {[item | rest] = items, child_node}, ctx) do
    ctx = if child_node == nil, do: store(ctx, as, item), else: ctx

    case tick(child, child_node, ctx) do
      {:running, child_node, ctx} -> {:running, {items, child_node}, ctx}
      {:success, _, ctx} -> each(each, {rest, nil}, ctx)
      {:failure, _, ctx} -> {:failure, nil, ctx}
    end
  end

  defp wait(until, ctx),
    do: if(ctx.tick >= until, do: {:success, nil, ctx}, else: {:running, until, ctx})

  # 发出命令（新 id）；draining 里还有技能时不启动新的技能叶子，保持原状下次再试。
  defp start(command, leaf, ctx) do
    kind = kind(command)

    if kind == :skill and Enum.any?(ctx.draining, fn {_, k} -> k == :skill end) do
      {:running, leaf, ctx}
    else
      id = ctx.next_id

      {:running, %{id: id, command: command},
       %{
         ctx
         | commands: [Map.put(command, :id, id) | ctx.commands],
           next_id: id + 1,
           pending: Map.put(ctx.pending, id, kind)
       }}
    end
  end

  defp kind(%{verb: :skill}), do: :skill
  defp kind(%{verb: verb}) when verb in [:move_to, :stop], do: :move
  defp kind(_), do: :world

  defp failed(name, reason, ctx),
    do: {:failure, nil, store(ctx, :last_failure, %{act: name, reason: reason})}

  defp store(ctx, nil, _value), do: ctx
  defp store(ctx, key, value), do: %{ctx | blackboard: Map.put(ctx.blackboard, key, value)}

  defp log(tag, context, ctx) do
    failure = Map.get(ctx.blackboard, :last_failure, %{})
    extra = if context, do: " context=#{inspect(Map.get(ctx.blackboard, context))}", else: ""

    Logger.info(
      "#{tag} entity=#{ctx.observation.self.entity_id} act=#{failure[:act]} reason=#{text(failure[:reason])}#{extra}"
    )
  end

  defp text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp text(reason), do: inspect(reason)

  # —— 构造期校验 ——

  defp check!({kind, children}, names, profile) when kind in [:seq, :sel] and is_list(children),
    do: Enum.each(children, &check!(&1, names, profile))

  defp check!({:act, name, args}, names, profile), do: check!({:act, name, args, []}, names, profile)

  defp check!({:act, name, args, opts}, names, profile) when is_list(opts) do
    unless MapSet.member?(names, name),
      do: raise(ArgumentError, "behaviour tree act #{inspect(name)} is not an ability of this profile")

    cond do
      is_function(args, 1) ->
        :ok

      is_map(args) ->
        case Abilities.command(name, args, 0, profile) do
          %{verb: :invalid_tool_arguments} ->
            raise ArgumentError, "behaviour tree act #{inspect(name)} has invalid arguments #{inspect(args)}"

          _ ->
            :ok
        end

      true ->
        raise ArgumentError, "behaviour tree act #{inspect(name)} arguments must be a map or a 1-arity function"
    end
  end

  defp check!({:cond, fun}, _, _) when is_function(fun, 2), do: :ok

  defp check!({:wait, n}, _, _) when (is_integer(n) and n >= 0) or is_function(n, 1), do: :ok

  defp check!({:repeat, n, child}, names, profile)
       when (is_integer(n) and n > 0) or n == :forever,
       do: check!(child, names, profile)

  defp check!({:each, key, as, child}, names, profile) when is_atom(key) and is_atom(as),
    do: check!(child, names, profile)

  defp check!({:succeed, child, opts}, names, profile) when is_list(opts),
    do: check!(child, names, profile)

  defp check!({:fail, child}, names, profile), do: check!(child, names, profile)

  defp check!(node, _, _), do: raise(ArgumentError, "unknown behaviour tree node #{inspect(node)}")
end
