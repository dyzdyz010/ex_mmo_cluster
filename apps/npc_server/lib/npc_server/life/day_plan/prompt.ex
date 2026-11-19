defmodule NpcServer.Life.DayPlan.Prompt do
  @moduledoc """
  规划调用的提示词拼装（纯函数，不做 I/O）：系统提示词与用户消息。词表由本模块渲染（`activities/1` + `activity_list/1`；
  日计划的 `system_prompt/2` 收渲染好的工作列表，每日回顾的 `review_system_prompt/2` 直接收词表）；用户消息的各行都是
  已经渲染好的文本，那些渲染（“多久以前”的写法、召回条目去后缀、此刻一块各行、今天的意图与 `wants` 的各行）不在本模块。

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

  ## 每日回顾（任务层决策稿 `2026-11-19-npc-long-task-loop-decision.md` K-5；还没接线）

  日计划将退化为每日回顾：输出在 `intents` / `cannot_yet` 之外多 `tasks`（开 / 弃任务）。新模板 `review_system_prompt/2`
  是**原创措辞**，先经 K-0 离线测量（`.demo/observe/npc-task-k0-20261119/`）；Life 现在仍用 `system_prompt/2`，T-1 才换。
  回顾应答的检查在 `NpcServer.Life.Tasks.check/3`（`{:review, …}`）。用户消息里“开着的任务”“最近关掉的任务”两块
  与任务持久行的渲染同批在 T-1 加（届时每行须带任务 id，模型才能写 `drop`）；现在回顾的用户消息与日计划相同。

  词表的渲染（`activities/1` + `activity_list/1`）是日计划、每日回顾与任务推进（`NpcServer.Life.Tasks.Prompt`）共用的一处；
  回顾与推进的模板还共用同一个填充函数 `fill_template/3`（人格卡、词表、答案格式里的 `"object"` 一栏）。
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

  # 每日回顾的系统提示词（任务层决策稿 K-5；**原创措辞，K-0 离线测量用，T-1 才替换上面的 S1-R8 模板接进 Life**）。
  # 与 S1-R8 模板的差别：三种写法（意图 / 任务 / cannot_yet）各讲一段；任务的步骤可以点名此刻不在的人（S1-R8b 发现 1）；
  # `cannot_yet` 改义为“连开一个任务也表达不了的事”（K-5）；答案格式里写出 `object`（S1-R8b 发现 3）与 `tasks`。
  # 前三段（人格卡、三样材料的说明）与 S1-R8 逐字相同。`<character>`、`<activities>` 同上；`<object>` 处代入 `@object_slot`。
  @review_template ~S"""
  You are this person: <character>

  It is time to plan the rest of today. You will be given three things. First, how things stand right now: plain facts about this moment; where they differ from what you remember, right now is what is true. Second, things you remember: what you did, what you saw, what others did to you or said to you, each with roughly how long ago it was. They are your own memories, not a file and not a report. Third, lines you wrote in your journal before: they are what you thought then, not facts, and you may have been wrong.

  These are the kinds of work you can do:

  <activities>

  Write down what you mean to do in up to three ways.

  Intents: things you mean to do before today ends at midnight. Each is one kind of work from the list, given by its name exactly as written, with how many times you mean to do it and the time of day by which you want it done.

  Tasks: something you want to bring about that takes more than one step, or that you cannot do right now. Give the goal in your own words and the first one to three steps towards it, in the order you would take them. Each step is one kind of work from the list. A step may name someone who is not here now; you take it when you get the chance. A task stays with you after today until you finish it or give it up. You can have at most three tasks open; to give one up, put its id under "drop".

  Cannot yet: something you want to do that not even a task made of these kinds of work can express. Put it in your own words.

  Answer with one JSON object and nothing else:
  {"intents": [{"activity": "<a name from the list>", "object": <object>, "times": <whole number, at least 1>, "by": "<HH:MM, 24-hour, later than now and before midnight>", "why": "<one sentence, first person>"}], "tasks": {"open": [{"goal": "<what you want to bring about, in your own words>", "why": "<one sentence, first person>", "steps": [{"activity": "<a name from the list>", "object": <object>, "why": "<one sentence, first person>"}]}], "drop": ["<the id of an open task you give up>"]}, "cannot_yet": [{"want": "<what you want to do, in your own words>", "why": "<one sentence, first person>"}]}

  At most five things in "intents" and "cannot_yet" together. Any list may be empty. Stay with what you actually remember and how things stand right now. Do not add events, people, numbers or times that are not there.
  """

  # 答案格式里意图 / 步骤的 `"object"` 一栏怎么写（每日回顾与任务推进共用这一句，经 `fill_template/3` 代入；**原创措辞**）。
  # 默认 null，只有词表那一行接了“Optionally add "object": …”的种类才写名字。为什么：K-0 写成“该种类列出的名字之一或
  # null”，模型把 Corvin 写成静态种类 `confront_wrecker` 的对象，18 份回顾里 6 份因此被拒（K-0 results.md 发现 1）。
  @object_slot "<null, unless the kind's line above lists names; then one of those names, in quotes>"

  # 用户消息的固定文字。
  @today_heading "What I meant to do today, as it stands:"
  @wants_heading "Things I wanted to do but could not yet:"
  @closing "Plan the rest of today now."

  @doc """
  系统提示词。`character` 是人格卡一行（`You are this person: ` 之后的原文）；`activities` 是工作种类的有序列表，
  每项至少有 `:name` 与 `:criterion`（多余的键忽略），每项写成一行 `- <name>: <criterion>`，次序不变。
  列表由 `NpcServer.Life.DayPlan.Round` 用本模块的 `activities/1` 从词表渲染（稿 A 批 0b：名字是种类；有可点名对象的
  种类，判据后已接好一句可选对象），本函数只代入，模板一字不改。
  """
  def system_prompt(character, activities), do: fill(@system_template, character, activities)

  @doc """
  每日回顾的系统提示词（任务层决策稿 K-5）：`vocabulary` 是 Round 交进来的词表（`activities/1` 的输入），经
  `fill_template/3` 代入（与任务推进 `NpcServer.Life.Tasks.Prompt` 同一个填充函数）。
  **原创措辞，K-0 离线测量用；T-1 才替换 `system_prompt/2` 接进 Life**（届时 S1-R8 金标测试重定）。
  """
  def review_system_prompt(character, vocabulary),
    do: fill_template(@review_template, character, vocabulary)

  @doc """
  每日回顾与任务推进（`NpcServer.Life.Tasks.Prompt`）共用的模板填充：`template` 末尾的换行去掉（真实发出的系统提示词
  末尾没有换行），`<character>` 代入人格卡一行，`<activities>` 代入词表的渲染（`activities/1` + `activity_list/1`），
  `<object>` 代入答案格式里 `"object": ` 之后的那一段（默认 null，只在词表那一行列了名字的种类上写名字）。
  `vocabulary` 同 `activities/1` 的输入。日计划的 `system_prompt/2` 不经这里（S1-R8 模板没有 `<object>`，收渲染好的列表）。
  """
  def fill_template(template, character, vocabulary),
    do:
      template
      |> fill(character, activities(vocabulary))
      |> String.replace("<object>", @object_slot)

  @doc """
  词表 → 工作列表 `[%{name:, criterion:}]`（`system_prompt/2` 的第二个参数）。`vocabulary` 是
  `[%{kind:, criterion:, objects: %{显示名 => 对象}}]`（`NpcServer.Life.DayPlan.Round` 的快照形状）。有可点名对象的种类在判据后接
  一句可选对象，显示名按字符串排序、各写成 JSON 字符串（模型照抄进 `"object"`）；没有对象的种类判据原样，所以没配说话时
  与 S1-R8 逐字节相同。这句的措辞是原创取值（稿 A 批 0b；S1-R8b 测过一次，见其 results.md）。
  日计划、每日回顾与任务推进共用这一处（任务层决策稿 K-4“与回顾共用同一份词表渲染”）。
  """
  def activities(vocabulary) do
    for %{kind: kind, criterion: criterion, objects: objects} <- vocabulary,
        do: %{name: kind, criterion: criterion <> object_hint(objects)}
  end

  defp object_hint(objects) when map_size(objects) == 0, do: ""

  defp object_hint(objects) do
    names = objects |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &Jason.encode!/1)
    ~s| Optionally add "object": exactly one of #{names}.|
  end

  @doc "工作列表 → 系统提示词里的那几行：每项一行 `- <name>: <criterion>`，次序不变，多余的键忽略。"
  def activity_list(activities) do
    Enum.map_join(activities, "\n", fn %{name: name, criterion: criterion} ->
      "- #{name}: #{criterion}"
    end)
  end

  defp fill(template, character, activities) do
    template
    |> String.replace_suffix("\n", "")
    |> String.replace("<character>", character)
    |> String.replace("<activities>", activity_list(activities))
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
