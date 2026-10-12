defmodule NpcServer.NpcEmotionProbeTest do
  @moduledoc "只测试：真实模型受控输入对照；合成情境经正式请求组装与评价接纳，不启动或修改任何运行中世界。"
  use ExUnit.Case, async: false
  @moduletag :live_llm
  @moduletag timeout: 1_800_000
  alias NpcServer.{Brain.Llm, Http, Responses}
  alias NpcServer.Life.{State, Appraisal}

  test "固定处境下测量强度和对象敏感性，再观察代表性评价" do
    out = Path.join(System.fetch_env!("NPC_EMOTION_OUT"), "probe")
    refute File.exists?(out)
    File.mkdir_p!(out)

    endpoint = %{
      url: System.fetch_env!("NPC_LLM_URL"),
      key: System.fetch_env!("NPC_LLM_KEY"),
      model: System.fetch_env!("NPC_LLM_MODEL"),
      effort: System.fetch_env!("NPC_LLM_EFFORT"),
      timeout_ms: 180_000
    }

    {_, profile} =
      NpcServer.Registry.brain("life", %{
        "goal" => "你是尊重他人劳动、重视合作与事实的调查员。甲和乙都邀请你下一次合作调查，你现在可自行决定如何回应或行动。使用简洁中文。",
        "tools" => %{},
        "groups" => ["move", "dialogue"],
        "life" => %{"url" => "http://unused.invalid"}
      })

    profile = %{profile | endpoint: endpoint}
    base = State.new(11, "synthetic-probe", 0, 0) |> Appraisal.enable()

    observation = %{
      self: %{entity_id: 11, tick: 1, position: {0.0, 65.0, 0.0}},
      pending: [],
      balances: [],
      entities: [
        %{entity_id: 12, name: "甲", position: {3.0, 65.0, 0.0}},
        %{entity_id: 13, name: "乙", position: {-3.0, 65.0, 0.0}}
      ]
    }

    memories = ["甲和乙此前都损坏过我的调查标记，之后已各自修复。我今天没有紧急任务。两人现在都邀请我合作，尚未答复。"]
    conditions = [{"low_a", 0.05, 12}, {"high_a", 0.8, 12}, {"high_b", 0.8, 13}]

    rows =
      for {label, intensity, actor} <- conditions ++ Enum.reverse(conditions) do
        state = seed(base, "anger", intensity, actor)

        context = %{
          mind: Appraisal.mind(State.view(state, 0)),
          emotion_context: Appraisal.context(state),
          memories: memories
        }

        body = Llm.body(profile, observation, [], context)
        run(out, label, endpoint, body, state)
      end

    scenarios = [
      {"insult", "你重视劳动尊严，刚向邻居分享了辛苦整理的记录。", "speech",
       %{"speaker_id" => 12, "text" => "你的记录都是垃圾，你也毫无价值，我故意当众羞辱你。"}, nil},
      {"help", "你重视合作，急需同伴帮忙整理调查资料。", "outcome",
       %{"actor" => 12, "status" => "done", "event" => "邻居主动替你完成了急需的资料整理，结果已验收。"}, nil},
      {"expectation_failed", "你此前期待今天能完成一次重要调查，已经为此做了准备。", "outcome",
       %{"status" => "rejected", "event" => "调查因场地封闭被取消，今天无法完成。"}, "hope"},
      {"danger_removed", "你此前担心调查笔记会在漏水中损毁。", "outcome",
       %{"status" => "done", "event" => "已检查：漏水停止，笔记全部完好，损毁危险解除。"}, "fear"}
    ]

    scenario_rows =
      for {label, goal, kind, data, prior} <- scenarios do
        state = if prior, do: seed(base, prior, 0.6, nil), else: base
        state = Appraisal.enqueue(state, kind, data, [12], 0)

        body =
          Llm.body(%{profile | goal: goal <> "根据当前处境自行行动。使用简洁中文。"}, observation, [], %{
            mind: Appraisal.mind(State.view(state, 0)),
            emotion_context: Appraisal.context(state),
            memories: []
          })

        run(out, label, endpoint, body, state)
      end

    File.write!(
      Path.join(out, "summary.json"),
      Jason.encode!(
        %{
          classification: "controlled synthetic model probe",
          behavior: rows,
          scenarios: scenario_rows,
          limitation: "每条件两次，仅报告观察差异，不证明统计稳定或真实世界动作结果"
        },
        pretty: true
      )
    )
  end

  test "相同处境只交换既有恐惧与感激对象，移动目的地随对象改变" do
    out = Path.join(System.fetch_env!("NPC_EMOTION_OUT"), "movement-contrast")
    refute File.exists?(out)
    File.mkdir_p!(out)

    endpoint = %{
      url: System.fetch_env!("NPC_LLM_URL"),
      key: System.fetch_env!("NPC_LLM_KEY"),
      model: System.fetch_env!("NPC_LLM_MODEL"),
      effort: System.fetch_env!("NPC_LLM_EFFORT"),
      timeout_ms: 180_000
    }

    {_, profile} =
      NpcServer.Registry.brain("life", %{
        "goal" => "今天的工作已完成，你准备在附近选一个地方休息。这是可步行的平地；你重视安全，也珍惜同伴的善意，请自主决定去哪里。",
        "tools" => %{},
        "groups" => ["move"],
        "life" => %{"url" => "http://unused.invalid"}
      })

    profile = %{profile | endpoint: endpoint}

    observation = %{
      self: %{entity_id: 11, tick: 1, position: {3.0, 65.0, 10.0}},
      pending: [],
      balances: [],
      entities: [
        %{entity_id: 12, name: "甲", position: {7.0, 65.0, 10.0}},
        %{entity_id: 13, name: "乙", position: {-1.0, 65.0, 10.0}}
      ]
    }

    rows =
      for {label, feared, appreciated} <- [{"fear_a", 12, 13}, {"fear_b", 13, 12}] do
        state =
          State.new(11, "synthetic-movement-probe", 0, 0)
          |> Appraisal.enable()
          |> Appraisal.enqueue("probe", %{"description" => "此前的交往已结束，目前没有新消息"}, [12, 13], 0)

        entries =
          for {emotion, actor} <- [{"fear", feared}, {"gratitude", appreciated}],
              do: %{
                "emotion" => emotion,
                "intensity" => 0.8,
                "source_seq" => 1,
                "target_id" => actor,
                "reason" => "此前交往留下的感受"
              }

        assert {:ok, state} = Appraisal.apply(state, 1, entries, 0)

        body =
          Llm.body(profile, observation, [], %{
            mind: Appraisal.mind(State.view(state, 0)),
            emotion_context: Appraisal.context(state),
            memories: []
          })

        row = run(out, label, endpoint, body, state)
        assert row.call == "move_to", "本次没有选择移动；不重试掩盖结果"
        {fear_x, help_x} = if feared == 12, do: {7.0, -1.0}, else: {-1.0, 7.0}
        x = row.arguments["x"]
        z = row.arguments["z"]
        fear_distance = :math.sqrt((x - fear_x) ** 2 + (z - 10.0) ** 2)
        help_distance = :math.sqrt((x - help_x) ** 2 + (z - 10.0) ** 2)
        assert fear_distance > 5.0
        assert help_distance < 3.0
        Map.merge(row, %{fear_distance: fear_distance, help_distance: help_distance})
      end

    File.write!(
      Path.join(out, "summary.json"),
      Jason.encode!(
        %{status: "passed", rows: rows, limitation: "两次受控模型探针，只有情绪对象改变；此处不执行世界动作，不证明统计稳定性"},
        pretty: true
      )
    )
  end

  defp run(out, label, endpoint, body, state) do
    id = System.unique_integer([:positive, :monotonic])
    path = Path.join(out, "#{id}-#{label}")
    File.write!(path <> "-request.json", Jason.encode!(body, pretty: true))
    result = Http.request(endpoint, body)

    File.write!(
      path <> "-response.json",
      Jason.encode!(NpcServer.Context.plain(result), pretty: true)
    )

    assert {:ok, response} = result
    assert [call] = Responses.function_calls(response)
    assert {:ok, args} = call.arguments

    assert {:ok, _} =
             Appraisal.apply(state, Appraisal.context(state).through, args["appraisal"], 0)

    assert [%{verb: verb}] = Llm.commands(response, 1, %{tools: %{}, groups: [:move, :dialogue]})
    refute verb in [:invalid_tool_arguments, :unknown_tool]
    row = %{condition: label, call: call.name, arguments: args, usage: response["usage"]}
    IO.puts("NPC_EMOTION_PROBE " <> Jason.encode!(row))
    row
  end

  defp seed(base, emotion, intensity, actor) do
    state = Appraisal.enqueue(base, "probe", %{}, if(actor, do: [actor], else: []), 0)

    {:ok, state} =
      Appraisal.apply(
        state,
        1,
        [
          %{
            "emotion" => emotion,
            "intensity" => intensity,
            "source_seq" => 1,
            "target_id" => actor,
            "reason" => "受控实验的既有情绪"
          }
        ],
        0
      )

    state
  end
end
