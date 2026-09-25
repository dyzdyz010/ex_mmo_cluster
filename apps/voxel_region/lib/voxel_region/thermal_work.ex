defmodule VoxelRegion.ThermalWork do
  @moduledoc """
  全局系统功能：可丢弃的热候选域、接触图复用与内核索引。

  只消费该职责的值，不读取 World 或保存温度、HP、燃料真值。
  几何缺键表示需要 owner 重新读取；空列表表示已经派生的空气或无热容量占用。
  """
  alias VoxelRegion.{Attachments, Damage, Thermal, ThermalGeometry, ThermalRadiation}

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
      indices: %{},
      attachment_cells: nil,
      attachment_graph: nil,
      solid_nodes: %{},
      thermal_slots: %{},
      indexed_edges: [],
      sights: %{},
      # cells 恰为 seeds 的六邻域 ∪ 视线伙伴、几何与视线未被编辑丢弃：此时种子只增时可按增量扩域。
      exact: false,
      # 本次提交内燃烧行键 => 足迹宏格；提交首轮扫描一次，其后按每轮变更行维护。
      burning: nil,
      # 节点键 => {几何节点, 附带默认记录的内核节点}；目录/环境标签变化即整体作废。
      augmented: {nil, %{}}
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
             abs(row.temperature_kelvin - Thermal.ambient(config, Damage.macro(row))) > config["tolerance_kelvin"]),
        cell <- cells(row),
        into: MapSet.new(),
        do: cell
  end

  @doc "合并活动种子，选择六邻域、已知辐射视线伙伴及缺失几何；返回值交 owner 读取本次 canonical 摘要。"
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

    burning_rows =
      work.burning ||
        for({key, row} <- damage, Map.get(row, :burning, false), into: %{}, do: {key, cells(row)})

    burning = for {_, footprint} <- burning_rows, cell <- footprint, into: MapSet.new(), do: cell

    seeds =
      work.hot
      |> MapSet.union(MapSet.new(Map.keys(sources)))
      |> MapSet.union(electric)
      |> MapSet.union(burning)

    complete = work.exact and map_size(work.geometry) == MapSet.size(work.cells)

    cond do
      seeds == work.seeds ->
        cells = work.cells
        # 几何键原本恰好覆盖旧域；编辑只删键。未变且未删键时不遍历几何。
        reuse = map_size(work.geometry) == MapSet.size(cells)

        # 精确域内种子的视线伙伴都已在域内，只需为缺几何的格补视线。
        {fresh, sightless} = if work.exact, do: {MapSet.new(), missing(cells, work.geometry, reuse)}, else: {seeds, cells}

        %{seeds: seeds, cells: cells, missing: missing(cells, work.geometry, reuse), grown: nil,
          exact: work.exact, fresh: fresh, sightless: sightless, burning: burning_rows,
          geometry: if(reuse, do: work.geometry, else: Map.take(work.geometry, MapSet.to_list(cells)))}

      complete and work.seeds != nil and MapSet.subset?(work.seeds, seeds) ->
        # 同一提交内种子只增：旧域不变，只按新增种子扩张；与整域重算得到同一集合。
        delta = MapSet.difference(seeds, work.seeds)
        grown = expand(delta, work.sights)
        missing = MapSet.reject(grown, &Map.has_key?(work.geometry, &1))

        %{seeds: seeds, cells: MapSet.union(work.cells, grown), missing: missing, grown: missing, exact: true,
          fresh: delta, sightless: missing, geometry: work.geometry, burning: burning_rows}

      true ->
        cells = expand(seeds, work.sights)
        reuse = cells == work.cells and map_size(work.geometry) == MapSet.size(cells)

        %{seeds: seeds, cells: cells, missing: missing(cells, work.geometry, reuse), grown: nil, exact: true,
          fresh: seeds, sightless: cells, burning: burning_rows,
          geometry: if(reuse, do: work.geometry, else: Map.take(work.geometry, MapSet.to_list(cells)))}
    end
  end

  defp expand(seeds, sights) do
    seeds
    |> Enum.flat_map(&[&1 | Thermal.neighbors(&1)])
    |> MapSet.new()
    |> MapSet.union(ThermalRadiation.partners(sights, seeds))
  end

  defp missing(_cells, _geometry, true), do: MapSet.new()
  defp missing(cells, geometry, false), do: MapSet.difference(cells, MapSet.new(Map.keys(geometry)))

  @doc "接纳本次完整几何，返回更新的缓存和是否需要重新构造附件接触图。"
  def refresh(work, plan, geometry, attachments) do
    attachment_cells =
      work.attachment_cells ||
        Enum.map(attachments, fn {slot, value} -> {slot, value, Attachments.macros([slot])} end)

    {nodes, slots, rebuild?} =
      cond do
        plan.cells == work.cells and MapSet.size(plan.missing) == 0 ->
          {work.solid_nodes, work.thermal_slots, false}

        plan.grown != nil ->
          # 增量扩域：新格的节点与附件并入旧集合，与整域展开得到同一映射（键集相同，迭代次序相同）。
          added = for cell <- plan.grown, pair <- Map.fetch!(geometry, cell), into: %{}, do: pair
          nodes = Map.merge(work.solid_nodes, added)

          slots =
            Map.merge(work.thermal_slots,
              for({slot, value, footprint} <- attachment_cells,
                Enum.any?(footprint, &MapSet.member?(plan.grown, &1)), into: %{}, do: {slot, value}))

          {nodes, slots,
           map_size(nodes) != map_size(work.solid_nodes) or map_size(slots) != map_size(work.thermal_slots)}

        true ->
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
         exact: plan.exact,
         burning: plan.burning,
         attachment_cells: attachment_cells,
         solid_nodes: nodes,
         thermal_slots: slots,
         # 视线键恒为已有域格的子集；只有整域重算可能收缩域。
         sights: if(plan.grown != nil or plan.cells == work.cells, do: work.sights,
           else: Map.take(work.sights, MapSet.to_list(plan.cells))),
         builds: work.builds + MapSet.size(plan.missing)
     }, rebuild?}
  end

  @doc "按本轮变更行（按写入次序，后写覆盖）更新提交内燃烧行，与重新扫描全部记录得到同一集合。"
  def burned(work, changes) do
    burning =
      Enum.reduce(changes, work.burning, fn {key, row}, burning ->
        if Map.get(row, :burning, false),
          do: Map.put(burning, key, cells(row)),
          else: Map.delete(burning, key)
      end)

    %{work | burning: burning}
  end

  @doc "占用编辑后丢弃受影响宏格的几何；编辑落在已缓存视线的包围盒外扩视距内时整体丢弃视线。"
  def drop(work, cells, range) do
    geometry = Map.drop(work.geometry, cells)

    box = if map_size(work.sights) > 0, do: box(Map.keys(work.sights), range)
    sights = if box && Enum.any?(cells, &within?(&1, box)), do: %{}, else: work.sights

    %{work | geometry: geometry, sights: sights, exact: false}
  end

  defp box(cells, range) do
    for axis <- 0..2 do
      {low, high} = cells |> Enum.map(&elem(&1, axis)) |> Enum.min_max()
      (low - range)..(high + range)
    end
  end

  defp within?(cell, box), do: Enum.all?(Enum.with_index(box), fn {span, axis} -> elem(cell, axis) in span end)

  @doc "按原节点遍历顺序生成每对一次的接触和索引，保持浮点累加顺序。"
  def index(work, nodes, attachment_graph) do
    ordered = Enum.to_list(nodes)
    edges = ThermalGeometry.contacts(nodes)
    indices = ordered |> Enum.with_index() |> Map.new(fn {{key, _}, i} -> {key, i} end)

    %{
      work
      | ordered: ordered,
        indices: indices,
        edges: edges,
        indexed_edges:
          for({a, b, g} <- edges, do: {Map.fetch!(indices, a), Map.fetch!(indices, b), g}),
        attachment_graph: attachment_graph
    }
  end
end
