Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcEmotionLifeTest do
  @moduledoc "只测试：真实 Body/Runtime/Life/World/PG 接缝，模型与 Hindsight 为显式可控替身。"
  use ExUnit.Case, async: false
  alias NpcServer.{Body, Life, Brain.Llm}
  alias NpcServer.NpcWorld

  defmodule Hindsight do
    def ensure(_, _), do: {:ok, %{}}
    def models(_), do: {:ok, %{models: %{}, metadata: %{}}}
    def status(_), do: {:ok, %{}}
    def recall(_, _, _), do: {:ok, %{results: [], latency_ms: 0}}
    def retain(_, _), do: {:ok, %{}}
    def refresh(_), do: models(nil)
  end

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  defmodule RuleBrain do
    def init(profile), do: profile
    def handle_event(_, state), do: {[], state}
  end

  test "规则 owner 加载模型情绪时显式拒绝，保留原持久行" do
    fixture = NpcWorld.start()
    cid = System.unique_integer([:positive]) + 900_000
    {:ok, events} = VoxelRegion.World.interactions_since(fixture.world, nil)

    canonical =
      NpcServer.Life.State.new(cid, events.world_id, events.cursor, 0)
      |> NpcServer.Life.Appraisal.enable()

    row = %{
      "state" => canonical,
      "pending" => [],
      "fragments" => [],
      "cache" => nil,
      "retained" => 0,
      "dirty" => false,
      "refresh_at_ms" => nil,
      "thanked_seq" => 0
    }

    :ok = DataService.NpcMemory.put(cid, "life", "state", row)

    NpcWorld.body(
      fixture,
      {RuleBrain, %{life: %{hindsight: Hindsight, poll_ms: 30, url: "http://life.test.invalid"}}},
      cid: cid
    )

    NpcWorld.await(fn ->
      case Life.observe(cid) do
        {:ok, %{error: :emotion_owner_mismatch}} -> true
        {:ok, %{state: %{} = _state}} -> flunk("规则 owner 不应接纳模型情绪")
        _ -> false
      end
    end)

    assert DataService.NpcMemory.get(cid, "life", "state") == row
  end

  test "自动模式消费在途积压的全部前缀，完成后不因自身提交反复唤醒" do
    fixture = NpcWorld.start()
    owner = self()
    cid = System.unique_integer([:positive]) + 900_000

    profile = %{
      goal: "观察",
      tools: %{},
      life: %{hindsight: Hindsight, poll_ms: 30, url: "http://life.test.invalid"},
      endpoint: %{model: "test"},
      max_requests_per_hour: :infinity,
      request: fn _, body ->
        send(owner, {:automatic_request, self(), Jason.decode!(body.input)})

        receive do
          :answer ->
            {:ok,
             %{
               "output" => [
                 %{
                   "type" => "function_call",
                   "name" => "wait",
                   "arguments" => Jason.encode!(%{seconds: 3600, appraisal: []})
                 }
               ]
             }}
        end
      end
    }

    %{body: body} = NpcWorld.body(fixture, {Llm, profile}, cid: cid)
    assert_receive {:automatic_request, first, input}, 5_000
    first_through = input["emotion_context"]["through"]
    assert first_through > 0

    for i <- 1..18 do
      Body.command(body, %{id: {:probe, i}, verb: :look, min: {4, 63, 10}, max: {4, 64, 10}})
      NpcWorld.await(fn -> Enum.any?(Body.observe(body).outcomes, &(&1.id == {:probe, i})) end)
    end

    NpcWorld.await(fn ->
      {:ok, life} = Life.observe(cid)
      life.state["affect"]["next_seq"] == first_through + 18
    end)

    send(first, :answer)
    assert_receive {:automatic_request, second, input}, 5_000
    assert length(input["emotion_context"]["sources"]) == 16
    send(second, :answer)
    assert_receive {:automatic_request, third, input}, 5_000
    assert length(input["emotion_context"]["sources"]) == 2
    send(third, :answer)

    NpcWorld.await(fn ->
      {:ok, life} = Life.observe(cid)
      life.state["affect"]["cursor"] == first_through + 18
    end)

    refute_receive {:automatic_request, _, _}, 1_500
  end

  test "模型评价先保存，真实观察动作生成新来源，轮询与重启保留情绪，非法评价不执行动作" do
    fixture = NpcWorld.start()
    owner = self()
    cid = System.unique_integer([:positive]) + 900_000

    profile = %{
      goal: "观察周围并与邻居交流",
      tools: %{},
      cadence: :manual,
      life: %{hindsight: Hindsight, poll_ms: 30, url: "http://life.test.invalid"},
      endpoint: %{model: "test"},
      request: fn _, body ->
        send(owner, {:request, self(), Jason.decode!(body.input), body.tools})

        receive do
          {:reply, args} ->
            {:ok,
             %{
               "output" => [
                 %{
                   "type" => "function_call",
                   "name" => "look",
                   "arguments" =>
                     Jason.encode!(
                       Map.merge(
                         %{"x0" => 0, "y0" => 63, "z0" => 0, "x1" => 1, "y1" => 64, "z1" => 1},
                         args
                       )
                     )
                 }
               ]
             }}
        end
      end
    }

    %{body: body, sup: sup} = NpcWorld.body(fixture, {Llm, profile}, cid: cid)
    NpcWorld.await(fn -> match?({:ok, %{state: %{"affect" => _}}}, Life.observe(cid)) end)

    NpcWorld.await(fn ->
      {:ok, c} = Life.context(cid, "test")
      c.emotion_context.sources != []
    end)

    assert :ok = Body.step(body, self(), :first)
    assert_receive {:request, worker, input, tools}, 3000
    seq = hd(input["emotion_context"]["sources"])["seq"]
    assert Enum.all?(tools, &Map.has_key?(&1.parameters.properties, :appraisal))

    feeling = %{
      "emotion" => "hope",
      "intensity" => 0.6,
      "source_seq" => seq,
      "target_id" => nil,
      "reason" => "眼前有可观察的环境，我期待新的发现"
    }

    send(worker, {:reply, %{"appraisal" => [feeling]}})
    assert_receive {:npc_llm_step, :first, {:ok, _, [command]}}, 3000

    assert hd(DataService.NpcMemory.get(cid, "life", "state")["state"]["feelings"])["intensity"] ==
             0.6

    NpcWorld.await(fn -> Enum.any?(Body.observe(body).outcomes, &(&1.id == command)) end)
    assert :ok = Body.step(body, self(), :second)
    assert_receive {:request, worker, input, _}, 3000
    assert input["mind"]["emotions"]["hope"] > 0.5
    assert Enum.any?(input["emotion_context"]["sources"], &(&1["kind"] == "outcome"))
    send(worker, {:reply, %{"appraisal" => [%{feeling | "source_seq" => 999_999}]}})

    assert_receive {:npc_llm_step, :second,
                    {:error, {:emotion_appraisal_failed, :invalid_appraisal}, _}},
                   3000

    assert Enum.count(Body.observe(body).outcomes, &(&1.verb == :look)) == 1
    :ok = DynamicSupervisor.terminate_child(sup, body)
    NpcWorld.await(fn -> Life.observe(cid) == {:error, :life_not_running} end)
    stop_supervised!(DynamicSupervisor)
    NpcWorld.body(fixture, {Llm, profile}, cid: cid)
    NpcWorld.await(fn -> match?({:ok, %{state: %{"affect" => _}}}, Life.observe(cid)) end)
    {:ok, restored} = Life.observe(cid)
    assert hd(restored.state["feelings"])["intensity"] == 0.6
    assert restored.state["affect"]["cursor"] == seq
  end
end
