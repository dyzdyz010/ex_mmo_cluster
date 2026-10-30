defmodule VoxelRegion.RawEditAccessTest do
  @moduledoc """
  只测试：原始格编辑的统一授权（`VoxelRegion.Access`，设计稿 2026-10-30-server-authorization-design.md）。

  场景复现 2026-10-30 的缺陷：author_regions 建立与如园同坐标的 reserved 区域后，玩家会话的原始编辑曾被直接提交。
  现在的期望：
  - 玩家角色（Gate 会话）做原始编辑 → `forbidden`，世界不变；
  - 创世 NPC 做原始编辑 → 受保护区约束：进保留区 `protected_region`，野外照常提交；
  - 运维做原始编辑 → 不受保护区约束（维护与作者用途）；
  - 对照：同格的角色工具挖掘、生产放置仍被保护区拒绝。

  范围：真实 World / 保护区 / 提交 / 文件日志；不启动应用、数据库、QUIC 或客户端。
  Gate 把玩家原始编辑交给 World 后收到 forbidden 帧，由 gate_server 的 `movement_route_test.exs` 覆盖。
  替身：空地形 Source、角色上下文 Actor、静止 WorldClock。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport
  alias VoxelRegion.TestSupport.{Actor, Log, Source, WorldClock}
  alias MmoContracts.Voxel.Payload

  @stone 11
  @cid 1001
  # 两格都在如园保留区内（宏格 x 3848..4127, z 4..321）
  @cell {3988, 10, 162}
  @other {3989, 10, 162}
  # 保留区以西的野外
  @wild {3840, 10, 162}
  @box {{62, 0, 2}, {63, 1, 3}}
  @region %{holder: :reserved, min: {3848, 4}, max: {4127, 321}}
  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"

  setup c do
    root =
      Path.join(
        System.tmp_dir!(),
        "raw_edit_access_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    clock = start_supervised!({WorldClock, 0})

    w =
      start_supervised!(
        {World,
         source: Source,
         log: Log,
         root: root,
         observer: self(),
         name: nil,
         clock: {WorldClock, clock},
         gm_tools: false,
         property_catalog_path: Path.join(__DIR__, "fixtures/combustion/#{@catalog}.json"),
         thermal_environment_path:
           Path.join(__DIR__, "fixtures/combustion/environment-radiation.json"),
         prefab_catalog_path: nil,
         production_materials: [@stone]}
      )

    initial = if c[:dig], do: [@cell, @other], else: [{3988, 9, 162}, {3989, 9, 162}]
    assert {:ok, _} = World.apply_edits(w, Enum.map(initial, &{&1, @stone}))
    assert {:ok, _} = World.author_regions(w, [@region])
    %{w: w}
  end

  for {kind, dig} <- [{:single, true}, {:single, false}, {:batch, true}, {:batch, false}] do
    @tag dig: dig
    test "玩家角色原始 #{kind} #{if dig, do: "挖", else: "放"} 被拒绝为 forbidden", c do
      before = observe(c.w)
      assert {:error, :forbidden} = raw_edit(c.w, {:character, @cid}, unquote(kind), unquote(dig))
      assert observe(c.w) == before
    end
  end

  @tag dig: true
  test "创世 NPC 原始编辑进保留区被拒绝为 protected_region", c do
    before = observe(c.w)
    assert {:error, :protected_region} = raw_edit(c.w, {:genesis, @cid}, :batch, true)
    assert {:error, :protected_region} = raw_edit(c.w, {:genesis, @cid}, :single, true)
    assert observe(c.w) == before
  end

  test "创世 NPC 原始编辑在野外照常提交", c do
    seq = World.seq(c.w)
    assert {:ok, next} = World.apply_edits(c.w, {:genesis, @cid}, [{@wild, @stone}])
    assert next == seq + 1
  end

  @tag dig: true
  test "运维原始编辑不受保护区约束", c do
    seq = World.seq(c.w)
    assert {:ok, next} = World.apply_edits(c.w, :operator, [{@cell, 0}])
    assert next == seq + 1
    assert {@cell, 0} in observe(c.w).cells
  end

  @tag dig: true
  test "对照：同格带角色工具挖掘被保护区拒绝", c do
    a = actor()

    q = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {0.0, -1.0, 0.0},
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }

    assert {:ok, target} = World.tool_intent(c.w, a, q)
    assert VoxelRegion.Damage.macro(target) == @cell

    request =
      Map.merge(q, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.put(:action, 1)

    before = observe(c.w)
    assert {:error, :protected_region} = World.tool_intent(c.w, a, request)
    assert observe(c.w) == before
  end

  test "对照：同格带角色生产放置被保护区拒绝", c do
    before = observe(c.w)

    assert {:error, :protected_region} =
             World.production_intent(c.w, actor(), %{
               request_id: 1,
               client_intent_seq: 1,
               logical_scene_id: 1,
               action: 1,
               material: @stone,
               tool_id: 1,
               coord: @cell
             })

    assert observe(c.w) == before
  end

  defp raw_edit(w, principal, :single, dig),
    do: World.apply_edit(w, principal, @cell, material(dig))

  defp raw_edit(w, principal, :batch, dig),
    do: World.apply_edits(w, principal, [{@cell, material(dig)}, {@other, material(dig)}])

  defp material(true), do: 0
  defp material(false), do: @stone

  defp actor do
    a = %{
      cid: @cid,
      gate: self(),
      identity: make_ref(),
      refresh: &Actor.tool_context/2,
      eye: {3988.5, 12.5, 162.5},
      tick_us: 16_667,
      received_us: 1_000_000,
      clock_node: node()
    }

    Map.put(a, :player, start_supervised!({Actor, a}))
  end

  # 世界可见状态：事务序号、两格材料与保护区；拒绝必须让三者都不变。
  defp observe(w) do
    payload = TestSupport.payload(w, 0, {62, 0, 2})

    cells =
      Enum.map([@cell, @other], fn {x, y, z} = coord ->
        {coord, Payload.material(payload, {x - 62 * 64 + 1, y + 1, z - 2 * 64 + 1})}
      end)

    %{
      seq: World.seq(w),
      cells: cells,
      protection: World.simulation_snapshot(w, [], @box).protection
    }
  end
end
