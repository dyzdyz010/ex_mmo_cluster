Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcSelectorTest do
  @moduledoc """
  只测试：控制链的“选择”一步（`NpcServer.Selector`、`Trees.npc/1` 与 Runtime 的受理），以及心智进快照的接缝
  （Life 的情绪与近期经历、一次记忆召回 → 给 Jev 的 state）。快照的英文转写本身在 `npc_mind_test`。

  范围与替身：
  - 纯函数用例直接构造输入：请求体、top1 读法、选择器记账。
  - 树用例是纯 `Brain.Tree`：手排事件，逐个断言命令字面量（按 `NpcServer.Brain` 的命令表手写）。
  - 集成用例是真实 `Runtime` + 真实 `Brain.Tree` + 真实 `build` 技能 + 真实 `Life`（规则模式，真实 `DataService.NpcMemory`，
    需要本 VM 独占的 Postgres）+ 真实 `VoxelRegion.World`（`NpcServer.NpcWorld` 夹具；“建设被破坏”是经 World 正式入口做出来的
    真实事务），profile 由正式入口 `Registry.brain/2` 解析。替身只有三处：
    Jev 的 HTTP 发送函数（`profile.request`，回放冻结应答，形状取自官方 HTTP 文档与 `npc_jev_test`）、
    Hindsight（只替 HTTP 适配器模块，沿用 `npc_life_test` 的做法；召回的结果或失败由测试给定）、
    Body（本文件的 GenServer，命令转给测试进程，Outcome 由测试手排）。
    所以它证明“活动结束 → 读心智 → 发问 → 应答 → 执行被选中的分支”这条链的交接与 Life 的真实状态进了 state，
    不证明真实身体的移动、真实 Hindsight 的召回内容，也不证明真实 Jev 会因此改选。
  - `:live_jev` 用例问真实 Jev（验收 a），只在显式 `--include live_jev` 时运行。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias NpcServer.{Life, NpcWorld, Persona, Runtime, Selector}
  alias NpcServer.Brain.Tree
  alias VoxelRegion.World

  @hex String.duplicate("AB", 32)
  @north %{"definition" => @hex, "anchor_micro" => [8, 8, 8], "orientation" => 0}
  @south %{"definition" => @hex, "anchor_micro" => [80, 8, 8], "orientation" => 0}

  # 候选的登记次序故意不是字典序（zeta 在 alpha 前）：请求体里的次序只能来自登记次序。
  @params %{
    "who" => "Lin, a builder",
    "persona" => %{"traits" => %{"bold" => 8}, "personal" => "Keeps promises."},
    "tools" => %{},
    "activities" => [
      %{"name" => "zeta_build_north", "criterion" => "Build the hut on the north plot.", "skill" => "build",
        "args" => @north},
      %{"name" => "alpha_build_south", "criterion" => "Build the hut on the south plot.", "skill" => "build",
        "args" => @south},
      %{"name" => "rest_at_home", "criterion" => "Go home and rest.", "place" => [3.0, -4.0], "stay_ticks" => 120}
    ]
  }

  # 只测试：Hindsight 适配器替身（只替 HTTP）。认识固定一份；召回把问句交给测试进程，结果取测试当前给定的那一个
  # （`config.recall` 是测试持有的 Agent：`{:ok, %{results:, latency_ms:}}` 或 `{:error, 原因}`）。
  defmodule Hindsight do
    def ensure(_, _), do: {:ok, %{}}
    def models(_), do: {:ok, %{models: %{"self" => "I am a careful builder."}, metadata: %{}}}
    def refresh(config), do: models(config)
    def status(_), do: {:ok, %{stats: %{}, usage: %{}}}
    def retain(_, fragments), do: {:ok, %{retained: length(fragments), facts: 1}}

    def recall(config, query, _now_ms) do
      send(config.owner, {:recall_called, query})
      Agent.get(config.recall, & &1)
    end
  end

  # 只测试：连不上的 Hindsight——建 bank 这一步就失败，认识读不出来。
  defmodule NoModels do
    def ensure(_, _), do: {:error, :transport_error}
  end

  # 只测试：Body 替身。命令转给测试进程；事件由测试手排后经真实 Runtime 入口投递。
  defmodule Body do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts) do
      # Runtime 起 Life 要用的会话身份：永久 cid、Scene 与路由（真实 Body 在 claim 后给出同一形状）。
      context = %{cid: opts.cid, scene_id: 1, router: NpcServer.NpcWorld.Route}
      {:ok, Map.put(opts, :brain, NpcServer.Runtime.init({NpcServer.Brain.Tree, opts.profile}, context))}
    end

    def handle_call(:brain, _, s), do: {:reply, s.brain, s}

    def handle_call(:skill_context, _, s),
      do: {:reply, {:ok, %{actor: %{cid: s.cid}, world: :world, scene: :scene}}, s}

    def handle_cast({:command, c}, s) do
      send(s.owner, {:command, c})
      {:noreply, s}
    end

    def handle_cast({:event, event}, s) do
      NpcServer.Runtime.handle_event(event, s.brain)
      {:noreply, s}
    end

    def handle_info({:npc_runtime_outcome, outcome}, s) do
      send(s.owner, {:runtime_outcome, outcome})
      {:noreply, s}
    end
  end

  setup context do
    Logger.put_module_level(Selector, :info)
    on_exit(fn -> Logger.delete_module_level(Selector) end)

    # 真实 Jev 用例读运行环境里的真实接口，不走替身 profile。
    if context[:live_jev], do: :ok, else: %{profile: stub_profile()}
  end

  # 只测试：Jev 的 endpoint 与 Hindsight 的地址取自运行环境；这里的地址不会被请求（发送函数与适配器被替换）。
  # 解析完即还原环境。
  defp stub_profile(params \\ @params) do
    env = %{
      "TYPESAFE_API_URL" => "http://127.0.0.1:9/jev",
      "TYPESAFE_API_KEY" => "test-key",
      "TYPESAFE_MODEL" => "jev-test",
      "NPC_LIFE_HINDSIGHT_URL" => "http://life.test.invalid"
    }

    old = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(env)

    try do
      {NpcServer.Brain.Tree, profile} = NpcServer.Registry.brain("npc", params)
      profile
    after
      for {key, value} <- old,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))
    end
  end

  defp observation(tick \\ 1, cid \\ 7),
    do: %{
      self: %{entity_id: cid, position: {1.0, 2.0, 3.0}, tick: tick, grounded: true, body_state: nil},
      pending: [],
      entities: [],
      balances: nil
    }

  # 官方 HTTP 文档的应答形状（同 npc_jev_test）。
  defp answer(choice, confidence),
    do:
      {:ok,
       %{"answers" => %{"activity" => %{"type" => "choice", "choice" => choice, "confidence" => confidence}}}}

  describe "request body" do
    test "candidates keep the registration order; the state is passed through as given", %{profile: profile} do
      body = Selector.body(profile, "Character: Lin, a builder.")

      assert "jev-test" == body.model
      assert [:activity] == Map.keys(body.questions)
      assert "choice" == body.questions.activity.type
      assert "Character: Lin, a builder." == body.state

      # 问法点到快照的每一栏。
      assert "Decide what this specific character does next. Choose the single option this character would " <>
               "actually pick, given their personality, feelings and relationships, what just happened, " <>
               "what they remember, current situation and recent activities." ==
               body.questions.activity.instructions

      # 线上的 JSON：候选对象的键次序 = 登记次序（zeta、alpha、rest），不是字典序。
      wire = Jason.decode!(Jason.encode!(body), objects: :ordered_objects)

      assert [
               {"zeta_build_north", "Build the hut on the north plot."},
               {"alpha_build_south", "Build the hut on the south plot."},
               {"rest_at_home", "Go home and rest."}
             ] == wire["questions"]["activity"]["criteria"].values
    end
  end

  describe "registration" do
    test "an npc row always carries Life: the address from the environment or the row, never switched off", %{
      profile: profile
    } do
      # 省略 life：地址取运行环境。
      assert %{url: "http://life.test.invalid"} == profile.life

      # 显式地址。
      assert %{life: %{url: "http://hindsight.example:8888"}} =
               stub_profile(Map.put(@params, "life", %{"url" => "http://hindsight.example:8888"}))

      # 统一形态必带 Life，不能关掉。
      assert_raise ArgumentError, ~r/life=false/, fn -> stub_profile(Map.put(@params, "life", false)) end

      # 运行环境没有 Hindsight 地址、参数里也没给：登记不了（stub_profile 结束时已还原环境，这里的环境里没有它）。
      assert nil == System.get_env("NPC_LIFE_HINDSIGHT_URL")

      System.put_env(%{
        "TYPESAFE_API_URL" => "http://127.0.0.1:9/jev",
        "TYPESAFE_API_KEY" => "test-key",
        "TYPESAFE_MODEL" => "jev-test"
      })

      try do
        assert_raise System.EnvError, ~r/NPC_LIFE_HINDSIGHT_URL/, fn -> NpcServer.Registry.brain("npc", @params) end
      after
        for key <- ~w(TYPESAFE_API_URL TYPESAFE_API_KEY TYPESAFE_MODEL), do: System.delete_env(key)
      end
    end
  end

  describe "ask/3 (frozen Jev answers)" do
    defp ask(profile, reply) do
      Selector.ask(
        Map.put(profile, :request, fn _endpoint, _body -> reply end),
        %{state: "Character: Lin, a builder.", recall_query: "q", recall_ms: 41},
        "start"
      )
    end

    test "preference: the top1 is taken even at very low confidence", %{profile: profile} do
      # 召回耗时取自这次发问（41），随选择一起记下。
      assert {:ok,
              %{
                activity: "alpha_build_south",
                confidence: 0.21,
                trigger: "start",
                model: "jev-test",
                latency_ms: ms,
                recall_ms: 41
              }} = ask(profile, answer("alpha_build_south", 0.21))

      assert is_integer(ms) and ms >= 0
    end

    test "a choice outside the candidates is an explicit failure", %{profile: profile} do
      assert {:error, {:unknown_activity, "dance"}} == ask(profile, answer("dance", 0.99))
    end

    test "transport errors and malformed answers are explicit failures", %{profile: profile} do
      assert {:error, {503, "busy"}} == ask(profile, {:error, {503, "busy"}})
      assert {:error, :malformed_response} == ask(profile, {:ok, %{"answers" => %{}}})
      assert {:error, :malformed_response} == ask(profile, {:ok, %{"error" => "bad request"}})
    end
  end

  describe "selector bookkeeping" do
    test "an ended activity is recorded once; a re-ask after a failed selection is a retry", %{
      profile: profile
    } do
      selection = fn name, trigger ->
        %{activity: name, confidence: 0.6, latency_ms: 12, recall_ms: 3, trigger: trigger, model: "m"}
      end

      state = Selector.new()
      assert nil == Selector.current(state)
      assert {"start", state} = Selector.ended(state, nil)

      state = Selector.chose(state, selection.("rest_at_home", "start"), profile, 7)
      assert "rest_at_home" == Selector.current(state)
      assert [] == Selector.history(state)

      # 活动失败：记一次结局，本次发问是 failed。
      failure = {:failed, "travel", "no_path"}
      assert {"failed", state} = Selector.ended(state, failure)
      assert nil == Selector.current(state)
      assert [%{activity: "rest_at_home", result: ^failure}] = Selector.history(state)

      # 刚结束的活动写成一句经历：候选名、它的判据、结局。
      assert ~s|I did "rest_at_home" (Go home and rest.). Result: failed (travel: no_path).| ==
               Selector.experience(state, profile)

      # 发问失败后树带着同一份报告重问：不重复记账，trigger 是 retry。
      state = Selector.failed(state, {503, "busy"}, 7)
      assert %{failure: {503, "busy"}} = state
      assert {"retry", ^state} = Selector.ended(state, failure)

      state = Selector.chose(state, selection.("zeta_build_north", "retry"), profile, 7)
      assert %{failure: nil} = state
      assert {"completed", state} = Selector.ended(state, :completed)

      assert ~s|I did "zeta_build_north" (Build the hut on the north plot.). Result: completed.| ==
               Selector.experience(state, profile)

      assert [
               %{activity: "rest_at_home", result: ^failure},
               %{activity: "zeta_build_north", result: :completed}
             ] = Selector.history(state)

      # 最近一次问 Jev 的内容原样留在状态里，供 observe 读。
      question = %{state: "Character: Lin.", recall_query: "q", recall_ms: 3}
      assert %{asked: nil} = state
      assert %{asked: ^question} = Selector.asked(state, question)
    end

    test "only the five most recent activities are kept", %{profile: profile} do
      state =
        Enum.reduce(1..7, Selector.new(), fn n, state ->
          {_, state} = Selector.ended(state, :completed)

          Selector.chose(
            state,
            %{activity: "a#{n}", confidence: 0.5, latency_ms: 1, recall_ms: 1, trigger: "completed", model: "m"},
            profile,
            7
          )
        end)

      assert ["a3", "a4", "a5", "a6", "a7"] == Enum.map(state.activities, & &1.activity)
    end
  end

  describe "Trees.npc (pure tree)" do
    defp obs(tick), do: {:observation, %{self: %{entity_id: 7, tick: tick}}}

    defp done(id, verb, data),
      do: {:outcome, %{id: id, verb: verb, status: :done, reason: nil, data: data}}

    defp rejected(id, verb, reason),
      do: {:outcome, %{id: id, verb: verb, status: :rejected, reason: reason, data: nil}}

    defp script(state, steps) do
      Enum.reduce(steps, state, fn {event, expected}, state ->
        {commands, state} = Tree.handle_event(event, state)
        assert commands == expected, "after #{inspect(event)}"
        state
      end)
    end

    test "ask, run the chosen branch to its end, report how it ended, ask again", %{profile: profile} do
      build_north = %{verb: :skill, skill: :build, args: @north}

      Tree.init(profile)
      |> script([
        # 首次发问：还没有活动结束过。
        {obs(0), [%{id: 1, verb: :choose_activity, ended: nil}]},
        # 等应答：观察只推进时间，不发任何命令。
        {obs(1), []},
        # 选中“去处”：travel 到登记的地点。
        {done(1, :choose_activity, %{activity: "rest_at_home"}),
         [%{id: 2, verb: :skill, skill: :travel, args: %{"x" => 3.0, "z" => -4.0}}]},
        # 到了之后待 120 tick：等待从最近一次观察的 tick 1 起算，121 到期。
        {done(2, :travel, %{}), []},
        {obs(120), []},
        {obs(121), []},
        # 活动结束后的下一个事件：再次发问，报告上一项已完成。
        {obs(122), [%{id: 3, verb: :choose_activity, ended: :completed}]},
        # 选中技能候选：执行登记的那次技能调用。
        {done(3, :choose_activity, %{activity: "zeta_build_north"}), [Map.put(build_north, :id, 4)]},
        # 活动失败不终止树：下一次发问带失败的动作与原因。
        {rejected(4, :build, :occupied), []},
        {obs(123), [%{id: 5, verb: :choose_activity, ended: {:failed, "build", "occupied"}}]}
      ])
    end

    test "a failed selection runs nothing, waits 600 ticks and asks again with the same report", %{
      profile: profile
    } do
      state =
        Tree.init(profile)
        |> script([
          {obs(0), [%{id: 1, verb: :choose_activity, ended: nil}]},
          # 发问失败：不执行任何分支；等待从 tick 0 起算，600 到期。
          {rejected(1, :choose_activity, {503, "busy"}), []},
          {obs(599), []},
          {obs(600), []},
          {obs(601), [%{id: 2, verb: :choose_activity, ended: nil}]},
          {rejected(2, :choose_activity, :malformed_response), []},
          {obs(1201), []},
          {obs(1202), [%{id: 3, verb: :choose_activity, ended: nil}]}
        ])

      # 树没有结束。
      assert state.finished == nil
    end
  end

  describe "real Runtime + Tree + Life" do
    setup do
      MmoTest.Database.start!()
      fixture = NpcWorld.start()
      # 永久 cid：每个用例一个新角色（Life 的持久行按 cid，世界身份随夹具变）。
      %{fixture: fixture, cid: System.unique_integer([:positive]) + 100_000}
    end

    # Jev 替身：每次请求把请求体交给测试进程，并等测试进程给出这一次的冻结应答。
    # Hindsight 替身的召回结果由返回的 `recall` Agent 给定，缺省是空结果（新 NPC 的空 bank）。
    defp start(profile, cid) do
      test = self()

      request = fn _endpoint, body ->
        send(test, {:jev_request, self(), body})

        receive do
          {:jev_reply, reply} -> reply
        end
      end

      recall = start_supervised!({Agent, fn -> {:ok, %{results: [], latency_ms: 3}} end})

      profile =
        profile
        |> Map.put(:request, request)
        |> Map.update!(:life, &Map.merge(&1, %{hindsight: Hindsight, owner: test, recall: recall, poll_ms: 30}))

      body = start_supervised!({Body, %{owner: self(), profile: profile, cid: cid}})

      # Life 加载完持久行、读到认识缓存之后，心智才读得到（在这之前的发问是显式失败，见下面的用例）。
      NpcWorld.await(fn -> match?({:ok, %{cache: %{}, job: nil}}, Life.observe(cid)) end)
      {body, GenServer.call(body, :brain), recall}
    end

    defp event(body, event), do: GenServer.cast(body, {:event, event})

    # 同步点：Body 已把此前的事件转给 Runtime，Runtime 已处理完，由此发出的命令也已经过 Body 到达测试进程。
    defp settled(body, runtime) do
      GenServer.call(body, :brain)
      state = Runtime.observe(runtime)
      GenServer.call(body, :brain)
      state
    end

    defp skill_step(body, call, status, reason) do
      event(
        body,
        {:outcome, %{id: {:skill, call, 1}, verb: :prefab_place, status: status, reason: reason, data: %{seq: 1}}}
      )
    end

    # 只测试：经 World 正式入口做出“我放的一格被别人破坏”。作者入口一次给料（记账），NPC 角色替身放一格石料，
    # 另一角色用镐打它一下（同 npc_life_test 的做法）。返回破坏者的 cid。
    defp damage(world, npc, seq, cell) do
      {:ok, _} = World.material_supply(world, npc, "selector-supply-#{seq}", %{11 => 512})

      {:ok, _} =
        World.production_intent(world, NpcWorld.actor(npc, {4.5, 65.5, 8.5}), %{
          request_id: seq,
          client_intent_seq: seq,
          logical_scene_id: 1,
          action: 1,
          coord: cell,
          tool_id: 1,
          material: 11
        })

      attacker = NpcWorld.actor(npc + 10, {4.5, 65.5, 8.5})
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
          query
          |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
          |> Map.put(:action, 1)
        )

      npc + 10
    end

    test "end of activity -> ask -> run the chosen branch; failures are explicit and the next round asks again",
         %{profile: profile, cid: cid} do
      {body, runtime, _recall} = start(profile, cid)

      log =
        capture_log([level: :info], fn ->
          # —— 第 1 次：首个观察触发发问；应答到达前不发任何命令。
          event(body, {:observation, observation(1, cid)})
          assert_receive {:jev_request, worker, request}
          assert request.state =~ "Character: Lin, a builder. Personality: very bold. Personal: Keeps promises."
          assert request.state =~ "Recent activities: None yet."

          event(body, {:observation, observation(2, cid)})
          assert %{select: %{activities: [], failure: nil}, skill: nil} = settled(body, runtime)
          refute_received {:command, _}

          # 置信度很低仍取 top1：执行 south 分支（锚点 80,8,8），不是登记在前的 north。
          send(worker, {:jev_reply, answer("alpha_build_south", 0.21)})

          assert_receive {:runtime_outcome,
                          %{id: 1, verb: :choose_activity, status: :done, data: %{activity: "alpha_build_south"}}}

          assert_receive {:command, %{id: {:skill, 2, 1}, verb: :prefab_place, anchor: {80, 8, 8}}}

          assert %{select: %{activities: [%{activity: "alpha_build_south", result: nil, confidence: 0.21}]}} =
                   settled(body, runtime)

          # —— 第 2 次：活动成功结束 → 下一个事件再次发问，state 里有它的结局。
          skill_step(body, 2, :done, nil)
          assert_receive {:runtime_outcome, %{id: 2, verb: :build, status: :done}}
          event(body, {:observation, observation(3, cid)})
          assert_receive {:jev_request, worker, request}
          assert request.state =~ "Recent activities: Oldest first. alpha_build_south: completed."
          send(worker, {:jev_reply, answer("zeta_build_north", 0.9)})
          assert_receive {:command, %{id: {:skill, 4, 1}, verb: :prefab_place, anchor: {8, 8, 8}}}

          # —— 第 3 次：活动失败 → 失败原因写进 state；这次应答的选项不在候选里 → 显式失败，不执行任何活动。
          skill_step(body, 4, :rejected, :occupied)
          assert_receive {:runtime_outcome, %{id: 4, verb: :build, status: :rejected, reason: :occupied}}
          event(body, {:observation, observation(4, cid)})
          assert_receive {:jev_request, worker, request}

          assert request.state =~
                   "alpha_build_south: completed. zeta_build_north: failed (build: occupied)."

          send(worker, {:jev_reply, answer("dance", 0.99)})

          assert_receive {:runtime_outcome,
                          %{id: 5, verb: :choose_activity, status: :rejected, reason: {:unknown_activity, "dance"}}}

          assert %{select: %{failure: {:unknown_activity, "dance"}} = select} = settled(body, runtime)
          assert nil == Selector.current(select)
          refute_received {:command, _}

          # —— 第 4 次：等够 600 tick（从 tick 4 起，604 到期；等待本身由纯树用例逐 tick 验证）后照常再问；
          # 这次 HTTP 出错 → 显式失败，树不崩。
          event(body, {:observation, observation(604, cid)})
          event(body, {:observation, observation(605, cid)})
          assert_receive {:jev_request, worker, _}
          send(worker, {:jev_reply, {:error, {503, "busy"}}})

          assert_receive {:runtime_outcome,
                          %{id: 6, verb: :choose_activity, status: :rejected, reason: {503, "busy"}}}

          # —— 第 5 次：再等 600 tick，照常再问并执行被选中的分支。
          event(body, {:observation, observation(1205, cid)})
          event(body, {:observation, observation(1206, cid)})
          assert_receive {:jev_request, worker, request}
          # 失败的活动只记了一次。
          assert request.state =~
                   "Recent activities: Oldest first. alpha_build_south: completed. " <>
                     "zeta_build_north: failed (build: occupied)."

          send(worker, {:jev_reply, answer("alpha_build_south", 0.55)})
          assert_receive {:command, %{id: {:skill, 8, 1}, verb: :prefab_place, anchor: {80, 8, 8}}}

          assert %{select: %{failure: nil} = select} = settled(body, runtime)
          assert "alpha_build_south" == Selector.current(select)
          refute_received {:command, _}
        end)

      # 召回耗时取自 Hindsight 替身给的 3 毫秒。
      candidates = "candidates=zeta_build_north,alpha_build_south,rest_at_home"
      assert log =~ ~r/npc_select cid=#{cid} trigger=start #{candidates} chosen=alpha_build_south confidence=0.21 latency_ms=\d+ recall_ms=3 model=jev-test/
      assert log =~ ~r/npc_select cid=#{cid} trigger=completed #{candidates} chosen=zeta_build_north confidence=0.9 latency_ms=\d+ recall_ms=3 model=jev-test/
      assert log =~ ~r/npc_select cid=#{cid} trigger=retry #{candidates} chosen=alpha_build_south confidence=0.55 latency_ms=\d+ recall_ms=3 model=jev-test/
      assert log =~ ~s(npc_select_failed cid=#{cid} reason={:unknown_activity, "dance"})
      assert log =~ ~s(npc_select_failed cid=#{cid} reason={503, "busy"})
      # 三次成功、两次失败，各一行。
      assert 3 == length(Regex.scan(~r/npc_select cid=/, log))
      assert 2 == length(Regex.scan(~r/npc_select_failed cid=/, log))
    end

    test "a selection worker that dies without an answer is an explicit failure", %{profile: profile, cid: cid} do
      {body, runtime, _recall} = start(profile, cid)

      capture_log(fn ->
        event(body, {:observation, observation(1, cid)})
        assert_receive {:jev_request, worker, request}
        Process.exit(worker, :kill)

        assert_receive {:runtime_outcome,
                        %{
                          id: 1,
                          verb: :choose_activity,
                          status: :rejected,
                          reason: {:select_worker_failed, :killed}
                        }}

        # 问过什么在请求发出前就记下了：worker 没交结果也读得到。
        assert %{select: %{failure: {:select_worker_failed, :killed}, asked: %{state: state}}} =
                 settled(body, runtime)

        assert state == request.state
      end)
    end

    # 薄片一 S1-B 的接缝：World 里真的发生“我放的一格被别人破坏”之后，下一次发问的 state 里出现对应的情绪、关系与
    # 近期经历；刚结束的活动是一条经历；选择器自己的往来（choose_activity）不是经历；记忆读不到 → 这次不问 Jev。
    @tag timeout: 120_000
    test "a real world event reaches the next question through Life; an unreadable memory fails the selection explicitly",
         %{profile: profile, cid: cid, fixture: fixture} do
      {body, runtime, recall} = start(profile, cid)
      brann = cid + 10
      # Brann 在 (4, 2, 7)，离自己 (1, 2, 3) 5.0 米。
      near = fn tick ->
        Map.put(observation(tick, cid), :entities, [
          %{entity_id: cid, kind: 1, name: "Lin", position: {1.0, 2.0, 3.0}},
          %{entity_id: brann, kind: 0, name: "Brann", position: {4.0, 2.0, 7.0}}
        ])
      end

      query =
        "I am deciding what to do next. Nearby: Brann (actor #{brann}). What I could do: " <>
          "Build the hut on the north plot. Build the hut on the south plot. Go home and rest. " <>
          "What do I remember about these people, places and tasks?"

      log =
        capture_log([level: :info], fn ->
          # —— 第 1 次：什么都还没发生。state 全文手写：情绪、近期经历为空；认识来自缓存；空 bank 的召回为空是正常结果。
          event(body, {:observation, near.(1)})
          assert_receive {:recall_called, ^query}
          assert_receive {:jev_request, worker, request}

          assert "Character: Lin, a builder. Personality: very bold. Personal: Keeps promises.\n" <>
                   "Feelings and relationships: Nothing notable.\n" <>
                   "What just happened: Nothing new.\n" <>
                   "What I remember: My own memories and beliefs; they may be out of date and are not " <>
                   "current world facts.\n- Belief (self): I am a careful builder.\n" <>
                   "Current situation: Standing at x=1.0, z=3.0 (height 2.0). " <>
                   "Nearby: Brann (player, 5.0 m away). Inventory: not checked yet.\n" <>
                   "Recent activities: None yet." == request.state

          # observe 读得到这次问的全文、召回问句与耗时。
          assert %{select: %{asked: %{state: asked, recall_query: ^query, recall_ms: 3}}} = settled(body, runtime)
          assert asked == request.state

          send(worker, {:jev_reply, answer("alpha_build_south", 0.7)})
          assert_receive {:command, %{id: {:skill, 2, 1}, verb: :prefab_place}}

          # —— 活动进行中：Brann 破坏了我放的一格（真实 World 事务），Life 按规则接纳。
          ^brann = damage(fixture.world, cid, 1, {4, 64, 8})

          NpcWorld.await(fn ->
            match?({:ok, %{state: %{"evidence" => %{"damage_count" => 1}}}}, Life.observe(cid))
          end)

          # 这次召回带回一条记忆。
          Agent.update(recall, fn _ ->
            {:ok, %{results: [%{"text" => "Brann once carried stone for me."}], latency_ms: 5}}
          end)

          # —— 第 2 次：活动结束后发问。情绪（刚发生，strong）、关系（一次破坏 −0.35 → Distrusts）、近期经历
          # （先是那次破坏，再是刚结束的活动）、召回都在 state 里。
          skill_step(body, 2, :done, nil)
          assert_receive {:runtime_outcome, %{id: 2, verb: :build, status: :done}}
          event(body, {:observation, near.(3)})
          assert_receive {:recall_called, ^query}
          assert_receive {:jev_request, worker, request}

          assert request.state =~
                   "\nFeelings and relationships: Feels strong anger toward Brann (actor #{brann}). " <>
                     "Distrusts Brann (actor #{brann}).\n"

          assert request.state =~
                   ~r/\nWhat just happened: Oldest first\. At \S+ \(UTC\), Actor #{brann} damaged construction I care about at \(4, 64, 8\), material 11, in world \S+ \(transaction \d+\)\. I feel angry toward this actor; my trust changed\. At \S+ \(UTC\), I did "alpha_build_south" \(Build the hut on the south plot\.\)\. Result: completed\.\n/

          assert request.state =~
                   "- Belief (self): I am a careful builder.\n- Recalled: Brann once carried stone for me.\n"

          assert request.state =~ "\nRecent activities: Oldest first. alpha_build_south: completed."
          second = request.state
          send(worker, {:jev_reply, answer("zeta_build_north", 0.8)})
          assert_receive {:command, %{id: {:skill, 4, 1}, verb: :prefab_place}}

          # —— 第 3 次：记忆读不到。不问 Jev，这次选择显式失败；树不崩。
          Agent.update(recall, fn _ -> {:error, :transport_error} end)
          skill_step(body, 4, :done, nil)
          assert_receive {:runtime_outcome, %{id: 4, verb: :build, status: :done}}
          event(body, {:observation, near.(4)})
          assert_receive {:recall_called, ^query}

          assert_receive {:runtime_outcome,
                          %{
                            id: 5,
                            verb: :choose_activity,
                            status: :rejected,
                            reason: {:mind_unavailable, :transport_error}
                          }}

          refute_received {:jev_request, _, _}
          refute_received {:command, _}

          # 没有发问：observe 里留的仍是上一次问的全文。
          assert %{select: %{failure: {:mind_unavailable, :transport_error}, asked: %{state: ^second}}} =
                   settled(body, runtime)

          assert {:ok, %{recall: %{status: :failed, error: :transport_error}}} = Life.observe(cid)

          # —— 第 4 次：600 tick 后照常再问（从 tick 4 起，604 到期）；记忆读得到了，照常问 Jev。
          Agent.update(recall, fn _ -> {:ok, %{results: [], latency_ms: 4}} end)
          event(body, {:observation, near.(604)})
          event(body, {:observation, near.(605)})
          assert_receive {:recall_called, ^query}
          assert_receive {:jev_request, worker, request}

          # 两项已结束的活动各是一条经历，重问没有重复记；四次 choose_activity 的往来一条也不在里面。
          assert request.state =~
                   ~r/I did "alpha_build_south" \(Build the hut on the south plot\.\)\. Result: completed\. At \S+ \(UTC\), I did "zeta_build_north" \(Build the hut on the north plot\.\)\. Result: completed\.\nWhat I remember/

          refute request.state =~ "choose_activity"
          send(worker, {:jev_reply, answer("alpha_build_south", 0.6)})
          # 命令号逐个递增：1 选、2 建、3 选、4 建、5 选（失败）、6 重选 → 这次的技能调用是 7。
          assert_receive {:command, %{id: {:skill, 7, 1}, verb: :prefab_place, anchor: {80, 8, 8}}}
        end)

      # Life 手里的经历恰好三条：一次破坏、两项活动。
      assert {:ok, %{pending_episodes: 3, pending_fragments: 0, unsaved_experiences: 0, error: nil}} =
               Life.observe(cid)

      assert log =~ ~r/npc_select cid=#{cid} trigger=completed \S+ chosen=zeta_build_north confidence=0.8 latency_ms=\d+ recall_ms=5 model=jev-test/
      assert log =~ "npc_select_failed cid=#{cid} reason={:mind_unavailable, :transport_error}"
      assert log =~ ~r/npc_select cid=#{cid} trigger=retry \S+ chosen=alpha_build_south confidence=0.6 latency_ms=\d+ recall_ms=4 model=jev-test/
    end

    test "without cached models the mind is unreadable: the selection fails explicitly and Jev is not asked",
         %{profile: profile, cid: cid} do
      test = self()

      profile =
        profile
        |> Map.put(:request, fn _, body -> send(test, {:jev_request, self(), body}) end)
        |> Map.update!(:life, &Map.merge(&1, %{hindsight: NoModels, owner: test, poll_ms: 30}))

      capture_log(fn ->
        body = start_supervised!({Body, %{owner: self(), profile: profile, cid: cid}})

        # Life 加载了持久行，但认识读不出来：没有缓存，错误可见。
        NpcWorld.await(fn ->
          match?({:ok, %{state: %{}, cache: nil, error: :transport_error}}, Life.observe(cid))
        end)

        event(body, {:observation, observation(1, cid)})

        assert_receive {:runtime_outcome,
                        %{
                          verb: :choose_activity,
                          status: :rejected,
                          reason: {:mind_unavailable, {:life_models_unavailable, :transport_error}}
                        }}

        refute_received {:jev_request, _, _}
      end)
    end
  end

  # 验收 (a)：同一处境、同一候选表、两张不同的人格卡，top1 不同。
  # 期望在运行前手写：Sella（极友善、很外向、很健谈，讨厌独处）→ 去广场；Hask（很懒、很不活跃，能少做就少做）→ 回家歇着。
  # 两张卡取自调研的 big5.py CARDS；候选的判据对两张卡完全相同，处境是同一份观察（附近没人、背包为空、还没做过任何事），
  # 所以 top1 的差别只能来自人格卡。每张卡问 2 次，串行（并发 1）。
  @tag :live_jev
  @tag timeout: 120_000
  test "the real Jev: the same situation and candidates, two persona cards, different top1" do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    jev = %{
      url: System.fetch_env!("TYPESAFE_API_URL"),
      key: System.fetch_env!("TYPESAFE_API_KEY"),
      model: System.fetch_env!("TYPESAFE_MODEL"),
      timeout_ms: 10_000
    }

    activities = [
      %{name: "gather_stone",
        criterion: "Go to the quarry face and cut stone for the building store. Hard, dusty labour, done alone."},
      %{name: "visit_plaza",
        criterion: "Walk to the village plaza and spend a while among the neighbours, chatting with whoever is there."},
      %{name: "rest_at_home", criterion: "Go home and rest quietly indoors for a while. No effort, no company."}
    ]

    cards = [
      {"Sella, a weaver",
       %{
         "traits" => %{"friendly" => 9, "extraverted" => 8, "talkative" => 8, "kind" => 8, "generous" => 8,
           "altruistic" => 8},
         "personal" => "Loves gossip and hates being alone. Will drop her own work to help a friend."
       }, "visit_plaza"},
      {"Hask, a farmhand",
       %{
         "traits" => %{"hardworking" => 2, "active" => 2, "adventurous and daring" => 3, "anxious" => 3, "tense" => 3},
         "personal" => "Does the least that lets him get by."
       }, "rest_at_home"}
    ]

    observation = %{observation() | balances: []}

    results =
      for {who, json, expected} <- cards, repeat <- 1..2 do
        {:ok, card} = Persona.new(json)
        profile = %{who: who, persona: card, activities: activities, jev: jev}
        # 验收 (a) 只比人格卡：情绪、近期经历、记忆三栏都是空的。
        life = %{feelings: [], relationships: [], recent: [], models: [], memories: [], recall_ms: 0}
        state = NpcServer.Mind.text(NpcServer.Mind.snapshot(profile, observation, [], life))
        {:ok, selection} = Selector.ask(profile, %{state: state, recall_ms: 0}, "start")

        IO.puts(
          "live_jev select who=#{who} repeat=#{repeat} expected=#{expected} chosen=#{selection.activity} " <>
            "confidence=#{selection.confidence} latency_ms=#{selection.latency_ms} model=#{selection.model}"
        )

        {expected, selection.activity}
      end

    assert 4 == length(results)
    assert Enum.all?(results, fn {expected, chosen} -> expected == chosen end), inspect(results)
  end
end
