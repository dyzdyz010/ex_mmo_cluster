defmodule SceneServer.Movement.Path do
  @moduledoc """
  全局系统功能：macro 格上的步行寻路。纯函数：不认识 NPC、不调 World、不持有状态；调用方给一份占用快照，
  用完即弃。“能站在哪、能迈到哪”的规则只在这里定义一次；规则与 `test/fixtures/movement_path_cases.json`
  的冻结样例一起构成契约，将来客户端的 C++ 实现对同一份样例。

  `grid` 是 `%{{x, y, z} => :open | :solid}`：`:open` = 可穿过的空气格，`:solid` = 能踩的实心格；
  不在表里的格（液体、快照之外的未知）既不能穿过也不能踩——缺失不冒充空气。
  `grid` 也可为一元坐标查询函数，返回同样的格类型；草稿检查可直接查询稀疏宏格／micro，避免展开空气表。

  规则（`height` = 角色占的格数，`step` = 不起跳能迈上的格数，二者来自权威下发的移动 profile）：
    * 站立格：自身及其上共 `height` 格 `:open`，脚下一格 `:solid`。
    * 只走 4 邻接，每步代价 1：平走；上 1..`step` 格（起步列头顶要有同样多的净空）；
      下落任意格数（落点列从起步高度到落点都 `:open`），落在遇到的第一个站立格。
    * 不起跳、不走对角。

  `smooth/7` 把格路径拉直成要依次走到的水平点：同一层上，只要胶囊（半径 `radius`）扫过的每一列都是这一层的
  站立格，中间的格心就跳过；换层的那一步不跳，仍走格心。开阔平地上结果就是 `[目标点]`，即原来的直线。
  """

  @doc """
  从 `start`（脚所在的格；悬空时先落到正下方第一个站立格）走到 `{gx, gz}` 列的站立格（给了 `goal_y` 就只认那一层）。
  返回 `{:ok, [cell]}`（不含起点、含终点；已在终点时为空表）或 `:no_path`。
  可选 `max_nodes` 限制本次发现的节点数；耗尽返回 `{:error, :search_limit}`，不冒充没有路径。
  """
  def find(grid, {sx, sy, sz}, {gx, gz}, goal_y, step, height, opts \\ []) do
    case land(grid, {sx, sy, sz}, height) do
      nil ->
        :no_path

      start ->
        goal? = fn {x, y, z} -> x == gx and z == gz and (goal_y == nil or y == goal_y) end
        estimate = fn {x, _, z} -> abs(gx - x) + abs(gz - z) end
        queue = :gb_sets.singleton({estimate.(start), 0, start})
        search(queue, %{start => nil}, goal?, estimate, {grid, step, height, Keyword.get(opts, :max_nodes, :infinity)})
    end
  end

  @doc "只读脚点诊断：复用寻路的站立与下落规则，不改变起点接纳。"
  def position(grid, cell, height), do: %{standable: standable?(grid,cell,height),landed: land(grid,cell,height)}

  @doc """
  `cells` 是 `find/6` 的结果，`from` / `target` 是水平点 `{x, z}`（target 在最后一格内），`level` 是起步所站的层。
  返回依次要走到的点，最后一个恒为 `target`。
  """
  def smooth(_grid, _from, _level, [], target, _radius, _height), do: [target]

  def smooth(grid, from, level, cells, target, radius, height) do
    # 每格的落脚点：最后一格用精确目标，其余用格心。
    points =
      cells
      |> Enum.map(fn {x, y, z} -> {{x + 0.5, z + 0.5}, y} end)
      |> List.replace_at(-1, {target, cells |> List.last() |> elem(1)})

    pull(grid, from, level, points, radius, height)
  end

  defp pull(_grid, _from, _level, [], _radius, _height), do: []

  defp pull(grid, from, level, [{next, next_level} | _] = points, radius, height) do
    # 同层且扫掠净空的最远点；一个都没有就走紧邻的下一格（那一步由 find/6 保证可走）。
    {reached, rest} =
      points
      |> Enum.take_while(fn {_, y} -> y == level end)
      |> Enum.with_index(1)
      |> Enum.filter(fn {{point, _}, _} -> swept?(grid, from, point, level, radius, height) end)
      |> List.last()
      |> case do
        nil -> {{next, next_level}, tl(points)}
        {far, count} -> {far, Enum.drop(points, count)}
      end

    {point, reached_level} = reached
    [point | pull(grid, point, reached_level, rest, radius, height)]
  end

  defp swept?(grid, {ax, az}, {bx, bz}, level, radius, height) do
    samples = max(1, ceil(:math.sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az)) / 0.2))

    Enum.all?(0..samples, fn i ->
      {x, z} = {ax + (bx - ax) * i / samples, az + (bz - az) * i / samples}

      Enum.all?([{-radius, -radius}, {-radius, radius}, {radius, -radius}, {radius, radius}], fn {dx, dz} ->
        standable?(grid, {floor(x + dx), level, floor(z + dz)}, height)
      end)
    end)
  end

  defp search(_queue, came, _goal?, _estimate, {_, _, _, limit}) when is_integer(limit) and map_size(came) > limit,
    do: {:error, :search_limit}

  defp search(queue, came, goal?, estimate, rules) do
    if :gb_sets.is_empty(queue) do
      :no_path
    else
      {{_, cost, cell}, queue} = :gb_sets.take_smallest(queue)

      if goal?.(cell) do
        {:ok, trace(came, cell, [])}
      else
        {queue, came} =
          for next <- moves(rules, cell), not is_map_key(came, next), reduce: {queue, came} do
            {queue, came} ->
              {:gb_sets.add({cost + 1 + estimate.(next), cost + 1, next}, queue), Map.put(came, next, cell)}
          end

        search(queue, came, goal?, estimate, rules)
      end
    end
  end

  defp trace(came, cell, path) do
    case came[cell] do
      nil -> path
      previous -> trace(came, previous, [cell | path])
    end
  end

  defp moves({grid, step, height, _limit}, {x, y, z}) do
    for {dx, dz} <- [{1, 0}, {-1, 0}, {0, 1}, {0, -1}],
        next = step_to(grid, {x, y, z}, {x + dx, z + dz}, step, height),
        next != nil,
        do: next
  end

  defp step_to(grid, {x, y, z}, {nx, nz}, step, height) do
    up =
      Enum.find(1..step//1, fn k ->
        standable?(grid, {nx, y + k, nz}, height) and
          Enum.all?(1..k, &(sample(grid, {x, y + height - 1 + &1, z}) == :open))
      end)

    cond do
      standable?(grid, {nx, y, nz}, height) -> {nx, y, nz}
      up -> {nx, y + up, nz}
      clear?(grid, {nx, y, nz}, height) -> land(grid, {nx, y - 1, nz}, height)
      true -> nil
    end
  end

  # 沿列向下找第一个站立格；途中遇到非 :open 的格（实心、液体、未知）就停。
  defp land(grid, {x, y, z} = cell, height) do
    cond do
      standable?(grid, cell, height) -> cell
      sample(grid, cell) == :open -> land(grid, {x, y - 1, z}, height)
      true -> nil
    end
  end

  defp clear?(grid, {x, y, z}, height), do: Enum.all?(0..(height - 1), &(sample(grid, {x, y + &1, z}) == :open))

  defp standable?(grid, {x, y, z} = cell, height),
    do: clear?(grid, cell, height) and sample(grid, {x, y - 1, z}) == :solid

  defp sample(query, cell) when is_function(query, 1), do: query.(cell)
  defp sample(grid, cell), do: Map.get(grid, cell)
end
