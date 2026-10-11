defmodule GateServer.Npc.Perception do
  @moduledoc """
  全局系统功能：父脑与技能共用的感知条目（look / survey / inspect / query_balances / read_catalog，形状见
  `GateServer.Npc.Abilities`）、范围校验、真实 World 只读入口与模型投影（`project/3`）。

  步行判据也只在这里：`walk_kind/1`（一格能不能踩、能不能穿过；Body 的寻路网格、survey 与扩张选址共用）与列扫描
  `floors/2`（一列里哪些格站得下自己）。survey 的地表（`surfaces/2`）、travel 的段终点站立层、expand 的地面都从它取。

  目录读取（Body 动词 `read_catalog`）也在这里：prefab 定义的材料单与尺寸、最近的运行时发布、材料表、工具表，
  全部取自 World 的公共只读目录（`prefab_catalog/1`、`published_prefabs/1`、`material_catalog/1`），不缓存。
  材料表的可食 / 配方只对生产材料给出（集合取自 `material_balances/2`），与 World 进食、合成门受理的材料一致。
  prefab 目录行（尺寸、材料单）只在 `prefab_row/3` 计算一次，`design_house` 的目录投影也用它。
  """
  alias GateServer.Npc.Actions
  alias MmoContracts.VoxelMaterialCatalog
  alias SceneServer.PrefabDesigner.Check
  alias VoxelRegion.{Phase, Spatial, World}
  @cells 512
  # 一次 survey 每边最多的列数。
  @columns 32
  # 感知与移动目标相对身体的单轴距离上限（米）。
  @reach 32
  # inspect 的窗口：自己所在的 tile（米）及相邻 tile。
  @tile 64
  # read_catalog "prefabs" 返回的最近运行时发布条数。
  @recent 20
  # 模型看到的 inspect 只列最近这么多件；原始只读查询仍返回完整窗口。
  @nearest 24

  @doc "当前角色可查询的各轴距离上限，单位米。"
  def reach, do: @reach
  @doc "一次 look 最多的格数（更大的范围分几次看）。"
  def look_cells, do: @cells
  @doc "一次 survey 每边最多的列数。"
  def survey_columns, do: @columns
  @doc "感知条目（group :sense，顺序固定）；条目形状见 `GateServer.Npc.Abilities`。"
  def entries,
    do: [
      %{
        name: "look",
        group: :sense,
        description:
          "看一个整数格闭区间 (x0,y0,z0)–(x1,y1,z1) 里有什么：1 格 = 1 米，格 (x,y,z) 占据 [x,x+1)×[y,y+1)×[z,z+1)。" <>
            "最多 #{@cells} 格，各边离自己不超过 #{@reach} 米。结果只列非空气格（按 \"x,z\" 列给出 [y, material]；有人放下的格是 [y, material, 放置者的 entity_id]，" <>
            "没有第三项表示没有放置溯源，可能是天然地形或历史／作者写入）。refined 行的 micro_boxes 按材质给出被占的 WORLD micro 闭区间盒 [x0,y0,z0,x1,y1,z1]（并起来恰好是被占的 micro 格），slots 给出各实例的格数与放置者。" <>
            "仅在 bounds_macro_inclusive 内两处都没列出的才是空气；窗口外未知，附件须用 inspect。",
        done: "data 是观察那一刻的世界（seq 为版本），不改世界。",
        params: [
          x0: :integer,
          y0: :integer,
          z0: :integer,
          x1: :integer,
          y1: :integer,
          z1: :integer
        ],
        build: fn p, _ -> %{verb: :look, min: {p.x0, p.y0, p.z0}, max: {p.x1, p.y1, p.z1}} end
      },
      %{
        name: "survey",
        group: :sense,
        description:
          "勘察一片地的高低（地表高度图）：整数列闭区间 (x0,z0)–(x1,z1)，1 列 = 1×1 米，每边最多 #{@columns} 列、各边离自己不超过 #{@reach} 米；" <>
            "竖直只看自己所在高度上下 #{@reach} 米。每列的地表 = 扫描范围里最高的、上面站得下自己的实心格 y（站在上面时脚所在的格是 y + 1；" <>
            "花草、液体、细化格都不是地面，花草长在地面上方）。rows 按 z 从 z0 到 z1 排，每行按 x 从 x0 到 x1：[ground_y, material, move_to_y]，" <>
            "移动时直接使用第三项 move_to_y，不要把第一项实心地表当作脚所在空气格；" <>
            "null = 扫描范围里这一列没有站得下的地面（水面、被细化格或悬空物压着、整列空气或实心、在范围外）。" <>
            "placed 列出地表格有放置者的列 [x, z, 放置者 entity_id]，refined 列出扫描范围里含细化格（micro 构件，多半是谁的建筑）的列 [x, z]。" <>
            "看地势、核对整平、找落脚点用它：一次看整片，比分层 look 省；要知道某几格具体是什么再用 look。",
        done: "data 是勘察时的世界（分 x 片读取，seq 是 [首片, 末片] 的版本），不改世界。",
        params: [x0: :integer, z0: :integer, x1: :integer, z1: :integer],
        build: fn p, _ -> %{verb: :survey, min: {p.x0, p.z0}, max: {p.x1, p.z1}} end
      },
      %{
        name: "inspect",
        group: :sense,
        description:
          "列出周围（自己所在 #{@tile} 米 tile 及相邻 tile）的附件与预制件构件：附件给 attachment_id、kind（face / edge）、" <>
            "axis（x / y / z，与 attach 的参数同名）、micro 坐标、material、hp；" <>
            "构件给 instance [birth, occurrence] 与占的格。只列离自己最近的 #{@nearest} 件，total 是总数。" <>
            "每行的 target 原样交给 use_tool / dismantle / detach，instance 用于 prefab 的 remove / replace。",
        done: "data 是观察那一刻的世界（seq 为版本），不改世界。",
        params: [],
        build: fn _, _ -> %{verb: :inspect} end
      },
      %{
        name: "query_balances",
        group: :sense,
        description:
          "读取自己的背包余额：每种 material 的单位数与放一格的花费（cost）。balances 为 null 时先调用它；" <>
            "自己的每次世界事务之后会自动刷新。",
        done: "data.balances 是 World 余额表的原样副本。",
        params: [],
        build: fn _, _ -> %{verb: :query_balances} end
      },
      %{
        name: "read_catalog",
        group: :sense,
        description:
          "读世界的公共目录。what = prefab：给 definition（64 位十六进制 id）的材料单（material → 单位）、尺寸（米）与" <>
            "包围盒 bounds_micro（朝向 0 时相对锚点的 micro 半开区间 [[x0,y0,z0],[x1,y1,z1]]，1 米 = #{Spatial.micro_resolution()} micro），" <>
            "没有这个 id 回 definition_not_found；prefabs：最近 #{@recent} 条运行时发布；materials：全部材料的名称、" <>
            "可食（edible）与合成配方（recipe）；tools：每个 tool_id 的动作、射程（米）与间隔（秒）。单位与 balances 相同；" <>
            "除 prefab 外 definition 写 null。",
        done: "data 是目录的当前内容，不改世界。",
        params: [
          what:
            {:enum,
             %{
               "prefab" => :prefab,
               "prefabs" => :prefabs,
               "materials" => :materials,
               "tools" => :tools
             }},
          definition: {:nullable, :hex32}
        ],
        build: fn %{what: what, definition: definition}, _ ->
          %{verb: :read_catalog, what: what, definition: definition}
        end
      }
    ]

  @doc "以当前角色位置校验完整 XYZ 查询范围；非法参数不访问 World。"
  def prepare({px, py, pz}, %{verb: :look, min: {x0, y0, z0}, max: {x1, y1, z1}})
      when is_integer(x0) and is_integer(y0) and is_integer(z0) and is_integer(x1) and
             is_integer(y1) and is_integer(z1) and x0 <= x1 and y0 <= y1 and z0 <= z1 and
             (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) <= @cells and
             x0 >= px - @reach and x1 <= px + @reach and y0 >= py - @reach and y1 <= py + @reach and
             z0 >= pz - @reach and z1 <= pz + @reach,
      do: {:look, for(x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x, y, z})}

  def prepare({x, y, z}, %{verb: :inspect}) do
    {rx, ry, rz} = {floor(x / @tile), floor(y / @tile), floor(z / @tile)}
    {:inspect, {{rx - 1, ry - 1, rz - 1}, {rx + 2, ry + 2, rz + 2}}}
  end

  # 目录与位置无关：prefab 必须给 32 字节定义 id，其余三种 definition 为 nil。
  def prepare(_, %{verb: :read_catalog, what: :prefab, definition: <<_::256>> = id}),
    do: {:catalog, :prefab, id}

  def prepare(_, %{verb: :read_catalog, what: what, definition: nil})
      when what in [:prefabs, :materials, :tools],
      do: {:catalog, what, nil}

  def prepare(_, _), do: nil

  @doc """
  survey 的范围校验：列闭区间每边不超过 #{@columns} 列、各边离自己不超过 reach；竖直取自己所在高度上下 reach 的整数格
  （与 look 同一距离护栏）。`clearance` 是身高占的格数（`GateServer.Npc.Context.clearance/1`）。返回 `{:survey, 范围}`；
  非法参数返回 nil，不访问 World。
  """
  def prepare({px, py, pz}, %{verb: :survey, min: {x0, z0}, max: {x1, z1}}, clearance)
      when is_integer(x0) and is_integer(z0) and is_integer(x1) and is_integer(z1) and
             x0 <= x1 and z0 <= z1 and x1 - x0 < @columns and z1 - z0 < @columns and
             x0 >= px - @reach and x1 <= px + @reach and z0 >= pz - @reach and z1 <= pz + @reach and
             is_integer(clearance) and clearance > 0,
      do:
        {:survey,
         %{
           columns: {{x0, z0}, {x1, z1}},
           y: {ceil(py - @reach), floor(py + @reach)},
           clearance: clearance
         }}

  def prepare(_, _, _), do: nil

  @doc """
  一格对步行的意义（唯一判据：Body 的寻路网格、survey 与扩张选址共用）。`row` 是 `World.material_snapshot` 的格行。
  `:solid` = 能踩：挡路（与碰撞同一判据 `VoxelMaterialCatalog.blocks_movement?/1`，collision_source.ex 用它建碰撞）、
  非液体、非细化；`:open` = 可穿过：不挡路（空气、花草）、非液体、非细化；`nil` = 既不能踩也不能穿过：液体，以及细化格——
  碰撞按 micro 几何，宏格网格只能保守地整格挡住，也不能站在它上面（1/8 米的面板顶站不住人）。
  """
  def walk_kind(%{material: material, refined: refined}) do
    cond do
      refined or Phase.liquid?(material) -> nil
      VoxelMaterialCatalog.blocks_movement?(material) -> :solid
      true -> :open
    end
  end

  @doc """
  列扫描（纯函数）：`cells` 是一列自下而上连续的格行（`%{cell: [x, y, z], material:, refined:}`），返回站得下的地面层 y
  （升序）：该格 `:solid`，其上 `clearance` 格都在这一列里且都 `:open`（`walk_kind/1`）。站在地面 y 上时脚所在格是 y + 1；
  净空伸出扫描范围的格不算（范围外未知）。
  """
  def floors(cells, clearance) do
    cells
    |> Enum.map(&{&1.cell, walk_kind(&1)})
    |> Enum.chunk_every(clearance + 1, 1, :discard)
    |> Enum.flat_map(fn
      [{[_, y, _], :solid} | above] ->
        if Enum.all?(above, &(elem(&1, 1) == :open)), do: [y], else: []

      _ ->
        []
    end)
  end

  @doc """
  survey 的列结果（纯函数）：`rows` 是若干整列的格行（每列同一竖直范围内的全部格，`World.material_snapshot` 的形状），返回按
  `{x, z}` 排序的 `[%{column: [x, z], floors:, y:, material:, placed_by:, refined:}]`：`floors` 同 `floors/2`；地表 `y` = 最高的
  一层（没有则 nil），`material` / `placed_by` 是地表这一格的；`refined` = 这一列扫描范围里有细化格。
  """
  def surfaces(rows, clearance) do
    rows
    |> Enum.group_by(fn %{cell: [x, _, z]} -> {x, z} end)
    |> Enum.sort()
    |> Enum.map(fn {{x, z}, cells} ->
      cells = Enum.sort_by(cells, fn %{cell: [_, y, _]} -> y end)
      floors = floors(cells, clearance)
      top = List.last(floors)
      surface = top && Enum.find(cells, &match?(%{cell: [_, ^top, _]}, &1))

      %{
        column: [x, z],
        floors: floors,
        y: top,
        material: surface && surface.material,
        placed_by: surface && surface.placed_by,
        refined: Enum.any?(cells, & &1.refined)
      }
    end)
  end

  @doc "读取已通过范围检查的请求；保留版本、采样范围与未观测边界。"
  def read(world, cid, {:look, cells}) do
    snapshot = World.material_snapshot(world, [cid], cells, :micro)
    lo = for axis <- 0..2, do: cells |> Enum.map(&elem(&1, axis)) |> Enum.min()
    hi = for axis <- 0..2, do: cells |> Enum.map(&elem(&1, axis)) |> Enum.max()

    {:ok,
     Map.merge(snapshot, %{
       bounds_macro_inclusive: [lo, hi],
       outside: :unknown,
       attachments: :not_sampled
     })}
  end

  # survey：按 x 分片（一片 = 这一个 x 的全部 z × 竖直范围，≤ 32 × 65 格），与 look 同一个只读入口；片与片之间可能有别人的
  # 事务，所以 seq 给 [首片, 末片]。不一次取整片：那会让 World 进程一口气逐格求值六万多格。
  def read(
        world,
        _cid,
        {:survey, %{columns: {{x0, z0}, {x1, z1}}, y: {y0, y1}, clearance: clearance}}
      ) do
    snapshots =
      for x <- x0..x1,
          do: World.material_snapshot(world, [], for(z <- z0..z1, y <- y0..y1, do: {x, y, z}))

    {:ok,
     %{
       seq: [hd(snapshots).seq, List.last(snapshots).seq],
       bounds_columns_inclusive: [[x0, z0], [x1, z1]],
       scanned_y: [y0, y1],
       clearance: clearance,
       columns: Enum.flat_map(snapshots, &surfaces(&1.probe_occupancy, clearance)),
       outside: :unknown
     }}
  end

  def read(world, cid, {:inspect, box}),
    do:
      {:ok,
       World.simulation_snapshot(world, [cid], box)
       |> Map.take([:seq, :property_states])
       |> Map.put(:bounds_region_half_open, box)}

  # 目录：作者目录与运行时发布都在 prefab_catalog 里（F21）；单位与余额相同，都是微格体积单位。
  def read(world, _cid, {:catalog, :prefab, id}) do
    case Map.fetch(World.prefab_catalog(world), id) do
      {:ok, compiled} ->
        row = prefab_row(id, compiled, World.material_catalog(world))
        {lo, hi} = row.summary.bounds

        {:ok,
         %{
           definition_id: id,
           materials: row.materials.units,
           size_m: row.size_m,
           bounds_micro: [Tuple.to_list(lo), Tuple.to_list(hi)]
         }}

      :error ->
        {:error, :definition_not_found}
    end
  end

  # 最近的运行时发布在前；id = 定义字节的 sha256（与 World 目录同一键）。
  def read(world, _cid, {:catalog, :prefabs, nil}) do
    published = World.published_prefabs(world)
    catalog = World.prefab_catalog(world)
    properties = World.material_catalog(world)

    rows =
      for {publisher, name, bytes} <- published |> Enum.reverse() |> Enum.take(@recent) do
        id = :crypto.hash(:sha256, bytes)

        %{
          definition_id: id,
          name: name,
          publisher: publisher,
          materials: prefab_row(id, Map.fetch!(catalog, id), properties).materials.units
        }
      end

    {:ok, %{prefabs: rows, total: length(published)}}
  end

  # 行列出全部材料（look 结果里的天然材料也要名字）；edible / recipe 只对生产材料给出，与 World 进食 / 合成门
  # 同一组条件（w/production.ex 的 consume、craft：目录有 food / recipe_inputs，且材料在 production_materials 里）。
  # 生产材料取自公共余额读口 material_balances/2，它恰按 production_materials 逐项返回。
  def read(world, cid, {:catalog, :materials, nil}) do
    producible = MapSet.new(World.material_balances(world, cid), & &1.material)

    rows =
      for {id, row} <- Enum.sort(World.material_catalog(world).materials) do
        open = MapSet.member?(producible, id)
        food = row["food"]

        %{
          material: id,
          name: row["display_name"],
          edible:
            if(open and food != nil,
              do: %{protein_g: food["protein_g"], energy_j: food["energy_j"]}
            ),
          recipe:
            if(open and Map.has_key?(row, "recipe_inputs"),
              do: %{
                inputs: Map.new(row["recipe_inputs"], &{&1["material_id"], &1["units"]}),
                units: row["recipe_units"]
              }
            )
        }
      end

    {:ok, %{materials: rows}}
  end

  def read(world, _cid, {:catalog, :tools, nil}) do
    rows =
      for {id, tool} <- Enum.sort(World.material_catalog(world).tools),
          do: %{
            tool_id: id,
            action: tool["action"],
            range_m: tool["range_macro"],
            interval_s: tool["interval_seconds"]
          }

    {:ok, %{tools: rows}}
  end

  @doc """
  一条 prefab 目录行：定义 id、编译摘要、包围盒尺寸（米）与材料单（`PrefabDesigner.Check.materials/2`：
  `units` 与 `volume_m3`，与完整检查同一计价）。`read_catalog` 与 `design_house` 的目录投影共用这一份计算。
  """
  def prefab_row(id, compiled, properties) do
    {lo, hi} = compiled.summary.bounds

    %{
      definition_id: id,
      summary: compiled.summary,
      size_m: for(i <- 0..2, do: (elem(hi, i) - elem(lo, i)) / Spatial.micro_resolution()),
      materials: Check.materials(compiled, properties)
    }
  end

  @doc """
  细化行给模型的紧凑形：逐个 micro 的 `micro_cells` 换成按材质合并的 `micro_boxes`
  `[%{material:, box: [x0, y0, z0, x1, y1, z1]}]`（WORLD micro 坐标闭区间；同一材质的盒互不重叠，并起来恰好是原占用，
  无损）。实例归属看 `slots`（各实例的格数与 placed_by）。没有 `micro_cells` 的行原样返回。
  原样逐格列出时，一面 micro 薄墙一格就是上百项：建在自家 micro 构件旁的设计会话首条消息约 13 万 token，两轮就越过
  会话预算（2026-10-08 长跑 run04）。只用于给模型的投影；Body 的 look Outcome 仍是 `World.material_snapshot/4` 原样。
  """
  def compact_refined(%{micro_cells: micros} = row) do
    boxes =
      micros
      |> Enum.group_by(& &1.material, &micro_coord/1)
      |> Enum.sort()
      |> Enum.flat_map(fn {material, coords} ->
        for box <- boxes(MapSet.new(coords)), do: %{material: material, box: box}
      end)

    row |> Map.delete(:micro_cells) |> Map.put(:micro_boxes, boxes)
  end

  def compact_refined(row), do: row

  defp micro_coord(%{micro: {x, y, z}}), do: {x, y, z}
  defp micro_coord(%{micro: [x, y, z]}), do: {x, y, z}

  # 贪心合并：取 (z, y, x) 最小的格，先沿 x、再沿 y、再沿 z 尽量延伸成实心盒，去掉后对剩下的格重复。
  defp boxes(set) do
    case Enum.min_by(set, fn {x, y, z} -> {z, y, x} end, fn -> nil end) do
      nil ->
        []

      {x0, y0, z0} ->
        x1 = extend(x0, &MapSet.member?(set, {&1, y0, z0}))
        y1 = extend(y0, fn y -> Enum.all?(x0..x1, &MapSet.member?(set, {&1, y, z0})) end)

        z1 =
          extend(z0, fn z ->
            Enum.all?(x0..x1, fn x -> Enum.all?(y0..y1, &MapSet.member?(set, {x, &1, z})) end)
          end)

        covered = for x <- x0..x1, y <- y0..y1, z <- z0..z1, into: MapSet.new(), do: {x, y, z}
        [[x0, y0, z0, x1, y1, z1] | boxes(MapSet.difference(set, covered))]
    end
  end

  defp extend(a, ok?), do: if(ok?.(a + 1), do: extend(a + 1, ok?), else: a)

  @doc """
  Outcome 进历史（新在前）。look 将普通非空气格按列压缩，保留细化格的占用与归属；survey 换成按行的地表高度图（放置者与
  细化格另列）。look / survey 保留各次观察的版本、范围与内容，历史长度由大脑统一控制，避免分段核对尚未完成就丢失前段。
  """
  def project(
        %{verb: :look, status: :done, data: %{probe_occupancy: cells}} = outcome,
        outcomes,
        _position
      ) do
    columns =
      for(
        %{cell: [x, y, z], material: material} = cell <- cells,
        material != 0,
        # 有人花材料放下的格带上放置者的 entity_id（第三项）；天然地形与作者写入的格只有 [y, material]。
        do: {"#{x},#{z}", [y, material] ++ List.wrap(cell[:placed_by])}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    data =
      Map.take(outcome.data, [:seq, :bounds_macro_inclusive, :outside, :attachments])
      |> Map.merge(%{solid: columns, refined: for(c <- cells, c.refined, do: compact_refined(c))})

    [%{outcome | data: data} | outcomes]
  end

  # survey：地表高度图按行（z）给出，每行按 x：[y, material] 或 null；放置者与细化格另列（多数列没有，不逐列重复）。
  def project(
        %{verb: :survey, status: :done, data: %{columns: columns}} = outcome,
        outcomes,
        _position
      ) do
    [[x0, z0], [x1, z1]] = outcome.data.bounds_columns_inclusive
    at = Map.new(columns, &{List.to_tuple(&1.column), &1})

    data =
      Map.take(outcome.data, [:seq, :bounds_columns_inclusive, :scanned_y, :outside])
      |> Map.merge(%{
        row_fields: [:ground_y, :material, :move_to_y],
        rows: for(z <- z0..z1, do: for(x <- x0..x1, do: height(at[{x, z}]))),
        placed: for(%{placed_by: by, column: column} <- columns, by != nil, do: column ++ [by]),
        refined: for(%{refined: true, column: column} <- columns, do: column)
      })

    [%{outcome | data: data} | outcomes]
  end

  # inspect 同理：只留模型用得上的身份与状态，更早的 inspect 只留结论。每行附原样目标句柄 target，
  # 模型把它抄进 use_tool / dismantle / detach（显式句柄，不靠“最近一次 inspect”的隐式状态）。
  def project(
        %{verb: :inspect, status: :done, data: %{property_states: rows}} = outcome,
        outcomes,
        position
      ) do
    # micro 坐标 / 8 = 米；按到自己的距离取最近的 @nearest 件。
    nearest = fn rows ->
      rows
      |> Enum.sort_by(fn %{micro: {x, y, z}} -> distance({x / 8, y / 8, z / 8}, position) end)
      |> Enum.take(@nearest)
    end

    # kind / axis 用 attach 参数的同名字符串（Actions 的同一张表），模型照抄即可贴一件同向的。
    attachments =
      for %{owner: {id, _}} = row <- nearest.(Enum.filter(rows, &(&1.granularity == 3))) do
        %{attachment_id: id, micro: row.micro}
        |> Map.merge(Actions.attachment_names(row))
        |> Map.merge(Map.take(row, [:material, :hp, :max_hp, :circuit]))
        |> Map.put(:target, target(row))
      end

    components =
      for %{owner: {birth, occurrence}} = row <-
            nearest.(Enum.filter(rows, &(&1.granularity == 2))),
          do: %{
            instance: [birth, occurrence],
            material: row.material,
            cells: row.observation_cells,
            target: target(row)
          }

    data =
      Map.merge(Map.take(outcome.data, [:seq, :bounds_region_half_open]), %{
        attachments: attachments,
        components: components,
        total: %{
          attachments: Enum.count(rows, &(&1.granularity == 3)),
          components: Enum.count(rows, &(&1.granularity == 2))
        }
      })

    older = for o <- outcomes, do: if(o.verb == :inspect, do: %{o | data: nil}, else: o)
    [%{outcome | data: data} | older]
  end

  # probe_toward 命中（g0..g3）：data 加原样目标句柄 target（带本次探测方向），模型抄进 use_tool / dismantle。
  def project(
        %{verb: :probe_toward, status: :done, data: %{granularity: g} = data} = outcome,
        outcomes,
        _position
      )
      when g in 0..3,
      do: [%{outcome | data: Map.put(data, :target, target(data))} | outcomes]

  def project(outcome, outcomes, _position), do: [outcome | outcomes]

  defp height(%{y: nil}), do: nil
  defp height(%{y: y, material: material}), do: [y, material, y + 1]

  # 目标句柄：0x7D 的身份字段 + 方向（inspect 行没有方向，为 nil，Body 按句柄从眼点瞄准）。
  defp target(row),
    do:
      row
      |> Map.take([:granularity, :micro, :incarnation, :owner, :material])
      |> Map.put(:direction, Map.get(row, :direction))

  defp distance({x, y, z}, {px, py, pz}),
    do: :math.sqrt((x - px) * (x - px) + (y - py) * (y - py) + (z - pz) * (z - pz))
end
