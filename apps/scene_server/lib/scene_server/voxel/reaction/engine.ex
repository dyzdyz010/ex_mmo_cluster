defmodule SceneServer.Voxel.Reaction.Engine do
  @moduledoc """
  涌现反应求值器(功能完善 · 反应层 R1 起,R5a 泛化 tag_reaction + 多效果)。

  **纯函数,驱动无关**:输入"已提交 truth 的 cell 状态列表"+ 反应规则,输出反应效果列表(交由
  `SystemActor` 分流提交)。只读 `MaterialCatalog`(纯数据)解析阈值,不触进程/IO。

  cell:`%{macro_index, material_id, temperature_celsius, burn_progress, tags}`(温度摄氏;
  burn_progress 比率 0..1,缺省 0;tags atom list 缺省 [])。

  效果(物化后):
    * `{:transform_material, %{macro_index, from_material_id, to_material_id, rule_id}}`
    * `{:set_tag, %{macro_index, add: [atom], remove: [atom], rule_id}}`(同 cell tag 增删合一)
    * `{:write_voxel_attribute, %{attribute: :temperature, macro_index, heat_energy_joules}}`(连续注热)
    * `{:write_voxel_attribute, %{attribute: name, macro_index, delta}}`(动态属性累进,如 burn_progress)

  相变:一 cell 至多一相变(取最高 priority)。tag_reaction:一 cell 可中多条 → 多效果(tag 增删合一)。
  """

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Reaction.Rule

  @type cell :: %{
          required(:macro_index) => integer(),
          required(:material_id) => integer(),
          required(:temperature_celsius) => number(),
          optional(:burn_progress) => number(),
          optional(:tags) => [atom()]
        }
  @type reaction_effect :: {atom(), map()}

  @doc "对所有 cell 求所有规则,返回反应效果列表(按 cell 输入序)。"
  @spec evaluate([cell()], [Rule.t()]) :: [reaction_effect()]
  def evaluate(cells, rules) when is_list(cells) and is_list(rules) do
    Enum.flat_map(cells, &evaluate_cell(&1, rules))
  end

  defp evaluate_cell(cell, rules) do
    phase_effects = phase_effects(cell, rules)
    tag_effects = tag_effects(cell, rules)
    phase_effects ++ tag_effects
  end

  # ---- 相变(phase_transition):至多一,最高 priority ----

  defp phase_effects(cell, rules) do
    case first_matching_transition(cell, rules) do
      nil -> []
      rule -> [transform_effect(rule.to_material, rule.id, cell)]
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

  # ---- 标签/状态反应(tag_reaction):可多条 ----

  defp tag_effects(cell, rules) do
    matched =
      rules
      |> Enum.filter(&(&1.kind == :tag_reaction))
      |> Enum.filter(&tags_match?(&1, cell))
      |> Enum.filter(&condition_holds?(&1.condition, cell))

    templates = Enum.flat_map(matched, fn rule -> Enum.map(rule.effects, &{rule.id, &1}) end)
    materialize(templates, cell)
  end

  defp tags_match?(%Rule{require_tags: req, forbid_tags: forbid}, cell) do
    tags = cell_tags(cell)
    Enum.all?(req, &(&1 in tags)) and not Enum.any?(forbid, &(&1 in tags))
  end

  defp cell_tags(%{tags: tags}) when is_list(tags), do: tags
  defp cell_tags(_cell), do: []

  # 物化效果模板:tag 增删合并为一条 set_tag;其余逐条。
  defp materialize(templates, cell) do
    {tag_adds, tag_removes, others} =
      Enum.reduce(templates, {[], [], []}, fn
        {_id, {:add_tag, tag}}, {a, r, o} -> {[tag | a], r, o}
        {_id, {:remove_tag, tag}}, {a, r, o} -> {a, [tag | r], o}
        {id, other}, {a, r, o} -> {a, r, [{id, other} | o]}
      end)

    tag_effect = set_tag_effect(Enum.reverse(tag_adds), Enum.reverse(tag_removes), cell)
    other_effects = others |> Enum.reverse() |> Enum.map(&materialize_other(&1, cell))

    tag_effect ++ other_effects
  end

  defp set_tag_effect([], [], _cell), do: []

  defp set_tag_effect(adds, removes, cell) do
    [{:set_tag, %{macro_index: cell.macro_index, add: adds, remove: removes}}]
  end

  defp materialize_other({_id, {:emit_heat_joules, joules}}, cell) do
    {:write_voxel_attribute,
     %{attribute: :temperature, macro_index: cell.macro_index, heat_energy_joules: joules * 1.0}}
  end

  defp materialize_other({_id, {:advance_attribute, attr, delta}}, cell) do
    {:write_voxel_attribute,
     %{attribute: attr, macro_index: cell.macro_index, delta: delta * 1.0}}
  end

  defp materialize_other({id, {:transform, to_material}}, cell) do
    transform_effect(to_material, id, cell)
  end

  # ---- 共用 ----

  defp condition_holds?(nil, _cell), do: true

  # R5d:未知材料(不在 catalog)不参与 material_threshold 反应——否则缺省阈值 0 会反转惰性安全
  # (未知材料在任意温度 ≥0 点燃/熔化)。未知材料 = 无定义行为 = 惰性,条件不成立。
  defp condition_holds?(
         {field, op, {:material_threshold, attr}},
         %{material_id: material_id} = cell
       ) do
    if MaterialCatalog.known_material?(material_id) do
      compare(op, field_value(field, cell), resolve_threshold({:material_threshold, attr}, cell))
    else
      false
    end
  end

  defp condition_holds?({field, op, threshold}, cell) do
    compare(op, field_value(field, cell), resolve_threshold(threshold, cell))
  end

  defp field_value(:temperature, cell), do: temperature_celsius(cell)
  defp field_value(:burn_progress, cell), do: burn_progress(cell)

  defp temperature_celsius(%{temperature_celsius: t}) when is_number(t), do: t * 1.0
  defp temperature_celsius(_cell), do: 0.0

  defp burn_progress(%{burn_progress: p}) when is_number(p), do: p * 1.0
  defp burn_progress(_cell), do: 0.0

  defp resolve_threshold({:celsius, value}, _cell), do: value * 1.0
  defp resolve_threshold({:value, value}, _cell), do: value * 1.0

  defp resolve_threshold({:material_threshold, attr}, %{material_id: material_id}) do
    raw = MaterialCatalog.default_attribute_value(material_id, attr, 0)
    raw / MaterialCatalog.fixed32_scale()
  end

  defp compare(:gte, a, b), do: a >= b
  defp compare(:gt, a, b), do: a > b
  defp compare(:lte, a, b), do: a <= b
  defp compare(:lt, a, b), do: a < b

  defp transform_effect(to_material, rule_id, cell) do
    {:transform_material,
     %{
       macro_index: cell.macro_index,
       from_material_id: cell.material_id,
       to_material_id: MaterialCatalog.material_id(to_material),
       rule_id: rule_id
     }}
  end
end
