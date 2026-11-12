defmodule NpcServer.Selector do
  @moduledoc """
  全局系统功能：控制链上的“选择”位置（总纲 docs/10-active/cross-cutting/2026-11-12-npc-architecture-overview.md）。
  回答“现在做哪件事”，不回答“怎么做”。判断者只有一个：Jev；这里负责什么时候问、候选是什么、选定后保持多久。

  ```mermaid
  sequenceDiagram
    participant T as 行为树（Trees.npc）
    participant R as Runtime
    participant W as 发问 worker
    participant J as Jev
    T->>R: choose_activity（带上一项活动怎样结束）
    R->>R: ended/2 记账
    R->>W: ask/4（心智快照 + 有序候选）
    W->>J: HTTPS
    J-->>W: top1
    W-->>R: 结果
    R-->>T: Outcome done %{activity:}（或 rejected）
    T->>T: 写进黑板，执行被选中的分支直到结束
  ```

  - **什么时候问**：一项活动结束（成功或失败）回到树根时。树发 `choose_activity` 命令（能力条目 `entries/1`），
    参数是上一项活动怎样结束。Runtime 在独立 worker 里发问，不阻塞权威帧；等应答期间树停在这一步，身体原地不动。
  - **候选**：`profile.activities`，有序列表 `[%{name:, criterion:, run:}]`（注册参数给出，见 `NpcServer.Registry`）。
    次序由列表承载，原样进请求体。当前没有可行性过滤：现有 Observation 里没有能判定某个候选做不成的依据
    （材料单、地块占用都要另查 World），做不成的候选由执行失败后写进“最近做过的事”来体现。
  - **判断**：给 Jev 的 state 是 `NpcServer.Mind` 的心智快照。偏好类选择直接取 top1，不设置信度门槛
    （调研稿结论 3：这类题置信度中位数只有 0.58–0.66 而 top1 稳定）；`Jev.verdict/3` 的 0.85 门槛只留给中断与 harm 护栏。
  - **保持多久**：选定后执行到该活动的终止条件为止，不按定时器改选。
  - **失败**：HTTP 出错、应答不成形、选项不在候选里都是显式失败（Outcome rejected + `npc_select_failed`），
    不换别的选择器、不取缺省活动；树等一会儿再问一次（`Trees.npc/1`）。
  - **过期应答**：命令与 Outcome 按 id 对应，由 `Brain.Tree` 与 Runtime 现有的编号机制丢弃。

  本模块的状态（`new/0`）由 Runtime 持有，是总纲心智快照里“我正在做什么”一栏的 owner：
  `%{activities: [条目], failure: 最近一次发问失败的原因 | nil}`，条目按选中次序排列（旧在前），只留最近
  5 条（`@recent`）：`%{activity:, trigger:, confidence:, latency_ms:, result: nil | :completed | {:failed, 动作名, 原因文字}}`。
  `result` 为 nil 的末项就是正在做的活动。`Body.observe/1` 与 `Runtime.observe/1` 的 `select` 键原样给出这份状态。

  日志：每次选择一行 `npc_select cid= trigger= candidates= chosen= confidence= latency_ms= model=`
  （trigger：`start` 首次、`completed` / `failed` 上一项活动的结局、`retry` 上次发问失败后重问）；
  失败一行 `npc_select_failed cid= reason=`。
  """
  require Logger
  alias NpcServer.{Jev, Mind}

  # 留多少条最近的活动（给 Jev 的“最近做过的事”与 observe 共用）。
  @recent 5

  # 问法取自离线实验（tools/jev/persona.py 的 INSTRUCTIONS），栏名换成心智快照现有的栏。
  @instructions "Decide what this specific character does next. Choose the single option this character " <>
                  "would actually pick, given their personality, current situation and recent activities."

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
  def new, do: %{activities: [], failure: nil}

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
  结局只记在还没有结局的那一项上：发问失败后树重问时带的是同一份报告，不重复记账，trigger 为 `retry`。
  """
  def ended(%{activities: activities} = state, ended) do
    case List.last(activities) do
      %{result: nil} = current when ended != nil ->
        trigger = if ended == :completed, do: "completed", else: "failed"
        {trigger, %{state | activities: List.replace_at(activities, -1, %{current | result: ended})}}

      _ ->
        {if(state.failure, do: "retry", else: "start"), state}
    end
  end

  @doc """
  发问一次（在 Runtime 的 worker 里调用，会阻塞到应答或超时）。`profile` 含 `who`、`persona`、`activities`、`jev`
  （endpoint），可带 `request`（发送函数，缺省 `NpcServer.Http.request/2`）。
  返回 `{:ok, %{activity:, confidence:, latency_ms:, trigger:, model:}}`；传输错误原样 `{:error, 原因}`，
  应答不成形 `{:error, :malformed_response}`，top1 不在候选里 `{:error, {:unknown_activity, 选项}}`。
  """
  def ask(profile, observation, history, trigger) do
    request = Map.get(profile, :request, &NpcServer.Http.request/2)
    started = System.monotonic_time(:millisecond)
    result = request.(profile.jev, body(profile, observation, history))
    latency = System.monotonic_time(:millisecond) - started

    with {:ok, response} <- result,
         {:ok, choice, confidence} <- Jev.top1(response) do
      if Enum.any?(profile.activities, &(&1.name == choice)) do
        {:ok,
         %{
           activity: choice,
           confidence: confidence,
           latency_ms: latency,
           trigger: trigger,
           model: profile.jev.model
         }}
      else
        {:error, {:unknown_activity, choice}}
      end
    end
  end

  @doc "请求体：state 是心智快照的英文转写，候选按 `profile.activities` 的次序（有序 JSON 对象）。"
  def body(profile, observation, history) do
    candidates =
      Jason.OrderedObject.new(for activity <- profile.activities, do: {activity.name, activity.criterion})

    Jev.body(
      profile.jev,
      %{instructions: @instructions, activities: candidates},
      Mind.text(Mind.snapshot(profile, observation, history))
    )
  end

  @doc "记下一次选择（成为正在做的活动）并记一行 `npc_select`。"
  def chose(state, selection, profile, cid) do
    Logger.info(
      "npc_select cid=#{cid} trigger=#{selection.trigger} " <>
        "candidates=#{Enum.map_join(profile.activities, ",", & &1.name)} chosen=#{selection.activity} " <>
        "confidence=#{selection.confidence} latency_ms=#{selection.latency_ms} model=#{selection.model}"
    )

    entry = selection |> Map.take([:activity, :trigger, :confidence, :latency_ms]) |> Map.put(:result, nil)
    %{state | activities: Enum.take(state.activities ++ [entry], -@recent), failure: nil}
  end

  @doc "记下一次发问失败并记一行 `npc_select_failed`；没有正在做的活动，等树重问。"
  def failed(state, reason, cid) do
    Logger.warning("npc_select_failed cid=#{cid} reason=#{inspect(reason)}")
    %{state | failure: reason}
  end
end
