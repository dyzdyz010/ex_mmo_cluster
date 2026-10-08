Code.require_file("../support/npc_world.exs", __DIR__)

defmodule GateServer.NpcExpandTest do
  @moduledoc """
  只测试：持续扩张技能 `GateServer.Npc.Skills.Expand`（放置阶段决策稿
  docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §7）。

  - 纯函数（选址 `site/5`、规格 `spec/3`、候选地块 `plots/3`、分段 `waypoints/3`、分块 `chunks/2`、采石候选 `quarry/3`）：
    手写小世界，期望逐项手算。
  - 集成：真实 World / Scene / Player / Body（`GateServer.NpcWorld` 夹具），NPC 起始余额 0；邻居的格经正常放置入口、
    石堆经作者入口一次写入并记账，期望按夹具目录手算（一格石料 512 单位，两格高石柱材料单 1024，镐射程 6 米）。
  """
  use ExUnit.Case, async: false
  alias GateServer.Npc.{Abilities, Body}
  alias GateServer.Npc.Skills.{Expand, Travel}
  alias GateServer.NpcWorld
  alias VoxelRegion.{Prefab, World}

  @stone 11
  # VoximMaterials：32 = 矮草（花草，不挡路）。
  @grass 32
  @npc 9101
  @neighbour 4242

  # 手写小世界：box 内逐格，fun.({x, y, z}) 给材料，或 {材料, 放置者}，或 :refined（细化格）。
  defp world({{x0, y0, z0}, {x1, y1, z1}}, fun) do
    for x <- x0..x1, y <- y0..y1, z <- z0..z1, into: %{} do
      row =
        case fun.({x, y, z}) do
          {material, by} -> %{material: material, refined: false, placed_by: by}
          :refined -> %{material: 0, refined: true, placed_by: nil}
          material -> %{material: material, refined: false, placed_by: nil}
        end

      {{x, y, z}, Map.merge(%{cell: [x, y, z], slots: []}, row)}
    end
  end

  # 平地：y ≤ 63 石料，其上空气；edits 覆盖个别格。
  defp flat(box, edits \\ %{}),
    do:
      world(box, fn {_, y, _} = cell ->
        Map.get_lazy(edits, cell, fn -> if y <= 63, do: @stone, else: 0 end)
      end)

  # 2×2 足迹、两格高、间隔 1、站位净空 2：包围盒 micro [0,16) 各轴。
  @spec2 %{offset: {0, 0, 0}, size: {2, 2, 2}, spacing: 1, clearance: 2}
  # 地块 (10, 20)：足迹 x 10..11、z 20..21；窗口外扩 max(1, 2) = 2 → x 8..13、z 18..23；地面带 59..67，顶 67 + 2。
  @window {{8, 59, 18}, {13, 69, 23}}
  @band {59, 67}
  # 自己在地块 −z 一侧。
  @from {10.0, 16.0}

  describe "pure functions" do
    test "spec: the micro bounds at orientation 0 become the macro footprint offset and size" do
      assert %{offset: {0, 0, 0}, size: {2, 2, 2}, spacing: 1, clearance: 2} ==
               Expand.spec([[0, 0, 0], [16, 16, 16]], 1, 2)

      # 不对齐的 micro 包围盒：x [3, 12) → 宏格 0..1；y [0, 9) → 0..1；z [−5, 4) → −1..0。
      assert %{offset: {0, 0, -1}, size: {2, 2, 2}, spacing: 0, clearance: 2} ==
               Expand.spec([[3, 0, -5], [12, 9, 4]], 0, 2)
    end

    test "site: flat ground fits; the anchor sits on the ground and the nearest standable edge stand is chosen" do
      # 地面 = 首列 (10, 20) 自上而下第一个上方不是实心的实心格 = 63；锚点格 (10, 64, 20) → micro × 8。
      # 站位（Blueprint.stands，从 (10, 16) 由近到远）：(11.0, 18.5) 4.25、(8.5, 21.0) 24.25、(13.5, 21.0) 29.25、(11.0, 23.5) 49.25。
      assert {:ok,
              %{
                anchor_micro: [80, 512, 160],
                orientation: 0,
                stand: [11.0, 18.5],
                site_cell: [10, 64, 20],
                ground: 63
              }} == Expand.site(flat(@window), {10, 20}, @spec2, @band, @from)

      # 最近的站位列 (11, 18) 被一棵树占着（木头挡路）：换下一个 (8.5, 21.0)。
      tree = flat(@window, %{{11, 64, 18} => 19})
      assert {:ok, %{stand: [8.5, 21.0]}} = Expand.site(tree, {10, 20}, @spec2, @band, @from)

      # 四个站位都没有同高的地面可站：no_stand。
      moat = for {x, z} <- [{11, 18}, {8, 21}, {13, 21}, {11, 23}], into: %{}, do: {{x, 63, z}, 0}

      assert {:error, :no_stand} ==
               Expand.site(flat(@window, moat), {10, 20}, @spec2, @band, @from)
    end

    test "site: a column one cell higher does not fit" do
      # 首列高一格：地面取 64，(11, 64, 20) 不是实心 → 足迹各列地面不同高。
      assert {:error, :uneven} ==
               Expand.site(
                 flat(@window, %{{10, 64, 20} => @stone}),
                 {10, 20},
                 @spec2,
                 @band,
                 @from
               )

      # 别的列高一格：地面 63 各列都实心，但 (11, 64, 21) 占着建筑的体积。
      assert {:error, :blocked} ==
               Expand.site(
                 flat(@window, %{{11, 64, 21} => @stone}),
                 {10, 20},
                 @spec2,
                 @band,
                 @from
               )

      # 地面带里找不到地面（整列空气）。
      hole = for y <- 59..63, into: %{}, do: {{10, y, 20}, 0}

      assert {:error, :no_ground} ==
               Expand.site(flat(@window, hole), {10, 20}, @spec2, @band, @from)
    end

    test "site: grass on the footprint does not fit (a prefab only goes into air)" do
      # 花草不挡路：地面仍是 63；但 (10, 64, 20) 不是空气。
      assert {:error, :blocked} ==
               Expand.site(
                 flat(@window, %{{10, 64, 20} => @grass}),
                 {10, 20},
                 @spec2,
                 @band,
                 @from
               )
    end

    test "site: a placed or refined cell within spacing does not fit; one cell further out does" do
      # 间隔 1：足迹外扩 1 = x 9..12、z 19..22。(12, 63, 22) 是别人铺的地板（有放置记录）。
      assert {:error, :crowded} ==
               Expand.site(
                 flat(@window, %{{12, 63, 22} => {@stone, @neighbour}}),
                 {10, 20},
                 @spec2,
                 @band,
                 @from
               )

      assert {:error, :crowded} ==
               Expand.site(
                 flat(@window, %{{9, 64, 19} => :refined}),
                 {10, 20},
                 @spec2,
                 @band,
                 @from
               )

      # (13, 63, 22) 在外扩 1 之外：放得下。
      assert {:ok, %{site_cell: [10, 64, 20]}} =
               Expand.site(
                 flat(@window, %{{13, 63, 22} => {@stone, @neighbour}}),
                 {10, 20},
                 @spec2,
                 @band,
                 @from
               )
    end

    test "plots: a lattice from the region corner with pitch = footprint + spacing, nearest first" do
      # 区域 x 0..7、z 0..4，2×2 足迹、间隔 1 → 间距 3：x ∈ {0, 3, 6}，z ∈ {0, 3}（z 3..4 是最后一块）。
      # 从 (7.0, 0.5) 到地块中心 (fx + 1, fz + 1) 的距离²：(6,0) 0.25、(3,0) 9.25、(6,3) 12.25、(3,3) 21.25、(0,0) 36.25、(0,3) 48.25。
      assert [{6, 0}, {3, 0}, {6, 3}, {3, 3}, {0, 0}, {0, 3}] ==
               Expand.plots({{0, 0}, {7, 4}}, @spec2, {7.0, 0.5})

      # 等距按 (fx, fz)：从 (4.0, 2.5) 到 (3,0)、(3,3) 都是 2.25。
      assert [{3, 0}, {3, 3} | _] = Expand.plots({{0, 0}, {7, 4}}, @spec2, {4.0, 2.5})
      # 区域比足迹窄：没有候选。
      assert [] == Expand.plots({{0, 0}, {0, 4}}, @spec2, {0.0, 0.0})
    end

    test "waypoints: equal legs no longer than the limit along the straight line" do
      # 距离 100，上限 30 → 4 段，每段 25。
      assert [{15.0, 20.0}, {30.0, 40.0}, {45.0, 60.0}, {60.0, 80.0}] ==
               Travel.waypoints({0.0, 0.0}, {60.0, 80.0}, 30)

      # 不超过上限：一段直达。
      assert [{4.0, 6.0}] == Travel.waypoints({1.0, 2.0}, {4.0, 6.0}, 30)
      assert [{30.0, 0.0}] == Travel.waypoints({0.0, 0.0}, {30.0, 0.0}, 30)
    end

    test "chunks: whole x slabs within the look limit; z strips when one slab is too big" do
      # 10 × 6 × 10 = 600 格：一片 x = 60 格 → 每块 8 片。
      assert [{{0, 0, 0}, {7, 5, 9}}, {{8, 0, 0}, {9, 5, 9}}] ==
               Expand.chunks({{0, 0, 0}, {9, 5, 9}}, 512)

      # 2 × 20 × 30：一片 x = 600 格超限 → 每条 z 25 格（20 × 25 = 500）。
      assert [
               {{0, 0, 0}, {0, 19, 24}},
               {{0, 0, 25}, {0, 19, 29}},
               {{1, 0, 0}, {1, 19, 24}},
               {{1, 0, 25}, {1, 19, 29}}
             ] == Expand.chunks({{0, 0, 0}, {1, 19, 29}}, 512)
    end

    test "quarry: exposed natural cells of the material, ground layer or above, outside the keep zone, top layer first" do
      # 一排 x 0..6、z 0：平地之上 (5,64)(5,65) 叠两格、(6,64) 一格；(4,64) 是别人放的；保护区 x −1..1（足迹 x 0 外扩 1）。
      rows =
        flat({{0, 63, 0}, {6, 66, 0}}, %{
          {5, 64, 0} => @stone,
          {5, 65, 0} => @stone,
          {6, 64, 0} => @stone,
          {4, 64, 0} => {@stone, @neighbour}
        })

      # 露天：(5,65)；(6,64)；地面层 (2,63)、(3,63)（(4,63) 上面压着别人的格，(5,63)(6,63) 被盖住，(0,63)(1,63) 在保护区）。
      # 层自上而下，同层离 (0.5, 0.5) 由近到远。
      assert [{5, 65, 0}, {6, 64, 0}, {2, 63, 0}, {3, 63, 0}] ==
               Expand.quarry(
                 rows,
                 %{
                   material: @stone,
                   ground: 63,
                   area: {{0, 0}, {6, 0}},
                   keep: {{-1, -1}, {1, 1}}
                 },
                 {0.5, 0.5}
               )

      assert [] ==
               Expand.quarry(
                 rows,
                 %{material: 19, ground: 63, area: {{0, 0}, {6, 0}}, keep: {{-1, -1}, {1, 1}}},
                 {0.5, 0.5}
               )
    end

    test "the expand tool schema is strict; every argument is required" do
      [tool] =
        Abilities.tools(%{groups: [:skill], tools: %{1 => "镐"}, skills: %{expand: %{}}})

      assert %{
               name: "expand",
               strict: true,
               parameters: %{
                 additionalProperties: false,
                 required: ["definition", "region", "tool_id", "spacing"],
                 properties: %{
                   definition: %{type: "string"},
                   tool_id: %{type: "integer", enum: [1]},
                   spacing: %{type: "integer", minimum: 0},
                   region: region
                 }
               }
             } = tool

      assert %{
               type: "array",
               minItems: 2,
               maxItems: 2,
               items: %{type: "array", minItems: 2, maxItems: 2, items: %{type: "integer"}}
             } = region
    end
  end

  # —— 真实 World ——

  # 两格高的石柱：材料单 2 × 512 = 1024。
  @pillar Prefab.encode(%{
            cells: [],
            macro_cells: [{{0, 0, 0}, @stone}, {{0, 1, 0}, @stone}],
            children: [],
            attachments: []
          })
  # 区域 x 6..16、z 8..10，间隔 2 → 间距 3：地块 x ∈ {6, 9, 12, 15}、z 8（z 11 出区域）。
  @region [[6, 8], [16, 10]]

  # 邻居（另一角色）发布石柱并花自己的材料在 (14, 64, 8) 放一格：地块 12、15 的间隔带里都有它（12 外扩 2 = 10..14，
  # 15 外扩 2 = 13..17），两块永远不是空地；地块 6、9 的间隔带（4..8、7..11）没有。
  # 作者石堆 (13..16, 64, 10)：离地块 6、9 的足迹都 ≥ 4 格（spacing + 2），两块都能从这里采。
  defp start_layout do
    fixture = NpcWorld.start(prefab_access: true)
    world = fixture.world
    neighbour = NpcWorld.actor(@neighbour, {15.5, 65.5, 6.5})
    {:ok, id} = World.publish_prefab(world, neighbour, @pillar, "石柱")
    {:ok, _} = World.material_supply(world, @neighbour, "expand-neighbour", %{@stone => 512})

    assert {:ok, _} =
             World.production_intent(world, neighbour, %{
               request_id: 1,
               client_intent_seq: 1,
               logical_scene_id: 1,
               action: 1,
               coord: {14, 64, 8},
               tool_id: 1,
               material: @stone
             })

    {:ok, _} = World.apply_edits(world, for(x <- 13..16, do: {{x, 64, 10}, @stone}))
    Map.put(fixture, :definition, Base.encode16(id))
  end

  defp expand(body, id, definition) do
    Body.command(body, %{
      id: id,
      verb: :skill,
      skill: :expand,
      args: %{"definition" => definition, "region" => @region, "tool_id" => 1, "spacing" => 2}
    })

    NpcWorld.await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == id)) end, 240_000)
  end

  # travel：单程 move_to 水平上限 32 m（Body 寻路取盒），一次 travel 从 (4, 10) 走到 (−50.5, −40.5)：直线
  # √(54.5² + 50.5²) ≈ 74.3 m，分成 ⌈74.3 / 30⌉ = 3 段（目标留在夹具 Scene 的活动范围 x、z ∈ [−60, 60) 内），
  # 每段仍由 Body 寻路；到了 done 带权威位置与段数。改前没有 travel 技能（单个 move_to 同样的目标回 too_far）。
  @tag timeout: 300_000
  test "travel walks far beyond one move_to in legs; a single move_to of the same distance is too_far" do
    fixture = NpcWorld.start([])
    profile = %{steps: [], tools: %{1 => "镐"}, skills: %{travel: %{}}, memory: NpcWorld.Memory}
    %{body: body} = NpcWorld.body(fixture, {GateServer.Npc.Brain.Routine, profile})

    assert {4.0, _, 10.0} =
             NpcWorld.await(fn ->
               with {_, y, _} = position <- Body.observe(body).position,
                    true <- abs(y - 64.9) < 0.05,
                    do: position
             end)

    Body.command(body, %{id: 1, verb: :move_to, position: {-50.5, -40.5}, tolerance: 0.5})

    assert %{status: :rejected, reason: :too_far} =
             NpcWorld.await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == 1)) end, 10_000)

    Body.command(body, %{id: 2, verb: :skill, skill: :travel, args: %{"x" => -50.5, "z" => -40.5}})

    assert %{verb: :travel, status: :done, data: %{position: {x, _, z}, legs: 3}} =
             NpcWorld.await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == 2)) end, 120_000)

    assert abs(x + 50.5) <= 0.5 and abs(z + 40.5) <= 0.5
  end

  @tag timeout: 600_000
  test "expand builds on the nearest free plot, gathers the shortage from the natural pile first, then the next plot, then no_site" do
    fixture = start_layout()
    world = fixture.world
    profile = %{steps: [], tools: %{1 => "镐"}, skills: %{expand: %{}}, memory: NpcWorld.Memory}
    %{body: body} = NpcWorld.body(fixture, {GateServer.Npc.Brain.Routine, profile})

    # 前提：落地站稳在出生点 (4.0, 10.0)，余额 0。
    assert {4.0, _, 10.0} =
             NpcWorld.await(fn ->
               with {_, y, _} = position <- Body.observe(body).position,
                    true <- abs(y - 64.9) < 0.05,
                    do: position
             end)

    assert 0 == NpcWorld.balance(world, @npc)

    # 第一座：从 (4.0, 10.0) 到地块中心距离² 6 → 8.5、9 → 32.5…，最近的是地块 6；站位 (6.5, 10.5)（见 site 用例的站位排序）。
    # 余额 0 → 缺 1024：从站位看石堆 (13..16, 64, 10)，层同为 64、离站位由近到远是 13、14、15、16，采 13、14 两格。
    assert %{
             verb: :expand,
             status: :done,
             data: %{
               anchor_micro: [48, 512, 64],
               orientation: 0,
               stand: [6.5, 10.5],
               site_cell: [6, 64, 8],
               skipped: skipped_a
             }
           } = expand(body, :a, fixture.definition)

    assert skipped_a == %{}
    # 采得 2 × 512、放下花 1024。
    assert 0 == NpcWorld.balance(world, @npc)

    assert %{
             {6, 64, 8} => %{material: @stone, placed_by: @npc},
             {6, 65, 8} => %{material: @stone, placed_by: @npc},
             {13, 64, 10} => %{material: 0},
             {14, 64, 10} => %{material: 0},
             {15, 64, 10} => %{material: @stone},
             {16, 64, 10} => %{material: @stone}
           } = NpcWorld.cells(world, [{6, 64, 8}, {6, 65, 8} | for(x <- 13..16, do: {x, 64, 10})])

    # 第二座：自己在 (6.5, 10.5)，地块 6 已有自家石柱（间隔带里有放置记录）跳过，下一个是地块 9；站位 (7.5, 8.5)
    # （从 (6, 10)：(7.5, 8.5) 5、(9.5, 10.5) 9、(9.5, 6.5) 25、(11.5, 8.5) 29）。保护区 x 6..12 → 只剩石堆 15、16。
    assert %{
             verb: :expand,
             status: :done,
             data: %{
               anchor_micro: [72, 512, 64],
               orientation: 0,
               stand: [7.5, 8.5],
               site_cell: [9, 64, 8],
               skipped: %{crowded: 1}
             }
           } = expand(body, :b, fixture.definition)

    assert 0 == NpcWorld.balance(world, @npc)

    built = NpcWorld.cells(world, [{9, 64, 8}, {9, 65, 8} | for(x <- 13..16, do: {x, 64, 10})])

    assert %{{9, 64, 8} => %{material: @stone, placed_by: @npc}, {9, 65, 8} => %{placed_by: @npc}} =
             built

    assert Enum.all?(for(x <- 13..16, do: built[{x, 64, 10}]), &(&1.material == 0))

    # 第三次：四块都不是空地（6、9 自家，12、15 邻居的格在间隔带里），不采不建。
    assert %{verb: :expand, status: :rejected, reason: :no_site} =
             expand(body, :c, fixture.definition)

    assert 0 == NpcWorld.balance(world, @npc)

    # 护栏：邻居的格还在；只挖了地表以上的石堆，地面一格没动；区域外不变。
    around =
      NpcWorld.cells(
        world,
        [{14, 64, 8} | for(x <- 5..17, z <- 7..11, do: {x, 63, z})] ++
          for(x <- [5, 17], z <- 7..11, do: {x, 64, z})
      )

    assert %{material: @stone, placed_by: @neighbour} = around[{14, 64, 8}]

    assert Enum.all?(
             for(x <- 5..17, z <- 7..11, do: around[{x, 63, z}]),
             &(&1.material == @stone)
           )

    assert Enum.all?(for(x <- [5, 17], z <- 7..11, do: around[{x, 64, z}]), &(&1.material == 0))
  end
end
