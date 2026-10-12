Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcEmotionAutomaticTest do
  @moduledoc "只测试：有限真实世界与真实模型的自动等待/对话唤醒；邻居台词是场景刺激，经 Body.say 正常裁决。"
  use ExUnit.Case, async: false
  @moduletag :live_llm
  @moduletag timeout: 600_000
  alias NpcServer.{Body, Life, Http, Responses, Context}
  alias NpcServer.NpcWorld

  defmodule Neighbor do
    @moduledoc "只测试：被作者操作的邻居，不运行自主模型。"
    def init(p), do: p
    def handle_event(_, p), do: {[], p}
  end

  test "自动角色安静等待，真实指向对话唤醒并评价，处理完后停止重复请求" do
    out = Path.join(System.fetch_env!("NPC_EMOTION_OUT"), "automatic")
    refute File.exists?(out)
    File.mkdir_p!(out)
    level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: level) end)
    MmoTest.Database.start!()
    fixture = NpcWorld.start()
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: NpcServer.BodySupervisor})
    start_supervised!({Registry, keys: :duplicate, name: NpcServer.Names})
    suffix = Integer.to_string(System.system_time(:millisecond))

    options = [
      scene_id: 1,
      bounds: {{-60, 40, -60}, {60, 120, 60}},
      claims: fixture.claims,
      route_module: NpcWorld.Route
    ]

    {:ok, peer} =
      Body.start("邻居-" <> suffix, options ++ [spawn: {7.0, 66.0, 10.0}, brain: {Neighbor, %{}}])

    %{actor: %{cid: peer_id}} = context(peer)

    {backend, profile} =
      NpcServer.Registry.brain("life", %{
        "goal" =>
          "你是重视劳动尊严、尊重他人且珍惜自己调查成果的学者。今天的工作已经完成，眼下没有待办，可以休息。有人来沟通时自行决定如何回应；没有新的事情就继续休息，避免重复闲聊。使用简洁中文。",
        "tools" => %{},
        "groups" => ["dialogue"],
        "max_requests_per_hour" => 60,
        "life" => %{"url" => System.fetch_env!("NPC_LIFE_HINDSIGHT_URL")}
      })

    owner = self()
    count = :atomics.new(1, [])

    request = fn endpoint, body ->
      n = :atomics.add_get(count, 1, 1)
      send(owner, {:started, n})
      write(out, "request-#{n}.json", body)
      result = Http.request(endpoint, body)
      write(out, "response-#{n}.json", result)
      send(owner, {:answered, n, result, Jason.decode!(body.input)})
      result
    end

    {:ok, body} =
      Body.start(
        "学者-" <> suffix,
        options ++
          [spawn: {4.0, 66.0, 10.0}, brain: {backend, Map.put(profile, :request, request)}]
      )

    %{actor: %{cid: cid}} = context(body)

    write(out, "protocol.json", %{
      classification: "Test-only",
      cid: cid,
      peer: peer_id,
      cadence: "automatic",
      max_requests_per_hour: 60,
      source: "正式 Registry.brain/Body.start；真实模型/World/Scene/PG/Hindsight"
    })

    try do
      baseline = settle(cid, [], 5)
      refute_receive {:started, _}, 1_500
      text = "我故意当面羞辱你：你辛苦整理的调查记录全是垃圾，你的劳动毫无价值。"

      command =
        NpcServer.Abilities.command(
          "say",
          %{"text" => text, "target_id" => cid, "conversation_id" => nil},
          :stimulus,
          %{}
        )

      Body.command(peer, command)

      NpcWorld.await(fn ->
        Enum.any?(Body.observe(peer).outcomes, &match?(%{id: :stimulus}, &1))
      end)

      assert %{status: :done} = Enum.find(Body.observe(peer).outcomes, &(&1.id == :stimulus))

      after_speech = settle(cid, [], 5 - length(baseline))
      refute_receive {:started, _}, 2_000
      assert after_speech != []
      entries = for row <- after_speech, e <- row.args["appraisal"], do: e
      assert entries != [], "本次真实对话未激发情绪，保留原始结果"
      assert Enum.all?(entries, &(&1["target_id"] in [nil, peer_id, cid]))
      {:ok, life} = Life.observe(cid)
      assert life.error == nil
      assert life.state["affect"]["cursor"] == life.state["affect"]["next_seq"]
      assert :atomics.get(count, 1) < 5, "场景应在最多四次模型请求内安静下来"

      write(out, "summary.json", %{
        status: "passed",
        baseline: baseline,
        after_speech: after_speech,
        requests: :atomics.get(count, 1),
        life: life,
        limitation: "短自动场景，不是长期浸泡或UE验收"
      })
    after
      write(out, "final.json", %{
        life: Life.observe(cid),
        body: Body.observe(body),
        persisted: DataService.NpcMemory.get(cid, "life", "state"),
        peer: Body.observe(peer)
      })
    end
  end

  defp settle(cid, rows, left) do
    assert left > 0, "没有在预算内安静下来"
    assert_receive {:started, n}, 20_000
    assert_receive {:answered, ^n, result, input}, 190_000
    assert {:ok, response} = result
    assert [call] = Responses.function_calls(response)
    assert {:ok, args} = call.arguments
    through = input["emotion_context"]["through"]

    NpcWorld.await(fn ->
      {:ok, life} = Life.observe(cid)
      life.state["affect"]["cursor"] >= through
    end)

    row = %{request: n, tool: call.name, args: args, usage: response["usage"]}
    IO.puts("NPC_EMOTION_AUTOMATIC " <> Jason.encode!(row))
    rows = rows ++ [row]
    {:ok, life} = Life.observe(cid)

    if call.name == "wait" and life.state["affect"]["cursor"] == life.state["affect"]["next_seq"],
      do: rows,
      else: settle(cid, rows, left - 1)
  end

  defp context(body),
    do:
      NpcWorld.await(fn ->
        case Body.skill_context(body) do
          {:ok, c} -> c
          _ -> false
        end
      end)

  defp write(out, name, value),
    do: File.write!(Path.join(out, name), Jason.encode!(Context.plain(value), pretty: true))
end
