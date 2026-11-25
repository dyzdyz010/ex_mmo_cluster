defmodule SceneServer.Movement.Path do
  @moduledoc """
  全局系统功能：macro 格上的步行寻路。纯函数：不认识 NPC、不调 World、不持有状态；调用方给一份占用快照，
  用完即弃。“能站在哪、能迈到哪”的规则只在这里定义一次；规则与 `test/fixtures/movement_path_cases.json`
  的冻结样例一起构成契约，将来客户端的 C++ 实现对同一份样例。

  `grid` 是 `%{{x, y, z} => :open | :solid}`：`:open` = 可穿过的空气格，`:solid` = 能踩的实心格；
  不在表里的格（液体、细化格、快照之外的未知）既不能穿过也不能踩——缺失不冒充空气。哪些格进表由调用方按自己的
  碰撞判据决定。
  `grid` 也可为一元坐标查询函数，返回同样的格类型；草稿检查可直接查询稀疏宏格／micro，避免展开空气表。

  规则（`height` = 角色占的格数，`step` = 不起跳能迈上的格数，二者来自权威下发的移动 profile）：
    * 站立格：自身及其上共 `height` 格 `:open`，脚下一格 `:solid`。
    * 只走 4 邻接，每步代价 1：平走；上 1..`step` 格（起步列头顶要有同样多的净空）；
      下落任意格数（落点列从起步高度到落点都 `:open`），落在遇到的第一个站立格。
    * 不起跳、不走对角。

  `smooth/7` 把格路径拉直成要依次走到的水平点：同一层上，只要胶囊（半径 `radius`）扫过的每一列都是这一层的
  站立格，中间的格心就跳过；换层的那一步不跳，仍走格心。开阔平地上结果就是 `[目标点]`，即原来的直线。

  `find_with_edits/7` 在同一套规则上多两种“改格”的走法（敲掉挡路的实心格、放一格当脚下的地），代价由调用方给；
  它只规划、不改任何东西，供 NPC 的路线查询列候选（决策稿 docs/10-active/cross-cutting/2026-11-24-npc-route-and-teleport-decision.md §5.2）。
  """

  @doc """
  从 `start`（脚所在的格；悬空时先落到正下方第一个站立格）走到 `{gx, gz}` 列的站立格（给了 `goal_y` 就只认那一层）。
  返回 `{:ok, [cell]}`（不含起点、含终点；已在终点时为空表）或 `:no_path`。
  可选 `max_nodes` 限制本次发现的节点数；耗尽返回 `{:error, :search_limit}`，不冒充没有路径。

  可选 `trusted_start: true`：`start` 是身体的权威位置（调用方担保身体此刻就在那里）。落不到站立格（起点格或下落途中
  遇到不在表里的格，如身体站在细化格空着的部分、站在细化格上面）时以起点本身为站立格出发，不回 `:no_path`：网格是对
  碰撞几何的保守离散，身体所在之处不能因离散而被判成去不了（2026-10-08 run06：建设者站进自己放的面板格后对任何目标
  都 no_path）。能落地时照旧先落地。缺省 false：假设的起点（草稿检查的入口点）照旧必须能落到站立格。
  """
  def find(grid, {sx, sy, sz}, {gx, gz}, goal_y, step, height, opts \\ []) do
    landed = land(grid, {sx, sy, sz}, height)

    case if(Keyword.get(opts, :trusted_start, false), do: landed || {sx, sy, sz}, else: landed) do
      nil ->
        :no_path

      start ->
        goal? = fn {x, y, z} -> x == gx and z == gz and (goal_y == nil or y == goal_y) end
        estimate = fn {x, _, z} -> abs(gx - x) + abs(gz - z) end
        queue = :gb_sets.singleton({estimate.(start), 0, start})

        search(
          queue,
          %{start => nil},
          goal?,
          estimate,
          {grid, step, height, Keyword.get(opts, :max_nodes, :infinity)}
        )
    end
  end

  @doc """
  带改格的寻路（只规划，不改任何东西）。站立、迈步、下落沿用 `find/7` 的规则，另允许两种改格：

    * **敲**：迈进下一列时身体要占的格、上台阶时起步列头顶要让出的净空格里，`:solid` 的格可以敲掉；
    * **放**：下一列脚下那一格是 `:open` 时可以放一格当地面（垫一级台阶、搭过一格的空）。

  不在表里的格（液体、细化格、快照之外的未知）既不能敲也不能放。下落途中不改格。

  `edit` 是调用方给的代价函数 `(:dig | :place, cell) -> 代价 | :forbidden`，代价以“走一步 = 1”为单位。
  Path 不认识材料、保护区与余额：哪些格能改、改一格算多少，都由调用方决定。
  `goals` 是目标站立格（脚所在的格）的集合，到其中任一格即算到；空集合回 `:no_path`。
  `start` 与可选 `trusted_start`、`max_nodes` 同 `find/7`。

  每一步都在“原地形 + 这条路此前各步的改格”上判（已敲掉的格算空气、已放的格算实心，不重复计代价），
  所以给出的路线按顺序执行时，每一步相对这份快照都成立。去重按站立格，有改格时不保证全局最省。
  返回 `{:ok, %{steps: [%{to: 格, dig: [格], place: [格]}], cost: 代价}}`（不含起点）、`:no_path`
  或 `{:error, :search_limit}`。同一步里 `dig` 先列起步列头顶的格（自下而上），再列目标列的身体格（自上而下），
  `place` 在 `dig` 之后做；够不够得着、敲不敲得动仍由执行时的权威裁决。
  `edit` 对任何格都回 `:forbidden` 时，与 `find/7` 走的是同一种路。
  """
  def find_with_edits(grid, start, goals, step, height, edit, opts \\ []) do
    landed = land(grid, start, height)
    from = if Keyword.get(opts, :trusted_start, false), do: landed || start, else: landed

    if from == nil or MapSet.size(goals) == 0 do
      :no_path
    else
      {xs, zs} = goals |> Enum.map(fn {x, _, z} -> {x, z} end) |> Enum.unzip()
      {x0, x1} = Enum.min_max(xs)
      {z0, z1} = Enum.min_max(zs)

      # 到目标列外接矩形的水平距离：每步至少代价 1、至多换一列，所以不高估。
      estimate = fn {x, _, z} -> outside(x, x0, x1) + outside(z, z0, z1) end

      weighted(
        :gb_sets.singleton({estimate.(from), 0, from}),
        %{from => %{g: 0, parent: nil, step: nil, overlay: %{}}},
        MapSet.new(),
        {goals, estimate},
        {grid, step, height, edit},
        Keyword.get(opts, :max_nodes, :infinity)
      )
    end
  end

  @doc "只读脚点诊断：复用寻路的站立与下落规则，不改变起点接纳。"
  def position(grid, cell, height),
    do: %{standable: standable?(grid, cell, height), landed: land(grid, cell, height)}

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

      Enum.all?(
        [{-radius, -radius}, {-radius, radius}, {radius, -radius}, {radius, radius}],
        fn {dx, dz} ->
          standable?(grid, {floor(x + dx), level, floor(z + dz)}, height)
        end
      )
    end)
  end

  defp search(_queue, came, _goal?, _estimate, {_, _, _, limit})
       when is_integer(limit) and map_size(came) > limit,
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
              {:gb_sets.add({cost + 1 + estimate.(next), cost + 1, next}, queue),
               Map.put(came, next, cell)}
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

  # 带权 A*：代价不再都是 1，所以按出队定型（closed），同一格找到更省的到达方式时更新。每个节点带着从起点到它
  # 这一路的改格（overlay：格 → :open | :solid），后续的走法在“原地形 + overlay”上判。
  defp weighted(_queue, nodes, _closed, _goal, _rules, limit)
       when is_integer(limit) and map_size(nodes) > limit,
       do: {:error, :search_limit}

  defp weighted(queue, nodes, closed, {goals, estimate} = goal, rules, limit) do
    if :gb_sets.is_empty(queue) do
      :no_path
    else
      {{_, g, cell}, queue} = :gb_sets.take_smallest(queue)
      node = Map.fetch!(nodes, cell)

      cond do
        # 已定型的格，或这一项是被更省的到达方式取代后留下的旧项。
        MapSet.member?(closed, cell) or g > node.g ->
          weighted(queue, nodes, closed, goal, rules, limit)

        MapSet.member?(goals, cell) ->
          {:ok, %{steps: route(nodes, cell, []), cost: g}}

        true ->
          {queue, nodes} =
            for {next, cost, step} <- edit_moves(rules, cell, node.overlay),
                not MapSet.member?(closed, next),
                reduce: {queue, nodes} do
              {queue, nodes} ->
                reached = g + cost

                case nodes do
                  %{^next => %{g: known}} when known <= reached ->
                    {queue, nodes}

                  _ ->
                    {:gb_sets.add({reached + estimate.(next), reached, next}, queue),
                     Map.put(nodes, next, %{
                       g: reached,
                       parent: cell,
                       step: step,
                       overlay: apply_edits(node.overlay, step)
                     })}
                end
            end

          weighted(queue, nodes, MapSet.put(closed, cell), goal, rules, limit)
      end
    end
  end

  defp route(nodes, cell, steps) do
    case Map.fetch!(nodes, cell) do
      %{parent: nil} -> steps
      %{parent: parent, step: step} -> route(nodes, parent, [step | steps])
    end
  end

  defp apply_edits(overlay, %{dig: dig, place: place}) do
    overlay = Enum.reduce(dig, overlay, &Map.put(&2, &1, :open))
    Enum.reduce(place, overlay, &Map.put(&2, &1, :solid))
  end

  defp outside(v, lo, _hi) when v < lo, do: lo - v
  defp outside(v, _lo, hi) when v > hi, do: v - hi
  defp outside(_v, _lo, _hi), do: 0

  # 一格的四个邻列，每列可能有几种到法：高 0..step 格处（平走或上台阶，可带改格）与下落。
  # 不改格时每列至多一种到法，且与 step_to/5 相同（平走、上台阶、下落三者的条件互斥）。
  defp edit_moves({grid, step, height, edit}, {x, _y, z} = from, overlay) do
    view = fn cell -> Map.get(overlay, cell) || sample(grid, cell) end

    for {dx, dz} <- [{1, 0}, {-1, 0}, {0, 1}, {0, -1}],
        move <- column_moves(view, edit, from, {x + dx, z + dz}, step, height),
        do: move
  end

  defp column_moves(view, edit, from, column, step, height) do
    rises =
      for k <- 0..step, move = rise(view, edit, from, column, k, height), move != nil, do: move

    rises ++ List.wrap(drop(view, edit, from, column, height))
  end

  # 迈到下一列高 k 格处（k = 0 是平走）：起步列头顶要让出 k 格净空，目标列身体格要空，脚下一格要实心；
  # 挡着的实心格可以敲掉，脚下缺的空气格可以放一格。
  defp rise(view, edit, {x, y, z}, {nx, nz}, k, height) do
    headroom = for i <- 1..k//1, do: {x, y + height - 1 + i, z}
    body = for i <- (height - 1)..0//-1, do: {nx, y + k + i, nz}
    to = {nx, y + k, nz}

    with {:ok, dig, dig_cost} <- clear_cost(view, edit, headroom ++ body),
         {:ok, place, place_cost} <- floor_cost(view, edit, {nx, y + k - 1, nz}) do
      {to, 1 + dig_cost + place_cost, %{to: to, dig: dig, place: place}}
    else
      _ -> nil
    end
  end

  # 下一列身体格空（或敲掉）而脚下是空气：落到这一列第一个站立格；下落途中不改格。
  defp drop(view, edit, {_x, y, _z}, {nx, nz}, height) do
    body = for i <- (height - 1)..0//-1, do: {nx, y + i, nz}

    with :open <- view.({nx, y - 1, nz}),
         {:ok, dig, dig_cost} <- clear_cost(view, edit, body),
         dug = fn cell -> if cell in dig, do: :open, else: view.(cell) end,
         to when to != nil <- land(dug, {nx, y - 1, nz}, height) do
      {to, 1 + dig_cost, %{to: to, dig: dig, place: []}}
    else
      _ -> nil
    end
  end

  # 这些格要成为空气：:open 不用改；:solid 按 edit 敲掉；不在表里的格、或 edit 不许敲的格，这一走法不成立。
  defp clear_cost(view, edit, cells) do
    Enum.reduce_while(cells, {:ok, [], 0}, fn cell, {:ok, dig, cost} ->
      with :solid <- view.(cell),
           {:ok, amount} <- price(edit.(:dig, cell)) do
        {:cont, {:ok, [cell | dig], cost + amount}}
      else
        :open -> {:cont, {:ok, dig, cost}}
        _ -> {:halt, :blocked}
      end
    end)
    |> case do
      {:ok, dig, cost} -> {:ok, Enum.reverse(dig), cost}
      :blocked -> :blocked
    end
  end

  # 脚下这一格要实心：:solid 不用改；:open 按 edit 放一格；不在表里的格、或 edit 不许放的格，这一走法不成立。
  defp floor_cost(view, edit, cell) do
    with :open <- view.(cell),
         {:ok, amount} <- price(edit.(:place, cell)) do
      {:ok, [cell], amount}
    else
      :solid -> {:ok, [], 0}
      _ -> :blocked
    end
  end

  defp price(:forbidden), do: :blocked
  defp price(amount) when is_number(amount) and amount >= 0, do: {:ok, amount}

  # 沿列向下找第一个站立格；途中遇到非 :open 的格（实心、液体、未知）就停。
  defp land(grid, {x, y, z} = cell, height) do
    cond do
      standable?(grid, cell, height) -> cell
      sample(grid, cell) == :open -> land(grid, {x, y - 1, z}, height)
      true -> nil
    end
  end

  defp clear?(grid, {x, y, z}, height),
    do: Enum.all?(0..(height - 1), &(sample(grid, {x, y + &1, z}) == :open))

  defp standable?(grid, {x, y, z} = cell, height),
    do: clear?(grid, cell, height) and sample(grid, {x, y - 1, z}) == :solid

  defp sample(query, cell) when is_function(query, 1), do: query.(cell)
  defp sample(grid, cell), do: Map.get(grid, cell)
end
