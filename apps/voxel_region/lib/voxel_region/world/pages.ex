defmodule VoxelRegion.World.Pages do
  @moduledoc """
  全局系统功能（M2a 页表，`docs/10-active/voxel-authority/2026-10-24-world-region-paging/m2a-page-store.md`）：
  页的归属、页索引与脏单元判定。只派生，不持久，不是第二真值。

  **单元**（写回与抽取的最小粒度）：
  - `{:chunk, 段, 子块}`：L0 逐格段按 16³ 子块（`CollisionSource.chunk_coord/1`）——overlay、refined、attachments（按锚点宏格）、
    liquid_units、liquid_active、epochs、placed_by、macro_owners、sources、damage（g=0/1/4，按 `Damage.macro/1`）；
  - `{:page, 段, {level, region}}`：`:base`（`region_bases`）、`:coarse_overlay`（L1+ 稀疏格）、`:identity`（L0 页：home 在本页的实例、
    有主附件 id 与 g=2/3 属性行）。
  全局账每个切点整行写，不进脏集。

  **判脏**分三类，在线提交与启动回放同一规则：
  1. 唯一写入口登记：`Edits.put_overlay`、`Canonical.put_refined / put_attachments / drop_attachments / put_liquid / put_macro_owner`、
     `Log.rebase_region` 各自调用 `mark/2`（失败意图的 state 被丢弃，登记随之丢弃）；
  2. 事务自带的键（`remember/2`）：epochs、placed_by、property_states——日志回放本来就要求事务完整描述它们；
  3. 整表值与上次记住的值按引用比较（`remember/2`）：instances、attachment_owners、liquid_active、thermal.sources。
     `append_log` 只在日志副本里补入前两者与 liquid_active，在线事务不带，所以不按事务字段判（评审 R1）。
  """
  alias VoxelRegion.{CollisionSource, Damage, LogProjection, Prefab}
  import VoxelRegion.World.Canonical, only: [region_of: 1]

  @remembered [:instances, :attachment_owners, :liquid_active, :sources]

  @doc "空索引：World 构造时放入；回放经 `remember/2` 增量建满。"
  def new, do: %{damage_home: %{}, unit_damage: %{}, instance_home: %{}, home_instances: %{}, aid_home: %{}, home_aids: %{},
    remembered: Map.new(@remembered, &{&1, nil})}

  @doc "登记一个脏单元（写入口调用）。缺 `page_dirty` 的局部 state（单测夹具）也可用。"
  def mark(state, unit), do: Map.update(state, :page_dirty, MapSet.new([unit]), &MapSet.put(&1, unit))

  @doc "宏格所在逐格段子块。"
  def cell_unit(segment, cell), do: {:chunk, segment, CollisionSource.chunk_coord(cell)}

  @doc "附件槽归锚点宏格的子块（`attachments.ex:34`：事实归 anchor 所在 core）。"
  def slot_unit(slot), do: cell_unit(:attachments, elem(Prefab.macro_slot(elem(slot, 2)), 0))

  @doc "某级稀疏格的单元：L0 进逐格子块，L1+ 进该级页。"
  def overlay_unit(0, cell), do: cell_unit(:overlay, cell)
  def overlay_unit(level, cell), do: {:page, :coarse_overlay, {level, region_of(cell)}}

  @doc "实例的 home：anchor（微格）所在宏格的 L0 区域。"
  def instance_home(%{anchor: anchor}), do: region_of(elem(Prefab.macro_slot(anchor), 0))

  @doc """
  一笔已成功提交（或回放）的事务之后：按事务键与整表比较登记脏单元，维护页索引。`state` 是提交后的状态。
  """
  def remember(state, txn) do
    index = state.pages
    dirty = Map.get(state, :page_dirty, MapSet.new())
    dirty = Enum.reduce(Map.keys(Map.get(txn, :epochs, %{})), dirty, &MapSet.put(&2, cell_unit(:epochs, &1)))
    dirty = Enum.reduce(Map.keys(Map.get(txn, :placed_by, %{})), dirty, &MapSet.put(&2, cell_unit(:placed_by, &1)))

    # 整表：实例与附件归属先于属性行，g=2/3 行的 home 读更新后的归属。
    {index, dirty} = instances(index, dirty, state.instances)
    {index, dirty} = aids(index, dirty, state.attachment_owners)
    {index, dirty} = cells(index, dirty, :liquid_active, state.liquid_active, &MapSet.to_list/1)
    sources = if state.thermal, do: state.thermal.sources, else: %{}
    {index, dirty} = cells(index, dirty, :sources, sources, &Map.keys/1)

    {index, dirty} =
      Enum.reduce(Map.get(txn, :property_states, []), {index, dirty}, fn t, acc ->
        damage(acc, Damage.key(t), Map.get(state.damage, Damage.key(t)))
      end)

    %{state | pages: index, page_dirty: dirty}
  end

  defp instances(%{remembered: %{instances: same}} = index, dirty, same), do: {index, dirty}

  defp instances(index, dirty, now) do
    old = index.remembered.instances || %{}
    changed = for {id, _} <- Map.merge(old, now), Map.get(old, id) != Map.get(now, id), do: id

    {homes, members, dirty} =
      Enum.reduce(changed, {index.instance_home, index.home_instances, dirty}, fn id, {homes, members, dirty} ->
        {homes, members, dirty} = unhome(homes, members, dirty, id)

        case Map.fetch(now, id) do
          {:ok, instance} -> home(homes, members, dirty, id, instance_home(instance))
          :error -> {homes, members, dirty}
        end
      end)

    {%{index | instance_home: homes, home_instances: members, remembered: %{index.remembered | instances: now}}, dirty}
  end

  # 有主附件 id 的 home = owner 实例的 home（m2a §3，对父稿 P1 的修订）。
  defp aids(%{remembered: %{attachment_owners: same}} = index, dirty, same), do: {index, dirty}

  defp aids(index, dirty, now) do
    old = index.remembered.attachment_owners || %{}
    changed = for {aid, _} <- Map.merge(old, now), Map.get(old, aid) != Map.get(now, aid), do: aid

    {homes, members, dirty} =
      Enum.reduce(changed, {index.aid_home, index.home_aids, dirty}, fn aid, {homes, members, dirty} ->
        {homes, members, dirty} = unhome(homes, members, dirty, aid)

        case Map.fetch(now, aid) do
          {:ok, {owner, _}} -> home(homes, members, dirty, aid, Map.fetch!(index.instance_home, owner))
          :error -> {homes, members, dirty}
        end
      end)

    {%{index | aid_home: homes, home_aids: members, remembered: %{index.remembered | attachment_owners: now}}, dirty}
  end

  defp unhome(homes, members, dirty, id) do
    case Map.pop(homes, id) do
      {nil, homes} -> {homes, members, dirty}
      {region, homes} -> {homes, drop_member(members, region, id), MapSet.put(dirty, {:page, :identity, {0, region}})}
    end
  end

  defp home(homes, members, dirty, id, region),
    do: {Map.put(homes, id, region), Map.update(members, region, MapSet.new([id]), &MapSet.put(&1, id)),
      MapSet.put(dirty, {:page, :identity, {0, region}})}

  defp drop_member(members, key, id) do
    rest = MapSet.delete(Map.fetch!(members, key), id)
    if MapSet.size(rest) == 0, do: Map.delete(members, key), else: Map.put(members, key, rest)
  end

  # 逐格整值（活动液体、热源）：与上次记住的值不同的格所在子块。
  defp cells(index, dirty, key, now, keys) do
    case Map.fetch!(index.remembered, key) do
      ^now ->
        {index, dirty}

      old ->
        old_keys = if old == nil, do: [], else: keys.(old)
        changed = for cell <- Enum.uniq(old_keys ++ keys.(now)), member(old, cell) != member(now, cell), do: cell
        {%{index | remembered: Map.put(index.remembered, key, now)},
          Enum.reduce(changed, dirty, &MapSet.put(&2, cell_unit(key, &1)))}
    end
  end

  defp member(nil, _cell), do: nil
  defp member(%MapSet{} = set, cell), do: MapSet.member?(set, cell)
  defp member(map, cell), do: Map.get(map, cell)

  # 属性行：新旧单元都登记（g=2/3 的 micro 随命中改变，旧单元只能从索引读，不从 before 推）。
  defp damage({index, dirty}, key, row) do
    {old, homes} = Map.pop(index.damage_home, key)
    members = if old, do: drop_member(index.unit_damage, old, key), else: index.unit_damage
    dirty = if old, do: MapSet.put(dirty, old), else: dirty

    if row == nil do
      {%{index | damage_home: homes, unit_damage: members}, dirty}
    else
      unit = damage_unit(index, row)
      {%{index | damage_home: Map.put(homes, key, unit), unit_damage: Map.update(members, unit, MapSet.new([key]), &MapSet.put(&1, key))},
        MapSet.put(dirty, unit)}
    end
  end

  @doc "属性行的单元：g=0/1/4 按所在宏格子块；g=2 按部件 owner 的 home；g=3 有主按 owner 的 home、无主按槽所在页（同一附件的槽都在一个宏格内）。"
  def damage_unit(_index, %{granularity: g} = row) when g in [0, 1, 4], do: cell_unit(:damage, Damage.macro(row))
  def damage_unit(index, %{granularity: 2, owner: owner}), do: {:page, :identity, {0, Map.fetch!(index.instance_home, owner)}}

  def damage_unit(index, %{granularity: 3, incarnation: aid} = row),
    do: {:page, :identity, {0, Map.get_lazy(index.aid_home, aid, fn -> region_of(Damage.macro(row)) end)}}

  # ---- 抽取（写回与测试共用）：只读给定 state（切点冻结的引用），单元的值 O(单元内容)。

  @doc "单元当前的值（空单元为空 map / 空集合）。"
  def extract(state, {:chunk, segment, chunk}) do
    region = chunk_region(chunk)
    in_chunk = fn cell -> CollisionSource.chunk_coord(cell) == chunk end

    case segment do
      :overlay ->
        for {_, cell} = key <- Map.get(state.overlay_regions, {0, region}, MapSet.new()) |> Enum.map(&{0, &1}),
            in_chunk.(cell), {:ok, value} <- [Map.fetch(state.overlay, key)], into: %{}, do: {cell, value}

      :refined -> sub(state.refined_regions, region, in_chunk)
      :liquid_units -> sub(state.liquid_regions, region, in_chunk)
      :macro_owners -> sub(state.macro_owner_regions, region, in_chunk)
      :attachments -> for {slot, value} <- Map.get(state.attachment_regions, region, %{}), slot_unit(slot) == {:chunk, :attachments, chunk}, into: %{}, do: {slot, value}
      :liquid_active -> MapSet.filter(state.liquid_active, in_chunk)
      :sources -> if state.thermal, do: Map.filter(state.thermal.sources, fn {cell, _} -> in_chunk.(cell) end), else: %{}
      :epochs -> Map.get(state.epochs, chunk, %{})
      :placed_by -> Map.get(state.placed_by, chunk, %{})
      :damage -> Map.take(state.damage, MapSet.to_list(Map.get(state.pages.unit_damage, {:chunk, :damage, chunk}, MapSet.new())))
    end
  end

  def extract(state, {:page, :base, key}), do: Map.get(state.region_bases, key)

  def extract(state, {:page, :coarse_overlay, {level, region} = key}),
    do: for(cell <- Map.get(state.overlay_regions, key, MapSet.new()), region_of(cell) == region,
      {:ok, value} <- [Map.fetch(state.overlay, {level, cell})], into: %{}, do: {cell, value})

  def extract(state, {:page, :identity, {0, region}} = unit) do
    %{instances: Map.take(state.instances, MapSet.to_list(Map.get(state.pages.home_instances, region, MapSet.new()))),
      attachment_owners: Map.take(state.attachment_owners, MapSet.to_list(Map.get(state.pages.home_aids, region, MapSet.new()))),
      damage: Map.take(state.damage, MapSet.to_list(Map.get(state.pages.unit_damage, unit, MapSet.new())))}
  end

  defp sub(index, region, in_chunk), do: index |> Map.get(region, %{}) |> Map.filter(fn {cell, _} -> in_chunk.(cell) end)

  defp chunk_region({x, y, z}), do: {Integer.floor_div(x, 4), Integer.floor_div(y, 4), Integer.floor_div(z, 4)}

  @doc """
  state 里全部非空单元（全量枚举：迁移时“全部页标脏”与测试判定器用；O(世界)，不在提交路径上）。
  """
  def units(state) do
    l0 = fn segment, cells -> Enum.map(cells, &cell_unit(segment, &1)) end

    [
      for({0, cell} <- Map.keys(state.overlay), do: cell_unit(:overlay, cell)),
      for({level, cell} <- Map.keys(state.overlay), level > 0, do: overlay_unit(level, cell)),
      l0.(:refined, Map.keys(state.refined)),
      l0.(:liquid_units, Map.keys(state.liquid_units)),
      l0.(:macro_owners, Map.keys(state.macro_owners)),
      Enum.map(Map.keys(state.attachments), &slot_unit/1),
      l0.(:liquid_active, MapSet.to_list(state.liquid_active)),
      l0.(:sources, if(state.thermal, do: Map.keys(state.thermal.sources), else: [])),
      for({chunk, _} <- state.epochs, do: {:chunk, :epochs, chunk}),
      for({chunk, _} <- state.placed_by, do: {:chunk, :placed_by, chunk}),
      Map.keys(state.pages.unit_damage),
      for({region, _} <- state.pages.home_instances, do: {:page, :identity, {0, region}}),
      for({region, _} <- state.pages.home_aids, do: {:page, :identity, {0, region}}),
      for(key <- Map.keys(state.region_bases), do: {:page, :base, key})
    ]
    |> Enum.concat()
    |> MapSet.new()
  end

  @doc "攒下的脏单元。"
  def dirty(state), do: Map.get(state, :page_dirty, MapSet.new())

  # ---- 存储行（段编码的唯一定义；后端只存取行）

  @segment_codes %{overlay: 1, refined: 2, attachments: 3, liquid_units: 4, liquid_active: 5, epochs: 6, placed_by: 7,
    macro_owners: 8, sources: 9, damage: 10, base: 20, coarse_overlay: 21, identity: 22}
  @segments Map.new(@segment_codes, fn {k, v} -> {v, k} end)

  # 全局账：每个切点一行（m2a §3）；thermal 去掉逐格的 sources（进页）。
  @globals [:seq, :material_balances, :caster_energy, :material_supplies, :craft_ledger, :food_ledger, :food_receipts,
    :beacons, :beacon_attunements, :phase_inventory, :attachment_serial, :material_units_per_micro, :interaction_history, :interaction_floor]

  @doc "单元与值 → 存储行（`term_to_binary` 压缩；空值也写，表示该单元已清空，不以缺行表示）。"
  def row({:chunk, segment, chunk} = _unit, value),
    do: %{level: 0, region: chunk_region(chunk), segment: Map.fetch!(@segment_codes, segment), chunk: chunk, payload: encode(value)}

  def row({:page, segment, {level, region}}, value),
    do: %{level: level, region: region, segment: Map.fetch!(@segment_codes, segment), chunk: {0, 0, 0}, payload: encode(value)}

  @doc "存储行 → `{单元, 值}`。"
  def unit_value(%{level: level, region: region, segment: code, chunk: chunk, payload: payload}) do
    unit =
      case Map.fetch!(@segments, code) do
        segment when code < 20 -> {:chunk, segment, chunk}
        segment -> {:page, segment, {level, region}}
      end

    {unit, decode(payload)}
  end

  @doc "切点冻结的持久字段引用（同进程零拷贝；不钉住订阅、保留历史与任务，评审 A4.1）。"
  def frozen(state),
    do: Map.take(state, [:overlay, :overlay_regions, :refined_regions, :liquid_regions, :macro_owner_regions, :attachment_regions,
      :liquid_active, :thermal, :epochs, :placed_by, :damage, :pages, :region_bases, :instances, :attachment_owners, :protection | @globals])

  @doc "冻结状态的全局账行。"
  def globals(state) do
    encode(state |> Map.take(@globals) |> Map.put(:protection, state.protection.regions)
      |> Map.put(:thermal, state.thermal && Map.delete(state.thermal, :sources)))
  end

  defp encode(value), do: :erlang.term_to_binary(%{format: 1, value: value}, compressed: 6)
  defp decode(bytes), do: VoxelRegion.OverlayLog.term(bytes).value

  @doc """
  唯一装页入口（m2a §6.2）：全局行与各段经各自的写入口装入，按段恢复 `snapshots`（R2：有基底或细节的区域不能再按 baseline 服务），
  不走日志回放的实例合并与存活过滤。装完从全量状态重建页索引，清空脏集（装入的内容已持久）。
  """
  def install(state, %{segments: rows, globals: globals}) do
    g = decode(globals)

    state =
      %{Map.merge(state, Map.take(g, @globals)) |
        protection: VoxelRegion.Protection.apply(state.protection, g.protection),
        thermal: g.thermal && Map.put(g.thermal, :sources, %{})}

    state = rows |> Enum.map(&unit_value/1) |> Enum.reduce(state, fn {unit, value}, s -> put_unit(s, unit, value) end)
    rebuild(state)
  end

  defp put_unit(s, _unit, nil), do: s
  defp put_unit(s, {:chunk, :overlay, _}, cells), do: Enum.reduce(cells, s, fn {cell, v}, s -> VoxelRegion.World.Edits.put_overlay(s, 0, cell, v) end)
  defp put_unit(s, {:page, :coarse_overlay, {level, _}}, cells), do: Enum.reduce(cells, s, fn {cell, v}, s -> VoxelRegion.World.Edits.put_overlay(s, level, cell, v) end)
  defp put_unit(s, {:chunk, :refined, _}, cells), do: cells |> Enum.reduce(s, fn {cell, slots}, s -> VoxelRegion.World.Canonical.put_refined(s, cell, slots) end) |> snapshot(Map.keys(cells))
  defp put_unit(s, {:chunk, :attachments, _}, slots), do: s |> VoxelRegion.World.Canonical.put_attachments(slots) |> snapshot(VoxelRegion.Attachments.macros(Map.keys(slots)))
  defp put_unit(s, {:chunk, :liquid_units, _}, cells), do: s |> VoxelRegion.World.Canonical.put_liquid(cells) |> snapshot(Map.keys(cells))
  defp put_unit(s, {:chunk, :macro_owners, _}, cells), do: cells |> Enum.reduce(s, fn {cell, o}, s -> VoxelRegion.World.Canonical.put_macro_owner(s, cell, o) end) |> snapshot(Map.keys(cells))
  defp put_unit(s, {:chunk, :liquid_active, _}, cells), do: %{s | liquid_active: MapSet.union(s.liquid_active, cells)}
  defp put_unit(s, {:chunk, :sources, _}, cells), do: %{s | thermal: %{s.thermal | sources: Map.merge(s.thermal.sources, cells)}}
  defp put_unit(s, {:chunk, :epochs, chunk}, cells) when map_size(cells) > 0, do: %{s | epochs: Map.put(s.epochs, chunk, cells)}
  defp put_unit(s, {:chunk, :placed_by, chunk}, cells) when map_size(cells) > 0, do: %{s | placed_by: Map.put(s.placed_by, chunk, cells)}
  defp put_unit(s, {:chunk, segment, _}, _empty) when segment in [:epochs, :placed_by], do: s
  defp put_unit(s, {:chunk, :damage, _}, rows), do: %{s | damage: Map.merge(s.damage, rows)}

  defp put_unit(s, {:page, :identity, _}, v),
    do: %{s | instances: Map.merge(s.instances, v.instances), attachment_owners: Map.merge(s.attachment_owners, v.attachment_owners),
      damage: Map.merge(s.damage, v.damage)}

  # 地形基底与旧检查点换基底同一语义（`Log.rebase_region/2`）：进 `region_bases`、记为完整快照、丢源解码与缓存。
  defp put_unit(s, {:page, :base, key}, base),
    do: %{VoxelRegion.World.Payloads.cache_delete(s, key) | region_bases: Map.put(s.region_bases, key, base),
      snapshots: MapSet.put(s.snapshots, key), decoded: Map.delete(s.decoded, key)}

  # 有细节的格所在及以其为 ring 的 L0 区域都按完整快照物化（与回放区域后像、液体数量增量同一规则）。
  defp snapshot(s, cells),
    do: %{s | snapshots: Enum.into(LogProjection.region_keys(Enum.map(cells, &{0, &1})), s.snapshots)}

  @doc "从全量状态重建页索引并清空脏集（装页与迁移后；O(世界)，只在启动）。"
  def rebuild(state) do
    state = remember(%{state | pages: new()}, %{property_states: Map.values(state.damage)})
    %{state | page_dirty: MapSet.new()}
  end
end
