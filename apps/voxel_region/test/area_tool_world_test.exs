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
      area_offset_m: 2.0, area_radius_m: 1.0, aim_max_deg: 45.0}
    single = Map.merge(area, %{tool_id: 22, id: "melee", target_mode: "object", interval_seconds: 0.5,
      body_impact: %{depth: 0.2, protein_g: 2.0, heal_s: 100.0}})
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
      observer: self(), property_catalog_path: catalog, prefab_catalog_path: prefabs, name: nil})
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

  defp body(id, position, life \\ 1), do: %{id: id, life_generation: life, position: position, profile: @profile}
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
    # yaw 0 前向 +X；俯仰不复核。
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

  test "微格盒相交包含负坐标边界，归一化方向不扩大偏移" do
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
