defmodule NpcServer.Life.Tasks.Prompt do
  @moduledoc """
  任务推进调用的提示词拼装（任务层决策稿 `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §4 K-4；纯函数，不做 I/O）。

  推进的系统提示词与用户消息（`system_prompt/2`、`user_message/4`）：由 `NpcServer.Life.Tasks.Round`（Life 的推进槽，T-1b）调，
  K-0 离线测量（`.demo/observe/npc-task-k0-20261119/`）渲染的也是这一份。每日回顾用户消息里“开着的任务”“最近关掉的任务”两块的各行
  （`review_open_lines/2`、`review_closed_lines/1`，T-1a 起由 Life 起回顾槽时调）。措辞全部是**原创取值**，按实跑读数再调。

  ## 系统提示词

  人格卡一行 + 三样材料的说明（与日计划 S1-R8 模板逐字相同的那一段）+ 词表 + 三种决定（continue / done / drop）与
  `cannot` 的说明 + 答案格式（恰为 `task` / `steps` / `cannot` / `note` 四个键，检查在 `NpcServer.Life.Tasks.check/3` 的 `:advance`）。
  模板的填充（人格卡、词表渲染、格式行里步骤的 `"object"` 一栏）与每日回顾共用 `DayPlan.Prompt.fill_template/3`，
  本模块只有模板原文（`"object"` 默认 null，只在列了名字的种类上写名字；K-0 之后的改法）。

  ## 用户消息

  三块材料（拼法与反思、日计划共用 `NpcServer.Life.Reflection.materials_blocks/1`）之后，块间 `\\n\\n`：

      The task I am working on: <goal>\\nWhy: <why>
      What I have done for it so far:\\n- <种类 对象>: <结局>        （没有时 `What I have done for it so far: nothing yet.`）
      Steps I still meant to take:\\n- <种类 对象> — <why>          （没有待做步骤时整块不出现）
      My other open tasks:\\n<各一行，见下>                         （没有时整块不出现）
      Why I am thinking about it now: <一句>
      Decide what to do next for this task now.

  步骤与结局的写法复用：种类 + 对象用 `NpcServer.Mind.activity_label/3`（点名的人按此刻观察里的名字写，不在场只有 `actor <cid>`，
  与词表里的显示名同一套名字层），结局用 `NpcServer.Mind.result/1`（“最近做过的事”一栏与活动经历的同一写法）。
  其它开着的任务一行是 `<goal> — next: <当头步>`，没有待做步骤时 `<goal> — no steps planned`。

  ## 输入的形状（K-1 持久行里的任务，T-1 才落库）

      %{"goal", "why", "steps" => [%{"kind", "object", "why"}],
        "log" => [%{"kind", "object", "outcome" => "completed" | "failed" | "interrupted", "act", "reason"}],
        "waiting" => "failed" | "steps_done" | "stalled"}

  `waiting` 是 K-3 判出的“为什么现在问”（`NpcServer.Life.Tasks.record_step/4`、`note_news/3`、`tick/3`）：`failed`（当头步失败，偏差；
  细节在 `log` 末条）、`steps_done`（步骤用完）、`stalled`（当头步长时间没被做）、`heard`（任务里的人对我说话）、`event`（任务里的人
  对我的东西做了什么，`kind:event`）。

  ## 每日回顾的两块（各行带任务 id，模型写 `drop` 要用）

      - <id>: <goal> — next: <当头步>; last step: <种类 对象>: <结局>      （开着的；没做过步骤时 `; nothing done yet`；
                                                                         没有待做步骤时 `<goal> — no steps planned`）
      - <id>: <goal> — finished | given up | ran out of time | set aside, stuck   （最近关掉的：done / dropped / expired / stuck）

  块的标题与位置在 `NpcServer.Life.DayPlan.Prompt.user_message/2`。
  """
  alias NpcServer.Life.DayPlan.Prompt, as: PlanPrompt
  alias NpcServer.Life.Reflection
  alias NpcServer.Mind

  @system_template ~S"""
  You are this person: <character>

  You are working on something that takes several steps, and it is time to decide what to do next for it. You will be given three things. First, how things stand right now: plain facts about this moment; where they differ from what you remember, right now is what is true. Second, things you remember: what you did, what you saw, what others did to you or said to you, each with roughly how long ago it was. They are your own memories, not a file and not a report. Third, lines you wrote in your journal before: they are what you thought then, not facts, and you may have been wrong. After them comes the task: what you want to bring about and why, the steps you have taken for it and how each went, the steps you still meant to take, and why you are thinking about it now.

  Each step is one of these kinds of work:

  <activities>

  Decide one of three things. "continue": give the next one to three steps, in the order you would take them; they replace the steps you still meant to take. A step may name someone who is not here now; you take it when you get the chance. "done": what you wanted has come about. "drop": you give it up.
  If the next thing you need to do cannot be expressed with these kinds of work, say "continue" and put it under "cannot" in your own words.

  Answer with one JSON object and nothing else:
  {"task": "continue" or "done" or "drop", "steps": [{"activity": "<a name from the list>", "object": <object>, "why": "<one sentence, first person>"}], "cannot": null or {"want": "<what you need to do, in your own words>", "why": "<one sentence, first person>"}, "note": "<one sentence, first person, about how this task stands>"}

  With "done" or "drop", "steps" is empty and "cannot" is null. Stay with what you actually remember and how things stand right now. Do not add events, people, numbers or times that are not there.
  """

  @closing "Decide what to do next for this task now."

  # K-3 判出的原因 → 一句英文（原创措辞）。
  @why_now %{
    "failed" => "My last step did not work out.",
    "steps_done" => "I have taken every step I planned for it.",
    "stalled" => "For a long while I have not taken the next step.",
    "heard" => "Someone this task is about has spoken to me.",
    "event" => "Someone this task is about has done something to what is mine."
  }

  # 关掉的任务怎样关的 → 回顾里一句（原创措辞）。
  @closed_words %{
    "done" => "finished",
    "dropped" => "given up",
    "expired" => "ran out of time",
    "stuck" => "set aside, stuck"
  }

  @doc """
  系统提示词。`character` 是人格卡一行；`vocabulary` 是词表 `[%{kind:, criterion:, objects: %{显示名 => 对象}}]`
  （与每日回顾同形、同一份渲染）。
  """
  def system_prompt(character, vocabulary),
    do: PlanPrompt.fill_template(@system_template, character, vocabulary)

  @doc """
  用户消息。`materials` 与 `NpcServer.Life.Reflection.user_message/2` 的第二个参数同形；`task` 是要推进的任务（形状见 moduledoc）；
  `names` 是 `%{cid => 名字}`（取自此刻观察）；`others` 是其它开着的任务（同形），各写一行（写法见 moduledoc）。
  """
  def user_message(materials, task, names, others \\ []) do
    Enum.join(
      Reflection.materials_blocks(materials) ++
        [
          "The task I am working on: #{task["goal"]}\nWhy: #{task["why"]}",
          done_block(task["log"], names)
        ] ++
        list_block(
          "Steps I still meant to take:",
          Enum.map(task["steps"], &"- #{label(&1, names)} — #{&1["why"]}")
        ) ++
        list_block("My other open tasks:", Enum.map(others, &task_line(&1, names))) ++
        ["Why I am thinking about it now: #{Map.fetch!(@why_now, task["waiting"])}", @closing],
      "\n\n"
    )
  end

  @doc """
  每日回顾用户消息里“开着的任务”一块的各行（开的次序），每行带任务 id：`- <id>: <task_line>; last step: <种类 对象>: <结局>`，
  没做过步骤时 `; nothing done yet`。当头步、结局的写法与推进同一套（`Mind.activity_label/3`、`Mind.result/1`）；
  `names` 是 `%{cid => 名字}`（取自此刻观察）。没有开着的任务给 []。
  """
  def review_open_lines(open, names) do
    for task <- open do
      last =
        case List.last(task["log"]) do
          nil -> "nothing done yet"
          entry -> "last step: #{label(entry, names)}: #{Mind.result(outcome(entry))}"
        end

      "- #{task["id"]}: #{task_line(task, names)}; #{last}"
    end
  end

  @doc """
  每日回顾用户消息里“最近关掉的任务”一块的各行（持久行 `closed` 的次序，旧在前）：`- <id>: <goal> — <怎样关的>`。
  """
  def review_closed_lines(closed),
    do:
      for(
        task <- closed,
        do: "- #{task["id"]}: #{task["goal"]} — #{@closed_words[task["result"]]}"
      )

  # 一个开着的任务写成一行：`<goal> — next: <当头步>`；没有待做步骤时 `<goal> — no steps planned`。
  defp task_line(%{"goal" => goal, "steps" => [head | _]}, names),
    do: "#{goal} — next: #{label(head, names)}"

  defp task_line(%{"goal" => goal, "steps" => []}, _names), do: "#{goal} — no steps planned"

  defp done_block([], _names), do: "What I have done for it so far: nothing yet."

  defp done_block(log, names),
    do:
      Enum.join(
        [
          "What I have done for it so far:"
          | Enum.map(log, &"- #{label(&1, names)}: #{Mind.result(outcome(&1))}")
        ],
        "\n"
      )

  defp list_block(_heading, []), do: []
  defp list_block(heading, lines), do: [Enum.join([heading | lines], "\n")]

  defp label(%{"kind" => kind} = item, names),
    do: Mind.activity_label(kind, item["object"], names)

  # 持久行里摊平的结局 → `Mind.result/1` 的形状（Selector 历史里的原样）。
  defp outcome(%{"outcome" => "completed"}), do: :completed

  defp outcome(%{"outcome" => "failed", "act" => act, "reason" => reason}),
    do: {:failed, act, reason}

  defp outcome(%{"outcome" => "interrupted", "reason" => reason}), do: {:interrupted, reason}
end
