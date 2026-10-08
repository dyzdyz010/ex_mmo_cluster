Code.require_file("../support/npc_world.exs", __DIR__)

defmodule GateServer.NpcGatherTest do
  @moduledoc """
  只测试：采石技能 `GateServer.Npc.Skills.Gather`（角色能力函数库设计稿 T3.3、T3.4，§10 S6）。
  T3.3 是候选纯函数（手算小世界）；T3.4 在真实 World / Scene / Player / Body 上（`GateServer.NpcWorld` 夹具），
  采石堆、邻居放的格与作者 prefab 宏格都经作者 / 正常玩法入口一次写入，余额与世界格只经 World 的公共只读入口观察。
  期望值按夹具目录手算：一格石料 cost 512 单位、4 击挖掉。
  """
  use ExUnit.Case, async: false
  alias GateServer.Npc.{Abilities, Body}
  alias GateServer.Npc.Skills.Gather
  alias GateServer.NpcWorld
  alias VoxelRegion.{Prefab, World}

  @stone 11
  # VoxelRegion.Phase.liquid?/1：21 = 水。
  @water 21
  @npc 9101
  @neighbour 4242

  defp row(cell, material, opts \\ []),
    do: %{
      cell: cell,
      material: material,
      refined: Keyword.get(opts, :refined, false),
      slots: [],
      placed_by: Keyword.get(opts, :placed_by)
    }

  test "candidates keep only unplaced natural cells of the material inside the box, top layer first, nearest first" do
    rows = [
      row([2, 64, 0], @stone),
      row([0, 64, 0], @stone),
      row([1, 65, 3], @stone),
      row([3, 65, 0], @stone),
      # 排除：别人放的格、自己放的格、液体、细化格、空气、材质不符、盒外。
      row([1, 64, 0], @stone, placed_by: @neighbour),
      row([1, 64, 1], @stone, placed_by: @npc),
      row([2, 64, 1], @water),
      row([3, 64, 1], @stone, refined: true),
      row([0, 65, 0], 0),
      row([0, 64, 1], 19),
      row([5, 64, 0], @stone)
    ]

    box = %{box: {{0, 64, 0}, {3, 65, 3}}, material: @stone}

    # 站位 (1.5, -2.5)：上层 (1,65,3) 水平距离² = 0+36 = 36、(3,65,0) = 4+9 = 13；下层 (0,64,0) = 1+9 = 10、(2,64,0) = 1+9 = 10（同距按 x）。
    assert [{3, 65, 0}, {1, 65, 3}, {0, 64, 0}, {2, 64, 0}] ==
             Gather.candidates(rows, box, {1.5, -2.5})

    # 液体材料、空气不是采石对象。
    assert [] == Gather.candidates(rows, %{box | material: @water}, {0.0, 0.0})
    assert [] == Gather.candidates(rows, %{box | material: 0}, {0.0, 0.0})
  end

  # 声明范围的替身：测试进程扮演 Body（按步回 Outcome）与 World（只回工具定义），被测的是 gather 自己的判定。
  # 一击之后再探测命中变了，但这一格仍是石头（眼点挪开或别的东西挡进射线）：不能算挖掉。改前 gather 把“命中变了”
  # 当作挖掉、立即去核对余额（2026-10-08 Demo 实跑首轮：hp 56 的半截格被算作已挖，最终 exhausted）。
  test "a changed probe hit is not a mined cell: gather looks at the cell and keeps it for another stand" do
    world =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, {:tool_definition, 1}} ->
            GenServer.reply(from, {:ok, %{"interval_seconds" => 0.0}})
        end
      end)

    me = self()
    context = %{body: me, call_id: 7, world: world, observation: %{self: %{position: {0.5, 65.0, -2.5}}}}
    args = %{"box" => [[0, 64, 0], [0, 64, 0]], "material" => @stone, "units" => 512, "tool_id" => 1}
    task = Task.async(fn -> Gather.run(context, args, %{}) end)

    step = fn verb, data ->
      assert_receive {:"$gen_cast", {:command, %{id: {:skill, 7, id}, verb: ^verb} = command}}, 2_000
      send(task.pid, {:outcome, %{id: id, verb: verb, status: :done, reason: nil, data: data}})
      command
    end

    stone = %{granularity: 0, micro: {0, 512, 0}, incarnation: 0, owner: {0, 0}, material: @stone}
    step.(:query_balances, %{balances: [%{material: @stone, balance: 0, cost: 512, seq: 0}]})
    step.(:move_to, %{position: {0.5, 64.9, -1.5}, within_tolerance: true, settled: true})
    step.(:look, %{probe_occupancy: [row([0, 64, 0], @stone)]})
    step.(:probe_toward, stone)
    step.(:use_tool, %{seq: 1})
    # 再探测命中了相邻格：身份变了。
    step.(:probe_toward, %{stone | micro: {8, 512, 0}})
    # 这一格的权威内容仍是石头 → 不算挖掉。
    assert %{min: {0, 64, 0}, max: {0, 64, 0}} = step.(:look, %{probe_occupancy: [row([0, 64, 0], @stone)]})
    # 留给下一个站位：去下一个站位，而不是核对余额。
    assert %{verb: :move_to} = step.(:move_to, %{position: {2.5, 64.9, 0.5}, within_tolerance: true, settled: true})
    Task.shutdown(task, :brutal_kill)
  end

  test "the gather tool schema is strict and lists the belt; every argument is required" do
    [tool] = Abilities.tools(%{groups: [:skill], tools: %{3 => "镐", 1 => "铲"}, skills: %{gather: %{}}})

    assert %{
             name: "gather",
             strict: true,
             parameters: %{
               additionalProperties: false,
               required: ["box", "material", "units", "tool_id"],
               properties: %{tool_id: %{type: "integer", enum: [1, 3]}, box: box}
             }
           } = tool

    assert %{type: "array", minItems: 2, maxItems: 2, items: %{type: "array", minItems: 3, maxItems: 3}} = box
  end

  defp gather(body, id, args) do
    Body.command(body, %{id: id, verb: :skill, skill: :gather, args: args})

    NpcWorld.await(
      fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == id)) end,
      120_000
    )
  end

  # 采石盒 x 20..23、y 64..65、z 6：作者写入四格石料 (21|22, 64|65, 6)；(20,64,6) 是邻居（另一角色）花材料放下的格；
  # (23,64,6) 是作者 prefab 的宏格（只记 macro_owners，没有放置溯源）；(24,64,6) 在盒外。
  @tag timeout: 300_000
  test "gather mines only the author's natural cells: done reports the exact gain, then exhausted leaves the guarded cells" do
    macro = Prefab.encode(%{cells: [], macro_cells: [{{0, 0, 0}, @stone}], children: [], attachments: []})
    fixture = NpcWorld.start(prefab_access: true, prefabs: [macro])
    world = fixture.world
    pile = for x <- 21..22, y <- 64..65, do: {x, y, 6}
    {:ok, _} = World.apply_edits(world, Enum.map(pile ++ [{24, 64, 6}], &{&1, @stone}))
    {:ok, _} = World.place_prefab(world, :crypto.hash(:sha256, macro), {184, 512, 48}, 0)

    # 邻居经正常放置入口花自己的材料（一次性供给记账）；角色替身不是被测主体。
    {:ok, _} = World.material_supply(world, @neighbour, "gather-neighbour", %{@stone => 512})
    neighbour = NpcWorld.actor(@neighbour, {18.5, 65.5, 6.5})

    assert {:ok, _} =
             World.production_intent(world, neighbour, %{
               request_id: 1,
               client_intent_seq: 1,
               logical_scene_id: 1,
               action: 1,
               coord: {20, 64, 6},
               tool_id: 1,
               material: @stone
             })

    guarded = [{20, 64, 6}, {23, 64, 6}, {24, 64, 6}]

    assert %{{20, 64, 6} => %{material: @stone, placed_by: @neighbour}, {23, 64, 6} => %{material: @stone, placed_by: nil}} =
             NpcWorld.cells(world, guarded)

    profile = %{steps: [], tools: %{1 => "镐"}, skills: %{gather: %{}}, memory: NpcWorld.Memory}
    %{body: body} = NpcWorld.body(fixture, {GateServer.Npc.Brain.Routine, profile})
    NpcWorld.await(fn -> Body.observe(body).position end)
    box = [[20, 64, 6], [23, 65, 6]]

    # 两格的量：从最近的西侧站位先挖上层两格（层自上而下），核对余额后结束。
    assert %{verb: :gather, status: :done, data: %{mined: 2, gained: 1024, skipped: 0}} =
             gather(body, :two, %{"box" => box, "material" => @stone, "units" => 1024, "tool_id" => 1})

    assert 1024 == NpcWorld.balance(world, @npc)

    assert %{{21, 65, 6} => %{material: 0}, {22, 65, 6} => %{material: 0}, {21, 64, 6} => %{material: @stone}, {22, 64, 6} => %{material: @stone}} =
             NpcWorld.cells(world, pile)

    # 要四格，盒里只剩两格天然石料：西侧被邻居的格挡住，换到南侧站位挖完；prefab 宏格探测出 owner 不是 {0,0}，不挖。
    assert %{verb: :gather, status: :rejected, reason: :exhausted} =
             gather(body, :more, %{"box" => box, "material" => @stone, "units" => 2048, "tool_id" => 1})

    assert 2048 == NpcWorld.balance(world, @npc)
    assert Enum.all?(Map.values(NpcWorld.cells(world, pile)), &(&1.material == 0))

    assert %{
             {20, 64, 6} => %{material: @stone, placed_by: @neighbour},
             {23, 64, 6} => %{material: @stone},
             {24, 64, 6} => %{material: @stone}
           } = NpcWorld.cells(world, guarded)

    # 参数不成立：目录里没有的工具、不是生产材料的材料、非正 units，不动手。
    for {id, args} <- [
          {:no_tool, %{"box" => box, "material" => @stone, "units" => 512, "tool_id" => 9}},
          {:not_production, %{"box" => box, "material" => 19, "units" => 512, "tool_id" => 1}},
          {:zero, %{"box" => box, "material" => @stone, "units" => 0, "tool_id" => 1}}
        ],
        do:
          assert(
            %{status: :rejected, reason: :invalid_skill_arguments} = gather(body, id, args),
            inspect(id)
          )

    assert 2048 == NpcWorld.balance(world, @npc)
  end

  # 够不够得着只由权威射线裁决：Damage.trace 量的是射线首次进入实占微格的距离（入射面），不是到格心的距离。
  # 盒 x 20..32、z 6..18（13 × 13，四个站位都离角上那格较远），盒里只有作者写入的一格 (20,64,6)。出生在南侧站位
  # (26.5, 4.5) 上（出生只沿 y 找落脚点，x / z 不变），站立时眼高 65.5：到格心 (20.5, 64.5, 6.5) 是 √(6² + 1² + 2²) ≈ 6.40 米，
  # 超过镐的射程 6 米；射线在 x = 21 的面进入这一格（t = 5.5 / 6，该点 y ≈ 64.58、z ≈ 6.33 都在格内），入射距离
  # ≈ 0.917 × 6.40 ≈ 5.87 米，在射程内。另三个站位到格心也都 ≥ 6.40 米。
  @tag timeout: 300_000
  test "a cell whose entry face is in range is mined even though its centre is beyond the tool range" do
    fixture = NpcWorld.start()
    world = fixture.world
    {:ok, _} = World.apply_edits(world, [{{20, 64, 6}, @stone}])

    profile = %{steps: [], tools: %{1 => "镐"}, skills: %{gather: %{}}, memory: NpcWorld.Memory}

    %{body: body} =
      NpcWorld.body(fixture, {GateServer.Npc.Brain.Routine, profile}, spawn: {26.5, 66.0, 4.5})

    # 前提：落地站稳（胶囊中心 = 地面 64 + 半高 0.9，眼高 = 中心 + 0.6 = 65.5），x / z 就是出生点。
    assert {26.5, _, 4.5} =
             NpcWorld.await(fn ->
               with {_, y, _} = position <- Body.observe(body).position,
                    true <- abs(y - 64.9) < 0.05,
                    do: position
             end)

    assert %{verb: :gather, status: :done, data: %{mined: 1, gained: 512, skipped: 0}} =
             gather(body, :edge, %{
               "box" => [[20, 64, 6], [32, 64, 18]],
               "material" => @stone,
               "units" => 512,
               "tool_id" => 1
             })

    assert 512 == NpcWorld.balance(world, @npc)
    assert %{{20, 64, 6} => %{material: 0}} = NpcWorld.cells(world, [{20, 64, 6}])
  end
end
