Code.require_file("../support/npc_world.exs", __DIR__)

defmodule GateServer.NpcSettlerTest do
  @moduledoc """
  只测试：建设者 Settler 树（`GateServer.Npc.Trees.settler/1` 跑在 `Brain.Tree` 上，角色能力函数库设计稿 T3.2、T3.5 与
  I3 多轮浸泡 (a)）。纯函数部分手排 Outcome 序列、逐个事件断言手写的命令字面量；集成部分在真实 World / Scene /
  Player / Body 上（`GateServer.NpcWorld` 夹具），作者采石堆、余额供给、定义发布都经作者 / 正常入口一次写入并记账，
  期望值按夹具目录手算（一格石料 cost 512、4 击挖掉；两格高的石柱定义材料单 1024）。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias GateServer.Npc.Brain.Tree
  alias GateServer.Npc.Trees
  alias GateServer.NpcWorld
  alias VoxelRegion.{Prefab, World}

  @hex String.duplicate("AB", 32)
  @id :binary.copy(<<0xAB>>, 32)
  @a %{anchor_micro: [64, 512, 112], orientation: 0, stand: [8.5, 11.5]}
  @b %{anchor_micro: [96, 512, 112], orientation: 5, stand: [12.5, 11.5]}
  @quarry %{11 => %{box: [[10, 64, 4], [13, 64, 6]], tool_id: 1}}

  defp settler(extra \\ %{}),
    do:
      Tree.init(
        Map.merge(
          %{
            tree: &Trees.settler/1,
            definition: @hex,
            sites: [@a, @b],
            quarries: @quarry,
            revisit_ticks: 600,
            tools: %{1 => "镐"},
            skills: %{build: %{}, gather: %{}}
          },
          extra
        )
      )

  defp obs(tick), do: {:observation, %{self: %{entity_id: 7, tick: tick}}}

  defp done(id, verb, data \\ %{}),
    do: {:outcome, %{id: id, verb: verb, status: :done, reason: nil, data: data}}

  defp rejected(id, verb, reason),
    do: {:outcome, %{id: id, verb: verb, status: :rejected, reason: reason, data: nil}}

  defp read(id), do: %{id: id, verb: :read_catalog, what: :prefab, definition: @id}

  defp walk(id, %{stand: [x, z]}),
    do: %{id: id, verb: :move_to, position: {x, z}, tolerance: 0.5, y: nil}

  defp build(id, site),
    do: %{
      id: id,
      verb: :skill,
      skill: :build,
      args: %{
        "definition" => @hex,
        "anchor_micro" => site.anchor_micro,
        "orientation" => site.orientation
      }
    }

  defp bill(materials), do: %{definition_id: @id, materials: materials, size_m: [1.0, 2.0, 1.0]}

  defp balances(pairs),
    do: %{balances: for({m, b} <- pairs, do: %{material: m, balance: b, cost: 512, seq: 9})}

  defp script(state, steps) do
    Enum.reduce(steps, state, fn {event, expected}, state ->
      {commands, state} = Tree.handle_event(event, state)
      assert commands == expected, "after #{inspect(event)}"
      state
    end)
  end

  defp info(fun) do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)
    capture_log(fun)
  end

  defp idle(log), do: Regex.scan(~r/npc_settler_idle [^\n]*/, log) |> List.flatten()

  # —— T3.2 纯函数 ——

  test "a shortage queries balances, gathers the hand-computed deficit once, returns to the stand and retries build once" do
    log =
      info(fn ->
        settler()
        |> script([
          {obs(0), [read(1)]},
          {done(1, :read_catalog, bill(%{11 => 1024, 19 => 512})), [walk(2, @a)]},
          {done(2, :move_to, %{position: {8.5, 64.9, 11.5}, within_tolerance: true}), [build(3, @a)]},
          {rejected(3, :build, :insufficient_material), [%{id: 4, verb: :query_balances}]},
          # 11 缺 1024 − 300 = 724 且有采石盒；19 缺 512 但没有采石盒。
          {done(4, :query_balances, balances([{11, 300}, {19, 0}])),
           [
             %{
               id: 5,
               verb: :skill,
               skill: :gather,
               args: %{
                 "box" => [[10, 64, 4], [13, 64, 6]],
                 "material" => 11,
                 "units" => 724,
                 "tool_id" => 1
               }
             }
           ]},
          {done(5, :gather, %{mined: 2, gained: 1024, skipped: 0}), [walk(6, @a)]},
          {done(6, :move_to), [build(7, @a)]},
          # 还缺 19：本工地不再 gather、不再重试 build，换下一个工地。
          {rejected(7, :build, :insufficient_material), [walk(8, @b)]},
          {done(8, :move_to), [build(9, @b)]},
          {rejected(9, :build, :insufficient_material), [%{id: 10, verb: :query_balances}]},
          # 只缺没有采石盒的 19：记 idle，本轮巡完，开始休息。
          {done(10, :query_balances, balances([{11, 1324}, {19, 0}])), []},
          {obs(599), []},
          # 休息到点：一轮结束先 RUNNING，下一个事件再巡。
          {obs(600), []},
          {obs(601), [read(11)]}
        ])
      end)

    assert [a, b] = idle(log)
    assert a =~ "entity=7 act=build reason=insufficient_material context=#{inspect(@a)}"
    assert b =~ "entity=7 act=build reason=insufficient_material context=#{inspect(@b)}"
  end

  test "occupied: the own anchor counts as built, a foreign anchor is skipped and logged" do
    occupancy = fn cell, by ->
      %{probe_occupancy: [%{cell: cell, material: 11, refined: false, slots: [], placed_by: by}]}
    end

    log =
      info(fn ->
        settler()
        |> script([
          {obs(0), [read(1)]},
          {done(1, :read_catalog, bill(%{11 => 1024})), [walk(2, @a)]},
          {done(2, :move_to), [build(3, @a)]},
          {rejected(3, :build, :occupied),
           [%{id: 4, verb: :look, min: {8, 64, 14}, max: {8, 64, 14}}]},
          {done(4, :look, occupancy.([8, 64, 14], 7)), [walk(5, @b)]},
          {done(5, :move_to), [build(6, @b)]},
          {rejected(6, :build, :occupied),
           [%{id: 7, verb: :look, min: {12, 64, 14}, max: {12, 64, 14}}]},
          {done(7, :look, occupancy.([12, 64, 14], 4242)), []}
        ])
      end)

    assert [line] = idle(log)
    assert line =~ "act=build reason=occupied context=#{inspect(@b)}"
  end

  test "no quarry for the missing material and an exhausted quarry both end the site; the next site goes on" do
    log =
      info(fn ->
        settler(%{quarries: %{}})
        |> script([
          {obs(0), [read(1)]},
          {done(1, :read_catalog, bill(%{11 => 1024})), [walk(2, @a)]},
          {done(2, :move_to), [build(3, @a)]},
          {rejected(3, :build, :insufficient_material), [%{id: 4, verb: :query_balances}]},
          {done(4, :query_balances, balances([{11, 0}])), [walk(5, @b)]}
        ])

        settler()
        |> script([
          {obs(0), [read(1)]},
          {done(1, :read_catalog, bill(%{11 => 1024})), [walk(2, @a)]},
          {done(2, :move_to), [build(3, @a)]},
          {rejected(3, :build, :insufficient_material), [%{id: 4, verb: :query_balances}]},
          {done(4, :query_balances, balances([{11, 0}])),
           [
             %{
               id: 5,
               verb: :skill,
               skill: :gather,
               args: %{
                 "box" => [[10, 64, 4], [13, 64, 6]],
                 "material" => 11,
                 "units" => 1024,
                 "tool_id" => 1
               }
             }
           ]},
          {rejected(5, :gather, :exhausted), [walk(6, @b)]}
        ])
      end)

    assert [no_quarry, exhausted] = idle(log)
    assert no_quarry =~ "act=build reason=insufficient_material context=#{inspect(@a)}"
    assert exhausted =~ "act=gather reason=exhausted context=#{inspect(@a)}"
  end

  test "definition_not_found rests the whole round and asks again next round" do
    log =
      info(fn ->
        settler()
        |> script([
          {obs(0), [read(1)]},
          {rejected(1, :read_catalog, :definition_not_found), []},
          {obs(600), []},
          {obs(601), [read(2)]}
        ])
      end)

    assert ["npc_settler_idle entity=7 act=read_catalog reason=definition_not_found"] == idle(log)
  end

  # 瞬态原因之后身体可能已不在站位：复活回会话出生点（player.ex died/1 → relocate）、重新 claim 也从 spawn 入场。
  test "a transient rejection restarts the site from the stand after 60 ticks instead of resending the step in place" do
    settler()
    |> script([
      {obs(100), [read(1)]},
      {done(1, :read_catalog, bill(%{11 => 1024})), [walk(2, @a)]},
      {done(2, :move_to), [build(3, @a)]},
      {rejected(3, :build, :dead), []},
      {obs(159), []},
      # 先回站位、再 build，而不是在出生点原样重发 build。
      {obs(160), [walk(4, @a)]},
      {done(4, :move_to), [build(5, @a)]},
      {done(5, :build, %{seq: 77}), [walk(6, @b)]}
    ])
  end

  test "a gather cut short by session_lost is not resent with the old units; the deficit is recomputed, and a second transient failure ends the site" do
    gather = fn id, units ->
      %{
        id: id,
        verb: :skill,
        skill: :gather,
        args: %{"box" => [[10, 64, 4], [13, 64, 6]], "material" => 11, "units" => units, "tool_id" => 1}
      }
    end

    log =
      info(fn ->
        settler()
        |> script([
          {obs(0), [read(1)]},
          {done(1, :read_catalog, bill(%{11 => 1024})), [walk(2, @a)]},
          {done(2, :move_to), [build(3, @a)]},
          {rejected(3, :build, :insufficient_material), [%{id: 4, verb: :query_balances}]},
          {done(4, :query_balances, balances([{11, 300}])), [gather.(5, 724)]},
          # 挖到一半会话丢了：已挖的格已经入账，原样重发 724 会多挖。
          {rejected(5, :gather, :session_lost), []},
          {obs(59), []},
          {obs(60), [walk(6, @a)]},
          {done(6, :move_to), [build(7, @a)]},
          {rejected(7, :build, :insufficient_material), [%{id: 8, verb: :query_balances}]},
          # 新余额 812：缺额按 1024 − 812 = 212 重算。
          {done(8, :query_balances, balances([{11, 812}])), [gather.(9, 212)]},
          # 这一轮的重来只有一次：再遇瞬态原因，本工地记 idle、换下一个。
          {rejected(9, :gather, :dead), [walk(10, @b)]}
        ])
      end)

    assert [line] = idle(log)
    assert line =~ "act=gather reason=dead context=#{inspect(@a)}"
  end

  # —— T3.5 与多轮浸泡 (a)：真实 World ——

  # 两格高的石柱：两个 macro 格，材料单 2 × 512 = 1024；放下后锚点格有本 NPC 的放置溯源。
  @pillar Prefab.encode(%{
            cells: [],
            macro_cells: [{{0, 0, 0}, 11}, {{0, 1, 0}, 11}],
            children: [],
            attachments: []
          })
  @npc 9101
  # 朝向 0：石柱沿 +Y 立在锚点格上（纯函数用例里 B 的朝向 5 会把第二格转进地面）。
  @b0 %{@b | orientation: 0}
  # 工地 C 的锚点格是作者写入的石料（别人的格）：每轮 occupied → 不是自家 → 记一行 idle。
  @c %{anchor_micro: [128, 512, 112], orientation: 0, stand: [16.5, 11.5]}
  @pile for x <- 10..13, z <- 4..6, do: {x, 64, z}

  defp start_world(prefabs \\ []) do
    fixture = NpcWorld.start(prefab_access: true, prefabs: prefabs)
    {:ok, _} = World.apply_edits(fixture.world, Enum.map([{16, 64, 14} | @pile], &{&1, 11}))
    fixture
  end

  defp tree_brain(definition, sites, revisit_ticks),
    do:
      {Tree,
       %{
         tree: &Trees.settler/1,
         definition: definition,
         sites: sites,
         quarries: @quarry,
         revisit_ticks: revisit_ticks,
         tools: %{1 => "镐"},
         skills: %{build: %{}, gather: %{}},
         memory: NpcWorld.Memory
       }}

  # 收日志直到 done?.(已收行) 为真。
  defp logs_until(acc, done?, deadline) do
    if done?.(acc) do
      acc
    else
      receive do
        {:npc_log, line} -> logs_until(acc ++ [line], done?, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("log condition not reached; got #{length(acc)} lines: #{inspect(Enum.take(acc, -10))}")
      end
    end
  end

  defp c_idle(lines),
    do: Enum.count(lines, &(&1 =~ "npc_settler_idle" and &1 =~ "context=#{inspect(@c)}"))

  defp placements(lines, result),
    do: Enum.filter(lines, &(&1 =~ "kind=voxel_prefab_place_v1 cid=#{@npc} " and &1 =~ "result=#{result}"))

  @tag timeout: 300_000
  test "two sites with supply for one: the second gathers; six rounds with a Body restart never build twice and conserve the balance" do
    fixture = start_world()
    world = fixture.world
    publisher = NpcWorld.actor(4242, {0.0, 0.0, 0.0})
    {:ok, id} = World.publish_prefab(world, publisher, @pillar, "石柱")
    {:ok, _} = World.material_supply(world, @npc, "settler-supply", %{11 => 1324})
    sites = [@a, @b0, @c]
    NpcWorld.assert_stands_within_reach(sites, @quarry)

    NpcWorld.LogTap.attach()
    %{sup: sup, body: body} = NpcWorld.body(fixture, tree_brain(Base.encode16(id), sites, 60))
    deadline = System.monotonic_time(:millisecond) + 240_000

    # 两轮：第一轮 A 用供给建成、B 缺 1024 − 300 = 724 → gather 两格（1024）→ 建成，C 被占；第二轮 A、B 认出自家锚点。
    before = logs_until([], &(c_idle(&1) >= 2), deadline)
    assert [_, _] = placements(before, "ok")
    assert 1324 + 1024 - 2 * 1024 == NpcWorld.balance(world, @npc)

    # 崩溃重启：监督者按 transient 重起 Body，树从头巡（不存档，以权威为准）。
    Process.exit(body, :kill)
    restarted =
      NpcWorld.await(fn ->
        pid = NpcWorld.current_body(sup)
        is_pid(pid) and pid != body and pid
      end)
    after_restart = logs_until([], &(c_idle(&1) >= 4), deadline)
    lines = before ++ after_restart

    # 六轮里只有两次放置成功；B 第一次因余额不足被拒（随后 gather），其余放置一律 occupied，没有重复建造。
    assert [first, second] = placements(lines, "ok")
    attempts = Enum.filter(lines, &(&1 =~ "kind=voxel_prefab_place_v1 cid=#{@npc} "))

    refused =
      Enum.frequencies_by(attempts -- [first, second], fn line ->
        [reason] = Regex.run(~r/result=error reason=(\S+)/, line, capture: :all_but_first)
        reason
      end)

    assert %{":insufficient_material" => 1, ":occupied" => occupied} = refused
    assert map_size(refused) == 2 and occupied >= 1 + 3 * 5

    # 每轮恰一行 idle，且只有预期原因：C 被占。gather 只在第一轮跑过一次。
    idle = Enum.filter(lines, &String.starts_with?(&1, "npc_settler_idle"))
    assert length(idle) == c_idle(lines) and c_idle(lines) >= 6
    assert Enum.all?(idle, &(&1 =~ "act=build reason=occupied context=#{inspect(@c)}"))
    assert [gather] = Enum.filter(lines, &(&1 =~ "npc_skill_outcome skill=gather"))
    assert gather =~ "status=done"

    # 余额守恒：供给 1324 + 采得 2 格 × 512 − 2 × 材料单 1024 = 300；采石堆少两格，其余世界不变。
    assert 300 == NpcWorld.balance(world, @npc)
    assert 10 == Enum.count(NpcWorld.cells(world, @pile), fn {_, row} -> row.material == 11 end)

    built =
      NpcWorld.cells(world, [{8, 64, 14}, {8, 65, 14}, {12, 64, 14}, {12, 65, 14}, {16, 64, 14}, {16, 65, 14}])

    for cell <- [{8, 64, 14}, {8, 65, 14}, {12, 64, 14}, {12, 65, 14}],
        do: assert(%{material: 11, placed_by: @npc} = built[cell])

    assert %{material: 11, placed_by: nil} = built[{16, 64, 14}]
    assert %{material: 0} = built[{16, 65, 14}]

    # 两个实例：事务号即实例 birth，各占两格。
    for line <- [first, second] do
      [seq] = Regex.run(~r/result=ok seq=(\d+)/, line, capture: :all_but_first)
      assert {:ok, [_, _]} = World.instance_cells(world, {String.to_integer(seq), 0})
    end

    assert is_pid(restarted) and Process.alive?(restarted)
  end

  @tag timeout: 120_000
  test "an author-catalog definition: the bill comes from read_catalog and the site is built once from supply" do
    # 作者目录定义：三格高的石柱，材料单 3 × 512 = 1536。
    tower =
      Prefab.encode(%{
        cells: [],
        macro_cells: [{{0, 0, 0}, 11}, {{0, 1, 0}, 11}, {{0, 2, 0}, 11}],
        children: [],
        attachments: []
      })

    fixture = start_world([tower])
    world = fixture.world
    {:ok, _} = World.material_supply(world, @npc, "settler-author", %{11 => 1536})
    %{body: body} = NpcWorld.body(fixture, tree_brain(NpcWorld.hex(tower), [@a], 36_000))

    NpcWorld.await(
      fn -> Enum.find(GateServer.Npc.Body.observe(body).outcomes, &(&1.verb == :build)) end,
      60_000
    )

    outcomes = GateServer.Npc.Body.observe(body).outcomes

    assert %{status: :done, data: %{materials: %{11 => 1536}, size_m: [1.0, 3.0, 1.0]}} =
             Enum.find(outcomes, &(&1.verb == :read_catalog))

    assert %{status: :done} = Enum.find(outcomes, &(&1.verb == :build))
    assert 0 == NpcWorld.balance(world, @npc)

    assert Enum.all?(
             Map.values(NpcWorld.cells(world, [{8, 64, 14}, {8, 65, 14}, {8, 66, 14}])),
             &match?(%{material: 11, placed_by: @npc}, &1)
           )
  end
end
