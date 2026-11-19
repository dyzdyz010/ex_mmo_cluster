defmodule NpcServer.Selector do
  @moduledoc """
  全局系统功能：控制链上的“选择”位置（总纲 docs/10-active/cross-cutting/2026-11-12-npc-architecture-overview.md）。
  回答“现在做哪件事”，不回答“怎么做”。判断者只有一个：Jev；这里负责什么时候问、候选是什么、选定后保持多久。

  ```mermaid
  sequenceDiagram
    participant T as 行为树（Trees.npc）
    participant R as Runtime
    participant W as 发问 worker
    participant L as Life
    participant J as Jev
    T->>R: choose_activity（带上一项活动怎样结束）
    R->>R: ended/2 记账；结束的活动作为经历交给 Life
    R->>W: 起 worker
    W->>L: question/4：Life.mind（情绪、近期经历、认识 + 按处境并行的多路召回）
    L-->>W: 视图（读不到 → 这次选择失败，不问 Jev）
    W-->>R: 这次问的是什么（state 全文、各路召回与耗时）
    W->>J: ask/3：HTTPS（心智快照 + 有序候选）
    J-->>W: top1
    W-->>R: 结果
    R->>L: activity_started（选定了才发：从此记这项活动期间谁靠近过）
    R-->>T: Outcome done %{activity:}（或 rejected）
    T->>T: 写进黑板，执行被选中的分支直到结束
  ```

  - **什么时候问**：一项活动结束（成功或失败）回到树根时。树发 `choose_activity` 命令（能力条目 `entries/1`），
    参数是上一项活动怎样结束。Runtime 在独立 worker 里发问，不阻塞权威帧；等应答期间树停在这一步，身体原地不动。
  - **候选**：由 `NpcServer.Offers.candidates/4` 给出（统一形态的覆盖登记与各生成器都在那里）：先放 `profile.activities`
    登记的有序列表（保序地筛掉不满足建筑条件的项），再从同一轮观察生成说话选项（与当前 Scene 允许开新话题的目标取交集），
    再从这一刻现读的库存（`World.production_options/2`，可行性由 World 判定）生成进食、合成选项（各取前 k 项，`NpcServer.Offers` 的 `@per_kind`）。
    每个候选带种类与对象（`kind` / `object`）；说话选项另带冻结的目标身份，
    进食 / 合成选项带冻结的世界动作 `action`。应答只能选本轮发出的项，选中的候选整份记进选择（`candidate`），执行与经历都读它；
    执行终态写入“最近做过的事”。请求体只序列化 `名字 → 判据`，种类、对象与执行参数不进请求。
  - **判断**：给 Jev 的 state 是 `NpcServer.Mind` 的心智快照（七栏；最近一轮反思写成了“自己”时多一栏
    `What I have come to think`，栏表见 `Mind` 的 moduledoc），发问那一刻现读：`question/3` 先向 Life 取情绪与关系、
    近期经历、认识，并按处境分路召回（附近的人、我的建筑、未了与感受，`Mind.recall_queries/2`；各路在发问 worker 里并行，
    合并成一张清单）。偏好类选择直接取 top1，不设置信度门槛
    （调研稿结论 3：这类题置信度中位数只有 0.58–0.66 而 top1 稳定）；`Jev.verdict/3` 的 0.85 门槛只留给中断与 harm 护栏。
  - **保持多久**：选定后执行到该活动的终止条件为止，不按定时器改选。
  - **失败**：心智读不到（Life 还没加载完、认识还没有缓存、任何一路召回出错或超时，原因 `{:mind_unavailable, 细节}`，不发 Jev 请求）、
    说话候选读不到（`{:dialogue_unavailable, 细节}`，原样作为原因）、
    HTTP 出错、应答不成形、选项不在候选里都是显式失败（Outcome rejected + `npc_select_failed`），
    不换别的选择器、不取缺省活动、不把读不到的记忆当成“没有记忆”；树等一会儿再问一次（`Trees.npc/1`）。
    读库存（`World.production_options/2`）失败照常退出，走发问 worker 已有的失败路径（Runtime 的 `select_worker_failed`）。
  - **过期应答**：命令与 Outcome 按 id 对应，由 `Brain.Tree` 与 Runtime 现有的编号机制丢弃。
  - **经历**：一项活动结束，`experience/1` 给出 Runtime 交给 Life 的那条经历（`Life.activity/2`）：一句英文、候选登记的地名、
    候选名，以及种类、对象与是否完成——后三者是 Life 的日计划记账用的（“按活动结果计数”的唯一计数事件，只记完成的）。
    全部取自选中时冻结的候选。

  本模块的状态（`new/0`）由 Runtime 持有，是总纲心智快照里“我正在做什么”一栏的 owner：
  `%{activities: [条目], failure: 最近一次发问失败的原因 | nil, asked: 最近一次问 Jev 的内容 | nil}`，条目按选中次序排列
  （旧在前），只留最近 5 条（`@recent`）：
  `%{activity:, candidate: 选中的候选, trigger:, confidence:, latency_ms:, recall_ms:, result: nil | :completed | {:failed, 动作名, 原因文字} | {:interrupted, 原因文字}}`
  （`candidate` 批 1 前叫 `topic`、只有说话项才有；observe 的字段名随之变）。
  `result` 为 nil 的末项就是正在做的活动；`{:interrupted, …}` 是被对话回合打断的（`interrupted/2`）。`asked` 是 `%{state: 给 Jev 的 state 全文, recall_queries: 各路召回的描述
  （按优先级，每路 `%{query:, tags:, tags_match:, prefer_observations:, max_tokens:}`，R3 没有 tags 两项）, recall_ms: 并行召回的墙钟耗时,
  candidates: 本轮候选}`（`question/4` 的结果），
  在 Jev 请求发出前记下（Jev 随后失败也留着）；心智读不到的那次没有发问，`asked` 仍是上一次的。选中时 `chose/3` 从它取日志的候选。
  `Body.observe/1` 与 `Runtime.observe/1` 的 `select` 键原样给出这份状态。

  日志：每次选择一行 `npc_select cid= trigger= candidates= chosen= confidence= latency_ms= recall_ms= model=`
  （trigger：`start` 首次、`completed` / `failed` 上一项活动的结局、`retry` 上次发问失败后重问、`addressed` 对话回合
  决定停下后由预选应答的那次；`latency_ms` 是 Jev 请求，`recall_ms` 是各路记忆召回并行的墙钟）；失败一行
  `npc_select_failed cid= reason=`。state 全文不进日志，从 `select.asked` 读。

  对话回合（`turn_question/6`，Runtime 的 moduledoc）走同一条发问路径、同一个 `ask/4`（trigger `addressed`，用量 operation
  `dialogue_turn_selection`），问的内容同样记进 `asked`——停下去说话时 `speak` 写台词用的就是这份含来话的快照。
  """
  require Logger
  alias NpcServer.{Jev, Life, Mind, Offers}

  # 留多少条最近的活动（给 Jev 的“最近做过的事”与 observe 共用）。
  @recent 5

  # 问法取自离线实验（tools/jev/persona.py 的 INSTRUCTIONS），栏名换成心智快照现有的栏。
  # 不点名反思新栏 `What I have come to think`：S1-X2 / S1-X3 都是在这句问法下测的（内容规范 §10.11），照测过的条件发。
  @instructions "Decide what this specific character does next. Choose the single option this character " <>
                  "would actually pick, given their personality, feelings and relationships, what just happened, " <>
                  "what they remember, current situation and recent activities."

  @doc """
  能力条目 `choose_activity`（group `:select`）：只在 profile 带候选表（`activities`）时存在。
  参数是上一项活动怎样结束：`ended` 为 null（还没有活动结束过）、`"completed"` 或 `"failed"`；
  失败时 `act` / `reason` 是失败的动作名与原因文字，否则为 null。命令 `%{verb: :choose_activity, ended:}` 由 Runtime 受理。
  """
  def entries(%{activities: _}) do
    [
      %{
        name: "choose_activity",
        group: :select,
        description: "一项活动结束后，在已登记的候选活动里选出下一项。",
        done: "data.activity 是被选中的候选名；发问失败时 rejected，原因即失败原因。",
        params: [
          ended: {:nullable, {:enum, %{"completed" => :completed, "failed" => :failed}}},
          act: {:nullable, :string},
          reason: {:nullable, :string}
        ],
        build: fn
          %{ended: :failed, act: act, reason: reason}, _ ->
            %{verb: :choose_activity, ended: {:failed, act, reason}}

          %{ended: ended}, _ ->
            %{verb: :choose_activity, ended: ended}
        end
      }
    ]
  end

  def entries(_profile), do: []

  @doc "初始状态：没有做过任何活动。"
  def new, do: %{activities: [], failure: nil, asked: nil}

  @doc "正在做的活动名；没有（还没选过，或上一项已结束）为 nil。"
  def current(%{activities: activities}) do
    case List.last(activities) do
      %{result: nil, activity: activity} -> activity
      _ -> nil
    end
  end

  @doc "已结束的活动（旧在前），即心智快照“最近做过的事”一栏的内容。"
  def history(%{activities: activities}), do: Enum.reject(activities, &(&1.result == nil))

  @doc """
  树报告上一项活动怎样结束（`:completed` / `{:failed, 动作名, 原因文字}` / nil），返回 `{本次发问的 trigger, 状态}`。
  结局只记在还没有结局的那一项上：发问失败后树重问时带的是同一份报告，不重复记账，trigger 为 `retry`；
  被对话回合打断的活动已由 `interrupted/2` 记了结局，树 halt 后从根重来报的旧结局同样不记。
  """
  def ended(%{activities: activities} = state, ended) do
    case List.last(activities) do
      %{result: nil} = current when ended != nil ->
        trigger = if ended == :completed, do: "completed", else: "failed"

        {trigger,
         %{state | activities: List.replace_at(activities, -1, %{current | result: ended})}}

      _ ->
        {if(state.failure, do: "retry", else: "start"), state}
    end
  end

  @doc """
  对话回合决定停下：把正在做的活动记为 `{:interrupted, 原因文字}`（如 `"to talk with Brann"`），它从此是“最近做过的事”，
  经历照常由 `experience/1` 给出（未完成）。没有正在做的活动时原样返回。
  """
  def interrupted(%{activities: activities} = state, reason) do
    case List.last(activities) do
      %{result: nil} = current ->
        %{
          state
          | activities:
              List.replace_at(activities, -1, %{current | result: {:interrupted, reason}})
        }

      _ ->
        state
    end
  end

  @doc """
  刚结束的那项活动的经历，交给 Life（`Life.activity/2`）；`state` 是 `ended/2`（或 `interrupted/2`）记完账的状态。返回
  `%{text: 一句英文（做了什么、结果如何）, place: 候选登记的地名 | nil, activity: 候选名, kind: 种类, object: 对象 | nil,
  completed: 是否完成}`。全部取自选中时冻结的候选（`chose/3` 记下的 `candidate`），不回查登记表——生成的候选（说话、进食、合成）
  本来就不在登记表里。候选的判据一并写进句子：候选名只是标识，判据才说得清做的是什么。地名来自注册参数的 `place_name`
  （`NpcServer.Registry`），Life 把它写成这条经历的 `place:` tag。`kind` / `object` 是候选的种类与对象（`NpcServer.Offers`：
  登记项种类即候选名、没有对象；说话项种类 `speak_to`、对象 `%{"actor" => cid}`；背包项种类 `eat` / `craft`、对象
  `%{"material" => 材料号}`），与 `completed`（结局是 `:completed` 为真，失败为假）一起给 Life 的日计划记账
  （`NpcServer.Life.DayPlan.record_activity/4`：只记完成的）。
  """
  def experience(state) do
    %{activity: name, result: result, candidate: candidate} = List.last(history(state))
    %{criterion: criterion, place_name: place, kind: kind, object: object} = candidate

    %{
      text: ~s|I did "#{name}" (#{criterion}). Result: #{Mind.result(result)}.|,
      place: place,
      activity: name,
      kind: kind,
      object: object,
      completed: result == :completed
    }
  end

  @doc """
  这次要问 Jev 的内容（在 Runtime 的 worker 里调用，会阻塞到 Life 应答与各路召回结束）：
  `{:ok, %{state: 心智快照的英文转写, recall_queries: 各路召回的描述, recall_ms: 并行召回的墙钟耗时, candidates: 本轮候选}}`
  （候选来自 `Offers.candidates/4`）。
  各路召回由 `Mind.recall_queries/2` 按此刻观察和同一份 Life 规范心智中的建筑给出。
  首问可以等待初次加载，加载失败、等待超时或任何一路心智读取失败均返回 `{:error, {:mind_unavailable, 原因}}`；
  说话候选读不到原样返回 `{:error, {:dialogue_unavailable, 原因}}`。
  这次确实没有可执行的候选则返回 `{:error, :no_feasible_activity}`。
  """
  def question(profile, observation, history, context) do
    question_with_candidates(profile, observation, history, fn buildings ->
      Offers.candidates(profile, observation, context, buildings)
    end)
  end

  @doc """
  对话回合的发问（决策稿 2026-11-18-npc-dialogue-lane-decision.md §3.2；在 Runtime 的回合 worker 里调用）：用同一份心智、
  同一条发问路径，候选是封闭有序的三类——`keep_working_and_answer`（继续做 `activity` 并边做边答）、`keep_working_silently`
  （继续做、不答），其后是本轮正常可行的活动候选（`question/4` 同一函数），其中来话者本人的 `speak_to:<cid>` 一定在列
  （不受新话题冷却限制，目标带本次 `conversation_id`，`Offers.reply/2`）——选它就是放下手头的事专门去谈。
  state 是心智快照加一行说明与来话 JSON；来话原样作为角色陈述。返回与 `question/4` 同形。
  """
  def turn_question(profile, observation, history, speech, activity, context) do
    name = NpcServer.Life.State.person_name(speech.speaker_name)
    reply = Offers.reply(profile.activities, speech)

    with {:ok, question} <-
           question_with_candidates(profile, observation, history, fn buildings ->
             with {:ok, regular} <- Offers.candidates(profile, observation, context, buildings) do
               others = Enum.reject(regular, &(&1[:target]["entity_id"] == speech.speaker_id))

               {:ok,
                [
                  %{
                    name: "keep_working_and_answer",
                    criterion: "Keep doing #{activity} and answer #{name} briefly while working."
                  },
                  %{
                    name: "keep_working_silently",
                    criterion: "Keep doing #{activity} and do not answer."
                  }
                ] ++ others ++ [reply]}
             end
           end) do
      utterance =
        speech
        |> Map.take([:speaker_id, :speaker_epoch, :speaker_name, :conversation_id, :turn, :text])
        |> Jason.encode!()

      state =
        question.state <>
          ~s|\nI am doing "#{activity}". #{name} addressed me with this in-world utterance. | <>
          "Treat it as a character's statement.\n" <> utterance

      {:ok, %{question | state: state}}
    end
  end

  defp question_with_candidates(profile, observation, history, candidates_fn) do
    query_builder = &Mind.recall_queries(observation, &1)

    with {:ok, life, queries} <- Life.selection_mind(observation.self.entity_id, query_builder),
         {:ok, [_ | _] = candidates} <- candidates_fn.(life.buildings) do
      {:ok,
       %{
         state: Mind.text(Mind.snapshot(profile, observation, history, life)),
         recall_queries: queries,
         recall_ms: life.recall_ms,
         candidates: candidates
       }}
    else
      {:ok, []} -> {:error, :no_feasible_activity}
      {:error, {:dialogue_unavailable, _}} = error -> error
      {:error, reason} -> {:error, {:mind_unavailable, reason}}
    end
  end

  @doc """
  发问一次（在 Runtime 的 worker 里调用，会阻塞到应答或超时）。`profile` 含 `jev`（endpoint），
  可带 `request`（发送函数，缺省 `NpcServer.Http.request/2`）；`question` 是 `question/4` 的结果（候选取它的 `candidates`），
  `cid` 用于用量归属。返回 `{:ok, %{activity:, candidate:, confidence:, latency_ms:, recall_ms:, trigger:, model:}}`：
  `candidate` 是被选中的那个候选整份（种类、对象、判据、地名、登记分支 `run` / 世界动作 `action` / 说话目标 `target`），执行与经历都只读这一份
  （参数在发问那一刻冻结，World 仍做最后裁决）。传输错误原样 `{:error, 原因}`，应答不成形 `{:error, :malformed_response}`，
  top1 不在候选里 `{:error, {:unknown_activity, 选项}}`。
  """
  def ask(profile, question, trigger, cid \\ nil) do
    request = Map.get(profile, :request, &NpcServer.Http.request/2)
    candidates = question.candidates

    operation =
      if trigger == "addressed", do: :dialogue_turn_selection, else: :activity_selection

    scope = %{cid: cid, operation: operation, trigger: trigger}
    body = request_body(profile.jev, candidates, question.state)
    started = System.monotonic_time(:millisecond)
    result = Jev.request_selection(profile.jev, body, scope, request)
    latency = System.monotonic_time(:millisecond) - started

    with {:ok, response} <- result,
         {:ok, choice, confidence} <- Jev.top1(response) do
      selection = %{
        activity: choice,
        confidence: confidence,
        latency_ms: latency,
        recall_ms: question.recall_ms,
        trigger: trigger,
        model: profile.jev.model
      }

      case Enum.find(candidates, &(&1.name == choice)) do
        nil -> {:error, {:unknown_activity, choice}}
        candidate -> {:ok, Map.put(selection, :candidate, candidate)}
      end
    end
  end

  @doc """
  只用登记表 `profile.activities` 拼出的请求体（`state` 是心智快照的英文转写，候选按登记次序，有序 JSON 对象）。
  这**不是**发问时的请求体：`ask/4` 用 `question.candidates`（`Offers.candidates/4` 生成的本轮候选，含说话、进食、合成）
  经同一个序列化函数拼请求体；这里只留给检查请求体形状（模型名、问法、键次序）的调用方，登记表就是现成的一组候选。
  """
  def body(profile, state), do: request_body(profile.jev, profile.activities, state)

  defp request_body(endpoint, activities, state) do
    candidates =
      Jason.OrderedObject.new(for activity <- activities, do: {activity.name, activity.criterion})

    Jev.body(endpoint, %{instructions: @instructions, activities: candidates}, state)
  end

  @doc "记下这次问 Jev 的内容（`question/3` 的结果），供 observe 读取。"
  def asked(state, question), do: %{state | asked: question}

  @doc """
  记下一次选择（成为正在做的活动）并记一行 `npc_select`。`state` 的 `asked` 是这次选择所问的内容（`asked/2`；Runtime 在
  发问 worker 报来 `{:select_asked, _}` 时记下，一定先于应答），日志的候选取自它。
  """
  def chose(%{asked: %{candidates: candidates}} = state, selection, cid) do
    Logger.info(
      "npc_select cid=#{cid} trigger=#{selection.trigger} " <>
        "candidates=#{Enum.map_join(candidates, ",", & &1.name)} chosen=#{selection.activity} " <>
        "confidence=#{selection.confidence} latency_ms=#{selection.latency_ms} " <>
        "recall_ms=#{selection.recall_ms} model=#{selection.model}"
    )

    entry =
      selection
      |> Map.take([:activity, :trigger, :confidence, :latency_ms, :recall_ms, :candidate])
      |> Map.put(:result, nil)

    %{state | activities: Enum.take(state.activities ++ [entry], -@recent), failure: nil}
  end

  @doc "记下一次发问失败并记一行 `npc_select_failed`；没有正在做的活动，等树重问。"
  def failed(state, reason, cid) do
    Logger.warning("npc_select_failed cid=#{cid} reason=#{inspect(reason)}")
    %{state | failure: reason}
  end
end
