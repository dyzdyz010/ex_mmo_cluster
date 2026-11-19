defmodule NpcServer.Life.Tasks do
  @moduledoc """
  任务层的纯函数核心（任务层决策稿 `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §4）。
  写法同 `NpcServer.Life.DayPlan`：不做 I/O、不依赖进程、不读时钟；结果是字符串键的普通 map，能原样过 JSON。

  **现在只有校验点 `check/3`**（K-0 离线探索要用的那一部分）：持久行 `"tasks"`、步骤记账 `record_step/4`、K-3 的触发分类、
  额度与 Mind 栏都是 T-1，**本模块现在没有接进 Life / Runtime**，产品运行里没有调用方；K-0 的离线脚本
  （`docs/10-active/cross-cutting/tools/jev/task_k0.exs`）用它判真实模型的应答。

  ## 任务与步骤（K-1）

  任务是 NPC 自己开的一件要几步才做成的事：`goal`（模型原文）、`why`、待做的步骤（≤ 3，当头那条是此刻的候选）。
  步骤粒度是一项活动 = **种类 + 可选对象**，与日计划的意图同一套词表 `%{种类 => %{显示名 => 对象}}`（K-4：回顾与推进
  共用一份词表；T-2 之前种类就是 `NpcServer.Offers.plan_kinds/1`，T-2 加 `look_for` 时再立任务词表入口；对象由 Life 展开）。检查后的步骤是 `%{"kind", "object", "why"}`，
  `object` 已换成显示名对应的对象（没点名为 nil）。

  ## 唯一校验点（K-4 / K-5）

  LLM 写的任务与步骤只经 `check/3` 一处进入：推进应答整份（`:advance`）与每日回顾应答整份（`{:review, 此刻分钟, 开着的任务}`）。
  单条种类与对象、`cannot` 的核对复用 `DayPlan` 的同一函数（`DayPlan.check_kind/3`、`DayPlan.check_want/1`），回顾里的
  意图与 `cannot_yet` 原样交 `DayPlan.check_lists/3`——错误原因与日计划完全相同，不另写一份。

  ## 原创取值（实跑后调；决策稿 §6 Q-4）

  开着的任务至多 3（`@max_open`）；一次（开任务或推进）至多 3 步（`@max_steps`）。
  """
  alias NpcServer.Life.DayPlan

  # 每个 NPC 同时开着的任务上限（决策稿 K-1，原创取值）。
  @max_open 3
  # 一次写出的待做步骤上限（决策稿 K-1 / K-4，原创取值）。
  @max_steps 3

  @advance_keys ["task", "steps", "cannot", "note"]
  @review_keys ["intents", "cannot_yet", "tasks"]
  @tasks_keys ["open", "drop"]
  @opened_keys ["goal", "why", "steps"]
  @step_keys ["activity", "why"]
  # 步骤里可缺的键：对象（可缺、可为 null，都是没点名；同日计划意图）。
  @step_optional_keys ["object"]
  @verdicts %{"continue" => :continue, "done" => :done, "drop" => :drop}

  @type vocabulary :: %{String.t() => %{String.t() => term()}}
  @type step :: %{String.t() => term()}
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

  不合格给 `{:error, 原因}`，原因：

      :not_json | :not_object | {:missing_key, 键} | {:unknown_key, 键} | {:not_a_list, 键}
      推进：{:bad_task, 值} | :bad_note | :nothing_to_continue | {:steps_on_close, task} | {:cannot_on_close, task}
            cannot 的错误同 `DayPlan.check_want/1`（:want_not_object、{:want_missing_key, 键} …）
      步骤：:step_not_object | {:step_missing_key, 键} | {:step_unknown_key, 键} | :bad_step_why | {:too_many_steps, n}
            {:unknown_activity, 值} | {:unknown_object, 种类, 值}（同 `DayPlan.check_kind/3`）
      回顾：意图 / cannot_yet 的错误同 `DayPlan.check/3`；:tasks_not_object | {:tasks_missing_key, 键} | {:tasks_unknown_key, 键}
            :task_not_object | {:task_missing_key, 键} | {:task_unknown_key, 键} | :bad_goal | :bad_task_why | :task_without_steps
            {:unknown_task, id} | {:too_many_open, n}

  本函数只给检查结果，采用、拒绝计数与重问规则在调用方（T-1）。
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

  # `holder` 里的 `steps`：列表、逐条核对、至多 3 条（数条数在逐条之后，同 `DayPlan.check/3` 的次序）。
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
