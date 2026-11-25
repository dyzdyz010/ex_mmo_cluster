defmodule NpcServer.Route do
  @moduledoc """
  全局系统功能（只读）：路线查询 `find_route`。从身体的权威位置到一个区域，按客观类别列出至多三条最省的路线——
  **只走**、**允许敲**、**允许敲和放**——每条写成依次调用的原子（`move_to` / `dig_cell` / `place` 的实参）与代价事实；
  列不出的类别写原因。不写世界、不进心智、不留体素副本。决策稿
  docs/10-active/cross-cutting/2026-11-24-npc-route-and-teleport-decision.md §5.2（下称 U-31 稿）。

  ```mermaid
  flowchart LR
    B["Body：find_route 命令<br/>prepare/3 校验范围"] --> W["执行进程：find/3"]
    W --> S["World.material_snapshot<br/>（规划盒外加一圈）"]
    W --> P["World.protected_cells<br/>material_catalog / tool_definition / material_balances"]
    S --> G["网格：Perception.walk_kind/1"]
    P --> C["改格代价（秒 → 步）"]
    G --> F["Path.find_with_edits/7 × 3"]
    C --> F
    F --> A["回答：routes / omitted / undiggable"]
  ```

  **规划盒**：起点列与区域的外接矩形各边水平外扩 `NpcServer.Body.path_margin/0` 格，竖直取脚所在格上下同样多格（与 `move_to`
  取盒同一外扩量）。一次 `World.material_snapshot/3`（与 look、`move_to` 同一只读入口）取规划盒外加一圈的格：多的一圈只用来判
  “挨着液体”，于是规划盒里每一格的六邻都已知。网格与 `move_to` 同一判据（`NpcServer.Perception.walk_kind/1`）。
  **目标**：区域里每一列在规划盒竖直范围内最高的站立层（survey 的 `move_to_y` 那一层，`Perception.floors/2`），到任一列即算到。

  **代价**（秒；交给 `Path` 时按“走一步 = 1”换算）：
  - 走一步 = `1 / speed` 秒（权威下发的移动 profile，1 格 = 1 米）；
  - 敲一格 = `dig_cost/2`：次数 ⌈满血 / 每击伤害⌉ × 工具间隔，每击伤害与 World 工具结算同一公式（`VoxelRegion.Damage.amount/3`）；
  - 放一格 = 一次工具动作的时间（这把工具的间隔）——World 不限放置频率，按“一个动作”计；材料另计（格数 × 每格单位）。
  **不敲**（代价无穷）：保护区（`World.protected_cells/3`）、伤害为 0、有别人的放置记录、六邻里有液体（mineflayer-pathfinder
  `dontCreateFlow`）。细化格、液体与未知格本来就不在网格里，既不能敲也不能放。**不放**：保护区。
  **放的材料**（客观规则）：余额里能放、挡路、非液体、够一格的生产材料中，够放格数最多的一种（同数取材料号小的）。

  **回答**（Body Outcome 的 data）：`%{seq, start, region, tool_id, step_seconds, goals, routes, omitted, undiggable}`。
  `routes` 每条 `%{kind: :walk | :dig | :dig_place, calls: [%{atom: 名, args: 实参}], moves, seconds, dig, place, end}`——
  `dig = %{cells, hits, seconds, by_material: %{材料 => 格数}}`，`place = %{cells, material, units, balance, enough}`（不放为 nil）。
  某类的最省路线没有用上这一类多出的能力（允许敲却没敲、允许放却没放），就与更简单的一类相同，不重复列（Mindcraft 先不破坏、
  再允许破坏），记进 `omitted`：`%{kind, reason}`，reason ∈ `:no_path`（规划盒有界、搜索穷尽，是确定的“没有”）、
  `:same_as_walk`、`:same_as_dig`、`:no_material`（没有可放的材料）。`undiggable` 按原因数规划盒里敲不了的实心格
  （`protected`、`ineffective`、`placed_by_other`、`liquid`）。`calls` 里只走的连续几步合成一次 `move_to`，但每段都落在
  `move_to` 自己的取盒里（起终点外接盒外扩同一 margin、单程不超过 reach），执行时它按自己的盒也找得到这段路；
  改格前先 `move_to` 到规划的站位，再按 `Path` 给的次序 `dig_cell`、`place`。

  已知限制：满血按目录估（快照不带已受的伤），敲的次数是上限；作者 prefab 宏格（只记 macro_owners）在快照里看不出，规划会当天然格，
  执行时 `dig_cell` 以 `foreign` 拒绝；规划后世界变了，某步被权威拒绝，失败照常写成事实（U-31 稿 §8）。
  """
  require Logger
  alias MmoContracts.VoxelMaterialCatalog
  alias NpcServer.{Body, Context, Perception}
  alias SceneServer.Movement.Path
  alias VoxelRegion.{Damage, Phase, World}

  # 不给 Path 节点上限：规划盒本身有界（水平 ≤ 45、竖直 13 格），最坏情形（全岩体处处可敲、目标不可达）穷尽搜索一次约 0.48 s
  # （2 个调度器，U-31 稿 §10 实测），三类合计约 1.5 s，所以每个 no_path 都是确定的“没有”，不必用 search_limit 截断。
  @kinds [:walk, :dig, :dig_place]

  @doc "能力条目（group `:sense`，形状见 `NpcServer.Abilities`）。"
  def entries do
    reach = Perception.reach()
    columns = Perception.survey_columns()

    [
      %{
        name: "find_route",
        group: :sense,
        description:
          "查从自己现在的位置到区域 (x0,z0)–(x1,z1)（整数列闭区间，每边最多 #{columns} 列、各边离自己不超过 #{reach} 米）里任一站立处的路线，" <>
            "不改世界。按三类各列最省的一条：walk 只走；dig 允许用 tool_id 敲掉挡路的天然格；dig_place 还允许在脚下缺地处放一格。" <>
            "每条给出依次调用的原子 calls（move_to / dig_cell / place 的实参，按顺序照做即可）、步数、要敲几格（按材料分）、约几击几秒、" <>
            "要放几格、用哪种材料多少、余额够不够、总秒数与终点。某类与更简单的一类相同就不重复列；列不出的类别在 omitted 里写原因：" <>
            "no_path = 附近没有这类路线，no_material = 没有能放的材料。" <>
            "undiggable 数出附近敲不了的格：protected（别人的保护区）、ineffective（这把工具敲不动）、placed_by_other（别人放的）、liquid（挨着液体）。",
        done: "data 是查询那一刻的世界（seq 为版本）算出的路线，不改世界；照做时每一步仍由权威裁决。",
        params: [x0: :integer, z0: :integer, x1: :integer, z1: :integer, tool_id: :belt],
        build: fn p, _ ->
          %{verb: :find_route, min: {p.x0, p.z0}, max: {p.x1, p.z1}, tool_id: p.tool_id}
        end
      }
    ]
  end

  @doc """
  以身体的权威位置与移动 profile 校验一次查询（非法参数不访问 World）：区域是整数列闭区间、每边不超过
  `Perception.survey_columns/0` 列、各边离自己不超过 `Perception.reach/0` 米（同 survey）。返回 `{:route, plan}`；
  区域太大 `{:error, :region_too_large}`、太远 `{:error, :too_far}`；形状不对 nil。
  """
  def prepare(
        {px, py, pz},
        profile,
        %{verb: :find_route, min: {x0, z0}, max: {x1, z1}, tool_id: tool}
      )
      when is_integer(x0) and is_integer(z0) and is_integer(x1) and is_integer(z1) and
             x0 <= x1 and z0 <= z1 and is_integer(tool) do
    reach = Perception.reach()
    columns = Perception.survey_columns()

    cond do
      x1 - x0 >= columns or z1 - z0 >= columns ->
        {:error, :region_too_large}

      x0 < px - reach or x1 > px + reach or z0 < pz - reach or z1 > pz + reach ->
        {:error, :too_far}

      true ->
        {:route,
         %{
           start: Body.foot({px, py, pz}, profile.half_height),
           region: {x0, z0, x1, z1},
           tool_id: tool,
           step: floor(profile.step_height),
           height: Context.clearance(profile),
           step_seconds: 1 / profile.speed
         }}
    end
  end

  def prepare(_position, _profile, _command), do: nil

  @doc """
  敲掉一格的次数与秒数（纯函数）：每击伤害 = `VoxelRegion.Damage.amount(材料行, 工具行, 0)`（max(0, 威力 − 防御) × 按动作名最长前缀
  取的倍率，与 World 工具结算同一公式），次数 = ⌈满血 `max_hp_per_macro` / 每击伤害⌉，秒数 = 次数 × 工具间隔。返回
  `{:ok, 次数, 秒数}`；伤害为 0 或工具不是伤害类动作（`damage` / `damage.*`）→ `:ineffective`（World 回 `ineffective_tool`）。
  """
  def dig_cost(material, tool) do
    damage = if damage_tool?(tool), do: Damage.amount(material, tool, 0), else: 0.0

    if damage > 0 do
      hits = ceil(material["max_hp_per_macro"] / damage)
      {:ok, hits, hits * tool["interval_seconds"]}
    else
      :ineffective
    end
  end

  # World 工具结算对伤害类动作走 `Damage.amount/3`（材料都带 damage 响应，目录加载时校验）；别的动作没有“敲掉一格”。
  defp damage_tool?(%{"action" => action}),
    do: action == "damage" or String.starts_with?(action, "damage.")

  @doc """
  执行一次查询（Body 执行进程里调用；`plan` 来自 `prepare/3`）。返回 `{:ok, 回答}`（形状见 moduledoc），工具不在目录里
  `{:error, :invalid_tool}`。
  """
  def find(world, cid, plan) do
    case World.tool_definition(world, plan.tool_id) do
      {:ok, tool} -> {:ok, answer(world, cid, plan, tool)}
      :error -> {:error, :invalid_tool}
    end
  end

  defp answer(world, cid, %{start: {sx, sy, sz} = start, region: {x0, z0, x1, z1}} = plan, tool) do
    started = System.monotonic_time(:millisecond)
    margin = Body.path_margin()
    {bx0, bx1} = {min(sx, x0) - margin, max(sx, x1) + margin}
    {bz0, bz1} = {min(sz, z0) - margin, max(sz, z1) + margin}
    {by0, by1} = {sy - margin, sy + margin}
    inside? = fn {x, y, z} -> x in bx0..bx1 and y in by0..by1 and z in bz0..bz1 end

    halo =
      for x <- (bx0 - 1)..(bx1 + 1),
          y <- (by0 - 1)..(by1 + 1),
          z <- (bz0 - 1)..(bz1 + 1),
          do: {x, y, z}

    snapshot = World.material_snapshot(world, [], halo)
    rows = Map.new(snapshot.probe_occupancy, &{List.to_tuple(&1.cell), &1})

    grid =
      for {cell, row} <- rows,
          inside?.(cell),
          kind = Perception.walk_kind(row),
          kind != nil,
          into: %{},
          do: {cell, kind}

    protected = MapSet.new(World.protected_cells(world, cid, Map.keys(grid)))
    materials = World.material_catalog(world).materials
    digs = dig_table(grid, rows, protected, materials, tool, cid)
    goals = goals(rows, plan.height, {x0, z0, x1, z1}, {by0, by1})
    placing = placing(World.material_balances(world, cid))
    to_steps = &(&1 / plan.step_seconds)

    dig = fn cell ->
      case digs[cell] do
        {:ok, _hits, seconds, _material} -> to_steps.(seconds)
        _ -> :forbidden
      end
    end

    place = fn cell ->
      if MapSet.member?(protected, cell),
        do: :forbidden,
        else: to_steps.(tool["interval_seconds"])
    end

    edits = %{
      walk: fn _, _ -> :forbidden end,
      dig: fn
        :dig, cell -> dig.(cell)
        :place, _ -> :forbidden
      end,
      dig_place: fn
        :dig, cell -> dig.(cell)
        :place, cell -> place.(cell)
      end
    }

    searched =
      for kind <- @kinds do
        result =
          if kind == :dig_place and placing == nil,
            do: :no_material,
            else:
              Path.find_with_edits(grid, start, goals, plan.step, plan.height, edits[kind],
                trusted_start: true
              )

        {kind, result}
      end

    {routes, omitted} = classify(searched)
    context = %{plan: plan, digs: digs, placing: placing}
    routes = Enum.map(routes, &describe(&1, start, context))

    undiggable =
      Enum.frequencies(for {_cell, {:blocked, reason}} <- digs, do: reason)
      |> then(&Map.merge(%{protected: 0, ineffective: 0, placed_by_other: 0, liquid: 0}, &1))

    answer = %{
      seq: snapshot.seq,
      start: Tuple.to_list(start),
      region: [x0, z0, x1, z1],
      tool_id: plan.tool_id,
      step_seconds: plan.step_seconds,
      goals: MapSet.size(goals),
      routes: routes,
      omitted: omitted,
      undiggable: undiggable
    }

    Logger.info(
      "npc_find_route cid=#{cid} start=#{inspect(start)} region=#{inspect([x0, z0, x1, z1], charlists: :as_lists)} " <>
        "routes=#{inspect(Enum.map(routes, &{&1.kind, Float.round(&1.seconds * 1.0, 2)}))} " <>
        "omitted=#{inspect(Enum.map(omitted, &{&1.kind, &1.reason}))} undiggable=#{inspect(undiggable)} " <>
        "goals=#{MapSet.size(goals)} elapsed_ms=#{System.monotonic_time(:millisecond) - started}"
    )

    answer
  end

  # 每个规划盒内的实心格敲不敲得了（一次算好，代价函数与计数共用）：`{:ok, 次数, 秒数, 材料}` 或 `{:blocked, 原因}`。
  defp dig_table(grid, rows, protected, materials, tool, cid) do
    for {cell, :solid} <- grid, into: %{} do
      row = rows[cell]

      verdict =
        cond do
          MapSet.member?(protected, cell) ->
            {:blocked, :protected}

          row.placed_by not in [nil, cid] ->
            {:blocked, :placed_by_other}

          Enum.any?(neighbours(cell), &liquid?(rows[&1])) ->
            {:blocked, :liquid}

          true ->
            case dig_cost(Map.fetch!(materials, row.material), tool) do
              {:ok, hits, seconds} -> {:ok, hits, seconds, row.material}
              :ineffective -> {:blocked, :ineffective}
            end
        end

      {cell, verdict}
    end
  end

  defp liquid?(%{material: material}), do: Phase.liquid?(material)
  defp liquid?(nil), do: false

  defp neighbours({x, y, z}),
    do: [
      {x + 1, y, z},
      {x - 1, y, z},
      {x, y + 1, z},
      {x, y - 1, z},
      {x, y, z + 1},
      {x, y, z - 1}
    ]

  # 区域里每一列在规划盒竖直范围内最高的站立层（脚所在格 = 地面 + 1）。
  defp goals(rows, height, {x0, z0, x1, z1}, {y0, y1}) do
    for x <- x0..x1,
        z <- z0..z1,
        column = for(y <- y0..y1, row = rows[{x, y, z}], row != nil, do: row),
        floors = Perception.floors(column, height),
        floors != [],
        into: MapSet.new(),
        do: {x, List.last(floors) + 1, z}
  end

  # 放的材料：能放（非液体、挡路，放下成为能踩的实心格）、余额够一格的生产材料中够放格数最多的一种，同数取材料号小的。
  defp placing(balances) do
    balances
    |> Enum.filter(fn %{material: m, balance: balance, cost: cost} ->
      not Phase.liquid?(m) and VoxelMaterialCatalog.blocks_movement?(m) and cost > 0 and
        balance >= cost
    end)
    |> Enum.min_by(fn %{material: m, balance: b, cost: c} -> {-div(b, c), m} end, fn -> nil end)
  end

  # 三类的搜索结果 → 要列的路线与不列的原因。没用上这一类多出的能力 = 与更简单的一类相同。
  defp classify(searched) do
    Enum.reduce(searched, {[], []}, fn {kind, result}, {routes, omitted} ->
      case result do
        {:ok, %{steps: steps} = found} ->
          digs? = Enum.any?(steps, &(&1.dig != []))
          places? = Enum.any?(steps, &(&1.place != []))

          cond do
            kind == :dig and not digs? ->
              {routes, omitted ++ [%{kind: kind, reason: :same_as_walk}]}

            kind == :dig_place and not places? ->
              reason = if digs?, do: :same_as_dig, else: :same_as_walk
              {routes, omitted ++ [%{kind: kind, reason: reason}]}

            true ->
              {routes ++ [Map.put(found, :kind, kind)], omitted}
          end

        :no_path ->
          {routes, omitted ++ [%{kind: kind, reason: :no_path}]}

        :no_material ->
          {routes, omitted ++ [%{kind: kind, reason: :no_material}]}
      end
    end)
  end

  defp describe(%{kind: kind, steps: steps, cost: cost}, start, context) do
    %{plan: plan, digs: digs, placing: placing} = context
    dug = Enum.flat_map(steps, & &1.dig)
    placed = Enum.flat_map(steps, & &1.place)

    dig =
      Enum.reduce(dug, %{cells: 0, hits: 0, seconds: 0.0, by_material: %{}}, fn cell, acc ->
        {:ok, hits, seconds, material} = Map.fetch!(digs, cell)

        %{
          acc
          | cells: acc.cells + 1,
            hits: acc.hits + hits,
            seconds: acc.seconds + seconds,
            by_material: Map.update(acc.by_material, material, 1, &(&1 + 1))
        }
      end)

    place =
      if placed != [] do
        units = length(placed) * placing.cost

        %{
          cells: length(placed),
          material: placing.material,
          units: units,
          balance: placing.balance,
          enough: placing.balance >= units
        }
      end

    %{
      kind: kind,
      calls: calls(steps, start, placing_material(placing), plan.tool_id),
      moves: length(steps),
      seconds: cost * plan.step_seconds,
      dig: dig,
      place: place,
      # 已在区域里时没有步，终点就是起点。
      end: Tuple.to_list(if(steps == [], do: start, else: List.last(steps).to))
    }
  end

  defp placing_material(nil), do: nil
  defp placing_material(%{material: material}), do: material

  # 路线步 → 原子调用。`from` = 这段走路开始时站的格（起点或上一次改格的站位），`walked` = 此后走过、还没发出的格。
  # 只走的步只攒进 `walked`；要改格时先把攒下的走路发出去（到改格的站位），再按 Path 的次序 dig_cell、place；最后发出剩下的走路。
  defp calls(steps, start, material, tool) do
    {calls, from, walked} =
      Enum.reduce(steps, {[], start, []}, fn %{to: to, dig: dig, place: place},
                                             {calls, from, walked} ->
        if dig == [] and place == [] do
          {calls, from, walked ++ [to]}
        else
          stand = List.last(walked) || from

          edits =
            Enum.map(dig, &call("dig_cell", &1, %{tool_id: tool})) ++
              Enum.map(place, &call("place", &1, %{material: material, tool_id: tool}))

          {calls ++ walk(from, walked) ++ edits, stand, [to]}
        end
      end)

    calls ++ walk(from, walked)
  end

  # 走过的格序列 → move_to 调用：每段终点尽量远，但整段都要落在 move_to 自己的取盒里（起终点外接盒各向外扩
  # `Body.path_margin/0`，同 Body 的寻路取盒）且各轴单程不超过 reach（同 move_to 的 too_far 判据），执行时它按自己的盒也找得到这段路。
  defp walk(_from, []), do: []

  defp walk(from, cells) do
    {targets, _origin, segment} =
      Enum.reduce(cells, {[], from, []}, fn cell, {targets, origin, segment} ->
        candidate = segment ++ [cell]

        if segment != [] and not fits?(origin, cell, candidate) do
          last = List.last(segment)
          {targets ++ [last], last, [cell]}
        else
          {targets, origin, candidate}
        end
      end)

    Enum.map(targets ++ [List.last(segment)], &move_to/1)
  end

  defp fits?({ox, oy, oz}, {tx, ty, tz}, segment) do
    margin = Body.path_margin()
    reach = Perception.reach()

    abs(tx - ox) <= reach and abs(tz - oz) <= reach and abs(ty - oy) <= reach and
      Enum.all?(segment, fn {x, y, z} ->
        x in (min(ox, tx) - margin)..(max(ox, tx) + margin) and
          y in (min(oy, ty) - margin)..(max(oy, ty) + margin) and
          z in (min(oz, tz) - margin)..(max(oz, tz) + margin)
      end)
  end

  # move_to 的目标是格心、y 是脚所在的站立格（同 survey 的 move_to_y）。
  defp move_to({x, y, z}), do: %{atom: "move_to", args: %{x: x + 0.5, z: z + 0.5, y: y}}

  defp call(atom, {x, y, z}, extra),
    do: %{atom: atom, args: Map.merge(%{x: x, y: y, z: z}, extra)}
end
