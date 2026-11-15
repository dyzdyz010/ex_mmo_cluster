defmodule NpcServer.NpcLifeDayPlanPromptTest do
  @moduledoc """
  只测试：规划提示词 `NpcServer.Life.DayPlan.Prompt` 的契约——系统提示词与用户消息与 S1-R8 真实发出的请求体逐字节相同，
  以及两个后加的可选块（今天已有的意图、旧 `wants`）的位置与“为空等于不传”。

  金标是 S1-R8 存下的两份真实请求体（`R1-r1`、`R5-r1`，来源见 `test/support/fixtures/day_plan/README.md`）：
  测试从请求体里取出人格卡、词表（`activities.json`）与材料（把用户消息拆回 `Reflection.user_message/2` 的
  第二个参数那张 map，拆法见 `materials/1`），再让产品函数重新拼，断言与存档字节相同。
  """
  use ExUnit.Case, async: true

  alias NpcServer.Life.DayPlan.Prompt

  @fixtures Path.expand("../support/fixtures/day_plan", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name) |> File.read!() |> Jason.decode!()

  defp request(name), do: fixture("requests-#{name}.json")

  defp activities do
    for %{"name" => name, "criterion" => criterion} <- fixture("activities.json"),
        do: %{name: name, criterion: criterion}
  end

  defp system_of(request), do: request["system"]
  defp user_of(request), do: request["messages"] |> hd() |> Map.fetch!("content")

  # 系统提示词第一行 `You are this person: ` 之后的原文。
  defp character(request) do
    [first | _] = String.split(system_of(request), "\n")
    "You are this person: " <> character = first
    character
  end

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

      test "系统提示词逐字节相同", %{request: request} do
        assert Prompt.system_prompt(character(request), activities()) == system_of(request)
      end

      test "用户消息（两个可选块都空）逐字节相同", %{request: request, materials: materials} do
        assert Prompt.user_message(materials) == user_of(request)
      end

      test "两个可选块为空列表时与不传相同", %{materials: materials} do
        assert Prompt.user_message(materials, today: [], wants: []) ==
                 Prompt.user_message(materials)
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

  test "候选每个一行 `- <name>: <criterion>`，次序同词表，多余的键忽略" do
    prompt =
      Prompt.system_prompt("Garen, a builder.", [
        %{name: "a_one", criterion: "Do the first thing.", extra: 1},
        %{name: "b_two", criterion: "Do the second thing."}
      ])

    assert prompt =~ "You are this person: Garen, a builder.\n"
    assert prompt =~ "\n- a_one: Do the first thing.\n- b_two: Do the second thing.\n"
    refute prompt =~ "<activities>"
    refute prompt =~ "<character>"
    refute String.ends_with?(prompt, "\n")
  end

  # 用户消息 = 三块材料 + 末行：返回 {前面的全部, 末行}。
  defp split_last(message) do
    [last | rest] = message |> String.split("\n\n") |> Enum.reverse()
    {rest |> Enum.reverse() |> Enum.join("\n\n"), last}
  end
end
