defmodule SceneServer.PrefabDesigner.Check do
  @moduledoc """
  全局系统功能：已编译 prefab 草稿的只读检查与文本视图。

  所有坐标与编译节点使用同一套 micro 坐标。`bounds` 是显式已知的半开检查窗口：
  窗口内未占用位置是草稿空气，窗外未知。可选 `ground_y` 明确声明该 micro 平面以下是地面，
  不表示已经检查真实工地的地形。调用方的输入接纳边界负责保证 bounds 和 interiors 是正跨度半开区域。

  必填选项：`profile`（米制 radius/half_height/step_height）、`properties`（已发布的 Damage 目录）、
  `bounds`、`entry`、`inside`、`max_path_nodes`、`max_scan_cells`。可选 `interiors` 是带名称和明确
  `floor_y` 的 XZ 半开室内矩形；未给室内范围时不声称检查了整屋屋顶。

  步行复用 Movement.Path，以 micro 为单位，用保守的圆形水平占用和向上取整的高度检查净空。
  结论只证明这套离散步行，不代替连续胶囊碰撞。悬空指实体通过面邻接不能连接到给定地面，
  不作结构力学判断。宏格不展开成 512 项常驻表；仅在查询占用时采样其隐式 micro 体积。
  """
  alias SceneServer.Movement.Path, as: Walk
  alias VoxelRegion.{Attachments, Damage, Prefab}
  alias MmoContracts.VoxelMaterialCatalog, as: Materials
  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "独立查看已编译草稿的局部几何；不猜测房间、脚点或地面。"
  def view(%{summary: %{bounds: nil}}), do: {:error, :empty_draft}
  def view(%{summary: %{bounds: bounds}} = compiled) do
    {:ok, views(Map.new(Prefab.footprint(compiled, {0, 0, 0}, 0)),
      Map.new(Prefab.macro_footprint(compiled, {0, 0, 0}, 0)), bounds)}
  end

  @doc "沿用正式材料单位和附件计价，供目录与完整检查共用。"
  def materials(compiled, properties), do: materials(compiled,
    Map.new(Prefab.footprint(compiled, {0, 0, 0}, 0)),
    Map.new(Prefab.macro_footprint(compiled, {0, 0, 0}, 0)), properties)

  def run(compiled, opts) do
    micros = Map.new(Prefab.footprint(compiled, {0, 0, 0}, 0))
    macros = Map.new(Prefab.macro_footprint(compiled, {0, 0, 0}, 0))
    bounds = Keyword.fetch!(opts, :bounds)
    rooms = Keyword.get(opts, :interiors, [])
    {lo, hi} = bounds
    volume = Enum.product(for a <- 0..2, do: elem(hi, a) - elem(lo, a))
    columns = Enum.reduce(rooms, 0, fn r, sum -> sum + area(r) * max(0, elem(hi, 1) - r.floor_y) end)
    work = volume + columns + map_size(macros) * 6 * @micro * @micro + map_size(micros) * 6

    if work > Keyword.fetch!(opts, :max_scan_cells) do
      {:error, :check_budget}
    else
      ground = Keyword.get(opts, :ground_y)
      sample = fn p -> sample(p, micros, macros, bounds, ground) end
      profile = Keyword.fetch!(opts, :profile)
      offsets = radius_offsets(profile.radius * @micro)
      probe = fn p -> query_sample(p,sample,offsets) end
      query = fn p -> probe.(p).kind end
      height = ceil(2 * profile.half_height * @micro)
      {gx, gy, gz} = inside = Keyword.fetch!(opts, :inside)
      route = Walk.find(query, Keyword.fetch!(opts, :entry), {gx, gz}, gy,
        floor(profile.step_height * @micro), height,
        max_nodes: Keyword.fetch!(opts, :max_path_nodes))
      room_reports = Enum.map(rooms, &room(&1, sample, bounds))

      {:ok, %{
        scope: :draft, bounds: bounds, route: route,
        endpoints: %{entry: endpoint(Keyword.fetch!(opts,:entry),query,probe,height),
          inside: endpoint(inside,query,probe,height)},
        headroom: %{inside: clearance(inside, sample, bounds), interiors: Enum.map(room_reports, & &1.headroom)},
        roof: Enum.map(room_reports, & &1.roof),
        floating: floating(micros, macros, ground),
        materials: materials(compiled, Keyword.fetch!(opts, :properties)),
        views: views(micros, macros, bounds)
      }}
    end
  end

  # 同一半径查询同时供 Path 与诊断使用；保留既有未知优先于实心的语义。
  defp query_sample({x,y,z},sample,offsets) do
    Enum.reduce_while(offsets,%{kind: :open},fn {dx,dz},state ->
      cell = {x+dx,y,z+dz}
      case sample.(cell) do
        :unknown -> {:halt,%{kind: :unknown,cell: cell}}
        :solid when state.kind == :open -> {:cont,%{kind: :solid,cell: cell}}
        _ -> {:cont,state}
      end
    end)
  end
  defp endpoint({x,y,z}=point,query,probe,height) do
    body = Enum.find_value(0..(height-1),fn dy ->
      hit = probe.({x,y+dy,z})
      if hit.kind != :open,do: hit
    end) || %{kind: :open}
    %{requested: point,position: Walk.position(query,point,height),body: body,support: probe.({x,y-1,z})}
  end

  defp sample({_, y, _} = p, micros, macros, bounds, ground) do
    cond do
      not inside?(p, bounds) -> :unknown
      ground != nil and y < ground -> :solid
      true -> kind(Map.get(micros, p, Map.get(macros, macro(p), 0)))
    end
  end
  defp kind(0), do: :open
  defp kind(material) do
    cond do
      Materials.blocks_movement?(material) -> :solid
      Materials.flora?(material) -> :open
      true -> :unknown
    end
  end
  defp inside?(p, {lo, hi}), do: Enum.all?(0..2, &(elem(p, &1) >= elem(lo, &1) and elem(p, &1) < elem(hi, &1)))
  defp macro(p), do: p |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1, @micro)) |> List.to_tuple()

  # 水平单位方格与角色圆形占用有实际相交；仅接触边界不计重叠。
  defp radius_offsets(radius) do
    reach = ceil(radius)
    for x <- -reach..reach, z <- -reach..reach,
      max(abs(x) - 0.5, 0) ** 2 + max(abs(z) - 0.5, 0) ** 2 < radius * radius or {x, z} == {0, 0},
      do: {x, z}
  end

  defp clearance({x, y, z} = point, sample, {_, hi} = bounds) do
    if not inside?(point, bounds) do
      %{status: :unknown, clear_micro: nil, metres: nil}
    else
      top = elem(hi, 1)
      stop = Enum.find(y..(top - 1), &(sample.({x, &1, z}) != :open))
      amount = (stop || top) - y
      status = cond do
        stop == nil -> :open_to_bound
        sample.({x, stop, z}) == :unknown -> :unknown
        stop == y -> :blocked
        true -> :ceiling
      end
      %{status: status, clear_micro: amount, metres: amount / @micro, ceiling_y: stop}
    end
  end
  defp area(%{min: {x, z}, max: {xx, zz}}), do: (xx - x) * (zz - z)
  defp room(%{name: name, floor_y: floor, min: {x, z}, max: {xx, zz}} = room, sample, bounds) do
    columns = for a <- x..(xx - 1), b <- z..(zz - 1), do: clearance({a, floor, b}, sample, bounds)
    covered = Enum.count(columns, &(&1.status == :ceiling))
    clearances = for c <- columns, is_integer(c.clear_micro), do: c.clear_micro
    %{roof: %{name: name, covered_columns: covered, total_columns: area(room), complete: covered == area(room)},
      headroom: %{name: name, floor_y: floor, min_clear_micro: Enum.min(clearances, fn -> nil end),
        blocked_columns: Enum.count(columns, &(&1.status == :blocked)),
        unknown_columns: Enum.count(columns, &(&1.status == :unknown)),
        open_to_bound_columns: Enum.count(columns, &(&1.status == :open_to_bound))}}
  end

  defp materials(compiled, micros, macros, properties) do
    quantum = Damage.material_units(properties)
    rows = Enum.map(micros, fn {_, m} -> {m, quantum} end) ++
      Enum.map(macros, fn {_, m} -> {m, quantum * @micro * @micro * @micro} end) ++
      (for node <- compiled.nodes, attachment <- node.attachments,
        do: {attachment.material, Attachments.units(attachment.slots, properties)})
    units = Enum.reduce(rows, %{}, fn {m, n}, acc -> Map.update(acc, m, n, &(&1 + n)) end)
    %{units: units, volume_m3: Map.new(units, fn {m, n} -> {m, n / (quantum * @micro * @micro * @micro)} end)}
  end

  defp floating(_, _, nil), do: %{status: :unknown, reason: :ground_not_supplied}
  defp floating(micros, macros, ground) do
    micros = Map.filter(micros, fn {_, m} -> Materials.blocks_movement?(m) end)
    macros = Map.filter(macros, fn {_, m} -> Materials.blocks_movement?(m) end)
    parts = MapSet.new(Enum.map(Map.keys(micros), &{:micro, &1}) ++ Enum.map(Map.keys(macros), &{:macro, &1}))
    seeds = Enum.filter(parts, fn {kind, {_, y, _}} -> y * if(kind == :macro, do: @micro, else: 1) <= ground end)
    rest = connected(:queue.from_list(seeds), MapSet.difference(parts, MapSet.new(seeds)), micros, macros)
    %{status: :checked, macro_cells: Enum.sort(for {:macro, p} <- rest, do: p),
      micro_cells: Enum.sort(for {:micro, p} <- rest, do: p)}
  end
  defp connected(queue, rest, micros, macros) do
    case :queue.out(queue) do
      {:empty, _} -> rest
      {{:value, part}, queue} ->
        neighbors = neighbors(part) |> Enum.map(fn p ->
          cond do
            Map.has_key?(micros, p) -> {:micro, p}
            Map.has_key?(macros, macro(p)) -> {:macro, macro(p)}
            true -> nil
          end
        end) |> Enum.filter(&MapSet.member?(rest, &1)) |> MapSet.new()
        connected(Enum.reduce(neighbors, queue, &:queue.in/2), MapSet.difference(rest, neighbors), micros, macros)
    end
  end
  defp neighbors({:micro, p}), do: for(a <- 0..2, sign <- [-1, 1], do: put_elem(p, a, elem(p, a) + sign))
  defp neighbors({:macro, p}) do
    base = p |> Tuple.to_list() |> Enum.map(&(&1 * @micro)) |> List.to_tuple()
    for axis <- 0..2, face <- [-1, @micro], u <- 0..(@micro - 1), v <- 0..(@micro - 1) do
      a = rem(axis + 1, 3); b = rem(axis + 2, 3)
      base |> put_elem(axis, elem(base, axis) + face) |> put_elem(a, elem(base, a) + u) |> put_elem(b, elem(base, b) + v)
    end
  end

  defp views(micros, macros, {lo, hi}) do
    low = macro(lo)
    high = hi |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1 - 1, @micro)) |> List.to_tuple()
    fine = micros |> Map.keys() |> Enum.map(&macro/1) |> MapSet.new()
    glyph = fn p -> cond do
      Map.has_key?(macros, p) -> if(kind(Map.fetch!(macros, p)) == :solid, do: "#", else: "~")
      MapSet.member?(fine, p) -> "+"
      true -> "."
    end end
    xs = elem(low, 0)..elem(high, 0); ys = elem(low, 1)..elem(high, 1); zs = elem(low, 2)..elem(high, 2)
    layers = for y <- ys, do: %{macro_y: y, text: Enum.map_join(zs, "\n", fn z -> Enum.map_join(xs, &glyph.({&1, y, z})) end)}
    project = fn values -> Enum.find(values, ".", &(&1 != ".")) end
    front = Enum.map_join(Enum.reverse(ys), "\n", fn y -> Enum.map_join(xs, fn x -> project.(Enum.map(zs, &glyph.({x,y,&1}))) end) end)
    side = Enum.map_join(Enum.reverse(ys), "\n", fn y -> Enum.map_join(zs, fn z -> project.(Enum.map(xs, &glyph.({&1,y,z}))) end) end)
    %{resolution: :macro, legend: "# solid macro; + micro detail (not a solid macro); ~ non-walkable material; . draft air",
      layers: layers, elevations: %{front: front, side: side}}
  end
end
