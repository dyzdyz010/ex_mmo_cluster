Code.require_file("../support/npc_world.exs", __DIR__)
Code.require_file("../support/reflection_fixtures.exs", __DIR__)
Code.require_file("../support/life_fixtures.exs", __DIR__)

defmodule NpcServer.NpcLifeTest do
  @moduledoc "只测试：真实 World/Scene/Body/NpcMemory；Hindsight 替身控制慢请求和失败，验证 owner 接缝。"
  use ExUnit.Case, async: false
  alias NpcServer.{Body, Life}
  alias NpcServer.NpcWorld
  alias SceneServer.Movement.Scene
  alias VoxelRegion.World

  # 反思用例的 profile（Hindsight 替身 `LifeFixtures.ReflectHindsight` 由它带上）与“别人打掉我放的一格”的 World 动作
  # （与日计划的 Life 集成用例共用）。
  import NpcServer.LifeFixtures, only: [damage: 4, actor: 1, reflect_profile: 3]

  defmodule Hindsight do
    def ensure(_, _), do: {:ok, %{}}
    def models(_), do: {:ok, %{models: %{"self" => "builder"}, metadata: %{}}}
    def status(_), do: {:ok, %{stats: %{"memory_unit_count" => 1}, usage: %{}}}

    def refresh(config) do
      send(config.owner, :refresh_called)
      models(config)
    end

    # 收到的是一路召回的描述（`Life.context/2` 把问句包成 `%{query: 问句}`）。
    def recall(config, description, _) do
      send(config.owner, {:recall_called, description})
      {:ok, %{results: [%{"text" => "remembered"}], latency_ms: 1}}
    end

    # 收到的是逐条经历的文档（每条经历一份），不是片段。
    def retain(config, documents) do
      send(config.owner, {:retain_started, self(), documents})

      receive do
        :complete -> {:ok, %{retained: length(documents), facts: 1}}
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

  defmodule SlowFailingHindsight do
    @moduledoc """
    只测试：一路立刻失败、另一路慢（这是正常返回，不是超时）。用来证明 `recollect/3` 等每一路各自结束再合成，
    不是第一路失败就停下；并且仍按“全有全无”把第一条失败报出去。
    """
    def ensure(_, _), do: {:ok, %{}}
    def retain(_, documents), do: {:ok, %{retained: length(documents), facts: 1}}
    def models(_), do: {:ok, %{models: %{"self" => "builder"}, metadata: %{}}}
    def status(_), do: {:ok, %{stats: %{"memory_unit_count" => 1}, usage: %{}}}

    def recall(config, %{query: query}, _now_ms) do
      send(config.owner, {:recall_started, query})

      if query == "slow" do
        Process.sleep(300)
        send(config.owner, {:recall_finished, query})
        {:ok, %{results: [], latency_ms: 300, truth: "test"}}
      else
        {:error, :service_failed}
      end
    end
  end

  defmodule RestoredHindsight do
    @moduledoc "只测试：旧模型只读；刷新替身被挂起，以观察 Life 的待刷新义务与持久缓存。"
    def ensure(_, _), do: {:ok, %{}}
    def retain(_, documents), do: {:ok, %{retained: length(documents), facts: 1}}
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

  defmodule ControlledStore do
    @moduledoc """
    只测试：真实 NpcMemory 之上由测试进程控制的一次保存失败。测试进程在同名 ETS 表里放下 `{cid, 测试进程}` 之后，
    这个 cid 的 Life 行的**下一次**保存被拒（同 `FailingStore` 的 `:write_denied`），被拒的那份行交给测试进程；其余读写照常。
    """
    defdelegate get(cid, kind, key), to: DataService.NpcMemory

    def put(cid, "life", "state", row) do
      # 表随测试进程结束而消失；测试收尾时 Life 的保存照常落库。
      case :ets.whereis(__MODULE__) != :undefined and :ets.take(__MODULE__, cid) do
        [{^cid, test}] ->
          send(test, {:save_refused, row})
          {:error, :write_denied}

        _ ->
          DataService.NpcMemory.put(cid, "life", "state", row)
      end
    end

    def put(cid, kind, key, value), do: DataService.NpcMemory.put(cid, kind, key, value)
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
                 %{
                   "type" => "function_call",
                   "name" => name,
                   "arguments" => Jason.encode!(Map.put(args, :appraisal, []))
                 }
               ]
             }}
        end
      end
    }

    %{body: body} = NpcWorld.body(fixture, {NpcServer.Brain.Llm, profile}, cid: cid)
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

  test "a short session loss excludes construction until the Body observes again" do
    offset = start_supervised!({Agent, fn -> 0 end})
    clock = fn -> System.system_time(:millisecond) + Agent.get(offset, & &1) end
    {fixture, body, cid} = start(DataService.NpcMemory, %{clock: clock})
    assert_receive {:life_observation, %{self: %{entity_id: ^cid}}}, 10_000

    builder = NpcWorld.actor(cid + 10, {4.5, 65.5, 10.5})

    assert {:ok, _} =
             World.material_supply(fixture.world, builder.cid, "sight-reconnect", %{11 => 1024})

    place = fn sequence, cell ->
      assert {:ok, seq} =
               World.production_intent(fixture.world, builder, %{
                 request_id: sequence,
                 client_intent_seq: sequence,
                 logical_scene_id: 1,
                 action: 1,
                 coord: cell,
                 material: 11,
                 tool_id: 1
               })

      NpcWorld.await(
        fn ->
          {:ok, %{state: %{"cursor" => cursor}}} = Life.observe(cid)
          cursor >= seq
        end,
        3000
      )

      seq
    end

    assert %{identity: identity} =
             Enum.find(Scene.observe(fixture.scene).characters, &(&1.entity_id == cid))

    # Scene 正常结束会话，只暂挂独立 Claims 以固定恢复和第一笔事务的先后；World 与 Life 继续运行。
    :ok = :sys.suspend(fixture.claims)

    try do
      began = System.monotonic_time(:millisecond)
      assert :ok = Scene.leave(fixture.scene, identity)
      NpcWorld.await(fn -> Body.observe(body).position == nil end, 3000)
      place.(1, {6, 64, 10})
      assert System.monotonic_time(:millisecond) - began < 4000
    after
      :ok = :sys.resume(fixture.claims)
    end

    NpcWorld.await(fn -> match?({_, _, _}, Body.observe(body).position) end)
    observed = place.(2, {7, 64, 10})
    Agent.update(offset, &(&1 + 31_000))

    sight =
      NpcWorld.await(fn ->
        entries = DataService.NpcMemory.get(cid, "life", "state")["pending"]

        case Enum.filter(
               entries,
               &("actor:#{builder.cid}" in &1["tags"] and "kind:sight" in &1["tags"])
             ) do
          [] -> nil
          matches -> matches
        end
      end)

    assert [%{"id" => id, "text" => text}] = sight
    assert id == "sight:place:#{builder.cid}:#{observed}"
    assert text =~ "placed 1 block about"
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

  # 只测试：构造一份"有 count 个待写片段"的合法持久行（其余键与 `initial/3` 同形）。
  defp row_with_fragments(cid, count) do
    fragments =
      for index <- 1..count do
        %{
          "id" => "e#{index}:fragment:f#{index}",
          "at_ms" => index,
          "episodes" => [
            %{
              "id" => "e#{index}",
              "at_ms" => index,
              "text" => "episode #{index}",
              "tags" => ["kind:event"]
            }
          ]
        }
      end

    %{
      "state" => Life.State.new(cid, "w", 3, 0),
      "pending" => [],
      "fragments" => fragments,
      "cache" => %{"models" => %{"self" => "builder"}, "at_ms" => 0},
      "retained" => 0,
      "dirty" => false,
      "refresh_at_ms" => 0,
      "thanked_seq" => 0
    }
  end

  # 只测试：一份可直接驱动 Life 回调的状态（不经 GenServer），时钟由测试的 Agent 控制。
  defp life_state(cid, clock, adapter) do
    %{
      row: nil,
      poll: %{ref: make_ref()},
      job: nil,
      job_error: nil,
      job_failures: 0,
      job_retry_at_ms: nil,
      dropped_fragments: 0,
      dropped_episodes: 0,
      error: nil,
      memory: DataService.NpcMemory,
      context: %{cid: cid},
      owner: self(),
      adapter: adapter,
      config: %{owner: self()},
      now: fn -> Agent.get(clock, & &1) end,
      poll_ms: 600_000,
      status: nil,
      speech_pending: [],
      appraise: false,
      observation: nil,
      experience_pending: [],
      journaling: nil,
      activity: nil,
      activity_pending: nil,
      sight: Life.Sight.new()
    }
  end

  # 只测试：喂一次"世界事件读取完成"，什么事件都没有。`poll` 槽由上一次 `done/2` 清空，
  # 这里补一个新的 ref（真实运行中下一次 `:poll` 消息会重新置位）。
  defp poll(s, row) do
    Life.handle_info(
      {:result, :poll, {:ok, %{row: row, events: %{world_id: "w", cursor: 3, events: []}}}},
      %{s | poll: %{ref: make_ref()}}
    )
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
    plan = NpcServer.Memory.working_context(DataService.NpcMemory, cid).current_plan
    assert before.state["traits"]["caution"] == 0.25
    assert before.state["relationships"][to_string(cid + 10)]["trust"] == -1.0
    assert before.state["relationships"][to_string(cid + 20)]["trust"] == 0.25

    for day <- [1, 7, 30] do
      Agent.update(clock, fn _ -> before.state["last_at_ms"] + day * 86_400_000 end)
      {:ok, aged} = Life.observe(cid)
      assert aged.state == before.state
      assert aged.mind["emotions"]["anger"] < 1.0e-50
      assert aged.mind["emotions"]["gratitude"] < 1.0e-50

      assert NpcServer.Memory.working_context(DataService.NpcMemory, cid).current_plan ==
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
    assert NpcServer.Memory.working_context(DataService.NpcMemory, cid).current_plan == plan
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
      current = NpcServer.Memory.working_context(DataService.NpcMemory, cid).current_plan
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
          "id" => "restored-world:1:fragment:restored-world:3",
          "at_ms" => 0,
          "episodes" => [
            %{
              "id" => "restored-world:1",
              "at_ms" => 0,
              "text" => "actor 2 damaged my construction.",
              "tags" => ["kind:event", "actor:2"]
            }
          ]
        }
      ],
      "cache" => nil,
      "retained" => 0,
      "dirty" => false,
      "refresh_at_ms" => nil,
      "thanked_seq" => 0
    }

    :ok = DataService.NpcMemory.put(cid, "life", "state", row)
    assert {:ok, loaded} = NpcServer.Memory.life_load(DataService.NpcMemory, cid)

    s = %{
      row: nil,
      poll: %{ref: make_ref()},
      job: nil,
      job_error: nil,
      job_failures: 0,
      job_retry_at_ms: nil,
      dropped_fragments: 0,
      dropped_episodes: 0,
      error: nil,
      memory: DataService.NpcMemory,
      context: %{cid: cid},
      owner: self(),
      adapter: RestoredHindsight,
      config: %{owner: self()},
      now: fn -> 1000 end,
      poll_ms: 600_000,
      status: nil,
      speech_pending: [],
      appraise: false,
      observation: nil,
      experience_pending: [],
      sight: Life.Sight.new(),
      # 花费额度开着（同不给 `spend` 时 Life 的缺省）：刷新义务照常。
      spend: fn -> :open end,
      spend_refused: %{}
    }

    {:noreply, s} =
      Life.handle_info(
        {:result, :poll,
         {:ok, %{row: loaded, events: %{world_id: "restored-world", cursor: 3, events: []}}}},
        s
      )

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

  # 记忆任务槽失败后的重试：原来 `job_error` 一置上就再也不会自动起槽（一次 Hindsight 抖动 = 这个 NPC 永久停止写记忆）。
  # 现在按指数退避自己重试。这一对用例直接驱动回调（不经 World / Body），把"什么时候重试"钉死。
  test "记忆任务槽失败后按退避自己重试，不再永久停摆" do
    cid = System.unique_integer([:positive]) + 300_000
    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)

    :ok = DataService.NpcMemory.put(cid, "life", "state", row_with_fragments(cid, 1))
    {:ok, loaded} = NpcServer.Memory.life_load(DataService.NpcMemory, cid)

    s = life_state(cid, clock, Hindsight)
    {:noreply, s} = poll(s, loaded)
    assert s.job.kind == :retain

    # 第一次失败：记一笔失败并定下退避截止（还没到点）。
    {:noreply, s} = Life.handle_info({:result, :job, {:error, :service_failed}}, s)
    assert s.job == nil
    assert s.job_failures == 1
    assert s.job_error == :service_failed
    assert s.job_retry_at_ms > Agent.get(clock, & &1)

    # 退避没到点：再来一次观察也不起槽。
    {:noreply, s} = poll(s, s.row)
    assert s.job == nil

    # 到点之后自己起来（不需要人用 CLI flush）。
    Agent.update(clock, fn _ -> s.job_retry_at_ms end)
    {:noreply, s} = poll(s, s.row)
    assert s.job.kind == :retain
  end

  test "退避随连续失败翻倍、有上限，抖动按 cid 稳定" do
    cid = 424_242
    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)

    for {failures, expected} <- [
          {1, 30_000},
          {2, 60_000},
          {3, 120_000},
          {4, 240_000},
          {5, 300_000},
          {9, 300_000}
        ] do
      # 起槽时 `job` 有 pid/ref；这里只喂"槽的结果"，所以给一个最小形状（`done/2` 只读 ref）。
      s = %{
        life_state(cid, clock, Hindsight)
        | job: %{ref: make_ref(), kind: :retain, ids: []},
          job_failures: failures - 1
      }

      {:noreply, failed} = Life.handle_info({:result, :job, {:error, :service_failed}}, s)
      actual = failed.job_retry_at_ms - Agent.get(clock, & &1)

      assert_in_delta actual,
                      expected,
                      expected * 0.25,
                      "第 #{failures} 次失败应在 #{expected} ms 的 ±25% 抖动内，实际 #{actual}"

      # 同一个 cid 算出来一样（抖动来自 cid 的稳定哈希，不是随机源）：换一次同样的失败，退避相同。
      {:noreply, again} =
        Life.handle_info(
          {:result, :job, {:error, :service_failed}},
          %{s | job_failures: failures - 1, job: %{ref: make_ref(), kind: :retain, ids: []}}
        )

      assert again.job_retry_at_ms == failed.job_retry_at_ms
    end
  end

  test "待写片段超过上限时丢最旧的并告警，持久行保持有界" do
    cid = System.unique_integer([:positive]) + 400_000
    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)

    row = row_with_fragments(cid, 9)
    :ok = DataService.NpcMemory.put(cid, "life", "state", row)
    {:ok, loaded} = NpcServer.Memory.life_load(DataService.NpcMemory, cid)

    :ets.new(ControlledStore, [:named_table, :public])
    :ets.insert(ControlledStore, {cid, self()})
    s = %{life_state(cid, clock, Hindsight) | row: loaded, memory: ControlledStore}

    # 这一段经历触发一次封存与保存（尾部很短，不新增片段）；上限在 `save/2` 里守。
    # 形状同 `Selector.experience/1`（登记项：种类即候选名、没有对象）。
    experience = %{
      text: "I built the hut.",
      place: nil,
      activity: "build_hut",
      kind: "build_hut",
      object: nil,
      outcome: :completed
    }

    failed_log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:reply, {:error, {:memory_unavailable, :write_denied}}, failed} =
                 Life.handle_call({:activity, experience}, nil, s)

        assert failed.row == loaded
        assert failed.dropped_fragments == 0
        assert failed.dropped_episodes == 0
      end)

    refute failed_log =~ "npc_memory_fragments_trimmed"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:reply, :ok, trimmed} = Life.handle_call({:activity, experience}, nil, s)
        assert length(trimmed.row["fragments"]) == 8
        assert trimmed.row["fragments"] == Enum.drop(loaded["fragments"], 1)
        assert trimmed.dropped_fragments == 1
      end)

    assert log =~ "npc_memory_fragments_trimmed"

    stored = DataService.NpcMemory.get(cid, "life", "state")
    assert length(stored["fragments"]) == 8
    refute Enum.any?(stored["fragments"], &(&1["id"] == hd(loaded["fragments"])["id"]))
  end

  # 召回的截止时间只有一个 owner（适配器交给 `NpcServer.Http` 的总超时），所以一路失败时不会再 kill 其余各路：
  # 等每一路各自结束再合成，仍按“全有全无”报第一条失败（决策稿 D-3a）。
  test "一路失败时仍等其余各路结束再合成、报第一条失败，不 fail-fast" do
    fixture = NpcWorld.start()
    cid = System.unique_integer([:positive]) + 500_000

    profile = %{
      owner: self(),
      life: %{
        hindsight: SlowFailingHindsight,
        owner: self(),
        poll_ms: 30,
        url: "http://life.test.invalid"
      }
    }

    NpcWorld.body(fixture, {Spy, profile}, cid: cid)
    NpcWorld.await(fn -> match?({:ok, %{cache: %{}}}, Life.observe(cid)) end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :service_failed} =
             Life.mind(cid, [%{query: "fast"}, %{query: "slow"}])

    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed >= 300, "第一路失败就返回了（fail-fast），没有等慢的那一路（#{elapsed} ms）"
    assert_receive {:recall_started, "fast"}, 2_000
    assert_receive {:recall_started, "slow"}, 2_000
    assert_receive {:recall_finished, "slow"}, 2_000
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

    # 一个片段里的一条经历 → 一份文档，文档 id 就是经历 id（不是片段 id）。
    assert_receive {:retain_started, worker, [document]}, 5000

    assert [
             %{
               "id" => "" <> fragment,
               "episodes" => [%{"id" => id, "tags" => ["kind:event", "actor:" <> _]}]
             }
           ] =
             DataService.NpcMemory.get(cid, "life", "state")["fragments"]

    assert fragment =~ "fragment:" and document["id"] == id
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
    assert_receive {:recall_called, %{query: "Who hurt me?"}}
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
    assert_receive {:retain_started, worker, [document]}, 5000
    send(worker, :fail)

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.error == :service_failed
    end)

    {:ok, s} = Life.observe(cid)
    assert s.pending_fragments == 1 and s.retained == 0

    # 失败后原片段原样留着，重发的是同一份文档（同一 id、正文、时刻与 tags）。
    assert [%{"episodes" => [%{"id" => id}]}] =
             DataService.NpcMemory.get(cid, "life", "state")["fragments"]

    assert document["id"] == id
    Body.command(body, %{id: :after_failure, verb: :stop})
    assert_receive {:life_outcome, %{id: :after_failure}}, 5000
    refute_receive {:retain_started, _, _}, 100
    assert {:ok, %{status: :started}} = Life.flush(cid)
    assert_receive {:retain_started, retry, [^document]}, 5000
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

    # 两条经历封在一个片段里，retain 时各成一份文档，正文各带时刻前缀。
    assert_receive {:retain_started, worker, [first, second]}, 5000
    assert first["text"] =~ ~r/^At \S+ \(UTC\), .*transaction 3/
    assert second["text"] =~ ~r/^At \S+ \(UTC\), .*transaction 6/

    assert [%{"episodes" => [_, _]}] =
             DataService.NpcMemory.get(cid, "life", "state")["fragments"]

    send(worker, :complete)
    assert_receive :refresh_called, 5000

    NpcWorld.await(fn ->
      {:ok, s} = Life.observe(cid)
      s.job == nil
    end)

    {:ok, _} = Life.context(cid, "construction")
    assert_receive {:recall_called, %{query: "construction"}}
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
             NpcServer.Memory.execute(DataService.NpcMemory, cid, {4, 64, 10}, %{
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

    llm = NpcServer.Brain.Llm.init(profile)

    on_exit(fn ->
      Process.unlink(llm)
      Process.exit(llm, :kill)
    end)

    NpcServer.Brain.Llm.handle_event(
      {:observation,
       %{
         self: %{entity_id: cid, position: {4.0, 64.0, 10.0}},
         entities: [],
         pending: [],
         balances: nil
       }},
      llm
    )

    assert_receive {:recall_called, %{query: query}}, 5000
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

  describe "reflection" do
    # 范围与替身：真实 World / Scene / Body / Runtime / NpcMemory 与真实 Life；“小屋被拆”是经 World 正式入口做出来的真实事务
    # （同 npc_selector_test 的整座移除用例）。替身两处：Hindsight 适配器（ReflectHindsight）与写日记的函数
    # （`profile.write_journal`：把系统提示词与用户消息交给测试进程，由测试逐次给出真实应答或真实形状的错误）。
    # 个别用例另有：落栏保存失败用 ControlledStore（真实 NpcMemory 之上由测试控制的一次 `:write_denied`）；槽在途时又到点
    # 注入 Life 的时钟（同本文件 thirty controlled days 的注入点）、让它比 World 慢 10 分钟以跨过 5 分钟间隔，第二件事是
    # `damage/4` 经 World 正式入口做出的。
    # 人格卡用 S1-T 的注册参数（`.demo/observe/npc-slice1-20261112/s1t/scripts/params-s1t.exs`），所以系统提示词应与
    # S1-X2 真实发出的逐字节相同。不证明：真实模型写什么、真实 Hindsight 把日记抽成什么；`Life.reflect/1` 的 `:no_observation`
    # 与到点时 `reason=no_observation` 的跳过（真实 Body 下“行已加载而还没有观察”的时序不受测试控制，不测）。
    import NpcServer.ReflectionFixtures, only: [fixture: 1, json: 1]

    @tag timeout: 120_000
    test "小屋被拆立即反思：材料齐全，三问写成落进持久行，存档进反思库，重启后还在" do
      %{fixture: fixture, cid: cid, brann: brann} = reflecting()
      reply = written_reply()

      # 第一问是建筑：此刻三行齐全（小屋现查 World 已不在），发生过的事第一条是那条还没封存的拆屋经历。
      assert_receive {:write, worker, system, place}, 10_000
      assert system == fixture("system-prompt.txt")

      assert place =~
               ~r/^Right now:\nIt is (morning|afternoon|evening|night), \d\d:\d\d\. It is day \d+\.\nStanding at .* My building "small hut" at \(4, 64, 8\) is gone\. .*\nMy body: life 100 of 100, no injuries or ailments\.\n\nWhat happened:\n\[1\] Just now, actor #{brann} removed the entire building "small hut" that I built/

      assert place =~ ~s|To think over now: My building "small hut": |
      send(worker, {:reply, reply})

      assert_receive {:write, worker, _, person}, 10_000
      assert person =~ "To think over now: actor #{brann}: "
      send(worker, {:reply, reply})

      # “自己”一问看得到本轮刚写成的两条。
      assert_receive {:write, worker, _, self_message}, 10_000
      journal = json("check-samples.json")["1-Q_place"]["journal"]

      assert self_message =~
               "About other things: #{journal}\n#{journal}\n\nTo think over now: How I have been"

      send(worker, {:reply, reply})

      reflection = await_reflection(cid, &(&1.round && &1.round["archive"] == "ok"))
      keys = ["person:#{brann}", "place:small hut", "self"]
      assert Enum.sort(Map.keys(reflection.latest)) == keys
      assert reflection.round["written"] == ["place:small hut", "person:#{brann}", "self"]
      assert reflection.round["causes"] == ["event"]

      assert %{"rounds" => 1, "written" => 3, "failed" => 0, "aborted" => 0, "skipped" => 0} =
               reflection.counts

      assert reflection.trigger["score"] == 0 and is_integer(reflection.trigger["last_at_ms"])
      # 做完的一轮消耗了起槽时取走的新经历（这期间没有新来的）。
      assert reflection.new == 0 and not reflection.running and reflection.error == nil

      # 这一轮“想的时刻”是起槽那一刻：各问最新一条与小结同一个时刻，不早于触发那条经历的时刻。
      at_ms = reflection.round["at_ms"]
      assert at_ms >= reflection.trigger["last_at_ms"]
      assert Enum.all?(Map.values(reflection.latest), &(&1["at_ms"] == at_ms))

      # 新栏：这一轮写成了“自己”，选择此刻看到的是它的收尾句与时刻；observe 与 `Life.mind/2` 给出同一条。
      thought = %{closing: reflection.latest["self"]["closing"], at_ms: at_ms}
      assert reflection.thought == thought
      assert {:ok, %{thought: ^thought}} = Life.mind(cid, [])

      # 召回走经历库；存档进反思库（建库名同经历库的写法），经历库没有收到任何反思文档。
      assert_received {:recall, "npc-life-" <> _, _}
      assert_received {:ensure_bank, "npc-reflect-" <> bank_cid, "NPC " <> _}
      assert bank_cid == to_string(cid)
      assert_received {:retained, "npc-reflect-" <> _, documents}

      assert Enum.map(documents, & &1["id"]) |> Enum.map(&hd(String.split(&1, ":"))) ==
               ~w(reflection reflection reflection)

      assert Enum.all?(documents, &(&1["at_ms"] == at_ms))

      refute_received {:retained, "npc-life-" <> _, _}

      # 重启：持久行是权威，各问最新一条与触发状态都还在。
      old_life = :global.whereis_name({Life, node(), cid})
      ref = Process.monitor(old_life)
      Process.exit(fixture.body, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}, 5000

      restored =
        await_reflection(cid, fn r ->
          :global.whereis_name({Life, node(), cid}) != old_life and r.latest != nil
        end)

      assert restored.latest == reflection.latest
      assert restored.thought == thought
      assert restored.trigger == reflection.trigger
      assert restored.counts == reflection.counts
    end

    @tag timeout: 120_000
    test "写日记失败一次：这一轮中止，不再发请求、新经历不消耗；封存不受影响；手动再起一轮把它们再问一遍" do
      %{cid: cid} = reflecting()

      # 槽在途：手动入口给 busy；这一刻的新经历条数（起槽时整份交给了这一轮）。
      assert_receive {:write, worker, _, place}, 10_000
      assert {:ok, %{status: :busy}} = Life.reflect(cid)
      {:ok, %{reflection: %{new: taken}}} = Life.observe(cid)
      assert taken > 0

      # 真实形状的失败（`Writer.write/3` 请求超时时的返回）。
      send(worker, {:reply, {:error, :timeout}})
      refute_receive {:write, _, _, _}, 300

      reflection = await_reflection(cid, &(&1.round != nil and not &1.running))

      assert reflection.round["failed"] == ["place:small hut"] and
               reflection.round["written"] == []

      assert reflection.round["archive"] == "none"

      assert %{"rounds" => 1, "failed" => 1, "written" => 0, "aborted" => 1} =
               reflection.counts

      assert reflection.error == :timeout and reflection.latest == %{}
      # 中止的一轮不消耗新经历。
      assert reflection.new == taken
      # 中止的一轮没写成“自己”：新栏没有那一句。
      assert reflection.thought == nil
      assert {:ok, %{thought: nil}} = Life.mind(cid, [])

      {:ok, observed} = Life.observe(cid)
      assert observed.error == nil and observed.job == nil
      assert {:ok, %{status: :started}} = Life.flush(cid)
      assert_receive {:retained, "npc-life-" <> _, [document]}, 5000
      assert document["text"] =~ ~s|removed the entire building "small hut"|
      refute_received {:ensure_bank, "npc-reflect-" <> _, _}

      # 手动再起一轮：同样的新经历，又从小屋问起；起轮时清掉上一轮的失败原因。
      assert {:ok, %{status: :started}} = Life.reflect(cid)
      assert {:ok, %{reflection: %{running: true, error: nil}}} = Life.observe(cid)
      assert_receive {:write, worker, _, again}, 10_000
      assert again =~ ~s|To think over now: My building "small hut": |
      assert place =~ ~s|To think over now: My building "small hut": |
      send(worker, {:reply, written_reply()})

      for _ <- 1..2 do
        assert_receive {:write, worker, _, _}, 10_000
        send(worker, {:reply, written_reply()})
      end

      reflection = await_reflection(cid, &(&1.round["archive"] == "ok"))
      assert reflection.round["causes"] == ["manual"] and map_size(reflection.latest) == 3
      assert %{"rounds" => 2, "aborted" => 1, "written" => 3} = reflection.counts

      assert reflection.thought == %{
               closing: reflection.latest["self"]["closing"],
               at_ms: reflection.round["at_ms"]
             }

      # 这一轮做完：新经历消耗掉，手动入口给 empty。
      assert reflection.new == 0
      assert {:ok, %{status: :empty}} = Life.reflect(cid)
    end

    # 新栏的核心判断是“这一轮写成了‘自己’”，不是“这一轮写成了点什么”：小屋写成、下一问失败的一轮，小屋那条落栏，新栏仍为空。
    @tag timeout: 120_000
    test "写成了小屋、下一问写日记失败：小屋那条落栏，没写成“自己”，新栏没有那一句" do
      %{cid: cid} = reflecting()

      assert_receive {:write, worker, _, place}, 10_000
      assert place =~ ~s|To think over now: My building "small hut": |
      send(worker, {:reply, written_reply()})

      # 真实形状的失败（`Writer.write/3` 请求超时时的返回）。
      assert_receive {:write, worker, _, _}, 10_000
      send(worker, {:reply, {:error, :timeout}})
      refute_receive {:write, _, _, _}, 300

      reflection = await_reflection(cid, &(&1.round != nil and not &1.running))
      assert reflection.round["written"] == ["place:small hut"]
      assert Map.keys(reflection.latest) == ["place:small hut"]
      assert %{"aborted" => 1, "written" => 1} = reflection.counts
      assert reflection.thought == nil
      assert {:ok, %{thought: nil}} = Life.mind(cid, [])
    end

    @tag timeout: 120_000
    test "应答检查不合格：同一份请求原样重问一次，仍不合格就丢弃，持久行里没有它" do
      %{cid: cid} = reflecting()

      # 不合格的真实应答：S1-X2 第 4 轮 Q_self 的应答引用到第 43 条材料，这里的材料只有 30 条左右（Used 编号越界）。
      # （check-samples 里没有 Used 缺失或超句数的真实应答；这是同一份真实应答落在条数更少的材料上的真实失败。）
      unfit = {:ok, %{text: json("check-samples.json")["4-Q_self"]["response"], usage: %{}}}
      assert_receive {:write, worker, system, user}, 10_000
      send(worker, {:reply, unfit})
      assert_receive {:write, ^worker, ^system, ^user}, 10_000
      send(worker, {:reply, unfit})

      for _ <- 1..2 do
        assert_receive {:write, worker, _, _}, 10_000
        send(worker, {:reply, written_reply()})
      end

      reflection = await_reflection(cid, &(&1.round != nil and not &1.running))
      assert reflection.round["discarded"] == ["place:small hut"]
      refute Map.has_key?(reflection.latest, "place:small hut")
      assert map_size(reflection.latest) == 2

      # 检查不合格被丢弃不算中止：这一轮做完，新经历照样消耗。
      assert %{"reasked" => 1, "discarded" => 1, "written" => 2, "aborted" => 0} =
               reflection.counts

      assert reflection.new == 0 and reflection.error == nil
    end

    @tag timeout: 120_000
    test "存档失败：archive_failed 加一、小结记 failed，已落栏的日记仍在" do
      %{cid: cid} = reflecting(archive_fails: true)

      for _ <- 1..3 do
        assert_receive {:write, worker, _, _}, 10_000
        send(worker, {:reply, written_reply()})
      end

      reflection = await_reflection(cid, &(&1.round != nil and not &1.running))
      assert_received {:retained, "npc-reflect-" <> _, [_, _, _]}
      assert reflection.round["archive"] == "failed"
      assert %{"archive_failed" => 1, "written" => 3, "failed" => 0} = reflection.counts
      assert map_size(reflection.latest) == 3 and reflection.error == :timeout
    end

    @tag timeout: 120_000
    test "写作阶段 worker 崩溃：Life 不崩，这一轮中止、新经历不消耗、槽已清，observe 给出原因" do
      %{cid: cid} = reflecting()
      life = :global.whereis_name({Life, node(), cid})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert_receive {:write, worker, _, _}, 10_000
          {:ok, %{reflection: %{new: taken}}} = Life.observe(cid)
          assert taken > 0

          # 写日记的函数在 worker 里退出：落栏之前崩溃。
          send(worker, {:exit, :journal_writer_crashed})
          reflection = await_reflection(cid, &(&1.round != nil and not &1.running))

          # 落栏前崩溃的小结：问到的键不知道，都是空表；没有可存的。
          assert %{"asked" => [], "written" => [], "failed" => [], "archive" => "none"} =
                   reflection.round

          assert %{"rounds" => 1, "aborted" => 1, "written" => 0, "archive_failed" => 0} =
                   reflection.counts

          assert reflection.new == taken and reflection.latest == %{}
          assert {:reflect_worker_crashed, detail} = reflection.error
          assert detail =~ "journal_writer_crashed"
        end)

      assert :global.whereis_name({Life, node(), cid}) == life and Process.alive?(life)
      assert log =~ "event=crashed" and log =~ "stage=writing"
    end

    @tag timeout: 120_000
    test "存档阶段 worker 崩溃：日记已落栏仍在，archive_failed 加一、小结记 failed，不算中止" do
      %{cid: cid} = reflecting(archive_crashes: true)
      life = :global.whereis_name({Life, node(), cid})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..3 do
            assert_receive {:write, worker, _, _}, 10_000
            send(worker, {:reply, written_reply()})
          end

          reflection = await_reflection(cid, &(&1.round != nil and not &1.running))
          assert_received {:retained, "npc-reflect-" <> _, [_, _, _]}
          assert reflection.round["archive"] == "failed"

          assert %{"archive_failed" => 1, "aborted" => 0, "written" => 3, "failed" => 0} =
                   reflection.counts

          # 做完的一轮：日记在 "latest"，新经历已消耗。
          assert map_size(reflection.latest) == 3 and reflection.new == 0
          assert {:reflect_worker_crashed, _} = reflection.error
        end)

      assert :global.whereis_name({Life, node(), cid}) == life and Process.alive?(life)
      assert log =~ "event=crashed" and log =~ "stage=archiving"
    end

    @tag timeout: 120_000
    test "落栏那次保存失败：Life 不崩，persist_failed 一行；存档结果回来不碰行，新经历不消耗" do
      :ets.new(ControlledStore, [:named_table, :public])
      %{cid: cid} = reflecting(memory: ControlledStore)
      life = :global.whereis_name({Life, node(), cid})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for n <- 1..3 do
            assert_receive {:write, worker, _, _}, 10_000

            # 最后一问交回之前放下“下一次保存被拒”：下一次保存就是落栏。
            if n == 3, do: :ets.insert(ControlledStore, {cid, self()})
            send(worker, {:reply, written_reply()})
          end

          assert_receive {:save_refused, refused}, 10_000
          assert refused["reflection"]["round"]["archive"] == "pending"
          assert length(refused["reflection"]["round"]["written"]) == 3

          # 槽结束（存档结果已回来）。
          reflection = await_reflection(cid, &(not &1.running))
          assert_received {:retained, "npc-reflect-" <> _, [_, _, _]}

          # 行没落栏、存档结果也没写进来：首轮的小结仍是 nil（不在 nil 上写、不记到别的轮头上）。
          assert reflection.round == nil and reflection.latest == %{}
          assert %{"rounds" => 1, "written" => 0, "archive_failed" => 0} = reflection.counts
          assert reflection.new > 0
          assert reflection.error == {:memory_unavailable, :write_denied}
          assert DataService.NpcMemory.get(cid, "life", "state")["reflection"]["round"] == nil
        end)

      assert :global.whereis_name({Life, node(), cid}) == life
      assert log =~ "event=persist_failed"
      assert log =~ "event=archive_unrecorded"
    end

    @tag timeout: 120_000
    test "槽在途时又到点：跳过这一次（skipped 加一），触发状态不清零，留给下一次" do
      # 间隔按经历的时刻算：World 事件的时刻是 World 提交的时刻，手动一轮的时刻是 Life 的时钟。让 Life 的时钟比 World 慢
      # 10 分钟，手动起的一轮记下的时刻就比随后真实发生的 World 事件早 5 分钟以上——不用等墙钟就能在槽在途时到点。
      %{fixture: fixture, cid: cid} =
        reflecting(clock: fn -> System.system_time(:millisecond) - 10 * 60_000 end)

      # 小屋被拆那一轮先中止（写日记失败），新经历留着；再手动起一轮，让它在途（写日记的函数不放行）。
      assert_receive {:write, worker, _, _}, 10_000
      send(worker, {:reply, {:error, :timeout}})
      await_reflection(cid, &(&1.round != nil and not &1.running))
      assert {:ok, %{status: :started}} = Life.reflect(cid)
      assert_receive {:write, worker, _, _}, 10_000

      {:ok, %{reflection: started}} = Life.observe(cid)
      manual_at_ms = started.trigger["last_at_ms"]
      assert started.running and started.trigger["score"] == 0

      # 又一件真实的“动我放的东西”：Brann 打掉我放的一格（World 正式入口）。距手动那一轮已过 5 分钟：到点了，但槽在途。
      damage(fixture.world, cid, 2, {5, 64, 8})
      skipped = await_reflection(cid, &(&1.counts["skipped"] == 1))

      assert skipped.running
      assert skipped.trigger["last_at_ms"] == manual_at_ms
      assert skipped.trigger["event_waiting"] and skipped.trigger["score"] > 0
      assert skipped.new == started.new + 1

      # 放行手动这一轮：它只消耗起槽时取走的那几条，后来的那一条留给下一轮；触发状态仍是跳过时的样子。
      send(worker, {:reply, written_reply()})

      for _ <- 1..2 do
        assert_receive {:write, worker, _, _}, 10_000
        send(worker, {:reply, written_reply()})
      end

      done = await_reflection(cid, &(&1.round["causes"] == ["manual"] and not &1.running))
      assert done.new == 1 and done.counts["rounds"] == 2 and done.counts["skipped"] == 1
      assert done.trigger == skipped.trigger
    end

    test "没开反思的形态：手动入口给 reflection_disabled，observe 没有反思" do
      {_fixture, _body, cid} = start()
      assert Life.reflect(cid) == {:error, :reflection_disabled}
      assert {:ok, %{reflection: nil}} = Life.observe(cid)
      # 不反思的形态：交给 Mind 的那一句恒为 nil（新栏不出现）。
      assert {:ok, %{thought: nil}} = Life.mind(cid, [])
    end

    test "反思之前存下的行（没有 reflection 键）：加载时补成空的一份，其余照常" do
      fixture = NpcWorld.start()
      cid = System.unique_integer([:positive]) + 100_000
      profile = reflect_profile(self(), %{}, DataService.NpcMemory)

      # 真实代码路径存下一份行，停掉这个 NPC，再把行里的 "reflection" 删掉。
      NpcWorld.body(fixture, {Spy, profile}, cid: cid)

      NpcWorld.await(fn ->
        match?({:ok, %{state: %{"cursor" => _}, cache: %{}, job: nil}}, Life.observe(cid))
      end)

      {:ok, before} = Life.observe(cid)
      ref = Process.monitor(:global.whereis_name({Life, node(), cid}))
      stop_supervised!(DynamicSupervisor)
      assert_receive {:DOWN, ^ref, _, _, _}, 5000

      saved = DataService.NpcMemory.get(cid, "life", "state")
      old = Map.delete(saved, "reflection")
      :ok = DataService.NpcMemory.put(cid, "life", "state", old)

      NpcWorld.body(fixture, {Spy, profile}, cid: cid)
      restored = await_reflection(cid, & &1.trigger)

      assert restored == %{
               enabled: true,
               running: false,
               trigger: %{"score" => 0, "last_at_ms" => nil, "event_waiting" => false},
               new: 0,
               latest: %{},
               round: nil,
               counts:
                 Map.new(
                   ~w(rounds written reasked discarded failed aborted skipped archive_failed),
                   &{&1, 0}
                 ),
               thought: nil,
               error: nil
             }

      {:ok, reloaded} = Life.observe(cid)
      assert reloaded.state == before.state

      # 补上的那份随下一次保存落库，其余各键照旧。
      NpcWorld.await(fn ->
        DataService.NpcMemory.get(cid, "life", "state")["reflection"] != nil
      end)

      stored = DataService.NpcMemory.get(cid, "life", "state")
      assert Map.delete(stored, "reflection") == old
    end

    # 起一个开着反思的 NPC，放下一座有名字的小屋，等到身体状态到了，再由另一角色（Brann）经镐的拆卸整座拆掉。
    # opts：`memory`（存储模块，缺省真实 NpcMemory）、`clock`（Life 的时钟）、`archive_fails` / `archive_crashes`
    # （反思库写入失败 / 抛错，见 ReflectHindsight）。
    defp reflecting(opts \\ []) do
      test = self()
      fixture = NpcWorld.start()
      world = fixture.world
      cid = System.unique_integer([:positive]) + 100_000

      profile =
        reflect_profile(
          test,
          Map.new(Keyword.take(opts, [:clock, :archive_fails, :archive_crashes])),
          Keyword.get(opts, :memory, DataService.NpcMemory)
        )

      %{body: body} = NpcWorld.body(fixture, {Spy, profile}, cid: cid)
      NpcWorld.await(fn -> match?({:ok, %{cache: %{}, job: nil}}, Life.observe(cid)) end)

      hut =
        VoxelRegion.Prefab.encode(%{
          cells: [],
          macro_cells: [{{0, 0, 0}, 11}],
          children: [],
          attachments: []
        })

      {:ok, id} =
        World.publish_prefab(world, NpcWorld.actor(cid + 20, {0.0, 0.0, 0.0}), hut, "small hut")

      {:ok, _} = World.material_supply(world, cid, "reflect-hut-supply", %{11 => 1024})

      {:ok, _placed} =
        World.prefab_intent(
          world,
          actor(cid),
          :voxel_prefab_place_v1,
          %{
            definition_id: id,
            anchor: {32, 512, 64},
            orientation: 0,
            client_intent_seq: 1
          }
        )

      NpcWorld.await(fn ->
        match?({:ok, %{state: %{"buildings" => [%{"name" => "small hut"}]}}}, Life.observe(cid))
      end)

      # 身体状态是 Scene 下行的真实值；到了之后 Life 手里的观察才带着它。
      await_body_state()
      brann = cid + 10
      remove(world, brann, {4, 64, 8})
      %{fixture: Map.put(fixture, :body, body), cid: cid, brann: brann}
    end

    defp await_body_state do
      receive do
        {:life_observation, %{self: %{body_state: %{}}}} -> :ok
        {:life_observation, _} -> await_body_state()
      after
        10_000 -> flunk("没有收到带身体状态的观察")
      end
    end

    # 另一角色站在 (4.5, 65.5, 8.5) 用镐拆下 cell 所在的整个构件（action 2，先查询命中目标，再按它出手）。
    # 角色替身经 `actor/1` 取（同一角色只起一个，`damage/4` 随后还能用它）。
    defp remove(world, attacker_cid, {x, y, z}) do
      attacker = actor(attacker_cid)

      query = %{
        request_id: 1,
        client_intent_seq: 1,
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
          Map.merge(attacker, %{received_us: 1_000_000, clock_node: node()}),
          query
          |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
          |> Map.put(:action, 2)
        )
    end

    # 合格的真实应答：S1-X2 第 1 轮 Q_place（Used 编号 3、8、10，都在这里的材料条数内）。
    defp written_reply,
      do: {:ok, %{text: json("check-samples.json")["1-Q_place"]["response"], usage: %{}}}

    defp await_reflection(cid, ready) do
      NpcWorld.await(
        fn ->
          case Life.observe(cid) do
            {:ok, %{reflection: %{} = reflection}} -> ready.(reflection) && reflection
            _ -> false
          end
        end,
        15_000
      )
    end
  end
end
