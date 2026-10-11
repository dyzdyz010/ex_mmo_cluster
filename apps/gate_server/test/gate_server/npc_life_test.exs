Code.require_file("../support/npc_world.exs", __DIR__)

defmodule GateServer.NpcLifeTest do
  @moduledoc "只测试：真实 World/Scene/Body/NpcMemory；Hindsight 替身控制慢请求和失败，验证 owner 接缝。"
  use ExUnit.Case, async: false
  alias GateServer.Npc.{Body, Life}
  alias GateServer.NpcWorld
  alias VoxelRegion.World

  defmodule Hindsight do
    def ensure(_, _), do: {:ok, %{}}
    def models(_), do: {:ok, %{models: %{"self" => "builder"}, metadata: %{}}}
    def status(_), do: {:ok, %{stats: %{"memory_unit_count" => 1}, usage: %{}}}

    def refresh(config) do
      send(config.owner, :refresh_called)
      models(config)
    end

    def recall(config, query, _) do
      send(config.owner, {:recall_called, query})
      {:ok, %{results: [%{"text" => "remembered"}], latency_ms: 1}}
    end

    def retain(config, fragments) do
      send(config.owner, {:retain_started, self(), fragments})

      receive do
        :complete -> {:ok, %{retained: length(fragments), facts: 1}}
        :fail -> {:error, :service_failed}
      end
    end
  end

  defmodule Spy do
    def init(profile) do
      send(profile.owner, {:life_runtime, self()})
      %{owner: profile.owner, ready: false}
    end

    def handle_event({:observation, observation}, %{owner: owner} = state) do
      unless state.ready, do: send(owner, {:life_runtime_ready, self()})
      send(owner, {:life_observation, observation})
      {[], %{state | ready: true}}
    end

    def handle_event({:outcome, outcome}, %{owner: owner} = state) do
      send(owner, {:life_outcome, outcome})
      {[], state}
    end

    def handle_event(_, state), do: {[], state}
  end

  defmodule RestoredHindsight do
    @moduledoc "只测试：旧模型只读；刷新替身被挂起，以观察 Life 的待刷新义务与持久缓存。"
    def ensure(_, _), do: {:ok, %{}}
    def retain(_, fragments), do: {:ok, %{retained: length(fragments), facts: 1}}
    def models(_), do: {:ok, %{models: %{"self" => "old model"}, metadata: %{}}}
    def status(_), do: {:ok, %{stats: %{"memory_unit_count" => 1}, usage: %{}}}

    def refresh(config) do
      send(config.owner, {:restored_refresh_started, self()})

      receive do
        :complete -> {:ok, %{models: %{"self" => "current model"}, metadata: %{}}}
      end
    end
  end

  defmodule FailingStore do
    def get(_, _, _), do: nil
    def put(_, _, _, _), do: {:error, :write_denied}
  end

  defmodule NoLexical do
    def recent(_, _), do: raise("life decision must not perform lexical retrieval")
    def search(_, _, _), do: raise("life decision must not perform lexical retrieval")
    defdelegate get(cid, kind, key), to: DataService.NpcMemory
    defdelegate recent_notes(cid, limit), to: DataService.NpcMemory
    defdelegate put(cid, kind, key, value), to: DataService.NpcMemory
  end

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  test "旧持久行在Life加载边界补亲和初值且保存，不追溯改变旧人格" do
    fixture = NpcWorld.start()
    cid = System.unique_integer([:positive]) + 100_000
    {:ok, events} = World.interactions_since(fixture.world, nil)

    old =
      Life.State.new(cid, events.world_id, events.cursor, 0)
      |> update_in(["traits"], &Map.delete(&1, "sociability"))

    row = %{
      "state" => old,
      "pending" => [],
      "fragments" => [],
      "cache" => nil,
      "retained" => 0,
      "dirty" => false,
      "refresh_at_ms" => nil,
      "thanked_seq" => 0
    }

    :ok = DataService.NpcMemory.put(cid, "life", "state", row)

    profile = %{
      owner: self(),
      life: %{hindsight: Hindsight, owner: self(), poll_ms: 30, url: "http://life.test.invalid"}
    }

    NpcWorld.body(fixture, {Spy, profile}, cid: cid)

    NpcWorld.await(fn ->
      match?({:ok, %{state: %{"traits" => %{"sociability" => 0.5}}}}, Life.observe(cid))
    end)

    stored = DataService.NpcMemory.get(cid, "life", "state")["state"]
    assert update_in(stored, ["traits"], &Map.delete(&1, "sociability")) == old
  end

  test "Life Llm 的真实路径拒绝进入下一轮和重启后的失败历史" do
    fixture = NpcWorld.start()
    cid = System.unique_integer([:positive]) + 100_000
    owner = self()

    profile = %{
      goal: "care for construction",
      tools: %{},
      memory: NoLexical,
      life: %{hindsight: Hindsight, owner: owner, poll_ms: 30, url: "http://life.test.invalid"},
      endpoint: %{model: "test"},
      max_requests_per_hour: 2,
      request: fn _, body ->
        send(owner, {:failure_context, self(), Jason.decode!(body.input)})

        receive do
          {:reply, name, args} ->
            {:ok,
             %{
               "output" => [
                 %{"type" => "function_call", "name" => name, "arguments" => Jason.encode!(args)}
               ]
             }}
        end
      end
    }

    %{body: body} = NpcWorld.body(fixture, {GateServer.Npc.Brain.Llm, profile}, cid: cid)
    assert_receive {:failure_context, first, _}, 10_000
    send(first, {:reply, "move_to", %{x: 7.5, z: 10.5, y: 63}})
    assert_receive {:failure_context, second, input}, 10_000
    assert [failure] = input["recent_failures"]

    assert failure["command"] == %{
             "tool" => "move_to",
             "args" => %{"x" => 7.5, "z" => 10.5, "y" => 63}
           }

    assert failure["reason"] == "no_path"
    assert failure["data"]["goal_position"]["standable"] == false
    send(second, {:reply, "wait", %{seconds: 3600}})
    old_life = :global.whereis_name({Life, node(), cid})
    ref = Process.monitor(old_life)
    Process.exit(body, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}, 5000
    assert_receive {:failure_context, restored, input}, 10_000
    assert input["recent_failures"] == [failure]
    send(restored, {:reply, "wait", %{seconds: 3600}})
  end

  test "地表格误用为脚层时返回同次寻路诊断，正确脚层仍可抵达" do
    {_fixture, body, _cid} = start()

    NpcWorld.await(fn ->
      case Body.observe(body).position do
        {_, y, _} -> abs(y - 64.91) < 0.02
        _ -> false
      end
    end)

    Body.command(body, %{
      id: :ground,
      verb: :move_to,
      position: {7.5, 10.5},
      y: 63,
      tolerance: 0.5
    })

    rejected =
      NpcWorld.await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == :ground)) end)

    assert %{status: :rejected, reason: :no_path, data: data} = rejected
    assert data.goal == {7, 63, 10}
    assert data.goal_position == %{standable: false, landed: nil}
    assert is_integer(data.seq)

    Body.command(body, %{id: :above, verb: :move_to, position: {7.5, 10.5}, y: 64, tolerance: 0.5})

    assert_receive {:life_outcome, %{id: :above, status: :done, data: %{settled: true}}}, 10_000
  end

  defp start(memory \\ DataService.NpcMemory, options \\ %{}) do
    fixture = NpcWorld.start()
    cid = System.unique_integer([:positive]) + 100_000

    profile = %{
      owner: self(),
      memory: memory,
      life:
        Map.merge(
          %{hindsight: Hindsight, owner: self(), poll_ms: 30, url: "http://life.test.invalid"},
          options
        )
    }

    body = NpcWorld.body(fixture, {Spy, profile}, cid: cid).body

    NpcWorld.await(fn ->
      match?({:ok, %{state: %{"cursor" => _}, cache: %{}, job: nil}}, Life.observe(cid))
    end)

    {fixture, body, cid}
  end

  defp damage(world, npc, seq, cell) do
    {:ok, _} = World.material_supply(world, npc, "life-supply-#{seq}", %{11 => 512})
    actor = actor(npc)

    {:ok, _} =
      World.production_intent(world, actor, %{
        request_id: seq,
        client_intent_seq: seq,
        logical_scene_id: 1,
        action: 1,
        coord: cell,
        tool_id: 1,
        material: 11
      })

    attacker = actor(npc + 10)
    {x, y, z} = cell

    query = %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {x + 0.5 - 4.5, y + 0.5 - 65.5, z + 0.5 - 8.5},
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }

    {:ok, target} = World.tool_intent(world, attacker, query)

    {:ok, _} =
      World.tool_intent(
        world,
        Map.merge(attacker, %{received_us: seq * 1_000_000, clock_node: node()}),
        Map.merge(
          query,
          Map.take(target, [:micro, :granularity, :incarnation, :owner, :material])
        )
        |> Map.put(:action, 1)
      )
  end

  defp actor(cid) do
    actor = Process.get({:life_actor, cid}) || NpcWorld.actor(cid, {4.5, 65.5, 8.5})
    Process.put({:life_actor, cid}, actor)
    actor
  end

  @tag long_horizon: true
  test "thirty controlled days and owner restart preserve intention and authority personality without revived emotion" do
    clock = start_supervised!({Agent, fn -> System.system_time(:millisecond) end})

    {fixture, body, cid} =
      start(DataService.NpcMemory, %{clock: fn -> Agent.get(clock, & &1) end})

    assert_receive {:life_runtime, runtime}
    assert_receive {:life_runtime_ready, ^runtime}, 5000

    Body.command(runtime, %{
      id: :plan_before,
      verb: :set_plan,
      text: "Check the construction after returning; repair only actual damage"
    })

    assert_receive {:life_outcome, %{id: :plan_before, status: :done}}, 5000

    for {cell, seq} <- Enum.with_index([{4, 64, 8}, {5, 64, 8}, {4, 64, 9}], 1),
        do: damage(fixture.world, cid, seq, cell)

    # 已有第一次伤害；继续真实工具击打至破坏，再由另一角色真实补回同材料。
    attacker = actor(cid + 10)

    for seq <- 101..103 do
      query = %{
        request_id: seq,
        client_intent_seq: seq,
        logical_scene_id: 1,
        action: 0,
        tool_id: 1,
        direction: {0.0, -1.0, 0.0},
        micro: {0, 0, 0},
        granularity: 0,
        incarnation: 0,
        owner: {0, 0},
        material: 0
      }

      {:ok, target} = World.tool_intent(fixture.world, attacker, query)

      {:ok, _} =
        World.tool_intent(
          fixture.world,
          Map.merge(attacker, %{received_us: seq * 1_000_000, clock_node: node()}),
          Map.merge(
            query,
            Map.take(target, [:micro, :granularity, :incarnation, :owner, :material])
          )
          |> Map.put(:action, 1)
        )
    end

    {:ok, _} = World.material_supply(fixture.world, cid + 20, "long-horizon-helper", %{11 => 512})

    {:ok, _} =
      World.production_intent(fixture.world, actor(cid + 20), %{
        request_id: 201,
        client_intent_seq: 201,
        logical_scene_id: 1,
        action: 1,
        coord: {4, 64, 8},
        tool_id: 1,
        material: 11
      })

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.state["evidence"]["damage_count"] == 3 and s.state["evidence"]["help_count"] == 1
    end)

    {:ok, before} = Life.observe(cid)
    plan = GateServer.Npc.Memory.working_context(DataService.NpcMemory, cid).current_plan
    assert before.state["traits"]["caution"] == 0.25
    assert before.state["relationships"][to_string(cid + 10)]["trust"] == -1.0
    assert before.state["relationships"][to_string(cid + 20)]["trust"] == 0.25

    for day <- [1, 7, 30] do
      Agent.update(clock, fn _ -> before.state["last_at_ms"] + day * 86_400_000 end)
      {:ok, aged} = Life.observe(cid)
      assert aged.state == before.state
      assert aged.mind["emotions"]["anger"] < 1.0e-50
      assert aged.mind["emotions"]["gratitude"] < 1.0e-50

      assert GateServer.Npc.Memory.working_context(DataService.NpcMemory, cid).current_plan ==
               plan
    end

    old_life = :global.whereis_name({Life, node(), cid})
    life_ref = Process.monitor(old_life)
    Process.exit(body, :kill)
    assert_receive {:DOWN, ^life_ref, _, _, _}, 5000
    assert_receive {:life_runtime, restarted_runtime}, 5000
    assert restarted_runtime != runtime

    NpcWorld.await(fn ->
      case Life.observe(cid) do
        {:ok, %{state: state, cache: cache}} -> state == before.state and cache != nil
        _ -> false
      end
    end)

    {:ok, restored} = Life.observe(cid)
    assert restored.mind["emotions"]["anger"] == 0.0
    assert restored.mind["emotions"]["gratitude"] == 0.0
    assert GateServer.Npc.Memory.working_context(DataService.NpcMemory, cid).current_plan == plan
    {:ok, history} = World.interactions_since(fixture.world, 0)

    assert {restored.state, []} ==
             Life.State.advance(
               restored.state,
               history.events,
               history.cursor,
               Agent.get(clock, & &1)
             )

    # 明确等新 Runtime 的正式观察：不向内部状态注入当前世界或心智。
    assert_receive {:life_runtime_ready, ^restarted_runtime}, 5000

    for {id, text} <- [{:replan, "Inspect another site before resuming"}, {:clear, ""}] do
      Body.command(restarted_runtime, %{id: id, verb: :set_plan, text: text})
      assert_receive {:life_outcome, %{id: ^id, status: :done}}, 5000
      current = GateServer.Npc.Memory.working_context(DataService.NpcMemory, cid).current_plan
      if text == "", do: assert(current == nil), else: assert(current["text"] == text)
    end
  end

  @tag :final_fix
  test "restored fragments with no cache keep refresh obligation through read-only models and save refreshed cache" do
    # 纯回调故障恢复测试：合法持久行形状，真实 NpcMemory；不启动 World/Body，不先等待缓存就绪。
    cid = System.unique_integer([:positive]) + 100_000

    row = %{
      "state" => Life.State.new(cid, "restored-world", 3, 0),
      "pending" => [],
      "fragments" => [
        %{
          "id" => "restored-world:#{cid}:fragment:1-3",
          "at_ms" => 0,
          "text" => "Actor 2 damaged my construction."
        }
      ],
      "cache" => nil,
      "retained" => 0,
      "dirty" => false,
      "refresh_at_ms" => nil,
      "thanked_seq" => 0
    }

    :ok = DataService.NpcMemory.put(cid, "life", "state", row)
    assert {:ok, loaded} = GateServer.Npc.Memory.life_load(DataService.NpcMemory, cid)

    s = %{
      row: nil,
      poll: %{ref: make_ref()},
      job: nil,
      job_error: nil,
      error: nil,
      memory: DataService.NpcMemory,
      context: %{cid: cid},
      owner: self(),
      adapter: RestoredHindsight,
      config: %{owner: self()},
      now: fn -> 1000 end,
      poll_ms: 600_000,
      status: nil,
      speech_pending: []
    }

    {:noreply, s} = Life.handle_info({:result, :poll, {:ok, %{row: loaded, episodes: []}}}, s)
    assert_receive {:result, :job, retained}, 5000
    {:noreply, s} = Life.handle_info({:result, :job, retained}, s)
    assert s.row["retained"] == 1 and s.row["dirty"]
    assert s.row["fragments"] == [] and s.row["cache"] == nil

    assert_receive {:result, :job, models}, 5000
    {:noreply, s} = Life.handle_info({:result, :job, models}, s)
    cached = DataService.NpcMemory.get(cid, "life", "state")
    assert cached["cache"]["models"] == %{"self" => "old model"}
    assert cached["dirty"]
    assert_receive {:restored_refresh_started, worker}, 5000
    assert s.job.kind == :refresh
    send(worker, :complete)

    assert_receive {:result, :job, refreshed}, 5000
    {:noreply, s} = Life.handle_info({:result, :job, refreshed}, s)
    assert s.job == nil
    saved = DataService.NpcMemory.get(cid, "life", "state")
    assert saved["cache"]["models"] == %{"self" => "current model"}
    refute saved["dirty"]
    assert saved["refresh_at_ms"] == 1000
  end

  @tag timeout: 120_000
  test "durable authority appraisal progresses during slow retain; completion removes only sent fragments" do
    {fixture, body, cid} = start()
    damage(fixture.world, cid, 1, {4, 64, 8})

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.state["evidence"]["damage_count"] == 1
    end)

    assert {:ok, %{status: :started}} = Life.flush(cid)
    assert_receive {:retain_started, worker, [fragment]}, 5000
    assert fragment["id"] =~ "fragment:"
    damage(fixture.world, cid, 2, {5, 64, 8})

    NpcWorld.await(fn ->
      case Life.observe(cid) do
        {:ok, %{state: %{} = canonical}} -> canonical["evidence"]["damage_count"] == 2
        _ -> false
      end
    end)

    Body.command(body, %{id: :responsive, verb: :stop})
    assert_receive {:life_outcome, %{id: :responsive}}, 5000
    send(worker, :complete)

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.retained == 1
    end)

    {:ok, s} = Life.observe(cid)
    assert s.pending_episodes == 1

    assert DataService.NpcMemory.get(cid, "life", "state")["state"]["evidence"]["damage_count"] ==
             2

    assert {:ok, context} = Life.context(cid, "Who hurt me?")
    assert context.mental_models["self"] == "builder"
    assert_receive {:recall_called, "Who hurt me?"}
    refute_receive {:recall_called, _}
    old_life = :global.whereis_name({Life, node(), cid})
    life_ref = Process.monitor(old_life)
    ref = Process.monitor(body)
    Process.exit(body, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert_receive {:DOWN, ^life_ref, _, _, _}, 5000

    NpcWorld.await(fn ->
      case Life.observe(cid) do
        {:ok, %{state: %{} = canonical}} -> canonical["evidence"]["damage_count"] == 2
        _ -> false
      end
    end)

    {:ok, restored} = Life.observe(cid)
    assert restored.state == s.state
    assert restored.pending_episodes == 1
  end

  test "failed durable initialization is explicit and does not publish a cursor" do
    fixture = NpcWorld.start()
    cid = System.unique_integer([:positive]) + 100_000

    NpcWorld.body(
      fixture,
      {Spy,
       %{
         owner: self(),
         memory: FailingStore,
         life: %{
           hindsight: Hindsight,
           owner: self(),
           poll_ms: 30,
           url: "http://life.test.invalid"
         }
       }},
      cid: cid
    )

    NpcWorld.await(fn ->
      match?({:ok, %{error: {:memory_unavailable, :write_denied}}}, Life.observe(cid))
    end)

    assert {:ok, %{state: nil}} = Life.observe(cid)
  end

  test "failed retain preserves sealed identity and stays diagnostic while Body continues" do
    {fixture, body, cid} = start()
    damage(fixture.world, cid, 1, {4, 64, 8})

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.pending_episodes == 1
    end)

    assert {:ok, %{status: :started}} = Life.flush(cid)
    assert_receive {:retain_started, worker, [fragment]}, 5000
    send(worker, :fail)

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.error == :service_failed
    end)

    {:ok, s} = Life.observe(cid)
    assert s.pending_fragments == 1 and s.retained == 0
    assert DataService.NpcMemory.get(cid, "life", "state")["fragments"] == [fragment]
    Body.command(body, %{id: :after_failure, verb: :stop})
    assert_receive {:life_outcome, %{id: :after_failure}}, 5000
    refute_receive {:retain_started, _, _}, 100
    assert {:ok, %{status: :started}} = Life.flush(cid)
    assert_receive {:retain_started, retry, [^fragment]}, 5000
    send(retry, :complete)

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.retained == 1
    end)
  end

  test "short facts form one fragment; models refresh after first retain and dirty cadence, never on context" do
    clock = start_supervised!({Agent, fn -> System.system_time(:millisecond) end})

    {fixture, _body, cid} =
      start(DataService.NpcMemory, %{clock: fn -> Agent.get(clock, & &1) end})

    damage(fixture.world, cid, 1, {4, 64, 8})
    damage(fixture.world, cid, 2, {5, 64, 8})

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.pending_episodes == 2
    end)

    refute_receive {:retain_started, _, _}, 100
    {:ok, %{status: :started}} = Life.flush(cid)
    assert_receive {:retain_started, worker, [fragment]}, 5000
    assert fragment["text"] =~ "transaction 3"
    assert fragment["text"] =~ "transaction 6"
    send(worker, :complete)
    assert_receive :refresh_called, 5000

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.job == nil
    end)

    {:ok, _} = Life.context(cid, "construction")
    assert_receive {:recall_called, "construction"}
    refute_receive :refresh_called, 100
    damage(fixture.world, cid, 3, {4, 64, 9})

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.pending_episodes == 1
    end)

    {:ok, _} = Life.flush(cid)
    assert_receive {:retain_started, worker, _}, 5000
    send(worker, :complete)

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.retained == 2
    end)

    refute_receive :refresh_called, 100
    Agent.update(clock, &(&1 + 600_001))
    assert_receive :refresh_called, 5000

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.job == nil and not s.cache_dirty
    end)

    assert DataService.NpcMemory.get(cid, "life", "state")["cache"]["models"] == %{
             "self" => "builder"
           }
  end

  @tag long_horizon: true
  test "production Llm decision uses durable intentions, notes, mind, cached models and exactly one recall" do
    {_fixture, _body, cid} = start()

    :ok =
      DataService.NpcMemory.put(cid, "intention", "current", %{
        "text" => "Inspect the western wall; repair only verified damage",
        "position" => [4, 64, 10]
      })

    assert %{status: :done} =
             GateServer.Npc.Memory.execute(DataService.NpcMemory, cid, {4, 64, 10}, %{
               id: 72,
               verb: :remember,
               key: "agreement",
               text: "Leave the eastern passage clear"
             })

    owner = self()

    profile = %{
      goal: "build carefully",
      tools: %{},
      life: %{},
      memory: NoLexical,
      endpoint: %{model: "test"},
      max_requests_per_hour: 1,
      request: fn _, body ->
        send(owner, {:llm_context, Jason.decode!(body.input)})

        {:ok,
         %{
           "output" => [
             %{"type" => "function_call", "name" => "wait", "arguments" => "{\"seconds\":3600}"}
           ]
         }}
      end
    }

    llm = GateServer.Npc.Brain.Llm.init(profile)

    on_exit(fn ->
      Process.unlink(llm)
      Process.exit(llm, :kill)
    end)

    GateServer.Npc.Brain.Llm.handle_event(
      {:observation,
       %{
         self: %{entity_id: cid, position: {4.0, 64.0, 10.0}},
         entities: [],
         pending: [],
         balances: nil
       }},
      llm
    )

    assert_receive {:recall_called, query}, 5000
    assert query =~ "build carefully"
    assert_receive {:llm_context, input}, 5000
    assert input["mental_models"]["self"] == "builder"
    assert input["mind"]["cid"] == cid
    assert input["memory_retrieval"] == "hindsight_once"
    assert input["memories"] == [%{"text" => "remembered"}]

    assert Enum.any?(
             input["recent_notes"],
             &(&1["body"]["text"] == "Leave the eastern passage clear")
           )

    assert input["current_plan"]["text"] ==
             "Inspect the western wall; repair only verified damage"

    refute_receive {:recall_called, _}, 100
    refute_receive :refresh_called, 100
  end

  test "real database rejection keeps canonical cursor and pending atomic until storage accepts the World event" do
    {fixture, _body, cid} = start()
    {:ok, before} = Life.observe(cid)
    function = "reject_life_#{cid}"

    Ecto.Adapters.SQL.query!(
      DataService.Repo,
      """
      CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.cid = #{cid} AND NEW.kind = 'life' THEN RAISE EXCEPTION 'test write unavailable'; END IF;
        RETURN NEW;
      END $$
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      DataService.Repo,
      "CREATE TRIGGER #{function} BEFORE INSERT ON npc_memories FOR EACH ROW EXECUTE FUNCTION #{function}()",
      []
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(
        DataService.Repo,
        "DROP TRIGGER IF EXISTS #{function} ON npc_memories",
        []
      )

      Ecto.Adapters.SQL.query!(DataService.Repo, "DROP FUNCTION IF EXISTS #{function}()", [])
    end)

    damage(fixture.world, cid, 1, {4, 64, 8})

    NpcWorld.await(fn ->
      match?({:ok, %{error: {:memory_unavailable, Postgrex.Error}}}, Life.observe(cid))
    end)

    {:ok, failed} = Life.observe(cid)
    assert failed.state == before.state
    assert failed.pending_episodes == 0
    assert DataService.NpcMemory.get(cid, "life", "state")["state"] == before.state
    Ecto.Adapters.SQL.query!(DataService.Repo, "DROP TRIGGER #{function} ON npc_memories", [])

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.state["evidence"]["damage_count"] == 1
    end)

    {:ok, accepted} = Life.observe(cid)
    assert accepted.state["cursor"] > before.state["cursor"]
    assert accepted.pending_episodes == 1
  end
end
