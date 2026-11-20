defmodule NpcServer.Life.Tasks do
  @moduledoc """
  任务层的纯函数核心（任务层决策稿 `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §4）。
  写法同 `NpcServer.Life.DayPlan`：不做 I/O、不依赖进程、不读时钟（日号、毫秒时刻都由参数给）；结果是字符串键的普通 map，
  能原样过 JSON。Life 的持久行 `"tasks"` 就是 `new/0` 的形状，规则全在这里，Life 只做触发、保存与视图（`NpcServer.Life`
  moduledoc 的“每日回顾与任务”）。

  ```mermaid
  flowchart LR
    RV["每日回顾应答<br/>check/3 {:review…}"] -->|review/4：开 / 弃| TK[("持久行 tasks")]
    EX["活动经历<br/>Selector.experience/1"] -->|"record_step/4：只记当头步，K-3 分类"| TK
    NW["对我说话 / kind:event 的人"] -->|"note_news/3"| TK
    CL["每帧观察的游戏日与时钟"] -->|"tick/3：到期关闭、停滞"| TK
    TK -->|"column/1"| MD["Mind 的 Plans and promises"]
    TK -->|"due/2：最早开的 waiting 任务<br/>admit/3：当日 12 次<br/>basis/2：起推进时的基准"| AD["推进写作<br/>Tasks.Round（check/3 :advance）"]
    AD -->|"adopt/6（比对基准）· reject/4 · fail/1 · refund/1"| TK
  ```

  ## 任务与步骤（K-1）

  任务是 NPC 自己开的一件要几步才做成的事：`goal`（模型原文）、`why`、待做的步骤（≤ 3，当头那条是此刻的候选）。
  步骤粒度是一项活动 = **种类 + 可选对象**，与日计划的意图同一套词表 `%{种类 => %{显示名 => 对象}}`（K-4：回顾与推进
  共用一份词表；T-2 之前种类就是 `NpcServer.Offers.plan_kinds/1`，T-2 加 `look_for` 时再立任务词表入口；对象由 Life 展开）。检查后的步骤是 `%{"kind", "object", "why"}`，
  `object` 已换成显示名对应的对象（没点名为 nil）。

  ## 持久行 `"tasks"`（`new/0`）

      "open"        [任务]，开的次序（≤ 3）
      "closed"      最近关掉的 5 条小结 %{"id", "goal", "result" => "done" | "dropped" | "expired" | "stuck", "note", "closed_day", "completed"}
      "calls"       %{"day", "n"}：本游戏日发出了写作请求的推进次数（`admit/3` 起调用时记、`refund/1` 退回没发出的；
                    T-3 的学习写作与推进共用这一个计数，决策稿 K-9）
      "last_at_ms"  上一次推进调用的时钟（`admit/3` 记；最小间隔从它算）
      "counts"      %{opened advanced done dropped expired stuck rejected failed cannot stale}
                    advanced = 采用的推进（任一决定）；rejected / failed / stale = 没采用的推进；cannot = 采用的推进里写了 cannot 的；
                    stale = 合格、但写作在途时任务的步骤已经变了的推进（见“推进”）

      任务 = %{"id" => "t<开的日号>:<开过的总数>", "goal", "why", "opened_day", "expires_day" => 开的日号 + 2,
              "steps" => [%{"kind", "object", "why"}],                       待做，当头那条是此刻的候选
              "log" => [%{"kind", "object", "outcome", "act", "reason", "at_ms"}],  最近 6 条步骤结局
              "waiting" => nil | "failed" | "steps_done" | "stalled" | "heard" | "event",   K-3 判出的“待推进”及其原因
              "head_since_ms", "head_failures", "rejected_in_row", "completed" => 完成的步数, "note" => 最近一次推进写的一句}

  `log` 记**当头步本身**的种类与对象（不是候选的实际对象：任务步只有“人或没点名”，候选的对象可能是材料，渲染不了；
  决策稿 §7 T-1a 偏差 D-6）。`completed` 另计（log 只留 6 条，数不出完成了几步；D-7）。`note` 是任务的字段，不进 log（D-5）。

  ## 谁写什么（不变量）

  - LLM 写的任务与步骤只经 `check/3` 一处进入（回顾 `{:review, …}`、推进 `:advance`）；采用回顾在 `review/4`，采用推进在 `adopt/6`。
  - 指针、`waiting`、计数、到期只由代码按结构化结局与时钟改（`record_step/4`、`note_news/3`、`tick/3`、推进落栏的 `reject/4` / `fail/1`）。
  - 开 / 关任务各给一条标准句经历（`review/4`、`tick/3`、`reject/4` 的第二个返回值、`adopt/6` 的第三个），由 Life 写进经历；Hindsight 里的这些只是派生物。

  ## K-3：只在偏差或新信息时待推进

  | 结局 / 事件 | 处理 |
  |---|---|
  | 当头步 completed，后面还有步 | 前移，`completed + 1`，`head_failures` 清零，当头步从此刻计时；在等的 `failed` / `stalled` 清掉（偏差已化解），`heard` / `event` 留着 |
  | 当头步 completed，没有下一步 | 同上，待推进 `steps_done` |
  | failed，原因是瞬态（`NpcServer.Trees.transient_reasons/0`） | `head_failures + 1`、从此刻计时；同一步连续第 2 次才待推进 `failed` |
  | failed，其它原因 | `head_failures + 1`，待推进 `failed` |
  | interrupted | 只记 log、从此刻计时；不计失败、不待推进（用户定 ④） |
  | 任务里的人（`people/1`）对我说话 / 是 `kind:event` 的出手者 | 待推进 `heard` / `event`（`note_news/3`） |
  | 当头步满 6 游戏小时没被做 | 待推进 `stalled`（`tick/3`） |
  | 过了到期日 | 关为 `expired`，写经历，不问模型（`tick/3`） |

  已在等的任务不改原因（第一个原因就是这次推进要回答的）。`place:` 那半行（决策稿 K-3）不做：任务对象现在只有人（D-2）。
  瞬态失败的“连续”只数失败：`head_failures` 只在当头步完成（前移）时清零，打断既不计也不清——失败、打断、再失败算连续两次。

  ## 唯一校验点（K-4 / K-5）

  LLM 写的任务与步骤只经 `check/3` 一处进入：推进应答整份（`:advance`）与每日回顾应答整份（`{:review, 此刻分钟, 开着的任务}`）。
  单条种类与对象、`cannot` 的核对复用 `DayPlan` 的同一函数（`DayPlan.check_kind/3`、`DayPlan.check_want/1`），回顾里的
  意图与 `cannot_yet` 原样交 `DayPlan.check_lists/3`——错误原因与日计划完全相同，不另写一份。

  ## 推进（K-4、K-9）

  Life 每帧观察上（回顾没有起的时候）问 `due/2`：过了 3 分钟最小间隔，取最早开的 `waiting` 任务；过花费闸门之后 `admit/3` 记一次
  调用，起推进槽（`NpcServer.Life.Tasks.Round`），槽里存这个任务此刻的基准 `basis/2`（待做步骤与完成步数）。落栏：合格 → `adopt/6`；
  不合格 → `reject/4`（连续 3 次关为 stuck）；写作失败 → `fail/1`；写作没发出 → 另 `refund/1`。除采用外 `waiting` 都留着，下一次到点再问。

  **比对后采用**（乐观并发控制：读时记版本、提交时比对，变了就放弃这次写入；Kung & Robinson 1981 的验证阶段）：写作在途时 NPC 照常
  行动，当头步可能已经做成前移（`record_step/4`）。合格的应答是对起推进那一刻的任务写的，落栏时任务的 `steps` 或 `completed` 与
  基准不同，就不采用（三种决定都一样）：任务保持现状，只计 `stale`；`rejected_in_row`、`waiting` 不动，下一次到点照常再问。
  额度已扣（写作已发出），不退。只比这两项：`waiting`、log、连续失败数变了（如又失败一次）不影响应答针对的那几步。

  ## 原创取值（实跑后调；决策稿 §6 Q-4）

  开着的任务至多 3（`@max_open`）；一次（开任务或推进）至多 3 步（`@max_steps`）；任务开后 2 个游戏日到期（`@expire_days`）；
  当头步 6 游戏小时没被做算停滞（`@stall_hours`）；瞬态失败连续 2 次算偏差（`@transient_tolerance`）；log 留 6 条、
  关掉的小结留 5 条；两次推进至少隔 3 分钟（`@min_gap_ms`）；推进连续 3 次不合格关为 stuck（`@stuck_after`）。
  推进与学习写作共用每人每游戏日 12 次（`@day_calls`，用户 2026-11-18 定）；回顾与推进每次写作出向 ≤ 4096（`write_max_tokens/0`，K-9）。
  """
  alias MmoContracts.WorldTime
  alias NpcServer.Life.DayPlan

  # 每个 NPC 同时开着的任务上限（决策稿 K-1，原创取值）。
  @max_open 3
  # 一次写出的待做步骤上限（决策稿 K-1 / K-4，原创取值）。
  @max_steps 3
  # 开任务那一日之后几个游戏日到期（K-1，原创取值）：过了 `opened_day + 2` 那一日即关。
  @expire_days 2
  # 当头步多久没被做算停滞（K-3，原创取值）：游戏小时，按游戏钟换算（不写死倍率）。
  @stall_hours 6
  @stall_game_us @stall_hours * 3_600_000_000
  # 同一步连续瞬态失败几次算偏差（K-3，原创取值）。
  @transient_tolerance 2
  # 每个任务留最近几条步骤结局、持久行留最近几条关掉的小结（K-1，原创取值）。
  @log_size 6
  @closed_size 5
  # 每人每游戏日的写作额度（K-9，用户 2026-11-18 定的 12 次）：推进与 T-3 的学习写作共用这一个计数（持久行 `"calls"`）。
  @day_calls 12
  # 两次推进的最小间隔（K-9“同日计划”，原创取值；与回顾的间隔各算各的，所以单独一个常量）。
  @min_gap_ms 3 * 60_000
  # 同一任务连续几次推进应答不合格就关为 stuck（K-4，Voyager“卡住 4 轮换任务”的对应，原创取值）。
  @stuck_after 3
  # 回顾与推进每次写作的出向上限（K-9：思考 + 正文，DeepSeek 执行这个参数；K-0 实测最大 4,406）。
  @write_max_tokens 4096

  @counts ~w(opened advanced done dropped expired stuck rejected failed cannot stale)
  # 起推进时记下、落栏时比对的任务字段（`basis/2`、`adopt/6`）：这两项只由“步骤做成前移”与采用推进改。
  @basis_keys ["steps", "completed"]

  @advance_keys ["task", "steps", "cannot", "note"]
  @review_keys ["intents", "cannot_yet", "tasks"]
  @tasks_keys ["open", "drop"]
  @opened_keys ["goal", "why", "steps"]
  @step_keys ["activity", "why"]
  # 步骤里可缺的键：对象（可缺、可为 null，都是没点名；同日计划意图）。
  @step_optional_keys ["object"]
  @verdicts %{"continue" => :continue, "done" => :done, "drop" => :drop}

  # 关闭方式 → 标准句经历（原创措辞，统筹 2026-11-19 采用，实跑后调）。推进的 done / drop（T-1b）在句后接模型写的 note。
  @closing_sentences %{
    "done" => ~s|I finished my task "<goal>".|,
    "dropped" => ~s|I gave up my task "<goal>".|,
    "expired" => ~s|I did not finish my task "<goal>" in time, so I let it go.|,
    "stuck" => ~s|I could not settle on a next step for my task "<goal>", so I set it aside.|
  }

  @type vocabulary :: %{String.t() => %{String.t() => term()}}
  @type step :: %{String.t() => term()}
  @type tasks :: %{String.t() => term()}
  @type episode :: %{String.t() => term()}
  @type advanced :: %{
          task: :continue | :done | :drop,
          steps: [step()],
          cannot: nil | %{String.t() => String.t()},
          note: String.t()
        }
  @type reviewed :: %{
          intents: [map()],
          wants: [map()],
          tasks: %{open: [map()], drop: [String.t()]}
        }

  # --- 持久行 ---

  @doc "空的一份（持久行 `\"tasks\"` 的初值；形状见 moduledoc）。"
  @spec new() :: tasks()
  def new do
    %{
      "open" => [],
      "closed" => [],
      "calls" => %{"day" => nil, "n" => 0},
      "last_at_ms" => nil,
      "counts" => Map.new(@counts, &{&1, 0})
    }
  end

  # --- 采用回顾（K-5） ---

  @doc """
  采用一份合格回顾应答里的 `tasks`（`check/3` 的 `{:review, …}` 结果里的 `%{open:, drop:}`）。`day` 是这次回顾的游戏日（开的日号），
  `at_ms` 是落栏那一刻的时钟（新任务的当头步从此刻计时，经历的时刻）。

  先按 id 关掉 `drop`（结果 `dropped`），再按次序开新任务：`id = "t<day>:<开过的总数>"`
  （`counts.opened` 只增，id 不会与已关的重）、`expires_day = day + 2`，其余字段取初值（形状见 moduledoc）。
  校验时 `drop` 里的 id 都开着，但回顾在途期间它可能已被 `tick/3` 到期关掉：落栏时已不在 `open` 的 id 跳过（不再写“弃”）。
  返回 `{新的持久行, 经历}`：弃的各一句、开的各一句（`I set myself a task: "<goal>".`），弃在前。
  """
  @spec review(tasks(), %{open: [map()], drop: [String.t()]}, integer(), integer()) ::
          {tasks(), [episode()]}
  def review(tasks, %{open: opened, drop: drop}, day, at_ms) do
    {tasks, dropped} =
      Enum.reduce(drop, {tasks, []}, fn id, {tasks, episodes} ->
        case Enum.find(tasks["open"], &(&1["id"] == id)) do
          nil ->
            {tasks, episodes}

          task ->
            {tasks, episode} = close(tasks, task, "dropped", day, at_ms)
            {tasks, episodes ++ [episode]}
        end
      end)

    Enum.reduce(opened, {tasks, dropped}, fn %{"goal" => goal, "why" => why, "steps" => steps},
                                             {tasks, episodes} ->
      seq = tasks["counts"]["opened"] + 1

      task = %{
        "id" => "t#{day}:#{seq}",
        "goal" => goal,
        "why" => why,
        "opened_day" => day,
        "expires_day" => day + @expire_days,
        "steps" => steps,
        "log" => [],
        "waiting" => nil,
        "head_since_ms" => at_ms,
        "head_failures" => 0,
        "rejected_in_row" => 0,
        "completed" => 0,
        "note" => nil
      }

      tasks = %{
        tasks
        | "open" => tasks["open"] ++ [task],
          "counts" => bump(tasks["counts"], "opened")
      }

      {tasks, episodes ++ [episode(task, "opened", ~s|I set myself a task: "#{goal}".|, at_ms)]}
    end)
  end

  # --- 步骤记账与 K-3 分类 ---

  @doc """
  一项活动结束时记账（Life 在接纳活动经历的同一次保存里调；`done` 是 `Selector.experience/1` 的 `{kind, object}`，`outcome` 是它的
  结构化结局 `:completed | {:failed, 动作, 原因} | {:interrupted, 原因}`，`at_ms` 是 Life 接纳那一刻的时钟）。

  只看开着的任务的**当头步**：先找当头步恰为 `{kind, object}` 的，再找当头步种类相同、没点名的（对谁都成立，同
  `DayPlan.record_activity/4` 的点名优先）；各取最早开的一个。不经 Selector 传任务 id——碰巧做了同一件事也算数（决策稿 K-2）。
  记进 log 的是当头步本身的种类与对象；分类见 moduledoc 的 K-3 表。没有匹配的当头步原样返回。
  """
  @spec record_step(tasks(), {String.t(), term()}, term(), integer()) :: tasks()
  def record_step(tasks, {kind, object}, outcome, at_ms) do
    case head_match(tasks["open"], kind, object) do
      nil -> tasks
      index -> update_open(tasks, index, &step(&1, outcome, at_ms))
    end
  end

  # 点名相同的先取，再取没点名的；同一组里列表次序（开的次序）靠前的即最早开的。
  defp head_match(open, kind, object) do
    indexed = Enum.with_index(open)

    Enum.find_value([object, nil], fn named ->
      Enum.find_value(indexed, fn
        {%{"steps" => [%{"kind" => ^kind, "object" => ^named} | _]}, index} -> index
        _ -> nil
      end)
    end)
  end

  defp step(%{"steps" => [head | rest]} = task, :completed, at_ms) do
    task = log(task, head, "completed", nil, nil, at_ms)

    task = %{
      task
      | "steps" => rest,
        "completed" => task["completed"] + 1,
        "head_failures" => 0,
        "head_since_ms" => at_ms,
        "waiting" => resolved(task["waiting"])
    }

    if rest == [], do: wait(task, "steps_done"), else: task
  end

  defp step(%{"steps" => [head | _]} = task, {:failed, act, reason}, at_ms) do
    failures = task["head_failures"] + 1

    task =
      %{log(task, head, "failed", act, reason, at_ms) | "head_failures" => failures}
      |> Map.put("head_since_ms", at_ms)

    if transient?(reason) and failures < @transient_tolerance,
      do: task,
      else: wait(task, "failed")
  end

  defp step(%{"steps" => [head | _]} = task, {:interrupted, reason}, at_ms),
    do: %{log(task, head, "interrupted", nil, reason, at_ms) | "head_since_ms" => at_ms}

  defp log(task, head, outcome, act, reason, at_ms) do
    entry = %{
      "kind" => head["kind"],
      "object" => head["object"],
      "outcome" => outcome,
      "act" => act,
      "reason" => reason,
      "at_ms" => at_ms
    }

    %{task | "log" => Enum.take(task["log"] ++ [entry], -@log_size)}
  end

  # 瞬态原因与 Settler 同一口径（唯一定义 `NpcServer.Trees.transient_reasons/0`）；树报给选择器的原因是字符串。
  defp transient?(reason),
    do: reason in Enum.map(NpcServer.Trees.transient_reasons(), &Atom.to_string/1)

  # 待推进：已在等的不改原因。
  defp wait(%{"waiting" => nil} = task, reason), do: %{task | "waiting" => reason}
  defp wait(task, _reason), do: task

  # 当头步成功前移时：偏差（failed / stalled）已被化解，清掉；新信息（heard / event）不是做成一步化解得了的，留着。
  defp resolved(waiting) when waiting in ["failed", "stalled"], do: nil
  defp resolved(waiting), do: waiting

  @doc """
  任务里点名的人：待做步骤与 log 里对象为 `%{"actor" => cid}` 的 cid（去重，先步骤后 log）。K-3 的“任务里的人”
  （`note_news/3`）与 Life 展开可点名的人（`NpcServer.Life` 的词表，决策稿 K-0 评审第 8 条）共用这一处。
  """
  @spec people(map()) :: [integer()]
  def people(task) do
    for(%{"object" => %{"actor" => cid}} <- task["steps"] ++ task["log"], do: cid)
    |> Enum.uniq()
  end

  @doc """
  K-3 的两行新信息：`cid` 是对我说话的人（`reason = "heard"`）或 `kind:event` 经历的出手者（`"event"`）。他落在某个开着的任务的
  `people/1` 里、且那个任务没在等时，置 `waiting = reason`；其余原样。只读 Life 已有的结构化字段（叫的是我的说话消息的 `speaker_id`，口径 `NpcServer.Dialogue.direct?/2`；
  World 经历的 `actor`），不解析文字。
  """
  @spec note_news(tasks(), integer(), String.t()) :: tasks()
  def note_news(tasks, cid, reason) do
    open =
      for task <- tasks["open"] do
        if cid in people(task), do: wait(task, reason), else: task
      end

    %{tasks | "open" => open}
  end

  # --- 时钟：到期、停滞 ---

  @doc """
  每帧观察上查（常数级：至多 3 个任务）。`day` 是此刻的游戏日，`now_ms` 是 Life 的时钟。

  - 过了到期日（`day > expires_day`）：关为 `expired`，写一句经历（不问模型）。
  - 当头步从 `head_since_ms` 起满 6 游戏小时（按 `MmoContracts.WorldTime.game_us/1` 换算）且没在等：待推进 `stalled`。

  返回 `{新的持久行, 经历}`；没有任何变化时返回的就是传进来的那一个（Life 据此不写库）。
  """
  @spec tick(tasks(), integer(), integer()) :: {tasks(), [episode()]}
  def tick(tasks, day, now_ms) do
    {tasks, episodes} =
      tasks["open"]
      |> Enum.filter(&(day > &1["expires_day"]))
      |> Enum.reduce({tasks, []}, fn task, {tasks, episodes} ->
        {tasks, episode} = close(tasks, task, "expired", day, now_ms)
        {tasks, episodes ++ [episode]}
      end)

    open = Enum.map(tasks["open"], &stall(&1, now_ms))
    if open == tasks["open"], do: {tasks, episodes}, else: {%{tasks | "open" => open}, episodes}
  end

  defp stall(%{"waiting" => nil, "steps" => [_ | _]} = task, now_ms) do
    elapsed = WorldTime.game_us(now_ms * 1000) - WorldTime.game_us(task["head_since_ms"] * 1000)
    if elapsed >= @stall_game_us, do: wait(task, "stalled"), else: task
  end

  defp stall(task, _now_ms), do: task

  # --- 推进（K-4、K-9；T-1b） ---

  @doc """
  此刻该推进哪个任务：距上一次推进调用（`"last_at_ms"`，`admit/3` 记）不足 3 分钟一律 nil；否则开着的任务里**最早开的**、
  `waiting` 非空的那个的 id，没有为 nil。一次只推进一个（决策稿 K-3 写“最早置上”，这里用开的次序代替，不另记置上的时刻；规划偏差 D-3）。
  排在前面的任务只有等待清掉或任务关掉才让位：采用清掉等待；被拒至多 3 次就关为 stuck；但写作失败（`fail/1`）与 stale 都把等待
  留着，所以写作一直失败时，最早开的那个任务会一直排在最前，后开的在等的任务轮不到。
  """
  @spec due(tasks(), integer()) :: String.t() | nil
  def due(%{"last_at_ms" => last} = tasks, now_ms) do
    if last != nil and now_ms - last < @min_gap_ms,
      do: nil,
      else: Enum.find_value(tasks["open"], &(&1["waiting"] && &1["id"]))
  end

  @doc """
  今天还能不能再起一次推进写作：每人每游戏日 12 次（`calls`，规则同日计划的 `DayPlan.admit/3`，共用 `DayPlan.charge_call/3`），
  放行给 `{:ok, 记了一次调用、记了 last_at_ms 的持久行}`，到顶给 `{:error, :day_budget_exhausted}`。调用在**起调用时**就记；
  写作没有发出的由 `refund/1` 退回。**T-3 的学习写作与推进共用这一个计数**（决策稿 K-9：推进与学习共用 12 次），届时同样经本函数记账。
  `waiting` 不清：只有采用（`adopt/6`）清它，被拒、失败、stale、花费到线都留着。
  """
  @spec admit(tasks(), integer(), integer()) :: {:ok, tasks()} | {:error, :day_budget_exhausted}
  def admit(tasks, day, now_ms) do
    with {:ok, calls} <- DayPlan.charge_call(tasks["calls"], day, @day_calls) do
      {:ok, %{tasks | "calls" => calls, "last_at_ms" => now_ms}}
    end
  end

  @doc "把一次**没有发出写作请求**的推进从当日额度里退回（前提与理由同 `DayPlan.refund/1`：额度管“问了模型几次”）。"
  @spec refund(tasks()) :: tasks()
  def refund(tasks), do: %{tasks | "calls" => DayPlan.refund_call(tasks["calls"])}

  @doc """
  起推进时的基准：任务 `id`（此刻开着，`due/2` 给的）的待做步骤与完成步数。Life 存进推进槽，落栏时原样交给 `adopt/6` 比对
  （“比对后采用”，见 moduledoc 的“推进”）。
  """
  @spec basis(tasks(), String.t()) :: %{String.t() => term()}
  def basis(tasks, id), do: Map.take(find_open(tasks, id), @basis_keys)

  @doc """
  采用一份合格的推进应答（`check/3` 的 `:advance` 结果）。`id` 是起推进时的任务，`basis` 是起推进时 `basis/2` 的结果，
  `day` 是起推进的游戏日（关掉时的 `closed_day`），`at_ms` 是落栏那一刻。返回 `{结局, 新的持久行, 经历}`，结局：

  - `:adopted`：任务还开着、`steps` 与 `completed` 都与基准相同。计数 `advanced + 1`（不论哪种决定）；写了 `cannot` 另 `cannot + 1`
    （交学习属 T-3，这里只计数，原文由 Life 进日志；D-8）。
    - `continue`：待做步骤整份换成新的（可为空：只写了 `cannot`），`note` 存进任务（D-5），清 `waiting`，`rejected_in_row` 与
      `head_failures` 清零，当头步从此刻计时。
    - `done` / `drop`：关为 `done` / `dropped`，`note` 进小结；经历是标准句后接 `note`。
  - `:stale`：任务还开着，但写作在途时 `steps` 或 `completed` 变了（当头步做成前移）。不采用：任务原样，只 `stale + 1`，无经历。
  - `:gone`：推进在途时任务已被关掉（到期）。原样返回、不计数。
  """
  @spec adopt(tasks(), String.t(), map(), advanced(), integer(), integer()) ::
          {:adopted | :stale | :gone, tasks(), [episode()]}
  def adopt(tasks, id, basis, checked, day, at_ms) do
    case find_open(tasks, id) do
      nil ->
        {:gone, tasks, []}

      task ->
        if Map.take(task, @basis_keys) == basis do
          {tasks, episodes} = apply_advance(tasks, task, checked, day, at_ms)
          {:adopted, tasks, episodes}
        else
          {:stale, %{tasks | "counts" => bump(tasks["counts"], "stale")}, []}
        end
    end
  end

  defp apply_advance(tasks, task, checked, day, at_ms) do
    %{task: verdict, steps: steps, cannot: cannot, note: note} = checked
    counts = bump(tasks["counts"], "advanced")
    tasks = %{tasks | "counts" => if(cannot, do: bump(counts, "cannot"), else: counts)}

    case verdict do
      :continue ->
        task = %{
          task
          | "steps" => steps,
            "note" => note,
            "waiting" => nil,
            "rejected_in_row" => 0,
            "head_failures" => 0,
            "head_since_ms" => at_ms
        }

        {replace_open(tasks, task), []}

      closing ->
        result = if closing == :done, do: "done", else: "dropped"
        {tasks, episode} = close(tasks, %{task | "note" => note}, result, day, at_ms, note)
        {tasks, [episode]}
    end
  end

  @doc """
  推进应答没过 `check/3`：`rejected + 1`，任务不动、`waiting` 留着，`rejected_in_row + 1`；连续第 3 次关为 `stuck` 并给一句经历（K-4）。
  返回 `{新的持久行, 经历}`。任务已被关掉则原样返回。
  """
  @spec reject(tasks(), String.t(), integer(), integer()) :: {tasks(), [episode()]}
  def reject(tasks, id, day, at_ms) do
    case find_open(tasks, id) do
      nil ->
        {tasks, []}

      task ->
        task = %{task | "rejected_in_row" => task["rejected_in_row"] + 1}
        tasks = %{tasks | "counts" => bump(tasks["counts"], "rejected")}

        if task["rejected_in_row"] >= @stuck_after do
          {tasks, episode} = close(tasks, task, "stuck", day, at_ms)
          {tasks, [episode]}
        else
          {replace_open(tasks, task), []}
        end
    end
  end

  @doc "推进写作失败（写作接口失败、取材失败、worker 崩溃）：`failed + 1`，任务不动、`waiting` 留着（同日计划的失败口径）。"
  @spec fail(tasks()) :: tasks()
  def fail(tasks), do: %{tasks | "counts" => bump(tasks["counts"], "failed")}

  @doc "回顾与推进每次写作的出向上限（K-9：4096；Life 起槽时交给写作接口，反思等其它写作不受影响）。"
  @spec write_max_tokens() :: pos_integer()
  def write_max_tokens, do: @write_max_tokens

  defp find_open(tasks, id), do: Enum.find(tasks["open"], &(&1["id"] == id))

  defp replace_open(tasks, task),
    do: %{
      tasks
      | "open" => Enum.map(tasks["open"], &if(&1["id"] == task["id"], do: task, else: &1))
    }

  # --- 关闭 ---

  # 把一个开着的任务关掉：移出 open，小结进 closed（留最近 5 条），计数，给一句经历（推进的 done / drop 在标准句后接模型写的 note）。
  defp close(tasks, task, result, day, at_ms, note \\ nil) do
    summary = %{
      "id" => task["id"],
      "goal" => task["goal"],
      "result" => result,
      "note" => task["note"],
      "closed_day" => day,
      "completed" => task["completed"]
    }

    tasks = %{
      tasks
      | "open" => Enum.reject(tasks["open"], &(&1["id"] == task["id"])),
        "closed" => Enum.take(tasks["closed"] ++ [summary], -@closed_size),
        "counts" => bump(tasks["counts"], result)
    }

    text = String.replace(@closing_sentences[result], "<goal>", task["goal"])
    text = if note, do: text <> " " <> note, else: text
    {tasks, episode(task, result, text, at_ms)}
  end

  # 一条任务经历：id 唯一（任务 id + 事件），tags 是 `kind:task` 加任务里的人（召回按人调得到）。
  defp episode(task, event, text, at_ms),
    do: %{
      "id" => "task:#{task["id"]}:#{event}",
      "at_ms" => at_ms,
      "text" => text,
      "tags" => ["kind:task" | Enum.map(people(task), &"actor:#{&1}")]
    }

  defp update_open(tasks, index, fun),
    do: %{tasks | "open" => List.update_at(tasks["open"], index, fun)}

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  # --- 给 Mind 的栏 ---

  @doc """
  给 Mind 的数据（`Plans and promises` 栏的任务行，决策稿 K-6）：开着的任务各一项 `%{goal:, next: 当头步 | nil, completed: 完成的步数}`，
  开的次序。只给数据，怎么写由 Mind 定（不写该选什么）。
  """
  @spec column(tasks()) :: [%{goal: String.t(), next: step() | nil, completed: non_neg_integer()}]
  def column(tasks) do
    for task <- tasks["open"],
        do: %{goal: task["goal"], next: List.first(task["steps"]), completed: task["completed"]}
  end

  # --- 唯一校验点 ---

  @doc """
  校验一份写作应答的整段正文（至多去一对 ``` 围栏，整段必须是一个 JSON 对象）。`vocabulary` 是展开后的词表
  `%{种类 => %{显示名 => 对象}}`。第三个参数说明这是哪一种应答：

  **`:advance`（推进，K-4）**：键恰为 `task` / `steps` / `cannot` / `note`。`task` 是 `"continue" | "done" | "drop"`；
  `steps` 是列表、至多 3 条，每条键为 `activity`、`why`，可另有 `object`（同日计划意图的核对）；`cannot` 是 null 或
  `{"want", "why"}`；`note` 是非空字符串。`continue` 时步骤非空或 `cannot` 非空；`done` / `drop` 时两者皆空。
  合格给 `{:ok, %{task: 原子, steps: [%{"kind", "object", "why"}], cannot: nil | map, note: 原文}}`。

  **`{:review, now_minute, open}`（每日回顾，K-5）**：键恰为 `intents` / `cannot_yet` / `tasks`。前两张表交
  `DayPlan.check_lists/3`（意图的 `by` 要严格晚于 `now_minute`、两表合计至多 5 条）；`tasks` 是对象，键恰为 `open` / `drop`：
  `open` 每条键恰为 `goal` / `why` / `steps`，`goal`、`why` 非空，步骤 1–3 条；`drop` 每条是 `open`（此刻开着的任务列表，
  每个带 `"id"`）里的一个 id，同一 id 写多次只算一次；开着的数 − 弃的数（去重后）+ 新开的数 ≤ 3。
  合格给 `{:ok, %{intents:, wants:, tasks: %{open: [%{"goal", "why", "steps"}], drop: [id（去重、保持首次出现的次序）]}}}`。
  这是 Life 规划槽（每日回顾）唯一的检查（`NpcServer.Life.DayPlan.Round`）。

  不合格给 `{:error, 原因}`，原因：

      :not_json | :not_object | {:missing_key, 键} | {:unknown_key, 键} | {:not_a_list, 键}
      推进：{:bad_task, 值} | :bad_note | :nothing_to_continue | {:steps_on_close, task} | {:cannot_on_close, task}
            cannot 的错误同 `DayPlan.check_want/1`（:want_not_object、{:want_missing_key, 键} …）
      步骤：:step_not_object | {:step_missing_key, 键} | {:step_unknown_key, 键} | :bad_step_why | {:too_many_steps, n}
            {:unknown_activity, 值} | {:unknown_object, 种类, 值}（同 `DayPlan.check_kind/3`）
      回顾：意图 / cannot_yet 的错误同 `DayPlan.check_lists/3`；:tasks_not_object | {:tasks_missing_key, 键} | {:tasks_unknown_key, 键}
            :task_not_object | {:task_missing_key, 键} | {:task_unknown_key, 键} | :bad_goal | :bad_task_why | :task_without_steps
            {:unknown_task, id} | {:too_many_open, n}

  本函数只给检查结果，采用在调用方（回顾 `review/4`；推进 `adopt/6` / `reject/4`）。
  """
  @spec check(String.t(), vocabulary(), :advance | {:review, non_neg_integer(), [map()]}) ::
          {:ok, advanced() | reviewed()} | {:error, term()}
  def check(text, vocabulary, :advance) when is_binary(text) and is_map(vocabulary) do
    with {:ok, answer} <- DayPlan.decode(text),
         :ok <- DayPlan.check_keys(answer, @advance_keys, :missing_key, :unknown_key),
         {:ok, task} <- verdict(answer["task"]),
         {:ok, steps} <- check_steps(answer, vocabulary),
         {:ok, cannot} <- check_cannot(answer["cannot"]),
         :ok <- DayPlan.check_text(answer["note"], :bad_note),
         :ok <- check_shape(answer["task"], task, steps, cannot) do
      {:ok, %{task: task, steps: steps, cannot: cannot, note: answer["note"]}}
    end
  end

  def check(text, vocabulary, {:review, now_minute, open})
      when is_binary(text) and is_map(vocabulary) do
    with {:ok, answer} <- DayPlan.decode(text),
         :ok <- DayPlan.check_keys(answer, @review_keys, :missing_key, :unknown_key),
         {:ok, plan} <- DayPlan.check_lists(answer, vocabulary, now_minute),
         {:ok, tasks} <- check_tasks(answer["tasks"], vocabulary, open) do
      {:ok, Map.put(plan, :tasks, tasks)}
    end
  end

  # --- 推进 ---

  defp verdict(value) do
    case Map.fetch(@verdicts, value) do
      {:ok, task} -> {:ok, task}
      :error -> {:error, {:bad_task, value}}
    end
  end

  defp check_cannot(nil), do: {:ok, nil}
  defp check_cannot(cannot), do: DayPlan.check_want(cannot)

  # continue 要有可做的（步骤或交学习的 cannot）；done / drop 关掉任务，两者都不许带。
  defp check_shape(_raw, :continue, [], nil), do: {:error, :nothing_to_continue}
  defp check_shape(_raw, :continue, _steps, _cannot), do: :ok
  defp check_shape(raw, _closing, [_ | _], _cannot), do: {:error, {:steps_on_close, raw}}
  defp check_shape(raw, _closing, [], %{}), do: {:error, {:cannot_on_close, raw}}
  defp check_shape(_raw, _closing, [], nil), do: :ok

  # --- 回顾 ---

  defp check_tasks(%{} = tasks, vocabulary, open) do
    with :ok <- DayPlan.check_keys(tasks, @tasks_keys, :tasks_missing_key, :tasks_unknown_key),
         {:ok, raw_opened} <- DayPlan.fetch_list(tasks, "open"),
         {:ok, raw_drop} <- DayPlan.fetch_list(tasks, "drop"),
         {:ok, opened} <- DayPlan.check_each(raw_opened, &check_opened(&1, vocabulary)),
         {:ok, drop} <- DayPlan.check_each(raw_drop, &check_drop(&1, open)),
         # 同一 id 写两次也只弃掉一个任务：按 id 去重后再数（评审反例）。
         drop = Enum.uniq(drop),
         :ok <- check_open_count(length(open) - length(drop) + length(opened)) do
      {:ok, %{open: opened, drop: drop}}
    end
  end

  defp check_tasks(_not_object, _vocabulary, _open), do: {:error, :tasks_not_object}

  defp check_opened(%{} = task, vocabulary) do
    with :ok <- DayPlan.check_keys(task, @opened_keys, :task_missing_key, :task_unknown_key),
         :ok <- DayPlan.check_text(task["goal"], :bad_goal),
         :ok <- DayPlan.check_text(task["why"], :bad_task_why),
         {:ok, steps} <- check_steps(task, vocabulary),
         :ok <- if(steps == [], do: {:error, :task_without_steps}, else: :ok) do
      {:ok, %{"goal" => task["goal"], "why" => task["why"], "steps" => steps}}
    end
  end

  defp check_opened(_not_object, _vocabulary), do: {:error, :task_not_object}

  defp check_drop(id, open) do
    if Enum.any?(open, &(&1["id"] == id)), do: {:ok, id}, else: {:error, {:unknown_task, id}}
  end

  defp check_open_count(n) when n <= @max_open, do: :ok
  defp check_open_count(n), do: {:error, {:too_many_open, n}}

  # --- 步骤（推进与回顾共用） ---

  # `holder` 里的 `steps`：列表、逐条核对、至多 3 条（数条数在逐条之后，同 `DayPlan.check_lists/3` 的次序）。
  defp check_steps(holder, vocabulary) do
    with {:ok, raw} <- DayPlan.fetch_list(holder, "steps"),
         {:ok, steps} <- DayPlan.check_each(raw, &check_step(&1, vocabulary)) do
      if length(steps) <= @max_steps,
        do: {:ok, steps},
        else: {:error, {:too_many_steps, length(steps)}}
    end
  end

  defp check_step(%{} = step, vocabulary) do
    with :ok <-
           DayPlan.check_keys(
             step,
             @step_keys,
             :step_missing_key,
             :step_unknown_key,
             @step_optional_keys
           ),
         {:ok, object} <- DayPlan.check_kind(step["activity"], step["object"], vocabulary),
         :ok <- DayPlan.check_text(step["why"], :bad_step_why) do
      {:ok, %{"kind" => step["activity"], "object" => object, "why" => step["why"]}}
    end
  end

  defp check_step(_not_object, _vocabulary), do: {:error, :step_not_object}
end
