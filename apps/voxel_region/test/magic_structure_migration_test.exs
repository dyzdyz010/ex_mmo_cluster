defmodule VoxelRegion.MagicStructureMigrationTest do
  @moduledoc """
  只测试：旧存档拟态的一次性迁移（魔法 v2 切片 4c，决策稿 `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md`
  Q4-6、§13 W4-5）。

  - 契约：World 恢复时若持久化的 `thermal` 仍带 `semblances`，每个拟态按旧规则的剩余能量散入空气、记
    `semblance_released_j`，并以一笔热事务删除该键；只迁移一次，之后的重启不再有迁移事务。
  - 夹具：`fixtures/semblance_migration/overlay.log` 由 master 62d9a5a5（Hello 45、魔法 v1）经正式施法入口录制
    （录制器与复现命令见同目录 `record_62d9a5a5_helper.exs`）：手边静止光球 `{8, 0}` 与落在石地面上的热投掷球 `{6, 0}`。
    期望值取自同目录 `world.json`——录制时用 master 自己的 `Semblance.stored_j/2` 对持久化的最后一份 `thermal` 算出，
    不在这里复算旧公式。材料与热环境夹具与录制时逐字节相同（录制器断言），魔法目录换成本分支的 v5 发布物。
  - 驱动：真实 World 冷启动（`Log` = 文件日志），手动时钟，不推进热提交；观察走 `TestSupport.observe/3` 的热账与日志回放。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias VoxelRegion.{OverlayLog, World}
  alias VoxelRegion.TestSupport.{Log, Source}

  @fixtures Path.expand("fixtures", __DIR__)
  @dir Path.join(@fixtures, "semblance_migration")
  @recorded Path.join(@dir, "world.json") |> File.read!() |> Jason.decode!()
  @external_resource Path.join(@dir, "world.json")
  @external_resource Path.join(@dir, "overlay.log")
  @catalog Path.expand("../priv/magic", __DIR__) |> Path.join("*.json") |> Path.wildcard() |> then(fn [path] -> path end)
  @box {{-2, -2, -2}, {2, 2, 2}}

  defmodule ManualClock do
    @moduledoc "只测试：不推进的时钟，World 不会自行开始热提交。"
    @behaviour VoxelRegion.World.Clock
    @impl true
    def now(_), do: 0
    @impl true
    def schedule(_, _, _, _), do: make_ref()
    @impl true
    def cancel(_, _), do: false
  end

  setup do
    root = Path.join(System.tmp_dir!(), "structure_migration_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join([@fixtures, @recorded["catalogs"]["properties"]["file"]]), Path.join(root, "properties.json"))
    File.cp!(Path.join([@fixtures, @recorded["catalogs"]["thermal_environment"]["file"]]), Path.join(root, "environment.json"))
    File.cp!(@catalog, Path.join(root, "magic.json"))
    File.cp!(Path.join(@dir, "overlay.log"), Path.join(root, "overlay.log"))
    %{root: root}
  end

  defp start(root) do
    start_supervised!(
      {World,
       [
         source: Source,
         log: Log,
         root: root,
         observer: self(),
         name: nil,
         clock: {ManualClock, nil},
         property_catalog_path: Path.join(root, "properties.json"),
         thermal_environment_path: Path.join(root, "environment.json"),
         magic_catalog_path: Path.join(root, "magic.json")
       ]},
      id: :world
    )
  end

  defp info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  # 持久化日志里带 `thermal` 的事务（回放顺序）。
  defp thermal_txns(root),
    do: Path.join(root, "overlay.log") |> OverlayLog.File.replay() |> Enum.filter(&Map.has_key?(&1, :thermal))

  test "W4-5 旧拟态恢复时一次散解：semblances 键消失、一笔迁移事务、semblance_released_j 增加存量能量；再重启不重复", c do
    final_seq = @recorded["final_seq"]
    stored = @recorded["stored_j_sum"]
    # 前提：夹具最后一份 thermal 带两个拟态，尚无释放账。
    assert %{semblances: old} = List.last(thermal_txns(c.root)).thermal
    assert old |> Map.keys() |> Enum.sort() == Enum.sort(Enum.map(@recorded["semblances"], &List.to_tuple(&1["id"])))
    assert @recorded["ledger"]["semblance_released_j"] == 0

    log = info_log(fn -> start(c.root) end)
    assert log =~ "voxel_structure_migrated seq=#{final_seq + 1} count=2 released_j=#{stored}"
    migrated = List.last(thermal_txns(c.root))
    assert migrated.seq == final_seq + 1
    refute Map.has_key?(migrated.thermal, :semblances)
    assert_in_delta migrated.thermal.semblance_released_j, stored, 1.0e-6
    # 创建账不变：迁移只把存量转入释放账。
    assert migrated.thermal.semblance_created_j == @recorded["ledger"]["semblance_created_j"]

    :ok = stop_supervised(:world)
    log = info_log(fn -> start(c.root) end)
    refute log =~ "voxel_structure_migrated"
    assert List.last(thermal_txns(c.root)).seq == final_seq + 1
  end

  test "迁移后的世界经观察契约读到同一释放账（窗口外观察也不再出现拟态）", c do
    w = start(c.root)
    s = VoxelRegion.TestSupport.observe(w, [1001], @box)
    assert_in_delta s.thermal.semblance_released_j, @recorded["stored_j_sum"], 1.0e-6
    refute Map.has_key?(s, :semblances)
  end
end
