Code.require_file("support/thermal_reference.exs", __DIR__)

defmodule VoxelRegion.ThermalReferenceTest do
  @moduledoc "只测试：纯历史判定反例；缺点、错值、错平台必须拒绝，不启动 World 或数据库。"
  use ExUnit.Case, async: true
  alias VoxelRegion.TestSupport.ThermalReference

  @windows %{10.0 => "windows-10", 20.0 => "common-20"}
  @linux %{10.0 => "linux-10", 20.0 => "common-20"}

  test "每个声明的历史时点都必须存在，缺一点不能以交集过半通过" do
    assert {:error, {:missing_reference_point, 20.0}} =
             ThermalReference.compare(Map.delete(@windows, 20.0), @windows)
  end

  test "完整参考接受额外观察，任何一个历史点错值仍明确失败" do
    assert :ok = ThermalReference.compare(Map.put(@windows, 15.0, "extra"), @windows)
    assert {:error, {:digest_mismatch, 10.0, "windows-10", "changed"}} =
             ThermalReference.compare(Map.put(@windows, 10.0, "changed"), @windows)
  end

  test "平台在读取输出前选定，不能接受另一平台恰好匹配的表" do
    assert {:ok, %{profile: :windows, recorded: expected}} =
             ThermalReference.radiation({:win32, :nt}, @windows, @linux)
    assert expected == @windows
    assert {:error, {:digest_mismatch, 10.0, "windows-10", "linux-10"}} =
             ThermalReference.compare(@linux, expected)

    assert {:ok, %{profile: :linux, recorded: expected}} =
             ThermalReference.radiation({:unix, :linux}, @windows, @linux)
    assert expected == @linux
    assert {:error, {:digest_mismatch, 10.0, "linux-10", "windows-10"}} =
             ThermalReference.compare(@windows, expected)
  end

  test "没有已声明历史参照的平台明确拒绝" do
    assert {:error, {:unsupported_reference_platform, {:unix, :darwin}}} =
             ThermalReference.radiation({:unix, :darwin}, @windows, @linux)
  end
end
