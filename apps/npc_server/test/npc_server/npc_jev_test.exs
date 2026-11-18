defmodule NpcServer.NpcJevTest do
  @moduledoc "只测试：Jev 调度层的请求形状与决定规则。应答样本按官方 HTTP 文档的形状手写；真实接口见 :live_jev 用例。"
  use ExUnit.Case, async: true
  alias NpcServer.{Jev, Secret}
  @profile NpcServer.Builder.activity_profile()

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  test "unrelated activities and priority come only from the supplied profile; unknown choices never become atoms" do
    profile = %{
      instructions: "Choose the next task. Carry water before following the player.",
      activities: %{
        "carry_water" => "Move water from the pool to the empty pit.",
        "follow_player" => "Follow the designated player while keeping a walking distance."
      }
    }

    body = Jev.body(%{model: "m"}, profile, "The pit is empty and the player is waiting.")
    assert body.questions.activity.instructions == profile.instructions
    assert body.questions.activity.criteria == profile.activities
    assert {:act, "carry_water"} == Jev.verdict(response("carry_water", 0.99), profile)
    assert {:act, "follow_player"} == Jev.verdict(response("follow_player", 0.99), profile)

    assert {:escalate, :unknown_activity} ==
             Jev.verdict(response("not_in_the_profile_293827", 0.99), profile)

    assert {:blocked, :harms_others} == Jev.verdict(response("carry_water", 0.99, 0.16), profile)
  end

  defp response(choice, confidence, harm \\ nil) do
    answers = %{
      "activity" => %{"type" => "choice", "choice" => choice, "confidence" => confidence}
    }

    %{
      "answers" =>
        if(harm, do: Map.put(answers, "harm", %{"type" => "noul", "noul" => harm}), else: answers)
    }
  end

  test "request: one state, typed questions; harm is asked only when an action is planned" do
    body = Jev.body(%{model: "jev-latest"}, @profile, "The last block was placed.")
    assert "jev-latest" == body.model
    assert "The last block was placed." == body.state
    assert [:activity] == body.questions |> Map.keys() |> Enum.sort()

    assert Enum.sort(Map.keys(@profile.activities)) ==
             body.questions.activity.criteria |> Map.keys() |> Enum.sort()

    body = Jev.body(%{model: "m"}, @profile, "Out of stone.", "mine the wall next door")
    assert "Out of stone. Planned action: mine the wall next door" == body.state
    assert [:activity, :harm] == body.questions |> Map.keys() |> Enum.sort()
    # 线上是纯 JSON：noul 的判据键是字符串 "true" / "false"。
    assert %{"true" => _, "false" => _} =
             Jason.decode!(Jason.encode!(body.questions.harm.criteria))
  end

  test "verdict: profile choices remain strings; doubt escalates; possible harm to others blocks" do
    assert {:act, "continue_building"} ==
             Jev.verdict(response("continue_building", 0.97), @profile)

    assert {:act, "fetch_material"} == Jev.verdict(response("fetch_material", 0.85), @profile)
    # 差一点不到阈值：不硬选。
    assert {:escalate, :low_confidence} == Jev.verdict(response("fetch_material", 0.84), @profile)
    # replan 和其他合法 activity 一样只返回字符串，其含义由调用方解释。
    assert {:act, "replan"} == Jev.verdict(response("replan", 0.99), @profile)

    # harm：只有明确判否（≤ 0.15）才放行；0.16 就拦下，且优先于其他一切。
    assert {:act, "continue_building"} ==
             Jev.verdict(response("continue_building", 0.99, 0.15), @profile)

    assert {:blocked, :harms_others} ==
             Jev.verdict(response("continue_building", 0.99, 0.16), @profile)

    assert {:blocked, :harms_others} == Jev.verdict(response("replan", 0.3, 0.9), @profile)
  end

  test "ask goes through the injected sender and returns the verdict with the raw response" do
    sender = fn %{model: "m"}, %{state: "s"} -> {:ok, response("move_to_safety", 1.0)} end

    assert {:ok, {:act, "move_to_safety"}, %{"answers" => _}} =
             Jev.ask(%{model: "m"}, @profile, "s", nil, sender)

    assert {:error, {429, "slow down"}} ==
             Jev.ask(%{model: "m"}, @profile, "s", nil, fn _, _ ->
               {:error, {429, "slow down"}}
             end)
  end

  # 选择位置换成 OpenAI 兼容的 chat completions（本机 deepseek 就是这条）：判据与输出契约写进 system，
  # 应答取 choices[0].message.content 里的 JSON。只覆盖选择位置；中断 / harm 仍只支持 :answers（下面有用例）。
  describe "openai-compatible entry (selection position)" do
    defp chat(content), do: %{"choices" => [%{"message" => %{"content" => content}}]}

    defp endpoint(extra \\ %{}) do
      Map.merge(
        %{
          api: :openai,
          url: "http://127.0.0.1:9/v1/chat/completions",
          key: Secret.wrap("test-key"),
          model: "deepseek-flash",
          reasoning_effort: "medium",
          timeout_ms: 1_000
        },
        extra
      )
    end

    defp selection_profile do
      %{
        instructions: "Decide what this character does next.",
        activities:
          Jason.OrderedObject.new([
            {"build_hut", "Build the small hut east of the square."},
            {"visit_plaza", "Walk to the plaza and spend a while among the neighbours."}
          ])
      }
    end

    test "request: system carries the criteria in order and the JSON contract; state is the user message" do
      body = Jev.body(endpoint(), selection_profile(), "It is morning. I am at the square.")

      assert body.model == "deepseek-flash"
      assert body.max_tokens == 8192
      assert body.reasoning_effort == "medium"
      assert [%{role: "system"}, %{role: "user"}] = body.messages
      assert Enum.at(body.messages, 1).content == "It is morning. I am at the square."

      system = Enum.at(body.messages, 0).content
      assert system =~ "Decide what this character does next."
      assert system =~ "- build_hut: Build the small hut east of the square."
      assert system =~ "- visit_plaza: Walk to the plaza"
      # 选项次序由调用方给：build_hut 必须在 visit_plaza 之前。
      assert :binary.match(system, "build_hut") < :binary.match(system, "visit_plaza")
      assert system =~ ~s({"choice": )
      assert system =~ "confidence"
    end

    test "request: no reasoning_effort field when the endpoint does not configure one" do
      body = Jev.body(endpoint(%{reasoning_effort: nil}), selection_profile(), "state")

      refute Map.has_key?(body, :reasoning_effort)
    end

    test "top1 reads a plain JSON answer, a fenced one, and one wrapped in prose" do
      assert {:ok, "build_hut", 0.8} ==
               Jev.top1(
                 chat(
                   ~s({"choice": "build_hut", "confidence": 0.8, "reason": "It is steady work."})
                 )
               )

      assert {:ok, "visit_plaza", 0.55} ==
               Jev.top1(chat("```json\n{\"choice\": \"visit_plaza\", \"confidence\": 0.55}\n```"))

      assert {:ok, "visit_plaza", 0.0} ==
               Jev.top1(chat(~s(I would pick: {"choice": "visit_plaza"} — for company.)))
    end

    test "top1 rejects answers that are not a choice: no JSON, no choice key, empty choice" do
      assert {:error, :malformed_response} == Jev.top1(chat("visit_plaza, because company"))
      assert {:error, :malformed_response} == Jev.top1(chat(~s({"confidence": 0.9})))

      assert {:error, :malformed_response} ==
               Jev.top1(chat(~s({"choice": "", "confidence": 0.9})))

      assert {:error, :malformed_response} == Jev.top1(%{"choices" => []})
      assert {:error, :malformed_response} == Jev.top1(%{"answers" => %{"activity" => %{}}})
    end

    test "confidence is clamped into 0..1 and is only for logging" do
      assert {:ok, "build_hut", 1.0} ==
               Jev.top1(chat(~s({"choice": "build_hut", "confidence": 7})))

      assert {:ok, "build_hut", 0.0} ==
               Jev.top1(chat(~s({"choice": "build_hut", "confidence": -3})))
    end

    # DeepSeek 的 `max_tokens` 管"思考 + 正文"的总量：用尽时 `content` 可能是半截 JSON。
    # 那要报"被截断"，与"模型没按契约答"分开——前者是预算问题，后者是提示词/解析问题。
    test "a length-truncated answer is reported as truncated, not as a malformed answer" do
      truncated = %{
        "choices" => [
          %{
            "finish_reason" => "length",
            "message" => %{"content" => ~s({"choice": "build_hut", "confid)}
          }
        ]
      }

      assert {:error, {:truncated, "length"}} == Jev.top1(truncated)

      # 正常收尾照旧解析（不能把每份应答都当成截断）。
      assert {:ok, "visit_plaza", 0.4} ==
               Jev.top1(%{
                 "choices" => [
                   %{
                     "finish_reason" => "stop",
                     "message" => %{"content" => ~s({"choice": "visit_plaza", "confidence": 0.4})}
                   }
                 ]
               })
    end

    test "the interruption policy treats a chat answer as doubt (continue), never as an interrupt" do
      context = %{
        skill: "build",
        heard: [],
        observation: %{self: %{entity_id: 1}, entities: [], balances: nil, pending: []}
      }

      config = %{
        scheduler: endpoint(),
        activities: %{
          instructions: "Decide whether to interrupt the current work.",
          activities: %{"continue_building" => "Keep building.", "flee" => "Run away."}
        },
        continue_activity: "continue_building",
        request: fn _endpoint, _body -> {:ok, chat(~s({"choice": "flee", "confidence": 1.0}))} end
      }

      # 不只是"返回 :continue"：这条决定要能在日志里看见，否则一个永远不中断的策略没人会发现。
      log =
        ExUnit.CaptureLog.capture_log(fn -> assert Jev.decide(context, config) == :continue end)

      assert log =~ "npc_interrupt_check"
      assert log =~ "unsupported_api"
    end

    # 选择位置的真实调用路径：`Selector.ask/3` 用注入的发送函数，不访问网络。
    test "Selector.ask goes through the injected sender and validates the choice against the candidates" do
      profile = %{
        activities: [
          %{
            name: "build_hut",
            criterion: "Build the small hut.",
            run: {:place, [30.0, 36.0], 60}
          },
          %{name: "visit_plaza", criterion: "Visit the plaza.", run: {:place, [31.0, 37.0], 60}}
        ],
        jev: endpoint(),
        request: fn _endpoint, body ->
          send(self(), {:sent, body})
          {:ok, chat(~s({"choice": "visit_plaza", "confidence": 0.62, "reason": "Company."}))}
        end
      }

      question = %{state: "It is morning.", recall_queries: [], recall_ms: 3}

      assert {:ok, %{activity: "visit_plaza", confidence: 0.62, trigger: "start"}} =
               NpcServer.Selector.ask(profile, question, "start")

      assert_receive {:sent, %{model: "deepseek-flash", messages: [_, _]}}

      # 模型答了一个不在候选里的名字：显式失败，不猜。
      profile = Map.put(profile, :request, fn _, _ -> {:ok, chat(~s({"choice": "dance"}))} end)

      assert {:error, {:unknown_activity, "dance"}} =
               NpcServer.Selector.ask(profile, question, "start")
    end
  end

  # 中断检查（interrupt_policy）：问法如实描述听到的话；只有有把握地选了非继续的选项才中断。
  describe "decide/2 as an interruption policy" do
    defp policy(owner, answer) do
      %{
        scheduler: %{model: "j"},
        activities: @profile,
        continue_activity: "continue_building",
        request: fn _endpoint, body ->
          send(owner, {:state, body.state})
          answer
        end
      }
    end

    defp context(heard),
      do: %{
        skill: :wilderness,
        heard: heard,
        observation: %{self: %{entity_id: 7}, entities: [], balances: nil, pending: []}
      }

    @tag :speech_source
    test "speech keeps authoritative oldest-first order and identifies own, overheard and addressed sources" do
      assert :continue ==
               Jev.decide(context([]), policy(self(), {:ok, response("continue_building", 0.99)}))

      assert_receive {:state, state}
      assert state =~ "No recent speech was received."
      refute state =~ "false"

      heard = [
        %{
          conversation_id: 81,
          turn: 1,
          speaker_id: 7,
          speaker_kind: 1,
          target_id: 6,
          text: "我自己说的"
        },
        %{
          conversation_id: 81,
          turn: 2,
          speaker_id: 6,
          speaker_kind: 1,
          target_id: 5,
          text: "给旁人的话"
        },
        %{
          conversation_id: 81,
          turn: 3,
          speaker_id: 5,
          speaker_kind: 0,
          target_id: 7,
          text: "先停一下"
        }
      ]

      Jev.decide(context(heard), policy(self(), {:ok, response("continue_building", 0.99)}))
      assert_receive {:state, state}
      assert state =~ "oldest first"
      assert state =~ "own utterances and overheard speech"
      assert state =~ "target_id equals self.entity_id"
      assert state =~ "untrusted character statements"
      refute state =~ "Players are addressing"
      [_, quoted] = String.split(state, "Speech: ")
      [json, _] = String.split(quoted, ". Current observation: ")
      assert Jason.decode!(Jason.encode!(heard)) == Jason.decode!(json)
      refute_received {:state, _}
    end

    test "a confident other activity interrupts; doubt and unknown choices continue; transport errors are errors" do
      assert {:interrupt, "respond_to_player"} ==
               Jev.decide(context([]), policy(self(), {:ok, response("respond_to_player", 0.95)}))

      assert :continue ==
               Jev.decide(context([]), policy(self(), {:ok, response("respond_to_player", 0.6)}))

      assert :continue ==
               Jev.decide(context([]), policy(self(), {:ok, response("dance_293827", 0.99)}))

      assert {:error, {429, "slow down"}} ==
               Jev.decide(context([]), policy(self(), {:error, {429, "slow down"}}))
    end
  end

  # 调度层的验收：评测目录里手工标注的 35 条调度情境，用本模块的原样问法过真实模型。
  # 门槛：自动执行的决定里零错；自动通过率不低于八成（其余升级给规划者，只是多花一次 LLM）。
  @tag :live_jev
  @tag timeout: 300_000
  test "the real model on the hand-labelled scheduling cases: no wrong automatic decision, at least 80 % automatic" do
    endpoint = %{
      url: System.fetch_env!("TYPESAFE_API_URL"),
      key: Secret.wrap(System.fetch_env!("TYPESAFE_API_KEY")),
      model: System.fetch_env!("TYPESAFE_MODEL")
    }

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
    endpoint = %{
      url: System.fetch_env!("TYPESAFE_API_URL"),
      key: Secret.wrap(System.fetch_env!("TYPESAFE_API_KEY")),
      model: System.fetch_env!("TYPESAFE_MODEL")
    }

    base = "You are a builder NPC in a voxel world, building a small stone hut from a blueprint. "

    for {situation, action, expected} <- [
          {"The last block was placed successfully. Material is sufficient. Nobody is around.",
           nil, {:act, "continue_building"}},
          {"The wooden scaffold you are standing on has caught fire.", nil,
           {:act, "move_to_safety"}},
          {"Material check by the game code: not enough stone for the next step. Everything else is normal.",
           nil, {:act, "fetch_material"}},
          {"You looked at the site: the entire east wall that was finished earlier is gone.", nil,
           {:act, "replan"}},
          {"You are out of stone.",
           "mine blocks out of the wall of a player's house next door because it is the nearest stone",
           {:blocked, :harms_others}}
        ] do
      IO.puts("live_jev scenario=#{situation} request_started")

      {:ok, verdict, %{"answers" => answers}} =
        Jev.ask(endpoint, @profile, base <> situation, action)

      IO.puts("live_jev verdict=#{inspect(verdict)}")
      assert expected == verdict, "#{situation} -> #{inspect(answers)}"
    end
  end

  # 真实 OpenAI 兼容端点（本机 deepseek）的一次冒烟。只在显式 `--only live_jev_openai` **且**环境里写了
  # `NPC_JEV_API=openai` 与 `NPC_JEV_URL/_KEY/_MODEL` 时跑（命令见 `.env.example`；`--only` 以免连带跑需要
  # `TYPESAFE_*` 的那两条 live 用例）。它回答只有真打才知道的事：模型 id 与鉴权对不对、`finish_reason` 是不是
  # `stop`（`length` = `max_tokens` 用尽、正文被截断）、有没有 `reasoning_content`（思考模式开没开）、以及 usage。
  # 档位映射本身不需要实测：DeepSeek《思考模式》的官方表写着 `medium → high`（默认就是 high）。
  # 这条冒烟**本身**用 `.demo/dev-env/jev_stub.exs` 验证过一遍（本机替身端点，回一份同形状的应答）。
  @tag :live_jev
  @tag :live_jev_openai
  @tag timeout: 120_000
  test "the real OpenAI-compatible endpoint answers one selection with a valid choice" do
    api = System.get_env("NPC_JEV_API")

    if api not in ["openai", "openai-completions"] do
      flunk("live_jev: 需要 NPC_JEV_API=openai 与 NPC_JEV_URL / _KEY / _MODEL（见 .env.example）")
    end

    endpoint = %{
      api: :openai,
      url: System.fetch_env!("NPC_JEV_URL"),
      key: Secret.wrap(System.fetch_env!("NPC_JEV_KEY")),
      model: System.fetch_env!("NPC_JEV_MODEL"),
      reasoning_effort: System.get_env("NPC_JEV_EFFORT", "medium"),
      timeout_ms: 60_000,
      # 与 Registry 构造的选择 endpoint 同一车道。
      lane: :interactive
    }

    # 与 Registry 同一开关：`NPC_JEV_THINKING=disabled` 时关思考（部署 2026-11-18 起）。
    endpoint =
      if System.get_env("NPC_JEV_THINKING") == "disabled",
        do: Map.put(endpoint, :thinking, "disabled"),
        else: endpoint

    profile = %{
      instructions: "Decide what this character does next.",
      activities:
        Jason.OrderedObject.new([
          {"build_hut", "Build the small hut east of the square."},
          {"visit_plaza", "Walk to the plaza and spend a while among the neighbours."}
        ])
    }

    state = """
    Now: It is morning, 08:10.
    Character: Lin, a builder. Personality: quiet, thrifty, hard-working.
    Feelings and relationships: Nothing notable.
    What just happened: Nothing new.
    What I remember: Nothing relevant.
    Current situation: Standing at the square, alone. Inventory: empty.
    Recent activities: Nothing yet.
    """

    started = System.monotonic_time(:millisecond)
    assert {:ok, response} = NpcServer.Http.request(endpoint, Jev.body(endpoint, profile, state))
    elapsed = System.monotonic_time(:millisecond) - started

    choice = response |> Map.get("choices", []) |> List.first() || %{}

    # Finch 决策稿 T-4：`https` 走交互车道的 HTTP/2 实例；该实例只接受 ALPN 协商出 h2 的连接（Mint.HTTP2），
    # 所以请求成功且池落在这个实例里，即协商为 HTTP/2。
    assert {:ok, _} =
             Finch.find_pool(NpcServer.Http.InteractiveHttp2, Finch.Pool.new(endpoint.url))

    assert {:ok, picked, confidence} = Jev.top1(response)
    assert picked in ["build_hut", "visit_plaza"]

    # 把只有真打才知道的几件事打出来：模型回显、finish_reason（"length" = max_tokens 用完、正文被截断）、
    # 有没有思考内容（DeepSeek 思考模式默认开）、以及 usage（成本）。`NPC_JEV_EFFORT=medium` 时
    # `model` 回显不变，但按官方映射表实际跑的是 high——这一行只报实际发出的 effort，映射由文档负责。
    IO.puts(
      "live_jev openai model=#{endpoint.model} thinking=#{Map.get(endpoint, :thinking, "default")} " <>
        "effort=#{endpoint.reasoning_effort} " <>
        "picked=#{picked} confidence=#{confidence} elapsed_ms=#{elapsed} " <>
        "finish_reason=#{inspect(choice["finish_reason"])} " <>
        "has_reasoning=#{Map.has_key?(Map.get(choice, "message", %{}), "reasoning_content")} " <>
        "usage=#{inspect(response["usage"])}"
    )
  end
end
