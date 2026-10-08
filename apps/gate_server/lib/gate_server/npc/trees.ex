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
        tools: %{t => 说明}, skills: %{build: %{}, gather: %{}}}

  每轮：`read_catalog what: "prefab"` 取材料单，按顺序走每个工地：到站位 → `build`；建成即这个工地完成。
  `build` 回 `insufficient_material` → `query_balances` → 取第一种缺料且配了采石盒的材料，`gather` 缺额
  （units = 材料单 − 余额）→ 回站位 → 再 `build` 一次。`build` 回 `occupied` → `look` 锚点格：整格或格内构件实例的 `placed_by` 是自己 →
  视为已建成，否则跳过。其余拒绝（protected_region、out_of_reach、no_path、stuck、out_of_bounds、exhausted、
  unreachable…）这个工地本轮放弃，换下一个。一轮巡完等 `revisit_ticks` 再巡。

  | 规则 | 内容 |
  |---|---|
  | 次数上限 | 每次尝试最多 gather 一次、build 重试一次；每工地每轮最多两次尝试（树结构保证，无循环） |
  | 瞬态原因 | `invalid_session` / `dead` / `session_lost`（`Brain.Tree.transient/0`）：工地内任一步遇到，60 tick（1 秒）后从站位整体重来一次——复活与重新 claim 后身体在出生点，缺额由 `query_balances` 重算，不原样重发旧命令；再遇瞬态原因本工地本轮放弃。只有 `read_catalog`（只读、与位置无关）带 `retry: 60` 原样重发 |
  | 停因日志 | 工地放弃记一行 `npc_settler_idle entity= act= reason= context=<工地>`；材料单取不到（`definition_not_found`）本轮放弃，记 `npc_settler_idle entity= act=read_catalog reason=…`，休息后再试 |
  | 进度 | 不存档，以权威为准：重启后从头巡，已建好的工地表现为 occupied → 自家锚点 → 跳过，不重复建 |

  作者保证：定义（宏格或 micro 构件均可）占着锚点格（`anchor_micro` 所在的 macro 格，否则 occupied 时认不出是自家）；各站位与采石盒站位
  两两水平距离不超过 `Perception.reach()`（不做分段与长途寻路）；站位离锚点格在工具射程内。被占一律跳过、不清场。
  """

  # 瞬态原因之后等 1 秒（60 tick）。
  @pause 60

  @doc "Settler 树与黑板初值（`definition`、`sites`、`quarries`）；形状见 moduledoc。"
  def settler(profile) do
    stand = {:act, "move_to", &stand_args/1}
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

    round =
      {:seq,
       [
         {:act, "read_catalog", %{"what" => "prefab", "definition" => profile.definition},
          store: :bill, retry: @pause},
         {:each, :sites, :site, {:succeed, site, log: "npc_settler_idle", context: :site}}
       ]}

    tree =
      {:repeat, :forever,
       {:seq, [{:succeed, round, log: "npc_settler_idle"}, {:wait, profile.revisit_ticks}]}}

    {tree,
     %{
       definition: profile.definition,
       sites: profile.sites,
       quarries: Map.get(profile, :quarries, %{})
     }}
  end

  defp stand_args(%{site: %{stand: [x, z]}}), do: %{"x" => x, "z" => z, "y" => nil}

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
