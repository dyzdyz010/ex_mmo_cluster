Code.require_file("../support/npc_world.exs", __DIR__)

defmodule GateServer.NpcExpandTest do
  @moduledoc """
  只测试：持续扩张技能 `GateServer.Npc.Skills.Expand`（放置阶段决策稿
  docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §7）。

  - 纯函数（选址 `site/4`、平整 `level/2`、终态 `ending/1`、规格 `spec/3`、候选地块 `plots/3`、分段 `waypoints/3`、分块
    `chunks/2`、采石候选 `quarry/3`）：手写小世界（survey 的列结果 / look 的格行），期望逐项手算。
  - 集成：真实 World / Scene / Player / Body（`GateServer.NpcWorld` 夹具）；邻居的格经正常放置入口、石堆 / 起伏 / 台阶经作者入口
    一次写入，NPC 的余额只经作者供给入口一次记账，期望按夹具目录手算（一格石料 512 单位，两格高石柱材料单 1024，三格石台
    1536，镐射程 6 米、一格 4 击）。
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

  # 手写勘察结果（`Perception.surfaces/2` 的列）：box 内逐列，缺省平地（地面 63、石料）；edits 给 {x, z} 的地表：整数 y、
  # {y, 放置者}、{:refined, y}（这一列有细化格）、nil（范围内没有可站的地面）。
  defp columns({{x0, z0}, {x1, z1}}, edits \\ %{}) do
    for x <- x0..x1, z <- z0..z1, into: %{} do
      column =
        case Map.get(edits, {x, z}, 63) do
          nil -> %{floors: [], y: nil, material: nil, placed_by: nil, refined: false}
          {:refined, y} -> %{floors: [y], y: y, material: @stone, placed_by: nil, refined: true}
          {y, by} -> %{floors: [y], y: y, material: @stone, placed_by: by, refined: false}
          y -> %{floors: [y], y: y, material: @stone, placed_by: nil, refined: false}
        end

      {{x, z}, Map.put(column, :column, [x, z])}
    end
  end

  # 2×2 足迹、两格高、间隔 1、站位净空 2：包围盒 micro [0,16) 各轴。
  @spec2 %{offset: {0, 0, 0}, size: {2, 2, 2}, spacing: 1, clearance: 2}
  # 地块 (10, 20)：足迹 x 10..11、z 20..21；勘察窗口外扩 max(1, 2) = 2 → x 8..13、z 18..23。
  @window {{8, 18}, {13, 23}}
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
      # 足迹四列地表都是 63 → 目标地面 63；锚点格 (10, 64, 20) → micro × 8。
      # 站位（Blueprint.stands，从 (10, 16) 由近到远）：(11.0, 18.5) 4.25、(8.5, 21.0) 24.25、(13.5, 21.0) 29.25、(11.0, 23.5) 49.25。
      assert {:ok,
              %{
                anchor_micro: [80, 512, 160],
                orientation: 0,
                stand: [11.0, 18.5],
                site_cell: [10, 64, 20],
                ground: 63,
                low: 63
              }} == Expand.site(columns(@window), {10, 20}, @spec2, @from)

      # 站位要离目标地面不超过 2 格：最近的站位列 (11, 18) 地面 60（低 3 格）不行，下一个 (8, 21) 地面 61（低 2 格）可以。
      low = columns(@window, %{{11, 18} => 60, {8, 21} => 61})
      assert {:ok, %{stand: [8.5, 21.0]}} = Expand.site(low, {10, 20}, @spec2, @from)

      # 四个站位列都没有离 63 不超过 2 格的地面：no_stand。
      moat = Map.new([{11, 18}, {8, 21}, {13, 21}, {11, 23}], &{&1, 60})
      assert {:error, :no_stand} == Expand.site(columns(@window, moat), {10, 20}, @spec2, @from)
    end

    test "site: each plot's own ground, relief up to 2 cells is levelled to the lower median, more is uneven" do
      # 地表 64、63、63、62（高差 2）：排序 62、63、63、64，下中位数（第 ⌈4/2⌉ = 2 个）= 63；最低 62。
      bumpy = columns(@window, %{{10, 20} => 64, {11, 21} => 62})

      assert {:ok, %{ground: 63, low: 62, site_cell: [10, 64, 20], anchor_micro: [80, 512, 160]}} =
               Expand.site(bumpy, {10, 20}, @spec2, @from)

      # 62、62、64、64：62..64 之间任何高度的土方量都是 4 格，取低的 62（只挖不填）→ 锚点格落在 63。
      halves = columns(@window, %{{10, 20} => 62, {10, 21} => 62, {11, 20} => 64, {11, 21} => 64})

      assert {:ok, %{ground: 62, low: 62, site_cell: [10, 63, 20]}} =
               Expand.site(halves, {10, 20}, @spec2, @from)

      # 整块地比自己脚下高很多也照样按它自己的地面判定（地面 80）：地面高度取自候选自己。
      high = Map.new(Map.keys(columns(@window)), &{&1, 80})

      assert {:ok, %{ground: 80, site_cell: [10, 81, 20]}} =
               Expand.site(columns(@window, high), {10, 20}, @spec2, @from)

      # 64 与 61：高差 3 → uneven。
      assert {:error, :uneven} ==
               Expand.site(columns(@window, %{{10, 20} => 64, {11, 21} => 61}), {10, 20}, @spec2, @from)

      # 足迹有一列在勘察范围里没有可站的地面（水面、整列空气…）→ no_ground。
      assert {:error, :no_ground} ==
               Expand.site(columns(@window, %{{11, 21} => nil}), {10, 20}, @spec2, @from)
    end

    test "site: a placed surface or a refined column within spacing does not fit; one column further out does" do
      # 间隔 1：足迹外扩 1 = x 9..12、z 19..22。(12, 22) 的地表是别人铺的一格（有放置记录）。
      assert {:error, :crowded} ==
               Expand.site(columns(@window, %{{12, 22} => {63, @neighbour}}), {10, 20}, @spec2, @from)

      assert {:error, :crowded} ==
               Expand.site(columns(@window, %{{9, 19} => {:refined, 63}}), {10, 20}, @spec2, @from)

      # (13, 22) 在外扩 1 之外：放得下。
      assert {:ok, %{site_cell: [10, 64, 20]}} =
               Expand.site(columns(@window, %{{13, 22} => {63, @neighbour}}), {10, 20}, @spec2, @from)
    end

    test "level: natural cells above the ground are dug (flora too), holes at or below it are filled; anything else blocks" do
      # 平整体积：足迹 x 10..11、z 20..21，y 从最低地表 62 到 g + 高 = 63 + 2 = 65。
      box = {{10, 62, 20}, {11, 65, 21}}
      # (10,20) 高出一格石头；(11,20) 地面上长草；(11,21) 是坑（63 是空气）。
      bumpy = %{{10, 64, 20} => @stone, {11, 64, 20} => @grass, {11, 63, 21} => 0}

      assert {:ok, %{dig: [{10, 64, 20}, {11, 64, 20}], fill: [{11, 63, 21}]}} ==
               Expand.level(flat(box, bumpy), 63)

      # 坑里长着草：放置直接覆盖花草，照样填；平地什么都不动。
      assert {:ok, %{dig: [], fill: [{11, 63, 21}]}} ==
               Expand.level(flat(box, %{{11, 63, 21} => @grass}), 63)

      assert {:ok, %{dig: [], fill: []}} == Expand.level(flat(box), 63)

      # 要动的格不是天然格：建筑体积里别人放的一格、坑里的水、细化格 → blocked（不拆、不改任何已有放置）。
      for edit <- [
            %{{10, 64, 21} => {@stone, @neighbour}},
            %{{11, 63, 21} => 21},
            %{{10, 65, 20} => :refined},
            %{{11, 63, 21} => {@grass, @neighbour}}
          ],
          do: assert({:error, :blocked} == Expand.level(flat(box, edit), 63), inspect(edit))
    end

    test "ending: a plot skipped as unreachable, out of reach or short of material means no_reachable_site, else region_full" do
      assert :region_full == Expand.ending(%{})
      assert :region_full == Expand.ending(%{crowded: 3, uneven: 1, no_stand: 1, blocked: 2, occupied: 1})

      for reason <- [:no_path, :stuck, :too_far, :out_of_reach, :insufficient_material],
          do: assert(:no_reachable_site == Expand.ending(%{:crowded => 2, reason => 1}), inspect(reason))
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

    test "the expand description tells region_full from no_reachable_site" do
      [tool] = Abilities.tools(%{groups: [:skill], tools: %{1 => "镐"}, skills: %{expand: %{}}})
      assert tool.description =~ "region_full = 区域里已经没有能建的地块"
      assert tool.description =~ "no_reachable_site = 还有本可成立的地块"
      assert tool.description =~ "高差不超过 2 格"
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

  # 落地站稳在出生点地面（顶 63，脚 64，胶囊半高 0.9）。
  defp grounded(body),
    do:
      NpcWorld.await(fn ->
        case Body.observe(body).position do
          {_, y, _} = position when abs(y - 64.9) < 0.05 -> position
          _ -> nil
        end
      end)

  defp outcome(body, id, timeout),
    do: NpcWorld.await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == id)) end, timeout)

  # 两层台地高差 8 米：出生点地面（脚 64）与东边平台（x 12..20、z 8..12，实心到 y 71，脚 72）之间一级一格的台阶（x 5..11，
  # 顶 64..70），直线 12.5 米只有一段。改前这一段 move_to 不带 y：Body 寻路取盒竖直只到脚下上下 6 格（58..70），目标列在盒里
  # 没有站立格 → no_path（2026-10-08 run06 住民从北坡去坡下的建房区，每段 no_path）。改后 travel 先 survey 段终点列，取离脚下
  # 最近的可站层（地面 71 → 站立格 72）带 y 走，取盒竖直覆盖 58..78，顺台阶走上平台。
  @tag timeout: 300_000
  test "travel climbs an 8 m terrace: each leg surveys its end column and walks with that standing level" do
    fixture = NpcWorld.start([])
    stairs = for x <- 5..11, z <- 8..12, y <- 64..(64 + x - 5), do: {{x, y, z}, @stone}
    plateau = for x <- 12..20, z <- 8..12, y <- 64..71, do: {{x, y, z}, @stone}
    {:ok, _} = World.apply_edits(fixture.world, stairs ++ plateau)
    profile = %{steps: [], tools: %{1 => "镐"}, skills: %{travel: %{}}, memory: NpcWorld.Memory}
    %{body: body} = NpcWorld.body(fixture, {GateServer.Npc.Brain.Routine, profile})
    grounded(body)

    Body.command(body, %{id: 1, verb: :skill, skill: :travel, args: %{"x" => 16.5, "z" => 10.5}})

    assert %{verb: :travel, status: :done, data: %{position: {x, y, z}, legs: 1}} =
             outcome(body, 1, 120_000)

    assert abs(x - 16.5) <= 0.5 and abs(z - 10.5) <= 0.5
    assert_in_delta 72.9, y, 0.05

    # 同一片台地经真实 Body / World 的 survey（z = 10 这一行）：x 3、4 平地 63，x 5..11 台阶顶 64..70，x 12、13 平台 71。
    Body.command(body, %{id: 2, verb: :survey, min: {3, 10}, max: {13, 10}})
    assert %{status: :done, data: %{columns: columns, seq: [seq, seq]}} = outcome(body, 2, 10_000)
    assert [63, 63, 64, 65, 66, 67, 68, 69, 70, 71, 71] == Enum.map(columns, & &1.y)
    assert Enum.all?(columns, &(&1.material == @stone and &1.placed_by == nil and not &1.refined))
  end

  @tag timeout: 600_000
  test "expand builds on the nearest free plot, gathers the shortage from the natural pile first, then the next plot, then region_full" do
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

    # 第三次：四块都不是空地（6、9 自家，12、15 邻居的格在间隔带里），不采不建；全是“地块不成立”→ region_full。
    assert %{verb: :expand, status: :rejected, reason: :region_full} =
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

  # —— 平整与换地块（2026-10-08 run06 的根因 2–4）——

  # 三格石台（x 方向 3 × 1 × 1 个宏格）：材料单 3 × 512 = 1536；作者目录定义（World 启动时载入）。
  @slab Prefab.encode(%{
          cells: [],
          macro_cells: [{{0, 0, 0}, @stone}, {{1, 0, 0}, @stone}, {{2, 0, 0}, @stone}],
          children: [],
          attachments: []
        })
  @dirt 7

  defp expand_in(body, id, region),
    do:
      Body.command(body, %{
        id: id,
        verb: :skill,
        skill: :expand,
        args: %{
          "definition" => NpcWorld.hex(@slab),
          "region" => region,
          "tool_id" => 1,
          "spacing" => 2
        }
      })

  # 自然起伏的地块：足迹 x 0..2、z 0 的地表 64、63、62（(0, 64, 0) 多一格天然石头，(2, 63, 0) 是坑），高差 2。改前选址要求各列
  # 同高（脚下地面带里找地面）→ uneven，区域里唯一的地块不成立，回 no_site（run06：自然地形 4×4 同高的位置一个都没有）。
  # 改后：下中位数 63 为目标地面，从站位 (−1.5, 0.5) 挖掉 (0, 64, 0)（+512 入账），花 512 把 (2, 63, 0) 填石，再放石台（−1536）。
  # 余额：供给 1536 → 挖 2048 → 不缺（材料单 1536 + 填坑 512 = 2048）→ 填 1536 → 放 0。第二次：足迹上是自家石台 → region_full。
  @tag timeout: 300_000
  test "a plot with 1–2 cells of natural relief is levelled to the median, then built; balance and cells checked by hand" do
    fixture = NpcWorld.start(prefab_access: true, prefabs: [@slab])
    world = fixture.world
    {:ok, _} = World.apply_edits(world, [{{0, 64, 0}, @stone}, {{2, 63, 0}, 0}])
    {:ok, _} = World.material_supply(world, @npc, "expand-level", %{@stone => 1536})
    profile = %{steps: [], tools: %{1 => "镐"}, skills: %{expand: %{}}, memory: NpcWorld.Memory}

    %{body: body} =
      NpcWorld.body(fixture, {GateServer.Npc.Brain.Routine, profile}, spawn: {-6.0, 66.0, 0.5})

    grounded(body)
    expand_in(body, :a, [[0, 0], [2, 0]])

    assert %{
             verb: :expand,
             status: :done,
             data: %{
               anchor_micro: [0, 512, 0],
               orientation: 0,
               stand: [-1.5, 0.5],
               site_cell: [0, 64, 0],
               skipped: skipped
             }
           } = outcome(body, :a, 240_000)

    assert skipped == %{}
    assert 0 == NpcWorld.balance(world, @npc)

    # 石台三格与填的坑是本 NPC 放下的；原地面 (0, 63)、(1, 63) 与坑底 (2, 62) 仍是天然石头。
    footprint =
      NpcWorld.cells(world, for(x <- 0..2, y <- 62..65, do: {x, y, 0}))

    assert %{
             {0, 64, 0} => %{material: @stone, placed_by: @npc},
             {1, 64, 0} => %{material: @stone, placed_by: @npc},
             {2, 64, 0} => %{material: @stone, placed_by: @npc},
             {2, 63, 0} => %{material: @stone, placed_by: @npc},
             {0, 63, 0} => %{material: @stone, placed_by: nil},
             {1, 63, 0} => %{material: @stone, placed_by: nil},
             {2, 62, 0} => %{material: @stone, placed_by: nil},
             {0, 65, 0} => %{material: 0},
             {1, 65, 0} => %{material: 0},
             {2, 65, 0} => %{material: 0}
           } = footprint

    # 足迹外不动：x −1..3、z −1..1 的地面 63 仍是天然石头，其上 64 是空气（足迹那三格除外）。
    around =
      NpcWorld.cells(
        world,
        for(x <- -1..3, z <- -1..1, y <- [63, 64], not (z == 0 and x in 0..2), do: {x, y, z})
      )

    for {{_, y, _} = cell, row} <- around do
      expected = if y == 63, do: @stone, else: 0
      assert %{material: ^expected, placed_by: nil} = row, inspect(cell)
    end

    # 区域里唯一的地块已有自家石台：地块不成立 → region_full（可以停）。
    expand_in(body, :b, [[0, 0], [2, 0]])
    assert %{verb: :expand, status: :rejected, reason: :region_full} = outcome(body, :b, 120_000)
    assert 0 == NpcWorld.balance(world, @npc)
  end

  # 换地块：区域 x 0..12、z 0，间隔 2 → 地块 A (0..2)、B (5..7)、C (10..12)，从出生点 (−6, 0.5) 由近到远；余额 0，材料单 1536（3 格）。
  # - A：最近的站位列 (−2, 0) 四邻被三格高的天然石墙围住 → 走不到（no_path），换下一块；
  # - B：站位 (3.5, 0.5) 周围区域内、保护区（足迹外扩 3 = x 2..10）之外露天的只有 x 0、1、11、12 的地面，都铺成了土（不是生产材料，
  #   不采）→ 附近采不到（insufficient_material），换下一块。改前缺料是终态，扩张就此停住（2026-10-08 run06 建设者的循环）；
  # - C：站位 (8.5, 0.5)，保护区 x 7..15 之外露天的石头是 x 2..6 的地面，由近到远采 (6, 63)、(5, 63)、(4, 63) 三格（各 512）→ 建成。
  # done 的 skipped 是 %{no_path: 1, insufficient_material: 1}；余额 3 × 512 − 1536 = 0。
  @tag timeout: 300_000
  test "an unreachable plot and a plot short of material nearby are skipped; the next plot gathers and is built" do
    fixture = NpcWorld.start(prefab_access: true, prefabs: [@slab])
    world = fixture.world
    walls = for {x, z} <- [{-3, 0}, {-1, 0}, {-2, -1}, {-2, 1}], y <- 64..66, do: {{x, y, z}, @stone}
    dirt = for x <- [0, 1, 11, 12], do: {{x, 63, 0}, @dirt}
    {:ok, _} = World.apply_edits(world, walls ++ dirt)
    profile = %{steps: [], tools: %{1 => "镐"}, skills: %{expand: %{}}, memory: NpcWorld.Memory}

    %{body: body} =
      NpcWorld.body(fixture, {GateServer.Npc.Brain.Routine, profile}, spawn: {-6.0, 66.0, 0.5})

    grounded(body)
    assert 0 == NpcWorld.balance(world, @npc)
    expand_in(body, :a, [[0, 0], [12, 0]])

    assert %{
             verb: :expand,
             status: :done,
             data: %{
               anchor_micro: [80, 512, 0],
               stand: [8.5, 0.5],
               site_cell: [10, 64, 0],
               skipped: skipped
             }
           } = outcome(body, :a, 240_000)

    assert skipped == %{no_path: 1, insufficient_material: 1}
    assert 0 == NpcWorld.balance(world, @npc)

    cells = NpcWorld.cells(world, [{10, 64, 0}, {12, 64, 0}, {0, 64, 0} | for(x <- 0..6, do: {x, 63, 0})])
    assert %{{10, 64, 0} => %{material: @stone, placed_by: @npc}, {12, 64, 0} => %{placed_by: @npc}} = cells
    # 采掉的三格、没动的地面与土、A 的足迹。
    assert [@dirt, @dirt, @stone, @stone, 0, 0, 0] == for(x <- 0..6, do: cells[{x, 63, 0}].material)
    assert %{material: 0} = cells[{0, 64, 0}]
  end
end
