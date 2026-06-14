defmodule SceneServer.Voxel.Reaction.Engine do
  @moduledoc """
  涌现反应求值器(功能完善 · 反应层 R1)。

  **纯函数,驱动无关**:输入"已提交 truth 的 cell 状态列表"+ 反应规则,输出反应效果列表(交由
  `SystemActor` 锁存提交)。本模块只读 `MaterialCatalog`(纯数据)解析阈值,不触进程/IO。

  cell:`%{macro_index, material_id, temperature_celsius, tags}`(温度已转摄氏;tags 可空)。
  效果:`{:transform_material, %{macro_index, from_material_id, to_material_id, rule_id}}`。

  一个 cell 一 tick 至多一次相变(同格只有一种材料 → 一种转变),取**最高 priority** 的命中规则。
  """

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Reaction.Rule

  @type cell :: %{
          required(:macro_index) => integer(),
          required(:material_id) => integer(),
          required(:temperature_celsius) => number(),
          optional(:tags) => [atom()]
        }
  @type reaction_effect :: {:transform_material, map()}

  @doc "对所有 cell 求所有规则,返回反应效果列表(顺序按 cell 输入序)。"
  @spec evaluate([cell()], [Rule.t()]) :: [reaction_effect()]
  def evaluate(cells, rules) when is_list(cells) and is_list(rules) do
    Enum.flat_map(cells, &evaluate_cell(&1, rules))
  end

  defp evaluate_cell(cell, rules) do
    case first_matching_transition(cell, rules) do
      nil -> []
      rule -> [transform_effect(rule, cell)]
    end
  end

  defp first_matching_transition(cell, rules) do
    rules
    |> Enum.filter(&(&1.kind == :phase_transition))
    |> Enum.filter(&from_material_matches?(&1, cell))
    |> Enum.sort_by(& &1.priority, :desc)
    |> Enum.find(&condition_holds?(&1.condition, cell))
  end

  defp from_material_matches?(%Rule{from_material: name}, %{material_id: id}) do
    MaterialCatalog.material_id(name) == id
  end

  defp condition_holds?({:temperature, op, threshold}, cell) do
    compare(op, temperature_celsius(cell), resolve_threshold(threshold, cell))
  end

  defp temperature_celsius(%{temperature_celsius: t}) when is_number(t), do: t * 1.0
  defp temperature_celsius(_cell), do: 0.0

  defp resolve_threshold({:celsius, value}, _cell), do: value * 1.0

  defp resolve_threshold({:material_threshold, attr}, %{material_id: material_id}) do
    raw = MaterialCatalog.default_attribute_value(material_id, attr, 0)
    raw / MaterialCatalog.fixed32_scale()
  end

  defp compare(:gte, a, b), do: a >= b
  defp compare(:gt, a, b), do: a > b
  defp compare(:lte, a, b), do: a <= b
  defp compare(:lt, a, b), do: a < b

  defp transform_effect(%Rule{} = rule, cell) do
    {:transform_material,
     %{
       macro_index: cell.macro_index,
       from_material_id: cell.material_id,
       to_material_id: MaterialCatalog.material_id(rule.to_material),
       rule_id: rule.id
     }}
  end
end
