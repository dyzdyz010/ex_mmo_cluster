defmodule GateServer.NpcJevTest do
  @moduledoc "只测试：Jev 调度层的请求形状与决定规则。应答样本按官方 HTTP 文档的形状手写；真实接口见 :live_jev 用例。"
  use ExUnit.Case, async: true
  alias GateServer.Npc.Jev
  @profile GateServer.Npc.Brain.Builder.activity_profile()

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  test "unrelated activities and priority come only from the supplied profile; unknown choices never become atoms" do
    profile = %{instructions: "Choose the next task. Carry water before following the player.",
      activities: %{"carry_water" => "Move water from the pool to the empty pit.",
        "follow_player" => "Follow the designated player while keeping a walking distance."}}
    body = Jev.body(%{model: "m"}, profile, "The pit is empty and the player is waiting.")
    assert body.questions.activity.instructions == profile.instructions
    assert body.questions.activity.criteria == profile.activities
    assert {:act, "carry_water"} == Jev.verdict(response("carry_water", 0.99), profile)
    assert {:act, "follow_player"} == Jev.verdict(response("follow_player", 0.99), profile)
    assert {:escalate, :unknown_activity} == Jev.verdict(response("not_in_the_profile_293827", 0.99), profile)
    assert {:blocked, :harms_others} == Jev.verdict(response("carry_water", 0.99, 0.16), profile)
  end

  defp response(choice, confidence, harm \\ nil) do
    answers = %{"activity" => %{"type" => "choice", "choice" => choice, "confidence" => confidence}}
    %{"answers" => if(harm, do: Map.put(answers, "harm", %{"type" => "noul", "noul" => harm}), else: answers)}
  end

  test "request: one state, typed questions; harm is asked only when an action is planned" do
    body = Jev.body(%{model: "jev-latest"}, @profile, "The last block was placed.")
    assert "jev-latest" == body.model
    assert "The last block was placed." == body.state
    assert [:activity] == body.questions |> Map.keys() |> Enum.sort()
    assert Enum.sort(Map.keys(@profile.activities)) == body.questions.activity.criteria |> Map.keys() |> Enum.sort()

    body = Jev.body(%{model: "m"}, @profile, "Out of stone.", "mine the wall next door")
    assert "Out of stone. Planned action: mine the wall next door" == body.state
    assert [:activity, :harm] == body.questions |> Map.keys() |> Enum.sort()
    # 线上是纯 JSON：noul 的判据键是字符串 "true" / "false"。
    assert %{"true" => _, "false" => _} = Jason.decode!(Jason.encode!(body.questions.harm.criteria))
  end

  test "verdict: profile choices remain strings; doubt escalates; possible harm to others blocks" do
    assert {:act, "continue_building"} == Jev.verdict(response("continue_building", 0.97), @profile)
    assert {:act, "fetch_material"} == Jev.verdict(response("fetch_material", 0.85), @profile)
    # 差一点不到阈值：不硬选。
    assert {:escalate, :low_confidence} == Jev.verdict(response("fetch_material", 0.84), @profile)
    # replan 和其他合法 activity 一样只返回字符串，其含义由调用方解释。
    assert {:act, "replan"} == Jev.verdict(response("replan", 0.99), @profile)
    # harm：只有明确判否（≤ 0.15）才放行；0.16 就拦下，且优先于其他一切。
    assert {:act, "continue_building"} == Jev.verdict(response("continue_building", 0.99, 0.15), @profile)
    assert {:blocked, :harms_others} == Jev.verdict(response("continue_building", 0.99, 0.16), @profile)
    assert {:blocked, :harms_others} == Jev.verdict(response("replan", 0.3, 0.9), @profile)
  end

  test "ask goes through the injected sender and returns the verdict with the raw response" do
    sender = fn %{model: "m"}, %{state: "s"} -> {:ok, response("move_to_safety", 1.0)} end
    assert {:ok, {:act, "move_to_safety"}, %{"answers" => _}} = Jev.ask(%{model: "m"}, @profile, "s", nil, sender)
    assert {:error, {429, "slow down"}} == Jev.ask(%{model: "m"}, @profile, "s", nil, fn _, _ -> {:error, {429, "slow down"}} end)
  end

  # 调度层的验收：评测目录里手工标注的 35 条调度情境，用本模块的原样问法过真实模型。
  # 门槛：自动执行的决定里零错；自动通过率不低于八成（其余升级给规划者，只是多花一次 LLM）。
  @tag :live_jev
  @tag timeout: 300_000
  test "the real model on the hand-labelled scheduling cases: no wrong automatic decision, at least 80 % automatic" do
    endpoint = %{url: System.fetch_env!("TYPESAFE_API_URL"), key: System.fetch_env!("TYPESAFE_API_KEY"), model: System.fetch_env!("TYPESAFE_MODEL")}

    cases =
      Path.expand("../../../../docs/10-active/cross-cutting/tools/jev/cases.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("cases")
      |> Enum.filter(&(&1["question"]["type"] == "choice"))

    assert 35 == length(cases)

    results =
      for c <- cases do
        IO.puts("live_jev case=#{c["id"]} request_started")
        {:ok, verdict, _} = Jev.ask(endpoint, @profile, c["state"])
        IO.puts("live_jev case=#{c["id"]} verdict=#{inspect(verdict)}")
        expected = {:act, c["expected"]}
        {c["id"], expected, verdict}
      end

    automatic = Enum.reject(results, &match?({_, _, {:escalate, :low_confidence}}, &1))
    assert [] == Enum.reject(automatic, fn {_, expected, verdict} -> expected == verdict end)
    IO.inspect({length(automatic), length(results)}, label: "jev_automatic_of_total")
    assert length(automatic) >= 28
  end

  @tag :live_jev
  test "the real model: routine, danger, shortage, surprise and harm to others" do
    endpoint = %{url: System.fetch_env!("TYPESAFE_API_URL"), key: System.fetch_env!("TYPESAFE_API_KEY"), model: System.fetch_env!("TYPESAFE_MODEL")}
    base = "You are a builder NPC in a voxel world, building a small stone hut from a blueprint. "

    for {situation, action, expected} <- [
          {"The last block was placed successfully. Material is sufficient. Nobody is around.", nil, {:act, "continue_building"}},
          {"The wooden scaffold you are standing on has caught fire.", nil, {:act, "move_to_safety"}},
          {"Material check by the game code: not enough stone for the next step. Everything else is normal.", nil, {:act, "fetch_material"}},
          {"You looked at the site: the entire east wall that was finished earlier is gone.", nil, {:act, "replan"}},
          {"You are out of stone.", "mine blocks out of the wall of a player's house next door because it is the nearest stone", {:blocked, :harms_others}}
        ] do
      IO.puts("live_jev scenario=#{situation} request_started")
      {:ok, verdict, %{"answers" => answers}} = Jev.ask(endpoint, @profile, base <> situation, action)
      IO.puts("live_jev verdict=#{inspect(verdict)}")
      assert expected == verdict, "#{situation} -> #{inspect(answers)}"
    end
  end
end
