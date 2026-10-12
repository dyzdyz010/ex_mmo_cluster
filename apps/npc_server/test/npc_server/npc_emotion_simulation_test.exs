Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcEmotionSimulationTest do
  @moduledoc """
  只测试：有限世界里的真实模型情绪模拟。正式 Registry 档案与 Body.start 组合，真实 World/Scene/PG/Hindsight。
  不启动 UE，不证明玩家双端链路；不注入情绪或预写动作。运行产物由 NPC_EMOTION_OUT 指定的新目录保存。
  """
  use ExUnit.Case, async: false
  @moduletag :live_llm
  @moduletag timeout: 900_000
  alias NpcServer.{Body, Life, Context, Http, Responses}
  alias NpcServer.NpcWorld

  test "邻里地面调查产生可追溯情绪并进入后续真实决策" do
    out = System.fetch_env!("NPC_EMOTION_OUT") |> Path.expand()
    refute File.exists?(out), "观察目录必须是新目录"
    File.mkdir_p!(out)
    old_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: old_level) end)
    MmoTest.Database.start!()
    fixture = NpcWorld.start()
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: NpcServer.BodySupervisor})
    start_supervised!({Registry, keys: :unique, name: NpcServer.Names})
    run = Path.basename(out) <> "-" <> Integer.to_string(System.system_time(:millisecond))

    roles = [
      {"知衡", "你是重视实地验证的学者，希望调查脚下地面是什么材料，能否供邻居未来建设使用，并分享真实发现。", {4.0, 66.0, 10.0}},
      {"松岚", "你是重视合作的探索者，希望了解附近地面，向邻居请教并贡献自己的观察；对有用帮助作出自然回应。", {7.0, 66.0, 10.0}}
    ]

    actors =
      for {name, goal, spawn} <- roles do
        {backend, profile} =
          NpcServer.Registry.brain("life", %{
            "goal" => goal <> "你们初次来到这里。实际观察足够就交流或行动，不反复查询同一处。目标完成后可休息。使用简洁中文。",
            "tools" => %{},
            "cadence" => "manual",
            "max_requests_per_hour" => "unlimited",
            "groups" => ["move", "sense", "dialogue", "memory"],
            "life" => %{"url" => System.fetch_env!("NPC_LIFE_HINDSIGHT_URL")}
          })

        request = fn endpoint, body ->
          id = System.unique_integer([:positive, :monotonic])
          write(out, "request-#{id}.json", %{name: name, request: body})
          result = Http.request(endpoint, body)
          write(out, "response-#{id}.json", %{name: name, result: result})
          result
        end

        {:ok, body} =
          Body.start(name <> "-" <> run,
            scene_id: 1,
            spawn: spawn,
            bounds: {{-60, 40, -60}, {60, 120, 60}},
            claims: fixture.claims,
            route_module: NpcWorld.Route,
            brain: {backend, Map.put(profile, :request, request)}
          )

        %{actor: %{cid: cid}} =
          NpcWorld.await(fn ->
            case Body.skill_context(body) do
              {:ok, context} -> context
              _ -> false
            end
          end)

        %{
          name: name,
          body: body,
          cid: cid,
          ready_at: System.monotonic_time(:millisecond),
          heard: []
        }
      end

    write(out, "protocol.json", %{
      classification: "Test-only",
      source: "正式 Body/Runtime/Life/Llm；有限真实世界模拟",
      cids: Enum.map(actors, & &1.cid),
      roles: Enum.map(roles, fn {name, goal, _} -> %{name: name, goal: goal} end),
      max_steps: 12,
      seconds: 480,
      model: System.fetch_env!("NPC_LLM_MODEL"),
      scope: "真实模型、Hindsight、PG；无UE、无预写情绪、无行为因果消融；不等待后台四模型刷新"
    })

    Enum.each(actors, fn a ->
      NpcWorld.await(
        fn ->
          case Life.observe(a.cid) do
            {:ok, %{state: %{"affect" => %{"next_seq" => n}}, cache: cache, error: nil}} ->
              n > 0 and cache != nil

            _ ->
              false
          end
        end,
        60_000
      )
    end)

    try do
      count = run_steps(actors, out, 1, System.monotonic_time(:millisecond) + 480_000)

      steps =
        File.read!(Path.join(out, "steps.jsonl"))
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      entries = for s <- steps, e <- s["appraisals"], do: {s, e}
      assert entries != [], "本轮未观测到情绪激发，保留原始结果"

      non_construction =
        Enum.filter(entries, fn {s, e} ->
          Enum.any?(
            s["sources"],
            &(&1["seq"] == e["source_seq"] and &1["kind"] in ["speech", "outcome"])
          )
        end)

      assert non_construction != [], "只有初始情境情绪，尚未验证非建设经历激发"

      inputs =
        for path <- Path.wildcard(Path.join(out, "request-*.json")),
            do:
              path
              |> File.read!()
              |> Jason.decode!()
              |> get_in(["request", "input"])
              |> Jason.decode!()

      assert Enum.any?(inputs, fn i ->
               Enum.any?(i["mind"]["emotions"], fn {_, v} -> v > 0 end)
             end)

      write(out, "summary.json", %{
        status: "passed",
        steps: count,
        appraisals: length(entries),
        non_construction: length(non_construction),
        emotions: Enum.uniq(Enum.map(entries, fn {_, e} -> e["emotion"] end)),
        decision_tokens: Enum.sum(Enum.map(steps, & &1["response"]["usage"]["total_tokens"])),
        limitation: "证明真实经历激发及后续读取，不证明情绪对动作的独立因果贡献"
      })
    after
      for a <- actors do
        write(out, "final-#{a.cid}.json", %{
          life: Life.observe(a.cid),
          body: Body.observe(a.body),
          persisted: DataService.NpcMemory.get(a.cid, "life", "state")
        })
      end
    end
  end

  defp run_steps(_actors, _out, n, _deadline) when n > 12, do: n - 1

  defp run_steps(actors, out, n, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      n - 1
    else
      {actors, next} =
        Enum.map_reduce(actors, n, fn a, n ->
          snapshot = Body.observe(a.body)

          addressed =
            Enum.any?(snapshot.dialogue, fn m ->
              NpcServer.Dialogue.direct?(m, a.cid) and m not in a.heard
            end)

          if n <= 12 and System.monotonic_time(:millisecond) < deadline and
               (now >= a.ready_at or addressed) do
            :ok = Body.step(a.body, self(), n, %{task: "共同调查身边地面并交流可用知识，依据真实观察推进；完成后可休息。"})

            result =
              receive do
                {:npc_llm_step, ^n, result} -> result
              after
                240_000 -> {:error, :step_timeout}
              end

            write(out, "step-result-#{n}.json", %{cid: a.cid, result: result})
            assert {:ok, response, ids} = result

            NpcWorld.await(
              fn ->
                terminal = Enum.map(Body.observe(a.body).outcomes, & &1.id)
                Enum.all?(ids, &(&1 in terminal))
              end,
              30_000
            )

            {:ok, life} = Life.observe(a.cid)
            assert life.error == nil
            after_body = Body.observe(a.body)
            [call] = Responses.function_calls(response)
            {:ok, arguments} = call.arguments

            request =
              Path.wildcard(Path.join(out, "request-*.json"))
              |> Enum.map(fn path ->
                {String.to_integer(
                   Path.basename(path)
                   |> String.trim_leading("request-")
                   |> String.trim_trailing(".json")
                 ), path}
              end)
              |> Enum.max_by(&elem(&1, 0))
              |> elem(1)
              |> File.read!()
              |> Jason.decode!()

            sources =
              request["request"]["input"]
              |> Jason.decode!()
              |> get_in(["emotion_context", "sources"])

            proof = %{
              step: n,
              name: a.name,
              cid: a.cid,
              appraisals: arguments["appraisal"],
              sources: sources,
              response: response,
              life: life,
              outcomes: Enum.filter(after_body.outcomes, &(&1.id in ids)),
              heard: after_body.dialogue
            }

            File.write!(
              Path.join(out, "steps.jsonl"),
              Jason.encode!(Context.plain(proof)) <> "\n",
              [:append]
            )

            wait =
              if call.name == "wait",
                do: call.arguments |> elem(1) |> Map.fetch!("seconds"),
                else: 0

            IO.puts(
              "NPC_EMOTION_STEP " <>
                Jason.encode!(%{
                  step: n,
                  name: a.name,
                  tool: call.name,
                  emotions: arguments["appraisal"]
                })
            )

            {%{
               a
               | ready_at: System.monotonic_time(:millisecond) + round(wait * 1000),
                 heard: after_body.dialogue
             }, n + 1}
          else
            {a, n}
          end
        end)

      if next == n, do: Process.sleep(100)
      run_steps(actors, out, next, deadline)
    end
  end

  defp write(out, file, value),
    do: File.write!(Path.join(out, file), Jason.encode!(Context.plain(value), pretty: true))
end
