defmodule DataService.Voxel.RegionEpochStoreTest do
  # 共享 voxel_region_epochs 表,async:false + 每测试清表。
  use ExUnit.Case, async: false

  alias DataService.Voxel.RegionEpochStore

  setup do
    RegionEpochStore.reset()
    :ok
  end

  test "allocate_next 首次为 1,其后单调 +1(CELL-18/23)" do
    assert 1 = RegionEpochStore.allocate_next(1, 10)
    assert 2 = RegionEpochStore.allocate_next(1, 10)
    assert 3 = RegionEpochStore.allocate_next(1, 10)
  end

  test "不同 region 独立计数" do
    assert 1 = RegionEpochStore.allocate_next(1, 10)
    assert 1 = RegionEpochStore.allocate_next(1, 20)
    assert 2 = RegionEpochStore.allocate_next(1, 10)
    assert 1 = RegionEpochStore.allocate_next(2, 10)
  end

  test "current 反映已分配值,未分配为 0" do
    assert 0 = RegionEpochStore.current(1, 99)
    RegionEpochStore.allocate_next(1, 99)
    RegionEpochStore.allocate_next(1, 99)
    assert 2 = RegionEpochStore.current(1, 99)
  end

  test "set_floor 把 epoch 抬到不低于 floor(迁移收敛),不回退" do
    assert 5 = RegionEpochStore.set_floor(1, 30, 5)
    # 已是 5,floor=3 不回退
    assert 5 = RegionEpochStore.set_floor(1, 30, 3)
    # 之后 allocate 从 6 继续
    assert 6 = RegionEpochStore.allocate_next(1, 30)
  end

  test "并发 allocate_next 不产生重复 epoch(线性化)" do
    parent = self()

    tasks =
      for _ <- 1..20 do
        Task.async(fn -> RegionEpochStore.allocate_next(9, 9) end)
      end

    epochs = Enum.map(tasks, &Task.await/1)
    _ = parent

    assert Enum.sort(epochs) == Enum.to_list(1..20)
    assert length(Enum.uniq(epochs)) == 20
  end
end
