defmodule VoxelRegion.World.CircuitGraph do
  @moduledoc "全局系统功能：实际电路与玩家潜在接纳共用的空间读取图；沿同一接触规则装页，不持有或提交世界真值。"
  alias VoxelRegion.{Attachments, Circuit, Damage, Prefab, Protection, ThermalGeometry}
  alias VoxelRegion.World.{Canonical, Pages}

  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "由当前自然段冻结 seq 与真实电动势种子；domain 为原电路附件保护域函数。"
  def new(seq, seeds, domain \\ nil, previous \\ nil) do
    %{seq: seq, status: :preparing, domain: domain, queue: :queue.from_list(Enum.map(seeds, &{:solid, &1})),
      solids: MapSet.new(), points: MapSet.new(), slots: %{}, hosts: %{}, contacts: [], keys: MapSet.new(),
      retained: if(previous, do: previous.keys, else: MapSet.new())}
  end

  @doc "实际求解和潜在接纳共用的附件保护域；跨持有者附件不与两侧端点混接。"
  def protection_domain(protection) do
    if not Protection.empty?(protection) do
      fn slot ->
        case [slot] |> Attachments.macros() |> Enum.map(&Protection.holder(protection, &1)) |> Enum.uniq() do
          [holder] -> {:holder, holder}
          _ -> {:mixed, slot}
        end
      end
    end
  end

  @doc "从一个新增潜在单元开始，只切换导电策略，复用同一空间读取图。"
  def potential(seq, seed, protection) do
    seed = case seed do {:solid, target} -> {:solid, Circuit.thermal_target(target)}; slot -> slot end
    new(seq, [], protection_domain(protection))
    |> Map.put(:queue, :queue.from_list([seed]))
    |> Map.put(:mode, :potential)
  end

  @doc "当前准备图确实已读取或将继续读取的页；邻页与粗层祖页仍走既有 Pages 合同。"
  def dependencies(nil), do: []
  def dependencies(graph), do: Pages.with_ancestors(MapSet.to_list(MapSet.union(graph.keys, Map.get(graph, :retained, MapSet.new()))))

  @doc "完成并消费一次合法图后，只保留下一段真实活动仍需要的读取依赖，释放图及目录／属性引用。"
  def completed(graph), do: Map.take(graph, [:seq, :keys]) |> Map.put(:status, :complete)

  @doc "只读图构造进度，不复制大输入或把统计作为产品门禁。"
  def observe(nil), do: %{status: :idle}
  def observe(%{status: :complete} = graph), do: %{status: :complete, seq: graph.seq, read_pages: MapSet.size(graph.keys)}
  def observe(graph), do: %{status: if(:queue.is_empty(graph.queue), do: :ready, else: :preparing),
    seq: graph.seq, pending_units: :queue.len(graph.queue), solid_nodes: MapSet.size(graph.solids),
    point_nodes: MapSet.size(graph.points), attachment_slots: map_size(graph.slots), read_pages: MapSet.size(graph.keys)}

  @doc "线性推进同一准备图；遇冷页保留当前自然单元，不进行求解或消费任何模型时间。"
  def advance(state, graph) do
    case :queue.out(graph.queue) do
      {:empty, _} -> {:ready, graph, state}
      {{:value, {:solid, target}}, rest} -> solid(state, graph, target, rest)
      {{:value, {:point, point}}, rest} -> point(state, graph, point, rest)
      {{:value, {:slot, slot}}, rest} -> slot(state, graph, slot, rest)
    end
  end

  defp solid(state, graph, target, rest) do
    key = ThermalGeometry.key(target)
    if MapSet.member?(graph.solids, key) do
      advance(state, %{graph | queue: rest})
    else
      faces = Circuit.solid_faces(target)
      # 附件端点的宿主是端点周围的八个微格；实体包含的全部顶点（闭端点盒）恰为其逆向查询范围。
      # 候选槽按种类／轴一次给出锚点范围，页与已存在槽都由范围直接求，不逐顶点展开关联槽再去重。
      attachable = Circuit.conductors([target], state.properties, state.damage, environment(state), mode(graph)) != []
      box = vertex_box(target)
      ranges = if attachable, do: Attachments.incident_ranges(elem(box, 0), elem(box, 1)), else: []
      slot_pages = ranges |> range_pages() |> Enum.uniq()
      # solid_faces 每面采样都落在同一相邻宏格（微格每面一点），每面首点即该面页。
      required = Enum.map(faces, &micro_page(hd(&1))) ++ slot_pages
      case require_pages(state, graph, required) do
        {:needs_pages, keys, graph} -> {:needs_pages, keys, graph, state}
        {:ready, graph} ->
          slots = present_slots(state, ranges, slot_pages, box)
          {runs, state} = Enum.flat_map_reduce(faces, state, &face_targets/2)
          contacts = Circuit.solid_contacts(runs, state.properties, state.damage, environment(state), mode(graph))
          graph = %{graph | queue: rest, solids: MapSet.put(graph.solids, key)}
          graph = Enum.reduce(contacts, graph, fn {other_key, {other, area}}, g ->
            if MapSet.member?(g.solids, other_key) or
                 not Circuit.contact_allowed?(target, other, state.properties) or
                 not Protection.same_holder?(state.protection, Damage.macro(target), Damage.macro(other)) do
              g
            else
              %{g | queue: :queue.in({:solid, other}, g.queue), contacts: [{target, other, area} | g.contacts]}
            end
          end)
          graph = add_slots(state, graph, slots, fn slot ->
            graph.domain == nil or graph.domain.(slot) == {:holder, Protection.holder(state.protection, Damage.macro(target))}
          end)
          advance(state, graph)
      end
    end
  end

  defp point(state, graph, point, rest) do
    if MapSet.member?(graph.points, point) do
      advance(state, %{graph | queue: rest})
    else
      position = elem(point, 1)
      slots = Attachments.incident_slots(position)
      samples = Circuit.near_points(point)
      # 关联槽锚点都在端点周围同八个微格内，其页已由采样点页覆盖。
      required = Enum.map(samples, &micro_page/1)
      case require_pages(state, graph, required) do
        {:needs_pages, keys, graph} -> {:needs_pages, keys, graph, state}
        {:ready, graph} ->
          {targets, state} = Enum.map_reduce(samples, state, &target/2)
          hosts = Circuit.conductors(targets, state.properties, state.damage, environment(state), mode(graph))
          hosts = if graph.domain,
            do: Enum.filter(hosts, &({:holder, Protection.holder(state.protection, Damage.macro(&1))} == elem(point, 2))),
            else: hosts
          graph = %{graph | queue: rest, points: MapSet.put(graph.points, point), hosts: Map.put(graph.hosts, point, hosts)}
          graph = Enum.reduce(hosts, graph, fn host, g -> %{g | queue: :queue.in({:solid, host}, g.queue)} end)
          graph = add_slots(state, graph, slots, fn slot -> graph.domain == nil or graph.domain.(slot) == elem(point, 2) end)
          advance(state, graph)
      end
    end
  end

  defp slot(state, graph, slot, rest) do
    case require_pages(state, graph, [slot_page(slot)]) do
      {:needs_pages, keys, graph} -> {:needs_pages, keys, graph, state}
      {:ready, graph} ->
        graph = add_slots(state, %{graph | queue: rest}, [slot], fn _ -> true end)
        advance(state, graph)
    end
  end

  defp mode(graph), do: Map.get(graph, :mode, :actual)
  defp environment(state), do: state.thermal && state.thermal.config

  defp add_slots(state, graph, candidates, permitted?) do
    Enum.reduce(candidates, graph, fn slot, g ->
      case Map.fetch(state.attachments, slot) do
        {:ok, value} ->
          if Map.has_key?(g.slots, slot) or not permitted?.(slot) or
               Circuit.sigma(state.properties, state.damage, environment(state), Attachments.identity(slot, value), mode(graph)) <= 0 do
            g
          else
            points = Enum.map(Attachments.vertices(slot), fn p ->
              if g.domain, do: Circuit.point(p, g.domain.(slot)), else: Circuit.point(p)
            end)
            queue = Enum.reduce(points, g.queue, fn p, q -> :queue.in({:point, p}, q) end)
            %{g | slots: Map.put(g.slots, slot, value), queue: queue}
          end
        :error -> g
      end
    end)
  end

  defp require_pages(state, graph, keys) do
    keys = Enum.uniq(keys)
    graph = %{graph | keys: Enum.into(keys, graph.keys)}
    case Enum.reject(keys, &Pages.resident?(state, &1)) do
      [] -> {:ready, graph}
      missing -> {:needs_pages, Pages.with_ancestors(missing), graph}
    end
  end

  # 实体包含的全部顶点构成的闭端点盒（宏格 0..8、微格 0..1 微格边长）。
  defp vertex_box(%{micro: {x, y, z}} = target) do
    size = if target.granularity == 0, do: @micro, else: 1
    {{x, y, z}, {x + size, y + size, z + size}}
  end

  # 锚点范围覆盖的宏格逐轴是连续区间，页集合与逐锚点 micro_page 相同。
  defp range_pages(ranges) do
    for {_, _, {xs, ys, zs}} <- ranges, cx <- cells(xs), cy <- cells(ys), cz <- cells(zs),
      do: {0, Canonical.region_of({cx, cy, cz})}
  end

  defp cells(first..last//1), do: Integer.floor_div(first, @micro)..Integer.floor_div(last, @micro)//1

  # 已存在的候选槽 = 锚点范围 ∩ 附件表，按原“端点盒顶点字典序 × 关联槽序”首次出现的次序排列，保持后续入队与求解边顺序不变。
  # 求交遍历较小一侧：宏格实体的锚点范围约五千个，而相关 L0 区域里实际附件常远少于此（反之微格实体范围仅数十）；
  # 区域侧读 Canonical 随 attachments 同步维护的 attachment_regions 派生索引，两侧结果为同一集合。
  defp present_slots(state, ranges, slot_pages, box) do
    regions = Enum.map(slot_pages, &elem(&1, 1))
    indexed = Enum.sum(for region <- regions, do: map_size(Map.get(state.attachment_regions, region, %{})))
    anchors = Enum.sum(for {_, _, {xs, ys, zs}} <- ranges, do: Range.size(xs) * Range.size(ys) * Range.size(zs))
    if indexed < anchors do
      Canonical.attachments_in_regions(state, regions, &in_ranges?(&1, ranges))
    else
      for {kind, axis, {xs, ys, zs}} <- ranges, x <- xs, y <- ys, z <- zs, slot = {kind, axis, {x, y, z}},
        Map.has_key?(state.attachments, slot), do: slot
    end
    |> Enum.sort_by(&first_incidence(&1, box))
  end

  defp in_ranges?({kind, axis, {x, y, z}}, ranges),
    do: Enum.any?(ranges, fn {k, a, {xs, ys, zs}} -> k == kind and a == axis and x in xs and y in ys and z in zs end)

  defp first_incidence(slot, {lo, hi}) do
    vertex = slot |> Attachments.vertices() |> Enum.filter(&inside?(&1, lo, hi)) |> Enum.min()
    {vertex, Enum.find_index(Attachments.incident_slots(vertex), &(&1 == slot))}
  end

  defp inside?({x, y, z}, {x0, y0, z0}, {x1, y1, z1}),
    do: x in x0..x1 and y in y0..y1 and z in z0..z1

  defp micro_page(micro), do: {0, Canonical.region_of(elem(Prefab.macro_slot(micro), 0))}
  defp slot_page({_, _, anchor}), do: micro_page(anchor)

  defp target(point, state) do
    {value, state} = Canonical.target_at(point, state)
    {if(value && Canonical.loose_cell?(state, value), do: nil, else: value), state}
  end

  # 宏格面仍复用原单次读取优化；细分或有限液柱保持逐微格实际采样。
  defp face_targets([point | _] = points, state) do
    {cell, _} = Prefab.macro_slot(point)
    if length(points) > 1 and not Map.has_key?(state.refined, cell) and not Map.has_key?(state.liquid_units, cell) do
      {value, state} = target(point, state)
      {[{value, length(points)}], state}
    else
      Enum.map_reduce(points, state, fn p, s -> {value, s} = target(p, s); {{value, 1}, s} end)
    end
  end
end
