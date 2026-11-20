defmodule NpcServer.NpcLifeDayPlanPromptTest do
  @moduledoc """
  只测试：每日回顾（原日计划）的提示词 `NpcServer.Life.DayPlan.Prompt` 的契约——系统提示词与 K-0 复测真实发出的回顾请求
  逐字节相同；用户消息在没有可选块时与 S1-R8 真实发出的逐字节相同；四个可选块（今天已有的意图、旧 `wants`、开着的任务、
  最近关掉的任务）的位置与“为空等于不传”。

  金标（来源见 `test/support/fixtures/day_plan/README.md`）：系统提示词是 K-0 复测的两份回顾请求（`review-request-R1/R5.json`，
  带人格卡与词表）；用户消息是 S1-R8 存下的两份真实请求体（`requests-R1/R5.json`）：测试把用户消息拆回
  `Reflection.user_message/2` 的第二个参数那张 map（拆法见 `materials/1`），再让产品函数重新拼，断言与存档字节相同。
  """
  use ExUnit.Case, async: true

  alias NpcServer.Life.DayPlan.Prompt

  @fixtures Path.expand("../support/fixtures/day_plan", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name) |> File.read!() |> Jason.decode!()

  defp request(name), do: fixture("requests-#{name}.json")

  defp user_of(request), do: request["messages"] |> hd() |> Map.fetch!("content")

  # 把真实用户消息拆回 `materials`：按 `\n\n` 切三块材料与末行，各块去掉标题、编号与前缀。
  defp materials(request) do
    [right_now, happened, thoughts, "Plan the rest of today now."] =
      request |> user_of() |> String.split("\n\n")

    "Right now:\n" <> right_now_lines = right_now
    "What happened:\n" <> happened_lines = happened

    "What I thought before (my own earlier thoughts, not facts):\nAbout this: " <> after_this =
      thoughts

    [this, others] = String.split(after_this, "\nAbout other things: ", parts: 2)

    %{
      right_now: String.split(right_now_lines, "\n"),
      happened:
        happened_lines
        |> String.split("\n")
        |> Enum.map(&Regex.replace(~r/^\[\d+\] /, &1, "")),
      thought_before: if(this == "nothing yet", do: nil, else: this),
      other_thoughts: if(others == "nothing yet", do: [], else: String.split(others, "\n"))
    }
  end

  for name <- ["R1", "R5"] do
    describe "S1-R8 #{name}-r1 的真实请求体" do
      setup do
        request = request(unquote(name))
        {:ok, request: request, materials: materials(request)}
      end

      test "用户消息（可选块都空）逐字节相同", %{request: request, materials: materials} do
        assert Prompt.user_message(materials) == user_of(request)
      end

      test "可选块为空列表时与不传相同", %{materials: materials} do
        assert Prompt.user_message(materials,
                 today: [],
                 wants: [],
                 open_tasks: [],
                 closed_tasks: []
               ) ==
                 Prompt.user_message(materials)
      end

      # 任务层 T-1a（K-5）：开着的任务、最近关掉的任务两块，在今天的意图与旧 wants 之后、末行之前；各行由
      # `Tasks.Prompt.review_open_lines/2` / `review_closed_lines/1` 渲染（带任务 id），本模块只加标题与位置。
      test "四块都给：今天的意图、旧 wants、开着的任务、最近关掉的任务，依次在三块材料之后、末行之前", %{
        request: request,
        materials: materials
      } do
        message =
          Prompt.user_message(materials,
            today: ["guard_hut: 0 of 1 done, by 20:00"],
            wants: ["speak to Tobin"],
            open_tasks: ["- t3:1: Rebuild my hut — next: gather_stone; nothing done yet"],
            closed_tasks: ["- t2:1: Ask Corvin why — finished"]
          )

        {materials_part, last} = split_last(user_of(request))

        assert message ==
                 Enum.join(
                   [
                     materials_part,
                     "What I meant to do today, as it stands:\nguard_hut: 0 of 1 done, by 20:00",
                     "Things I wanted to do but could not yet:\nspeak to Tobin",
                     "My open tasks (by id):\n- t3:1: Rebuild my hut — next: gather_stone; nothing done yet",
                     "Tasks I closed recently:\n- t2:1: Ask Corvin why — finished",
                     last
                   ],
                   "\n\n"
                 )
      end

      test "只给今天的意图：多出一块，在三块材料之后、末行之前", %{request: request, materials: materials} do
        lines = ["gather_stone: 1 of 2 done, by 15:00", "visit_plaza: 0 of 1 done, by 18:00"]
        message = Prompt.user_message(materials, today: lines)

        block = "What I meant to do today, as it stands:\n" <> Enum.join(lines, "\n")
        {materials_part, last} = split_last(user_of(request))

        assert message == materials_part <> "\n\n" <> block <> "\n\n" <> last
      end

      test "只给旧 wants：多出一块，在三块材料之后、末行之前", %{request: request, materials: materials} do
        lines = ["I would like to ask Corvin why, but I cannot do that yet"]
        message = Prompt.user_message(materials, wants: lines)

        block = "Things I wanted to do but could not yet:\n" <> Enum.join(lines, "\n")
        {materials_part, last} = split_last(user_of(request))

        assert message == materials_part <> "\n\n" <> block <> "\n\n" <> last
      end

      test "两块都给：今天的意图在前，旧 wants 在后", %{request: request, materials: materials} do
        today = ["guard_hut: 0 of 1 done, by 20:00"]
        wants = ["speak to Tobin"]
        message = Prompt.user_message(materials, today: today, wants: wants)
        {materials_part, last} = split_last(user_of(request))

        assert message ==
                 Enum.join(
                   [
                     materials_part,
                     "What I meant to do today, as it stands:\nguard_hut: 0 of 1 done, by 20:00",
                     "Things I wanted to do but could not yet:\nspeak to Tobin",
                     last
                   ],
                   "\n\n"
                 )
      end
    end
  end

  # 任务层 T-1a：回顾是唯一的规划调用，系统提示词金标换成 K-0 复测里产品渲染、真实发出的两份回顾请求（同一人格卡；请求里存的
  # 就是那次交给模板的词表，含点名 Corvin 的说话一行；来源见 `test/support/fixtures/day_plan/README.md`）。
  for name <- ["R1", "R5"] do
    test "回顾系统提示词与 K-0 复测 #{name} 真实发出的逐字节相同" do
      request = fixture("review-request-#{unquote(name)}.json")

      vocabulary =
        for %{"kind" => kind, "criterion" => criterion, "objects" => objects} <-
              request["vocabulary"],
            do: %{kind: kind, criterion: criterion, objects: objects}

      assert Prompt.review_system_prompt(request["character"], vocabulary) == request["system"]
    end
  end

  describe "每日回顾的模板（任务层决策稿 K-5）" do
    # 词表与 Round 交进来的同形：静态种类、说话（对象是人）。
    @vocabulary [
      %{kind: "guard_hut", criterion: "Stand beside the small hut for a while.", objects: %{}},
      %{
        kind: "speak_to",
        criterion: "Walk up to someone and say one thing to them.",
        objects: %{"actor 7" => %{"actor" => 7}}
      }
    ]

    test "词表渲染一处定义：有对象的种类判据后接可选对象句，静态种类原样" do
      assert Prompt.activity_list(Prompt.activities(@vocabulary)) ==
               Enum.join(
                 [
                   "- guard_hut: Stand beside the small hut for a while.",
                   ~s|- speak_to: Walk up to someone and say one thing to them. Optionally add "object": exactly one of "actor 7".|
                 ],
                 "\n"
               )
    end

    test "系统提示词：人格卡、同一份词表渲染、三个键都讲到、答案格式里有 object 与 tasks，不留占位符" do
      prompt = Prompt.review_system_prompt("Garen, a builder.", @vocabulary)

      assert String.starts_with?(prompt, "You are this person: Garen, a builder.\n")
      assert prompt =~ "\n" <> Prompt.activity_list(Prompt.activities(@vocabulary)) <> "\n"
      assert prompt =~ ~s|{"intents": [{"activity": |
      assert prompt =~ ~s|"tasks": {"open": [{"goal": |
      assert prompt =~ ~s|"drop": [|
      assert prompt =~ ~s|"cannot_yet": [{"want": |
      assert prompt =~ ~s|"object": |
      refute prompt =~ "<activities>"
      refute prompt =~ "<character>"
      refute String.ends_with?(prompt, "\n")
    end

    # K-0 复测前的改法（`.demo/observe/npc-task-k0-20261119/results.md` 发现 1）：K-0 的格式行在每条意图 / 步骤上都写
    # “该种类列出的名字之一或 null”，模型给静态种类 `confront_wrecker` 也点了名（18 份里 6 份因此被拒）。
    # 现在 `"object"` 默认 null，只有词表那一行列了名字的种类才写名字；意图与任务步同一句（与推进共用一处定义）。
    test "答案格式行（金标）：object 默认 null，只在列了名字的种类上写名字" do
      prompt = Prompt.review_system_prompt("Garen, a builder.", @vocabulary)

      object =
        ~s|"object": <null, unless the kind's line above lists names; then one of those names, in quotes>|

      format =
        ~s|{"intents": [{"activity": "<a name from the list>", #{object}, "times": <whole number, at least 1>, | <>
          ~s|"by": "<HH:MM, 24-hour, later than now and before midnight>", "why": "<one sentence, first person>"}], | <>
          ~s|"tasks": {"open": [{"goal": "<what you want to bring about, in your own words>", "why": "<one sentence, first person>", | <>
          ~s|"steps": [{"activity": "<a name from the list>", #{object}, "why": "<one sentence, first person>"}]}], | <>
          ~s|"drop": ["<the id of an open task you give up>"]}, | <>
          ~s|"cannot_yet": [{"want": "<what you want to do, in your own words>", "why": "<one sentence, first person>"}]}|

      assert prompt =~ "\n" <> format <> "\n"
      refute prompt =~ "one of the names listed for that kind"
    end
  end

  # 用户消息 = 三块材料 + 末行：返回 {前面的全部, 末行}。
  defp split_last(message) do
    [last | rest] = message |> String.split("\n\n") |> Enum.reverse()
    {rest |> Enum.reverse() |> Enum.join("\n\n"), last}
  end
end
