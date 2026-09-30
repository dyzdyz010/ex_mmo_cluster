defmodule VoxelRegion.ThermalDomain do
  @moduledoc """
  全局系统功能：热内核的节点表与常驻原生热域（可丢弃的派生缓存）。

  `table` 是本轮内核节点：节点键 => 已按受保护区域／气候分区过滤接触、并附默认记录等派生字段的节点，
  其遍历次序就是内核次序（与原先 `Enum.to_list(nodes)` 相同）。节点按整数槽位、宏格按整数编号交给
  `VoxelRegion.ThermalNative` 的热域资源：接触、辐射视线和节点工作副本只推送变化的部分，每轮把节点次序交给原生侧
  生成内核边与辐射项（次序与数值同 `ThermalGeometry.contacts/1`、`ThermalRadiation.terms/4`），每步在原生侧演进与结算。

  不读取 World：分区、派生字段与记录换算由调用方以函数给出；取回的节点值由调用方写回属性记录（唯一真值）。
  """
  alias VoxelRegion.{Combustion, ThermalNative}

  defstruct native: nil, slots: %{}, keys: %{}, cells: %{}, cell_at: %{}, table: %{}, inputs: %{}, derived: [],
            finite: MapSet.new(), phases: MapSet.new(), recorded: MapSet.new(), sights: %{}, tag: nil, hot: nil,
            seen: nil, pending: false, edges: 0, pairs: 0, sky: 0

  @doc "空节点表与新的原生热域资源。"
  def new, do: %__MODULE__{native: ThermalNative.domain_new()}

  @doc """
  按本轮节点（附件并入后、边界过滤前）更新节点表、原生拓扑与节点工作副本。

  - `hint`：`{:grown, added_keys}` 表示除附件派生节点（`derived_keys`，本轮与上轮）外只有这些键可能变化
    （同一提交内增量扩域），`:full` 表示与上次整表比较；`tag` 变化（目录、环境、气候）时整表重算派生字段。
  - `bound`：`nil` 或 `fn key -> 热分区 end`，接触只保留伙伴与本节点同分区的一侧。
  - `augment`：`fn bounded_node -> {kernel_node, finite?} end`；`finite?` 的节点每轮重算派生字段。
  - `load`：`fn kernel_node -> {ThermalRecord.static/3, ThermalRecord.dynamic/4} end`，按当前记录装入。
  """
  def sync(domain, nodes, hint, derived, tag, bound, augment, load) do
    # 派生字段的标签变了：节点表整表重算；槽位与原生资源沿用，不在次序里的旧槽位不产生任何项。
    domain = if tag == domain.tag, do: domain,
      else: %{domain | table: %{}, inputs: %{}, derived: [], finite: MapSet.new(), phases: MapSet.new(), tag: tag}

    {changed, removed} =
      case hint do
        {:grown, added} when domain.table != %{} ->
          keys = Enum.uniq(added ++ derived ++ domain.derived)
          {for(key <- keys, Map.has_key?(nodes, key), Map.get(domain.inputs, key) != nodes[key], do: key),
           for(key <- domain.derived, not Map.has_key?(nodes, key), do: key)}

        _ ->
          {for({key, node} <- nodes, Map.get(domain.inputs, key) != node, do: key),
           for({key, _} <- domain.inputs, not Map.has_key?(nodes, key), do: key)}
      end

    domain = %{domain | derived: derived}

    {domain, upserts, loads} =
      Enum.reduce(changed, {domain, [], []}, fn key, {d, upserts, loads} ->
        node = Map.fetch!(nodes, key)
        bounded = bounded(key, node, bound)
        {d, slot} = slot(d, key)
        {d, contacts} = Enum.reduce(bounded.contacts, {d, []}, fn {other, g}, {d, acc} ->
          {d, other_slot} = slot(d, other)
          {d, [{other_slot, g, key < other} | acc]}
        end)
        {kernel, finite?} = augment.(bounded)
        kernel = Map.put(kernel, :slot, slot)
        {static, dynamic} = load.(kernel)
        {d, static} = native_static(d, kernel, static)
        d = %{d | table: Map.put(d.table, key, kernel), inputs: Map.put(d.inputs, key, node),
                  finite: if(finite?, do: MapSet.put(d.finite, key), else: MapSet.delete(d.finite, key)),
                  phases: if(elem(static, 9), do: MapSet.put(d.phases, kernel.damage_key),
                    else: MapSet.delete(d.phases, kernel.damage_key))}
        {d, [{slot, Enum.reverse(contacts)} | upserts], [{slot, static, dynamic} | loads]}
      end)

    domain = %{domain | table: Map.drop(domain.table, removed), inputs: Map.drop(domain.inputs, removed),
      finite: Enum.reduce(removed, domain.finite, &MapSet.delete(&2, &1)),
      phases: Enum.reduce(removed, domain.phases, &MapSet.delete(&2, domain.table[&1].damage_key))}

    # 有限宏格的默认 HP 随数量变化：每轮按当前数量重算派生字段（接触与槽位不变；本轮刚写入的已是新值），
    # 没有待写回变化的节点按当前记录重新装入。
    refreshed = MapSet.difference(domain.finite, MapSet.new(changed))
    table = Enum.reduce(refreshed, domain.table, fn key, table ->
      {kernel, _} = augment.(bounded(key, Map.fetch!(domain.inputs, key), bound))
      Map.put(table, key, Map.put(kernel, :slot, Map.fetch!(table, key).slot))
    end)

    :ok = ThermalNative.domain_put(domain.native, upserts, Enum.map(removed, &Map.fetch!(domain.slots, &1)), [], false)
    :ok = ThermalNative.domain_load(domain.native, loads)
    :ok = ThermalNative.domain_reload(domain.native,
      for(key <- refreshed, kernel = table[key], do: {kernel.slot, elem(load.(kernel), 1)}), true)
    %{domain | table: table}
  end

  @doc "按当前记录重新装入这些节点的动态量（`[{键, ThermalRecord.dynamic/4}]`；外部事务改写或点燃之后）。"
  def reload(domain, []), do: domain

  def reload(domain, values) do
    :ok = ThermalNative.domain_reload(domain.native, for({key, dynamic} <- values, do: {domain.slots[key], dynamic}), false)
    domain
  end

  @doc "热格集合（`ThermalWork.hot`）；与上次交给原生侧的集合相同时不推送。"
  def put_hot(%{hot: hot} = domain, hot), do: domain

  def put_hot(domain, hot) do
    {domain, ids} = Enum.reduce(hot, {domain, []}, fn cell, {d, ids} -> {d, id} = cell_id(d, cell); {d, [id | ids]} end)
    :ok = ThermalNative.domain_hot(domain.native, ids)
    %{domain | hot: hot}
  end

  @doc """
  一个内核步。`sources` 为 `[{宏格, 功率, 余能}]`，`powers` 为 `%{节点键 => 电功率}`，`extra` 为外部节点的
  `{输入, 事件}`（接在世界节点之后），`requested` 为需要步末温度的世界节点下标。返回节点表（热格集合已并入新热格）和结算：
  新热格、点燃候选、共享损失、熄灭与变化的节点都按内核次序给出节点键。
  """
  def step(domain, duration, exchange, tolerance, sources, powers, extra, extra_contacts, extra_ambient, prefix, requested) do
    {domain, sources} = Enum.map_reduce(sources, domain, fn {cell, power, remaining}, d ->
      {d, id} = cell_id(d, cell)
      {{id, power, remaining}, d}
    end) |> then(fn {sources, d} -> {d, sources} end)
    powers = for {key, power} <- powers, slot = domain.slots[key], slot != nil, do: {slot, power}

    {elapsed, supplied, environment, combustion, extra_out, hot, ignitions, losses, extinguished, changed, left, temps} =
      ThermalNative.domain_step(domain.native, duration, exchange, tolerance, Combustion.fuel_epsilon_j(), sources,
        powers, extra, extra_contacts,
        extra_ambient, prefix, requested)

    new_hot = Enum.map(hot, &domain.cell_at[&1])
    key = &Map.fetch!(domain.keys, &1)

    # 相态节点走过一步后，原实现的记录就带上了焓字段；写回之前由 recorded 代为回答（见 phase_recorded?/2）。
    {%{domain | hot: MapSet.union(domain.hot, MapSet.new(new_hot)), pending: domain.pending or changed != [],
                recorded: MapSet.union(domain.recorded, domain.phases)},
     %{elapsed: elapsed, supplied: supplied, environment: environment, combustion: combustion, extra: extra_out,
       hot: new_hot, ignitions: Enum.map(ignitions, key), losses: for({slot, before, hp} <- losses, do: {key.(slot), before, hp}),
       extinguished: Enum.map(extinguished, key), changed: Enum.map(changed, key),
       sources: for({id, rest} <- left, do: {domain.cell_at[id], rest}), temperatures: temps}}
  end

  @doc "取回自上次取回以来变化的节点当前值 `[{键, ThermalRecord.dynamic/4 形状}]`，交调用方写回属性记录；`pending` 即是否可能有待取回的节点。"
  def flush(domain),
    do: {%{domain | pending: false, recorded: MapSet.new()},
         for({slot, dynamic} <- ThermalNative.domain_flush(domain.native), do: {domain.keys[slot], dynamic})}

  @doc "相态节点的焓是否已进入记录：记录已有焓字段，或该节点已在原生侧演进、尚待写回。"
  def phase_recorded?(domain, row, damage_key),
    do: Map.has_key?(row, :phase_energy_j) or MapSet.member?(domain.recorded, damage_key)

  @doc "节点当前值 `%{键 => 动态量}`（不改变待写回标记）。"
  def values(_domain, []), do: %{}

  def values(domain, keys) do
    keys
    |> Enum.zip(ThermalNative.domain_values(domain.native, Enum.map(keys, &domain.slots[&1])))
    |> Map.new()
  end

  @doc """
  同步辐射视线（宏格 => `[{节点键, :sky | :blocked | {伙伴键, 伙伴宏格}, 面积}]`）。只新增宏格时推送新增部分，
  宏格被丢弃（编辑、域收缩）时整体重推。
  """
  def sync_sights(domain, sights) when sights == domain.sights, do: domain

  def sync_sights(domain, sights) do
    reset? = Enum.any?(domain.sights, fn {cell, rows} -> Map.get(sights, cell) != rows end)
    cells = if reset?, do: Map.keys(sights), else: for({cell, _} <- sights, not Map.has_key?(domain.sights, cell), do: cell)

    {domain, pushed} =
      Enum.reduce(cells, {domain, []}, fn cell, {d, pushed} ->
        sights
        |> Map.fetch!(cell)
        |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})
        |> Enum.reduce({d, pushed}, fn {key, rows}, {d, pushed} ->
          {d, slot} = slot(d, key)
          # 与 ThermalRadiation.terms/4 相同：同一节点的视线按 {命中, 面积} 的项序排列，遮挡的面不换热。
          {d, rows} = rows |> Enum.sort() |> Enum.flat_map_reduce(d, fn
            {:blocked, _}, d -> {[], d}
            {:sky, area}, d -> {[{nil, area}], d}
            {{other, _cell}, area}, d -> {d, other_slot} = slot(d, other); {[{other_slot, area}], d}
          end) |> then(fn {rows, d} -> {d, rows} end)
          {d, [{slot, rows} | pushed]}
        end)
      end)

    :ok = ThermalNative.domain_put(domain.native, [], [], pushed, reset?)
    %{domain | sights: sights}
  end

  @doc "按节点表次序重建原生内核边与辐射项；返回带边数／辐射项数的节点表和内核次序的节点列表 `[{键, 节点}]`。"
  def index(domain, emissivity) do
    ordered = Enum.to_list(domain.table)
    # 内核下标按 Enum.to_list 次序；接触按推导式遍历节点表的次序发出（超过 32 键的 map 两者互逆），
    # 与原 ThermalWork.index/3 + ThermalGeometry.contacts/1 逐位相同。
    emission = for {_, node} <- domain.table, do: node.slot
    {edges, pairs, sky} =
      ThermalNative.domain_index(domain.native, Enum.map(ordered, fn {_, node} -> node.slot end), emission,
        emissivity * 1.0)
    {%{domain | edges: edges, pairs: pairs, sky: sky}, ordered}
  end

  @doc "节点键 => 本轮内核下标（不在节点表内的键不出现）。"
  def positions(_domain, []), do: %{}

  def positions(domain, keys) do
    known = for key <- keys, slot = Map.get(domain.slots, key), slot != nil, do: {key, slot}
    found = ThermalNative.domain_positions(domain.native, Enum.map(known, &elem(&1, 1)))
    for {{key, _}, position} <- Enum.zip(known, found), position != nil, into: %{}, do: {key, position}
  end

  defp native_static(domain, kernel, {capacity, conductivity, resistance, faces, ambient, ignition, shared, macro?, phase}) do
    {cells, domain} = Enum.map_reduce(kernel.cells, domain, fn cell, d -> {d, id} = cell_id(d, cell); {id, d} end)
    {domain, macro} = if macro?, do: cell_id(domain, kernel.cell), else: {domain, nil}
    {domain, {capacity, conductivity, resistance, faces, ambient, ignition, shared, macro, cells, phase}}
  end

  defp bounded(_key, node, nil), do: node

  defp bounded(key, node, bound) do
    partition = bound.(key)
    %{node | contacts: Enum.filter(node.contacts, fn {other, _} -> bound.(other) == partition end)}
  end

  defp slot(domain, key) do
    case domain.slots do
      %{^key => slot} -> {domain, slot}
      slots -> slot = map_size(slots)
        {%{domain | slots: Map.put(slots, key, slot), keys: Map.put(domain.keys, slot, key)}, slot}
    end
  end

  defp cell_id(domain, cell) do
    case domain.cells do
      %{^cell => id} -> {domain, id}
      cells -> id = map_size(cells)
        {%{domain | cells: Map.put(cells, cell, id), cell_at: Map.put(domain.cell_at, id, cell)}, id}
    end
  end
end
