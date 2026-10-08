defmodule GateServer.Npc.Skills.Expand do
  @moduledoc """
  全局系统功能：持续扩张（放置阶段决策稿 docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §7）。在作者划定的
  水平区域 `region` 里找一块放得下定义的空地，缺料就近采天然格，经 Body 的 `prefab_place`（与玩家同一入口）放下；done 返回
  新工地 `%{anchor_micro, orientation, stand, site_cell}`（另带事务号 `seq` 与按原因计数的跳过候选 `skipped`），Settler 把它
  追加进工地列表。技能壳只经 Body 原子动作 `read_catalog` / `move_to` / `look` / `query_balances` / `prefab_place`；采石调
  `Skills.Gather.run/3`（同一套 `move_to` / `look` / `probe_toward` / `use_tool`，步号在本调用号下另起命名空间 `{:gather, n}`，
  见 `GateServer.Npc.Skill.call/2`），不复制采石逻辑、不直接写 World。选址 `site/5`、候选地块 `plots/3`、分段（`Travel.waypoints/3`）、
  分块 `chunks/2`、采石候选 `quarry/3` 都是纯函数。

  流程：

  1. `read_catalog prefab` 取材料单与包围盒 `bounds_micro`（`spec/3`）。只用朝向 0：包围盒即足迹，不枚举朝向（朝向只改变
     足迹形状，选址规则不变；需要时再加）。锚点总落在宏格角上（micro 坐标是 8 的倍数），宏格定义与 micro 定义都满足 World 的
     对齐门（w/prefabs.ex `prefab_alignment/2`）；
  2. 候选地块（`plots/3`）：区域内从 (x0, z0) 起、间距 = 足迹宽 + spacing 的网格，按地块中心离自己的水平距离由近到远（同距按
     坐标）。网格让相邻地块之间恰好留出 spacing，自己建过的地块下次仍在网格上（重启后被拆的扩张建筑会在原地重建）；代价是
     网格位上有障碍的地块整个跳过，不左右挪动找位置；
  3. 逐个候选：看窗口（足迹水平外扩 max(spacing, 2) 格，竖直为自己脚下地面上下 4 格到其上建筑高度与站位净空）不在 look
     范围内就先分段走到地块最近的站位（`Travel.walk/2`，每段 ≤ reach − 2 米，每段 `move_to` 仍由 Body 寻路），再分块 look
     （`chunks/2`，每块 ≤ `Perception.look_cells/0` 格）后由 `site/5` 判定；
  4. 走到站位 → `query_balances` 按材料单算缺额 → 对缺的材料在站位周围 look（区域内、各轴离自己 ≤ 14 格），按 `quarry/3`
     取地表天然格（层自上而下，先挖地表以上的料堆），逐格交给 gather，每次之后重取余额，直到不缺；候选用尽 →
     `:insufficient_material`（不硬建）；余额表里没有的材料（不是本世界的生产材料，挖了也不入账）同样以它结束；
  5. 挖过料就先回站位，然后 `prefab_place`。

  候选被跳过（按原因计入 `skipped`，换下一个）：判定不过（`crowded` / `no_ground` / `uneven` / `blocked` / `no_stand`）、走不到
  （`no_path` / `stuck` / `too_far`，含走近后窗口仍超出 look 范围）、放置被拒（`occupied` / `out_of_reach` / `out_of_bounds` /
  `protected_region`）。候选用尽 → `:no_site`。其余拒绝（会话丢失、死亡、材料不足、超时…）换地块也不会变，原样作为终态。
  每次结束记一行 `npc_expand entity= result= site= skipped= gathers=`。

  护栏：`region` 是唯一的作者护栏——只在区域内采石（gather 的盒子是区域内的单格）与建造（足迹整个在区域内）；行走与只读的
  look 可以出区域。不拆任何已有放置：足迹只放进空气，足迹外扩 spacing 内有放置记录或细化格的地块整个跳过；采石格离足迹
  ≥ spacing + 2 格（保住间隔带与站位），且只取 `placed_by == nil` 的天然格（gather 再按探测命中的 owner 挡住作者 prefab 宏格）。
  作者 prefab 宏格只记 macro_owners，look 看不到（能力库设计稿 F20），在间隔带里不算拥挤；在足迹里则不是空气，照样跳过。

  作者保证：区域大致平坦（地块地面与看它时自己脚下地面相差不超过 4 格，否则看不到地面而跳过）；区域大小与地块数相称
  （候选都不成立时会逐个看过去、远处的还要走过去，耗时与地块数成正比）；定义已发布（作者目录或运行时发布）。
  """
  @behaviour GateServer.Npc.Skill
  require Logger
  alias GateServer.Npc.{Abilities, Blueprint, Perception, Skill}
  alias GateServer.Npc.Skills.{Gather, Travel}
  alias MmoContracts.VoxelMaterialCatalog
  alias VoxelRegion.{Phase, Spatial}

  @metrics %{request_count: 0, jev_request_count: 0}
  @unreachable Skill.unreachable()
  # prefab_place 被这些原因拒绝 = 这块地此刻放不下（被人抢先占了、够不着、出了部署编辑盒、在保护区），换下一个候选；
  # 其余拒绝（材料不足、会话丢失、死亡…）换地块也不会变，原样作为终态。
  @refused [:occupied, :out_of_reach, :out_of_bounds, :protected_region]
  # 地面在看它时自己脚下地面上下这么多格内找。
  @band 4
  # 采石：地面层（至多 1 层深）到其上这么多层（地表以上的料堆）。
  @heap 2
  # 采石范围（各轴离自己的格数）：范围内任两格各轴相距 ≤ 28，加 gather 站位离格 1.5 米仍 < 32 米，所以 gather 的每个站位与
  # 采完回地块站位都是单程 move_to（`Perception.reach/0` 是 move_to 的单程上限）。
  @quarry div(Perception.reach(), 2) - 2

  @impl true
  def definition(profile) do
    %{
      description:
        "持续扩张：在作者划定的水平区域 region（整数格闭区间 [[x0,z0],[x1,z1]]，1 格 = 1 米）里找一块空地，把已发布的 definition " <>
          "按朝向 0 放下。地块从 (x0, z0) 起按「足迹宽 + spacing」的间距排成网格，从离自己最近的开始看；足迹各列地面同高、" <>
          "上方到建筑高度全是空气（花草也不行）、足迹外扩 spacing 格内没有任何人放下的格或细化格，才算空地。" <>
          "缺料时在附近区域内挖地表的天然格（tool_id 用挖掘工具），挖不够以 insufficient_material 结束、不硬建；" <>
          "找不到空地以 no_site 结束。只在 region 内挖与建，不拆任何已有的放置；远处的地块会分段走过去。" <>
          "done 给出新工地的锚点 anchor_micro（micro 坐标，1 米 = #{Spatial.micro_resolution()} micro）、orientation、" <>
          "站位 stand [x, z] 与锚点格 site_cell。",
      parameters: %{
        type: "object",
        properties: %{
          definition: %{type: "string"},
          region: %{
            type: "array",
            items: %{type: "array", items: %{type: "integer"}, minItems: 2, maxItems: 2},
            minItems: 2,
            maxItems: 2
          },
          tool_id: Abilities.belt_schema(profile),
          spacing: %{type: "integer", minimum: 0}
        },
        required: ["definition", "region", "tool_id", "spacing"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def run(
        context,
        %{
          "definition" => text,
          "region" => [[x0, z0], [x1, z1]],
          "tool_id" => tool,
          "spacing" => spacing
        },
        _config
      )
      when is_binary(text) and is_integer(x0) and is_integer(z0) and is_integer(x1) and
             is_integer(z1) and is_integer(tool) and is_integer(spacing) and spacing >= 0 do
    case Base.decode16(text, case: :mixed) do
      {:ok, <<_::binary-size(32)>> = id} ->
        half = context.movement_profile.half_height

        state = %{
          body: context.body,
          call: context.call_id,
          step: 0,
          context: context,
          definition: id,
          tool: tool,
          spacing: spacing,
          region: {{min(x0, x1), min(z0, z1)}, {max(x0, x1), max(z0, z1)}},
          half_height: half,
          # 站位要能站人：身高占的格数（与 Body 寻路的净空同一算法）。
          clearance: ceil(2 * half),
          position: context.observation.self.position,
          skipped: %{},
          gathers: 0
        }

        finish(context, expand(state))

      _ ->
        {:error, :invalid_skill_arguments, @metrics}
    end
  end

  def run(_, _, _), do: {:error, :invalid_skill_arguments, @metrics}

  @doc """
  包围盒 → 选址规格（纯函数）。`bounds` 是 `read_catalog prefab` 的 `bounds_micro`：朝向 0 时相对锚点的 micro 半开区间
  `[[x0, y0, z0], [x1, y1, z1]]`。锚点在宏格角上时足迹覆盖的宏格 = 锚点格 + `offset` 起、`size` 个；返回
  `%{offset: {dx, dy, dz}, size: {宽 x, 高, 宽 z}, spacing:, clearance:}`（clearance = 站位所需净空格数）。
  """
  def spec([lo, hi], spacing, clearance) do
    n = Spatial.micro_resolution()
    [x0, y0, z0] = Enum.map(lo, &Integer.floor_div(&1, n))
    [x1, y1, z1] = Enum.map(hi, &Integer.floor_div(&1 - 1, n))

    %{
      offset: {x0, y0, z0},
      size: {x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1},
      spacing: spacing,
      clearance: clearance
    }
  end

  @doc """
  候选地块（纯函数）：区域 `{{x0, z0}, {x1, z1}}`（闭区间）内足迹最小角 `{fx, fz}` 的网格——从 (x0, z0) 起，x 方向间距
  宽 x + spacing、z 方向间距宽 z + spacing，足迹整个在区域内；按地块中心 `(fx + 宽 x / 2, fz + 宽 z / 2)` 离 `from = {x, z}`
  的水平距离由近到远，同距按 `{fx, fz}`。
  """
  def plots({{x0, z0}, {x1, z1}}, %{size: {wx, _, wz}, spacing: s}, {px, pz}) do
    for(
      fx <- x0..(x1 - wx + 1)//(wx + s),
      fz <- z0..(z1 - wz + 1)//(wz + s),
      do: {fx, fz}
    )
    |> Enum.sort_by(fn {fx, fz} ->
      {(fx + wx / 2 - px) ** 2 + (fz + wz / 2 - pz) ** 2, fx, fz}
    end)
  end

  @doc """
  选址判定（纯函数）。`rows` 是 look 的逐格行（`%{{x, y, z} => %{material:, refined:, placed_by:}}`），须覆盖地块的看窗口
  （足迹水平外扩 max(spacing, 2)，竖直 `g0` 到 `g1 + max(高, clearance)`）；`plot` 是足迹最小角 `{fx, fz}`；`{g0, g1}` 是找地面的
  高度带；`from = {x, z}` 只用来给站位排序。依次判定（第一条不过即返回该原因）：

  1. `crowded`：足迹外扩 spacing 的水平范围内（窗口里的任意高度）有放置记录（`placed_by` 非 nil）或细化格——不挨着任何人
     （包括自己）已有的建筑，也不建在别人铺的地上；
  2. `no_ground`：首列在高度带里自上而下找不到「实心、上面一格不实心」的地面 g（实心 = 挡路、非液体、非细化；花草不挡路，
     地面上长着草时地面仍是草下那格）；
  3. `uneven`：足迹各列在 g 不都是实心；
  4. `blocked`：足迹各列 g + 1 .. g + 高 不全是空气——prefab 只放进空气（w/prefabs.ex `place_aligned_tree`：宏格与 micro 都要求
     格值 `{0, _}`，花草也算被占；细化格另由第 1 条挡住）；
  5. `no_stand`：四个站位（`Blueprint.stands/2`：足迹四条边中点外 1.5 米，离 `from` 由近到远）里没有一个在 g 有实心地面、
     其上 clearance 格可穿过（与 Body 寻路同一判据）。

  成立 → `{:ok, %{anchor_micro: [x, y, z], orientation: 0, stand: [x, z], site_cell: [x, y, z], ground: g}}`：锚点格 = 足迹最小角
  − `offset`、底层落在 g + 1；`anchor_micro` = 锚点格 × #{Spatial.micro_resolution()}。否则 `{:error, 原因}`。够不够得着由权威的放置射程裁决。
  """
  def site(rows, {fx0, fz0} = plot, spec, {g0, g1}, from) do
    %{offset: {dx, dy, dz}, size: {wx, h, wz}, spacing: s, clearance: c} = spec
    {fx1, fz1} = {fx0 + wx - 1, fz0 + wz - 1}
    columns = for x <- fx0..fx1, z <- fz0..fz1, do: {x, z}
    at = &Map.fetch!(rows, &1)

    crowded =
      Enum.any?(rows, fn {{x, _, z}, row} ->
        x in (fx0 - s)..(fx1 + s) and z in (fz0 - s)..(fz1 + s) and
          (row.placed_by != nil or row.refined)
      end)

    with :ok <- check(not crowded, :crowded),
         {:ok, g} <- surface(at, {fx0, fz0}, g0..g1//1),
         :ok <- check(Enum.all?(columns, fn {x, z} -> solid?(at.({x, g, z})) end), :uneven),
         :ok <-
           check(
             Enum.all?(columns, fn {x, z} ->
               Enum.all?((g + 1)..(g + h), &air?(at.({x, &1, z})))
             end),
             :blocked
           ),
         {:ok, stand} <- stand(at, stands(plot, spec, from), g, c) do
      cell = [fx0 - dx, g + 1 - dy, fz0 - dz]

      {:ok,
       %{
         anchor_micro: Enum.map(cell, &(&1 * Spatial.micro_resolution())),
         orientation: 0,
         stand: stand,
         site_cell: cell,
         ground: g
       }}
    end
  end

  @doc """
  采石候选（纯函数）：`rows` 同 `site/5`，须覆盖 `area` 的地面层 g 到 g + #{@heap + 1}。取 `Gather.candidates/3` 的候选（材质为
  `material`、非液体、非细化、没有放置记录，在 `area` 的 g .. g + #{@heap} 内：地面层是「至多 1 层深」，其上是地表以上的料堆；层自上
  而下、同层离 `from` 由近到远），再只留露天的（上面一格是空气，射线打得到）且不在 `keep`（`{{x0, z0}, {x1, z1}}`，足迹外扩
  spacing + 1，即离足迹不足 spacing + 2 格）里的。返回 `[{x, y, z}]`。
  """
  def quarry(rows, %{material: material, ground: g, area: {{x0, z0}, {x1, z1}}, keep: keep}, from) do
    {{kx0, kz0}, {kx1, kz1}} = keep

    rows
    |> Map.values()
    |> Gather.candidates(%{box: {{x0, g, z0}, {x1, g + @heap, z1}}, material: material}, from)
    |> Enum.filter(fn {x, y, z} ->
      air?(Map.fetch!(rows, {x, y + 1, z})) and not (x in kx0..kx1 and z in kz0..kz1)
    end)
  end

  @doc """
  分块（纯函数）：把整数格闭区间盒切成每块不超过 `limit` 格的盒，按 x、再按 z 排列。一片 x（高 × 宽 z）放得下时每块取整数片
  x；放不下时每片再按 z 切条。高度不会超过 `limit`（看窗口的高由 look 的竖直范围限住）。
  """
  def chunks({{x0, y0, z0}, {x1, y1, z1}}, limit) do
    ny = y1 - y0 + 1
    nz = z1 - z0 + 1

    if ny * nz <= limit do
      step = div(limit, ny * nz)
      for x <- x0..x1//step, do: {{x, y0, z0}, {min(x + step - 1, x1), y1, z1}}
    else
      step = div(limit, ny)
      for x <- x0..x1//1, z <- z0..z1//step, do: {{x, y0, z}, {x, y1, min(z + step - 1, z1)}}
    end
  end

  # —— 技能壳 ——

  defp expand(state) do
    command = %{verb: :read_catalog, what: :prefab, definition: state.definition}

    with {:ok, %{materials: materials, bounds_micro: bounds}, state} <- Skill.call(state, command) do
      spec = spec(bounds, state.spacing, state.clearance)
      plots = plots(state.region, spec, horizontal(state.position))
      try_plots(plots, materials, spec, state)
    end
  end

  defp try_plots([], _materials, _spec, state), do: {:error, :no_site, state}

  defp try_plots([plot | rest], materials, spec, state) do
    case attempt(plot, materials, spec, state) do
      {:skip, reason, state} ->
        try_plots(rest, materials, spec, %{
          state
          | skipped: Map.update(state.skipped, reason, 1, &(&1 + 1))
        })

      result ->
        result
    end
  end

  # 一个候选：走近 → 看 → 判定 → 到站位 → 补料 →（挖过料先回站位）→ 放置。返回 {:ok, data, state} / {:skip, 原因, state} /
  # {:error, 原因, state}。
  defp attempt(plot, materials, spec, state) do
    with {:ok, state} <- approach(plot, spec, state),
         band = band(state),
         {:ok, rows, state} <- survey(window(plot, spec, band), state),
         {:site, {:ok, found}, _} <-
           {:site, site(rows, plot, spec, band, horizontal(state.position)), state},
         stand = List.to_tuple(found.stand),
         {:ok, state} <- walk(state, stand),
         gathers = state.gathers,
         {:ok, state} <- supply(materials, plot, found, spec, state),
         {:ok, state} <- if(state.gathers > gathers, do: walk(state, stand), else: {:ok, state}),
         {:ok, %{seq: seq}, state} <- place(found, state) do
      data = Map.take(found, [:anchor_micro, :orientation, :stand, :site_cell])
      {:ok, Map.merge(data, %{seq: seq, skipped: state.skipped, metrics: @metrics}), state}
    else
      {:site, {:error, reason}, state} -> {:skip, reason, state}
      other -> other
    end
  end

  # 看窗口不在 look 范围内：先分段走到地块最近的站位；走近后仍不在（间隔太大，窗口比 look 范围宽）→ too_far。
  defp approach(plot, spec, state) do
    if in_sight?(window(plot, spec, band(state)), state.position) do
      {:ok, state}
    else
      [stand | _] = stands(plot, spec, horizontal(state.position))

      with {:ok, state} <- walk(state, stand) do
        if in_sight?(window(plot, spec, band(state)), state.position),
          do: {:ok, state},
          else: {:skip, :too_far, state}
      end
    end
  end

  # 地面高度带：脚所在的格 = 胶囊中心下移半高（+0.5 容忍贴地的 skin / snap，同 Body），地面 = 脚下一格，上下 @band 格。
  defp band(%{position: {_, y, _}, half_height: half}) do
    ground = floor(y - half + 0.5) - 1
    {ground - @band, ground + @band}
  end

  # 看窗口：足迹外扩 max(spacing, 2)（间隔带与四个站位列），竖直到地面带顶上再加建筑高度与站位净空中较大的。
  defp window({fx0, fz0}, %{size: {wx, h, wz}, spacing: s, clearance: c}, {g0, g1}) do
    e = max(s, 2)
    {{fx0 - e, g0, fz0 - e}, {fx0 + wx - 1 + e, g1 + max(h, c), fz0 + wz - 1 + e}}
  end

  defp in_sight?(box, position) do
    Enum.all?(chunks(box, Perception.look_cells()), fn {lo, hi} ->
      Perception.prepare(position, %{verb: :look, min: lo, max: hi}) != nil
    end)
  end

  # 分块 look，合并成按格索引的行。
  defp survey(box, state) do
    box
    |> chunks(Perception.look_cells())
    |> Enum.reduce_while({:ok, %{}, state}, &look/2)
  end

  defp look({lo, hi}, {:ok, rows, state}) do
    case Skill.call(state, %{verb: :look, min: lo, max: hi}) do
      {:ok, %{probe_occupancy: occupancy}, state} ->
        {:cont, {:ok, Enum.into(occupancy, rows, &{List.to_tuple(&1.cell), &1}), state}}

      error ->
        {:halt, error}
    end
  end

  # 分段走到 target（水平 {x, z}，与 travel 技能同一个 Travel.walk/2）；去不了 → 跳过这个候选。
  defp walk(state, target) do
    case Travel.walk(state, target) do
      {:error, reason, state} when reason in @unreachable -> {:skip, reason, state}
      other -> other
    end
  end

  # 补料：按材料号取第一种缺料，采够后重取余额再看下一种；都不缺 → :ok。
  defp supply(materials, plot, site, spec, state) do
    with {:ok, %{balances: rows}, state} <- Skill.call(state, %{verb: :query_balances}) do
      have = Map.new(rows, &{&1.material, &1.balance})

      case Enum.find(Enum.sort(materials), fn {m, need} -> need > Map.get(have, m, 0) end) do
        nil ->
          {:ok, state}

        # 不是本世界的生产材料（余额表里没有它）：挖了也不入账。
        {material, _} when not is_map_key(have, material) ->
          {:error, :insufficient_material, state}

        {material, need} ->
          with {:ok, cells, state} <- quarry_cells(material, plot, site, spec, state),
               {:ok, state} <- dig(cells, material, need, need - have[material], state),
               do: supply(materials, plot, site, spec, state)
      end
    end
  end

  # 站位周围（区域内、各轴离自己 ≤ @quarry）地面层到其上 @heap 层的天然格，看到 @heap + 1 层（判露天）。
  defp quarry_cells(material, {fx0, fz0}, site, spec, state) do
    %{size: {wx, _, wz}, spacing: s} = spec
    {{rx0, rz0}, {rx1, rz1}} = state.region
    {px, pz} = from = horizontal(state.position)
    {sx, sz} = {floor(px), floor(pz)}

    area =
      {{max(rx0, sx - @quarry), max(rz0, sz - @quarry)},
       {min(rx1, sx + @quarry), min(rz1, sz + @quarry)}}

    {{x0, z0}, {x1, z1}} = area
    g = site.ground

    with {:ok, rows, state} <- survey({{x0, g, z0}, {x1, g + @heap + 1, z1}}, state) do
      keep = {{fx0 - s - 1, fz0 - s - 1}, {fx0 + wx + s, fz0 + wz + s}}
      {:ok, quarry(rows, %{material: material, ground: g, area: area, keep: keep}, from), state}
    end
  end

  # 逐格交给 gather（单格盒、缺额 units）：done / exhausted / unreachable 都重取余额（挖到一半也已入账），不缺了就结束，
  # 还缺就下一格；候选用尽 → insufficient_material。gather 的其余拒绝原样作为终态。
  defp dig([], _material, _need, _units, state), do: {:error, :insufficient_material, state}

  defp dig([cell | rest], material, need, units, state) do
    n = state.gathers + 1

    context =
      state.context
      |> put_in([:observation, :self, :position], state.position)
      |> Map.put(:step_space, {:gather, n})

    box = [Tuple.to_list(cell), Tuple.to_list(cell)]
    args = %{"box" => box, "material" => material, "units" => units, "tool_id" => state.tool}
    state = %{state | gathers: n}

    case Gather.run(context, args, %{}) do
      {:error, reason, _} when reason not in [:exhausted, :unreachable] ->
        {:error, reason, state}

      _ ->
        with {:ok, %{balances: rows}, state} <- Skill.call(state, %{verb: :query_balances}) do
          short = need - Enum.find(rows, &(&1.material == material)).balance
          if short > 0, do: dig(rest, material, need, short, state), else: {:ok, state}
        end
    end
  end

  defp place(site, state) do
    [x, y, z] = site.anchor_micro

    command = %{
      verb: :prefab_place,
      definition_id: state.definition,
      anchor: {x, y, z},
      orientation: site.orientation
    }

    case Skill.call(state, command) do
      {:error, reason, state} when reason in @refused -> {:skip, reason, state}
      result -> result
    end
  end

  defp finish(context, result) do
    {outcome, text, site, state} =
      case result do
        {:ok, data, state} -> {{:ok, data}, "done", data.site_cell, state}
        {:error, reason, state} -> {{:error, reason, @metrics}, inspect(reason), nil, state}
      end

    Logger.info(
      "npc_expand entity=#{context.observation.self.entity_id} result=#{text} site=#{inspect(site)} " <>
        "skipped=#{inspect(state.skipped)} gathers=#{state.gathers}"
    )

    outcome
  end

  defp surface(at, {x, z}, band) do
    case Enum.find(
           Enum.reverse(band),
           &(solid?(at.({x, &1, z})) and not solid?(at.({x, &1 + 1, z})))
         ) do
      nil -> {:error, :no_ground}
      g -> {:ok, g}
    end
  end

  defp stand(at, stands, g, clearance) do
    case Enum.find(stands, fn {sx, sz} ->
           {x, z} = {floor(sx), floor(sz)}

           solid?(at.({x, g, z})) and
             Enum.all?((g + 1)..(g + clearance), &passable?(at.({x, &1, z})))
         end) do
      nil -> {:error, :no_stand}
      {sx, sz} -> {:ok, [sx, sz]}
    end
  end

  # 四个站位：足迹四条边中点外 1.5 米（与 gather、蓝图施工同一函数），离 from 由近到远。
  defp stands({fx0, fz0}, %{size: {wx, _, wz}}, {px, pz}),
    do:
      Blueprint.stands(
        %{{fx0, 0, fz0} => 0, {fx0 + wx - 1, 0, fz0 + wz - 1} => 0},
        {floor(px), 0, floor(pz)}
      )

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp horizontal({x, _, z}), do: {x, z}

  # 实心地面：挡路（与碰撞同一判据）、非液体、非细化。
  defp solid?(row),
    do:
      not row.refined and VoxelMaterialCatalog.blocks_movement?(row.material) and
        not Phase.liquid?(row.material)

  # 空气：prefab 只放进这种格（花草、液体、细化格都不是）。
  defp air?(row), do: row.material == 0 and not row.refined

  # 站位可穿过：与 Body 寻路同一判据（非细化、不挡路；液体不进寻路网格）。
  defp passable?(row),
    do:
      not row.refined and not VoxelMaterialCatalog.blocks_movement?(row.material) and
        not Phase.liquid?(row.material)
end
