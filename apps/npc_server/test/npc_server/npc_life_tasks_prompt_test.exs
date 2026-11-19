defmodule NpcServer.NpcLifeTasksPromptTest do
  @moduledoc """
  只测试：任务推进的提示词 `NpcServer.Life.Tasks.Prompt`（任务层决策稿
  `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §4 K-4）的拼装契约：
  词表与每日回顾共用同一份渲染、材料三块与反思 / 规划共用同一拼法、步骤结局用 `Mind.result/1` 的写法、
  这次为什么问的一句、各块次序。输入是直接构造的小例（纯函数）。

  不证明：模型怎样读这份提示词（K-0 离线探索）、取材与写作（T-1 的推进 Round）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias NpcServer.Life.DayPlan.Prompt, as: PlanPrompt
  alias NpcServer.Life.Reflection
  alias NpcServer.Life.Tasks.Prompt

  @vocabulary [
    %{kind: "build_hut", criterion: "Build the small hut.", objects: %{}},
    %{
      kind: "speak_to",
      criterion: "Walk up to someone and say one thing to them.",
      objects: %{"actor 7" => %{"actor" => 7}}
    }
  ]

  @materials %{
    right_now: ["It is afternoon, 13:00. It is day 3.", "Nobody else is nearby."],
    happened: ["I did something."],
    thought_before: nil,
    other_thoughts: []
  }

  defp task(log, waiting) do
    %{
      "id" => "t3:1",
      "goal" => "Rebuild my hut",
      "why" => "It is mine.",
      "steps" => [%{"kind" => "speak_to", "object" => %{"actor" => 7}, "why" => "Ask for stone."}],
      "log" => log,
      "waiting" => waiting
    }
  end

  test "系统提示词：人格卡、与回顾同一份词表渲染、答案格式恰为四个键，不留占位符" do
    prompt = Prompt.system_prompt("Garen, a builder.", @vocabulary)

    assert String.starts_with?(prompt, "You are this person: Garen, a builder.\n")
    assert prompt =~ "\n" <> PlanPrompt.activity_list(PlanPrompt.activities(@vocabulary)) <> "\n"

    assert prompt =~
             ~s|{"task": "continue" or "done" or "drop", "steps": [{"activity": |

    assert prompt =~ ~s|"cannot": null or {"want": |
    assert prompt =~ ~s|"note": |
    refute prompt =~ "<activities>"
    refute prompt =~ "<character>"
    refute String.ends_with?(prompt, "\n")
  end

  # 与每日回顾同一句 `"object"`（K-0 复测前的改法，见 `npc_life_day_plan_prompt_test` 的格式行金标）。
  test "答案格式行（金标）：步骤的 object 默认 null，只在列了名字的种类上写名字" do
    prompt = Prompt.system_prompt("Garen, a builder.", @vocabulary)

    format =
      ~s|{"task": "continue" or "done" or "drop", "steps": [{"activity": "<a name from the list>", | <>
        ~s|"object": <null, unless the kind's line above lists names; then one of those names, in quotes>, | <>
        ~s|"why": "<one sentence, first person>"}], | <>
        ~s|"cannot": null or {"want": "<what you need to do, in your own words>", "why": "<one sentence, first person>"}, | <>
        ~s|"note": "<one sentence, first person, about how this task stands>"}|

    assert prompt =~ "\n" <> format <> "\n"
    refute prompt =~ "one of the names listed for that kind"
  end

  test "用户消息：材料三块（同一拼法）→ 任务 → 已做步骤的结局 → 还要做的步骤 → 为什么现在问 → 末行" do
    log = [
      %{
        "kind" => "build_hut",
        "object" => nil,
        "outcome" => "failed",
        "act" => "build",
        "reason" => "insufficient_material"
      }
    ]

    message = Prompt.user_message(@materials, task(log, "failed"), %{7 => "Corvin"})

    assert message ==
             Enum.join(
               Reflection.materials_blocks(@materials) ++
                 [
                   "The task I am working on: Rebuild my hut\nWhy: It is mine.",
                   "What I have done for it so far:\n- build_hut: failed (build: I did not have enough material for it)",
                   "Steps I still meant to take:\n- speak_to Corvin (actor 7) — Ask for stone.",
                   "Why I am thinking about it now: My last step did not work out.",
                   "Decide what to do next for this task now."
                 ],
               "\n\n"
             )
  end

  test "还没做过步骤、点名的人不在此刻观察里（只有 cid）：写 nothing yet 与 actor <cid>；停滞与步骤用完各一句" do
    stalled = Prompt.user_message(@materials, task([], "stalled"), %{})
    assert stalled =~ "\n\nWhat I have done for it so far: nothing yet.\n\n"
    assert stalled =~ "- speak_to actor 7 — Ask for stone."

    assert stalled =~
             "Why I am thinking about it now: For a long while I have not taken the next step."

    done = %{
      task(
        [%{"kind" => "speak_to", "object" => %{"actor" => 7}, "outcome" => "completed"}],
        "steps_done"
      )
      | "steps" => []
    }

    message = Prompt.user_message(@materials, done, %{})
    assert message =~ "What I have done for it so far:\n- speak_to actor 7: completed"
    refute message =~ "Steps I still meant to take"
    assert message =~ "Why I am thinking about it now: I have taken every step I planned for it."
  end

  test "其它开着的任务各一行（当头步 / 没有步骤），在还要做的步骤之后、为什么现在问之前" do
    other = %{
      "goal" => "Keep the hut safe",
      "steps" => [%{"kind" => "guard_hut", "object" => nil, "why" => "x"}]
    }

    empty = %{"goal" => "Learn to fish", "steps" => []}
    message = Prompt.user_message(@materials, task([], "stalled"), %{}, [other, empty])

    assert message =~
             "— Ask for stone.\n\nMy other open tasks:\nKeep the hut safe — next: guard_hut\n" <>
               "Learn to fish — no steps planned\n\nWhy I am thinking about it now:"
  end
end
