defmodule NpcServer.Life.Reflection do
  @moduledoc """
  反思的纯函数核心（内容规范 `docs/10-active/cross-cutting/2026-11-13-npc-mind-content-spec.md` §10.11、§10.12 的 R1）：
  经历计分与触发判定、定问题、提示词拼装、应答检查、存档文档。不做 I/O、不依赖进程、不读时钟（时刻都由参数给）；
  要进 Life 持久行的数据（触发状态、问题、存档文档）都是字符串键的普通 map，能原样过 JSON。

  规则与提示词照离线测量 S1-X2 定稿的做法（`.demo/observe/npc-slice1-20261112/s1x2/plan.md` 的“做法”“提示词”
  “运行前补记”三节；离线实现 `docs/10-active/cross-cutting/tools/jev/s1x2_reflect.py`），只有句数上限按 §10.11 放宽一档。

      每条经历 → record/2（到点了吗）→ questions/4（问哪几件事）
        → 每问：system_prompt/1 + user_message/2 →（调用方发给模型）→ check/2（应答合格吗）→ archive/3（存档文档）
      落栏之后：thought/1（持久行里此刻该进选择的那一句，R4）

  ## 计分与触发（`score/1`、`new_trigger/0`、`record/2`、`started/2`、`manual/2`）

  每条经历按 tags 给分：`kind:event`（别人打或毁了我放的东西）8、`kind:conversation` 5、`kind:sight` 3、
  `kind:activity` 且带任一 `actor:`（期间有人进过 6 米）3、其余 `kind:activity` 1、`kind:task`（开 / 关任务的标准句，任务层 T-1a）1。
  触发条件两种：`kind:event` 的经历到来（立即触发）、累计分 ≥ 20。条件成立时距上一轮不足现实 5 分钟（按经历的 `"at_ms"`）
  就不触发、条件保留，到满 5 分钟后的第一条经历上触发。

  “一轮的时刻”有两个含义，别混：
  - **触发时刻**：`record/2` 给出的一轮的 `at_ms`、触发状态里的 `"last_at_ms"`，是触发它的那条经历的 `"at_ms"`
    （手动一轮是手动那一刻）；5 分钟间隔只从它算。
  - **想的时刻**：日记（Life 持久行 `"latest"` 各条）、`"round"` 小结与存档文档（`archive/3`）的时刻，是 Life 起槽那一刻的
    时钟（同离线的 t′，`Reflection.Round` 的 `now_ms` / `thought_at_ms`）；本模块不读时钟，由调用方传进来。
  判定与起轮分两步：`record/2` 只计分、判定到没到点；调用方真的起了一轮才 `started/2`（累计分清零、记下这一轮的触发时刻）。
  到点却起不了的那次不清零，条件留到下一条经历再判。
  分值、阈值、间隔都是原创取值（§10.3），实跑后调。

  ## 定问题（`questions/4`）

  每座我的建筑一问（有带 `place:<名>` 的新经历才问）、每个有关系的人一问（有带 `actor:<cid>` 的新经历才问）、
  “自己”一问（有任何新经历就问）；至多 3 问，次序 建筑 → 人 → 自己。超过 3 问时“自己”保留，其余两个名额给最近一条新经历
  最新的对象（原创取值）。问题原文是 S1-X2 定稿的三句。

  ## 提示词（`system_prompt/1`、`user_message/2`）

  系统提示词与用户消息的格式逐字照 S1-X2 定稿与真实发出的样本，不改一个字。输入都是已经渲染好的文本：
  “多久以前”的写法、召回条目去掉 `| When: …` 后缀、此刻一块各行的渲染都不在本模块。

  ## 应答检查（`check/2`）

  `Used:` 行存在、列了编号且编号都在材料条数内；正文（`Used:` 行之前）有内容且句数不超过 5。
  提示词写的是“至多 4 句”，代码的上限比提示词宽一档（§10.11：S1-X2 与网关核实的全部写作都是 4 或 5 句）。
  切句规则与离线检查 `s1x_reflect.py` 的 `checks` 同一条正则。本模块只给检查结果，重问与丢弃由调用方决定。

  ## 存档文档（`archive/3`）

  与经历条目同形 `%{"id", "at_ms", "text", "tags"}`；`"text"` 不带时刻前缀（Life 写库时统一加 `At <UTC> (UTC), `）。

  ## 新栏的那一句（`thought/1`，R4）

  “选择此刻该看到哪一句想法”这条规则只在这里：最近一轮写成了“自己”一问，就是那条的收尾一句；否则没有（撤下，
  不沿用上一轮的；只对留下了小结的一轮成立，见 `thought/1`）。Life 交给心智快照与 observe 的都是它的结果，不另判。
  """
  alias NpcServer.Life.State

  # 各类经历的分值、触发阈值与最小间隔：原创取值（内容规范 §10.3），实跑后调。
  @score_event 8
  @score_conversation 5
  @score_sight 3
  @score_activity_with_people 3
  @score_activity_alone 1
  # 开 / 关任务的标准句经历（任务层 T-1a，`Life.Tasks`）：同独自的活动，原创取值——自己定的打算，不该自己催出一轮反思。
  @score_task 1
  @trigger_score 20
  @min_gap_ms 5 * 60_000

  # 一轮至多问几件事（§10.3，参照 AI 小镇的 3 问）；超出时的取舍（“自己”保留、其余给最近的）是原创取值。
  @max_questions 3

  # 日记正文的句数上限：比提示词里的“至多 4 句”宽一档（§10.11 的决定）。
  @max_sentences 5

  # 系统提示词：S1-X2 plan.md 定稿原文，`<character>` 处代入人格卡一行。heredoc 末尾多一个换行，
  # 在 `system_prompt/1` 里去掉（真实发出的系统提示词末尾没有换行）。
  @system_template ~S"""
  You are this person: <character>

  You have a quiet moment to yourself and are writing a few lines in your own journal. Nobody else will ever read it. You write to get your own thinking straight, and you will read these lines again later when you decide what to do with your days.

  You will be given four things. First, how things stand right now: these are plain facts about this moment, and where they differ from what you remember, right now is what is true. Second, things you remember: what you did, what you saw, what others did to you or said to you, each with roughly how long ago it was. They are your own memories, not a file and not a report. Third, lines you wrote in this journal before: they are what you thought then, not facts, and you may have been wrong. Last, one thing to think over.

  Write what you now think about it, in your own voice, in the first person, in plain connected sentences, the way you would mutter to yourself. If what has happened since, or how things stand right now, no longer fits what you wrote before, say what you think now. If two of your earlier thoughts would have you do opposite things, make up your mind between them. End with what you will actually do next. Four sentences at most.

  Stay with what you actually remember and how things stand right now. Do not add events, people, numbers or times that are not there. Where you do not know something, say so the way a person would, for example: "I don't know whether he came back after that."

  Write only the journal lines: no headings, no lists, nothing about memories, records, data, notes or summaries as such, and no account of how you reasoned.

  Here are three journal entries written by other people, only to show the kind of voice. Their lives are not yours; take nothing from what they say.
  <example>The nets came up half empty again, three mornings now. I think the shoal has moved past the point, and I would rather row an hour further than sit here hoping. Tomorrow I try the north bank.</example>
  <example>Mira paid back the flour she owed, and a day early. I was wrong to grumble about her. Next time she asks I will lend without making her wait.</example>
  <example>The beam I set last week has not shifted. Good. I still do not trust the east wall, and I will hang nothing heavy on it until I have seen it through a storm.</example>
  """

  # 用户消息的固定文字（S1-X2 plan.md 定稿原文）。
  @thoughts_heading "What I thought before (my own earlier thoughts, not facts):"
  @nothing_yet "nothing yet"
  @used_instruction ~s|After the journal lines, add one last line that starts with "Used:" and lists the numbers of the things under "What happened" that you drew on.|

  # 存档正文的开头；Life 写库时在前面加 `At <UTC> (UTC), `，合起来同 S1-X2 存进反思库的原文。
  @archive_opening "I thought it over: "

  # “自己”一问的键：定问题（`self_question/0`）与新栏取哪一句（`thought/1`）共用。
  @self_key "self"

  @doc """
  一条经历的分值，按它的 tags（`kind:` 恰好一个）：`kind:event` 8、`kind:conversation` 5、`kind:sight` 3、
  `kind:activity` 带任一 `actor:` 3、不带 1、`kind:task`（开 / 关任务的标准句，任务层 T-1a）1。`kind:` 不是恰好一个、或不在这五种里，
  直接崩：计分表只覆盖 Life 的经历入口，别的种类（例如反思自己的存档）进来是调用方的错误。
  """
  def score(%{"tags" => tags}) do
    [kind] = for "kind:" <> kind <- tags, do: kind

    case kind do
      "event" ->
        @score_event

      "conversation" ->
        @score_conversation

      "sight" ->
        @score_sight

      "activity" ->
        if with_people?(tags), do: @score_activity_with_people, else: @score_activity_alone

      "task" ->
        @score_task
    end
  end

  @doc """
  空的触发状态：`"score"` 自上一轮以来的累计分、`"last_at_ms"` 上一轮的时刻（还没有过为 nil）、
  `"event_waiting"` 有一条 `kind:event` 因间隔不足还在等着触发。整份进 Life 持久行。
  """
  def new_trigger, do: %{"score" => 0, "last_at_ms" => nil, "event_waiting" => false}

  @doc """
  记入一条经历（`%{"at_ms", "tags"}`），返回 `{新的触发状态, nil | 到点的一轮}`。只计分与判定，**不清零**：
  累计分照加、等着的 `kind:event` 照记、`"last_at_ms"` 不动；真的起了一轮由调用方再调 `started/2`。
  所以条件成立且间隔已满时，之后每一条经历都给出“到点”，直到调用方起了一轮——起不了（槽在途、还没有观察）的那次
  不会把条件吃掉。

  一轮是 `%{at_ms: 这条经历的时刻, score: 此刻的累计分（含这一条）, causes: 成立的条件}`，`causes` 是
  `[:event]`、`[:score]` 或 `[:event, :score]`——保留期间先后成立的条件都算。条件成立但距上一轮不足 5 分钟时给 nil，
  到满 5 分钟后的第一条经历上给出一轮。
  """
  def record(
        %{"score" => accumulated, "last_at_ms" => last_at_ms, "event_waiting" => event_waiting},
        %{"at_ms" => at_ms} = entry
      ) do
    total = accumulated + score(entry)
    event_waiting = event_waiting or "kind:event" in entry["tags"]
    trigger = %{"score" => total, "last_at_ms" => last_at_ms, "event_waiting" => event_waiting}

    causes =
      if(event_waiting, do: [:event], else: []) ++
        if(total >= @trigger_score, do: [:score], else: [])

    # 没有条件成立，或条件成立但离上一轮还不满 5 分钟：不到点。
    if causes == [] or (last_at_ms != nil and at_ms - last_at_ms < @min_gap_ms),
      do: {trigger, nil},
      else: {trigger, %{at_ms: at_ms, score: total, causes: causes}}
  end

  @doc """
  真的起了一轮（到点的或手动的）：返回起轮之后的触发状态——累计分清零、等着的事件清掉、`"last_at_ms"` 记下 `at_ms`。
  `at_ms` 是那一轮的 `at_ms`（`record/2` 给的触发那条经历的时刻，或 `manual/2` 的手动时刻），下一轮的 5 分钟间隔从它算。
  """
  def started(%{"score" => _, "last_at_ms" => _, "event_waiting" => _}, at_ms),
    do: %{"score" => 0, "last_at_ms" => at_ms, "event_waiting" => false}

  @doc """
  手动起一轮（`NpcServer.Life.reflect/1`）：给出 `%{at_ms:, score: 此前的累计分, causes: [:manual]}`，`at_ms` 由调用方给
  （手动那一刻的时钟）。不看间隔、不改触发状态：手动入口是运维 / 调试用的，要不要起由调用方决定；起了之后与到点的一轮
  一样调 `started/2`。
  """
  def manual(%{"score" => accumulated}, at_ms),
    do: %{at_ms: at_ms, score: accumulated, causes: [:manual]}

  @doc """
  这一轮要问的问题（有序，至多 3 个）。`buildings` 是我的建筑名（同名的只问一次：`place:` tag 分不出同名的两座），
  `people` 是有关系的人的 cid，`names` 是 `%{cid => 名字}`（写法按 `Life.State.person/2`，取不到名字写 `actor <cid>`），
  `entries` 是自上一轮以来的新经历（`%{"at_ms", "tags"}`）。没有新经历返回 `[]`。

  每个问题是 `%{"key", "text", "tags"}`：`"key"` 稳定地指认对象（`"place:<名>"`、`"person:<cid>"`、`"self"`），
  `"text"` 是问题原文，`"tags"` 是存档用的（`kind:reflection` 加相应的 `place:` / `actor:`）。
  """
  def questions(_buildings, _people, _names, []), do: []

  def questions(buildings, people, names, entries) do
    places =
      Enum.flat_map(Enum.uniq(buildings), fn name ->
        candidate(entries, "place:" <> name, place_question(name))
      end)

    persons =
      Enum.flat_map(people, fn cid ->
        candidate(entries, "actor:#{cid}", person_question(cid, names))
      end)

    candidates = places ++ persons

    keep(candidates) ++ [self_question()]
  end

  @doc """
  系统提示词：S1-X2 定稿原文，`character` 是人格卡一行（给 Jev 的 state 里 `Character: ` 之后的原文）。
  """
  def system_prompt(character) do
    @system_template
    |> String.replace_suffix("\n", "")
    |> String.replace("<character>", character)
  end

  @doc """
  一个问题的用户消息（四块加末尾的 `Used:` 要求），格式逐字同 S1-X2 真实发出的样本。`materials`：

      right_now       此刻一块的各行（`Right now:` 标题由本函数加）
      happened        发生过的事的各条正文（已带“多久以前”、已去后缀），本函数从 1 起编号写成 `[n] 正文`
      thought_before  同一问题上一次的日记，没有为 nil（写 `nothing yet`）
      other_thoughts  其它问题各自最新的日记，各占一行，没有为 `[]`（写 `nothing yet`）

  之前的日记各压成一行（连续空白换成一个空格），一条日记才占一行。
  """
  def user_message(%{"text" => question}, materials) do
    Enum.join(
      materials_blocks(materials) ++ ["To think over now: " <> question, @used_instruction],
      "\n\n"
    )
  end

  @doc """
  用户消息里的三块材料（`Right now:` / `What happened:` / `What I thought before …`），返回三块字符串的列表
  （块内行间用 `\\n`，块与块之间的 `\\n\\n` 由调用方连）。入参是 `user_message/2` 的第二个参数那张 map。

  反思（`user_message/2`）与日计划（`NpcServer.Life.DayPlan.Prompt.user_message/2`）共用这一个拼法：两处的材料取自
  同一条路径、写法必须一致，所以只在这里写一遍。`happened` 至少一条（空列表没有“发生过的事”，直接崩）。
  """
  def materials_blocks(%{
        right_now: right_now,
        happened: [_ | _] = happened,
        thought_before: thought_before,
        other_thoughts: other_thoughts
      }) do
    numbered = happened |> Enum.with_index(1) |> Enum.map(fn {text, n} -> "[#{n}] #{text}" end)
    this = if thought_before, do: one_line(thought_before), else: @nothing_yet

    others =
      case other_thoughts do
        [] -> @nothing_yet
        _ -> Enum.map_join(other_thoughts, "\n", &one_line/1)
      end

    [
      Enum.join(["Right now:" | right_now], "\n"),
      Enum.join(["What happened:" | numbered], "\n"),
      Enum.join(
        [@thoughts_heading, "About this: " <> this, "About other things: " <> others],
        "\n"
      )
    ]
  end

  @doc """
  检查模型的应答全文（`response`，`items` 是这一问 `What happened` 的条数）。

  合格返回 `{:ok, %{journal:, used:, sentences:, closing:}}`：`journal` 是 `Used:` 行之前的正文（去掉首尾空白），
  `used` 是 `Used:` 行里的编号（原样次序），`sentences` 是句数，`closing` 是正文的最后一句（原文不改）。
  `Used:` 行取最后一个以它开头的行，其后的行不看。不合格返回 `{:error, 原因}`，按下面的次序报第一个，可直接写进日志：

      :used_line_missing              没有以 `Used:` 开头的行
      :used_line_empty                `Used:` 行里一个编号都没有
      {:used_out_of_range, [编号]}    不在 1..items 内的编号（原样次序）
      :journal_empty                  `Used:` 行之前没有正文
      {:too_many_sentences, 句数}     句数超过 5
  """
  def check(response, items) do
    with {:ok, journal, used} <- split_used(response),
         :ok <- check_used(used, items),
         sentences = split_sentences(journal),
         :ok <- check_sentences(sentences) do
      {:ok,
       %{
         journal: journal,
         used: used,
         sentences: length(sentences),
         closing: List.last(sentences)
       }}
    end
  end

  @doc """
  一条反思的存档文档，与经历条目同形：`"id"` 是 `reflection:<问题的键>:<at_ms>`，`"at_ms"` 是这一轮**想的时刻**
  （Life 起槽那一刻的时钟，`Reflection.Round` 的 `thought_at_ms`；不是触发那条经历的时刻，见 moduledoc），
  `"text"` 是 `I thought it over: <日记>`（不带时刻前缀，Life 写库时加），`"tags"` 是问题的存档 tags。
  """
  def archive(%{"key" => key, "tags" => tags}, at_ms, journal),
    do: %{
      "id" => "reflection:#{key}:#{at_ms}",
      "at_ms" => at_ms,
      "text" => @archive_opening <> journal,
      "tags" => tags
    }

  @doc """
  此刻该进选择的那一句想法（心智快照的 `What I have come to think` 栏，内容规范 §10.11 末尾用户对第 1 条的答复）。
  `reflection` 是 Life 持久行的 `"reflection"`。

  最近一轮的小结 `"round"` 里“自己”一问写成了 → `%{closing: 那条日记的收尾一句（原文）, at_ms: 那条的想的时刻}`，
  取自 `"latest"` 里“自己”那条（落栏时它与这一轮的小结同一个时刻）；心智快照只写 `closing` 原文，`at_ms` 给 observe 看。
  否则 → nil：还没有过任何一轮；
  或最近一轮没写成“自己”（中止、写作失败、丢弃）——此时 `"latest"` 里还留着上一轮的那条，但**不沿用**：
  起一轮说明其间有了够多的新经历，上一轮的打算是在那之前想的。
  “不沿用”只对留下了小结的一轮成立：本函数只看 `"round"`，一轮已起而没留下小结时给的仍是上一轮那句
  （哪些路径会这样，见 `NpcServer.Life` moduledoc 的“已知”清单）。
  """
  def thought(%{"round" => nil}), do: nil

  def thought(%{"round" => %{"written" => written}, "latest" => latest}) do
    if @self_key in written do
      %{"closing" => closing, "at_ms" => at_ms} = latest[@self_key]
      %{closing: closing, at_ms: at_ms}
    end
  end

  defp with_people?(tags), do: Enum.any?(tags, &String.starts_with?(&1, "actor:"))

  # 一个候选对象：带 `tag` 的新经历里最新的时刻与问题；没有带它的新经历就不是候选。
  defp candidate(entries, tag, question) do
    case for(%{"at_ms" => at_ms, "tags" => tags} <- entries, tag in tags, do: at_ms) do
      [] -> []
      times -> [{Enum.max(times), question}]
    end
  end

  # 留给建筑与人的名额（总数减去“自己”那一问）：超出时留最近一条新经历最新的，同样新的按原次序；留下的仍按原次序。
  defp keep(candidates) when length(candidates) < @max_questions,
    do: Enum.map(candidates, &elem(&1, 1))

  defp keep(candidates) do
    indexed = Enum.with_index(candidates)

    kept =
      indexed
      |> Enum.sort_by(fn {{latest_ms, _question}, index} -> {-latest_ms, index} end)
      |> Enum.take(@max_questions - 1)
      |> Enum.map(fn {_, index} -> index end)

    for {{_latest_ms, question}, index} <- indexed, index in kept, do: question
  end

  defp place_question(name),
    do: %{
      "key" => "place:" <> name,
      "text" =>
        ~s|My building "#{name}": what has actually happened there, where do things stand with it now, and what exactly will I do about it next?|,
      "tags" => ["kind:reflection", "place:" <> name]
    }

  defp person_question(cid, names),
    do: %{
      "key" => "person:#{cid}",
      "text" =>
        "#{State.person(cid, names)}: what have they actually done around me, where do things stand between us now, and how exactly will I act the next time they are near?",
      "tags" => ["kind:reflection", "actor:#{cid}"]
    }

  @doc """
  “自己”那一问（`questions/4` 每一轮都带的那条）：`%{"key" => "self", "text", "tags"}`。日计划的取材也用它
  （`NpcServer.Life.DayPlan.Round`：离线测量 S1-R8 的材料就是这一问的两次召回与“之前的想法”）。
  """
  def self_question,
    do: %{
      "key" => @self_key,
      "text" =>
        "How I have been spending my time lately: what came of it, and what exactly will I keep doing or do differently from here?",
      "tags" => ["kind:reflection"]
    }

  # 同 s1x_reflect.py `one_line`：连续空白换成一个空格，去掉首尾空白。
  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # 同 s1x_reflect.py `split_used`：取最后一个（去掉行首空白后）以 `Used:` 开头的行；正文是它之前的各行。
  defp split_used(response) do
    lines = response |> String.trim() |> String.split("\n")

    used_at =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _index} -> used_line?(line) end)
      |> List.last()

    case used_at do
      nil ->
        {:error, :used_line_missing}

      {line, index} ->
        "Used:" <> listed = String.trim_leading(line)
        used = for [number] <- Regex.scan(~r/\d+/, listed), do: String.to_integer(number)
        {:ok, lines |> Enum.take(index) |> Enum.join("\n") |> String.trim(), used}
    end
  end

  defp used_line?(line), do: line |> String.trim_leading() |> String.starts_with?("Used:")

  defp check_used([], _items), do: {:error, :used_line_empty}

  defp check_used(used, items) do
    case Enum.reject(used, &(&1 >= 1 and &1 <= items)) do
      [] -> :ok
      outside -> {:error, {:used_out_of_range, outside}}
    end
  end

  # 切句：句末标点之后（可跟收尾的引号、括号）的空白处断开，各句是原文的子串。正则与 s1x_reflect.py `checks`
  # （约第 223 行）逐字相同。写在函数里而不放模块属性：较新的 OTP 上编译好的正则不能存进模块属性。
  defp split_sentences(journal),
    do:
      ~r/(?<=[.!?])["')\]]*\s+/u
      |> Regex.split(journal)
      |> Enum.reject(&(String.trim(&1) == ""))

  defp check_sentences([]), do: {:error, :journal_empty}

  defp check_sentences(sentences) when length(sentences) > @max_sentences,
    do: {:error, {:too_many_sentences, length(sentences)}}

  defp check_sentences(_sentences), do: :ok
end
