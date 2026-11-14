Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcRegistryTest do
  @moduledoc """
  只测试：NPC 注册表 `NpcServer.Registry`（放置阶段决策稿 docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md
  §2 M1、§3 授予、§5）。

  - `brain/2`：手写 JSON 参数 → 手写期望 profile（Trees moduledoc 的 Settler profile、Llm moduledoc 的 profile、Patrol 的 profile）。
  - 集成：真实 data_service 测试库（本 VM 独占）、真实 World / Scene / Player（`NpcServer.NpcWorld` 夹具）、以正式缺省名字起的
    `Session.Claims`、`NpcServer.Names` 与 `NpcServer.BodySupervisor`，路由走正式的 `WorldServer.Movement`（`:movement_routes`
    指向夹具 Scene）——注册表与 `Body.start/2` 都不注入替身。“节点重启”= 停掉 NpcSup 的全部子进程后调 `start_all/0`。
  """
  use ExUnit.Case, async: false
  alias DataService.Schema.Character
  alias NpcServer.{Body, Brain, Trees}
  alias NpcServer.Registry, as: NpcRegistry
  alias NpcServer.NpcWorld
  alias SceneServer.Movement.Scene

  @moduletag :capture_log

  @hex String.duplicate("2A", 32)
  @patrol %{"route" => [[4.0, 10.0], [8.0, 10.0]], "dig" => nil}
  # 只测试：Llm 的模型接口取自运行环境；集成用例里指向本机一个没人听的端口（请求失败只记日志、按退避重试）。
  @llm_env %{
    "NPC_LLM_URL" => "http://127.0.0.1:9/responses",
    "NPC_LLM_KEY" => "test-key",
    "NPC_LLM_MODEL" => "test-model",
    "NPC_LLM_EFFORT" => nil,
    "NPC_LLM_CACERTFILE" => nil,
    "NPC_LLM_TIMEOUT_MS" => nil
  }

  # 只测试：Jev 的接口取自运行环境；集成用例里指向本文件起的本机 HTTP 替身。
  @jev_env %{
    "TYPESAFE_API_URL" => "http://127.0.0.1:9/jev",
    "TYPESAFE_API_KEY" => "test-key",
    "TYPESAFE_MODEL" => "jev-test"
  }
  # 只测试：统一形态必带 Life，Hindsight 的地址取自运行环境；集成用例里指向本文件起的本机 HTTP 替身。
  # 只测试：反思写日记的接口同样取自运行环境；本文件不触发反思（地址是本机不监听的端口，不会被请求到外部）。
  @npc_env @jev_env
           |> Map.put("NPC_LIFE_HINDSIGHT_URL", "http://life.test.invalid")
           |> Map.merge(%{
             "NPC_REFLECT_URL" => "http://127.0.0.1:9/v1/messages",
             "NPC_REFLECT_KEY" => "test-key",
             "NPC_REFLECT_MODEL" => "reflect-test"
           })
  @npc %{
    "who" => "Lin, a builder",
    "persona" => %{"traits" => %{"thrifty" => 8, "extraverted" => 3}, "personal" => "Dislikes crowds."},
    "tools" => %{"1" => "镐"},
    "activities" => [
      %{
        "name" => "gather_stone",
        "criterion" => "Cut stone at the quarry.",
        "skill" => "gather",
        "args" => %{"box" => [[10, 64, 4], [13, 64, 6]], "material" => 11, "units" => 512, "tool_id" => 1}
      },
      %{"name" => "rest_at_home", "criterion" => "Go home and rest.", "place" => [2, -3.5], "stay_ticks" => 600}
    ]
  }

  describe "brain/2" do
    test "settler: the row's JSON becomes the Settler tree profile; skills build / gather are fixed" do
      params = %{
        "definition" => @hex,
        "sites" => [
          %{"anchor_micro" => [64, 512, 112], "orientation" => 0, "stand" => [8.5, 11.5]}
        ],
        "quarries" => %{"11" => %{"box" => [[10, 64, 4], [13, 64, 6]], "tool_id" => 1}},
        "revisit_ticks" => 36_000,
        "tools" => %{"1" => "镐"}
      }

      assert {Brain.Tree,
              %{
                tree: &Trees.settler/1,
                definition: @hex,
                sites: [%{anchor_micro: [64, 512, 112], orientation: 0, stand: [8.5, 11.5]}],
                quarries: %{11 => %{box: [[10, 64, 4], [13, 64, 6]], tool_id: 1}},
                revisit_ticks: 36_000,
                tools: %{1 => "镐"},
                skills: %{build: %{}, gather: %{}, travel: %{}}
              }} == NpcRegistry.brain("settler", params)

      # 采石盒可缺省（只用现有余额）。
      assert {Brain.Tree, %{quarries: %{}}} =
               NpcRegistry.brain("settler", Map.delete(params, "quarries"))
    end

    # 放置阶段决策稿 §7：可选的扩张区域；配了才多一个 expand 技能（Settler 树每轮维护完已知工地后调用一次）。
    test "settler: an optional expansion (region, spacing, tool_id) becomes profile.expansion and adds the expand skill" do
      params = %{
        "definition" => @hex,
        "sites" => [],
        "revisit_ticks" => 600,
        "tools" => %{"1" => "镐"},
        "expansion" => %{"region" => [[6, 8], [16, 10]], "spacing" => 2, "tool_id" => 1}
      }

      assert {Brain.Tree,
              %{
                tree: &Trees.settler/1,
                definition: @hex,
                sites: [],
                quarries: %{},
                revisit_ticks: 600,
                tools: %{1 => "镐"},
                skills: %{build: %{}, gather: %{}, travel: %{}, expand: %{}},
                expansion: %{region: [[6, 8], [16, 10]], spacing: 2, tool_id: 1}
              }} == NpcRegistry.brain("settler", params)

      for bad <- [
            %{"region" => [[6, 8], [16, 10]], "spacing" => -1, "tool_id" => 1},
            %{"region" => [[6, 8]], "spacing" => 2, "tool_id" => 1},
            %{"region" => [[6, 8], [16.5, 10]], "spacing" => 2, "tool_id" => 1},
            %{"region" => [[6, 8], [16, 10]], "spacing" => 2},
            %{"region" => [[6, 8], [16, 10]], "tool_id" => 1}
          ] do
        assert_raise_any(
          fn -> NpcRegistry.brain("settler", %{params | "expansion" => bad}) end,
          bad
        )
      end
    end

    # 统一形态（总纲 2026-11-12，薄片一）：人格卡与有序候选表来自注册参数，Jev 的 endpoint 与 Hindsight 的地址来自运行环境。
    test "npc: persona card, ordered activities and derived skills from the row, the Jev endpoint and Life from the environment" do
      with_env(@npc_env, fn ->
        assert {Brain.Tree,
                %{
                  tree: &Trees.npc/1,
                  who: "Lin, a builder",
                  # 特质按词表次序（extraverted 在 thrifty 前），不是 JSON 键的次序。
                  persona: %{traits: [{"extraverted", 3}, {"thrifty", 8}], personal: "Dislikes crowds."},
                  activities: [
                    %{
                      name: "gather_stone",
                      criterion: "Cut stone at the quarry.",
                      run:
                        {:skill, "gather",
                         %{"box" => [[10, 64, 4], [13, 64, 6]], "material" => 11, "units" => 512, "tool_id" => 1}},
                      place_name: nil
                    },
                    %{name: "rest_at_home", criterion: "Go home and rest.", run: {:place, [2, -3.5], 600}, place_name: nil}
                  ],
                  tools: %{1 => "镐"},
                  skills: %{gather: %{}, travel: %{}},
                  jev: %{url: "http://127.0.0.1:9/jev", key: "test-key", model: "jev-test", timeout_ms: 10_000},
                  # 反思写日记的接口取运行环境（R3 起）。
                  reflect: %{url: "http://127.0.0.1:9/v1/messages", key: "test-key", model: "reflect-test"},
                  # 必带 Life：行里没写 life，地址取运行环境。大脑仍是 Tree，不套 Social。
                  life: %{url: "http://life.test.invalid"}
                }} == NpcRegistry.brain("npc", @npc)

        # 行里显式给地址。
        assert {Brain.Tree, %{life: %{url: "http://hindsight.example:8888"}}} =
                 NpcRegistry.brain("npc", Map.put(@npc, "life", %{"url" => "http://hindsight.example:8888"}))

        # 只有技能候选：技能表里没有 travel。
        assert {Brain.Tree, %{skills: %{gather: %{}}}} =
                 NpcRegistry.brain("npc", %{@npc | "activities" => [hd(@npc["activities"])]})

        [gather, rest] = @npc["activities"]

        # 走向一个角色（S1-F）：选择器 "distrusted" + 停留；由 travel 承担移动，技能表推出 travel。
        confront = %{"name" => "confront", "criterion" => "Face the person I distrust.", "person" => "distrusted", "stay_ticks" => 60}

        assert {Brain.Tree,
                %{
                  activities: [
                    %{name: "confront", criterion: "Face the person I distrust.", run: {:person, :distrusted, 60}, place_name: nil}
                  ],
                  skills: %{travel: %{}}
                }} = NpcRegistry.brain("npc", %{@npc | "activities" => [confront]})

        # 可选的地名（第五个键 place_name）：三种形状都能带，进 profile 的 place_name；不写是 nil（上面）。
        assert {Brain.Tree,
                %{
                  activities: [
                    %{name: "gather_stone", place_name: "the quarry", run: {:skill, "gather", _}},
                    %{name: "rest_at_home", place_name: "home", run: {:place, [2, -3.5], 600}},
                    %{name: "confront", place_name: "wherever they are", run: {:person, :distrusted, 60}}
                  ]
                }} =
                 NpcRegistry.brain("npc", %{
                   @npc
                   | "activities" => [
                       Map.put(gather, "place_name", "the quarry"),
                       Map.put(rest, "place_name", "home"),
                       Map.put(confront, "place_name", "wherever they are")
                     ]
                 })

        for bad <- [
              # 走向一个角色：未知选择器、选择器不是字符串、与去处同写。
              %{@npc | "activities" => [%{confront | "person" => "trusted"}]},
              %{@npc | "activities" => [%{confront | "person" => 21}]},
              %{@npc | "activities" => [Map.put(rest, "person", "distrusted")]},
              # 人格卡：键不在词表、级别越界、personal 不是字符串。
              %{@npc | "persona" => %{"traits" => %{"brave" => 8}, "personal" => ""}},
              %{@npc | "persona" => %{"traits" => %{"thrifty" => 10}, "personal" => ""}},
              %{@npc | "persona" => %{"traits" => %{"thrifty" => 8}, "personal" => nil}},
              # 候选表：空、重名、缺判据、未知技能（design_house 要 LLM，不能作候选）、去处不是 [x, z]、停留不是正整数、
              # 一项里同时写技能与去处。
              %{@npc | "activities" => []},
              %{@npc | "activities" => [gather, %{rest | "name" => "gather_stone"}]},
              %{@npc | "activities" => [Map.delete(gather, "criterion")]},
              %{@npc | "activities" => [%{gather | "skill" => "design_house"}]},
              %{@npc | "activities" => [%{rest | "place" => [2]}]},
              %{@npc | "activities" => [%{rest | "stay_ticks" => 0}]},
              %{@npc | "activities" => [Map.put(rest, "skill", "travel")]},
              # 地名：空串、不是字符串；地名不能顶替缺的键（四个键仍要齐）。
              %{@npc | "activities" => [Map.put(rest, "place_name", "")]},
              %{@npc | "activities" => [Map.put(rest, "place_name", 7)]},
              %{@npc | "activities" => [Map.put(rest, "place_name", nil)]},
              %{@npc | "activities" => [rest |> Map.delete("stay_ticks") |> Map.put("place_name", "home")]},
              Map.delete(@npc, "who"),
              Map.delete(@npc, "tools"),
              # 统一形态不能关掉 Life；地址不是 http(s) URL。
              Map.put(@npc, "life", false),
              Map.put(@npc, "life", %{"url" => "hindsight:8888"})
            ] do
          assert_raise_any(fn -> NpcRegistry.brain("npc", bad) end, bad)
        end
      end)

      # 运行环境没有 Jev 接口：登记不了。
      with_env(%{@npc_env | "TYPESAFE_API_URL" => nil}, fn ->
        assert_raise_any(fn -> NpcRegistry.brain("npc", @npc) end, :no_jev_url)
      end)

      # 运行环境没有反思写日记的接口：登记不了。
      with_env(%{@npc_env | "NPC_REFLECT_URL" => nil}, fn ->
        assert_raise System.EnvError, ~r/NPC_REFLECT_URL/, fn -> NpcRegistry.brain("npc", @npc) end
      end)

      # 运行环境没有 Hindsight 地址、行里也没给：登记不了。
      with_env(%{@npc_env | "NPC_LIFE_HINDSIGHT_URL" => nil}, fn ->
        assert_raise System.EnvError, ~r/NPC_LIFE_HINDSIGHT_URL/, fn -> NpcRegistry.brain("npc", @npc) end
      end)
    end

    test "llm: expand is registered without configuration and projected as a tool" do
      with_env(@llm_env, fn ->
        assert {Brain.Llm, %{skills: %{build: %{}, expand: %{}}} = profile} =
                 NpcRegistry.brain("llm", %{
                   "goal" => "g",
                   "tools" => %{"1" => "镐"},
                   "skills" => ["expand", "build"]
                 })

        assert "expand" in Enum.map(NpcServer.Abilities.tools(profile), & &1.name)
      end)
    end

    test "llm: goal / belt / groups / skills / spells / genesis from the row, endpoint from the environment" do
      env = %{
        @llm_env
        | "NPC_LLM_URL" => "https://llm.example/v1/responses",
          "NPC_LLM_EFFORT" => "high",
          "NPC_LLM_CACERTFILE" => "/etc/ca.pem",
          "NPC_LLM_TIMEOUT_MS" => "300000"
      }

      params = %{
        "goal" => "把西边整平",
        "tools" => %{"1" => "镐", "9" => "点火器"},
        "groups" => ["move", "sense", "genesis"],
        "skills" => ["build"],
        "spells" => %{"ignite" => "{}"},
        "max_requests_per_hour" => 60,
        "genesis" => true
      }

      with_env(env, fn ->
        assert {Brain.Llm,
                %{
                  goal: "把西边整平",
                  tools: %{1 => "镐", 9 => "点火器"},
                  groups: [:move, :sense, :genesis],
                  skills: %{build: %{}},
                  spells: %{"ignite" => "{}"},
                  max_requests_per_hour: 60,
                  cadence: :automatic,
                  genesis: true,
                  endpoint: %{
                    url: "https://llm.example/v1/responses",
                    key: "test-key",
                    model: "test-model",
                    effort: "high",
                    cacertfile: "/etc/ca.pem",
                    timeout_ms: 300_000
                  }
                }} == NpcRegistry.brain("llm", params)

        # 只有 goal 与 tools 是必填；没给 genesis 就不是创世 NPC，groups 缺省 = 全部组。
        assert {Brain.Llm,
                %{
                  goal: "g",
                  tools: %{},
                  groups: nil,
                  skills: %{},
                  spells: %{},
                  genesis: false,
                  endpoint: %{url: "https://llm.example/v1/responses", key: "test-key"}
                } = profile} = NpcRegistry.brain("llm", %{"goal" => "g", "tools" => %{}})

        refute Map.has_key?(profile, :max_requests_per_hour)
      end)
    end

    # design_house 的配置只有会话预算：给了的键覆盖缺省（D2 验收配置 12 轮 / 240 000 token / 每轮输出 4096），
    # 模型接口与大脑同一个 endpoint；配置齐全时技能条目投影给 LLM。
    test "llm: design_house is registered with a session budget; bad budgets are rejected" do
      with_env(@llm_env, fn ->
        params = %{"goal" => "g", "tools" => %{"1" => "镐"}, "skills" => ["design_house", "build"]}

        assert {Brain.Llm, %{skills: %{build: %{}, design_house: %{budget: budget}}} = profile} =
                 NpcRegistry.brain("llm", Map.put(params, "design_budget", %{"rounds" => 3}))

        assert budget == %{rounds: 3, tokens: 240_000, max_output_tokens: 4096}
        assert "design_house" in Enum.map(NpcServer.Abilities.tools(profile), & &1.name)

        assert {Brain.Llm, %{skills: %{design_house: %{budget: %{rounds: 12}}}}} =
                 NpcRegistry.brain("llm", params)

        for bad <- [%{"rounds" => 0}, %{"tokens" => "many"}] do
          assert_raise MatchError, fn ->
            NpcRegistry.brain("llm", Map.put(params, "design_budget", bad))
          end
        end
      end)
    end

    test "patrol: route points and the optional dig" do
      assert {Brain.Patrol, %{route: [{4.0, 10.0}, {8.0, 10.0}], dig: nil}} ==
               NpcRegistry.brain("patrol", @patrol)

      dig = %{"direction" => [1.0, 0.0, 0.0], "tool_id" => 1}

      assert {Brain.Patrol,
              %{route: [{4.0, 10.0}, {8.0, 10.0}], dig: %{direction: {1.0, 0.0, 0.0}, tool_id: 1}}} ==
               NpcRegistry.brain("patrol", %{@patrol | "dig" => dig})
    end

    test "bad params raise (put turns that into a rejection)" do
      settler = %{
        "definition" => @hex,
        "sites" => [],
        "revisit_ticks" => 600,
        "tools" => %{"1" => "镐"}
      }

      with_env(@llm_env, fn ->
        for {brain, params} <- [
              # 定义 id 不是 64 位十六进制：Tree.new 建树时译码 read_catalog 的静态参数就失败。
              {"settler", %{settler | "definition" => "zz"}},
              {"settler", Map.delete(settler, "revisit_ticks")},
              {"settler",
               %{settler | "sites" => [%{"anchor_micro" => [1, 2], "orientation" => 0}]}},
              {"patrol", %{"route" => [[4.0, 10.0]]}},
              {"llm", %{"tools" => %{}}},
              {"llm", %{"goal" => "g", "tools" => %{"pickaxe" => "镐"}}},
              # wilderness 需要调度器端点，没有 JSON 形配置，不经注册表（design_house 已可登记，见上一个用例）；
              # 没有的组名、未授予时请求 genesis 组。
              {"llm", %{"goal" => "g", "tools" => %{}, "skills" => ["wilderness"]}},
              {"llm", %{"goal" => "g", "tools" => %{}, "groups" => ["dance"]}},
              {"llm", %{"goal" => "g", "tools" => %{}, "groups" => ["genesis"]}},
              {"llm", %{"goal" => "g", "tools" => %{}, "genesis" => "yes"}},
              {"dancer", %{}}
            ] do
          assert_raise_any(fn -> NpcRegistry.brain(brain, params) end, {brain, params})
        end
      end)

      # 没有模型接口的运行环境登记不了 llm 大脑。
      with_env(%{@llm_env | "NPC_LLM_URL" => nil}, fn ->
        assert_raise_any(
          fn -> NpcRegistry.brain("llm", %{"goal" => "g", "tools" => %{}}) end,
          :no_url
        )
      end)
    end
  end

  describe "registry" do
    setup do
      MmoTest.Database.start!()
      DataService.Repo.delete_all("npc_specs")
      on_exit(fn -> DataService.Repo.delete_all("npc_specs") end)
      fixture = NpcWorld.start()

      restore_env(:world_server, :movement_routes, %{
        1 => %{scene_ref: fixture.scene, world_ref: fixture.world, scene_epoch: 7}
      })

      # 部署编辑盒（Body 的缺省 bounds 取自它，与玩家 QUIC 连接同一份）。
      restore_env(:voxel_region, :edit_bounds, {{-60, 40, -60}, {60, 120, 60}})

      # 夹具自己的 Claims（未具名）是另一个子进程；Body.start/2 用的是正式缺省名字的这一个。
      start_supervised!(
        Supervisor.child_spec(
          {WorldServer.Session, name: WorldServer.Session},
          id: :registry_claims
        )
      )

      start_supervised!({Registry, keys: :duplicate, name: NpcServer.Names})

      start_supervised!(
        {DynamicSupervisor, name: NpcServer.BodySupervisor, strategy: :one_for_one}
      )

      fixture
    end

    test "put starts the NPC in the real Scene with the row's brain; remove stops it and keeps its identity",
         %{scene: scene} do
      name = "巡逻者#{System.unique_integer([:positive])}"

      assert {:ok, %{cid: cid, pid: pid}} =
               NpcRegistry.put(name, %{
                 scene_id: 1,
                 spawn: {4.0, 66.0, 10.0},
                 brain: "patrol",
                 params: @patrol
               })

      # 独立读口：characters 表里这个名字的 NPC 行就是 cid；Scene 的成员里有它。
      assert %{id: ^cid, kind: "npc"} = DataService.Repo.get_by!(Character, name: name)
      NpcWorld.await(fn -> in_scene?(scene, cid) end)
      # 大脑来自注册表行：走到第二个路点 (8, 10)。
      patrols!(pid)

      assert [%{cid: ^cid, brain: "patrol", params: @patrol, enabled: true, running: true}] =
               rows(name)

      monitor = Process.monitor(pid)
      assert :ok = NpcRegistry.remove(name)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 5_000
      assert [%{cid: ^cid, enabled: false, running: false}] = rows(name)
      assert [] == DynamicSupervisor.which_children(NpcServer.BodySupervisor)
      NpcWorld.await(fn -> not in_scene?(scene, cid) end)
      # 角色行保留：同名还是同一 cid。
      assert {:ok, %{id: ^cid}} = DataService.CharacterStore.ensure_npc(name)
      assert {:error, :not_found} = NpcRegistry.remove("没有这个人#{System.unique_integer()}")
    end

    test "put of a running name stops the old Body first, then starts the new brain" do
      name = "换脑者#{System.unique_integer([:positive])}"
      spec = %{scene_id: 1, spawn: {4.0, 66.0, 10.0}, brain: "patrol", params: @patrol}
      assert {:ok, %{cid: cid, pid: first}} = NpcRegistry.put(name, spec)
      monitor = Process.monitor(first)

      assert {:ok, %{cid: ^cid, pid: second}} =
               NpcRegistry.put(name, %{
                 spec
                 | params: %{@patrol | "route" => [[4.0, 10.0], [4.0, 6.0]]}
               })

      # 旧 Body 是被停掉的（:shutdown），不是被新 claim 顶替（{:shutdown, :replaced}）。
      assert_receive {:DOWN, ^monitor, :process, ^first, :shutdown}, 5_000

      assert [{:undefined, ^second, :worker, _}] =
               DynamicSupervisor.which_children(NpcServer.BodySupervisor)

      patrols!(second, {4.0, 6.0})
      assert [%{params: %{"route" => [[4.0, 10.0], [4.0, 6.0]]}, running: true}] = rows(name)
    end

    test "a node restart: start_all brings every enabled row back with the same cid and brain",
         %{scene: scene} do
      name = "常驻者#{System.unique_integer([:positive])}"
      gone = "已停用#{System.unique_integer([:positive])}"
      spec = %{scene_id: 1, spawn: {4.0, 66.0, 10.0}, brain: "patrol", params: @patrol}
      assert {:ok, %{cid: cid, pid: before}} = NpcRegistry.put(name, spec)
      assert {:ok, _} = NpcRegistry.put(gone, %{spec | spawn: {4.0, 66.0, 14.0}})
      assert :ok = NpcRegistry.remove(gone)

      # 模拟节点重启：NpcSup 的全部子进程停掉，注册表行还在库里。
      for {_, pid, _, _} <- DynamicSupervisor.which_children(NpcServer.BodySupervisor),
          do: :ok = DynamicSupervisor.terminate_child(NpcServer.BodySupervisor, pid)

      NpcWorld.await(fn -> not in_scene?(scene, cid) end)

      assert [{^name, {:ok, %{cid: ^cid, pid: pid}}}] = NpcRegistry.start_all()
      assert pid != before

      assert [{:undefined, ^pid, :worker, _}] =
               DynamicSupervisor.which_children(NpcServer.BodySupervisor)

      NpcWorld.await(fn -> in_scene?(scene, cid) end)
      patrols!(pid)
      assert [%{running: false, enabled: false}] = rows(gone)
    end

    test "bad params are rejected at put: no row, no character, no Body" do
      name = "坏参数#{System.unique_integer([:positive])}"

      with_env(@npc_env, fn ->
      for {brain, params} <- [
            {"settler",
             %{"definition" => "zz", "sites" => [], "revisit_ticks" => 1, "tools" => %{}}},
            {"patrol", %{"route" => [[4.0, 10.0]]}},
            # 元组不是 JSON：参数先按 JSON 规范化，存的和解析的是同一份。
            {"patrol", %{"route" => [{4.0, 10.0}, {8.0, 10.0}]}},
            # 统一形态：坏人格卡、空候选表、重名候选（运行环境里有 Jev 接口与 Hindsight 地址，被拒只因参数）。
            {"npc", %{@npc | "persona" => %{"traits" => %{"brave" => 8}, "personal" => ""}}},
            {"npc", %{@npc | "activities" => []}},
            {"npc", %{@npc | "activities" => List.duplicate(hd(@npc["activities"]), 2)}},
            {"dancer", %{}}
          ] do
        assert {:error, {:invalid_params, message}} =
                 NpcRegistry.put(name, %{
                   scene_id: 1,
                   spawn: {4.0, 66.0, 10.0},
                   brain: brain,
                   params: params
                 })

        assert is_binary(message)
      end

      # 说明里带原因：坏人格卡指出是哪个键。
      assert {:error, {:invalid_params, message}} =
               NpcRegistry.put(name, %{
                 scene_id: 1,
                 spawn: {4.0, 66.0, 10.0},
                 brain: "npc",
                 params: %{@npc | "persona" => %{"traits" => %{"brave" => 8}, "personal" => ""}}
               })

      assert message =~ "persona" and message =~ ~s({:unknown_trait, "brave"})
      end)

      assert [] == rows(name)
      assert nil == DataService.Repo.get_by(Character, name: name)
      assert [] == DynamicSupervisor.which_children(NpcServer.BodySupervisor)
    end

    # 统一形态经正式入口：真实 Body / Scene / World / Runtime / Tree / 技能 / Life / NpcMemory / 两个 HTTP 发送器；
    # 替身只有两个外部服务本身——Jev（每个请求回同一份冻结应答，形状取自官方 HTTP 文档）与 Hindsight（冻结应答，形状取自
    # `npc_hindsight_test` 的 0.10.3 接口样本）。证明真实观察与真实 Hindsight 适配器读回的认识、召回能拼成发问，应答被执行；
    # 不证明真实 Jev 的选择与真实 Hindsight 的内容（那是 :live_jev 用例与服务端实跑）。
    @tag timeout: 120_000
    test "an npc row reads its mind through Life, asks Jev from the real Body and runs the chosen activity" do
      answer = %{"answers" => %{"activity" => %{"type" => "choice", "choice" => "walk_east", "confidence" => 0.4}}}
      test = self()

      jev =
        http_stub(fn :post, "/jev", body ->
          send(test, {:jev_http, body})
          answer
        end) <> "/jev"

      hindsight =
        http_stub(fn
          :put, "/v1/default/banks/npc-life-" <> _cid, _ ->
            %{}

          :patch, "/v1/default/banks/npc-life-" <> rest, _ ->
            true = String.ends_with?(rest, "/config")
            %{}

          :get, "/v1/default/banks/npc-life-" <> rest, _ ->
            cond do
              rest =~ "/mental-models/self?" -> %{"content" => "I keep to myself and save what I can."}
              rest =~ "/mental-models/" -> %{"content" => "Nothing recorded yet."}
              rest =~ "/operations?" -> %{"operations" => [], "total" => 0}
              rest =~ "/llm-requests?" -> %{"items" => [], "total" => 0}
              rest =~ "/stats" -> %{}
            end

          :post, "/v1/default/banks/npc-life-" <> rest, body ->
            true = String.ends_with?(rest, "/memories/recall")
            send(test, {:hindsight_recall, body})
            %{"results" => [%{"id" => "fact-1", "text" => "The east post is quiet in the morning.", "type" => "world"}]}
        end)

      name = "住民#{System.unique_integer([:positive])}"

      params = %{
        @npc
        | "activities" => [
            %{"name" => "stay_here", "criterion" => "Stay where you are.", "place" => [4.0, 10.0], "stay_ticks" => 60},
            %{"name" => "walk_east", "criterion" => "Walk to the east post.", "place" => [8.0, 10.0], "stay_ticks" => 60}
          ]
      }

      with_env(%{@npc_env | "TYPESAFE_API_URL" => jev, "NPC_LIFE_HINDSIGHT_URL" => hindsight}, fn ->
        assert {:ok, %{cid: cid, pid: pid}} =
                 NpcRegistry.put(name, %{scene_id: 1, spawn: {4.0, 66.0, 10.0}, brain: "npc", params: params})

        assert [%{cid: ^cid, brain: "npc", params: ^params, enabled: true, running: true}] = rows(name)

        # 附近没人、没有我的建筑：一次选择只有“未了与感受”一路召回（`Mind.recall_queries/2`），线上的请求体按适配器的契约。
        assert_receive {:hindsight_recall, recall}, 30_000

        assert Map.delete(recall, "query_timestamp") == %{
                 "query" => "What am I looking forward to, worried about, or have promised to do?",
                 "budget" => "mid",
                 "prefer_observations" => true,
                 "max_tokens" => 600
               }

        # 发问来自真实观察与真实读回的心智：人格描述、认识（四份，按建立次序）、召回、位置都在请求里。
        assert_receive {:jev_http, request}, 20_000
        assert request["model"] == "jev-test"
        assert request["state"] =~ "Character: Lin, a builder. Personality: introverted, very thrifty."
        assert request["state"] =~ "\nFeelings and relationships: Nothing notable.\nWhat just happened: Nothing new.\n"

        assert request["state"] =~
                 "What I remember: My own memories and beliefs; they may be out of date and are not current " <>
                   "world facts.\n- Belief (self): I keep to myself and save what I can.\n" <>
                   "- Belief (relationships): Nothing recorded yet.\n- Belief (world): Nothing recorded yet.\n" <>
                   "- Belief (commitments): Nothing recorded yet.\n" <>
                   "- Recalled: The east post is quiet in the morning.\n"

        assert request["state"] =~ "Current situation: Standing at x=4.0, z=10.0"

        # 被选中的是登记在后的 walk_east：走到 (8, 10)。
        travel =
          NpcWorld.await(
            fn -> Enum.find(Body.observe(pid).outcomes, &match?(%{verb: :travel, status: :done}, &1)) end,
            20_000
          )

        {x, _, z} = travel.data.position
        assert abs(x - 8.0) <= 0.5 and abs(z - 10.0) <= 0.5

        # 活动结束后再次发问：带上一项的结局，刚结束的活动也成了 Life 手里的一条经历（真实 Body 的观察里没有别人：nobody came near）。
        assert_receive {:jev_http, %{"state" => again}}, 20_000
        assert again =~ "Recent activities: Oldest first. walk_east: completed."
        # 句首是按游戏时间写的多久以前（具体取整由 npc_mind_test 断言），不是 UTC。
        assert again =~ ~r/What just happened: Oldest first\. (?:Just now|About [\d.]+ (?:hour|hours|day|days) ago), I did "walk_east" \(Walk to the east post\.\)\. Result: completed\. During it: nobody came near\.\n/

        # observe 读得到当前活动、最近的选择，以及最近一次问 Jev 的全文与各路召回的描述。
        assert %{
                 select: %{
                   activities: [%{activity: "walk_east", trigger: "start", confidence: 0.4, recall_ms: recall_ms} | _],
                   asked: %{state: asked, recall_queries: [%{query: query}]}
                 }
               } = Body.observe(pid)

        assert is_integer(recall_ms) and recall_ms >= 0
        assert asked =~ "Character: Lin, a builder."
        assert query == recall["query"]

        assert :ok = NpcRegistry.remove(name)
      end)
    end

    # 走向一个角色（S1-F），全链路同上一用例（替身仍只有 Jev 与 Hindsight 两个 HTTP 服务）：Jev 选中“去找我不信任的人”，
    # 附近没有人、Life 里也没有关系 → 不发 travel，活动以 failed (travel: nobody_distrusted) 结束，下一次发问的
    # “最近做过的事”与“刚发生的事”里都写着它。
    @tag timeout: 120_000
    test "an npc row choosing to face a distrusted person with nobody distrusted nearby reports nobody_distrusted" do
      answer = %{"answers" => %{"activity" => %{"type" => "choice", "choice" => "confront", "confidence" => 0.6}}}
      test = self()

      jev =
        http_stub(fn :post, "/jev", body ->
          send(test, {:jev_http, body})
          answer
        end) <> "/jev"

      hindsight =
        http_stub(fn
          :put, "/v1/default/banks/npc-life-" <> _cid, _ ->
            %{}

          :patch, "/v1/default/banks/npc-life-" <> rest, _ ->
            true = String.ends_with?(rest, "/config")
            %{}

          :get, "/v1/default/banks/npc-life-" <> rest, _ ->
            cond do
              rest =~ "/mental-models/" -> %{"content" => "Nothing recorded yet."}
              rest =~ "/operations?" -> %{"operations" => [], "total" => 0}
              rest =~ "/llm-requests?" -> %{"items" => [], "total" => 0}
              rest =~ "/stats" -> %{}
            end

          :post, "/v1/default/banks/npc-life-" <> rest, _body ->
            true = String.ends_with?(rest, "/memories/recall")
            %{"results" => []}
        end)

      name = "住民#{System.unique_integer([:positive])}"

      params = %{
        @npc
        | "activities" => [
            %{"name" => "confront", "criterion" => "Face the person I distrust.", "person" => "distrusted", "stay_ticks" => 60}
          ]
      }

      with_env(%{@npc_env | "TYPESAFE_API_URL" => jev, "NPC_LIFE_HINDSIGHT_URL" => hindsight}, fn ->
        assert {:ok, %{pid: pid}} =
                 NpcRegistry.put(name, %{scene_id: 1, spawn: {4.0, 66.0, 10.0}, brain: "npc", params: params})

        assert_receive {:jev_http, first}, 30_000
        assert first["state"] =~ "Recent activities: None yet."

        assert_receive {:jev_http, %{"state" => again}}, 20_000
        assert again =~ "Recent activities: Oldest first. confront: failed (travel: nobody_distrusted)."

        # 句首是按游戏时间写的多久以前（具体取整由 npc_mind_test 断言），不是 UTC。
        assert again =~
                 ~r/What just happened: Oldest first\. (?:Just now|About [\d.]+ (?:hour|hours|day|days) ago), I did "confront" \(Face the person I distrust\.\)\. Result: failed \(travel: nobody_distrusted\)\. During it: nobody came near\.\n/

        # 没有发出过 travel：身体没有任何 travel 的终态。
        refute Enum.any?(Body.observe(pid).outcomes, &(&1.verb == :travel))

        assert :ok = NpcRegistry.remove(name)
      end)
    end

    # M2 授予（决策稿 §3）：唯一来源是注册表行。llm 行 genesis: true → Body 受理 genesis_edit 并经 World 写格；
    # 没标的 llm 行 → not_permitted。
    test "an llm row with genesis: true starts a Body that may edit the world; without it, not_permitted",
         %{world: world} do
      with_env(@llm_env, fn ->
        llm = %{"goal" => "整平出生点西边", "tools" => %{}}
        creator = "创世者#{System.unique_integer([:positive])}"
        plain = "住民#{System.unique_integer([:positive])}"

        assert {:ok, %{pid: creator}} =
                 NpcRegistry.put(creator, %{
                   scene_id: 1,
                   spawn: {4.0, 66.0, 10.0},
                   brain: "llm",
                   params: Map.put(llm, "genesis", true)
                 })

        assert {:ok, %{pid: plain}} =
                 NpcRegistry.put(plain, %{
                   scene_id: 1,
                   spawn: {4.0, 66.0, 14.0},
                   brain: "llm",
                   params: llm
                 })

        for body <- [creator, plain],
            do: NpcWorld.await(fn -> Body.observe(body).position end, 15_000)

        Body.command(creator, %{id: :g, verb: :genesis_edit, edits: [{{6, 64, 12}, 11}]})
        assert %{status: :done, data: %{seq: _}} = outcome(creator, :g)
        assert %{material: 11, placed_by: nil} = NpcWorld.cells(world, [{6, 64, 12}])[{6, 64, 12}]

        Body.command(plain, %{id: :g, verb: :genesis_edit, edits: [{{7, 64, 12}, 11}]})
        assert %{status: :rejected, reason: :not_permitted} = outcome(plain, :g)
        assert %{material: 0} = NpcWorld.cells(world, [{7, 64, 12}])[{7, 64, 12}]
      end)
    end
  end

  defp rows(name), do: Enum.filter(NpcRegistry.list(), &(&1.name == name))

  defp in_scene?(scene, cid),
    do: Enum.any?(Scene.observe(scene).characters, &(&1.entity_id == cid))

  defp outcome(body, id),
    do: NpcWorld.await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == id)) end)

  # 巡逻大脑的可观察行为：某次 move_to 完成在给定路点 0.5 米内（Patrol 的到达容差）。
  defp patrols!(body, {px, pz} \\ {8.0, 10.0}) do
    NpcWorld.await(
      fn ->
        Enum.find(Body.observe(body).outcomes, fn
          %{verb: :move_to, status: :done, data: %{position: {x, _, z}}} ->
            abs(x - px) <= 0.5 and abs(z - pz) <= 0.5

          _ ->
            false
        end)
      end,
      20_000
    )
  end

  # 只测试：本机 HTTP 监听，逐个连接读完一个 POST、把请求体（JSON）交给测试进程、回同一份应答后关闭连接。
  # 监听与在途连接随本进程退出关闭；只用回环 TCP。
  # 只测试：本机 HTTP 替身。每个请求交给 `handler.(方法, 路径, JSON 体 | nil)`，它返回的 map 以 200 JSON 回给调用方。
  # 返回服务根地址。
  defp http_stub(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    server = spawn_link(fn -> http_accept(listen, handler) end)
    :ok = :gen_tcp.controlling_process(listen, server)
    "http://127.0.0.1:#{port}"
  end

  defp http_accept(listen, handler) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, {:http_request, method, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0)
    length = http_headers(socket, 0)
    :ok = :inet.setopts(socket, packet: :raw)

    body =
      if length > 0 do
        {:ok, bytes} = :gen_tcp.recv(socket, length)
        Jason.decode!(bytes)
      end

    answer = Jason.encode!(handler.(%{"PATCH" => :patch, GET: :get, PUT: :put, POST: :post}[method], path, body))

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\n",
        "content-length: #{byte_size(answer)}\r\n\r\n",
        answer
      ])

    :ok = :gen_tcp.close(socket)
    http_accept(listen, handler)
  end

  defp http_headers(socket, length) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, :"Content-Length", _, value}} -> http_headers(socket, String.to_integer(value))
      {:ok, :http_eoh} -> length
      {:ok, _} -> http_headers(socket, length)
    end
  end

  defp assert_raise_any(fun, label) do
    try do
      fun.()
      flunk("expected a raise: #{inspect(label)}")
    rescue
      error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
      _ -> :ok
    end
  end

  # 只测试：临时改运行环境变量（nil = 删除），结束后还原。
  defp with_env(env, fun) do
    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)

    put = fn values ->
      for {k, v} <- values, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end

    put.(env)

    try do
      fun.()
    after
      put.(previous)
    end
  end

  defp restore_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
