defmodule VoxelRegion.ThermalWork do
  @moduledoc """
  全局系统功能：可丢弃的热候选域、接触图复用与内核索引。

  只消费该职责的值，不读取 World 或保存温度、HP、燃料真值。
  几何缺键表示需要 owner 重新读取；空列表表示已经派生的空气或无热容量占用。
  """
  alias VoxelRegion.{Attachments, Damage, Thermal, ThermalGeometry}

  @doc "创建空派生缓存；冷恢复、附件或目录变化时可直接重建。"
  def new do
    %{
      hot: MapSet.new(),
      cells: MapSet.new(),
      geometry: %{},
      edges: [],
      builds: 0,
      seeds: nil,
      ordered: [],
      attachment_cells: nil,
      attachment_graph: nil,
      solid_nodes: %{},
      thermal_slots: %{},
      indexed_edges: []
    }
  end

  @doc "目标涉及的全部 canonical 宏格，附件可跨宏格和区域。"
  def cells(%{granularity: 4} = target), do: Attachments.macros([Attachments.slot(target)])
  def cells(target), do: [Damage.macro(target)]

  @doc "从当前温度与燃烧记录派生热种子，不持有属性真值。"
  def hot(damage, config) do
    for {_, row} <- damage,
        Map.get(row, :burning, false) or
          (Map.has_key?(row, :temperature_kelvin) and
             abs(row.temperature_kelvin - config["ambient_kelvin"]) > config["tolerance_kelvin"]),
        cell <- cells(row),
        into: MapSet.new(),
        do: cell
  end

  @doc "合并活动种子，选择六邻域及缺失几何；返回值交 owner 读取本次 canonical 摘要。"
  def plan(work, sources, powers, damage) do
    electric =
      for {key, _} <- powers,
          cell <-
            (case key do
               {4, {type, p}} -> Attachments.macros([{div(type, 3), rem(type, 3), p}])
               {_, p} -> [Damage.macro(%{micro: p})]
             end),
          into: MapSet.new(),
          do: cell

    burning =
      for {_, row} <- damage,
          Map.get(row, :burning, false),
          cell <- cells(row),
          into: MapSet.new(),
          do: cell

    seeds =
      work.hot
      |> MapSet.union(MapSet.new(Map.keys(sources)))
      |> MapSet.union(electric)
      |> MapSet.union(burning)

    cells =
      if seeds == work.seeds,
        do: work.cells,
        else: seeds |> Enum.flat_map(&[&1 | Thermal.neighbors(&1)]) |> MapSet.new()

    # 几何键原本恰好覆盖旧域；编辑只删键。未变且未删键时不遍历几何。
    reuse = cells == work.cells and map_size(work.geometry) == MapSet.size(cells)

    %{
      seeds: seeds,
      cells: cells,
      missing:
        if(reuse,
          do: MapSet.new(),
          else: MapSet.difference(cells, MapSet.new(Map.keys(work.geometry)))
        ),
      geometry: if(reuse, do: work.geometry, else: Map.take(work.geometry, MapSet.to_list(cells)))
    }
  end

  @doc "接纳本次完整几何，返回更新的缓存和是否需要重新构造附件接触图。"
  def refresh(work, plan, geometry, attachments) do
    attachment_cells =
      work.attachment_cells ||
        Enum.map(attachments, fn {slot, value} -> {slot, value, Attachments.macros([slot])} end)

    {nodes, slots, rebuild?} =
      if plan.cells == work.cells and MapSet.size(plan.missing) == 0 do
        {work.solid_nodes, work.thermal_slots, false}
      else
        nodes = geometry |> Map.values() |> List.flatten() |> Map.new()

        slots =
          for {slot, value, footprint} <- attachment_cells,
              Enum.any?(footprint, &MapSet.member?(plan.cells, &1)),
              into: %{},
              do: {slot, value}

        # 仅空气扩缩域可复用；旧域内编辑即使无热节点，也可能改变附件暴露面。
        reuse =
          MapSet.disjoint?(plan.missing, work.cells) and
            nodes == work.solid_nodes and slots == work.thermal_slots

        {nodes, slots, not reuse}
      end

    {%{
       work
       | geometry: geometry,
         cells: plan.cells,
         seeds: plan.seeds,
         attachment_cells: attachment_cells,
         solid_nodes: nodes,
         thermal_slots: slots,
         builds: work.builds + MapSet.size(plan.missing)
     }, rebuild?}
  end

  @doc "按原节点遍历顺序生成每对一次的接触和索引，保持浮点累加顺序。"
  def index(work, nodes, attachment_graph) do
    ordered = Enum.to_list(nodes)
    edges = ThermalGeometry.contacts(nodes)
    indices = ordered |> Enum.with_index() |> Map.new(fn {{key, _}, i} -> {key, i} end)

    %{
      work
      | ordered: ordered,
        edges: edges,
        indexed_edges:
          for({a, b, g} <- edges, do: {Map.fetch!(indices, a), Map.fetch!(indices, b), g}),
        attachment_graph: attachment_graph
    }
  end
end
