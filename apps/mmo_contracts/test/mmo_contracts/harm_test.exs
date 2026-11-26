defmodule MmoContracts.HarmTest do
  @moduledoc """
  只测试：`MmoContracts.Harm` 的许可规则（魔法 v2 切片 6 由 scene_server 原样迁入，行为不变）。
  期望来自规则本身：范围是半开盒 `[下界, 上界)`，来源与目标都在盒内才允许；`nil` 范围一律禁止。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Harm

  @scope {{0.0, 0.0, 0.0}, {10.0, 10.0, 10.0}}

  test "未配置战斗范围：本场不开放，任何作用都不允许" do
    refute Harm.open?(nil)
    refute Harm.permitted?(nil, {1.0, 1.0, 1.0}, {2.0, 2.0, 2.0})
  end

  test "来源与目标都在半开盒内才允许；下界含、上界不含" do
    assert Harm.open?(@scope)
    assert Harm.permitted?(@scope, {0.0, 0.0, 0.0}, {9.999, 5.0, 5.0})
    refute Harm.permitted?(@scope, {10.0, 5.0, 5.0}, {5.0, 5.0, 5.0})
    refute Harm.permitted?(@scope, {5.0, 5.0, 5.0}, {5.0, -0.001, 5.0})
  end
end
