defmodule VoxelRegion.BodyContactTest do
  @moduledoc """
  只测试：身体接触换热的纯规则（魔法增量 4，Voxim Docs/Magic.md §6）。期望全部手算：

  - 鞋底：0.03 / (0.06 + 0.5/25) = 0.375 W/K（石 k 25）；0.03 / (0.06 + 0.5/150) = 0.47368421 W/K（木 k 150）；
  - 浸没：A 1.8 m²、身高 1.8 m、重叠 1.8 m → 1.8 / (0.03 + 1/100) = 45 W/K；重叠 0.8 m → 20 W/K；
  - 触碰：r 0.4 m、k_s 400 → 0.01 / (0.4/400) = 10 W/K。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.BodyContact

  test "三类接触导热按串联式手算" do
    assert_in_delta BodyContact.sole(25, 0.5), 0.375, 1.0e-12
    assert_in_delta BodyContact.sole(150, 0.5), 0.03 / (0.06 + 0.5 / 150), 1.0e-12
    assert BodyContact.sole(0, 0.5) == 0.0
    assert_in_delta BodyContact.immersion(1.8, 1.8, 1.8), 45.0, 1.0e-9
    assert_in_delta BodyContact.immersion(1.8, 0.8, 1.8), 20.0, 1.0e-9
    assert_in_delta BodyContact.touch(0.4, 400), 10.0, 1.0e-9
    assert BodyContact.touch(0.4, 0) == 0.0
  end

  test "浸没高度：身体 [1, 2.8) 与两格水（满、八成）的重叠" do
    assert BodyContact.overlap(1.0, 1.8, 1, 1.0) == 1.0
    assert_in_delta BodyContact.overlap(1.0, 1.8, 2, 1.0), 0.8, 1.0e-12
    assert_in_delta BodyContact.overlap(1.0, 1.8, 2, 0.5), 0.5, 1.0e-12
    assert BodyContact.overlap(1.0, 1.8, 3, 1.0) == 0.0
    # 脚在格中（1.25）：只算格内水面以下
    assert_in_delta BodyContact.overlap(1.25, 1.8, 1, 0.5), 0.25, 1.0e-12
  end

  test "拟态与身体胶囊：轴线段 [脚 + r, 脚 + 身高 − r] 上的最近点距离" do
    feet = {0.5, 1.0, 0.5}
    # 球心高 1.4 m 落在轴线段高度内：最近点 (0.5, 1.4, 0.5)，水平距 0.6 ≤ 0.4 + 0.3
    assert BodyContact.touching?({1.1, 1.4, 0.5}, 0.4, feet, 1.8, 0.3)
    # 水平距 0.75 m > 0.7
    refute BodyContact.touching?({1.25, 1.4, 0.5}, 0.4, feet, 1.8, 0.3)
    # 头顶上方：最近点 (0.5, 2.5, 0.5)，球心 (0.5, 3.3, 0.5) 距离 0.8 > 0.7
    refute BodyContact.touching?({0.5, 3.3, 0.5}, 0.4, feet, 1.8, 0.3)
    assert BodyContact.touching?({0.5, 3.1, 0.5}, 0.4, feet, 1.8, 0.3)
  end
end
