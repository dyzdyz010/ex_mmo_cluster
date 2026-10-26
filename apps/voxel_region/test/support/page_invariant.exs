defmodule VoxelRegion.TestSupport.PageInvariant do
  @moduledoc """
  只测试：M2a 脏单元覆盖全部改动（`m2a-page-store.md` §8 第 7 项）。

  从 World 状态的原始字段独立按单元分组（不调用 `World.Pages` 的索引、枚举或抽取），比较两个时刻，凡内容变了的单元必须在
  `page_dirty` 里。单元定义与归属规则按设计稿 §3：L0 逐格段按 16³ 子块（向负无穷取整）；g=2/3 行与实例、有主附件 id 按实例
  anchor 所在 L0 区域；无主附件的 g=3 行按行的宏格所在区域；base 与 L1+ 稀疏格按页。
  """

  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "某时刻的按单元分组内容。"
  def snapshot(world), do: group(:sys.get_state(world))

  @doc "自 `before` 以来内容变了却不在脏集里的单元。"
  def missed(world, before) do
    state = :sys.get_state(world)
    now = group(state)
    dirty = state.page_dirty

    for unit <- Enum.uniq(Map.keys(before) ++ Map.keys(now)),
        Map.get(before, unit) != Map.get(now, unit),
        not MapSet.member?(dirty, unit),
        do: unit
  end

  defp group(s) do
    flat = fn nested -> for {_, cells} <- nested, kv <- cells, into: %{}, do: kv end
    homes = Map.new(s.instances, fn {id, i} -> {id, region(macro(i.anchor))} end)
    aid_home = Map.new(s.attachment_owners, fn {aid, {owner, _}} -> {aid, Map.fetch!(homes, owner)} end)

    identity = fn region -> {:page, :identity, {0, region}} end

    damage_unit = fn
      %{granularity: g} = t when g in [0, 1, 4] -> {:chunk, :damage, chunk(macro(t.micro))}
      %{granularity: 2, owner: owner} -> identity.(Map.fetch!(homes, owner))
      %{granularity: 3, incarnation: aid} = t -> identity.(Map.get(aid_home, aid, region(macro(t.micro))))
    end

    entries =
      Enum.concat([
        for({{0, cell}, v} <- s.overlay, do: {{:chunk, :overlay, chunk(cell)}, {cell, v}}),
        for({{l, cell}, v} <- s.overlay, l > 0, do: {{:page, :coarse_overlay, {l, region(cell)}}, {cell, v}}),
        for({cell, v} <- s.refined, do: {{:chunk, :refined, chunk(cell)}, {cell, v}}),
        for({cell, v} <- s.liquid_units, do: {{:chunk, :liquid_units, chunk(cell)}, {cell, v}}),
        for({cell, v} <- s.macro_owners, do: {{:chunk, :macro_owners, chunk(cell)}, {cell, v}}),
        for({{_, _, p} = slot, v} <- s.attachments, do: {{:chunk, :attachments, chunk(macro(p))}, {slot, v}}),
        for(cell <- s.liquid_active, do: {{:chunk, :liquid_active, chunk(cell)}, {cell, true}}),
        for({cell, v} <- (if s.thermal, do: s.thermal.sources, else: %{}), do: {{:chunk, :sources, chunk(cell)}, {cell, v}}),
        for({cell, v} <- flat.(s.epochs), do: {{:chunk, :epochs, chunk(cell)}, {cell, v}}),
        for({cell, v} <- flat.(s.placed_by), do: {{:chunk, :placed_by, chunk(cell)}, {cell, v}}),
        for({key, t} <- s.damage, do: {damage_unit.(t), {key, t}}),
        for({id, i} <- s.instances, do: {identity.(Map.fetch!(homes, id)), {{:instance, id}, i}}),
        for({aid, v} <- s.attachment_owners, do: {identity.(Map.fetch!(aid_home, aid)), {{:aid, aid}, v}}),
        for({key, p} <- s.region_bases, do: {{:page, :base, key}, {:base, p}})
      ])

    Enum.reduce(entries, %{}, fn {unit, {k, v}}, acc -> Map.update(acc, unit, %{k => v}, &Map.put(&1, k, v)) end)
  end

  defp macro({x, y, z}), do: {Integer.floor_div(x, @micro), Integer.floor_div(y, @micro), Integer.floor_div(z, @micro)}
  defp chunk({x, y, z}), do: {Integer.floor_div(x, 16), Integer.floor_div(y, 16), Integer.floor_div(z, 16)}
  defp region({x, y, z}), do: {Integer.floor_div(x, 64), Integer.floor_div(y, 64), Integer.floor_div(z, 64)}
end
