defmodule VoxelRegion.CollisionStreamBoxTest do
  @moduledoc "只测试：窗口滞回的 XYZ、负坐标、边界与远距移动；不替代真实 Player 流送实跑。"
  use ExUnit.Case, async: true
  alias VoxelRegion.CollisionStream

  test "亭子坡道跨过 Y=512 时保留已覆盖的窗口" do
    window = {{0, 7, 0}, {3, 10, 3}}
    assert CollisionStream.box({101.6, 513.16, 64.6}, 1) == window
    for y <- [511.9, 510.4, 513.16, 510.4] do
      assert CollisionStream.box({100.0, y, 74.0}, 1, window) == window
    end
  end

  test "各轴跨出四分之一 tile 滞回带时重新居中，负坐标仍向下取整" do
    window = {{-1, -1, -1}, {2, 2, 2}}
    for axis <- 0..2 do
      assert CollisionStream.box(put_elem({32.0, 32.0, 32.0}, axis, -16.0), 1, window) == window
      assert CollisionStream.box(put_elem({32.0, 32.0, 32.0}, axis, 79.999), 1, window) == window
      below = {put_elem({-1, -1, -1}, axis, -2), put_elem({2, 2, 2}, axis, 1)}
      above = {put_elem({-1, -1, -1}, axis, 0), put_elem({2, 2, 2}, axis, 3)}
      assert CollisionStream.box(put_elem({32.0, 32.0, 32.0}, axis, -16.001), 1, window) == below
      assert CollisionStream.box(put_elem({32.0, 32.0, 32.0}, axis, 80.0), 1, window) == above
    end
    assert CollisionStream.box({-129.0, 257.0, -65.0}, 1, window) == {{-4, 3, -3}, {-1, 6, 0}}
  end
end
