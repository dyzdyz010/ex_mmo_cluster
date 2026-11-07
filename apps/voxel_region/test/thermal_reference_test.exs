Code.require_file("support/thermal_reference.exs", __DIR__)

defmodule VoxelRegion.ThermalReferenceTest do
  @moduledoc "只测试：纯历史判定反例；缺点、错值必须拒绝，不启动 World 或数据库。"
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.TestSupport.ThermalReference

  @recorded %{10.0 => "digest-10", 20.0 => "digest-20"}

  test "每个声明的历史时点都必须存在，缺一点不能以交集过半通过" do
    assert {:error, {:missing_reference_point, 20.0}} =
             ThermalReference.compare(Map.delete(@recorded, 20.0), @recorded)
  end

  test "完整参考接受额外观察，任何一个历史点错值仍明确失败" do
    assert :ok = ThermalReference.compare(Map.put(@recorded, 15.0, "extra"), @recorded)
    assert {:error, {:digest_mismatch, 10.0, "digest-10", "changed"}} =
             ThermalReference.compare(Map.put(@recorded, 10.0, "changed"), @recorded)
  end
end
