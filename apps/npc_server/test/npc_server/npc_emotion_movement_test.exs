Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcEmotionMovementTest do
  @moduledoc "只测试：真实移动场景；Hindsight 替身隔离记忆，模型替身干跑后显式运行真实模型。"
  use ExUnit.Case, async: false
  alias NpcServer.{Abilities, Body, Context, Http, Life, Responses}
  alias NpcServer.NpcWorld

  defmodule Memory do
    @moduledoc "只测试：不涉及本场景的长期记忆接口替身。"
    def ensure(_, _), do: {:ok, %{}}
    def models(_), do: {:ok, %{models: %{}, metadata: %{}}}
    def status(_), do: {:ok, %{}}
    def recall(_, _, _), do: {:ok, %{results: [], latency_ms: 0}}
    def retain(_, _), do: {:ok, %{}}
    def refresh(_), do: models(nil)
  end

  defmodule Neighbor do
    @moduledoc "只测试：作者经正常能力入口控制场景邻居。"
    def init(p), do: p
    def handle_event(_, p), do: {[], p}
  end

  test "移动驱动干跑核对接纳、持久化、距离与权威终态" do
    run(:dry)
  end

  @tag :live_llm
  @tag timeout: 600_000
  test "真实模型评价实际对话，自主选择并执行移动" do
    run(:live)
  end

  defp run(mode) do
    level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: level) end)
    MmoTest.Database.start!()
    fixture = NpcWorld.start()
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: NpcServer.BodySupervisor})
    start_supervised!({Registry, keys: :duplicate, name: NpcServer.Names})

    options = [
      scene_id: 1,
      bounds: {{-60, 40, -60}, {60, 120, 60}},
      claims: fixture.claims,
      route_module: NpcWorld.Route
    ]

    suffix = Integer.to_string(System.system_time(:microsecond))

    {:ok, a} =
      Body.start("甲-" <> suffix, options ++ [spawn: {7.0, 66.0, 10.0}, brain: {Neighbor, %{}}])

    {:ok, b} =
      Body.start("乙-" <> suffix, options ++ [spawn: {-1.0, 66.0, 10.0}, brain: {Neighbor, %{}}])

    a_id = context(a).actor.cid
    b_id = context(b).actor.cid
    owner = self()
    out = if mode == :live, do: Path.join(System.fetch_env!("NPC_EMOTION_OUT"), "movement")

    if out do
      refute File.exists?(out)
      File.mkdir_p!(out)
    end

    {backend, profile} =
      NpcServer.Registry.brain("life", %{
        "goal" =>
          "你是重视安全、珍惜同伴帮助的调查员。今天的工作已完成，现在需要在附近选一个位置休息。这里是可步行的平地，请根据自身感受和眼前处境自行选择停留位置，避免冲突。",
        "tools" => %{},
        "groups" => ["move"],
        "life" => %{"url" => "http://memory.test.invalid"}
      })

    request = fn endpoint, body ->
      input = Jason.decode!(body.input)
      write(out, "request.json", body)

      result =
        if mode == :live, do: Http.request(endpoint, body), else: dry_response(input, a_id, b_id)

      write(out, "response.json", result)
      send(owner, {:answer, input, result})
      result
    end

    profile =
      profile
      |> Map.put(:cadence, :manual)
      |> Map.put(:request, request)
      |> Map.update!(:life, &Map.merge(&1, %{hindsight: Memory, poll_ms: 30}))

    {:ok, body} =
      Body.start(
        "调查员-" <> suffix,
        options ++ [spawn: {3.0, 66.0, 10.0}, brain: {backend, profile}]
      )

    cid = context(body).actor.cid

    try do
      NpcWorld.await(fn ->
        case Life.context(cid, "准备") do
          {:ok, c} ->
            c.emotion_context.sources != [] and map_size(Body.observe(body).entities) >= 2

          _ ->
            false
        end
      end)

      say(a, cid, "我现在就在这里威胁你：我准备伤害你。我不欢迎你靠近。", :threat)
      say(b, cid, "我刚才主动替你整理了辛苦收集的资料，谢谢你的劳动。我尊重你，也不会伤害你，欢迎到我身边休息。", :help)

      NpcWorld.await(fn ->
        {:ok, c} = Life.context(cid, "对话")
        Enum.count(c.emotion_context.sources, &(&1["kind"] == "speech")) == 2
      end)

      body =
        if mode == :dry do
          assert :ok = Body.step(body, self(), :appraisal)
          assert_receive {:answer, _, {:ok, _}}, 5_000
          assert_receive {:npc_llm_step, :appraisal, {:ok, _, _}}, 5_000
          saved = DataService.NpcMemory.get(cid, "life", "state")["state"]["feelings"]
          assert length(saved) == 3
          :ok = DynamicSupervisor.terminate_child(NpcServer.BodySupervisor, body)
          NpcWorld.await(fn -> Life.observe(cid) == {:error, :life_not_running} end)

          {:ok, restarted} =
            Body.start(
              "调查员-" <> suffix,
              options ++ [spawn: {3.0, 66.0, 10.0}, brain: {backend, profile}]
            )

          assert context(restarted).actor.cid == cid

          NpcWorld.await(fn ->
            case Life.observe(cid) do
              {:ok, %{state: %{} = state}} ->
                state["feelings"] == saved and map_size(Body.observe(restarted).entities) >= 2

              _ ->
                false
            end
          end)

          restarted
        else
          body
        end

      before = Body.observe(body)
      write(out, "before.json", before)
      assert :ok = Body.step(body, self(), :movement)
      assert_receive {:answer, input, result}, 190_000
      assert {:ok, response} = result
      assert [call] = Responses.function_calls(response)
      assert {:ok, args} = call.arguments

      if mode == :dry do
        feelings = input["mind"]["feelings"]

        assert Enum.any?(
                 feelings,
                 &(&1["emotion"] == "fear" and &1["object"]["id"] == a_id and
                     &1["intensity"] > 0.7)
               )

        assert Enum.any?(
                 feelings,
                 &(&1["emotion"] == "fear" and &1["object"]["id"] == b_id and
                     &1["intensity"] < 0.3)
               )

        assert Enum.any?(feelings, &(&1["emotion"] == "gratitude" and &1["object"]["id"] == b_id))
      end

      assert_receive {:npc_llm_step, :movement, {:ok, _, [command]}}, 10_000
      assert call.name == "move_to", "本次模型未选择移动，保留失败供观察"

      outcome =
        NpcWorld.await(
          fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == command)) end,
          30_000
        )

      assert outcome.status == :done
      assert outcome.data.settled
      assert outcome.data.within_tolerance
      after_move = Body.observe(body)
      {:ok, life} = Life.observe(cid)
      persisted = DataService.NpcMemory.get(cid, "life", "state")["state"]
      assert persisted["feelings"] == life.state["feelings"]
      refute Map.has_key?(persisted, "emotions")

      assert Enum.any?(
               persisted["feelings"],
               &(&1["emotion"] == "fear" and &1["object"] == %{"kind" => "actor", "id" => a_id})
             )

      assert Enum.any?(
               persisted["feelings"],
               &(&1["emotion"] == "gratitude" and
                   &1["object"] == %{"kind" => "actor", "id" => b_id})
             )

      distances = %{
        a_before: distance(before, a_id),
        a_after: distance(after_move, a_id),
        b_before: distance(before, b_id),
        b_after: distance(after_move, b_id)
      }

      assert distances.a_after > distances.a_before + 1.0
      assert distances.b_after < distances.b_before - 1.0

      write(out, "summary.json", %{
        status: "passed",
        mode: mode,
        cid: cid,
        a: a_id,
        b: b_id,
        distances: distances,
        outcome: outcome,
        args: args,
        input: input,
        life: life,
        usage: response["usage"],
        limitation: "有限服务端场景；Hindsight替身；不是UE入口、战斗或统计因果验证"
      })
    after
      if out,
        do:
          write(out, "final.json", %{
            life: Life.observe(cid),
            body: Body.observe(body),
            a: Body.observe(a),
            b: Body.observe(b)
          })
    end
  end

  defp dry_response(input, a, b) do
    sources = input["emotion_context"]["sources"]

    entries =
      for {actor, emotion, intensity} <- [
            {a, "fear", 0.8},
            {b, "fear", 0.2},
            {b, "gratitude", 0.8}
          ],
          Enum.any?(sources, &(&1["kind"] == "speech")) do
        source =
          Enum.find(sources, &(&1["kind"] == "speech" and &1["data"]["speaker_id"] == actor))

        %{
          "emotion" => emotion,
          "intensity" => intensity,
          "source_seq" => source["seq"],
          "target_id" => actor,
          "reason" => "只测试：检查真实评价与移动接缝"
        }
      end

    {name, args} =
      if entries == [],
        do: {"move_to", %{x: 0.0, y: 64, z: 10.0, appraisal: []}},
        else: {"wait", %{seconds: 3600, appraisal: entries}}

    {:ok,
     %{
       "output" => [
         %{"type" => "function_call", "name" => name, "arguments" => Jason.encode!(args)}
       ]
     }}
  end

  defp say(body, cid, text, id) do
    Body.command(
      body,
      Abilities.command(
        "say",
        %{"text" => text, "target_id" => cid, "conversation_id" => nil},
        id,
        %{}
      )
    )

    assert %{status: :done} =
             NpcWorld.await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == id)) end)
  end

  defp context(body),
    do:
      NpcWorld.await(fn ->
        case Body.skill_context(body) do
          {:ok, c} -> c
          _ -> false
        end
      end)

  defp distance(observation, id) do
    {x, y, z} = observation.position
    {a, b, c} = Map.fetch!(observation.entities, id).position
    :math.sqrt((x - a) ** 2 + (y - b) ** 2 + (z - c) ** 2)
  end

  defp write(nil, _, _), do: :ok

  defp write(out, name, value),
    do: File.write!(Path.join(out, name), Jason.encode!(Context.plain(value), pretty: true))
end
