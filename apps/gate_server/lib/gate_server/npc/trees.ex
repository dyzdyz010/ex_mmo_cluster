defmodule GateServer.Npc.Trees do
  @moduledoc """
  全局系统功能：行为树定义（`GateServer.Npc.Brain.Tree` 的作者侧）。每个函数接 profile、返回 `{树, 黑板初值}`，
  配置成 `brain: {GateServer.Npc.Brain.Tree, %{tree: &GateServer.Npc.Trees.settler/1, ...}}`。

  ## Settler（建设者，设计稿 docs/10-active/cross-cutting/2026-10-07-character-capability-library.md §8.2）

  profile：

      %{tree: &GateServer.Npc.Trees.settler/1,
        definition: hex64,                                    # 已发布的定义（作者目录或运行时发布）
        sites: [%{anchor_micro: [x, y, z], orientation: 0..23, stand: [x, z]}],
        quarries: %{material_id => %{box: [[x0, y0, z0], [x1, y1, z1]], tool_id: t}},   # 可缺省（只用现有余额）
        revisit_ticks: 36_000,                                # 一轮巡完后休息多久（tick，60 Hz）
        expansion: %{region: [[x0, z0], [x1, z1]], spacing: n, tool_id: t},   # 可缺省；配了 skills 要有 expand
        tools: %{t => 说明}, skills: %{build: %{}, gather: %{}, travel: %{}}}

  每轮：`read_catalog what: "prefab"` 取材料单，按顺序走每个工地：到站位 → `build`；建成即这个工地完成。
  `build` 回 `insufficient_material` → `query_balances` → 取第一种缺料且配了采石盒的材料，`gather` 缺额
  （units = 材料单 − 余额）→ 回站位 → 再 `build` 一次。`build` 回 `occupied` → `look` 锚点格：整格或格内构件实例的 `placed_by` 是自己 →
  视为已建成，否则跳过。其余拒绝（protected_region、out_of_reach、no_path、stuck、out_of_bounds、exhausted、
  unreachable…）这个工地本轮放弃，换下一个。配了 `expansion` 时，巡完已知工地后调一次 `expand`（`Skills.Expand`：在区域里找空地、
  缺料自己采、放下）：done 就把新工地 `%{anchor_micro, orientation, stand}` 追加进黑板的工地列表，下一轮起与作者工地同样维护
  （被拆就重建）；`no_site` 等拒绝记一行 `npc_settler_idle entity= act=expand reason=`（没有 context），下一轮再找（期间空出来的
  地块会被用上）。所以每轮最多新建一座。一轮巡完等 `revisit_ticks` 再巡。

  | 规则 | 内容 |
  |---|---|
  | 次数上限 | 每次尝试最多 gather 一次、build 重试一次；每工地每轮最多两次尝试（树结构保证，无循环） |
  | 瞬态原因 | `invalid_session` / `dead` / `session_lost`（`Brain.Tree.transient/0`）：工地内任一步遇到，60 tick（1 秒）后从站位整体重来一次——复活与重新 claim 后身体在出生点，缺额由 `query_balances` 重算，不原样重发旧命令；再遇瞬态原因本工地本轮放弃。只有 `read_catalog`（只读、与位置无关）带 `retry: 60` 原样重发 |
  | 停因日志 | 工地放弃记一行 `npc_settler_idle entity= act= reason= context=<工地>`；材料单取不到（`definition_not_found`）本轮放弃，记 `npc_settler_idle entity= act=read_catalog reason=…`，休息后再试 |
  | 进度 | 不存档，以权威为准：重启后从头巡，已建好的工地表现为 occupied → 自家锚点 → 跳过，不重复建 |
  | 扩张出来的工地 | 只在黑板里，不存档：重启后只剩作者工地。扩张从世界现状继续（已建的地块因间隔带里有放置记录不再是候选），代价只是重启前扩张出来的建筑不再被维护；它们被拆后地块空出来，又会被扩张在网格上的原位置重建。不写进记忆：记忆将来换成独立系统，现在不依赖它（放置阶段决策稿 §7） |

  作者保证：定义（宏格或 micro 构件均可）占着锚点格（`anchor_micro` 所在的 macro 格，否则 occupied 时认不出是自家）；各站位与采石盒站位
  两两水平距离不超过 `Perception.reach()`（维护工地时是单程 move_to，不做分段与长途寻路）；配了扩张时，扩张区域（含外扩 2 格的站位）
  也在这个范围里，否则远处扩张出来的工地在维护时 `too_far`、本轮跳过（`expand` 自己找地时会分段走）；站位离锚点格在工具射程内。
  被占一律跳过、不清场。
  """

  # 瞬态原因之后等 1 秒（60 tick）。
  @pause 60

  @doc "Settler 树与黑板初值（`definition`、`sites`、`quarries`、`expansion`）；形状见 moduledoc。"
  def settler(profile) do
    # 回工地站位走 travel（分段 move_to）：扩张出来的工地可以离得比单程上限远（放置阶段决策稿 §7）。
    stand = {:act, "travel", &stand_args/1}
    build = {:act, "build", &build_args/1}

    attempt =
      {:seq,
       [
         stand,
         {:sel,
          [
            # 建成即本工地完成。
            build,
            {:seq,
             [
               {:cond, &last?(&1, &2, :insufficient_material)},
               {:act, "query_balances", %{}, store: :balances},
               # 首个缺料且配了采石盒的材料。
               {:cond, &shortage?/2},
               {:act, "gather", &gather_args/1},
               # 先回站位再重试一次 build。
               stand,
               build
             ]},
            {:seq,
             [
               {:cond, &last?(&1, &2, :occupied)},
               {:act, "look", &anchor_cell/1, store: :anchor},
               # 锚点格（或格内构件实例）placed_by == 自己 → 视为已建成。
               {:cond, &own_anchor?/2}
             ]}
          ]}
       ]}

    # 瞬态原因：身体可能已回出生点、余额可能已变（gather 中途失败时已挖的格已入账），从站位整体重来一次。
    site = {:sel, [attempt, {:seq, [{:cond, &transient?/2}, {:wait, @pause}, attempt]}]}

    expansion = Map.get(profile, :expansion)

    # 巡完已知工地再扩张一次：done 的新工地追加进工地列表（下一轮起维护它），其余结果记 idle。
    expand =
      {:succeed, {:act, "expand", &expand_args/1, append: {:sites, &new_site/1}},
       log: "npc_settler_idle"}

    round =
      {:seq,
       [
         {:act, "read_catalog", %{"what" => "prefab", "definition" => profile.definition},
          store: :bill, retry: @pause},
         {:each, :sites, :site, {:succeed, site, log: "npc_settler_idle", context: :site}}
       ] ++ if(expansion, do: [expand], else: [])}

    tree =
      {:repeat, :forever,
       {:seq, [{:succeed, round, log: "npc_settler_idle"}, {:wait, profile.revisit_ticks}]}}

    {tree,
     %{
       definition: profile.definition,
       sites: profile.sites,
       quarries: Map.get(profile, :quarries, %{}),
       expansion: expansion
     }}
  end

  defp expand_args(%{definition: definition, expansion: expansion}),
    do: %{
      "definition" => definition,
      "region" => expansion.region,
      "tool_id" => expansion.tool_id,
      "spacing" => expansion.spacing
    }

  # expand 的 done data 里只有这三项是工地（另有 site_cell / seq / skipped 与 Runtime 加的 metrics）。
  defp new_site(data), do: Map.take(data, [:anchor_micro, :orientation, :stand])

  defp stand_args(%{site: %{stand: [x, z]}}), do: %{"x" => x, "z" => z}

  defp build_args(%{site: site, definition: definition}),
    do: %{
      "definition" => definition,
      "anchor_micro" => site.anchor_micro,
      "orientation" => site.orientation
    }

  defp gather_args(blackboard) do
    {material, units} = shortage(blackboard)
    quarry = blackboard.quarries[material]

    %{
      "box" => quarry.box,
      "material" => material,
      "units" => units,
      "tool_id" => quarry.tool_id
    }
  end

  # 锚点 micro 所在的 macro 格。
  defp anchor_cell(%{site: %{anchor_micro: micro}}) do
    {x, y, z} = VoxelRegion.Damage.macro(%{micro: List.to_tuple(micro)})
    %{"x0" => x, "y0" => y, "z0" => z, "x1" => x, "y1" => y, "z1" => z}
  end

  defp last?(blackboard, _observation, reason),
    do: match?(%{last_failure: %{reason: ^reason}}, blackboard)

  defp transient?(%{last_failure: %{reason: reason}}, _observation),
    do: reason in GateServer.Npc.Brain.Tree.transient()

  defp shortage?(blackboard, _observation), do: shortage(blackboard) != nil

  # 材料单 − 余额：按材料号取第一种缺料且配了采石盒的 → {材料, 缺额}；没有 → nil。
  defp shortage(%{bill: %{materials: bill}, balances: %{balances: rows}, quarries: quarries}) do
    have = Map.new(rows, &{&1.material, &1.balance})

    Enum.find_value(Enum.sort(bill), fn {material, need} ->
      short = need - Map.get(have, material, 0)
      if short > 0 and Map.has_key?(quarries, material), do: {material, short}
    end)
  end

  # 锚点格由自己放下：整格的 placed_by，或格内 micro 构件所属实例的 placed_by（prefab 只含 micro 格时宏格没有放置记录）。
  defp own_anchor?(%{anchor: %{probe_occupancy: [row]}}, %{self: %{entity_id: cid}}),
    do: row.placed_by == cid or Enum.any?(row.slots, &(Map.get(&1, :placed_by) == cid))
end
