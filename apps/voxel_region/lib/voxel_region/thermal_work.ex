defmodule VoxelRegion.ThermalWork do
  @moduledoc """
  全局系统功能：可丢弃的热候选域与接触图复用；内核节点表与拓扑在 `VoxelRegion.ThermalDomain`。

  只消费该职责的值，不读取 World 或保存温度、HP、燃料真值。
  几何缺键表示需要 owner 重新读取；空列表表示已经派生的空气或无热容量占用。
  """
  alias VoxelRegion.{Attachments, Damage, Thermal, ThermalDomain, ThermalRadiation}

  @doc "创建空派生缓存；冷恢复、附件或目录变化时可直接重建。"
  def new do
    %{
      hot: MapSet.new(),
      # 上次判定时的热行（键 => 足迹）与此后事务改写过的行键：提交末只重判这两部分（R8-05 增量维护）。
      hot_rows: %{},
      touched: MapSet.new(),
      cells: MapSet.new(),
      geometry: %{},
      builds: 0,
      seeds: nil,
      # 内核次序的节点列表 [{键, 节点}]，每次重建由 domain 给出。
      ordered: [],
      domain: ThermalDomain.new(),
      attachment_cells: nil,
      attachment_graph: nil,
      solid_nodes: %{},
      thermal_slots: %{},
      sights: %{},
      # cells 恰为 seeds 的六邻域 ∪ 视线伙伴、几何与视线未被编辑丢弃：此时种子只增时可按增量扩域。
      exact: false,
      # 燃烧行键 => 足迹宏格；首次全量扫描，其后按提交内变更行与事务改写的行（`touched/3`）维护（R8-05）。
      burning: nil,
      # R8-05 结算增量：上次结算以来事务改写过的行键（提交内的改写另由 visited 给出）。结算的耗尽、相变与提交后的转化
      # 只重判这些行，转化另加上次达到阈值而未转化的 `due`；nil 表示尚未派生，下次结算全量扫描。
      pending: nil,
      due: MapSet.new(),
      # 电路候选行键（`VoxelRegion.Circuit.candidate?/2`）：种子与电观察清理只在候选与本次提交改写的行里判定；
      # 每次结算按当前记录收缩。nil 表示尚未派生（`rebuild_work` 全量派生）。
      electric: nil
    }
  end

  @doc """
  一笔事务改写了这些行（R8-05）：记入热行重判键、结算待判键；燃烧行与电路候选按行的当前值更新。
  已派生的增量集合才更新（nil 仍待全量派生）。删除行不经这里，使用处按当前记录过滤。
  """
  def touched(work, rows, catalog) do
    keys = Enum.map(rows, &Damage.key/1)
    work = %{work | touched: Enum.into(keys, work.touched),
      pending: work.pending && Enum.into(keys, work.pending)}
    work = if work.burning, do: burned(work, Enum.zip(keys, rows)), else: work
    if work.electric,
      do: %{work | electric: for({key, row} <- Enum.zip(keys, rows), VoxelRegion.Circuit.candidate?(row, catalog),
        into: work.electric, do: key)},
      else: work
  end

  @doc """
  结算重判耗尽与相变的行键（R8-05）：上次结算以来事务改写的 `pending` 与本次提交改写的 `visited`；
  pending 尚未派生（nil）时为全部记录。其余行自上次结算未变：已耗尽的已归零，相变已由相变事务换掉材料。
  """
  def settle_keys(nil, _visited, damage), do: Map.keys(damage)
  def settle_keys(pending, visited, _damage), do: Enum.into(visited, pending)

  @doc """
  提交后转化重判的行键：结算交来的键、此后事务改写的行（`pending`）与上次达到阈值而未转化的行（`due`，如缺还原剂）。
  结算之后的事务重建了工作集（如燃尽删除附件，pending 回到 nil）时为全部记录。
  """
  def transform_keys(_settled, nil, _due, damage), do: Map.keys(damage)
  def transform_keys(settled, pending, due, _damage), do: settled |> Enum.into(pending) |> Enum.into(due)

  @doc "燃烧行按当前记录过滤（删除行不经事务 touch）；nil 仍待全量扫描。"
  def live_burning(nil, _damage), do: nil
  def live_burning(burning, damage),
    do: for({key, footprint} <- burning, Map.get(Map.get(damage, key, %{}), :burning, false), into: %{}, do: {key, footprint})

  @doc "电路候选按当前记录收缩，并入本次提交改写过的行键。"
  def electric(keys, damage, catalog),
    do: for(key <- keys, row = Map.get(damage, key), VoxelRegion.Circuit.candidate?(row, catalog), into: MapSet.new(), do: key)

  @doc "目标涉及的全部 canonical 宏格，附件可跨宏格和区域。"
  def cells(%{granularity: 4} = target), do: Attachments.macros([Attachments.slot(target)])
  def cells(target), do: [Damage.macro(target)]

  @doc "热节点键的全部 canonical 足迹；未进入计算域的邻点也有确定的边界归属。"
  def key_cells({4, {type, point}}), do: Attachments.macros([{div(type, 3), rem(type, 3), point}])
  def key_cells({_granularity, point}), do: [Damage.macro(%{micro: point})]

  @doc "从当前温度与燃烧记录派生全部热行（键 => 足迹）：燃烧，或温度偏离所在宏格环境超过容差；不持有属性真值。"
  def hot_rows(damage, config), do: for({key, row} <- damage, hot_row?(row, config), into: %{}, do: {key, cells(row)})

  @doc """
  增量维护热行：只按当前记录重判上次的热行与 `keys`（此后改写过的行），其余行沿用上次判定。
  只要其余行自上次判定以来未被改写、环境与容差未变，结果与 `hot_rows/2` 全量扫描相同；删除的行不再是热行。
  """
  def rehot(rows, keys, damage, config) do
    Enum.reduce(keys, Enum.reduce(Map.keys(rows), rows, &judge(&2, &1, damage, config)), &judge(&2, &1, damage, config))
  end

  @doc "热行的足迹并集（热格集合）。"
  def footprints(rows), do: for({_, footprint} <- rows, cell <- footprint, into: MapSet.new(), do: cell)

  defp judge(rows, key, damage, config) do
    case damage do
      %{^key => row} -> if hot_row?(row, config), do: Map.put(rows, key, cells(row)), else: Map.delete(rows, key)
      _ -> Map.delete(rows, key)
    end
  end

  defp hot_row?(row, config) do
    Map.get(row, :burning, false) or
      (Map.has_key?(row, :temperature_kelvin) and
         abs(row.temperature_kelvin - VoxelRegion.Climate.air_k(config, Damage.macro(row))) > config["tolerance_kelvin"])
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
end
