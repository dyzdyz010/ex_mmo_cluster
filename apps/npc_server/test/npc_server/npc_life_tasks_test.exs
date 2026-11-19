defmodule NpcServer.NpcLifeTasksTest do
  @moduledoc """
  只测试：任务层校验点 `NpcServer.Life.Tasks.check/3`（任务层决策稿
  `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §4 K-4、K-5，§5 测试矩阵 K-1）——
  推进应答与每日回顾应答里任务 / 步骤的唯一校验：合法即给出类型化结果，反例逐条显式失败。

  反例取自矩阵 K-1 的清单：多键 / 缺键、未知种类、对象不在词表、`continue` 无步骤、`done` 带步骤、步骤 > 3、开任务超上限；
  另证明单条种类与对象的核对复用 `DayPlan` 的同一函数（错误原因与日计划意图的相同）。
  期望是按契约手写的小例。不证明：提示词（`npc_life_tasks_prompt_test`）、Life 接线与持久化（T-1）。
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
end
