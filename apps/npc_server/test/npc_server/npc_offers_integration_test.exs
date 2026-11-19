Code.require_file("../support/life_fixtures.exs", __DIR__)
Code.require_file("../support/http_stub.exs", __DIR__)
Code.require_file("../support/spend_fixtures.exs", __DIR__)

defmodule NpcServer.NpcOffersIntegrationTest do
  @moduledoc """
  只测试：稿 A 批 1 的背包候选（eat / craft）从生成到记账的整条链（`docs/10-active/cross-cutting/2026-11-18-npc-full-capability-coverage-decision.md`
  §5 T-A4）：真实 World 的 `production_options/2`（进食 / 合成门由 World 与提交同一处判定）→ `Offers` 生成候选（每类前 3 项）
  → Jev 选中 → `Trees.npc` 按冻结的世界动作（候选的 `action`）发命令 → Body → Scene / Player → World 提交或拒绝
  → 下一次发问带结局 → Life 的经历与日计划记账。

  契约：
  - **进食**：World 列出的能吃一份的材料按材料号升序进候选；选中后 World 的进食账记一份；活动完成的经历（判据写进句子）进 Life，
    下一次发问的 state 里有它；当日计划里没点名对象的 `eat` 意图记一次完成；选中的候选整份记在 observe 的
    `select.activities[].candidate`（世界动作在 `action`）。吃到不够一份的材料下一轮不再列出。当前真实目录只有 3 种可食植物，
    **进食一类的前 3 截断在当前目录下不可达**，截断由合成用例证明。
  - **合成与每类截断**：真实目录里只需石 / 石灰石（另加铜）的 4 个配方都够时只列前 3（按材料号）；合成一次后合成账记各材料净变化，
    输入不够的产物下一轮不再列出、原来排第 4 的补进来；`npc_select … candidates=…` 一行列出本轮候选。
  - **权威拒绝**：发问那一刻可行、执行时已不可行（余额被同一角色的另一笔进食吃掉）→ World 拒绝 `insufficient_material`
    → 这一项活动失败 → 下一次发问的 state 带失败原因，候选里不再有它。生成器不替 World 做最后裁决。

  层次与依赖（`../Voxim/Docs/Testing.md` §2.2），照生产组合根：真实 `Registry.brain/2`（统一形态 profile 的正式解析入口，
  含生产注入的花费额度闸门 `spend`）、Body、Runtime、`Brain.Tree`（`Trees.npc/1`）、Life（规则模式、真实 `DataService.NpcMemory`，
  本 VM 独占的 PostgreSQL）、真实 `SpendBudget`（真实账本；上限取 `SpendFixtures.env/1` 的 65 美元，宽松到本用例碰不到；
  `poll_ms: :manual`，读回一轮后为 `:open`；读回的 Hindsight 服务是 `HttpStub`，没有任何库）、Scene / Player、
  World（`NpcWorld.start/1` 夹具，文件世界）。替身只有三处外部依赖：Jev（`profile.request` 发送函数，把请求体交给测试进程、
  由测试给出冻结应答，应答形状同 `npc_jev_test` 的官方 HTTP 文档样本，没有用量所以不进额度账）、写作（`profile.write_journal`，同
  `LifeFixtures.reflect_profile/3`：规划应答由测试给出，反思一律给写作接口真实形状的超时失败）与 Hindsight（Life 只替适配器模块
  `LifeFixtures.ReflectHindsight`；额度读回替 HTTP 对端）。对正式组合根的调整只有一处：`Registry.brain/2` 之后换上这三处替身
  （适配器模块经 `put/2` 的 JSON 参数注入不了，同 `npc_selector_test` 的做法，所以不经 `Registry.put/2`）。
  不证明：真实模型会选进食 / 合成（选择快照里没有饥饿信号，是已知不覆盖的后续议题）、营养进身体（本夹具世界没有 climate）与
  真实客户端（T-A5）。

  前提与生命周期：每个用例一个新世界（具名进程，所以 `async: false`）、一个新角色 cid、一个新的额度进程；材料行取真实目录
  Voxim `Content/Voxel/Properties/Playable/Published/e6db8dee…json`（2026-11-10 最新一份）的目录字段（`display_name`、`food`、
  `place_units`、`recipe_inputs`、`recipe_units`）：可食 Fern 34 / Dandelion 36 / Allium 39；配方 Switch 41（铜 24 × 8192 + 石 11 × 4096）、
  灰褐砌石 46（石 × 2097152）、石质饰面 47 与太湖石 56（石灰石 10 × 2097152）。余额只经作者入口 `World.material_supply/4`
  一次供给并记账，之后只经正常玩法消费。权威拒绝用例里“另一笔进食”经 World 的正式生产入口 `World.production_intent/3`
  （action 5，与 Body 发出的同一种请求）以该 NPC 的身份提交。

  游戏钟：Runtime 写进观察的游戏钟直接取墙钟（现实 150 秒 = 游戏 1 小时），没有可注入的缝。进食用例的计划记账要求完成时仍在
  规划那一游戏日，所以用例给自己一个运行预算 `@run_ms`：开始前到游戏日末的现实余量不足 `@run_ms` 就先等到下一游戏日
  （等的是日号变化这个条件，至多 `@run_ms`），之后每一步都在截止时刻前完成、否则显式失败——用例活不到日末，不会偶发跨日；
  用例总时限 = 至多一次等待 + 运行预算 + 余量。

  执行：`cd apps/npc_server && mix test --no-start test/npc_server/npc_offers_integration_test.exs`（WSL Linux、本机 PostgreSQL）。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import NpcServer.SpendFixtures, only: [env: 1]
  alias MmoContracts.WorldTime
  alias NpcServer.{HttpStub, Life, NpcWorld, Selector, SpendBudget}
  alias NpcServer.LifeFixtures.ReflectHindsight
  alias NpcServer.SpendBudget.Config
  alias VoxelRegion.World

  @moduletag :capture_log

  # 统一形态的注册参数：只登记一个去处（统一形态的候选表不能为空）；背包候选全由生成器做出。
  @params %{
    "who" => "Lin, a forager",
    "persona" => %{"traits" => %{"practical" => 7}, "personal" => "Eats what the land gives."},
    "tools" => %{},
    "activities" => [
      %{
        "name" => "rest_at_home",
        "criterion" => "Go home and rest.",
        "place" => [4.0, 10.0],
        "stay_ticks" => 60,
        "place_name" => "home"
      }
    ]
  }

  # 真实目录的目录字段（见 moduledoc；其余属性用夹具的基础属性）。
  @serving 262_144
  @macro 2_097_152
  @fern %{
    display_name: "Fern",
    food: %{protein_g: 1.38, energy_j: 42_705.36},
    place_units: @serving
  }
  @dandelion %{
    display_name: "Dandelion",
    food: %{protein_g: 1.08, energy_j: 75_362.4},
    place_units: @serving
  }
  @allium %{
    display_name: "Allium",
    food: %{protein_g: 0.6, energy_j: 102_157.92},
    place_units: @serving
  }
  @limestone %{display_name: "Limestone"}
  @copper %{display_name: "Copper"}
  @switch %{
    display_name: "Switch",
    recipe_inputs: [%{material_id: 24, units: 8192}, %{material_id: 11, units: 4096}],
    recipe_units: 4096
  }
  @masonry %{
    display_name: "灰褐砌石",
    recipe_inputs: [%{material_id: 11, units: @macro}],
    recipe_units: @macro
  }
  @facing %{
    display_name: "石质饰面",
    recipe_inputs: [%{material_id: 10, units: @macro}],
    recipe_units: @macro
  }
  @taihu %{
    display_name: "太湖石",
    recipe_inputs: [%{material_id: 10, units: @macro}],
    recipe_units: @macro
  }

  @stone 11
  @rest {"rest_at_home", "Go home and rest."}
  @plan_marker "It is time to plan the rest of today."

  # 进食用例的运行预算（见 moduledoc 的“游戏钟”）。**原创取值**：2026-11-19 本机（WSL）实测这个用例从起世界到最后一问
  # 约 1.8 秒，取 10 倍有余给负载抖动；它同时是开始前至多等待的时长（原来最坏空等约 75 秒，现在至多 20 秒，
  # 落在游戏日最后 20 秒现实时间里的概率约 20 / 3600）。
  @run_ms 20_000

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  # 生产组合根里花费额度进程与 NPC 同在：起真实 SpendBudget（真实账本、宽松上限），Life 经生产注入的 `spend` 读它的结论。
  setup do
    DataService.Repo.delete_all("npc_spend_ledger")
    url = HttpStub.start(&hindsight/3)

    start_supervised!(
      {SpendBudget,
       config: Config.load!(env(%{"NPC_LIFE_HINDSIGHT_URL" => url})), poll_ms: :manual}
    )

    assert %{state: :open} = SpendBudget.sync()
    :ok
  end

  @tag timeout: 2 * @run_ms + 10_000
  test "eat: World-listed servings become candidates; eating spends one serving, is an experience and counts toward the day plan" do
    deadline = same_game_day(@run_ms)

    %{world: world, cid: cid, body: body} =
      start_npc(
        %{34 => @fern, 36 => @dandelion, 39 => @allium},
        %{34 => 2 * @serving, 36 => @serving, 39 => @serving}
      )

    # 第一问：登记项在前，进食候选按材料号升序（当前目录只有 3 种可食，前 3 截断在这里不可达）；没有合成候选、附近没人所以没有说话。
    {jev, request} = await_jev(deadline)

    assert criteria(request) == [
             @rest,
             {"eat:34", "Eat one serving of Fern (material 34) from my inventory."},
             {"eat:36", "Eat one serving of Dandelion (material 36) from my inventory."},
             {"eat:39", "Eat one serving of Allium (material 39) from my inventory."}
           ]

    reply(jev, "eat:34")
    NpcWorld.await(fn -> food_ledger(world) == %{34 => @serving} end, left(deadline))
    assert @serving == NpcWorld.balance(world, cid, 34)

    # 吃完是一条活动经历；有过经历后 Life 起当日规划（花费额度开着）。规划提示词的词表里有进食与合成两类（不可点名对象）。
    {writer, system} = await_plan_write(deadline)

    assert system =~
             "\n- eat: Eat one serving of something edible from my inventory." <>
               "\n- craft: Craft something from materials in my inventory."

    plan =
      ~s|{"intents": [{"activity": "eat", "times": 1, "by": "23:59", | <>
        ~s|"why": "I should eat again before the day is out."}], "cannot_yet": []}|

    send(writer, {:reply, {:ok, %{text: plan, usage: %{}}}})

    NpcWorld.await(
      fn ->
        match?(
          {:ok,
           %{plan: %{running: false, row: %{"intents" => [%{"activity" => "eat", "done" => 0}]}}}},
          Life.observe(cid)
        )
      end,
      left(deadline)
    )

    # 第二问：上一项完成，经历里有判据；Fern 还剩一份，候选不变。
    {jev, request} = await_jev(deadline)

    assert request.state =~
             ~s|I did "eat:34" (Eat one serving of Fern (material 34) from my inventory.). Result: completed.|

    assert request.state =~ "Recent activities: Oldest first. eat:34: completed."
    assert [@rest, {"eat:34", _}, {"eat:36", _}, {"eat:39", _}] = criteria(request)
    reply(jev, "eat:34")

    # 第三问：第二份记到当日计划那条 eat 意图上（第一份在计划之前，不算）；Fern 吃完不再列出。
    {jev, request} = await_jev(deadline)
    assert food_ledger(world) == %{34 => 2 * @serving}
    assert 0 == NpcWorld.balance(world, cid, 34)

    assert {:ok,
            %{
              plan: %{row: %{"intents" => [%{"activity" => "eat", "object" => nil, "done" => 1}]}}
            }} =
             Life.observe(cid)

    assert criteria(request) == [
             @rest,
             {"eat:36", "Eat one serving of Dandelion (material 36) from my inventory."},
             {"eat:39", "Eat one serving of Allium (material 39) from my inventory."}
           ]

    # observe：选中的候选整份记在选择里（种类、对象、冻结的世界动作）。
    assert %{select: %{activities: [first, second]}} = NpcServer.Body.observe(body)

    for entry <- [first, second] do
      assert %{
               activity: "eat:34",
               result: :completed,
               candidate: %{
                 kind: "eat",
                 object: %{"material" => 34},
                 action: {"eat", %{"material" => 34}}
               }
             } = entry
    end

    reply(jev, "rest_at_home")
  end

  @tag timeout: 60_000
  test "craft: four feasible recipes list only the first three; crafting writes the craft ledger and the next round refills from the fourth" do
    Logger.put_module_level(Selector, :info)
    on_exit(fn -> Logger.delete_module_level(Selector) end)

    log =
      capture_log([level: :info], fn ->
        # 铜与石恰够一个开关、石另够一份砌石；石灰石够饰面或太湖石各一份（两份的量）。
        %{world: world, cid: cid} =
          start_npc(
            %{
              10 => @limestone,
              24 => @copper,
              41 => @switch,
              46 => @masonry,
              47 => @facing,
              56 => @taihu
            },
            %{24 => 8192, @stone => @macro + 4096, 10 => 2 * @macro}
          )

        send(self(), {:cid, cid})

        # 第一问：四个配方都够，按材料号只列前 3（太湖石 56 排第 4，不列）。
        {jev, request} = await_jev()

        assert criteria(request) == [
                 @rest,
                 {"craft:41", "Craft Switch (material 41) from materials in my inventory."},
                 {"craft:46", "Craft 灰褐砌石 (material 46) from materials in my inventory."},
                 {"craft:47", "Craft 石质饰面 (material 47) from materials in my inventory."}
               ]

        reply(jev, "craft:46")

        # 第二问：合成账（石 −2097152、砌石 +2097152）；石只剩 4096，砌石不再列，太湖石补进前 3。
        {jev, request} = await_jev()
        assert %{@stone => -@macro, 46 => @macro} == craft_ledger(world)
        assert {4096, @macro} == {NpcWorld.balance(world, cid), NpcWorld.balance(world, cid, 46)}

        assert request.state =~
                 ~s|I did "craft:46" (Craft 灰褐砌石 (material 46) from materials in my inventory.). Result: completed.|

        assert criteria(request) == [
                 @rest,
                 {"craft:41", "Craft Switch (material 41) from materials in my inventory."},
                 {"craft:47", "Craft 石质饰面 (material 47) from materials in my inventory."},
                 {"craft:56", "Craft 太湖石 (material 56) from materials in my inventory."}
               ]

        reply(jev, "craft:41")

        # 第三问：开关合成（铜 −8192、石 −4096、开关 +4096）；铜与石用完，开关不再列。
        {jev, request} = await_jev()

        assert %{@stone => -(@macro + 4096), 24 => -8192, 41 => 4096, 46 => @macro} ==
                 craft_ledger(world)

        assert criteria(request) == [
                 @rest,
                 {"craft:47", "Craft 石质饰面 (material 47) from materials in my inventory."},
                 {"craft:56", "Craft 太湖石 (material 56) from materials in my inventory."}
               ]

        reply(jev, "rest_at_home")
      end)

    assert_received {:cid, cid}

    # CLI / 日志：每次选择一行，列出本轮候选（截断之后的）。
    assert log =~
             ~r/npc_select cid=#{cid} trigger=start candidates=rest_at_home,craft:41,craft:46,craft:47 chosen=craft:46 /

    assert log =~
             ~r/npc_select cid=#{cid} trigger=completed candidates=rest_at_home,craft:41,craft:47,craft:56 chosen=craft:41 /
  end

  @tag timeout: 60_000
  test "authority refusal: the serving is eaten between asking and acting; World refuses, the activity fails and the next ask carries why" do
    %{world: world, cid: cid} = start_npc(%{34 => @fern}, %{34 => @serving})

    {jev, request} = await_jev()

    assert criteria(request) == [
             @rest,
             {"eat:34", "Eat one serving of Fern (material 34) from my inventory."}
           ]

    # 发问那一刻恰好一份；应答之前，同一角色经 World 正式生产入口吃掉了它（可行性在执行时已过时）。
    eater = NpcWorld.actor(cid, {4.0, 67.5, 10.0})

    assert {:ok, _} =
             World.production_intent(world, eater, %{
               request_id: 1,
               client_intent_seq: 1,
               logical_scene_id: 1,
               action: 5,
               coord: {0, 0, 0},
               tool_id: 1,
               material: 34
             })

    assert 0 == NpcWorld.balance(world, cid, 34)
    reply(jev, "eat:34")

    # World 拒绝；这一项失败，下一次发问的 state 带动作与原因，候选里不再有它；进食账只有那一笔。
    {jev, request} = await_jev()

    assert request.state =~
             "Recent activities: Oldest first. eat:34: failed (eat: insufficient_material)."

    assert request.state =~
             ~s|I did "eat:34" (Eat one serving of Fern (material 34) from my inventory.). | <>
               "Result: failed (eat: insufficient_material)."

    assert criteria(request) == [@rest]
    assert %{34 => @serving} == food_ledger(world)
    reply(jev, "rest_at_home")
  end

  # —— 夹具 ——

  # 新世界（材料行与生产材料由用例给）+ 作者供给一次 + 用正式入口解析的统一形态 profile 起一个 NPC Body。
  defp start_npc(rows, supply) do
    fixture =
      NpcWorld.start(
        material_rows: rows,
        production_materials: Enum.sort([@stone | Map.keys(rows)])
      )

    cid = System.unique_integer([:positive]) + 100_000
    {:ok, _} = World.material_supply(fixture.world, cid, "offers-supply", supply)
    %{body: body} = NpcWorld.body(fixture, {NpcServer.Brain.Tree, profile()}, cid: cid)
    %{world: fixture.world, cid: cid, body: body}
  end

  # 统一形态 profile 经 `Registry.brain/2`（解析完即还原环境），再换上三处替身；生产注入的 `spend` 原样保留。
  defp profile do
    env = %{
      "TYPESAFE_API_URL" => "http://127.0.0.1:9/jev",
      "TYPESAFE_API_KEY" => "test-key",
      "TYPESAFE_MODEL" => "jev-test",
      "NPC_LIFE_HINDSIGHT_URL" => "http://life.test.invalid",
      "NPC_REFLECT_URL" => "http://127.0.0.1:9/v1/messages",
      "NPC_REFLECT_KEY" => "test-key",
      "NPC_REFLECT_MODEL" => "reflect-test"
    }

    old = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(env)

    {NpcServer.Brain.Tree, profile} =
      try do
        NpcServer.Registry.brain("npc", @params)
      after
        for {key, value} <- old,
            do: if(value, do: System.put_env(key, value), else: System.delete_env(key))
      end

    test = self()

    profile
    |> Map.put(:request, fn _endpoint, body ->
      send(test, {:jev_request, self(), body})

      receive do
        {:jev_reply, reply} -> reply
      end
    end)
    |> Map.put(:write_journal, fn system, user ->
      send(test, {:write, self(), system, user})

      receive do
        {:reply, reply} -> reply
      end
    end)
    |> Map.update!(
      :life,
      &Map.merge(&1, %{hindsight: ReflectHindsight, owner: test, poll_ms: 30})
    )
  end

  # 额度读回的 Hindsight 对端：没有任何 `npc-` 库（本用例的 Life 适配器是替身，不建库）。
  defp hindsight(:get, "/v1/default/banks?" <> _, nil), do: {200, %{"banks" => [], "total" => 0}}

  defp await_jev(deadline \\ nil) do
    receive do
      {:jev_request, jev, request} -> {jev, request}
    after
      left(deadline, 30_000) -> flunk("没有收到 Jev 请求")
    end
  end

  # 请求体里的有序候选 `[{名字, 判据}]`（同 `npc_selector_test` 读法）。
  defp criteria(request), do: request.questions.activity.criteria.values

  defp reply(jev, choice),
    do:
      send(
        jev,
        {:jev_reply,
         {:ok,
          %{
            "answers" => %{
              "activity" => %{"type" => "choice", "choice" => choice, "confidence" => 0.6}
            }
          }}}
      )

  # 等下一次规划写作（只认规划的系统提示词）；途中的反思写作给写作接口真实形状的超时失败。
  defp await_plan_write(deadline) do
    receive do
      {:write, worker, system, _user} ->
        if String.contains?(system, @plan_marker) do
          {worker, system}
        else
          send(worker, {:reply, {:error, :timeout}})
          await_plan_write(deadline)
        end
    after
      left(deadline) -> flunk("没有收到规划写作")
    end
  end

  defp food_ledger(world), do: World.material_snapshot(world, [], []).food_ledger
  defp craft_ledger(world), do: World.material_snapshot(world, [], []).craft_ledger

  # —— 游戏钟（见 moduledoc） ——

  # 开始前到游戏日末的现实余量不足 `run_ms` 就等到下一游戏日；返回这次运行的截止时刻（单调毫秒）。
  defp same_game_day(run_ms) do
    %{day: day} = WorldTime.at(System.system_time(:microsecond))
    to_day_end = real_ms_to_day_end()

    if to_day_end < run_ms,
      do:
        NpcWorld.await(
          fn -> WorldTime.at(System.system_time(:microsecond)).day != day end,
          to_day_end + 1_000
        )

    System.monotonic_time(:millisecond) + run_ms
  end

  # 此刻到这一游戏日结束的现实毫秒（游戏时间 = 现实时间 × rate）。
  defp real_ms_to_day_end do
    day_us = 24 * 60 * 60_000_000
    game_us = WorldTime.game_us(System.system_time(:microsecond))
    div(day_us - Integer.mod(game_us, day_us), WorldTime.params().rate * 1_000)
  end

  # 离截止时刻还剩多少毫秒（没有截止时刻时用给定的缺省）。
  defp left(deadline, default \\ nil)
  defp left(nil, default), do: default
  defp left(deadline, _default), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
