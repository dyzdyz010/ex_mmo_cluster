defmodule NpcServer.Life.DayPlan do
  @moduledoc """
  日计划的纯函数核心（实现设计 `docs/10-active/cross-cutting/2026-11-15-npc-day-plan-implementation.md` §1、§2，决策稿
  `2026-11-14-npc-day-plan-decision.md`）：规划应答的检查、规划调用额度与触发判定、采用一份计划、活动记账、给 Mind 的栏。
  不做 I/O、不依赖进程、不读时钟（日号、日内分钟、毫秒时刻都由参数给）；要进 Life 持久行 `"plan"` 的数据都是字符串键的
  普通 map，能原样过 JSON。写法同 `NpcServer.Life.Reflection`。

  ## 计划是什么

  一份计划是“今天我打算做几件事”：每条**意图**是 `种类 + 可选对象 + 次数 + 时限`（`by` 是日内分钟）。种类只能取该 NPC 的
  词表（稿 A §4 A-5，批 0b）：不对人的登记项各是一个**静态种类**（种类名就是候选名，没有对象）；对人的登记项（如 `confront`）
  由生成器按人展开、可点名，各是一个对象为人的种类（种类名 = 登记名，任务层稿 §7 ①）；配了说话时另有生成的种类 `speak_to`
  （对象是一个人）；种类的来源是 `NpcServer.Offers.plan_kinds/1`，对象由 Life 起规划槽时从关系与观察展开成
  `%{显示名 => 对象}`（显示名用名字层 `Life.State.person/2`，对象如 `%{"actor" => cid}`）。逐轮变的候选名（`speak_to:<cid>`、
  `confront:<cid>`）不是种类，写不进计划。词表写不出的想法记在 `wants`（想做而现在做不到的事），由下一次规划的模型留或撤。
  计划不新增任何动作，只是把“想做什么”记下来，让选择看得见。

  ```mermaid
  flowchart LR
    K["Offers.plan_kinds/1<br/>种类 + objects: :none | :people"] --> V["Life 展开对象<br/>%{种类 => %{显示名 => 对象}}"]
    V --> C["check/3<br/>意图：activity = 种类，object = 显示名 | 缺 | null"]
    C --> P["持久行 intents<br/>object 存对象本身（或 nil）"]
    E["活动经历 {种类, 对象}"] --> R["record_activity/4<br/>种类相同：点名相同的优先，再没点名的"]
    R --> P
  ```

  ## 谁写什么（不变量）

  - `done`（已完成次数）只由代码按活动结果增（`record_activity/4`，只记完成的、不记失败的）；模型只在规划调用里写意图与留 / 撤 `wants`。
  - 意图的状态不存，读时由代码推（`status/3`）：`done >= times` → `:done`；否则日号已过或此刻分钟 > `by` → `:missed`；否则 `:open`。
  - 规划失败（写作失败、检查不过）不挡选择：行里沿用上一份，只记一笔计数与 `last`（`fail/5`）。

  ## 调用流程

      观察 / 经历到来 → due/3（该不该规划）→ admit/3（今天还有额度吗）→（调用方起写作调用）→ check/3（应答合格吗）
        → 合格：adopt/6；不合格或写作失败：fail/5；写作之前就失败：fail/5 再 refund/1；到点而当日额度用完：skip/1
      活动结束 → record_activity/4；经历是 event 类 → note_event/1；选择之前 → column/3（给 Mind 的栏）

  槽在途、没有观察时调用方根本不查 `due/3`，所以不计 `skipped`（触发是逐帧查的，那样记会随帧数增长）。

  ## `event_waiting` 的生命周期

  `note_event/1` 置真；`admit/3` 放行时清掉——这次调用的材料在起调用那一刻取，已经含了那条 event。调用在途时又来的 event
  再置真，`adopt/6` 不碰它，所以落栏之后过了最小间隔还会因它重排。`:event` 调用失败（`fail/5`）把它恢复为真（这次重排没成，
  条件留到下次）；`:day` 失败不恢复（日号没采用过，`due/3` 本来就再给 `:day`）。

  ## 持久行 `"plan"`（`new/0`）

      "day"           当前意图属于哪个游戏日（nil 表示还没采用过）
      "intents"       [%{"id", "activity", "object", "times", "by", "why", "done"}]，by 为日内分钟（0..1439），id 为 "<日号>:<序号>"；
                      activity 是种类，object 是对象（如 %{"actor" => cid}）或 nil。批 0b 之前存下的意图没有 "object" 键，
                      读作 nil（不迁移）
      "wants"         [%{"want", "why"}]
      "calls"         %{"day", "n"}：本游戏日发出了写作请求的规划调用数（起调用时 admit/3 先记；落栏时写作没有发出的
                      由 refund/1 退回；崩溃不退、不重置；跨日清零）
      "event_waiting" 有一条 event 经历进来、等着触发重排（生命周期见上）
      "last_at_ms"    上一次规划调用的时钟（防连发的最小间隔用；起调用时 admit/3 就记，采用与失败再记一次）
      "last"          nil | %{"at_ms", "kind" => "day" | "event", "result" => "adopted" | "failed" | "rejected", "reason"}
      "counts"        %{"planned", "replanned", "failed", "rejected", "skipped"}

  ## 原创取值（实跑后调）

  每游戏日 5 次发出了写作请求的规划调用（`@day_calls`，决策稿：规划加重排共计；写作之前就失败的不算，见 `refund/1`）、
  两次调用至少隔 3 分钟（`@min_gap_ms`，写作之前就失败的也算间隔）、
  条目总数上限 8（`@max_intents`，防计划无限增长；`check/3` 本身限一次至多 5 条，`@cap`）。这些数都是原创取值，没有外部依据，
  实跑后调。

  ## 应答检查（`check/3`）

  检查 1–5 照离线测量 S1-R8（`.demo/observe/npc-slice1-20261112/s1r8/plan.md` 的“产品式检查”），`stop_reason` 的判断在调用方。
  单条核对（`decode/1`、`check_keys/5`、`check_lists/3`、`check_kind/3`、`check_want/1`、`check_text/2` 等）是公开的：任务层的唯一校验点
  `NpcServer.Life.Tasks.check/3` 调用它们核对任务步与回顾应答（任务层决策稿 K-4“抽出单条核对函数共用，不另写一份”），所以日计划意图与任务步的
  种类 / 对象错误原因完全相同。
  `times` 必须是 JSON 整数（`2.0` 不算）、`by` 严格匹配 `HH:MM`，多余的键、缺的键、类型不对都不放行。
  失败原因是可直接写进日志的原子或元组，见 `check/3`。本模块只给检查结果，要不要重问由调用方决定。
  """

  # 一次规划至多写几条（意图与 wants 合计）：S1-R8 提示词里“At most five things in all”，原创取值。
  @cap 5
  # 一个游戏日的规划调用数（规划加重排共计）：决策稿的取值，原创，实跑后调。
  @day_calls 5
  # 两次规划调用的最小间隔（防连发）：原创取值，实跑后调。
  @min_gap_ms 3 * 60_000
  # 行里意图条数的上限：原创取值，实跑后调。
  @max_intents 8

  @by_pattern ~r/\A([01]\d|2[0-3]):([0-5]\d)\z/
  # 至多一对围栏：```（可带 json 标记）开头、``` 结尾，中间整段是 JSON。
  @fence_pattern ~r/\A```(?:json)?\s*(.*?)\s*```\z/s

  @intent_keys ["activity", "times", "by", "why"]
  # 意图里可缺的键：对象（可缺、可为 null，都是没点名）。
  @intent_optional_keys ["object"]
  @want_keys ["want", "why"]

  @type plan :: %{required(String.t()) => term()}
  @type checked :: %{intents: [map()], wants: [map()]}
  @type status :: :done | :missed | :open

  # --- 持久行 ---

  @doc "空的一份计划（持久行 `\"plan\"` 的初值）。"
  @spec new() :: plan()
  def new do
    %{
      "day" => nil,
      "intents" => [],
      "wants" => [],
      "calls" => %{"day" => nil, "n" => 0},
      "event_waiting" => false,
      "last_at_ms" => nil,
      "last" => nil,
      "counts" => %{
        "planned" => 0,
        "replanned" => 0,
        "failed" => 0,
        "rejected" => 0,
        "skipped" => 0
      }
    }
  end

  # --- 应答检查 ---

  @doc """
  检查写作接口给的整段正文：至多去一对 ``` 围栏（可带 `json` 标记）外，整段必须就是一个 JSON 对象，只有 `intents` / `cannot_yet`
  两个键，都是列表。

  `vocabulary` 是展开后的词表 `%{种类 => %{显示名 => 对象}}`（静态种类的对象表为空）。

  - 每条意图的键是 `activity`、`times`、`by`、`why`，另可有 `object`：`activity` 是 `vocabulary` 的一个种类（逐字）；`object`
    缺、为 null 都是没点名，否则必须逐字是该种类列出的显示名之一（静态种类不接受对象）；`times` 是 JSON 整数且 ≥ 1；
    `by` 严格匹配 `HH:MM`（`00:00`–`23:59`）且**严格晚于** `now_minute`；`why` 是非空字符串。
  - 每条 `cannot_yet` 的键恰为 `want`、`why`，都是非空字符串。
  - 两张表合计至多 5 条；数条数在逐条检查之后（同离线检查 5 排在 3、4 之后）。

  合格返回 `{:ok, %{intents: [...], wants: [...]}}`：意图是 `%{"activity", "object", "times", "by", "why"}`，`object` 已换成
  显示名对应的对象（没点名为 nil），`by` 已换成日内分钟，其余原样；wants 是 `%{"want", "why"}` 原样。不合格返回
  `{:error, 原因}`，原因：

      :not_json | :not_object
      {:missing_key, 键} | {:unknown_key, 键} | {:not_a_list, 键}
      :intent_not_object | {:intent_missing_key, 键} | {:intent_unknown_key, 键}
      {:unknown_activity, 值} | {:unknown_object, 种类, 值}
      {:bad_times, 值} | {:bad_by, 值} | {:by_not_after_now, "HH:MM"} | :bad_why
      :want_not_object | {:want_missing_key, 键} | {:want_unknown_key, 键} | :bad_want | :bad_want_why
      {:too_many_items, 总条数}
  """
  @spec check(String.t(), %{String.t() => %{String.t() => term()}}, non_neg_integer()) ::
          {:ok, checked()} | {:error, term()}
  def check(text, vocabulary, now_minute) when is_binary(text) and is_map(vocabulary) do
    with {:ok, object} <- decode(text),
         :ok <- check_keys(object, ["intents", "cannot_yet"], :missing_key, :unknown_key) do
      check_lists(object, vocabulary, now_minute)
    end
  end

  # --- 共用的单条核对（任务层 `NpcServer.Life.Tasks.check/3` 也用，不另写一份；任务层决策稿 K-4） ---

  @doc """
  应答正文 → JSON 对象：至多去一对 ``` 围栏（可带 `json` 标记），整段必须是一个 JSON 对象。
  `{:ok, map}` 或 `{:error, :not_json | :not_object}`。
  """
  @spec decode(String.t()) :: {:ok, map()} | {:error, :not_json | :not_object}
  def decode(text) do
    with {:ok, body} <- unfence(text), do: decode_object(body)
  end

  @doc """
  已解码的规划应答里的 `intents` 与 `cannot_yet` 两张表（顶层键已由调用方核过）：逐条核对、两张表合计至多 5 条，规则同 `check/3`。
  `{:ok, %{intents:, wants:}}` 或 `{:error, 原因}`（原因同 `check/3`）。
  """
  @spec check_lists(map(), %{String.t() => map()}, non_neg_integer()) ::
          {:ok, checked()} | {:error, term()}
  def check_lists(object, vocabulary, now_minute) do
    with {:ok, raw_intents} <- fetch_list(object, "intents"),
         {:ok, raw_wants} <- fetch_list(object, "cannot_yet"),
         {:ok, intents} <- check_each(raw_intents, &check_intent(&1, vocabulary, now_minute)),
         {:ok, wants} <- check_each(raw_wants, &check_want/1),
         :ok <- check_count(length(intents) + length(wants)) do
      {:ok, %{intents: intents, wants: wants}}
    end
  end

  defp unfence(text) do
    text = String.trim(text)

    case Regex.run(@fence_pattern, text) do
      [_, inner] -> {:ok, inner}
      nil -> {:ok, text}
    end
  end

  defp decode_object(body) do
    case Jason.decode(body) do
      {:ok, %{} = object} -> {:ok, object}
      {:ok, _other} -> {:error, :not_object}
      {:error, _} -> {:error, :not_json}
    end
  end

  @doc """
  一个 map 的键恰为 `expected` 加上可缺的 `optional`：先报缺的 `{missing_reason, 键}`、再报多的 `{unknown_reason, 键}`
  （各按确定的次序），都齐返回 `:ok`。
  """
  @spec check_keys(map(), [String.t()], atom(), atom(), [String.t()]) :: :ok | {:error, term()}
  def check_keys(map, expected, missing_reason, unknown_reason, optional \\ []) do
    keys = Map.keys(map)

    case {expected -- keys, Enum.sort(keys -- (expected ++ optional))} do
      {[missing | _], _} -> {:error, {missing_reason, missing}}
      {[], [unknown | _]} -> {:error, {unknown_reason, unknown}}
      {[], []} -> :ok
    end
  end

  @doc "取一个必定存在的键，值必须是列表：`{:ok, 列表}` 或 `{:error, {:not_a_list, 键}}`。"
  @spec fetch_list(map(), String.t()) :: {:ok, list()} | {:error, {:not_a_list, String.t()}}
  def fetch_list(object, key) do
    case Map.fetch!(object, key) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, {:not_a_list, key}}
    end
  end

  @doc "逐条核对，保序：全部 `{:ok, 结果}` 给 `{:ok, [结果]}`，否则给第一条的 `{:error, 原因}`。"
  @spec check_each(list(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, list()} | {:error, term()}
  def check_each(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, checked} -> {:cont, {:ok, [checked | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp check_intent(%{} = intent, vocabulary, now_minute) do
    with :ok <-
           check_keys(
             intent,
             @intent_keys,
             :intent_missing_key,
             :intent_unknown_key,
             @intent_optional_keys
           ),
         {:ok, object} <- check_kind(intent["activity"], intent["object"], vocabulary),
         :ok <- check_times(intent["times"]),
         {:ok, by} <- check_by(intent["by"], now_minute),
         :ok <- check_text(intent["why"], :bad_why) do
      {:ok, Map.merge(intent, %{"object" => object, "by" => by})}
    end
  end

  defp check_intent(_not_object, _vocabulary, _now), do: {:error, :intent_not_object}

  @doc """
  一条“种类 + 可选对象”按词表 `%{种类 => %{显示名 => 对象}}` 核对（日计划的意图与任务的步骤共用）：种类逐字是词表的一个键，
  否则 `{:unknown_activity, 值}`；对象缺（nil）即没点名，给 `{:ok, nil}`；写了就必须逐字是该种类列出的显示名之一，给
  `{:ok, 对应的对象}`，否则 `{:unknown_object, 种类, 值}`（静态种类的对象表为空，所以写了任何对象都不过）。
  """
  @spec check_kind(term(), term(), %{String.t() => map()}) :: {:ok, term()} | {:error, term()}
  def check_kind(kind, name, vocabulary) do
    with {:ok, objects} <- check_activity(kind, vocabulary),
         do: check_object(kind, name, objects)
  end

  # 种类在词表里：给出它的对象表（显示名 → 对象）。
  defp check_activity(kind, vocabulary) when is_binary(kind) do
    case Map.fetch(vocabulary, kind) do
      {:ok, objects} -> {:ok, objects}
      :error -> {:error, {:unknown_activity, kind}}
    end
  end

  defp check_activity(other, _vocabulary), do: {:error, {:unknown_activity, other}}

  # 对象可缺、可为 null（都是没点名）；写了就必须逐字是该种类列出的显示名之一，换成它对应的对象。
  defp check_object(_kind, nil, _objects), do: {:ok, nil}

  defp check_object(kind, name, objects) do
    case is_binary(name) && Map.fetch(objects, name) do
      {:ok, object} -> {:ok, object}
      _ -> {:error, {:unknown_object, kind, name}}
    end
  end

  defp check_times(times) when is_integer(times) and times >= 1, do: :ok
  defp check_times(other), do: {:error, {:bad_times, other}}

  defp check_by(by, now_minute) when is_binary(by) do
    case Regex.run(@by_pattern, by) do
      [_, hour, minute] ->
        minute_of_day = String.to_integer(hour) * 60 + String.to_integer(minute)

        if minute_of_day > now_minute,
          do: {:ok, minute_of_day},
          else: {:error, {:by_not_after_now, by}}

      nil ->
        {:error, {:bad_by, by}}
    end
  end

  defp check_by(other, _now_minute), do: {:error, {:bad_by, other}}

  @doc "非空字符串（去掉首尾空白后不空）给 `:ok`，否则 `{:error, reason}`。"
  @spec check_text(term(), term()) :: :ok | {:error, term()}
  def check_text(text, reason) do
    if is_binary(text) and String.trim(text) != "", do: :ok, else: {:error, reason}
  end

  @doc """
  一条“想做而写不出的事” `%{"want", "why"}`（日计划的 `cannot_yet`、任务推进的 `cannot` 同形）：键恰为这两个、都是非空字符串，
  原样给出；否则 `:want_not_object | {:want_missing_key, 键} | {:want_unknown_key, 键} | :bad_want | :bad_want_why`。
  """
  @spec check_want(term()) :: {:ok, map()} | {:error, term()}
  def check_want(%{} = want) do
    with :ok <- check_keys(want, @want_keys, :want_missing_key, :want_unknown_key),
         :ok <- check_text(want["want"], :bad_want),
         :ok <- check_text(want["why"], :bad_want_why) do
      {:ok, want}
    end
  end

  def check_want(_not_object), do: {:error, :want_not_object}

  defp check_count(n) when n <= @cap, do: :ok
  defp check_count(n), do: {:error, {:too_many_items, n}}

  # --- 规划调用：额度、触发 ---

  @doc """
  今天还能不能再起一次规划调用：当日 `calls.n < 5`（规划加重排共计）返回 `{:ok, 记了一次调用的 plan}`，跨日清零；
  否则 `{:error, :day_budget_exhausted}`（行不变）。调用在**起调用时**就记（这时还不知道写作会不会发出）；落栏时写作没有发出的
  由调用方 `refund/1` 退回，写作发出了的（不论成败）、worker 崩溃的都不退（见 `refund/1`）。

  放行时还：记 `last_at_ms = now_ms`——起调用就记而不是落栏才记，这样规划在途时 Life 重启、落栏那次保存失败之后，
  也至少隔最小间隔才再调用；清 `event_waiting`——这次调用的材料在起调用那一刻取，已含那条 event。
  """
  @spec admit(plan(), integer(), integer()) :: {:ok, plan()} | {:error, :day_budget_exhausted}
  def admit(plan, day, now_ms) do
    case plan["calls"] do
      %{"day" => ^day, "n" => n} when n >= @day_calls -> {:error, :day_budget_exhausted}
      %{"day" => ^day, "n" => n} -> {:ok, started(plan, day, n + 1, now_ms)}
      _other_day -> {:ok, started(plan, day, 1, now_ms)}
    end
  end

  defp started(plan, day, n, now_ms) do
    %{
      plan
      | "calls" => %{"day" => day, "n" => n},
        "last_at_ms" => now_ms,
        "event_waiting" => false
    }
  end

  @doc """
  此刻该不该起一次规划：`:day`（本游戏日还没有采用过计划）、`:event`（计划是今天的、且有一条 event 经历在等）或 nil。
  两者同时成立给 `:day`。距上一次规划调用（`"last_at_ms"`）不足 3 分钟一律 nil（条件保留，不清）；`"last_at_ms"` 为 nil 时不受间隔限制。
  """
  @spec due(plan(), integer(), integer()) :: :day | :event | nil
  def due(plan, day, now_ms) do
    cond do
      too_soon?(plan["last_at_ms"], now_ms) -> nil
      plan["day"] != day -> :day
      plan["event_waiting"] -> :event
      true -> nil
    end
  end

  defp too_soon?(nil, _now_ms), do: false
  defp too_soon?(last_at_ms, now_ms), do: now_ms - last_at_ms < @min_gap_ms

  @doc "有一条 event 经历进来了：记下，等着触发重排（`due/3` 给 `:event`）。"
  @spec note_event(plan()) :: plan()
  def note_event(plan), do: %{plan | "event_waiting" => true}

  # --- 采用 / 失败 / 跳过 ---

  @doc """
  采用一份检查合格的计划（`check/3` 的 `{:ok, checked}`），`kind` 是 `:day` 或 `:event`（触发它的原因），`at_ms` 是这次规划的时钟。

  同日重排：旧意图里已 `done` 与已 `missed`（按 `status/3`，用此刻的日号与分钟）的保留，open 的换成新的；跨日整份换。
  新意图 `id` 为 `"<日号>:<序号>"`（序号接着保留项里最大的往下排，同一份里不重复）、`done` 为 0。`wants` 整份换成新的。
  记 `last`、`last_at_ms` 与计数（`:day` → `planned`，`:event` → `replanned`）。不碰 `event_waiting`：起调用时 `admit/3`
  已清过，此刻若为真，是调用在途时新来的 event，这次的材料没看到它，要留着触发下一次重排。

  条目总数上限 8：保留项在前、新的在后，超出时丢最旧的保留项（保留项都是已结束的）。新意图至多 5 条（`check/3` 的上限）、
  小于上限 8，所以不会丢到新意图。
  """
  @spec adopt(plan(), integer(), non_neg_integer(), checked(), :day | :event, integer()) :: plan()
  def adopt(plan, day, now_minute, %{intents: intents, wants: wants}, kind, at_ms) do
    kept =
      if plan["day"] == day,
        do:
          Enum.filter(plan["intents"], &(status(plan, &1, {day, now_minute}) in [:done, :missed])),
        else: []

    first_seq = next_sequence(kept, day)

    fresh =
      for {intent, offset} <- Enum.with_index(intents, first_seq) do
        Map.merge(intent, %{"id" => "#{day}:#{offset}", "done" => 0})
      end

    %{
      plan
      | "day" => day,
        "intents" => Enum.take(kept ++ fresh, -@max_intents),
        "wants" => wants,
        "last_at_ms" => at_ms,
        "last" => %{
          "at_ms" => at_ms,
          "kind" => Atom.to_string(kind),
          "result" => "adopted",
          "reason" => nil
        },
        "counts" => bump(plan["counts"], if(kind == :day, do: "planned", else: "replanned"))
    }
  end

  defp next_sequence(kept, day) do
    prefix = "#{day}:"

    kept
    |> Enum.flat_map(fn %{"id" => id} ->
      case String.split(id, prefix, parts: 2) do
        ["", seq] -> [String.to_integer(seq)]
        _ -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  @doc """
  一次规划调用没有成功：`outcome` 是 `:failed`（写作失败、崩溃、超时）或 `:rejected`（应答没过 `check/3`），`reason` 记进 `last`
  （不是字符串的用 `inspect/1` 转成字符串，保证能过 JSON）。意图与 `wants` 不动（沿用上一份）；`last_at_ms` 记下，两次调用的
  最小间隔照算。`kind == :event` 时把 `event_waiting` 恢复为真（起调用时 `admit/3` 清掉了它，这次重排没成，条件留到下次）；
  `:day` 失败不恢复（日号没采用过，`due/3` 本来就再给 `:day`）。
  """
  @spec fail(plan(), :day | :event, :failed | :rejected, term(), integer()) :: plan()
  def fail(plan, kind, outcome, reason, at_ms) when outcome in [:failed, :rejected] do
    %{
      plan
      | "event_waiting" => plan["event_waiting"] or kind == :event,
        "last_at_ms" => at_ms,
        "last" => %{
          "at_ms" => at_ms,
          "kind" => Atom.to_string(kind),
          "result" => Atom.to_string(outcome),
          "reason" => if(is_binary(reason), do: reason, else: inspect(reason))
        },
        "counts" => bump(plan["counts"], Atom.to_string(outcome))
    }
  end

  @doc """
  把一次**没有发出写作请求**的规划调用从当日额度里退回：`calls.n` 减一。只动 `calls`：失败的记账（`fail/5` 记下的计数、`last`、
  `last_at_ms`、`event_waiting`）照旧，最小间隔照样从起调用那一刻算。

  不判日号、不设下限，因为调用方（Life 落栏）保证退回的就是 `calls` 里记着的那一次：规划槽在途时 Life 不查触发（要求槽空），
  不会有 `admit/3` 或 `skip/1` 改 `calls`；调用在途时 Life 重启，槽随进程没了、不落栏、不退回。所以落栏时 `calls` 仍是起调用
  那次 `admit/3` 记下的（日号就是起槽那天，`n ≥ 1`）。调用期间越过日界也一样：`calls` 还是起槽那天的，照常退回，下一帧观察的
  `admit/3` 按新日清零重计。

  额度管的是“问了模型几次”（T7，用户 2026-11-16 定）：实跑 S1-R10 里 8 次规划调用有 4 次在写作之前就失败（出生时没有材料、
  Hindsight 召回超时），照样各扣一次，当日额度很快用完。所以调用方在一次调用落栏时，结果说明写作没有发出（`Round.write/1` 的
  `wrote: false`）才调本函数；写作函数被调用过（不论成败）、worker 崩溃（不知道发没发出，按发出算，防额度被反复崩溃绕过）、
  调用在途时 Life 重启（结果随进程丢了，同理）都不退。起调用时 `admit/3` 照旧先记一次，退回只在落栏时发生。
  """
  @spec refund(plan()) :: plan()
  def refund(plan), do: update_in(plan, ["calls", "n"], &(&1 - 1))

  @doc """
  到点而当日额度用完（`admit/3` 拒绝）：只给 `counts.skipped` 加一，触发条件不清。槽在途、没有观察时调用方不查 `due/3`，
  不走这里、不计数。
  """
  @spec skip(plan()) :: plan()
  def skip(plan), do: %{plan | "counts" => bump(plan["counts"], "skipped")}

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  # --- 状态与记账 ---

  @doc """
  意图此刻的状态（读时由代码推，不存）：`done >= times` → `:done`；否则计划的日号已过、或此刻分钟 > `by` → `:missed`；否则 `:open`
  （恰在 `by` 那一分钟仍 `:open`）。`now` 是 `{此刻日号, 此刻日内分钟}`。
  """
  @spec status(plan(), map(), {integer(), non_neg_integer()}) :: status()
  def status(plan, %{"done" => done, "times" => times} = intent, {day, minute}) do
    cond do
      done >= times -> :done
      is_integer(plan["day"]) and plan["day"] < day -> :missed
      minute > intent["by"] -> :missed
      true -> :open
    end
  end

  @doc """
  一项活动**完成**（失败的不算，调用方不调）时记账。`done` 是完成的活动的 `{种类, 对象}`（`NpcServer.Selector.experience/1`
  的 `kind` 与 `object`），只看今天、种类相同、`:open` 的意图：

  1. **点名优先**：先在点名的就是这个对象的意图里取；
  2. 没有，再在没点名的意图（`object` 为 nil，或旧行没有这个键）里取。

  每一步都取 `by` 最早的一条 `done + 1`（`by` 并列取列表里靠前的）。点名优先是因为没点名的意图对谁都成立、点名的只对这个人
  成立：混在一起按时限取，会把对这个人做的事记到时限更早的没点名意图上，点名那条就白白落空（稿 A 批 0 评审）。
  找不到就原样返回，不报错；计划不是今天的（含还没采用过计划）也原样返回。`done` 不是 `{种类, 对象}` 是调用错误，
  直接 `FunctionClauseError`。
  """
  @spec record_activity(plan(), {String.t() | nil, term()}, integer(), non_neg_integer()) ::
          plan()
  def record_activity(%{"day" => day} = plan, {kind, object}, day, minute) do
    open =
      plan["intents"]
      |> Enum.with_index()
      |> Enum.filter(fn {intent, _index} ->
        intent["activity"] == kind and status(plan, intent, {day, minute}) == :open
      end)

    # 点名相同的先取，没有再取没点名的（对象为 nil 时两步是同一组）。
    case Enum.find([naming(open, object), naming(open, nil)], &(&1 != [])) do
      nil ->
        plan

      candidates ->
        {_intent, index} = Enum.min_by(candidates, fn {intent, _index} -> intent["by"] end)

        %{
          plan
          | "intents" => List.update_at(plan["intents"], index, &%{&1 | "done" => &1["done"] + 1})
        }
    end
  end

  def record_activity(plan, {_kind, _object}, _other_day, _minute), do: plan

  # 意图里点名的就是 `object` 的那些（`object` 为 nil 即没点名的；旧行没有 "object" 键，读作 nil）。
  defp naming(intents, object),
    do: Enum.filter(intents, fn {intent, _index} -> intent["object"] == object end)

  # --- 给 Mind 的栏 ---

  @doc """
  给 Mind 的数据：今天的各条意图 `%{activity, object, times, done, by, status}`（`activity` 是种类，`object` 是点名的对象或 nil，
  `by` 是日内分钟，`status` 此刻推出）与 `wants`
  （`%{"want", "why"}`，直到下一次规划换掉才撤）。计划不是今天的则意图为空列表；没有意图也没有 `wants` 返回 nil。
  只给数据，怎么渲染、是否点名该选什么由 Mind 决定。
  """
  @spec column(plan(), integer(), non_neg_integer()) :: %{intents: [map()], wants: [map()]} | nil
  def column(plan, day, minute) do
    intents =
      if plan["day"] == day,
        do:
          for(
            intent <- plan["intents"],
            do: %{
              activity: intent["activity"],
              object: intent["object"],
              times: intent["times"],
              done: intent["done"],
              by: intent["by"],
              status: status(plan, intent, {day, minute})
            }
          ),
        else: []

    case {intents, plan["wants"]} do
      {[], []} -> nil
      {intents, wants} -> %{intents: intents, wants: wants}
    end
  end
end
