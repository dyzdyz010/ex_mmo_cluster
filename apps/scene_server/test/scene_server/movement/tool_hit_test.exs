defmodule SceneServer.Movement.ToolHitTest do
  use ExUnit.Case, async: true
  alias SceneServer.Movement.ToolHit

  test "球扫掠当前胶囊：半径、起始重叠、短段外和移动后的擦过" do
    p = %{radius: 0.3, half_height: 0.9}
    assert {:ok, t} = ToolHit.sweep({0.0, 0.0, 0.0}, {3.0, 0.0, 0.0}, 0.2, {2.0, 0.0, 0.0}, p)
    assert_in_delta t, 0.5, 1.0e-12
    assert {:ok, 0.0} = ToolHit.sweep({1.6, 0.0, 0.0}, {1.7, 0.0, 0.0}, 0.2, {2.0, 0.0, 0.0}, p)
    assert :miss = ToolHit.sweep({0.0, 0.0, 0.0}, {1.49, 0.0, 0.0}, 0.2, {2.0, 0.0, 0.0}, p)
    assert :miss = ToolHit.sweep({0.0, 0.0, 0.0}, {3.0, 0.0, 0.0}, 0.2, {2.0, 0.0, 0.501}, p)
  end

  test "Y-up 胶囊正中、擦边和负坐标平移" do
    profile = %{radius: 0.3, half_height: 0.9}

    assert {:ok, distance, :torso} =
             ToolHit.ray({0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {2.0, 0.0, 0.0}, profile, 3.0)

    assert_in_delta distance, 1.7, 1.0e-9

    assert {:ok, distance, :torso} =
             ToolHit.ray({-4.0, -3.0, -2.0}, {1.0, 0.0, 0.0}, {-2.0, -3.0, -1.7}, profile, 3.0)

    assert_in_delta distance, 2.0, 1.0e-7
    assert :miss = ToolHit.ray({0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {2.0, 0.0, 0.301}, profile, 3.0)
    assert :miss = ToolHit.ray({0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {2.0, 0.0, 0.0}, profile, 1.69)
  end

  test "竖直射线命中端球，部位按胶囊局部高度" do
    p = %{radius: 0.3, half_height: 0.9}

    assert {:ok, t, :head} =
             ToolHit.ray({0.0, 2.0, 0.0}, {0.0, -1.0, 0.0}, {0.0, 0.0, 0.0}, p, 3.0)

    assert_in_delta t, 1.1, 1.0e-9

    assert {:ok, _, :legs} =
             ToolHit.ray({-2.0, -0.7, 0.0}, {1.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, p, 3.0)
  end
end
