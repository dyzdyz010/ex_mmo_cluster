defmodule NpcServer.Life.DayPlan do
  @moduledoc """
  日计划的纯函数核心（实现设计 `docs/10-active/cross-cutting/2026-11-15-npc-day-plan-implementation.md` §1、§2，决策稿
  `2026-11-14-npc-day-plan-decision.md`）：规划应答的检查、规划调用额度与触发判定、采用一份计划、活动记账、给 Mind 的栏。
  不做 I/O、不依赖进程、不读时钟（日号、日内分钟、毫秒时刻都由参数给）；要进 Life 持久行 `"plan"` 的数据都是字符串键的
  普通 map，能原样过 JSON。写法同 `NpcServer.Life.Reflection`。

  ## 计划是什么

  一份计划是“今天我打算做几件事”：每条**意图**是 `活动名 + 次数 + 时限`（`by` 是日内分钟），活动名只能取该 NPC 登记的词表
  （`profile.activities` 的 `name`，逐字）；词表写不出的想法记在 `wants`（想做而现在做不到的事），由下一次规划的模型留或撤。
  计划不新增任何动作，只是把“想做什么”记下来，让选择看得见。

  ## 谁写什么（不变量）

  - `done`（已完成次数）只由代码按活动结果增（`record_activity/4`，只记完成的、不记失败的）；模型只在规划调用里写意图与留 / 撤 `wants`。
  - 意图的状态不存，读时由代码推（`status/3`）：`done >= times` → `:done`；否则日号已过或此刻分钟 > `by` → `:missed`；否则 `:open`。
  - 规划失败（写作失败、检查不过）不挡选择：行里沿用上一份，只记一笔计数与 `last`（`fail/5`）。

  ## 调用流程

      观察 / 经历到来 → due/3（该不该规划）→ admit/2（今天还有额度吗）→（调用方起写作调用）→ check/3（应答合格吗）
        → 合格：adopt/6；不合格或写作失败：fail/5；到点却起不了：skip/1
      活动结束 → record_activity/4；经历是 event 类 → note_event/1；选择之前 → column/3（给 Mind 的栏）

  ## 持久行 `"plan"`（`new/0`）

      "day"           当前意图属于哪个游戏日（nil 表示还没采用过）
      "intents"       [%{"id", "activity", "times", "by", "why", "done"}]，by 为日内分钟（0..1439），id 为 "<日号>:<序号>"
      "wants"         [%{"want", "why"}]
      "calls"         %{"day", "n"}：本游戏日已发的规划调用数（起调用时就记，崩溃不重置，跨日清零）
      "event_waiting" 有一条 event 经历进来、等着触发重排
      "last_at_ms"    上一次规划调用的时钟（防连发的最小间隔用；采用与失败都记）
      "last"          nil | %{"at_ms", "kind" => "day" | "event", "result" => "adopted" | "failed" | "rejected", "reason"}
      "counts"        %{"planned", "replanned", "failed", "rejected", "skipped"}

  ## 原创取值（实跑后调）

  每游戏日 5 次规划调用（`@day_calls`，决策稿：规划加重排共计）、两次调用至少隔 3 分钟（`@min_gap_ms`）、
  条目总数上限 8（`@max_intents`，防计划无限增长；`check/3` 本身限一次至多 5 条，`@cap`）。这些数都是原创取值，没有外部依据，
  实跑后调。

  ## 应答检查（`check/3`）

  检查 1–5 照离线测量 S1-R8（`.demo/observe/npc-slice1-20261112/s1r8/plan.md` 的“产品式检查”），`stop_reason` 的判断在调用方。
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

  - 每条意图的键恰为 `activity`、`times`、`by`、`why`：`activity` 是 `activity_names` 里的一个（逐字）；`times` 是 JSON 整数且 ≥ 1；
    `by` 严格匹配 `HH:MM`（`00:00`–`23:59`）且**严格晚于** `now_minute`；`why` 是非空字符串。
  - 每条 `cannot_yet` 的键恰为 `want`、`why`，都是非空字符串。
  - 两张表合计至多 5 条；数条数在逐条检查之后（同离线检查 5 排在 3、4 之后）。

  合格返回 `{:ok, %{intents: [...], wants: [...]}}`：意图是 `%{"activity", "times", "by", "why"}`，`by` 已换成日内分钟，
  其余原样；wants 是 `%{"want", "why"}` 原样。不合格返回 `{:error, 原因}`，原因：

      :not_json | :not_object
      {:missing_key, 键} | {:unknown_key, 键} | {:not_a_list, 键}
      :intent_not_object | {:intent_missing_key, 键} | {:intent_unknown_key, 键}
      {:unknown_activity, 值} | {:bad_times, 值} | {:bad_by, 值} | {:by_not_after_now, "HH:MM"} | :bad_why
      :want_not_object | {:want_missing_key, 键} | {:want_unknown_key, 键} | :bad_want | :bad_want_why
      {:too_many_items, 总条数}
  """
  @spec check(String.t(), [String.t()], non_neg_integer()) :: {:ok, checked()} | {:error, term()}
  def check(text, activity_names, now_minute) when is_binary(text) do
    with {:ok, body} <- unfence(text),
         {:ok, object} <- decode_object(body),
         :ok <- check_keys(object, ["intents", "cannot_yet"], :missing_key, :unknown_key),
         {:ok, raw_intents} <- fetch_list(object, "intents"),
         {:ok, raw_wants} <- fetch_list(object, "cannot_yet"),
         {:ok, intents} <- check_each(raw_intents, &check_intent(&1, activity_names, now_minute)),
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

  # 键恰为 expected：先报缺的、再报多的（各按确定的次序）。
  defp check_keys(map, expected, missing_reason, unknown_reason) do
    keys = Map.keys(map)

    case {expected -- keys, Enum.sort(keys -- expected)} do
      {[missing | _], _} -> {:error, {missing_reason, missing}}
      {[], [unknown | _]} -> {:error, {unknown_reason, unknown}}
      {[], []} -> :ok
    end
  end

  defp fetch_list(object, key) do
    case Map.fetch!(object, key) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, {:not_a_list, key}}
    end
  end

  defp check_each(items, fun) do
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

  defp check_intent(%{} = intent, activity_names, now_minute) do
    with :ok <- check_keys(intent, @intent_keys, :intent_missing_key, :intent_unknown_key),
         :ok <- check_activity(intent["activity"], activity_names),
         :ok <- check_times(intent["times"]),
         {:ok, by} <- check_by(intent["by"], now_minute),
         :ok <- check_text(intent["why"], :bad_why) do
      {:ok, %{intent | "by" => by}}
    end
  end

  defp check_intent(_not_object, _names, _now), do: {:error, :intent_not_object}

  defp check_activity(name, names) when is_binary(name) do
    if name in names, do: :ok, else: {:error, {:unknown_activity, name}}
  end

  defp check_activity(other, _names), do: {:error, {:unknown_activity, other}}

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

  defp check_text(text, reason) do
    if is_binary(text) and String.trim(text) != "", do: :ok, else: {:error, reason}
  end

  defp check_want(%{} = want) do
    with :ok <- check_keys(want, @want_keys, :want_missing_key, :want_unknown_key),
         :ok <- check_text(want["want"], :bad_want),
         :ok <- check_text(want["why"], :bad_want_why) do
      {:ok, want}
    end
  end

  defp check_want(_not_object), do: {:error, :want_not_object}

  defp check_count(n) when n <= @cap, do: :ok
  defp check_count(n), do: {:error, {:too_many_items, n}}

  # --- 规划调用：额度、触发 ---

  @doc """
  今天还能不能再起一次规划调用：当日 `calls.n < 5`（规划加重排共计）返回 `{:ok, 记了一次调用的 plan}`，跨日清零；
  否则 `{:error, :day_budget_exhausted}`。调用在**起调用时**就记，崩溃或失败都不退还。
  """
  @spec admit(plan(), integer()) :: {:ok, plan()} | {:error, :day_budget_exhausted}
  def admit(plan, day) do
    case plan["calls"] do
      %{"day" => ^day, "n" => n} when n >= @day_calls -> {:error, :day_budget_exhausted}
      %{"day" => ^day, "n" => n} -> {:ok, %{plan | "calls" => %{"day" => day, "n" => n + 1}}}
      _other_day -> {:ok, %{plan | "calls" => %{"day" => day, "n" => 1}}}
    end
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
  清 `event_waiting`，记 `last`、`last_at_ms` 与计数（`:day` → `planned`，`:event` → `replanned`）。

  条目总数上限 8：保留项在前、新的在后，超出就丢最前面的——先是最旧的已结束项，已结束项丢光后仍超才丢最旧的 open。
  `check/3` 一次至多放行 5 条，所以丢 open 的那条路径只有直接给 `adopt/6` 超长的 `checked` 才会走到。
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
        "event_waiting" => false,
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
  （不是字符串的用 `inspect/1` 转成字符串，保证能过 JSON）。意图与 `wants` 不动（沿用上一份）、`event_waiting` 不清（条件留到下次）；
  `last_at_ms` 记下，两次调用的最小间隔照算。
  """
  @spec fail(plan(), :day | :event, :failed | :rejected, term(), integer()) :: plan()
  def fail(plan, kind, outcome, reason, at_ms) when outcome in [:failed, :rejected] do
    %{
      plan
      | "last_at_ms" => at_ms,
        "last" => %{
          "at_ms" => at_ms,
          "kind" => Atom.to_string(kind),
          "result" => Atom.to_string(outcome),
          "reason" => if(is_binary(reason), do: reason, else: inspect(reason))
        },
        "counts" => bump(plan["counts"], Atom.to_string(outcome))
    }
  end

  @doc "到点却起不了（槽被占、没有观察、当日额度用完）：只给 `counts.skipped` 加一，触发条件不清。"
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
  一项活动**完成**（失败的不算，调用方不调）时记账：给同名、今天、`:open` 的意图里 `by` 最早的一条 `done + 1`
  （`by` 并列取列表里靠前的）。找不到就原样返回，不报错。
  """
  @spec record_activity(plan(), String.t() | nil, integer(), non_neg_integer()) :: plan()
  def record_activity(%{"day" => day} = plan, activity, day, minute) do
    open =
      plan["intents"]
      |> Enum.with_index()
      |> Enum.filter(fn {intent, _index} ->
        intent["activity"] == activity and status(plan, intent, {day, minute}) == :open
      end)

    case open do
      [] ->
        plan

      candidates ->
        {_intent, index} = Enum.min_by(candidates, fn {intent, _index} -> intent["by"] end)

        %{
          plan
          | "intents" => List.update_at(plan["intents"], index, &%{&1 | "done" => &1["done"] + 1})
        }
    end
  end

  def record_activity(plan, _activity, _other_day, _minute), do: plan

  # --- 给 Mind 的栏 ---

  @doc """
  给 Mind 的数据：今天的各条意图 `%{activity, times, done, by, status}`（`by` 是日内分钟，`status` 此刻推出）与 `wants`
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
