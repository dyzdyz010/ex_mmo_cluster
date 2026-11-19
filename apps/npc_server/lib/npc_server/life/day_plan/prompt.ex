defmodule NpcServer.Life.DayPlan.Prompt do
  @moduledoc """
  规划调用的提示词拼装（纯函数，不做 I/O）：系统提示词与用户消息。输入都是已经渲染好的文本，渲染（“多久以前”的写法、
  召回条目去后缀、此刻一块各行、今天的意图与 `wants` 的各行）都不在本模块。

  ## 为什么逐字照 S1-R8

  系统提示词与用户消息的文字逐字照离线测量 S1-R8 实际发出的那一份（`.demo/observe/npc-slice1-20261112/s1r8/plan.md`
  的“提示词”一节），一个字不改：S1-R8 回答的是“规划模型能不能用我们的词表写出合规意图”，测过的形状才有读数可依；
  提示词措辞的调整是后期的事（实现设计稿 §7），要改先离线重测。`npc_life_day_plan_prompt_test.exs` 用 S1-R8 存下的
  真实请求体当金标，同样的人格、词表、材料，产出与存档逐字节相同。

  ## 用户消息

  三块材料（`Right now:` / `What happened:` / `What I thought before …`，拼法与反思共用
  `NpcServer.Life.Reflection.materials_blocks/1`）加末行 `Plan the rest of today now.`，块间 `\\n\\n`、块内行间 `\\n`。
  S1-R8 之后加了两块可选的，**这两块没测过**，实跑后看模型怎么用它们：

      What I meant to do today, as it stands:     今天已有的意图与状态，一条一行（`today:`）
      Things I wanted to do but could not yet:    旧 `wants`，一条一行（`wants:`）

  两块都只在非空时才出现，位置在三块材料之后、末行之前，今天的意图在前。所以“当日第一次规划且没有旧 `wants`”与 S1-R8
  测过的用户消息逐字节相同。
  """
  alias NpcServer.Life.Reflection

  # 系统提示词：S1-R8 plan.md 的原文。`<character>` 处代入人格卡一行，`<activities>` 处代入工作种类列表。
  # heredoc 末尾多一个换行，在 `system_prompt/2` 里去掉（真实发出的系统提示词末尾没有换行）。
  @system_template ~S"""
  You are this person: <character>

  It is time to plan the rest of today. You will be given three things. First, how things stand right now: plain facts about this moment; where they differ from what you remember, right now is what is true. Second, things you remember: what you did, what you saw, what others did to you or said to you, each with roughly how long ago it was. They are your own memories, not a file and not a report. Third, lines you wrote in your journal before: they are what you thought then, not facts, and you may have been wrong.

  Decide what you mean to get done before today ends at midnight. Each thing you mean to do is one of two kinds.

  Either it is one of the kinds of work below. Then give its name exactly as written, how many times you mean to do it before midnight, and the time of day by which you want it done.

  <activities>

  Or it is something you want to do that none of the kinds of work above can express. Then put it under "cannot_yet" in your own words.

  Answer with one JSON object and nothing else:
  {"intents": [{"activity": "<a name from the list>", "times": <whole number, at least 1>, "by": "<HH:MM, 24-hour, later than now and before midnight>", "why": "<one sentence, first person>"}], "cannot_yet": [{"want": "<what you want to do, in your own words>", "why": "<one sentence, first person>"}]}

  At most five things in all, counting both lists. Either list may be empty. Stay with what you actually remember and how things stand right now. Do not add events, people, numbers or times that are not there.
  """

  # 用户消息的固定文字。
  @today_heading "What I meant to do today, as it stands:"
  @wants_heading "Things I wanted to do but could not yet:"
  @closing "Plan the rest of today now."

  @doc """
  系统提示词。`character` 是人格卡一行（`You are this person: ` 之后的原文）；`activities` 是工作种类的有序列表，
  每项至少有 `:name` 与 `:criterion`（多余的键忽略），每项写成一行 `- <name>: <criterion>`，次序不变。
  列表由 `NpcServer.Life.DayPlan.Round` 从词表渲染（稿 A 批 0b：名字是种类；有可点名对象的种类，判据后已接好一句可选对象），
  本函数只代入，模板一字不改。
  """
  def system_prompt(character, activities) do
    listed =
      Enum.map_join(activities, "\n", fn %{name: name, criterion: criterion} ->
        "- #{name}: #{criterion}"
      end)

    @system_template
    |> String.replace_suffix("\n", "")
    |> String.replace("<character>", character)
    |> String.replace("<activities>", listed)
  end

  @doc """
  用户消息。`materials` 与 `NpcServer.Life.Reflection.user_message/2` 的第二个参数同形
  （`right_now` / `happened` / `thought_before` / `other_thoughts`）。`opts`：

      today:   今天已有的意图的各行文本（已渲染），默认 []
      wants:   旧 `wants` 的各行文本（已渲染），默认 []

  输出 = 三块材料 +（`today` 非空才有）今天的意图一块 +（`wants` 非空才有）旧 `wants` 一块 + 末行。两块都为空时
  与 S1-R8 实际发出的用户消息逐字节相同（moduledoc）。
  """
  def user_message(materials, opts \\ []) do
    today = Keyword.get(opts, :today, [])
    wants = Keyword.get(opts, :wants, [])

    Enum.join(
      Reflection.materials_blocks(materials) ++
        optional_block(@today_heading, today) ++
        optional_block(@wants_heading, wants) ++
        [@closing],
      "\n\n"
    )
  end

  defp optional_block(_heading, []), do: []
  defp optional_block(heading, lines), do: [Enum.join([heading | lines], "\n")]
end
