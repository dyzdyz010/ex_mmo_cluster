defmodule VoxelRegion.AreaToolWorldTest do
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  # 只测试：真实 World / 文件日志；Source、角色姿态与人物候选是有限夹具，不覆盖网络、Scene 和玩家输入。
  # 手算几何：眼点 (0.5,1.5,0.5)、方向 +X、offset 2 → 判定球心 (2.5,1.5,0.5)、半径 1；
  # 人物胶囊 radius 0.3、half_height 0.9 → 轴段半长 0.6，入区条件为“球心到轴段距离 ≤ 1.3”。
  @profile %{radius: 0.3, half_height: 0.9}

  setup do
    root = Path.join(System.tmp_dir!(), "area_tool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")
    materials = for id <- 0..23, do: %{material_id: id, max_hp_per_macro: 100.0,
      defense: 2.0, tags: [], responses: [%{action: "damage", multiplier: 1.0}]}
    area = %{tool_id: 23, id: "area", action: "damage", power: 30.0,
      target_mode: "direction", range_macro: 3.0, interval_seconds: 0.8,
      area_offset_m: 2.0, area_radius_m: 1.0, aim_max_deg: 45.0,
      body_impact: %{depth: 0.2, protein_g: 2.0, heal_s: 100.0}}
    single = Map.merge(area, %{tool_id: 22, id: "melee", target_mode: "object", interval_seconds: 0.5})
    pick = %{tool_id: 1, id: "pick", action: "damage", power: 30.0, range_macro: 6.0, interval_seconds: 0.5}
    File.write!(catalog, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}],
      materials: materials, tools: [pick, single, area], definitions: []}))
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    cells = for x <- 0..7, y <- 0..7, z <- 0..15,
      into: <<>>, do: <<x::signed-little-32, y::signed-little-32, z::signed-little-32, 19::16-little>>
    bytes = <<"VXPD", 1::32-little, 1024::32-little, cells::binary, 0::32-little>>
    File.write!(Path.join(prefabs, "leaf.vxpd"), bytes)
    world = start_supervised!({World, source: Source, log: Log, root: root,
      observer: self(), property_catalog_path: catalog, prefab_catalog_path: prefabs, name: nil, gm_tools: true, liquid_bounds: {{-8, -8, -8}, {8, 8, 8}}, production_materials: [19]})
    actor = %{cid: 1001, gate: self(), identity: :test, refresh: &Actor.tool_context/2,
      eye: {0.5, 1.5, 0.5}, position: {0.5, 0.9, 0.5}, life_generation: 1, tick_us: 16_667, yaw: 0}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    actor = Map.merge(actor, %{received_us: 1_000_000, clock_node: node()})
    request = %{request_id: 1, client_intent_seq: 1, logical_scene_id: 1,
      action: 1, granularity: 6, direction: {1.0, 0.0, 0.0}, micro: {0, 0, 0},
      incarnation: 0, owner: {0, 0}, material: 0, tool_id: 23}
    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world, actor: actor, request: request, leaf: :crypto.hash(:sha256, bytes)}
  end

  # permitted 是 Scene 侧 Harm 许可标记（`SceneServer.Movement.ToolAction` 随候选传入）。
  defp body(id, position, life \\ 1), do: %{id: id, life_generation: life, position: position, profile: @profile, permitted: true}
  defp forbidden(id, position), do: %{body(id, position) | permitted: false}
  # g5 人物射线的遮挡复核（action 0 探测不占频率）：沿 +X 走 distance 米。
  defp probe(c, distance), do: World.body_tool(c.world, c.actor,
    %{c.request | granularity: 5, tool_id: 1, action: 0}, distance)
  defp ids({:area, _, hits}), do: Enum.map(hits, fn {target, :torso} -> target.id end)
  defp observe(c), do: VoxelRegion.TestSupport.observe(c.world, [1001], {{-1, -1, -1}, {6, 5, 5}})

  # 每次接纳一段都换新的入口时刻与序号，避免把频率当成被测对象。
  defp swing(c, bodies, at, changes) do
    actor = %{c.actor | received_us: at} |> Map.put(:area_targets, bodies)
    World.tool_intent(c.world, actor, Map.merge(c.request, Map.merge(%{request_id: at, client_intent_seq: div(at, 1000)}, changes)))
  end

  test "单体段：区内提示只选它；无提示或提示在区外时选离判定中心最近者，同距按 id", c do
    a = body(1, {2.5, 1.5, 0.5})   # 距中心 0
    b = body(2, {2.5, 1.5, 1.5})   # 距中心 1.0 ≤ 1.3
    out = body(3, {2.5, 1.5, 2.5}) # 距中心 2.0 > 1.3
    single = %{tool_id: 22}
    assert [2] = ids(swing(c, [b, out, a], 1_000_000, Map.merge(single, %{owner: {2, 0}, incarnation: 1})))
    assert [1] = ids(swing(c, [b, out, a], 2_000_000, single))
    assert [1] = ids(swing(c, [b, out, a], 3_000_000, Map.merge(single, %{owner: {3, 0}, incarnation: 1})))
    # B(2) 与 B'(5) 都距中心 1.0：同距取 id 小者。
    assert [2] = ids(swing(c, [body(5, {2.5, 1.5, -0.5}), b], 4_000_000, single))
  end

  test "区内无人时打空：接纳一次频率，不写世界，判定区内的墙／保护物／叶构件都不受损", c do
    assert {:ok, _} = World.place_prefab(c.world, c.leaf, {16, 8, 0}, 0)   # 叶构件占 {2,1,0}、{2,1,1}
    assert {:ok, _} = World.apply_edit(c.world, {3, 1, 0}, 19)
    assert {:ok, _} = World.author_regions(c.world, [%{holder: :reserved, min: {3, 0}, max: {3, 0}}])
    before = observe(c)
    assert {:area, seq, []} = World.tool_intent(c.world, c.actor, c.request)
    assert seq == before.seq
    assert observe(c).damage == before.damage and observe(c).seq == before.seq
    assert {:error, :replayed_attack} = World.tool_intent(c.world, c.actor, c.request)
    assert {:error, :tool_cooldown} = World.tool_intent(c.world, c.actor,
      %{c.request | client_intent_seq: 2, request_id: 2})
    # 单体段同样只打空，不按精确射线落到地形。
    assert {:area, ^seq, []} = swing(c, [], 5_000_000, %{tool_id: 22})
    assert observe(c).damage == before.damage
  end

  test "墙后对象不受击，提示也不采信；墙不变且无新事务", c do
    assert {:ok, _} = World.apply_edit(c.world, {2, 1, 0}, 19)
    before = observe(c)
    behind = body(1, {3.3, 1.5, 0.5}) # 距中心 0.8，在区内；眼点到它的射线穿过 {2,1,0}
    open = body(2, {2.5, 1.5, 1.5})   # 射线经 {1,1,0}、{1,1,1}、{2,1,1}，均为空
    assert [2] = ids(swing(c, [behind, open], 1_000_000, %{tool_id: 22, owner: {1, 0}, incarnation: 1}))
    assert [] = ids(swing(c, [behind], 2_000_000, %{tool_id: 22, owner: {1, 0}, incarnation: 1}))
    assert [2] = ids(swing(c, [behind, open], 3_000_000, %{}))
    assert observe(c).damage == before.damage and observe(c).seq == before.seq
  end

  test "观察日志：眼点、各候选位置／tick／遮挡结果、选中者与原因逐字段可读（只观测，不改裁决）", c do
    assert {:ok, _} = World.apply_edit(c.world, {2, 1, 0}, 19)
    behind = Map.put(body(1, {3.3, 1.5, 0.5}), :sim_tick, 70)
    open = Map.put(body(2, {2.5, 1.5, 1.5}), :sim_tick, 71)
    far = Map.put(body(3, {2.5, 1.5, 2.5}), :sim_tick, 72)
    c = %{c | actor: Map.put(c.actor, :sim_tick, 77)}
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    line = fn bodies, at, changes ->
      ExUnit.CaptureLog.capture_log(fn -> swing(c, bodies, at, changes) end)
    end

    hit = line.([behind, open, far], 1_000_000, %{tool_id: 22, owner: {1, 0}, incarnation: 1})
    assert hit =~ "actor_owner=1001 eye=0.500,1.500,0.500 actor_tick=77 hint=1/1 received_us=1000000 clock_node=#{node()} server_mono_us="
    assert hit =~ " c=1:3.300,1.500,0.500:70:occluded;2:2.500,1.500,1.500:71:clear;3:2.500,1.500,2.500:72:out chosen=2 reason=hit"

    blocked = line.([behind], 2_000_000, %{tool_id: 22})
    assert blocked =~ "hint=none"
    assert blocked =~ " c=1:3.300,1.500,0.500:70:occluded chosen=none reason=occluded"

    missed = line.([far], 3_000_000, %{})
    assert missed =~ " c=3:2.500,1.500,2.500:72:out chosen=none reason=miss_out_of_area"

    protected = line.([%{open | permitted: false}], 4_000_000, %{})
    assert protected =~ " c=2:2.500,1.500,1.500:71:clear chosen=none reason=not_permitted"

    refused = line.([open], 5_000_000, %{direction: {-1.0, 0.0, 0.0}})
    assert refused =~ "result=facing" and refused =~ "reason=facing" and refused =~ "eye=0.500,1.500,0.500 actor_tick=77"
  end

  test "液体不遮挡人物攻击：眼在水下、对象在水中，g6 判定区与 g5 人物射线都照常命中", c do
    # 同“墙后对象”手算：眼点 (0.5,1.5,0.5) 在 {0,1,0}；a 在 {2,1,0}，behind 的射线穿过 {2,1,0}；石墙遮挡由“墙后对象”覆盖。
    # 精确工具里液体对非相变工具透明，人物攻击同规则。
    a = body(1, {2.5, 1.5, 0.5})
    behind = body(2, {3.3, 1.5, 0.5})
    # 只测试：液体不能经普通编辑放置，经 GM 填满格水（同 parcel_world_test）。
    assert {:ok, _} = World.gm(c.world, "water", :fill, %{box: {{0, 1, 0}, {2, 1, 0}}, material: 21})
    assert [1, 2] = ids(swing(c, [a, behind], 1_000_000, %{}))
    assert :ok = probe(c, 2.8)
  end

  test "附件面遮挡：岩浆（液体、透明）后的人照常命中；岩浆迎面装上面附件后 g6 与 g5 都被挡", c do
    # 岩浆 22 是液体（对攻击透明）但可支撑附件，所以面附件是这里唯一的遮挡物。
    # 手算：射线 y=1.5、z=0.5（微格 12、4）沿 +X，越过 x=2 m（微格平面 16）处的面槽 {0,0,{16,12,4}}；
    # 面附件 size 8 锚点 {16,8,0} 覆盖平面 x=16 上 y∈[8,16)、z∈[0,8) 微格，由平面另一侧的岩浆宏格 {2,1,0} 支撑。
    behind = body(1, {3.3, 1.5, 0.5})
    assert {:ok, _} = World.gm(c.world, "lava", :fill, %{box: {{2, 1, 0}, {2, 1, 0}}, material: 22})
    assert [1] = ids(swing(c, [behind], 1_000_000, %{}))
    assert :ok = probe(c, 2.8)
    # 只测试：经正常附件意图（扣料、支撑裁决）安装，材料经既有供给入口一次写入。
    assert {:ok, _} = World.material_supply(c.world, 1001, "area-face", %{19 => 64})
    assert {:ok, _} = World.attachment_intent(c.world, c.actor, %{request_id: 900, client_intent_seq: 900,
      logical_scene_id: 1, action: 0, kind: 0, axis: 0, size: 8, anchor: {16, 8, 0}, id: 0, material: 19, tool_id: 1})
    assert [] = ids(swing(c, [behind], 2_000_000, %{}))
    assert {:error, :occluded} = probe(c, 2.8)
    # 眼点 x=0.5，面在 x=2：走 1.4 m 止于 x=1.9，不越过面槽。
    assert :ok = probe(c, 1.4)
  end

  test "Harm 标记：区内只有不可作用者拒绝 combat_not_permitted；有可作用者时只在其中选；区内无人仍打空", c do
    near = forbidden(1, {2.5, 1.5, 0.5}) # 距中心 0
    far = body(2, {2.5, 1.5, 1.5})       # 距中心 1.0
    out = forbidden(3, {2.5, 1.5, 2.5})  # 区外
    assert {:error, :combat_not_permitted} = swing(c, [near, out], 1_000_000, %{tool_id: 22})
    assert [2] = ids(swing(c, [near, far], 2_000_000, %{tool_id: 22}))
    assert [2] = ids(swing(c, [near, far], 3_000_000, %{tool_id: 22, owner: {1, 0}, incarnation: 1}))
    assert [2] = ids(swing(c, [near, far], 4_000_000, %{}))
    assert {:area, _, []} = swing(c, [out], 5_000_000, %{})
  end

  test "范围段：区内未锁定对象各作用一次，区外排除，锁定不缩成单体", c do
    a = body(1, {2.5, 1.5, 0.5})
    b = body(2, {2.5, 1.5, 1.5})
    behind = body(3, {-1.0, 1.5, 0.5})  # 距中心 3.5
    upstairs = body(4, {2.5, 4.0, 0.5}) # 轴段 y∈[3.4,4.6]，距中心 1.9
    assert [1, 2] = ids(swing(c, [a, a, b, behind, upstairs], 1_000_000, %{owner: {4, 0}, incarnation: 1}))
  end

  test "重生：旧生命提示剔除同 id 新生命候选，不作替补", c do
    reborn = body(2, {2.5, 1.5, 0.5}, 2)
    hint = %{tool_id: 22, owner: {2, 0}, incarnation: 1}
    assert {:area, _, []} = swing(c, [reborn], 1_000_000, hint)
    assert [1] = ids(swing(c, [reborn, body(1, {2.5, 1.5, 1.5})], 2_000_000, hint))
  end

  test "朝向：请求方向水平分量与已确认 yaw 前向夹角 ≤ aim_max_deg，超出拒绝且不消耗频率", c do
    deg = :math.pi() / 180
    # yaw 0 前向 +X；俯仰只被丢弃（见下一用例），{1,1,0} 的水平朝向仍是 +X。
    for {direction, at} <- [{{1.0, 0.0, 0.0}, 1_000_000}, {{:math.cos(30 * deg), 0.0, :math.sin(30 * deg)}, 2_000_000},
         {{:math.cos(30 * deg), 0.0, -:math.sin(30 * deg)}, 3_000_000}, {{1.0, 1.0, 0.0}, 4_000_000}],
      do: assert({:area, _, []} = swing(c, [], at, %{direction: direction}))
    for direction <- [{0.0, 0.0, 1.0}, {:math.cos(60 * deg), 0.0, :math.sin(60 * deg)}, {-1.0, 0.0, 0.0}],
      do: assert({:error, :facing} = swing(c, [], 5_000_000, %{direction: direction}))
    assert {:area, _, []} = swing(c, [], 5_000_000, %{})
    # yaw 16384 = 四分之一圈，前向 (cos 90°, 0, sin 90°) = +Z。
    turned = %{c | actor: %{c.actor | yaw: 16384}}
    assert {:error, :facing} = swing(turned, [], 6_000_000, %{})
    assert {:area, _, []} = swing(turned, [], 6_000_000, %{direction: {0.0, 0.0, 1.0}})
  end

  test "俯仰：判定球只沿水平朝向前移，伪造俯仰不能把球抬到眼点上方；竖直方向没有朝向即拒绝", c do
    # 手算：方向 (0.28,0.96,0) 水平朝向 +X → 球心 (2.5,1.5,0.5)。若按三维方向则球心 (1.06,3.42,0.5)。
    # 高处人物 up 站 (0.5,3.9,0.5)，轴段 y ∈ [3.3,4.5]：离三维球心 0.56 m（会入区），离水平球心 √(2²+1.8²)=2.69 m > 1.3（区外）。
    up = body(1, {0.5, 3.9, 0.5})
    assert [] = ids(swing(c, [up], 1_000_000, %{direction: {0.28, 0.96, 0.0}}))
    # 水平分量为零：旧实现 atan2(0,0)=0 当作 +X 放行，球心落到眼点正下方 2 m。
    for {direction, at} <- [{{0.0, -1.0, 0.0}, 2_000_000}, {{0.0, 1.0, 0.0}, 2_000_000}],
      do: assert({:error, :facing} = swing(c, [body(2, {0.5, -0.5, 0.5})], at, %{direction: direction}))
    # 近乎竖直但仍有水平分量 (0.001,-1,0)：投影为 +X，球心 (2.5,1.5,0.5)。身后下方 low 站 (-0.7,-0.5,0.5)
    # （水平身后 1.2 m）：三维球心 (0.502,-0.5,0.5) 离它 1.202 m ≤ 1.3 会入区；投影后离 3.33 m，不命中。
    low = body(3, {-0.7, -0.5, 0.5})
    assert [] = ids(swing(c, [low], 3_000_000, %{direction: {0.001, -1.0, 0.0}}))
  end

  test "yaw 回绕：已确认 yaw 超过 32768 时按最短角差复核", c do
    deg = :math.pi() / 180
    # yaw 49152 前向 -Z；(sin30°,0,-cos30°) 的方位 -60° ≡ 54613，角差 5461（30°）放行；+X 角差 90° 拒绝。
    south = %{c | actor: %{c.actor | yaw: 49152}}
    assert {:area, _, []} = swing(south, [], 1_000_000, %{direction: {0.0, 0.0, -1.0}})
    assert {:area, _, []} = swing(south, [], 2_000_000, %{direction: {:math.sin(30 * deg), 0.0, -:math.cos(30 * deg)}})
    assert {:error, :facing} = swing(south, [], 3_000_000, %{})
    # yaw 65000 与 +X（0）跨零相差 536（2.9°）放行；与 -Z（49152）相差 15848（87°）拒绝。
    wrapped = %{c | actor: %{c.actor | yaw: 65000}}
    assert {:area, _, []} = swing(wrapped, [], 3_000_000, %{})
    assert {:error, :facing} = swing(wrapped, [], 4_000_000, %{direction: {0.0, 0.0, -1.0}})
  end

  test "负坐标：判定区与遮挡射线在 -X/-Z 象限同样成立", c do
    # 手算：眼点 (-0.5,1.5,-0.5)、yaw 32768（前向 -X）→ 球心 (-2.5,1.5,-0.5)。墙 {-3,1,-1} 占 x∈[-3,-2]、z∈[-1,0]。
    # behind (-3.3,1.5,-0.5) 距中心 0.8：射线在 x=-2 处进墙。open (-2.5,1.5,0.5) 距中心 1.0：射线在 x=-1.5 处已越过 z=0，
    # 止于 (-2.232,1.5,0.366)，经 {-1,1,-1}、{-2,1,-1}、{-2,1,0}、{-3,1,0}，均为空。
    assert {:ok, _} = World.apply_edit(c.world, {-3, 1, -1}, 19)
    west = %{c | actor: %{c.actor | yaw: 32768, eye: {-0.5, 1.5, -0.5}, position: {-0.5, 0.9, -0.5}}}
    behind = body(1, {-3.3, 1.5, -0.5})
    open = body(2, {-2.5, 1.5, 0.5})
    assert [2] = ids(swing(west, [behind, open], 1_000_000, %{direction: {-1.0, 0.0, 0.0}}))
    assert [] = ids(swing(west, [behind], 2_000_000, %{direction: {-1.0, 0.0, 0.0}}))
  end

  test "附件面槽穿越：只记越过的整微格平面，含负坐标与双向" do
    alias VoxelRegion.Attachments
    # x 微格 -0.4 → 1.6 越过平面 0、1；y、z 微格 2.4 取 2。反向越过同一组面。
    expected = [{0, 0, {0, 2, 2}}, {0, 0, {1, 2, 2}}]
    assert Enum.sort(Attachments.faces_crossed({-0.05, 0.3, 0.3}, {0.2, 0.3, 0.3})) == expected
    assert Enum.sort(Attachments.faces_crossed({0.2, 0.3, 0.3}, {-0.05, 0.3, 0.3})) == expected
    # z 微格 -2.4 → -0.4 越过 -2、-1；x、y 微格 -2.4 取 -3。
    assert Enum.sort(Attachments.faces_crossed({-0.3, -0.3, -0.3}, {-0.3, -0.3, -0.05})) ==
      [{0, 2, {-3, -3, -2}}, {0, 2, {-3, -3, -1}}]
    # 不越过平面（同一微格内）没有面。
    assert Attachments.faces_crossed({0.01, 0.01, 0.01}, {0.1, 0.1, 0.1}) == []
  end

  test "非精确工具不能经精确射线作用地形", c do
    assert {:ok, _} = World.apply_edit(c.world, {2, 1, 0}, 19)
    query = %{c.request | granularity: 0, tool_id: 1, action: 0}
    assert {:ok, target} = World.tool_intent(c.world, c.actor, query)
    precise = Map.merge(query, Map.take(target, [:micro, :incarnation, :owner, :material]))
    before = observe(c)
    for tool <- [22, 23] do
      assert {:error, :invalid_tool} = World.tool_intent(c.world, c.actor,
        %{precise | tool_id: tool, action: 1, client_intent_seq: tool, request_id: tool})
    end
    assert observe(c).damage == before.damage and observe(c).seq == before.seq
  end

  test "频率按角色按工具独立：A 不挡 B，各自按自己的间隔", c do
    at = fn tool, us, seq -> swing(c, [], us, %{tool_id: tool, client_intent_seq: seq, request_id: seq}) end
    # A=22 间隔 0.5 s，B=23 间隔 0.8 s；tick 容差 16.667 ms。
    assert {:area, _, []} = at.(22, 1_000_000, 1)
    assert {:area, _, []} = at.(23, 1_000_000, 2)
    assert {:error, :tool_cooldown} = at.(22, 1_250_000, 3)
    assert {:area, _, []} = at.(22, 1_500_000, 4)
    assert {:error, :tool_cooldown} = at.(23, 1_500_000, 5)
    assert {:area, _, []} = at.(23, 1_800_000, 6)
    # 每个角色只监视一次；角色进程退出后该角色的全部工具频率一并清除。
    {:monitors, monitors} = Process.info(c.world, :monitors)
    assert Enum.count(monitors, &(&1 == {:process, c.actor.player})) == 1
    assert :ok = stop_supervised(Actor)
    assert :sys.get_state(c.world).tool_sessions == %{}
  end

  test "g6 闭包只含眼点射程区域，不把占位 micro {0,0,0} 当编辑坐标装原点各级页", c do
    # 手算：眼点 (640.5,1.5,640.5)、射程 3 → x/z ∈ [637.5,643.5] 跨区 9、10，y ∈ [-1.5,4.5] 跨区 -1、0。
    actor = %{c.actor | eye: {640.5, 1.5, 640.5}}
    expected = for x <- [9, 10], y <- [-1, 0], z <- [9, 10], do: {0, {x, y, z}}
    assert {:ok, keys} = VoxelRegion.World.Tools.intent_keys(:sys.get_state(c.world), {:tool_intent, actor, c.request})
    assert Enum.sort(keys) == Enum.sort(expected)
  end

  test "判定球心：负坐标眼点沿归一化水平朝向前移 offset，方向模长偏离 1 不扩大偏移" do
    alias VoxelRegion.World.AreaTool
    tool = %{"area_offset_m" => 2.0}
    assert AreaTool.center({-2.0, 3.0, -4.0}, {0.0, 0.0, -1.004}, tool) == {-2.0, 3.0, -6.0}
  end

  test "旧来源生命拒绝，已采样段不混入源后续姿态", c do
    a = body(1, {2.5, 1.5, 0.5})
    assert {:error, :stale_life} = World.tool_intent(c.world,
      Map.merge(c.actor, %{life_generation: 0, area_targets: [a]}), c.request)
    # 只测试：Actor是已声明姿态替身；这里控制两次权威采样，不冒充玩家移动验证。
    assert :ok = GenServer.call(c.actor.player, {:eye, {20.5, 1.5, 0.5}})
    assert [1] = ids(World.tool_intent(c.world, Map.put(c.actor, :area_targets, [a]), c.request))
  end
end
