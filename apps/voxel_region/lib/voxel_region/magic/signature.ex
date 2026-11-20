defmodule VoxelRegion.Magic.Signature do
  @moduledoc """
  符号组合魔法 v2（切片 0a）：类型签名解释器（设计 §3.2、§3.3 的 T1–T3、T7、T9、T12 结构类检查）。

  只解释目录 v5 的签名数据，不按符号 id 写任何分支；客户端（C++）解释同一份目录，双端用冻结样本对拍。
  输入是 `Program.diagnose_ir/2` 已完成字节级校验（段归属、规范顺序、槽区间）的结构组，这里只做组内结构检查：

  1. 汇总本组提供的标签：`provides` 加上按槽取值命中的 `provides_by_param`。
  2. 目录级 `group_requires_all`：每组必须具备的标签（表达“恰好 1 个〈形〉、恰好 1 个〈蓄〉”）。
  3. 逐个符号实例检查 `requires_all`、`requires_any`、`requires_by_param`、`excludes`、`refs`。
  4. 逐个符号检查组内次数 `max_per_group` 与 `unique_by`；逐条规则检查 `max_per_rule`。

  数值类检查（T5、T6 位置、T13、T14、T15）不在这里，由服务端报价（Cost）给出。

  输出全部违规（设计 v2.5 S3），每条带原因码、组序号、步序号、符号与细节（未满足的标签等）。
  **步序号**是该符号实例在本组规范字节中的 0 起序号：形成锚为 0，其后依次是参考锚、形、质、能、动各段，
  再按优先级逐条规则的读数、响应、〈否〉内联响应。它与 Cost 按“段序 + 最近姿态贪心”排出的构造步号无关
  （签名在报价之前，构造顺序尚不存在）。次数类违规（`max_per_group`、`unique_by`、`max_per_rule`）对每个
  超出的实例各报一条，即第一个超限实例及其后各个。
  """

  alias VoxelRegion.Magic.Program.{Glyph, Group, Rule}

  @typedoc """
  一条违规：组序号、步序号（组级检查为 `nil`）、符号 id（组级检查为 `nil`）、原因码（检查名）与细节
  （未满足或冲突的标签、超出的次数、未满足的引用声明）。
  """
  @type violation :: %{group: non_neg_integer(), step: non_neg_integer() | nil, symbol: String.t() | nil,
          check: atom(), detail: term()}

  @doc """
  检查程序的全部结构组；返回 `:ok`，或 `{:error, [violation]}`（列出全部违规，供编辑器提示与日志诊断）。
  顺序：按组；组内依次为组级、逐实例（按步序号）、组内次数（按下标）、规则内次数（按优先级）。
  """
  @spec check([Group.t()], VoxelRegion.Magic.Catalog.t()) :: :ok | {:error, [violation()]}
  def check(groups, catalog) do
    groups
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, position} -> group_violations(group, position, catalog) end)
    |> case do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  defp group_violations(%Group{} = group, position, catalog) do
    placed = placements(group, catalog)
    tags = MapSet.new(Enum.flat_map(placed, &provided(&1.glyph, &1.symbol)))

    group_level =
      case missing(catalog.group_requires_all, tags) do
        [] -> []
        missing -> [violation(position, nil, nil, :group_requires_all, missing)]
      end

    per_glyph = Enum.flat_map(placed, &glyph_violations(&1, tags, position))

    per_symbol =
      placed
      |> Enum.group_by(& &1.glyph.index)
      |> Enum.sort()
      |> Enum.flat_map(fn {_, instances} -> symbol_violations(instances, position) end)

    per_rule =
      placed
      |> Enum.filter(&(&1.priority != nil))
      |> Enum.group_by(&{&1.priority, &1.glyph.index})
      |> Enum.sort()
      |> Enum.flat_map(fn {{priority, _}, instances} -> rule_violations(instances, priority, position) end)

    group_level ++ per_glyph ++ per_symbol ++ per_rule
  end

  # 本组每个符号实例：所在规则的优先级（段内符号为 nil，供 `refs` 与 `max_per_rule`）与步序号（规范字节中的序号）。
  defp placements(group, catalog) do
    segments = [group.form_anchor | group.ref_anchors ++ group.shape ++ group.quality ++ group.energy ++ group.motion]
    in_rules = for rule <- group.rules, glyph <- rule_glyphs(rule), do: {glyph, rule.priority}

    (Enum.map(segments, &{&1, nil}) ++ in_rules)
    |> Enum.with_index()
    |> Enum.map(fn {{glyph, priority}, step} ->
      %{glyph: glyph, symbol: catalog.symbols[glyph.index], priority: priority, step: step}
    end)
  end

  defp rule_glyphs(%Rule{} = rule), do: rule.readings ++ rule.responses ++ List.wrap(rule.backup_response)

  defp provided(glyph, symbol), do: symbol.provides ++ by_param(symbol.provides_by_param, glyph, symbol)

  defp glyph_violations(%{glyph: glyph, symbol: symbol, priority: priority, step: step}, tags, position) do
    any_met = symbol.requires_any == [] or Enum.any?(symbol.requires_any, &(missing(&1, tags) == []))

    [
      {:requires_all, missing(symbol.requires_all, tags)},
      {:requires_any, if(any_met, do: [], else: symbol.requires_any)},
      {:requires_by_param, missing(by_param(symbol.requires_by_param, glyph, symbol), tags)},
      {:excludes, Enum.filter(symbol.excludes, &MapSet.member?(tags, &1))},
      {:refs, Enum.reject(symbol.refs, &earlier?(&1, glyph, symbol, position, priority))}
    ]
    |> Enum.reject(fn {_, detail} -> detail == [] end)
    |> Enum.map(fn {check, detail} -> violation(position, step, symbol.id, check, detail) end)
  end

  # 引用规则（设计 §11.4.3 第 6 条；v2.5 S1、v2.6 S4）：“在前”指严格在前；组引用 < 本组序号，规则引用 < 本规则
  # 优先级。不另判越界：越界的值必然不在前，同样以 `refs` 报出。0xFF（无）解码为 nil，总是满足；
  # 字节层已保证 `refs_enabled = false` 的槽只能是 0xFF。
  defp earlier?(ref, glyph, symbol, position, priority) do
    case {param_value(glyph, symbol, ref.param), ref.kind} do
      {nil, _} -> true
      {value, :group} -> value < position
      {value, :rule} -> priority != nil and value < priority
    end
  end

  defp symbol_violations([%{symbol: symbol} | _] = instances, position) do
    over =
      if symbol.max_per_group != nil,
        do: excess(instances, symbol.max_per_group, position, :max_per_group, length(instances)),
        else: []

    # unique_by：键值已在前面实例出现过的实例各报一条。
    duplicate =
      if symbol.unique_by == [] do
        []
      else
        instances
        |> Enum.map(&{&1, Enum.map(symbol.unique_by, fn name -> param_value(&1.glyph, symbol, name) end)})
        |> Enum.reduce({MapSet.new(), []}, fn {instance, key}, {seen, acc} ->
          if MapSet.member?(seen, key),
            do: {seen, [violation(position, instance.step, symbol.id, :unique_by, symbol.unique_by) | acc]},
            else: {MapSet.put(seen, key), acc}
        end)
        |> elem(1)
        |> Enum.reverse()
      end

    over ++ duplicate
  end

  defp rule_violations([%{symbol: symbol} | _] = instances, priority, position) do
    if symbol.max_per_rule != nil,
      do: excess(instances, symbol.max_per_rule, position, :max_per_rule, {priority, length(instances)}),
      else: []
  end

  # 超出次数上限的实例（第 max + 1 个起）各报一条。
  defp excess(instances, max, position, check, detail) do
    instances
    |> Enum.drop(max)
    |> Enum.map(&violation(position, &1.step, &1.symbol.id, check, detail))
  end

  # `*_by_param` 命中：取值键为枚举名、整数的十进制字符串；已写入的值另外匹配 "present"（schema 文档 §5）。
  defp by_param(table, glyph, symbol) do
    for {slot_name, by_key} <- table,
        key <- value_keys(param_value(glyph, symbol, slot_name)),
        tag <- Map.get(by_key, key, []),
        do: tag
  end

  defp value_keys(nil), do: []
  defp value_keys(value) when is_binary(value), do: [value, "present"]
  defp value_keys(value) when is_integer(value), do: [Integer.to_string(value), "present"]

  defp param_value(%Glyph{params: params}, symbol, slot_name) do
    slot = Enum.find(symbol.params, &(&1.name == slot_name))
    Map.fetch!(params, slot.key)
  end

  defp missing(required, tags), do: Enum.reject(required, &MapSet.member?(tags, &1))

  defp violation(position, step, id, check, detail),
    do: %{group: position, step: step, symbol: id, check: check, detail: detail}
end
