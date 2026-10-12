defmodule NpcServer.Skills.Expand do
  @moduledoc """
  全局系统功能：持续扩张（放置阶段决策稿 docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §7）。在作者划定的
  水平区域 `region` 里找一块放得下定义的地块，地表略有起伏就先平整，缺料就近采天然格，经 Body 的 `prefab_place`（与玩家同一
  入口）放下；done 返回新工地 `%{anchor_micro, orientation, stand, site_cell}`（另带事务号 `seq` 与按原因计数的跳过候选
  `skipped`），Settler 把它追加进工地列表。技能壳只经 Body 原子动作 `read_catalog` / `survey` / `look` / `move_to`（经
  `Travel.walk/2`）/ `probe_toward` / `use_tool` / `query_balances` / `place` / `prefab_place`：挖一格调 `Skills.Gather.mine/3`，
  采石调 `Skills.Gather.run/3`（步号在本调用号下另起命名空间 `{:gather, n}`，见 `NpcServer.Skill.call/2`），不复制采石
  逻辑、不直接写 World。规格 `spec/3`、候选地块 `plots/3`、选址 `site/4`、平整 `level/2`、终态 `ending/1`、分块 `chunks/2`、
  采石候选 `quarry/3` 都是纯函数。

  流程：

  1. `read_catalog prefab` 取材料单与包围盒 `bounds_micro`（`spec/3`）。只用朝向 0：包围盒即足迹，不枚举朝向（朝向只改变
     足迹形状，选址规则不变；需要时再加）。锚点总落在宏格角上（micro 坐标是 8 的倍数），宏格定义与 micro 定义都满足 World 的
     对齐门（w/prefabs.ex `prefab_alignment/2`）；
  2. 候选地块（`plots/3`）：区域内从 (x0, z0) 起、间距 = 足迹宽 + spacing 的网格，按地块中心离自己的水平距离由近到远（同距按
     坐标）。网格让相邻地块之间恰好留出 spacing，自己建过的地块下次仍在网格上（重启后被拆的扩张建筑会在原地重建）；代价是
     网格位上有障碍的地块整个跳过，不左右挪动找位置；
  3. 逐个候选：勘察窗口（足迹水平外扩 max(spacing, 2) 列，含四个站位列）不在 survey 范围内就先分段走到地块最近的站位
     （`Travel.walk/2`），再 `survey` 窗口，由 `site/4` 按每列自己的地表判定——地面高度取自候选自己，不限于自己脚下；
  4. 成立 → 分块 look 平整体积（足迹各列从最低地表到目标地面 + 建筑高度，`chunks/2`），`level/2` 算出要挖的格与要填的格；
  5. 走到站位 → 挖（`Gather.order/2`：自上而下、由近到远，每格 `Gather.mine/3`，挖到的材料照常入账）→ `query_balances`，按材料单
     加填坑石料算缺额，缺就在站位周围（区域内、各轴离自己 ≤ 14 格）按 `quarry/3` 取露天天然格逐格交给 gather，每次之后
     重取余额，直到不缺 → 采过料先回站位 → 自下而上 `place` 填石（与玩家同一入口、花自己的余额）→ `prefab_place`。

  平整（`site/4`、`level/2`）：足迹各列地表高差不超过 2 格才平整。目标地面 g = 足迹各列地表高度的下中位数（升序第 ⌈n/2⌉ 个）：
  各列要挖或要填的格数是 |地表 − g|，中位数使它们的和（土方量）最小；n 为偶数时两个中间值之间的任何高度同样最小，取低的那个——
  同样土方量下少填多挖，挖出的天然格入账、填坑要花石料（依据：L1 损失的最优解是中位数，Hastie 等《The Elements of Statistical
  Learning》第 2 版 §2.4；土地平整工程用最小二乘平面再升降到挖填比 1.1–1.5，FAO 灌溉手册第 6 章 Land levelling——本项目目标面
  水平、按整格计、填方花材料，所以取土方量最小的中位数并偏挖）。g 以上到建筑高度的非空气格（含花草）挖掉，g 及以下的空位（空气或花草，
  放置会直接覆盖花草）填石；要动的格必须是天然格（没有放置记录、非细化、非液体），否则这块地不成立（`blocked`）。只动足迹内的格，
  站位不动（站位只要求离 g 不超过同样的高差、站得下）。

  候选被跳过（按原因计入 `skipped`，换下一个）分两类：

  - 地块不成立：`crowded` / `no_ground` / `uneven` / `no_stand` / `blocked`（判定，`blocked` 也含挖时命中作者 prefab 宏格），
    `occupied` / `out_of_bounds` / `protected_region`（放置或填坑被拒）；
  - 本可成立但此刻做不到：`no_path` / `stuck` / `too_far`（走不到，含走近后窗口仍超出 survey 范围）、`out_of_reach`（够不着要挖、
    要填或放置的格）、`insufficient_material`（站位附近采不到够用的料）。

  候选用尽 → 终态 `ending/1`：有第二类 → `:no_reachable_site`（换个位置或稍后再试），否则 `:region_full`（区域放满，可以停）。
  其余拒绝（会话丢失、死亡、材料单或填坑石料不是本世界的生产材料、gather 的其他拒绝…）换地块也不会变，原样作为终态。
  平整与放置之间不是事务：挖 / 填之后才被拒（放置被抢先、缺料）时已改的天然格不回滚，已入账 / 已花的材料照实。
  每次结束记一行 `npc_expand entity= result= site= skipped= gathers=`。

  护栏：`region` 是唯一的作者护栏——只在区域内动土（平整只动足迹内的格；gather 的盒子是区域内的单格）与建造（足迹整个在区域内）；
  行走与只读的 survey / look 可以出区域。不拆、不改任何已有放置：足迹只放进空气；足迹外扩 spacing 内的地表有放置记录或有细化格的
  地块整个跳过；平整只挖 / 填天然格，挖之前再按探测命中的 owner 挡住作者 prefab 宏格；采石格离足迹 ≥ spacing + 2 格（保住间隔带与
  站位），且只取 `placed_by == nil` 的天然格。作者 prefab 宏格只记 macro_owners，survey / look 看不到（能力库设计稿 F20），在间隔带里
  不算拥挤；在足迹里由挖时的探测挡住。

  作者保证：区域大小与地块数相称（候选都不成立时会逐个勘察、远处的还要走过去，耗时与地块数成正比）；定义已发布（作者目录或运行时发布）。
  """
  @behaviour NpcServer.Skill
  require Logger
  alias NpcServer.{Abilities, Blueprint, Context, Perception, Skill}
  alias NpcServer.Skills.{Gather, Travel}
  alias MmoContracts.VoxelMaterialCatalog
  alias SceneServer.Movement.Player
  alias VoxelRegion.{Phase, Spatial, World}

  @metrics %{request_count: 0, jev_request_count: 0}
  # prefab_place / place 被这些原因拒绝 = 这块地此刻放不下（被人抢先占了、够不着、出了部署编辑盒、在保护区），换下一个候选。
  @refused [:occupied, :out_of_reach, :out_of_bounds, :protected_region]
  # 这些跳过原因 = 地块本可成立，只是此刻走不到、够不着或附近采不到料（终态 no_reachable_site）；其余跳过原因是地块不成立。
  @unreachable Skill.unreachable() ++ [:out_of_reach, :insufficient_material]
  # 足迹内地表高差不超过这么多格才平整（站位离目标地面也不超过它）。
  @relief 2
  # 采石：地面层（至多 1 层深）到其上这么多层（地表以上的料堆）。
  @heap 2
  # 采石范围（各轴离自己的格数）：范围内任两格各轴相距 ≤ 28，加 gather 站位离格 1.5 米仍 < 32 米，所以 gather 的每个站位与
  # 采完回地块站位都是单程 move_to（`Perception.reach/0` 是 move_to 的单程上限）。
  @quarry div(Perception.reach(), 2) - 2
  # 填坑用的石料：材质契约（MmoContracts.VoxelMaterialCatalog，即 Voxim EVoxelMaterial）里名为 stone 的 id。
  @fill Enum.find_value(VoxelMaterialCatalog.table(), &(&1["name"] == "stone" && &1["id"]))

  @impl true
  def definition(profile) do
    %{
      description:
        "持续扩张：在作者划定的水平区域 region（整数格闭区间 [[x0,z0],[x1,z1]]，1 格 = 1 米）里找一块地，把已发布的 definition " <>
          "按朝向 0 放下。地块从 (x0, z0) 起按「足迹宽 + spacing」的间距排成网格，从离自己最近的开始，先勘察每块地自己的地表；" <>
          "足迹外扩 spacing 格内没有任何人放下的格或细化格、足迹各列地表高差不超过 #{@relief} 格才行：先把足迹平整到各列地表的中位数高度" <>
          "（高出的天然格挖掉、材料入账，低处的空位花自己的石料填平，建筑高度内的花草也挖掉），再放下。" <>
          "缺料时在附近区域内挖地表的天然格（tool_id 用挖掘工具）。只在 region 内挖、填与建，不拆不改任何已有的放置；远处的地块会分段走过去。" <>
          "一块地走不到、够不着或附近采不到料就换下一块。结束原因：region_full = 区域里已经没有能建的地块" <>
          "（都被占、太挤或地形不行），可以停止扩张；no_reachable_site = 还有本可成立的地块，只是此刻走不到、够不着或附近采不到料" <>
          "（不是放满了），换个位置或过一会儿再试。done 给出新工地的锚点 anchor_micro（micro 坐标，1 米 = " <>
          "#{Spatial.micro_resolution()} micro）、orientation、站位 stand [x, z]、锚点格 site_cell 与按原因计数的跳过地块 skipped。",
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
        state = %{
          body: context.body,
          call: context.call_id,
          step: 0,
          context: context,
          world: context.world,
          definition: id,
          tool: tool,
          spacing: spacing,
          region: {{min(x0, x1), min(z0, z1)}, {max(x0, x1), max(z0, z1)}},
          half_height: context.movement_profile.half_height,
          # 站位要能站人：身高占的格数（与 Body 寻路、survey 同一算法）。
          clearance: Context.clearance(context.movement_profile),
          position: context.observation.self.position,
          skipped: %{},
          gathers: 0,
          # 平整时挖格（Gather.mine/3）的工具间隔与上一击时刻；间隔在第一次要挖时才读。
          interval_ms: nil,
          last_hit: nil
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
  选址判定（纯函数）。`columns` 是 survey 的列结果按 `{x, z}` 索引（`Perception.surfaces/2` 的行），须覆盖地块的勘察窗口
  （足迹水平外扩 max(spacing, 2)）；`plot` 是足迹最小角 `{fx, fz}`；`from = {x, z}` 只用来给站位排序。依次判定（第一条不过即
  返回该原因）：

  1. `crowded`：足迹外扩 spacing 的列里，有地表格带放置记录（`placed_by` 非 nil）或这一列有细化格——不挨着任何人（包括自己）
     已有的建筑，也不建在别人铺的地上；
  2. `no_ground`：足迹有一列在 survey 范围里没有站得下的地面；
  3. `uneven`：足迹各列地表高差超过 #{@relief} 格；
  4. `no_stand`：四个站位（`Blueprint.stands/2`：足迹四条边中点外 1.5 米，离 `from` 由近到远）的列里都没有离目标地面不超过
     #{@relief} 格、站得下的地面。

  目标地面 g = 足迹各列地表的下中位数（规则与依据见 moduledoc）。成立 → `{:ok, %{anchor_micro: [x, y, z], orientation: 0,
  stand: [x, z], site_cell: [x, y, z], ground: g, low: 足迹最低地表}}`：锚点格 = 足迹最小角 − `offset`、底层落在 g + 1；
  `anchor_micro` = 锚点格 × #{Spatial.micro_resolution()}。否则 `{:error, 原因}`。地面以上是否只剩可挖的天然格、平整要动哪些格由
  `level/2` 按 look 判定；够不够得着由权威的射程裁决。
  """
  def site(columns, {fx0, fz0} = plot, spec, from) do
    %{offset: {dx, dy, dz}, size: {wx, _, wz}, spacing: s} = spec
    {fx1, fz1} = {fx0 + wx - 1, fz0 + wz - 1}
    heights = for x <- fx0..fx1, z <- fz0..fz1, do: Map.fetch!(columns, {x, z}).y

    crowded =
      Enum.any?(columns, fn {{x, z}, column} ->
        x in (fx0 - s)..(fx1 + s) and z in (fz0 - s)..(fz1 + s) and
          (column.placed_by != nil or column.refined)
      end)

    with :ok <- check(not crowded, :crowded),
         :ok <- check(nil not in heights, :no_ground),
         {low, high} = Enum.min_max(heights),
         :ok <- check(high - low <= @relief, :uneven),
         g = Enum.at(Enum.sort(heights), div(length(heights) - 1, 2)),
         {:ok, stand} <- stand(columns, stands(plot, spec, from), g) do
      cell = [fx0 - dx, g + 1 - dy, fz0 - dz]

      {:ok,
       %{
         anchor_micro: Enum.map(cell, &(&1 * Spatial.micro_resolution())),
         orientation: 0,
         stand: stand,
         site_cell: cell,
         ground: g,
         low: low
       }}
    end
  end

  @doc """
  平整计划（纯函数）。`rows` 是 look 的逐格行（按 `{x, y, z}` 索引），恰是平整体积（足迹各列从最低地表到 g + 建筑高度）；`g` 是
  目标地面。g 以上要成为空气：非空气的天然格（`placed_by == nil`、非细化、非液体；花草也算）挖掉。g 及以下要是实心地面
  （`Perception.walk_kind/1` 为 `:solid`）：空位——空气或天然花草（放置直接覆盖花草）——填石。要动的格不是天然格（有放置记录、
  细化格、液体）→ `{:error, :blocked}`。成立 → `{:ok, %{dig: [格], fill: [格]}}`：dig 按坐标排序（执行时再按站位排，见
  `Gather.order/2`），fill 自下而上、同层按 x、z。
  """
  def level(rows, g) do
    rows
    |> Enum.sort()
    |> Enum.reduce_while(%{dig: [], fill: []}, fn {{_, y, _} = cell, row}, plan ->
      case work(row, y > g) do
        :keep -> {:cont, plan}
        :blocked -> {:halt, :blocked}
        kind -> {:cont, Map.update!(plan, kind, &[cell | &1])}
      end
    end)
    |> case do
      :blocked ->
        {:error, :blocked}

      plan ->
        {:ok,
         %{
           dig: Enum.reverse(plan.dig),
           fill: Enum.sort_by(plan.fill, fn {x, y, z} -> {y, x, z} end)
         }}
    end
  end

  @doc """
  候选用尽时的终态（纯函数）：`skipped` 是按原因计数的跳过地块。有地块因为走不到、够不着或附近采不到料（`#{inspect(@unreachable)}`）
  被跳过 → `:no_reachable_site`（地块本可成立，换个位置或稍后再试）；否则 → `:region_full`（都被占、太挤或地形不成立，含区域里
  一块候选都没有）。
  """
  def ending(skipped),
    do:
      if(Enum.any?(Map.keys(skipped), &(&1 in @unreachable)),
        do: :no_reachable_site,
        else: :region_full
      )

  @doc """
  采石候选（纯函数）：`rows` 同 `level/2` 的形状，须覆盖 `area` 的地面层 g 到 g + #{@heap + 1}。取 `Gather.candidates/3` 的候选（材质为
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

  defp try_plots([], _materials, _spec, state), do: {:error, ending(state.skipped), state}

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

  # 一个候选：（走近）→ 勘察 → 判定 → 看平整体积 → 到站位 → 挖 → 补料 →（采过料先回站位）→ 填 → 放置。返回 {:ok, data, state} /
  # {:skip, 原因, state} / {:error, 原因, state}。
  defp attempt(plot, materials, spec, state) do
    window = window(plot, spec)

    with {:ok, state} <- approach(window, plot, spec, state),
         {lo, hi} = window,
         {:ok, %{columns: columns}, state} <-
           Skill.call(state, %{verb: :survey, min: lo, max: hi}),
         columns = Map.new(columns, &{List.to_tuple(&1.column), &1}),
         {:site, {:ok, found}, _} <-
           {:site, site(columns, plot, spec, horizontal(state.position)), state},
         volume = volume(plot, spec, found),
         {:ok, state} <- sight(volume, state),
         {:ok, rows, state} <- look_box(volume, state),
         {:site, {:ok, works}, _} <- {:site, level(rows, found.ground), state},
         stand = List.to_tuple(found.stand),
         {:ok, state} <- walk(state, stand),
         {:ok, state} <- dig(works.dig, state),
         gathers = state.gathers,
         {:ok, state} <- supply(materials, length(works.fill), plot, found, spec, state),
         {:ok, state} <- if(state.gathers > gathers, do: walk(state, stand), else: {:ok, state}),
         {:ok, state} <- fill(works.fill, state),
         {:ok, %{seq: seq}, state} <- place(found, state) do
      data = Map.take(found, [:anchor_micro, :orientation, :stand, :site_cell])
      {:ok, Map.merge(data, %{seq: seq, skipped: state.skipped, metrics: @metrics}), state}
    else
      {:site, {:error, reason}, state} -> {:skip, reason, state}
      other -> other
    end
  end

  # 勘察窗口不在 survey 范围内：先分段走到地块最近的站位；走近后仍不在（窗口比 survey 范围大）→ too_far。
  defp approach(window, plot, spec, state) do
    if surveyable?(window, state) do
      {:ok, state}
    else
      [stand | _] = stands(plot, spec, horizontal(state.position))

      with {:ok, state} <- walk(state, stand) do
        if surveyable?(window, state), do: {:ok, state}, else: {:skip, :too_far, state}
      end
    end
  end

  defp surveyable?({lo, hi}, state),
    do:
      Perception.prepare(state.position, %{verb: :survey, min: lo, max: hi}, state.clearance) !=
        nil

  # 勘察窗口：足迹外扩 max(spacing, 2) 列（间隔带与四个站位列）。
  defp window({fx0, fz0}, %{size: {wx, _, wz}, spacing: s}) do
    e = max(s, 2)
    {{fx0 - e, fz0 - e}, {fx0 + wx - 1 + e, fz0 + wz - 1 + e}}
  end

  # 平整体积：足迹各列从最低地表到目标地面之上的建筑高度。
  defp volume({fx0, fz0}, %{size: {wx, h, wz}}, %{ground: g, low: low}),
    do: {{fx0, low, fz0}, {fx0 + wx - 1, g + h, fz0 + wz - 1}}

  defp sight(box, state),
    do: if(in_sight?(box, state.position), do: {:ok, state}, else: {:skip, :too_far, state})

  defp in_sight?(box, position) do
    Enum.all?(chunks(box, Perception.look_cells()), fn {lo, hi} ->
      Perception.prepare(position, %{verb: :look, min: lo, max: hi}) != nil
    end)
  end

  # 分块 look，合并成按格索引的行。
  defp look_box(box, state) do
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

  # 平整的挖：从站位逐格挖（Gather.order/2：自上而下、由近到远；每格 Gather.mine/3，挖到的天然格照常入账）。这次打不到 →
  # 此刻够不着（out_of_reach）；命中的不是天然宏格（作者 prefab 宏格）→ 地块不成立（blocked）。
  defp dig([], state), do: {:ok, state}

  defp dig(cells, state) do
    with {:ok, state} <- interval(state) do
      eye = Player.eye_position(state.position)

      cells
      |> Gather.order(horizontal(state.position))
      |> Enum.reduce_while({:ok, state}, fn cell, {:ok, state} ->
        case Gather.mine(cell, eye, state) do
          {:mined, state} -> {:cont, {:ok, state}}
          {:blocked, state} -> {:halt, {:skip, :out_of_reach, state}}
          {:foreign, state} -> {:halt, {:skip, :blocked, state}}
          {:error, _, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # 工具间隔（两击之间至少隔它，与 gather 同一读路径）；工具不在目录里 = 参数不成立。
  defp interval(%{interval_ms: nil} = state) do
    case World.tool_definition(state.world, state.tool) do
      {:ok, definition} ->
        {:ok, %{state | interval_ms: round(definition["interval_seconds"] * 1_000)}}

      :error ->
        {:error, :invalid_skill_arguments, state}
    end
  end

  defp interval(state), do: {:ok, state}

  # 补料：材料单加上填坑的石料（要填的格数 × 每格单位），按材料号取第一种缺料，采够后重取余额再看下一种；都不缺 → :ok。
  # 缺的材料不是本世界的生产材料（余额表里没有它，挖了也不入账）：换地块也不会变 → 终态 insufficient_material；
  # 站位附近采不到够用的 → 跳过这块地（insufficient_material，见 gather/5）。
  defp supply(materials, fills, plot, site, spec, state) do
    with {:ok, %{balances: rows}, state} <- Skill.call(state, %{verb: :query_balances}) do
      # 石料不在余额表里时每格按 1 单位记缺，由 stock/6 以终态结束。
      units = fills * Enum.find_value(rows, 1, &(&1.material == @fill && &1.cost))

      need =
        if units == 0, do: materials, else: Map.update(materials, @fill, units, &(&1 + units))

      stock(need, rows, plot, site, spec, state)
    end
  end

  defp stock(need, rows, plot, site, spec, state) do
    have = Map.new(rows, &{&1.material, &1.balance})

    case Enum.find(Enum.sort(need), fn {m, units} -> units > Map.get(have, m, 0) end) do
      nil ->
        {:ok, state}

      {material, _} when not is_map_key(have, material) ->
        {:error, :insufficient_material, state}

      {material, units} ->
        with {:ok, cells, state} <- quarry_cells(material, plot, site, spec, state),
             {:ok, state} <- gather(cells, material, units, units - have[material], state),
             {:ok, %{balances: rows}, state} <- Skill.call(state, %{verb: :query_balances}),
             do: stock(need, rows, plot, site, spec, state)
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

    with {:ok, rows, state} <- look_box({{x0, g, z0}, {x1, g + @heap + 1, z1}}, state) do
      keep = {{fx0 - s - 1, fz0 - s - 1}, {fx0 + wx + s, fz0 + wz + s}}
      {:ok, quarry(rows, %{material: material, ground: g, area: area, keep: keep}, from), state}
    end
  end

  # 逐格交给 gather（单格盒、缺额 units）：done / exhausted / unreachable 都重取余额（挖到一半也已入账），不缺了就结束，
  # 还缺就下一格；候选用尽 → 这块地附近采不到够用的料，跳过（insufficient_material）。gather 的其余拒绝原样作为终态。
  defp gather([], _material, _need, _units, state), do: {:skip, :insufficient_material, state}

  defp gather([cell | rest], material, need, units, state) do
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
          if short > 0, do: gather(rest, material, need, short, state), else: {:ok, state}
        end
    end
  end

  # 填坑：自下而上逐格 place 石料（与玩家同一入口、花自己的余额）。被拒为 @refused 或缺料 → 跳过这块地（原因原样计入）；
  # 其余拒绝原样作为终态。
  defp fill(cells, state) do
    Enum.reduce_while(cells, {:ok, state}, fn cell, {:ok, state} ->
      command = %{verb: :place, coord: cell, material: @fill, tool_id: state.tool}

      case Skill.call(state, command) do
        {:ok, _, state} ->
          {:cont, {:ok, state}}

        {:error, reason, state} when reason in @refused or reason == :insufficient_material ->
          {:halt, {:skip, reason, state}}

        error ->
          {:halt, error}
      end
    end)
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

  # 站位：离 from 由近到远第一个“列里有离 g 不超过 @relief 格、站得下的地面”的。
  defp stand(columns, stands, g) do
    case Enum.find(stands, fn {sx, sz} ->
           Enum.any?(
             Map.fetch!(columns, {floor(sx), floor(sz)}).floors,
             &(abs(&1 - g) <= @relief)
           )
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

  # 一格要怎样平整：g 以上（above = true）要空气，g 及以下要实心地面。
  defp work(row, true) do
    cond do
      air?(row) -> :keep
      natural?(row) -> :dig
      true -> :blocked
    end
  end

  defp work(row, false) do
    case Perception.walk_kind(row) do
      :solid -> :keep
      :open -> if air?(row) or natural?(row), do: :fill, else: :blocked
      nil -> :blocked
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp horizontal({x, _, z}), do: {x, z}

  # 空气：prefab 只放进这种格（花草、液体、细化格都不是）。
  defp air?(row), do: row.material == 0 and not row.refined

  # 天然的非空气格：没有放置记录、非细化、非液体（天然地形、花草、作者写入的格）。
  defp natural?(row),
    do:
      row.material != 0 and row.placed_by == nil and not row.refined and
        not Phase.liquid?(row.material)
end
