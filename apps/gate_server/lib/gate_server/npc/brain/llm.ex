defmodule GateServer.Npc.Brain.Llm do
  @moduledoc """
  全局系统功能：LLM 决策后端（OpenAI Responses 线格式）。回调只把事件转给自己的进程，立刻返回；
  该进程在“没有在途命令且有新情况”时问一次模型，把模型的工具调用译成命令，用 `Body.command/2` 投回。
  每次请求无状态：目标 + 当前 Observation + 最近的 Outcome + 持久化经历。模型的输出是外部输入：
  工具表是 `GateServer.Npc.Abilities.tools(profile)`（strict，按 `profile.groups` 裁剪）加本地的 `wait`；
  译码是 `Responses.function_calls/1` → `wait` 本地处理 → `Abilities.command/4`。解析失败、形状不对或未知工具在本地
  回报拒绝（`invalid_tool_arguments` / `unknown_tool`，附原调用），不发给 Body、也不让进程崩溃；合法性由 Body 与权威裁决。
  本模块不保存“最近一次 probe / inspect”之类的隐式目标：`use_tool` / `dismantle` / `detach` / `cast_spell`（g0–g2）的
  target 是模型从 probe_toward 结果或 inspect 行里原样抄来的显式句柄。
  请求之间模型看不到自己上一次调用了什么，所以给它看的每条 Outcome 都附上当初那次调用（`command`）：
  只有 `{id, verb, status}` 时模型对不上“哪一格放好了”，实测会原地反复 look。
  `remember` / `recall` / `search_memory` 通过 NpcMemory 保存、读取与搜索长期记忆；每轮现读近期与相关内容。

  “有新情况”= 有了新 Outcome、听到有人说话、`wait` 到期，或有实体走进身边 6 米（离开 8 米才算走远）。
  询问节流：两次询问至少隔 1 秒；应答没有工具调用或请求失败时按 1、2、4…60 秒退避，拿到工具调用即清零；
  每个 NPC 任意连续一小时内最多 `max_requests_per_hour` 次（缺省 600，滑动窗口），用完记一条日志，等最早那次滑出一小时。

  profile:
      %{goal: "自然语言目标", tools: %{tool_id => "用途"},   # 这个 NPC 带着的工具；模型只能从中选
        endpoint: %{url:, key:, model:, effort: 可选（思考强度，接口认的 "low" / "medium" / "high" 等，缺省 "low"）, cacertfile: 可选},
        groups: 可选（能力组，缺省全部；见 Abilities），max_requests_per_hour: 可选,
        spells: 可选（作者法术带 %{名字 => 程序字节}，非空时投影 cast_spell / cancel_cast；见 Abilities）}

  skills 是技能名到配置的 map；技能和记忆命令交给 Runtime，LLM 只等待最终 Outcome。
  Runtime 拥有可选中断策略、worker 与停止确认；本模块只拥有模型请求、工具解析和模型上下文。
  """
  @behaviour GateServer.Npc.Brain
  require Logger
  alias GateServer.Npc.{Abilities, Memory, Context, Perception, Responses}
  alias SceneServer.Movement.Player

  @history 8
  # 两次请求的最小间隔（毫秒）：连续被拒时不空转打接口。
  @min_gap_ms 1_000
  # 无工具调用或请求失败时的退避上限（毫秒）。
  @max_gap_ms 60_000
  # 每个 NPC 每小时询问上限的缺省值：曾两次出现模型原地空转、持续花费额度。
  @max_requests_per_hour 600
  @hour_ms 3_600_000
  # 实体走进这个距离（米）叫醒大脑；离开 @forget_m 才算走远，边界上来回不反复叫醒。
  @notice_m 6.0
  @forget_m 8.0
  # wait 的秒数范围（夹住模型给的值）：说明与到期计时共用。上限 1 小时：目标已完成的住民原先每 5 分钟（旧上限 300 s）
  # 被问一次，长期空闲约每小时 12 次请求（2026-10-08 机制实跑 run02）；有人走近、说话或有新 Outcome 时仍提前询问。
  @min_wait_s 1
  @max_wait_s 3600

  @wait %{
    type: "function",
    name: "wait",
    description:
      "什么都不做，seconds 秒后再被询问（#{@min_wait_s}–#{@max_wait_s}）。目标已完成或暂时无事可做时用它；已经无事可做就等久一点（每次询问都要花费）。" <>
        "有人走到身边 #{@notice_m} 米内或对你说话时会提前询问。",
    parameters: %{
      type: "object",
      properties: %{seconds: %{type: "number"}},
      required: ["seconds"],
      additionalProperties: false
    },
    strict: true
  }

  defp tools(profile), do: Abilities.tools(profile) ++ [@wait]

  @impl true
  def init(profile) do
    body = self()
    spawn_link(fn -> loop(start(profile, body)) end)
  end

  @impl true
  def handle_event(event, pid) do
    send(pid, event)
    {[], pid}
  end

  @doc """
  把一次 Responses 应答里的工具调用按出现顺序译成命令，id 从 `next_id` 起递增。
  `wait` 在本 adapter 内处理；其余交 `Abilities.command/4`：参数不是 JSON 对象或形状不对 →
  `%{verb: :invalid_tool_arguments}`，没有这个工具（含被 groups 裁掉的）→ `%{verb: :unknown_tool}`，这两种不发给 Body。
  """
  def commands(response, next_id, profile) do
    response
    |> Responses.function_calls()
    |> Enum.with_index(next_id)
    |> Enum.map(fn {call, id} -> command(call, id, profile) end)
  end

  defp command(%{name: name, arguments: {:error, reason}}, id, _),
    do: %{id: id, verb: reason, tool: name}

  defp command(%{name: "wait", arguments: {:ok, args}}, id, _),
    do: %{id: id, verb: :wait, seconds: args["seconds"]}

  defp command(%{name: name, arguments: {:ok, args}}, id, profile),
    do: Abilities.command(name, args, id, profile)

  @doc "一次应答里的工具调用原样（id => %{tool:, args:}），编号方式与 `commands/3` 相同；Outcome 回来时附给模型看。"
  def calls(response, next_id) do
    for {call, id} <- response |> Responses.function_calls() |> Enum.with_index(next_id),
        into: %{} do
      args =
        case call.arguments do
          {:ok, args} -> args
          {:error, reason} -> reason
        end

      {id, %{tool: call.name, args: args}}
    end
  end

  defp start(profile, body) do
    Process.flag(:trap_exit, true)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    now = System.monotonic_time(:millisecond)

    %{
      body: body,
      profile: profile,
      memory: Map.get(profile, :memory, DataService.NpcMemory),
      request: Map.get(profile, :request, &GateServer.Npc.Http.request/2),
      observation: nil,
      outcomes: [],
      # 发出去还没有 Outcome 的调用：id => %{tool:, args:}。
      calls: %{},
      # 身边（@notice_m 内）的实体 id；有新的走近就叫醒。
      nearby: MapSet.new(),
      dirty: true,
      asking: false,
      request_pid: nil,
      # 连续“没有可用应答”的次数，决定退避间隔。
      failures: 0,
      # monotonic_time 可以为负，不能用 0 当“很久以前”。
      asked_ms: now - @min_gap_ms,
      # 最近一小时内各次询问的时刻（新在前），滑动窗口计额度。
      asks: [],
      budget_logged: false,
      next_id: 1
    }
  end

  defp loop(state) do
    state =
      receive do
        {:observation, observation} ->
          nearby = nearby(observation, state.nearby)

          %{
            state
            | observation: observation,
              nearby: nearby,
              dirty: state.dirty or not MapSet.subset?(nearby, state.nearby)
          }

        {:outcome, outcome} ->
          record_outcome(state, outcome)

        {:heard, _message} ->
          %{state | dirty: true}

        {:EXIT, body, _reason} when body == state.body ->
          exit(:shutdown)

        {:EXIT, pid, reason} when pid == state.request_pid and reason != :normal ->
          exit(reason)

        {:EXIT, _pid, _reason} ->
          state

        {:answer, {:ok, response}} ->
          answer(state, response)

        :wake ->
          %{state | dirty: true}

        {:answer, {:error, reason}} ->
          Logger.warning(
            "npc_llm_request_failed reason=#{inspect(reason)} failures=#{state.failures + 1}"
          )

          %{state | asking: false, request_pid: nil, dirty: true, failures: state.failures + 1}
      end

    loop(ask(state))
  end

  defp answer(state, response) do
    all = commands(response, state.next_id, state.profile)
    {waits, rest} = Enum.split_with(all, &(&1.verb == :wait))

    {local, commands} =
      Enum.split_with(rest, &(&1.verb in [:unknown_tool, :invalid_tool_arguments]))

    # 每个列表最多打 64 项：创世 fill_box 一次可展开到 4096 格，全量打印一行约 100 KB。
    Logger.info("npc_llm_decision #{inspect(all, limit: 64)}")
    for command <- commands, do: GateServer.Npc.Body.command(state.body, command)

    # 每次询问都要花钱：模型说等多久就挂起多久（夹在 @min_wait_s–@max_wait_s 秒），到点再标记有新情况。
    for %{seconds: seconds} <- waits,
        is_number(seconds),
        do:
          Process.send_after(
            self(),
            :wake,
            round(min(@max_wait_s, max(@min_wait_s, seconds)) * 1_000)
          )

    # 没有任何工具调用（如 incomplete、代理只回了文本）：不会有 Outcome 来叫醒，必须自己按退避重问。
    if all == [] do
      Logger.warning(
        "npc_llm_no_tool_call status=#{inspect(response["status"])} failures=#{state.failures + 1}"
      )
    end

    sent = Map.take(calls(response, state.next_id), Enum.map(commands ++ local, & &1.id))

    state = %{
      state
      | asking: false,
        request_pid: nil,
        calls: Map.merge(state.calls, sent),
        next_id: state.next_id + length(all),
        dirty: all == [],
        failures: if(all == [], do: state.failures + 1, else: 0)
    }

    # 解析失败与未知工具不经 Body，直接作为被拒绝的 Outcome 给模型看（附原调用）。
    Enum.reduce(local, state, fn %{id: id, verb: reason}, state ->
      record_outcome(state, %{id: id, verb: reason, status: :rejected, reason: reason, data: nil})
    end)
  end

  defp nearby(%{self: %{position: {x, y, z}}, entities: entities}, previous) do
    for %{entity_id: id, position: {ex, ey, ez}} <- entities,
        d = :math.sqrt((ex - x) * (ex - x) + (ey - y) * (ey - y) + (ez - z) * (ez - z)),
        d <= @notice_m or (d <= @forget_m and MapSet.member?(previous, id)),
        into: MapSet.new(),
        do: id
  end

  defp nearby(_, previous), do: previous

  defp record_outcome(state, outcome) do
    position = state.observation && state.observation.self.position
    {call, calls} = Map.pop(state.calls, outcome.id)
    outcome = if call, do: Map.put(outcome, :command, call), else: outcome

    %{
      state
      | calls: calls,
        dirty: true,
        outcomes: Enum.take(Perception.project(outcome, state.outcomes, position), @history)
    }
  end

  # 有新情况、没有在途命令、没有在途请求、过了（退避后的）间隔、且本小时还有额度，才问一次。
  defp ask(
         %{dirty: true, asking: false, calls: calls, observation: %{pending: []} = observation} =
           state
       )
       when map_size(calls) == 0 do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.profile, :max_requests_per_hour, @max_requests_per_hour)
    asks = recent_asks(state.asks, now)
    state = if length(asks) < limit, do: %{state | asks: asks, budget_logged: false}, else: %{state | asks: asks}

    cond do
      now - state.asked_ms < gap(state.failures) ->
        state

      length(asks) >= limit ->
        unless state.budget_logged,
          do:
            Logger.warning(
              "npc_llm_budget_exhausted cid=#{observation.self.entity_id} limit_per_hour=#{limit}"
            )

        %{state | budget_logged: true}

      true ->
        owner = self()

        query =
          state.profile.goal <>
            " " <> inspect(Enum.take(state.outcomes, 1), limit: 20, printable_limit: 300)

        experiences = Memory.context(state.memory, observation.self.entity_id, query)
        body = body(state.profile, observation, state.outcomes, experiences)

        pid =
          spawn_link(fn ->
            send(owner, {:answer, state.request.(state.profile.endpoint, body)})
          end)

        %{
          state
          | dirty: false,
            asking: true,
            request_pid: pid,
            asked_ms: now,
            asks: [now | asks]
        }
    end
  end

  defp ask(state), do: state

  defp gap(failures), do: min(@max_gap_ms, @min_gap_ms * Integer.pow(2, failures))

  @doc """
  滑动窗口：只留 `now` 之前一小时内的询问时刻（毫秒，新在前）。额度按它的长度判：任意连续一小时都不超过
  `max_requests_per_hour`。原先是从启动起每满一小时清零的固定窗口，跨窗口边界的一小时里最多可到两倍额度
  （2026-10-08 run05：过去一小时 26 次，而额度是 20）。
  """
  def recent_asks(asks, now), do: Enum.take_while(asks, &(now - &1 < @hour_ms))

  @doc "一次请求体：目标、当前 Observation、最近 Outcome（旧在前），要求恰好一次工具调用。"
  def body(profile, observation, outcomes, experiences \\ []) do
    %{
      model: profile.endpoint.model,
      instructions: instructions(profile),
      input:
        Jason.encode!(
          %{
            goal: profile.goal,
            coordinates: Context.coordinates(),
            self: Context.plain(observation.self),
            tools: profile.tools,
            # 背包：每种材料还能放几个整格；null = 还没读过。
            balances:
              observation.balances &&
                for(
                  %{balance: balance} = b when balance > 0 <- observation.balances,
                  do: %{material: b.material, cells: balance / b.cost}
                ),
            entities: Enum.map(observation.entities, &Context.plain/1),
            outcomes: outcomes |> Enum.reverse() |> Enum.map(&Context.plain/1)
          }
          |> Map.merge(Context.plain(Map.take(observation, [:view, :targets])))
          |> Map.merge(memory_input(experiences))
        ),
      tools: tools(profile),
      tool_choice: "required",
      parallel_tool_calls: false,
      reasoning: %{effort: Map.get(profile.endpoint, :effort, "low")},
      store: false
    }
  end

  # 通用说明 + 只关乎某些工具的提示：提示点名的工具都在本次工具表里才写进去，被 groups 裁掉的工具不被点名。
  # 句柄抄写、射程见 read_catalog 等只关乎单个工具的规则写在该工具的说明里，随工具一起出现或消失。
  defp instructions(profile) do
    names = MapSet.new(Abilities.entries(profile), & &1.name)
    {_, eye, _} = Player.eye_position({0.0, 0.0, 0.0})

    for {needs, text} <- [
          {[], "你控制体素世界里的一个 NPC。每次只调用一个工具来推进目标；不要输出文字。"},
          {[], "坐标单位米，Y 向上，水平面是 X/Z。上一步的结果在 outcomes 里：status=rejected 表示权威拒绝，reason 是原因。"},
          {[], "眼睛在 self.position 上方 #{eye} 米，探测与射程都从眼睛算。"},
          {[], "观察位置和方向见 view，独立于移动和目标选择；entities 仅表示已同步，不检查视锥与遮挡。"},
          {~w(get_visible_entities), "get_visible_entities 才检查视锥与遮挡。"},
          {~w(get_aim), "get_aim 的查询范围不是技能射程。"},
          {[], "balances 是你的背包（每种 material 还能放几个整格）。"},
          {[], "entities 的 relation：#{relations()}，只表示敌我颜色，不表示能否攻击；"},
          {[], "self.body_state 的 status：#{statuses()}（死亡期间世界动作被拒），life 0–100，null 表示还没收到。"},
          {[], "记忆不是世界真值。"},
          {~w(look inspect), "每次动手前先用 look/inspect 核对当前位置与目标。"},
          {[], "experiences 是近期经历；memories 是每轮检索的相关记忆和近期笔记，带时间与来源；memory_error 表示读取失败。"},
          {~w(remember recall search_memory),
           "新获知的约定、计划、重要经验用 remember 保存或更新；recall 按键读，search_memory 按内容找，中文可换短关键词。"},
          {[], "能力以本次 tools 参数表为准。"},
          {~w(design_house build), "设计技能可自行 look/inspect 和读写记忆，发布后用 build 才会改变世界。"}
        ],
        Enum.all?(needs, &MapSet.member?(names, &1)),
        into: "",
        do: text
  end

  # relation 码取自 MmoContracts.Relation（线上同一组码）。
  defp relations,
    do:
      Enum.map_join(
        [neutral: "中立", self: "自己", own: "同属", friendly: "友好", hostile: "敌对"],
        "、",
        fn {relation, label} -> "#{MmoContracts.Relation.code(relation)} #{label}" end
      )

  # status 码取自 SceneServer.Body.status_code/1（与玩家 HUD 的 Session.BodyState 同一张表）。
  defp statuses,
    do:
      Enum.map_join(
        [alive: "存活", dying: "濒死", dead: "死亡"],
        "、",
        fn {status, label} -> "#{SceneServer.Body.status_code(status)} #{label}" end
      )

  defp memory_input(events) when is_list(events), do: %{experiences: Context.plain(events)}
  defp memory_input(%{} = context), do: Context.plain(context)
end
