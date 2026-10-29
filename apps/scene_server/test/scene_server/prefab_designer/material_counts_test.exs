defmodule SceneServer.PrefabDesigner.MaterialCountsTest do
  @moduledoc "只测试：手算轻目录材料计数的计价，不启动 World、数据库、模型或渲染器。"
  use ExUnit.Case, async: true
  alias SceneServer.PrefabDesigner.Check

  @properties %{
    attachments: %{"material_units_per_micro" => 10, "face_units" => 2, "edge_units" => 1}
  }

  test "descriptor counts preserve micro, macro and attachment costs without geometry" do
    descriptor = %{
      material_counts: %{
        micro: %{11 => 2, 19 => 1},
        macro: %{11 => 1},
        attachments: %{{0, 19} => 3, {1, 19} => 2}
      }
    }

    # 材料 11：2*10 + 1*8³*10；材料 19：1*10 + 3*2 + 2*1。
    assert Check.materials(descriptor, @properties) == %{
             units: %{11 => 5140, 19 => 18},
             volume_m3: %{11 => 5140 / 5120, 19 => 18 / 5120}
           }
  end

  test "empty descriptor counts do not invent materials" do
    descriptor = %{material_counts: %{micro: %{}, macro: %{}, attachments: %{}}}
    assert Check.materials(descriptor, @properties) == %{units: %{}, volume_m3: %{}}
  end
end
