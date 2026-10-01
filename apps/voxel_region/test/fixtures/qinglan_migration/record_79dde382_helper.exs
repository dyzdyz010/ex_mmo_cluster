# 只测试（Test-only）：青岚迁移夹具的录制器，不在当前 master 上运行（_helper.exs 被 mix test 忽略）。
#
# 用途：当前服务端已对 circuit.install／circuit.feed 一律返回 :retired_tool，无法再造出“在用并已投煤的工具 19 电源”。
# 所以用青岚 0923 版服务端源码 79dde382（目录 4b2c6abe 实际运行的版本）经正式入口录一份 overlay 日志：
#   作者编辑铺地 → material_supply 记账供料（铜、煤） → attachment_intent 付费放铜面 → tool_intent 工具 19 安装 → 工具 8 投料两次。
#
# 复现（WSL，worktree 在 79dde382）：
#   cp record_79dde382_helper.exs <old>/apps/voxel_region/test/r809c_record_test.exs
#   OUT=<本目录> mix test --no-start test/r809c_record_test.exs      # 在 <old>/apps/voxel_region 下，MIX_ENV=test
# 输出：overlay.log、world.json（面身份、锚点、投料前后读数，供新测试核对）。
defmodule VoxelRegion.R809cRecordTest do
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @catalog "4b2c6abeaec3818e2203a0b95e3ee03f1cf1aed6bf796c5f33ab41001eb641ed"
  @stone 11
  @coal 15
  @copper 24
  @anchor {40, 8, 0}

  test "record a Qinglan-catalog world with an in-use, fed 480 V source (tool 19)" do
    out = System.fetch_env!("OUT")
    root = Path.join(System.tmp_dir!(), "r809c_record_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.cp!(Path.join(out, "../combustion/#{@catalog}.json"), Path.join(root, "properties.json"))
    env = Path.join(root, "environment.json")
    # 青岚 0923 热环境（ε 0，平衡容差 1 K）；79dde382 尚无辐射字段。
    File.write!(env, Jason.encode!(%{ambient_kelvin: 293.15, environment_w_per_m2_k: 10, tolerance_kelvin: 1}))

    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"), thermal_environment_path: env,
      production_materials: [@stone, @coal, @copper]]})
    actor = %{cid: 1001, gate: self(), identity: :record, refresh: &Actor.tool_context/2, eye: {5.5, 1.75, 0.5}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    stamp = fn seq -> Map.merge(actor, %{received_us: seq * 1_000_000, clock_node: node()}) end

    {:ok, _} = World.apply_edits(w, for(x <- -1..6, z <- 0..4, do: {{x, 0, z}, @stone}))
    {:ok, _} = World.material_supply(w, 1001, "r809c-fixture", %{@copper => 512 * 4096, @coal => 3 * 4 * 4096})

    face = %{request_id: 10, client_intent_seq: 10, logical_scene_id: 1, action: 0,
      kind: 0, axis: 1, size: 8, anchor: @anchor, id: 0, material: @copper, tool_id: 1}
    {:ok, _} = World.attachment_intent(w, stamp.(10), face)
    [{id, _}] = Enum.uniq(for {{0, 1, _}, v} <- :sys.get_state(w).attachments, do: v)

    use = fn tool, seq ->
      r = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1, tool_id: tool,
        direction: {0.0, -1.0, 0.0}, micro: @anchor, granularity: 3, incarnation: id, owner: {id, 1}, material: @copper}
      World.tool_intent(w, stamp.(seq), r)
    end
    {:ok, _} = use.(19, 20)
    {:ok, _} = use.(8, 21)
    {:ok, _} = use.(8, 22)
    s = :sys.get_state(w)
    c = s.damage[{3, id}].circuit
    {tool, remaining} = {c.tool_id, c.remaining_j}
    coal_left = Map.get(s.material_balances, {1001, @coal}, 0)
    seq = s.seq
    :ok = stop_supervised(World)

    File.cp!(Path.join(root, "overlay.log"), Path.join(out, "overlay.log"))
    File.write!(Path.join(out, "world.json"), Jason.encode!(%{
      catalog: @catalog, source: %{id: id, anchor: Tuple.to_list(@anchor), tool_id: tool, remaining_j: remaining},
      coal_left_units: coal_left, seq: seq,
      recorded_by: "ex_mmo_cluster 79dde382 (Qinglan 0923 server), test/fixtures/qinglan_migration/record_79dde382_helper.exs"}, pretty: true))
    File.rm_rf!(root)
  end
end
