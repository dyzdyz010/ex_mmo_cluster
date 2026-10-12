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

      for {brain, params} <- [
            {"settler",
             %{"definition" => "zz", "sites" => [], "revisit_ticks" => 1, "tools" => %{}}},
            {"patrol", %{"route" => [[4.0, 10.0]]}},
            # 元组不是 JSON：参数先按 JSON 规范化，存的和解析的是同一份。
            {"patrol", %{"route" => [{4.0, 10.0}, {8.0, 10.0}]}},
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

      assert [] == rows(name)
      assert nil == DataService.Repo.get_by(Character, name: name)
      assert [] == DynamicSupervisor.which_children(NpcServer.BodySupervisor)
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
