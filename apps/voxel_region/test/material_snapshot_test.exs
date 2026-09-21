defmodule VoxelRegion.MaterialSnapshotTest do
  @moduledoc "只测试：材料观察不要求热、液体、数据库或全场景夹具。"
  use ExUnit.Case, async: true
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.Source

  test "通过作者入口准备样本，观察只包含所请求的格且不改事务位置" do
    root = Path.join(System.tmp_dir!(), "material_snapshot_#{System.pid()}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    world = start_supervised!({World, root: root, source: Source, observer: self(), name: nil})
    assert {:ok, 1} = World.apply_edits(world, [{{1, 1, 1}, 11}, {{2, 1, 1}, 19}])
    snapshot = World.material_snapshot(world, [1001], [{1, 1, 1}])
    assert snapshot.seq == 1
    assert snapshot.material_balances == []
    assert snapshot.probe_occupancy == [%{cell: [1, 1, 1], material: 11, refined: false, slots: [], placed_by: nil}]
    assert World.seq(world) == 1
  end
end
