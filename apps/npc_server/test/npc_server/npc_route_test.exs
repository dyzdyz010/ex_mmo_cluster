Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcRouteTest do
  @moduledoc """
  只测试：NPC 走不通时的三件产品能力（决策稿 docs/10-active/cross-cutting/2026-11-24-npc-route-and-teleport-decision.md
  §5.2、§5.4、§5.5，§6 的 2.1 / 2.2 行）——路线查询 `find_route`（`NpcServer.Route`）、原子 `dig_cell`
  （`NpcServer.Skills.DigCell`）、原子 `teleport_to_spawn`（Body → `Player.teleport_to_spawn/4`）。

  - 2.1 `Route.dig_cost/2`：手算的目录行（1 / 3 / 4 / 5 击、伤害为 0、倍率 0、最长前缀倍率、非伤害类工具）。
  - 2.2 在真实 World / Scene / Player / Body 上（`NpcServer.NpcWorld` 夹具：y ≤ 63 实心石料，镐每击 28、间隔 0.5 s、射程 6 m；
    移动 profile 速度 8 m/s → 走一步 0.125 s，台阶 1 格、身高 2 格）。地形、保护区、余额都只经作者入口
    （`World.apply_edits/2`、`World.author_regions/2`、`World.material_supply/4`）与邻居的正常放置入口一次写入；
    原子调用都经 LLM / harness 同一译码入口 `Abilities.command/4` 交给 Body。期望值手算（见各处注释），不复制产品算法。
  - Body 的传送：先停下再读条（Player 的 10 s 读条是真实计时，这一例约 12 s），完成时 Brain 已看到落点的观察；冷却拒绝带游戏钟时刻。
    Player 侧的读条、打断、死亡与流送落点由 scene_server `teleport_to_spawn_test` 覆盖。
  """
  use ExUnit.Case, async: false
  alias NpcServer.{Abilities, Body, NpcWorld, Route}
  alias VoxelRegion.World

  @stone 11
  @granite 12
  @npc 9101
  @neighbour 4242
  @profile %{steps: [], tools: %{1 => "镐"}, skills: %{dig_cell: %{}}, memory: NpcWorld.Memory}

  describe "Route.dig_cost/2（2.1 手算）" do
    @pick %{"action" => "damage", "power" => 30.0, "interval_seconds" => 0.5}
    @damage [%{"action" => "damage", "multiplier" => 1.0}]

    defp material(hp, defense, responses \\ @damage),
      do: %{"max_hp_per_macro" => hp, "defense" => defense, "responses" => responses}

    test "次数 = ⌈满血 / 每击伤害⌉，秒数 = 次数 × 间隔；伤害为 0 不敲" do
      # 每击 = (30 − 2) × 1 = 28。
      assert {:ok, 1, 0.5} = Route.dig_cost(material(28.0, 2.0), @pick)
      assert {:ok, 3, 1.5} = Route.dig_cost(material(84.0, 2.0), @pick)
      # 夹具石料：100 / 28 = 3.57… → 4 击。
      assert {:ok, 4, 2.0} = Route.dig_cost(material(100.0, 2.0), @pick)
      assert {:ok, 5, 2.5} = Route.dig_cost(material(140.0, 2.0), @pick)
      # 防御 ≥ 威力、倍率 0（锚心石）：每击 0 → World 回 ineffective_tool。
      assert :ineffective = Route.dig_cost(material(100.0, 30.0), @pick)

      assert :ineffective =
               Route.dig_cost(
                 material(100.0, 2.0, [%{"action" => "damage", "multiplier" => 0.0}]),
                 @pick
               )

      # 按动作名最长前缀取倍率：damage.blade 取 ×2 → 每击 56，100 / 56 → 2 击。
      blade = %{@pick | "action" => "damage.blade"}

      both = [
        %{"action" => "damage", "multiplier" => 1.0},
        %{"action" => "damage.blade", "multiplier" => 2.0}
      ]

      assert {:ok, 2, 1.0} = Route.dig_cost(material(100.0, 2.0, both), blade)
      # 不是伤害类动作的工具敲不掉格。
      assert :ineffective = Route.dig_cost(material(28.0, 2.0), %{@pick | "action" => "heat"})
    end
  end

  defp await_outcome(body, id, timeout \\ 120_000),
    do: NpcWorld.await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == id)) end, timeout)

  # 一次原子调用（`Route` 回答里 calls 的一项，或手写的同形调用）：实参按 JSON 走一遍，经 `Abilities.command/4` 交给 Body。
  defp perform(body, id, %{atom: atom, args: args}) do
    json = args |> Jason.encode!() |> Jason.decode!()
    Body.command(body, Abilities.command(atom, json, id, @profile))
    await_outcome(body, id)
  end

  defp route(body, id, {x0, z0, x1, z1}) do
    assert %{status: :done, data: answer} =
             perform(body, id, %{
               atom: "find_route",
               args: %{x0: x0, z0: z0, x1: x1, z1: z1, tool_id: 1}
             })

    answer
  end

  defp settled_at(body, y) do
    NpcWorld.await(fn ->
      with {_, py, _} = position <- Body.observe(body).position,
           true <- abs(py - y) < 0.05,
           do: position
    end)
  end

  # 地形：出生在 (4, ·, 10) 的柱上（地面 63、脚 64）；四周一圈 x 3..5、z 9..11 挖成两格深的沟（y 62..63 写成空气），
  # 沟底脚在 62，爬出要上两格（台阶只有 1 格）。区域 = 东边地面 x 8..9、z 10（两列，目标脚 64）。
  # 手算三类（走一步 = 1；敲一格石料 4 击 × 0.5 s = 2 s = 16 步；放一格 = 一个间隔 0.5 s = 4 步）：
  # - 只走：跳进沟里出不来 → no_path。
  # - 允许敲：(4,64,10) 落到 (5,62,10)〔1〕→ 上一级到 (6,63,10)，敲掉 (6,63,10)〔1 + 16〕→ (7,64,10)〔1〕→ (8,64,10)〔1〕，
  #   共 20 步 = 2.5 s；调用 = move_to 沟底站位、dig_cell、move_to 终点。
  # - 允许敲和放：在 (5,63,10) 放一格当地面平走过沟〔1 + 4〕→ (6,64,10)、(7,64,10)、(8,64,10)〔各 1〕，共 8 步 = 1.0 s；
  #   放在起点就能做，调用 = place、move_to 终点。余额没有石料时这一类 no_material。
  @tag timeout: 300_000
  test "find_route 列三类路线（真实快照、目录、余额、保护区）；照 calls 做能走出去；dig_cell 挖掉入账、保护区拒绝" do
    fixture = NpcWorld.start(material_rows: %{@granite => %{defense: 30.0}})
    world = fixture.world
    trench = for x <- 3..5, z <- 9..11, {x, z} != {4, 10}, y <- 62..63, do: {{x, y, z}, 0}
    {:ok, _} = World.apply_edits(world, trench)

    %{body: body} =
      NpcWorld.body(fixture, {NpcServer.Brain.Routine, @profile}, spawn: {4.5, 66.0, 10.5})

    assert {4.5, _, 10.5} = settled_at(body, 64.9)

    move_to = fn x, z, y -> %{atom: "move_to", args: %{x: x, z: z, y: y}} end

    dig_route = %{
      kind: :dig,
      calls: [
        move_to.(5.5, 10.5, 62),
        %{atom: "dig_cell", args: %{x: 6, y: 63, z: 10, tool_id: 1}},
        move_to.(8.5, 10.5, 64)
      ],
      moves: 4,
      estimated_seconds: 2.5,
      dig: %{cells: 1, estimated_hits: 4, estimated_seconds: 2.0, by_material: %{@stone => 1}},
      place: nil,
      end: [8, 64, 10]
    }

    # 余额里没有可放的料。
    first = route(body, :first, {8, 10, 9, 10})
    assert %{start: [4, 64, 10], region: [8, 10, 9, 10], tool_id: 1, goals: 2} = first
    assert first.step_seconds == 0.125
    assert first.routes == [dig_route]

    assert first.omitted == [
             %{kind: :walk, reason: :no_path},
             %{kind: :dig_place, reason: :no_material}
           ]

    assert first.undiggable == %{protected: 0, ineffective: 0, placed_by_other: 0, liquid: 0}

    # 供一格石料（每格 512 单位）：第三类列出来；同一世界再问一次，回答逐字相同（路线槽与表思考查询的是同一个函数）。
    {:ok, _} = World.material_supply(world, @npc, "route-stone", %{@stone => 512})
    second = route(body, :second, {8, 10, 9, 10})
    assert second == route(body, :again, {8, 10, 9, 10})
    assert second.omitted == [%{kind: :walk, reason: :no_path}]

    assert second.routes == [
             dig_route,
             %{
               kind: :dig_place,
               calls: [
                 %{atom: "place", args: %{x: 5, y: 63, z: 10, material: @stone, tool_id: 1}},
                 move_to.(8.5, 10.5, 64)
               ],
               moves: 4,
               estimated_seconds: 1.0,
               dig: %{cells: 0, estimated_hits: 0, estimated_seconds: 0.0, by_material: %{}},
               place: %{cells: 1, material: @stone, units: 512, balance: 512, enough: true},
               end: [8, 64, 10]
             }
           ]

    # 照“允许敲”的 calls 逐步做：落进沟里、敲掉一格（4 击，石料进余额）、走上东边地面。
    for {call, n} <- Enum.with_index(dig_route.calls),
        do: assert(%{status: :done} = perform(body, {:step, n}, call), inspect(call))

    assert %{{6, 63, 10} => %{material: 0}} = NpcWorld.cells(world, [{6, 63, 10}])
    assert 1024 == NpcWorld.balance(world, @npc)
    # move_to 到 0.5 m 容差内：脚所在格是终点 (8, 64, 10)。
    assert {8, 64, 10} = Body.foot(settled_at(body, 64.9), 0.9)

    # 敲不了的格按原因计数（规划盒 x 1..14、z 4..16、y 58..70，地面实心 y 58..63 每列 6 格）：
    # 保留区 x = 9 的整列 → 13 列 × 6 = 78；两格花岗岩（防御 30，镐每击 0）；一格邻居花自己的料放下的石头。
    {:ok, _} = World.author_regions(world, [%{holder: :reserved, min: {9, -20}, max: {9, 40}}])
    {:ok, _} = World.apply_edits(world, [{{11, 64, 10}, @granite}, {{11, 65, 10}, @granite}])
    {:ok, _} = World.material_supply(world, @neighbour, "route-neighbour", %{@stone => 512})

    assert {:ok, _} =
             World.production_intent(world, NpcWorld.actor(@neighbour, {11.5, 65.5, 13.5}), %{
               request_id: 1,
               client_intent_seq: 1,
               logical_scene_id: 1,
               action: 1,
               coord: {11, 64, 12},
               tool_id: 1,
               material: @stone
             })

    # 区域就在西边一格：只走就到；另两类最省也是同一条，不重复列。
    third = route(body, :third, {7, 10, 7, 10})
    assert [%{kind: :walk, calls: [%{atom: "move_to"}], moves: 1}] = third.routes

    assert third.omitted == [
             %{kind: :dig, reason: :same_as_walk},
             %{kind: :dig_place, reason: :same_as_walk}
           ]

    assert third.undiggable == %{protected: 78, ineffective: 2, placed_by_other: 1, liquid: 0}

    # dig_cell 对保留区里的格：探测命中，权威以 protected_region 拒绝，世界与余额不变。
    assert %{verb: :dig_cell, status: :rejected, reason: :protected_region} =
             perform(body, :protected, %{
               atom: "dig_cell",
               args: %{x: 9, y: 63, z: 10, tool_id: 1}
             })

    assert %{{9, 63, 10} => %{material: @stone}} = NpcWorld.cells(world, [{9, 63, 10}])
    assert 1024 == NpcWorld.balance(world, @npc)

    # 范围护栏（不访问 World）：每边超过 32 列、离自己超过 32 m。
    assert %{status: :rejected, reason: :region_too_large} =
             perform(body, :big, %{
               atom: "find_route",
               args: %{x0: 0, z0: 0, x1: 32, z1: 0, tool_id: 1}
             })

    assert %{status: :rejected, reason: :too_far} =
             perform(body, :far, %{
               atom: "find_route",
               args: %{x0: 60, z0: 10, x1: 61, z1: 10, tool_id: 1}
             })
  end

  # 只测试：把每个 Outcome 连同 Brain 此刻看到的最新位置转给测试进程；自己不发命令。
  defmodule Relay do
    @behaviour NpcServer.Brain
    def init(%{owner: owner}), do: %{owner: owner, position: nil}

    def handle_event({:observation, %{self: %{position: position}}}, state),
      do: {[], %{state | position: position}}

    def handle_event({:outcome, outcome}, state) do
      send(state.owner, {:outcome, outcome, state.position})
      {[], state}
    end

    def handle_event(_event, state), do: {[], state}
  end

  # 出生 (4.5, ·, 10.5)，平地。先向东走，走开 3 米以上时发传送：在途的 move_to 被顶替、身体先停稳，再读条 10 s 回到出生柱。
  # 完成那一刻 Brain 已看到落点（位置缓存已更新），紧接着再传送回冷却（游戏钟 1 小时，现实 150 s 内）。
  @tag timeout: 120_000
  test "teleport_to_spawn：先停下再读条，落点生效后才报完成（Brain 已看到落点）；冷却中拒绝并给游戏钟时刻" do
    fixture = NpcWorld.start()

    %{body: body} =
      NpcWorld.body(fixture, {Relay, %{owner: self()}}, spawn: {4.5, 66.0, 10.5})

    {sx, sy, sz} = settled_at(body, 64.9)
    profile = %{tools: %{1 => "镐"}}

    command = fn name, args, id ->
      Body.command(body, Abilities.command(name, args, id, profile))
    end

    command.("move_to", %{"x" => 30.5, "z" => 10.5, "y" => nil}, :walk)
    NpcWorld.await(fn -> match?({x, _, _} when x > 7.5, Body.observe(body).position) end)
    command.("teleport_to_spawn", %{}, :home)

    assert_receive {:outcome, %{id: :walk, status: :superseded}, _}, 2_000

    assert_receive {:outcome,
                    %{
                      id: :home,
                      verb: :teleport_to_spawn,
                      status: :done,
                      data: %{from: {fx, _, _}, to: {tx, ty, tz}}
                    }, seen},
                   20_000

    assert fx > 7.5
    assert {tx, tz} == {sx, sz}
    assert_in_delta ty, sy, 0.05
    # Brain 收到完成时，它看到的最新观察已是落点。
    {px, py, pz} = seen
    assert_in_delta px, tx, 0.05
    assert_in_delta py, ty, 0.05
    assert_in_delta pz, tz, 0.05

    command.("teleport_to_spawn", %{}, :again)

    assert_receive {:outcome,
                    %{
                      id: :again,
                      status: :rejected,
                      reason: :teleport_cooldown,
                      data: %{
                        ready_at: %{day: _, minute_of_day: minute, weekday: _},
                        wait_game_minutes: wait
                      }
                    }, _},
                   5_000

    assert wait in 59..60
    assert minute in 0..1439
  end
end
