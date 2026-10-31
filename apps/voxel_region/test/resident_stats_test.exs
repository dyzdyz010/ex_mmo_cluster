defmodule VoxelRegion.ResidentStatsTest do
  @moduledoc """
  只测试：真实 World + 文件日志验证统计的驻留口径，不覆盖数据库、物理演化或客户端。
  经作者编辑建立远处页，compact 后真实重启；只读进程状态用于确认观察没有装页，不注入真值。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{OverlayLog, World}
  alias VoxelRegion.TestSupport.Source

  test "冷页统计明确局部覆盖且不装页，正常读入才改变驻留内容" do
    root = Path.join(System.tmp_dir!(), "resident_stats_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [source: Source, root: root, observer: self(), name: nil, log: OverlayLog.File]
    world = start_supervised!({World, opts})
    initial = World.stats(world)
    coord = {1282, 129, -127}
    assert {:ok, _} = World.apply_edits(world, [{coord, 19}])
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, opts})

    before = :sys.get_state(world).resident
    cold = World.stats(world)
    assert cold.scope == %{canonical_data: "resident_pages", cache: "process_local", runtime: "world", disk: "not_counted"}
    assert initial.scope.canonical_data == "loaded_persistent_state"
    assert cold.overlay_cells == 0
    assert cold.region_bases == 0
    assert cold.resident_pages == 0
    assert cold.page_loads == 0
    assert cold.page_waiters == 0
    assert cold.published_seq == 1
    stats_preserved_resident = :sys.get_state(world).resident == before
    assert stats_preserved_resident
    assert World.stats(world).resident_pages == 0

    assert [%{material: 19}] = World.material_snapshot(world, [], [coord]).probe_occupancy
    warm = World.stats(world)
    assert warm.scope == cold.scope
    assert warm.region_bases > cold.region_bases
    assert warm.overlay_cells == cold.overlay_cells
    assert warm.resident_pages > cold.resident_pages
    assert warm.published_seq == cold.published_seq
    assert Jason.decode!(Jason.encode!(warm.scope))["disk"] == "not_counted"

    if out = System.get_env("RESIDENT_STATS_OBSERVE_DIR") do
      File.mkdir_p!(out)
      File.write!(Path.join(out, "stats.json"), Jason.encode!(%{cold: cold, warm: warm,
        stats_preserved_resident: stats_preserved_resident}))
    end
  end
end
