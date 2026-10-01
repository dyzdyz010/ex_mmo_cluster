# 只测试（Test-only）：master 时代热电世界夹具的录制器，不在当前代码上运行（_helper.exs 被 mix test 忽略）。
#
# 用途：R8-04 增量 3 之后、R8-09 片 1 之前（master 7bfd0bba）的世界里，热账已有累计的 circuit_thermoelectric_j，
# 但没有 circuit_peltier_absorbed_j／circuit_peltier_released_j。升级后两个佩尔捷键从 0 起算，热电做功接着累加，
# 所以“吸热 − 放热 = 做功”只对升级后的增量成立。当前代码会写佩尔捷键，造不出这样的检查点，故用 7bfd0bba 录制。
#
# 装置（z = 2，地面 y = 0 石）：煤 (1,3,2) 垫石柱 (1,1,2)(1,2,2)，热铜 H (2,3,2)，热电石 (3,3,2)，冷铜 C (4,3,2)；
# 回路 H→热电石→C→合金 (4,2,2)→铜 (4,1,2)(3,1,2)(2,1,2)(2,2,2)→H。Test-only 记账供煤 2 宏格（1 格建造、余量供 K 点火扣煤），正式建造放下后 K 点燃，
# 推进热提交直到热电做功 > 1e4 J，压实成检查点，挂起 World 取无进行中提交的状态写 world.json，然后停。
#
# 复现（WSL，源码树在 7bfd0bba）：
#   cp record_7bfd0bba_helper.exs <old>/apps/voxel_region/test/r809a_record_test.exs
#   OUT=<本目录> mix test --no-start test/r809a_record_test.exs      # 在 <old>/apps/voxel_region 下，MIX_ENV=test
# 输出：overlay.log、world.json（录制版本、目录、末 seq、热账里热电做功与佩尔捷键是否存在）。
defmodule VoxelRegion.R809aRecordTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 600_000
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @catalog "b88329ab0d3652c30f67d012fce04fd30afd7fd6dcc263e5066ba0b08f90284f"
  @cap 2_097_152
  @stone 11
  @coal 15
  @copper 24
  @alloy 40
  @te 43

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp frozen(w) do
    :sys.suspend(w)
    s = :sys.get_state(w)
    if s.thermal_run == nil, do: s, else: (:sys.resume(w); Process.sleep(2); frozen(w))
  end

  defp frames(path, n), do: frames_in(File.read!(path), n)
  defp frames_in(<<>>, n), do: n
  defp frames_in(<<len::32, _::binary-size(len), rest::binary>>, n), do: frames_in(rest, n + 1)

  test "record a master-era (7bfd0bba) world whose thermal ledger already carries thermoelectric work" do
    out = System.fetch_env!("OUT")
    combustion = Path.join(out, "../combustion")
    root = Path.join(System.tmp_dir!(), "r809a_record_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    File.cp!(Path.join(combustion, @catalog <> ".json"), Path.join(root, "properties.json"))
    File.cp!(Path.join(combustion, "environment-radiation.json"), Path.join(root, "environment.json"))
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"), thermal_environment_path: Path.join(root, "environment.json"),
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [@stone, @coal, @copper, @alloy, @te]]})
    a = %{cid: 1001, gate: self(), identity: :record, refresh: &Actor.tool_context/2, eye: {1.5, 4.5, 2.5}, tick_us: 16_667}
    a = Map.put(a, :player, start_supervised!({Actor, a}))

    ground = for x <- -1..6, z <- 0..4, do: {{x, 0, z}, @stone}
    cells = [{{1, 1, 2}, @stone}, {{1, 2, 2}, @stone}, {{2, 3, 2}, @copper}, {{3, 3, 2}, @te}, {{4, 3, 2}, @copper},
      {{4, 2, 2}, @alloy}, {{4, 1, 2}, @copper}, {{3, 1, 2}, @copper}, {{2, 1, 2}, @copper}, {{2, 2, 2}, @copper}]
    {:ok, _} = World.apply_edits(w, ground ++ cells)
    {:ok, _} = World.material_supply(w, 1001, "r809a-fixture", %{@coal => 2 * @cap})
    seq = next()
    {:ok, _} = World.production_intent(w, Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1, material: @coal, tool_id: 1, coord: {1, 3, 2}})

    ignite = fn ignite, n ->
      q = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 0, tool_id: 9,
        direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
      {:ok, target} = World.tool_intent(w, a, q)
      s = next()
      r = Map.merge(q, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
        |> Map.merge(%{action: 1, request_id: s, client_intent_seq: s})
      case World.tool_intent(w, Map.merge(a, %{received_us: s * 1_000_000, clock_node: node()}), r) do
        {:ok, _} -> ignite.(ignite, n + 1)
        {:error, :already_burning} -> n
      end
    end
    clicks = ignite.(ignite, 0)
    true = clicks >= 1

    Enum.reduce_while(1..4000, nil, fn _, _ ->
      send(w, :thermal_commit)
      t = VoxelRegion.World.simulation_snapshot(w, [1001], {{-2, -2, -2}, {2, 2, 2}}).thermal_accounting
      if Map.get(t, :circuit_thermoelectric_j, 0.0) > 1.0e4, do: {:halt, t}, else: {:cont, t}
    end)
    # 压实成检查点：投递检查点计时器到期消息（生产路径的 60 s 维护计时器，这里不等它自然到期），日志变成一帧完整检查点。
    s = frozen(w)
    true = s.checkpoint_timer != nil
    send(w, {:timeout, s.checkpoint_timer, :checkpoint})
    :sys.resume(w)
    s = frozen(w)
    true = s.checkpoints > 0
    te = s.thermal.circuit_thermoelectric_j
    true = te > 1.0e4
    refute Map.has_key?(s.thermal, :circuit_peltier_absorbed_j)
    refute Map.has_key?(s.thermal, :circuit_peltier_released_j)
    :sys.resume(w)
    :ok = stop_supervised(World)
    File.cp!(Path.join(root, "overlay.log"), Path.join(out, "overlay.log"))
    File.write!(Path.join(out, "world.json"), Jason.encode!(%{
      recorded_by: "ex_mmo_cluster 7bfd0bba (master, after R8-04 increment 3, before R8-09 slice 1), test/fixtures/thermoelectric_master/record_7bfd0bba_helper.exs",
      catalog: @catalog, seq: s.seq, checkpoints: s.checkpoints, frames: frames(Path.join(out, "overlay.log"), 0), clicks: clicks, elapsed_s: s.thermal.elapsed_s, circuit_thermoelectric_j: te,
      peltier_keys_present: false}, pretty: true))
    File.rm_rf!(root)
  end
end
