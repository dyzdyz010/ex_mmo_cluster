defmodule VoxelRegion.BinaryRetentionTest do
  @moduledoc "只测试：`BinaryRetention` 判定器本身必须能区分切片、独立小值与独立大值；纯函数，不启动 World。"
  use ExUnit.Case, async: true
  alias VoxelRegion.TestSupport.BinaryRetention

  # 手算：父对象 8192 字节（refc），切出 1024 字节 -> 切片存活时父对象的 8192 字节被拖住。
  test "大切片拖住 8192 字节父对象，被判定为 8192" do
    assert BinaryRetention.max_retained_bytes(fn -> binary_part(:binary.copy(<<1>>, 8192), 100, 1024) end) == 8192
  end

  test "位串匹配切出的大切片同样报告完整父对象" do
    assert BinaryRetention.max_retained_bytes(fn ->
             <<_::binary-size(100), slice::binary-size(1024), _::binary>> = :binary.copy(<<1>>, 8192)
             slice
           end) == 8192
  end

  test "大切片复制成独立 binary 后不再拖住父对象，只报告自身大小" do
    assert BinaryRetention.max_retained_bytes(fn ->
             :binary.copy(binary_part(:binary.copy(<<1>>, 8192), 100, 1024))
           end) == 1024
  end

  test "<= 64 字节的切片在该 VM 上本就是独立 heap binary" do
    assert BinaryRetention.max_retained_bytes(fn -> binary_part(:binary.copy(<<1>>, 8192), 100, 40) end) == 0
  end
end
