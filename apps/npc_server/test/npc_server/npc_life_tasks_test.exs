defmodule NpcServer.NpcLifeTasksTest do
  @moduledoc """
  只测试：任务层校验点 `NpcServer.Life.Tasks.check/3`（任务层决策稿
  `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §4 K-4、K-5，§5 测试矩阵 K-1）——
  推进应答与每日回顾应答里任务 / 步骤的唯一校验：合法即给出类型化结果，反例逐条显式失败。

  反例取自矩阵 K-1 的清单：多键 / 缺键、未知种类、对象不在词表、`continue` 无步骤、`done` 带步骤、步骤 > 3、开任务超上限；
  另证明单条种类与对象的核对复用 `DayPlan` 的同一函数（错误原因与日计划意图的相同）。
  T-1a 起另测纯核心的其余部分（矩阵 K-2）：持久行初值、采用回顾的 `tasks`、步骤记账只动当头步与 K-3 分类表的每一行
  （含反例：被打断不计失败、瞬态失败第 1 次不推进、碰巧同种类同对象的活动也记账）、两行新信息、到期与停滞、给 Mind 的栏。

  T-1b 起另测推进的规则：`due/2`（最小间隔、最早开的等待任务）、额度 `admit/3` / `refund/1`（每游戏日 12 次、跨日恢复）、
  采用 `adopt/6`（continue 换步骤并清等待；done / drop 关闭并写句子；起推进时的基准 `basis/2` 变了即 stale、不采用）、
  `reject/4`（连续 3 次关为 stuck）、`fail/1`（等待留着）。

  期望是按契约手写的小例。不证明：提示词（`npc_life_tasks_prompt_test`）、Life 接线与持久化（`npc_life_tasks_integration_test`）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias NpcServer.Life.Tasks

  @corvin "Corvin (actor 1)"

  # 词表 `%{种类 => %{显示名 => 对象}}`：两个静态种类、一个对象是人的种类（与 `DayPlan.check/3` 同形）。
  @vocabulary %{
    "build_hut" => %{},
    "guard_hut" => %{},
    "speak_to" => %{@corvin => %{"actor" => 1}}
  }

  defp step(activity, object, why \\ "I need to."),
    do: %{"activity" => activity, "object" => object, "why" => why}

  defp advance(answer), do: answer |> Jason.encode!() |> Tasks.check(@vocabulary, :advance)

  defp continue(steps, cannot \\ nil),
    do: %{"task" => "continue", "steps" => steps, "cannot" => cannot, "note" => "I keep at it."}

  describe "check/3 :advance：合法的应答" do
    test "continue 两步：种类 + 对象换成对象本身，键为 kind / object / why，结果过 JSON 不变形" do
      answer =
        continue([
          step("guard_hut", nil, "He may come back."),
          step("speak_to", @corvin, "I want to ask him why.")
        ])

      assert {:ok, checked} = advance(answer)
      assert checked.task == :continue
      assert checked.cannot == nil
      assert checked.note == "I keep at it."

      assert checked.steps == [
               %{"kind" => "guard_hut", "object" => nil, "why" => "He may come back."},
               %{
                 "kind" => "speak_to",
                 "object" => %{"actor" => 1},
                 "why" => "I want to ask him why."
               }
             ]

      assert checked.steps |> Jason.encode!() |> Jason.decode!() == checked.steps
    end

    test "静态种类的对象可缺、可为 null（都是没点名）" do
      answer =
        continue([
          step("guard_hut", nil),
          %{"activity" => "build_hut", "why" => "Rebuild it."}
        ])

      assert {:ok, %{steps: [%{"object" => nil}, %{"object" => nil, "kind" => "build_hut"}]}} =
               advance(answer)
    end

    test "至多一对围栏（带 json 标记）照样合格" do
      text = "```json\n" <> Jason.encode!(continue([step("guard_hut", nil)])) <> "\n```"
      assert {:ok, %{task: :continue}} = Tasks.check(text, @vocabulary, :advance)
    end

    test "continue 没有步骤但写了 cannot：合格，cannot 原样（交学习）" do
      cannot = %{"want" => "ask the mayor", "why" => "Only she knows."}
      assert {:ok, %{steps: [], cannot: ^cannot}} = advance(continue([], cannot))
    end

    test "done / drop：步骤为空、cannot 为 null" do
      for task <- ["done", "drop"] do
        answer = %{"task" => task, "steps" => [], "cannot" => nil, "note" => "That is that."}
        assert {:ok, %{task: atom, steps: [], cannot: nil}} = advance(answer)
        assert Atom.to_string(atom) == task
      end
    end
  end

  describe "check/3 :advance：反例逐条显式失败" do
    test "不是 JSON / 不是对象" do
      assert {:error, :not_json} = Tasks.check("I will look for him.", @vocabulary, :advance)
      assert {:error, :not_object} = Tasks.check("[1]", @vocabulary, :advance)
    end

    test "键恰好四个：缺键、多键" do
      assert {:error, {:missing_key, "note"}} =
               advance(Map.delete(continue([step("guard_hut", nil)]), "note"))

      assert {:error, {:unknown_key, "plan"}} =
               advance(Map.put(continue([step("guard_hut", nil)]), "plan", []))
    end

    test "task 只能是 continue / done / drop" do
      assert {:error, {:bad_task, "pause"}} =
               advance(%{continue([step("guard_hut", nil)]) | "task" => "pause"})
    end

    test "continue 既无步骤也无 cannot" do
      assert {:error, :nothing_to_continue} = advance(continue([]))
    end

    test "done 带步骤、drop 带 cannot" do
      assert {:error, {:steps_on_close, "done"}} =
               advance(%{continue([step("guard_hut", nil)]) | "task" => "done"})

      assert {:error, {:cannot_on_close, "drop"}} =
               advance(%{continue([], %{"want" => "x", "why" => "y"}) | "task" => "drop"})
    end

    test "步骤多于 3 条" do
      steps = for _ <- 1..4, do: step("guard_hut", nil)
      assert {:error, {:too_many_steps, 4}} = advance(continue(steps))
    end

    test "种类不在词表、对象不是该种类列出的显示名、静态种类带对象：与日计划意图同一核对、同一原因" do
      assert {:error, {:unknown_activity, "find_corvin"}} =
               advance(continue([step("find_corvin", @corvin)]))

      assert {:error, {:unknown_object, "speak_to", "Corvin"}} =
               advance(continue([step("speak_to", "Corvin")]))

      assert {:error, {:unknown_object, "guard_hut", @corvin}} =
               advance(continue([step("guard_hut", @corvin)]))
    end

    test "步骤缺键、多键、不是对象、why 为空" do
      assert {:error, {:step_missing_key, "why"}} =
               advance(continue([%{"activity" => "guard_hut"}]))

      assert {:error, {:step_unknown_key, "times"}} =
               advance(continue([Map.put(step("guard_hut", nil), "times", 2)]))

      assert {:error, :step_not_object} = advance(continue(["guard_hut"]))
      assert {:error, :bad_step_why} = advance(continue([step("guard_hut", nil, " ")]))
    end

    test "steps 不是列表、cannot 不是 null 也不是对象、cannot 键不齐、note 为空" do
      assert {:error, {:not_a_list, "steps"}} = advance(%{continue([]) | "steps" => "none"})
      assert {:error, :want_not_object} = advance(continue([], "ask the mayor"))
      assert {:error, {:want_missing_key, "why"}} = advance(continue([], %{"want" => "x"}))

      assert {:error, :bad_note} =
               advance(%{continue([step("guard_hut", nil)]) | "note" => ""})
    end
  end

  describe "check/3 {:review, 此刻分钟, 开着的任务}：回顾应答整份" do
    @now 13 * 60

    defp review(answer, open \\ []),
      do: answer |> Jason.encode!() |> Tasks.check(@vocabulary, {:review, @now, open})

    defp review_answer(tasks, intents \\ []),
      do: %{"intents" => intents, "cannot_yet" => [], "tasks" => tasks}

    defp opened(steps),
      do: %{
        "goal" => "Find out why Corvin wrecked my hut",
        "why" => "I want to know.",
        "steps" => steps
      }

    defp open_task(id), do: %{"id" => id, "goal" => "old", "steps" => []}

    test "开一个两步的任务、写一条意图：意图同日计划的检查结果，任务步换成对象本身" do
      intent = %{"activity" => "guard_hut", "times" => 1, "by" => "20:00", "why" => "Keep watch."}

      answer =
        review_answer(
          %{
            "open" => [opened([step("guard_hut", nil), step("speak_to", @corvin)])],
            "drop" => []
          },
          [intent]
        )

      assert {:ok, %{intents: [checked_intent], wants: [], tasks: %{open: [task], drop: []}}} =
               review(answer)

      assert checked_intent["by"] == 20 * 60
      assert task["goal"] == "Find out why Corvin wrecked my hut"
      assert Enum.map(task["steps"], & &1["kind"]) == ["guard_hut", "speak_to"]
      assert Enum.map(task["steps"], & &1["object"]) == [nil, %{"actor" => 1}]
    end

    test "三张表都可空；弃开着的任务按 id" do
      assert {:ok, %{tasks: %{open: [], drop: []}}} =
               review(review_answer(%{"open" => [], "drop" => []}))

      assert {:ok, %{tasks: %{drop: ["t3:1"]}}} =
               review(review_answer(%{"open" => [], "drop" => ["t3:1"]}), [open_task("t3:1")])
    end

    test "顶层键：缺 tasks；tasks 键不齐；意图的错误原因与日计划相同" do
      assert {:error, {:missing_key, "tasks"}} =
               review(Map.delete(review_answer(%{"open" => [], "drop" => []}), "tasks"))

      assert {:error, {:tasks_missing_key, "drop"}} = review(review_answer(%{"open" => []}))

      bad_intent = %{"activity" => "nap", "times" => 1, "by" => "20:00", "why" => "Tired."}

      assert {:error, {:unknown_activity, "nap"}} =
               review(review_answer(%{"open" => [], "drop" => []}, [bad_intent]))
    end

    test "开的任务：没有步骤、步骤多于 3、goal 为空、键不齐" do
      assert {:error, :task_without_steps} =
               review(review_answer(%{"open" => [opened([])], "drop" => []}))

      four = for _ <- 1..4, do: step("guard_hut", nil)

      assert {:error, {:too_many_steps, 4}} =
               review(review_answer(%{"open" => [opened(four)], "drop" => []}))

      assert {:error, :bad_goal} =
               review(
                 review_answer(%{
                   "open" => [%{opened([step("guard_hut", nil)]) | "goal" => ""}],
                   "drop" => []
                 })
               )

      assert {:error, {:task_missing_key, "steps"}} =
               review(review_answer(%{"open" => [%{"goal" => "g", "why" => "w"}], "drop" => []}))
    end

    test "弃的 id 不是开着的任务" do
      assert {:error, {:unknown_task, "t9:1"}} =
               review(review_answer(%{"open" => [], "drop" => ["t9:1"]}), [open_task("t3:1")])
    end

    test "开着的任务至多 3：已开 2、再开 2 不弃 → 超上限；弃 1 个则恰为 3，合格" do
      open = [open_task("t3:1"), open_task("t3:2")]
      two = [opened([step("guard_hut", nil)]), opened([step("build_hut", nil)])]

      assert {:error, {:too_many_open, 4}} =
               review(review_answer(%{"open" => two, "drop" => []}), open)

      assert {:ok, %{tasks: %{open: [_, _], drop: ["t3:1"]}}} =
               review(review_answer(%{"open" => two, "drop" => ["t3:1"]}), open)
    end

    # 评审反例：同一 id 弃两次只弃掉一个任务，计数按 id 去重；不去重时 3 − 2 + 2 = 3 会被误放行。
    test "同一 id 弃两次只算弃一个：已开 3、弃 t3:1 两次、再开 2 → 超上限" do
      open = [open_task("t3:1"), open_task("t3:2"), open_task("t3:3")]
      two = [opened([step("guard_hut", nil)]), opened([step("build_hut", nil)])]

      assert {:error, {:too_many_open, 4}} =
               review(review_answer(%{"open" => two, "drop" => ["t3:1", "t3:1"]}), open)
    end
  end

  # —— T-1a：持久行、采用回顾、步骤记账与 K-3 分类、新信息、到期 / 停滞、给 Mind 的栏（决策稿 K-1、K-3、K-5，§5 K-2）——
  # 输入是 `check/3` 合格后的形状（步骤 `%{"kind", "object", "why"}`）与 `Selector.experience/1` 交出的种类、对象、结局。

  defp checked_step(kind, object \\ nil),
    do: %{"kind" => kind, "object" => object, "why" => "I need to."}

  defp rebuild,
    do: %{
      "goal" => "Rebuild my hut",
      "why" => "It is gone.",
      "steps" => [checked_step("gather_stone"), checked_step("build_hut")]
    }

  defp ask,
    do: %{
      "goal" => "Ask Corvin why",
      "why" => "I want to know.",
      "steps" => [checked_step("confront_wrecker"), checked_step("speak_to", %{"actor" => 1})]
    }

  # 回顾在第 1418 日、时刻 1000 开出的两个任务：t1418:1 重建、t1418:2 问 Corvin。
  defp opened_tasks(opened \\ [rebuild(), ask()]) do
    {tasks, _episodes} = Tasks.review(Tasks.new(), %{open: opened, drop: []}, 1418, 1_000)
    tasks
  end

  defp task(tasks, id), do: Enum.find(tasks["open"], &(&1["id"] == id))
  defp step!(tasks, done, outcome, at_ms), do: Tasks.record_step(tasks, done, outcome, at_ms)
  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  describe "new/0 与 review/4（回顾采用 tasks）" do
    test "持久行初值：没有任务、调用数为 0、各计数为 0" do
      assert Tasks.new() == %{
               "open" => [],
               "closed" => [],
               "calls" => %{"day" => nil, "n" => 0},
               "last_at_ms" => nil,
               "counts" =>
                 Map.new(
                   ~w(opened advanced done dropped expired stuck rejected failed cannot stale),
                   &{&1, 0}
                 )
             }
    end

    test "开两个任务：id 按开过的总数排、两个游戏日后到期、当头步从此刻计时；各写一句开任务的经历，带任务里的人" do
      {tasks, episodes} =
        Tasks.review(Tasks.new(), %{open: [rebuild(), ask()], drop: []}, 1418, 1_000)

      assert [first, second] = tasks["open"]

      assert first == %{
               "id" => "t1418:1",
               "goal" => "Rebuild my hut",
               "why" => "It is gone.",
               "opened_day" => 1418,
               "expires_day" => 1420,
               "steps" => rebuild()["steps"],
               "log" => [],
               "waiting" => nil,
               "head_since_ms" => 1_000,
               "head_failures" => 0,
               "rejected_in_row" => 0,
               "completed" => 0,
               "note" => nil
             }

      assert second["id"] == "t1418:2"
      assert tasks["counts"]["opened"] == 2
      assert json(tasks) == tasks

      assert episodes == [
               %{
                 "id" => "task:t1418:1:opened",
                 "at_ms" => 1_000,
                 "text" => ~s|I set myself a task: "Rebuild my hut".|,
                 "tags" => ["kind:task"]
               },
               %{
                 "id" => "task:t1418:2:opened",
                 "at_ms" => 1_000,
                 "text" => ~s|I set myself a task: "Ask Corvin why".|,
                 "tags" => ["kind:task", "actor:1"]
               }
             ]
    end

    test "弃：按 id 关为 dropped、进最近关掉的小结、写一句经历；新开的 id 接着开过的总数，不与已关的重" do
      {tasks, episodes} =
        Tasks.review(opened_tasks(), %{open: [rebuild()], drop: ["t1418:1"]}, 1419, 2_000)

      assert Enum.map(tasks["open"], & &1["id"]) == ["t1418:2", "t1419:3"]

      assert tasks["closed"] == [
               %{
                 "id" => "t1418:1",
                 "goal" => "Rebuild my hut",
                 "result" => "dropped",
                 "note" => nil,
                 "closed_day" => 1419,
                 "completed" => 0
               }
             ]

      assert tasks["counts"]["dropped"] == 1

      assert [
               %{
                 "id" => "task:t1418:1:dropped",
                 "text" => ~s|I gave up my task "Rebuild my hut".|
               },
               _
             ] =
               episodes
    end

    # 评审反例：回顾在途时，它要弃的任务已被 tick 到期关掉（校验时开着，落栏时不在了）。弃这一项跳过，不再写“弃”的经历与计数。
    test "要弃的任务落栏时已不在 open（回顾在途时到期关掉）：跳过，只开新的" do
      {tasks, _} = Tasks.review(Tasks.new(), %{open: [rebuild()], drop: []}, 10, 1_000)
      {expired, [_]} = Tasks.tick(tasks, 13, 2_000)

      {reviewed, episodes} =
        Tasks.review(expired, %{open: [ask()], drop: ["t10:1"]}, 13, 3_000)

      assert Enum.map(reviewed["open"], & &1["id"]) == ["t13:2"]
      assert reviewed["closed"] == expired["closed"]
      assert reviewed["counts"]["dropped"] == 0 and reviewed["counts"]["expired"] == 1
      assert [%{"id" => "task:t13:2:opened"}] = episodes
    end

    test "最近关掉的只留 5 条（新的在后）" do
      tasks =
        Enum.reduce(1..6, Tasks.new(), fn n, tasks ->
          {tasks, _} = Tasks.review(tasks, %{open: [rebuild()], drop: []}, n, n)
          [%{"id" => id}] = tasks["open"]
          {tasks, _} = Tasks.review(tasks, %{open: [], drop: [id]}, n, n)
          tasks
        end)

      assert Enum.map(tasks["closed"], & &1["id"]) == ~w(t2:2 t3:3 t4:4 t5:5 t6:6)
    end
  end

  describe "record_step/4（K-2 只记当头步；K-3 分类）" do
    test "当头步完成、后面还有步：前移，完成数加一，当头步从此刻计时，不待推进；log 记当头步的种类与对象" do
      tasks = step!(opened_tasks(), {"gather_stone", nil}, :completed, 2_000)
      task = task(tasks, "t1418:1")

      assert task["steps"] == [checked_step("build_hut")]
      assert task["completed"] == 1
      assert task["head_since_ms"] == 2_000
      assert task["waiting"] == nil

      assert task["log"] == [
               %{
                 "kind" => "gather_stone",
                 "object" => nil,
                 "outcome" => "completed",
                 "act" => nil,
                 "reason" => nil,
                 "at_ms" => 2_000
               }
             ]

      assert task(tasks, "t1418:2") == task(opened_tasks(), "t1418:2")
    end

    test "完成最后一步：步骤用完，待推进 steps_done" do
      tasks =
        opened_tasks()
        |> step!({"gather_stone", nil}, :completed, 2_000)
        |> step!({"build_hut", nil}, :completed, 3_000)

      assert %{"steps" => [], "completed" => 2, "waiting" => "steps_done"} =
               task(tasks, "t1418:1")
    end

    test "非瞬态失败：偏差，待推进 failed，步骤留着，log 带动作与原因" do
      tasks =
        step!(opened_tasks(), {"gather_stone", nil}, {:failed, "gather", "exhausted"}, 2_000)

      task = task(tasks, "t1418:1")

      assert task["waiting"] == "failed"
      assert task["head_failures"] == 1
      assert task["steps"] == rebuild()["steps"]

      assert [%{"outcome" => "failed", "act" => "gather", "reason" => "exhausted"}] =
               task["log"]
    end

    test "瞬态失败（Trees.transient_reasons/0）：第 1 次不推进，同一步连续第 2 次才偏差；world_timeout 也是瞬态" do
      assert NpcServer.Trees.transient_reasons() ==
               [:invalid_session, :dead, :session_lost, :world_timeout]

      once =
        step!(opened_tasks(), {"gather_stone", nil}, {:failed, "travel", "session_lost"}, 2_000)

      assert %{"waiting" => nil, "head_failures" => 1, "head_since_ms" => 2_000} =
               task(once, "t1418:1")

      twice = step!(once, {"gather_stone", nil}, {:failed, "gather", "world_timeout"}, 3_000)
      assert %{"waiting" => "failed", "head_failures" => 2} = task(twice, "t1418:1")
    end

    # 评审修正：偏差（failed / stalled）由当头步成功前移化解，清掉；新信息（heard / event）不是步骤化解得了的，留着。
    test "当头步失败或停滞之后再成功前移：清掉 failed / stalled；heard / event 留着" do
      failed =
        opened_tasks()
        |> step!({"gather_stone", nil}, {:failed, "gather", "exhausted"}, 2_000)
        |> step!({"gather_stone", nil}, :completed, 3_000)

      assert %{"waiting" => nil, "head_failures" => 0, "completed" => 1} =
               task(failed, "t1418:1")

      {stalled, []} = Tasks.tick(opened_tasks(), 1418, 1_000 + 900_000)
      assert task(stalled, "t1418:1")["waiting"] == "stalled"
      moved = step!(stalled, {"gather_stone", nil}, :completed, 1_000 + 900_001)
      assert task(moved, "t1418:1")["waiting"] == nil

      for reason <- ["heard", "event"] do
        noted = Tasks.note_news(opened_tasks(), 1, reason)
        moved = step!(noted, {"confront_wrecker", nil}, :completed, 2_000)
        assert %{"waiting" => ^reason, "completed" => 1} = task(moved, "t1418:2")
      end
    end

    test "被打断：不算失败，只记 log，当头步从此刻计时" do
      tasks =
        step!(opened_tasks(), {"gather_stone", nil}, {:interrupted, "to talk with Brann"}, 2_000)

      assert %{"waiting" => nil, "head_failures" => 0, "head_since_ms" => 2_000, "steps" => steps} =
               task(tasks, "t1418:1")

      assert steps == rebuild()["steps"]

      assert [%{"outcome" => "interrupted", "act" => nil, "reason" => "to talk with Brann"}] =
               task(tasks, "t1418:1")["log"]
    end

    test "两个任务当头步相同：只记最早开的那个" do
      tasks = opened_tasks([rebuild(), %{rebuild() | "goal" => "Stock up stone"}])
      tasks = step!(tasks, {"gather_stone", nil}, :completed, 2_000)

      assert task(tasks, "t1418:1")["completed"] == 1
      assert task(tasks, "t1418:2")["completed"] == 0
    end

    test "点名优先，再没点名的：当头步恰为这个人的先记；没点名的当头步对谁都成立（碰巧同种类也记账），log 记当头步" do
      anyone = %{ask() | "goal" => "Talk to someone", "steps" => [checked_step("speak_to")]}
      corvin = %{ask() | "steps" => [checked_step("speak_to", %{"actor" => 1})]}
      tasks = opened_tasks([anyone, corvin])

      named = step!(tasks, {"speak_to", %{"actor" => 1}}, :completed, 2_000)
      assert task(named, "t1418:1")["completed"] == 0
      assert task(named, "t1418:2")["completed"] == 1

      other = step!(tasks, {"speak_to", %{"actor" => 9}}, :completed, 2_000)
      assert task(other, "t1418:1")["completed"] == 1
      assert [%{"object" => nil}] = task(other, "t1418:1")["log"]
    end

    test "不是当头步（第二步、别的种类）：原样返回" do
      tasks = opened_tasks()
      assert step!(tasks, {"build_hut", nil}, :completed, 2_000) == tasks
      assert step!(tasks, {"visit_plaza", nil}, {:failed, "travel", "no_path"}, 2_000) == tasks
    end

    test "log 只留最近 6 条" do
      tasks =
        Enum.reduce(1..8, opened_tasks(), fn n, tasks ->
          step!(tasks, {"gather_stone", nil}, {:interrupted, "to talk"}, n)
        end)

      assert Enum.map(task(tasks, "t1418:1")["log"], & &1["at_ms"]) == [3, 4, 5, 6, 7, 8]
    end
  end

  describe "people/1 与 note_news/3（K-3 的两行新信息）" do
    test "任务里的人：待做步骤与 log 里点名过的（去重）" do
      tasks = opened_tasks()
      assert Tasks.people(task(tasks, "t1418:1")) == []
      assert Tasks.people(task(tasks, "t1418:2")) == [1]

      done =
        tasks
        |> step!({"confront_wrecker", nil}, :completed, 2_000)
        |> step!({"speak_to", %{"actor" => 1}}, :completed, 3_000)

      assert task(done, "t1418:2")["steps"] == []
      assert Tasks.people(task(done, "t1418:2")) == [1]
    end

    test "人落在任务里：待推进 heard / event；不在任何任务里：原样；已在等的不改原因" do
      tasks = opened_tasks()
      heard = Tasks.note_news(tasks, 1, "heard")

      assert task(heard, "t1418:2")["waiting"] == "heard"
      assert task(heard, "t1418:1")["waiting"] == nil
      assert Tasks.note_news(tasks, 99, "event") == tasks
      assert task(Tasks.note_news(heard, 1, "event"), "t1418:2")["waiting"] == "heard"
    end
  end

  describe "tick/3（到期、停滞）" do
    test "到期日当天还开着，过了到期日关为 expired（不问模型），各写一句经历" do
      tasks = opened_tasks()
      assert Tasks.tick(tasks, 1420, 1_000) == {tasks, []}

      {expired, episodes} = Tasks.tick(tasks, 1421, 5_000)
      assert expired["open"] == []

      assert Enum.map(expired["closed"], &{&1["id"], &1["result"]}) ==
               [{"t1418:1", "expired"}, {"t1418:2", "expired"}]

      assert expired["counts"]["expired"] == 2

      assert [
               %{
                 "id" => "task:t1418:1:expired",
                 "at_ms" => 5_000,
                 "text" => ~s|I did not finish my task "Rebuild my hut" in time, so I let it go.|,
                 "tags" => ["kind:task"]
               },
               %{"tags" => ["kind:task", "actor:1"]}
             ] = episodes
    end

    test "当头步满 6 游戏小时（游戏钟 ×24：现实 900 秒）没被做：待推进 stalled；差 1 毫秒不算；已在等的不改" do
      tasks = Tasks.note_news(opened_tasks(), 1, "heard")
      assert Tasks.tick(tasks, 1418, 1_000 + 899_999) == {tasks, []}

      {stalled, []} = Tasks.tick(tasks, 1418, 1_000 + 900_000)
      assert task(stalled, "t1418:1")["waiting"] == "stalled"
      assert task(stalled, "t1418:2")["waiting"] == "heard"
    end
  end

  test "column/1：给 Mind 的每个开着的任务——目标、当头步（没有为 nil）、完成的步数" do
    tasks =
      opened_tasks()
      |> step!({"gather_stone", nil}, :completed, 2_000)
      |> step!({"build_hut", nil}, :completed, 3_000)

    assert Tasks.column(tasks) == [
             %{goal: "Rebuild my hut", next: nil, completed: 2},
             %{goal: "Ask Corvin why", next: checked_step("confront_wrecker"), completed: 0}
           ]

    assert Tasks.column(Tasks.new()) == []
  end

  # —— 推进（T-1b）。`checked` 是 `check/3` 的 `:advance` 结果的形状。 ——

  defp advanced(task, steps, cannot \\ nil, note \\ "It went as it went."),
    do: %{task: task, steps: steps, cannot: cannot, note: note}

  describe "due/2：一次推进一个，最早开的等待任务，两次至少隔 3 分钟" do
    test "没有任务在等：nil；只有后开的在等：它；两个都在等：最早开的那个" do
      tasks = opened_tasks()
      assert Tasks.due(tasks, 10_000) == nil

      later = Tasks.note_news(tasks, 1, "heard")
      assert Tasks.due(later, 10_000) == "t1418:2"

      both = step!(later, {"gather_stone", nil}, {:failed, "gather", "exhausted"}, 2_000)
      assert task(both, "t1418:1")["waiting"] == "failed"
      assert Tasks.due(both, 10_000) == "t1418:1"
    end

    test "距上一次推进调用不足 3 分钟一律 nil，恰满 3 分钟给出" do
      tasks = Tasks.note_news(opened_tasks(), 1, "heard")
      {:ok, admitted} = Tasks.admit(tasks, 1418, 50_000)

      assert Tasks.due(admitted, 50_000 + 179_999) == nil
      assert Tasks.due(admitted, 50_000 + 180_000) == "t1418:2"
    end
  end

  describe "admit/3 与 refund/1（每人每游戏日 12 次写作）" do
    test "同一游戏日第 13 次被拒、行不变；跨日从 1 重计；放行时记起调用的时刻，不清 waiting" do
      tasks = Tasks.note_news(opened_tasks(), 1, "heard")

      admitted =
        Enum.reduce(1..12, tasks, fn n, acc ->
          assert {:ok, acc} = Tasks.admit(acc, 1418, n)
          acc
        end)

      assert admitted["calls"] == %{"day" => 1418, "n" => 12}
      assert admitted["last_at_ms"] == 12
      assert task(admitted, "t1418:2")["waiting"] == "heard"
      assert Tasks.admit(admitted, 1418, 13) == {:error, :day_budget_exhausted}

      assert {:ok, next_day} = Tasks.admit(admitted, 1419, 14)
      assert next_day["calls"] == %{"day" => 1419, "n" => 1}
    end

    test "写作没有发出：退回这一次，其余不动（最小间隔照算）" do
      {:ok, admitted} = Tasks.admit(opened_tasks(), 1418, 7_000)
      refunded = Tasks.refund(admitted)

      assert refunded["calls"] == %{"day" => 1418, "n" => 0}
      assert refunded["last_at_ms"] == 7_000
      assert Map.delete(refunded, "calls") == Map.delete(admitted, "calls")
    end
  end

  # 起推进那一刻（落栏前没有别的变化）就采用：基准取自传进来的同一份行。
  defp adopt_now(tasks, id, checked, day, at_ms),
    do: Tasks.adopt(tasks, id, Tasks.basis(tasks, id), checked, day, at_ms)

  describe "adopt/6：合格的推进应答" do
    test "continue：待做步骤整份换掉，note 存进任务，等待与连续不合格清零，当头步从此刻计时；cannot 只计数" do
      tasks =
        opened_tasks()
        |> step!({"gather_stone", nil}, {:failed, "gather", "exhausted"}, 2_000)
        |> Tasks.reject("t1418:1", 1418, 3_000)
        |> elem(0)

      assert %{"waiting" => "failed", "head_failures" => 1, "rejected_in_row" => 1} =
               task(tasks, "t1418:1")

      steps = [checked_step("gather_stone"), checked_step("visit_plaza")]
      cannot = %{"want" => "rest a while", "why" => "I am worn out."}

      {:adopted, adopted, episodes} =
        adopt_now(tasks, "t1418:1", advanced(:continue, steps, cannot), 1418, 9_000)

      assert episodes == []

      assert %{
               "steps" => ^steps,
               "note" => "It went as it went.",
               "waiting" => nil,
               "rejected_in_row" => 0,
               "head_failures" => 0,
               "head_since_ms" => 9_000,
               "log" => [%{"outcome" => "failed"}]
             } = task(adopted, "t1418:1")

      assert task(adopted, "t1418:2") == task(tasks, "t1418:2")
      assert adopted["counts"]["advanced"] == 1
      assert adopted["counts"]["cannot"] == 1
      assert json(adopted) == adopted

      # 推进在途时任务已被关掉（到期）：gone，原样返回、不计数。
      basis = Tasks.basis(adopted, "t1418:1")
      {expired, _episodes} = Tasks.tick(adopted, 1421, 9_000)

      assert Tasks.adopt(expired, "t1418:1", basis, advanced(:continue, steps), 1421, 9_000) ==
               {:gone, expired, []}
    end

    test "done / drop：关为 done / dropped，note 进小结；经历是标准句后接 note，带任务里的人" do
      tasks = opened_tasks()

      {:adopted, done, [episode]} =
        adopt_now(tasks, "t1418:2", advanced(:done, [], nil, "He heard me."), 1419, 9_000)

      assert Enum.map(done["open"], & &1["id"]) == ["t1418:1"]

      assert done["closed"] == [
               %{
                 "id" => "t1418:2",
                 "goal" => "Ask Corvin why",
                 "result" => "done",
                 "note" => "He heard me.",
                 "closed_day" => 1419,
                 "completed" => 0
               }
             ]

      assert episode == %{
               "id" => "task:t1418:2:done",
               "at_ms" => 9_000,
               "text" => ~s|I finished my task "Ask Corvin why". He heard me.|,
               "tags" => ["kind:task", "actor:1"]
             }

      assert %{"advanced" => 1, "done" => 1, "cannot" => 0} = done["counts"]

      {:adopted, dropped, [episode]} =
        adopt_now(tasks, "t1418:1", advanced(:drop, [], nil, "No stone left."), 1418, 9_000)

      assert [%{"id" => "t1418:1", "result" => "dropped"}] = dropped["closed"]
      assert episode["text"] == ~s|I gave up my task "Rebuild my hut". No stone left.|
      assert dropped["counts"]["dropped"] == 1
    end
  end

  describe "adopt/6：推进在途时任务已经变了（比对后采用）" do
    test "反例：采石失败起推进，写作在途时当头步做成、前移——旧应答把同一份步骤再写一遍，不采用，步骤不换回" do
      failed =
        step!(opened_tasks(), {"gather_stone", nil}, {:failed, "gather", "exhausted"}, 2_000)

      basis = Tasks.basis(failed, "t1418:1")
      assert basis == %{"steps" => rebuild()["steps"], "completed" => 0}

      # 写作在途：Jev 又选了 gather_stone 并做成 → 前移、completed + 1、偏差 failed 已化解。
      moved = step!(failed, {"gather_stone", nil}, :completed, 5_000)

      assert %{"steps" => [%{"kind" => "build_hut"}], "completed" => 1, "waiting" => nil} =
               task(moved, "t1418:1")

      # 应答是对起推进那一刻写的（从采石重来，同 A01）：stale，任务原样、只计 stale。
      stale_answer =
        advanced(:continue, rebuild()["steps"], %{"want" => "rest", "why" => "Tired."})

      assert {:stale, landed, []} =
               Tasks.adopt(moved, "t1418:1", basis, stale_answer, 1418, 9_000)

      assert landed["open"] == moved["open"]
      assert landed["counts"] == %{moved["counts"] | "stale" => 1}
    end

    test "反例：只剩一步、在等 heard，写作在途时这一步做完——done 也不采用，任务开着、waiting 原样留着" do
      tasks =
        opened_tasks()
        |> step!({"confront_wrecker", nil}, :completed, 2_000)
        |> Tasks.note_news(1, "heard")

      basis = Tasks.basis(tasks, "t1418:2")
      done = step!(tasks, {"speak_to", %{"actor" => 1}}, :completed, 5_000)

      assert %{"steps" => [], "completed" => 2, "waiting" => "heard"} = task(done, "t1418:2")

      assert {:stale, landed, []} =
               Tasks.adopt(
                 done,
                 "t1418:2",
                 basis,
                 advanced(:done, [], nil, "Asked."),
                 1418,
                 9_000
               )

      assert landed["open"] == done["open"]
      assert %{"stale" => 1, "advanced" => 0, "done" => 0, "rejected" => 0} = landed["counts"]
    end

    test "只有 waiting、log、连续失败变了（步骤与完成数没变）：照常采用" do
      failed =
        step!(opened_tasks(), {"gather_stone", nil}, {:failed, "gather", "exhausted"}, 2_000)

      basis = Tasks.basis(failed, "t1418:1")
      again = step!(failed, {"gather_stone", nil}, {:interrupted, "to talk"}, 3_000)
      again = step!(again, {"gather_stone", nil}, {:failed, "gather", "exhausted"}, 4_000)
      assert task(again, "t1418:1")["head_failures"] == 2

      steps = [checked_step("build_hut")]

      assert {:adopted, adopted, []} =
               Tasks.adopt(again, "t1418:1", basis, advanced(:continue, steps), 1418, 9_000)

      assert %{"steps" => ^steps, "waiting" => nil} = task(adopted, "t1418:1")
      assert %{"advanced" => 1, "stale" => 0} = adopted["counts"]
    end
  end

  describe "reject/4 与 fail/1：没有采用的推进" do
    test "不合格：任务不动、waiting 留着、连续不合格加一；连续第 3 次关为 stuck 并写经历" do
      tasks =
        step!(opened_tasks(), {"gather_stone", nil}, {:failed, "gather", "exhausted"}, 2_000)

      {once, []} = Tasks.reject(tasks, "t1418:1", 1418, 3_000)
      {twice, []} = Tasks.reject(once, "t1418:1", 1418, 4_000)

      assert task(twice, "t1418:1") == %{task(tasks, "t1418:1") | "rejected_in_row" => 2}
      assert twice["counts"]["rejected"] == 2

      {stuck, [episode]} = Tasks.reject(twice, "t1418:1", 1419, 5_000)
      assert Enum.map(stuck["open"], & &1["id"]) == ["t1418:2"]
      assert [%{"id" => "t1418:1", "result" => "stuck", "closed_day" => 1419}] = stuck["closed"]
      assert %{"rejected" => 3, "stuck" => 1} = stuck["counts"]

      assert episode == %{
               "id" => "task:t1418:1:stuck",
               "at_ms" => 5_000,
               "text" =>
                 ~s|I could not settle on a next step for my task "Rebuild my hut", so I set it aside.|,
               "tags" => ["kind:task"]
             }
    end

    test "写作失败：只计数，任务与 waiting 不动" do
      tasks = Tasks.note_news(opened_tasks(), 1, "heard")
      failed = Tasks.fail(tasks)

      assert failed["open"] == tasks["open"]
      assert failed["counts"] == %{tasks["counts"] | "failed" => 1}
    end
  end
end
