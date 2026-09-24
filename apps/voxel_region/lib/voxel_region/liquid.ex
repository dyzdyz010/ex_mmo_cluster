defmodule VoxelRegion.Liquid do
  @moduledoc """
  Global system：单一流动材料（液体，或 R8-07 可倾倒散体）的有限宏格数量计算，不持有世界或库存状态。
  World 按材料分组逐种调用同一内核；散体与液体的唯一区别是侧向阈值（散体取目录 loose_threshold_units）：
  静止时同层相邻格数量差不超过阈值（+7 量子截断），即休止角的离散版本。

  输入为 canonical Y-up 宏格坐标到正整数库存量子的稀疏表。容量、单步下落和
  侧向流量上限由已发布参数换算后传入，不能从显示高度反推水量。
  每步先同步下落，再同步侧向平衡；返回含零值删除的稀疏变化供 World 一次提交。
  open? 读取完整权威占用：空气或同种水可接收，实体宏格容器阻挡，与客户端驻留无关。
  bounds 为实际计算域的半开 XYZ 盒；域边界封闭，不丢弃流出量。

  依据：Tom Forsyth《Cellular Automata for Physical Modelling》的格点水量与双缓冲；
  https://tomforsyth1000.github.io/papers/cellular_automata_for_physical_modelling.html
  以及有限体积共享面通量相消：
  https://www.clawpack.org/riemann_book/html/Approximate_solvers.html
  本增量只保留重力与同层平衡，不建速度、压缩或向上传压，不能模拟压力管。
  四邻面差值除以八保证每次侧向更新至少保留一半原量，避免棋盘振荡。
  整数截断保留不足八量子的水位差，绝不删除小余量。
  """

  @doc "从同一权威输入计算一步液量变化；每个阶段只读取阶段开始时的量。"
  def step(water, bounds, capacity, gravity_limit, side_limit, open?) do
    {changes, _stages} = step_transfers(water, bounds, capacity, gravity_limit, side_limit, open?)
    changes
  end

  # Global system: expose the actual fluxes for thermal/integrity advection.
  # connected?(a, b)：同层两格之间是否允许侧流（受保护区域边界为 false）；nil 表示全部连通。
  def step_transfers(water, bounds, capacity, gravity_limit, side_limit, open?, threshold \\ 0, active \\ nil, connected? \\ nil) do
    sources = if active == nil, do: water, else: Map.take(water, Enum.to_list(active))
    {gravity, down} =
      Enum.reduce(sources, {%{}, []}, fn {{x, y, z} = from, quantity}, {deltas, flows} ->
        to = {x, y - 1, z}

        if available?(to, bounds, open?) and open?.(from) do
          flow = min(quantity, min(capacity - Map.get(water, to, 0), gravity_limit))
          {flux(deltas, from, to, flow), transfer(flows, from, to, flow)}
        else
          {deltas, flows}
        end
      end)

    fallen = apply_changes(water, offsets(water, gravity))

    side_cells = if active == nil, do: Map.keys(fallen),
      else: Enum.uniq(Enum.to_list(active) ++ Map.keys(gravity))
    {sides, sideways} =
      side_cells
      |> Enum.flat_map(fn {x, y, z} = cell ->
        for neighbor <- [{x - 1, y, z}, {x + 1, y, z}, {x, y, z - 1}, {x, y, z + 1}] do
          if cell < neighbor, do: {cell, neighbor}, else: {neighbor, cell}
        end
      end)
      |> Enum.uniq()
      |> Enum.reduce({%{}, []}, fn {a, b}, {deltas, flows} ->
        if available?(a, bounds, open?) and available?(b, bounds, open?) and
             (connected? == nil or connected?.(a, b)) do
          difference = Map.get(fallen, a, 0) - Map.get(fallen, b, 0)
          flow = min(div(max(abs(difference) - threshold, 0), 8), side_limit)
          {from,to} = if difference > 0, do: {a,b}, else: {b,a}
          {flux(deltas,from,to,flow), transfer(flows,from,to,flow)}
        else
          {deltas, flows}
        end
      end)

    next = apply_changes(fallen, offsets(fallen, sides))
    changes = Map.merge(gravity, sides, fn _cell, down, side -> down + side end)
    |> Map.new(fn {cell, _} -> {cell, Map.get(next, cell, 0)} end)
    |> Map.reject(fn {cell, quantity} -> Map.get(water, cell, 0) == quantity end)
    {changes, [{water, down}, {fallen, sideways}]}
  end

  @doc "实际重力通量的目的格和量子整帧；净数量抵消不消除已经发生的下落。"
  def fall_transfers([{_, gravity}, {_, _sideways}]) do
    gravity |> Enum.map(fn {_from, to, units} -> {to, units} end) |> Enum.sort()
  end

  @doc "Changed cells and their six neighbors are the only next-step candidates."
  def neighborhood(cells) do
    cells |> Enum.flat_map(fn {x,y,z}=p ->
      [p,{x-1,y,z},{x+1,y,z},{x,y-1,z},{x,y+1,z},{x,y,z-1},{x,y,z+1}]
    end) |> MapSet.new()
  end

  @doc "Actual flow endpoints also wake when opposing stage fluxes cancel the net quantity change."
  def next_active(stages) do
    stages |> Enum.flat_map(fn {_,flows} ->
      Enum.flat_map(flows,fn {from,to,_} -> [from,to] end)
    end) |> neighborhood()
  end

  @doc "盛水：从一个宏格转入既有材料余额；limit 是工具每次最多转移的库存量子。"
  def scoop(water, cell, balance, limit) do
    quantity = Map.get(water, cell, 0)
    moved = min(quantity, limit)
    result(cell, quantity - moved, balance + moved, moved)
  end

  @doc "倒水：余额与格内剩余容量共同限制转移，实体或域外不接收水。"
  def pour(water, cell, balance, limit, capacity, bounds, open?) do
    quantity = Map.get(water, cell, 0)
    moved = if available?(cell, bounds, open?), do: min(balance, min(limit, capacity - quantity)), else: 0
    result(cell, quantity + moved, balance - moved, moved)
  end

  @doc "应用本模块的纯变化值；零量删除稀疏记录，不修改调用方的输入值。"
  def apply_changes(water, changes) do
    Enum.reduce(changes, water, fn
      {cell, 0}, next -> Map.delete(next, cell)
      {cell, quantity}, next -> Map.put(next, cell, quantity)
    end)
  end

  @doc "建造排液：依次下、水平四面、上，全量可容纳才返回变化和守恒通量。"
  def displace(water, {x,y,z}=cell, capacity, bounds, open?) do
    neighbors = [{x,y-1,z},{x-1,y,z},{x+1,y,z},{x,y,z-1},{x,y,z+1},{x,y+1,z}]
    {remaining, changes, flows} = Enum.reduce(neighbors,
      {Map.fetch!(water,cell),%{cell=>0},[]}, fn to,{remaining,changes,flows} ->
        moved = if available?(to,bounds,open?),
          do: min(remaining,capacity-Map.get(water,to,0)), else: 0
        if moved > 0 do
          {remaining-moved,Map.put(changes,to,Map.get(water,to,0)+moved),[{cell,to,moved}|flows]}
        else
          {remaining,changes,flows}
        end
      end)
    if remaining == 0, do: {:ok,changes,Enum.reverse(flows)}, else: {:error,:occupied}
  end

  defp result(cell, quantity, balance, moved),
    do: %{changes: if(moved == 0, do: %{}, else: %{cell => quantity}), balance: balance, transferred_units: moved}

  defp transfer(flows, _from, _to, 0), do: flows
  defp transfer(flows, from, to, units), do: [{from,to,units}|flows]

  defp flux(deltas, _from, _to, 0), do: deltas
  defp flux(deltas, from, to, quantity) do
    deltas |> Map.update(from, -quantity, &(&1 - quantity)) |> Map.update(to, quantity, &(&1 + quantity))
  end

  defp offsets(water, deltas), do: Map.new(deltas, fn {cell, delta} -> {cell, Map.get(water, cell, 0) + delta} end)

  defp available?({x, y, z} = cell, {{lx, ly, lz}, {hx, hy, hz}}, open?),
    do: x >= lx and x < hx and y >= ly and y < hy and z >= lz and z < hz and open?.(cell)
end
