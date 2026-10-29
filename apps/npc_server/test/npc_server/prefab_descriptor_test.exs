defmodule NpcServer.PrefabDescriptorTest do
  @moduledoc "只测试：NPC 目录投影直接消费 World 轻描述；不启动 World、数据库、模型或渲染器。"
  use ExUnit.Case, async: true
  alias NpcServer.Perception

  test "catalog row keeps dimensions and bill with no nodes or original definition" do
    id = :binary.copy(<<7>>, 32)

    summary = %{
      bounds: {{-8, 0, 0}, {8, 16, 24}},
      macro_cells: 1,
      micro_cells: 2,
      nodes: 1,
      depth: 1,
      attachment_slots: 3
    }

    descriptor = %{
      summary: summary,
      has_macro_cells: true,
      presentation_bindings: [],
      material_counts: %{
        micro: %{19 => 2},
        macro: %{11 => 1},
        attachments: %{{0, 19} => 3}
      }
    }

    properties = %{
      attachments: %{"material_units_per_micro" => 10, "face_units" => 2, "edge_units" => 1}
    }

    assert Perception.prefab_row(id, descriptor, properties) == %{
             definition_id: id,
             summary: summary,
             size_m: [2.0, 2.0, 3.0],
             materials: %{
               units: %{11 => 5120, 19 => 26},
               volume_m3: %{11 => 1.0, 19 => 26 / 5120}
             }
           }
  end
end
