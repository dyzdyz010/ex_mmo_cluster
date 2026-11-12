defmodule NpcServer.Utility do
  @moduledoc """
  全局系统功能：NPC 活动选择器（效用打分，N1）。纯规则，不调用任何模型、不发 HTTP。
  设计与调参见 docs/10-active/cross-cutting/2026-11-10-npc-utility-selector.md。

  回答"现在该做哪件事"，不回答"怎么做"：怎么做仍由 Tree 与技能负责。两处接线，共用同一个纯函数 `choose/3`：

    * `NpcServer.Scheduler` 实现（`profile.interrupt_policy = {NpcServer.Utility, config}`）：技能运行中每次检查，
      选出的活动与正在做的不同就 `{:interrupt, 活动}`，否则 `:continue`。
    * Tree 根部守卫 `gate/3`：被中断后树从根重来，各活动子树用 `gate` 包起来，只有被选中的那个往下走。

  活动是**有序**列表（`default_activities/0`）；分数相同按列表次序取靠前者，不依赖 map 遍历。分数是普通函数：

      分数 = 时段权重(日程) + 情绪／社交加成（取自 `Life.State.behavior/3`，不重写避险规则） + 附近有人的小加成

  防抖动：正在做的活动加 `@inertia`（惯性）；"avoid" 分数达到 `@urgent` 时直接压过惯性（紧急覆盖）。
  没有单独的最短持续时间状态：Runtime 每 10 秒才检查一次技能，这就是重新打分的节拍。

  所有数值（`@inertia`、`@urgent`、各加成、默认日程）是游戏设计参数，不来自论文或实测，等埋点数据后再调。
  本版不读 balances：当前没有哪个活动的分数取决于余额（缺料由 Tree 自己去采），不为未来需要预建输入。

  时钟：服务端没有游戏日时钟。游戏时刻由墙钟推出：`rem(now_ms, day_ms)`，所有 NPC 与重启后一致。
  `day_ms` 默认 1_440_000（现实 24 分钟 = 一个游戏日，1 分钟 = 1 游戏小时）。

  config（均可省略）：`%{day_ms:, schedule:, activities:, activity_of: (skill -> 活动), clock: (-> ms)}`；
  `activity_of` 缺省把所有正在运行的技能都算作 "work"。
  """
  @behaviour NpcServer.Scheduler
  require Logger
  alias NpcServer.Life.State

  # 游戏设计参数（调参起点，不是研究结论）。
  @inertia 0.25
  @urgent 1.0
  @avoid_threat 1.5
  @avoid_cautious 0.4
  @thank_bonus 0.7
  @nearby_bonus 0.15
  @nearby_range 10.0
  @day_ms 1_440_000
  # LLM 日计划当前段的活动权重：与手写日程各段主导活动同值，情绪加成与紧急覆盖照常压过它。
  @plan_weight 0.8

  # 有序：平分时靠前者胜；avoid 在最前，紧急项优先。
  @activities ["avoid", "work", "rest", "social"]

  # 默认日程，按日内千分位切段；有序，取第一个覆盖当前时刻的段。权重是该时段对各活动的基础倾向。
  @schedule [
    {0, 250, %{"rest" => 0.8, "work" => 0.2, "social" => 0.1}},
    {250, 700, %{"work" => 0.8, "rest" => 0.1, "social" => 0.3}},
    {700, 850, %{"social" => 0.8, "work" => 0.3, "rest" => 0.2}},
    {850, 1000, %{"rest" => 0.8, "work" => 0.2, "social" => 0.1}}
  ]

  def default_activities, do: @activities
  def default_schedule, do: @schedule
  def inertia, do: @inertia
  def urgent, do: @urgent

  @doc """
  按分数选活动，返回 `{活动, 有序分数}`。`inputs`：`%{slot: %{活动 => 权重}, mode: Life.State.behavior 的 mode 或 nil, nearby: 布尔}`。
  `current` 是正在做的活动（没有则 nil）。紧急项（分数 ≥ `@urgent` 的 "avoid"）无视惯性；其余情况正在做的活动加 `@inertia`。
  """
  def choose(activities, inputs, current) do
    scores = Enum.map(activities, &{&1, score(&1, inputs)})

    urgent? =
      match?({"avoid", value} when value >= @urgent, List.keyfind(scores, "avoid", 0))

    chosen =
      if urgent? do
        "avoid"
      else
        {best, _} =
          Enum.max_by(scores, fn {activity, value} ->
            if activity == current, do: value + @inertia, else: value
          end)

        best
      end

    {chosen, scores}
  end

  defp score(activity, inputs) do
    base = Map.get(inputs.slot, activity, 0.0)

    case activity do
      "avoid" ->
        base + avoid_term(inputs.mode)

      "social" ->
        base + if(inputs.mode == :thank, do: @thank_bonus, else: 0.0) +
          if inputs.nearby, do: @nearby_bonus, else: 0.0

      _ ->
        base
    end
  end

  defp avoid_term(:avoid), do: @avoid_threat
  defp avoid_term(:cautious), do: @avoid_cautious
  defp avoid_term(_), do: 0.0

  @doc "当前游戏时刻落在哪个日程段，返回该段的权重表；日程按千分位 `{from, to, weights}` 有序，不覆盖时返回空表。"
  def slot(schedule, day_ms, now_ms) do
    permille = div(rem(now_ms, day_ms) * 1000, day_ms)

    case Enum.find(schedule, fn {from, to, _} -> permille >= from and permille < to end) do
      {_, _, weights} -> weights
      nil -> %{}
    end
  end

  @doc """
  从 Observation 取 `choose/3` 的输入。情绪与社交 mode 一律来自 `Life.State.behavior/3`；没有 Life 的 NPC mode 为 nil。
  时段权重：当日有被接受的 LLM 日计划（`observation.plan`，见 `NpcServer.DayPlan`）就用计划当前段——该段活动权重
  `@plan_weight`、其余 0，`source: :llm`；否则用手写日程，`source: :authored`（批准的显式缺省，见决策稿 N2）。
  """
  def inputs(observation, config) do
    now_ms = now_ms(observation, config)

    mode =
      case observation do
        %{life: %{state: canonical, now_ms: life_now}} ->
          State.behavior(canonical, observation, life_now).mode

        _ ->
          nil
      end

    {slot, source} =
      case planned(observation, config) do
        {_, _, activity, _} ->
          {%{activity => @plan_weight}, :llm}

        nil ->
          {slot(Map.get(config, :schedule, @schedule), Map.get(config, :day_ms, @day_ms), now_ms),
           :authored}
      end

    %{slot: slot, mode: mode, nearby: nearby?(observation), source: source}
  end

  @doc "当日 LLM 日计划里覆盖当前时刻的段 `{from, to, activity, target}`；计划不是今天的或没有计划时 nil。"
  def planned(%{plan: %{day: day, slots: slots}} = observation, config) do
    day_ms = Map.get(config, :day_ms, @day_ms)
    now_ms = now_ms(observation, config)

    if div(now_ms, day_ms) == day do
      permille = div(rem(now_ms, day_ms) * 1000, day_ms)
      Enum.find(slots, fn {from, to, _, _} -> permille >= from and permille < to end)
    end
  end

  def planned(_observation, _config), do: nil

  defp now_ms(%{life: %{now_ms: now}}, _config), do: now

  defp now_ms(_observation, config),
    do: Map.get(config, :clock, fn -> System.system_time(:millisecond) end).()

  defp nearby?(%{self: %{entity_id: me, position: origin}, entities: entities}) do
    Enum.any?(entities, fn %{entity_id: id, position: position} ->
      id != me and distance(origin, position) <= @nearby_range
    end)
  end

  defp nearby?(_), do: false

  defp distance({x, y, z}, {ex, ey, ez}),
    do: :math.sqrt((x - ex) ** 2 + (y - ey) ** 2 + (z - ez) ** 2)

  @impl true
  def decide(%{skill: skill, observation: observation}, config) do
    current = Map.get(config, :activity_of, fn _ -> "work" end).(skill)
    inputs = inputs(observation, config)
    {chosen, scores} = choose(Map.get(config, :activities, @activities), inputs, current)
    log(observation, current, chosen, scores, inputs.source)
    if chosen == current, do: :continue, else: {:interrupt, chosen}
  end

  @doc """
  Tree 根部守卫：`{:seq, [{:cond, 是否选中 activity}, subtree]}`。被中断的树从根重来，没有正在做的活动，所以不加惯性。
  各活动的子树按 `activities` 的次序放进根 `sel`，同分取靠前者与 `choose/3` 一致。
  """
  def gate(activity, subtree, config) do
    {:seq,
     [
       {:cond,
        fn _blackboard, observation ->
          inputs = inputs(observation, config)
          {chosen, scores} = choose(Map.get(config, :activities, @activities), inputs, nil)

          # 只由被选中的那个分支记一行，避免根 sel 里每个守卫各记一次。
          if chosen == activity, do: log(observation, nil, chosen, scores, inputs.source)
          chosen == activity
        end},
       subtree
     ]}
  end

  defp log(observation, current, chosen, scores, source) do
    Logger.info(
      "npc_utility_decision cid=#{get_in(observation, [:self, :entity_id])} current=#{current || "none"} " <>
        "chosen=#{chosen} switched=#{current != nil and chosen != current} plan_source=#{source} " <>
        "scores=#{Enum.map_join(scores, ",", fn {a, v} -> "#{a}:#{Float.round(v * 1.0, 2)}" end)}"
    )
  end
end
