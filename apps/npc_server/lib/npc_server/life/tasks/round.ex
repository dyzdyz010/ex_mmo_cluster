defmodule NpcServer.Life.Tasks.Round do
  @moduledoc """
  一次任务推进调用（任务层决策稿 `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §4 K-4）的流程：
  在 Life 的规划槽 worker 里（与每日回顾共用一个槽，`job: :advance`）串行地取材料、写一次、检查。
  规则在 `NpcServer.Life.Tasks`，提示词在 `NpcServer.Life.Tasks.Prompt`；这里只把它们按 K-0 离线测量的做法串起来。

      write/1：此刻一块 → “自己”一问的材料（两次召回、之前的想法）→ 推进系统提示词 + 用户消息 → 写一次
               → Tasks.check/3 :advance

  取材、写一次、检查、`wrote` 标记与每日回顾是同一段（`NpcServer.Life.DayPlan.Round.ask/3`），本模块只给提示词与检查方式。
  材料与回顾、K-0 实测同形：不加“任务对象是人时按 `actor:` 再召回一路”（决策稿 K-4 那一路；规划偏差 D-4，实跑后再议）。

  ## 不回头问 Life，不重问

  Life 起槽那一刻把需要的一切取齐成快照交进来（见 `write/1`），I/O 只经快照里的 Hindsight 适配器、写作函数与 World 路由。
  只写一次：写作失败或检查不过都是这一次的结局，交回 Life 落栏（`Tasks.fail/1` / `Tasks.reject/4`），不重问；下一次到点
  （过了最小间隔、任务仍在等）再推进。结果里带 `wrote`，Life 落栏时对写作之前就失败的那次退回额度（`Tasks.refund/1`）。

  日志 `npc_task cid=<cid> event=start|end task=<id> why=<waiting> …`（`end` 带结局、写成时的决定与步骤数、`wrote`、用量）；
  任务原文（`goal`、步骤的 `why`、`note`）不进日志，从 Life 的 observe 读。
  """
  require Logger
  alias NpcServer.Life.DayPlan.Round, as: PlanRound
  alias NpcServer.Life.Tasks
  alias NpcServer.Life.Tasks.Prompt

  @doc """
  推进一次。`snapshot` 由 Life 在起槽那一刻取齐，取材的几项与每日回顾相同（`NpcServer.Life.DayPlan.Round.write/1` 的
  `cid`、`now_ms`、`observation`、`recent`、`buildings`、`people`、`names`、`latest`、`adapter`、`config`、`context`、`write`、
  `character`、`vocabulary`），另有：

      day     起推进的游戏日（日志用）
      task    要推进的任务（持久行 `tasks.open` 里的一项，`waiting` 是这次为什么问）
      others  其它开着的任务（同形；用户消息里各一行）

  返回交回 Life 落栏的结果 `%{result:, checked:, elapsed_ms:, usage:, wrote:}`（形状与每日回顾相同）：`checked` 是
  `Tasks.check/3` 的 `:advance` 结果 `%{task:, steps:, cannot:, note:}`，不是 :ok 时为 nil。
  """
  def write(snapshot) do
    started = System.monotonic_time(:millisecond)
    head = "npc_task cid=#{snapshot.cid}"
    which = "task=#{snapshot.task["id"]} why=#{snapshot.task["waiting"]} day=#{snapshot.day}"

    Logger.info("#{head} event=start #{which} at_ms=#{snapshot.now_ms}")

    vocabulary = Map.new(snapshot.vocabulary, &{&1.kind, &1.objects})

    {result, checked, usage, wrote} =
      PlanRound.ask(
        snapshot,
        fn materials ->
          {Prompt.system_prompt(snapshot.character, snapshot.vocabulary),
           Prompt.user_message(materials, snapshot.task, snapshot.names, snapshot.others)}
        end,
        &Tasks.check(&1, vocabulary, :advance)
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started

    Logger.info(
      "#{head} event=end #{which} #{outcome(result, checked)} wrote=#{wrote} elapsed_ms=#{elapsed_ms} " <>
        PlanRound.usage_fields(usage)
    )

    %{result: result, checked: checked, elapsed_ms: elapsed_ms, usage: usage, wrote: wrote}
  end

  defp outcome(:ok, checked),
    do:
      "result=written verdict=#{checked.task} steps=#{length(checked.steps)} cannot=#{checked.cannot != nil}"

  defp outcome({:failed, reason}, nil), do: "result=failed reason=#{inspect(reason)}"
  defp outcome({:rejected, reason}, nil), do: "result=rejected reason=#{inspect(reason)}"
end
