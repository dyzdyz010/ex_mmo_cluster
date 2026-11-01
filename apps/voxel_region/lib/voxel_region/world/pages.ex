defmodule VoxelRegion.World.Pages do
  alias VoxelRegion.RefinedSlots
  @moduledoc """
  全局系统功能（M2a 页表 + M2b 按需装页，`docs/10-active/voxel-authority/2026-10-24-world-region-paging/m2a-page-store.md`、
  `m2b-on-demand-pages.md`）：页的归属、页索引、脏单元判定与装页接纳。只派生，不持久，不是第二真值。

  **单元**（写回与抽取的最小粒度）：
  - `{:chunk, 段, 子块}`：L0 逐格段按 16³ 子块（`CollisionSource.chunk_coord/1`）——overlay、refined、attachments（按锚点宏格）、
    liquid_units、liquid_active、epochs、placed_by、macro_owners、sources、damage（g=0/1/4，按 `Damage.macro/1`）；
  - `{:page, 段, {level, region}}`：`:base`（`region_bases`）、`:coarse_overlay`（L1+ 稀疏格）、`:identity`（L0 页：home 在本页的实例、
    有主附件 id 与 g=2/3 属性行）、`:covers`（M2b：home 在本页的根实例的整树覆盖页集合）、`:activity`（M2b：本页是否有进行中的过程）；
  - `{:fragment, 段, {level, L0 页}}`（M2b，拆分稿 §5 e 的 `(level, L0 页)` 行键）：`:structure`（L1–L5 structure 中格落在该 L0 页的项）、
    `:canopy`（该 L0 页的树冠片段，`Canopy.fragments/2`）；
  - `{:locator, {kind, a, b}}`（M2b）：身份定位行（实例 kind 1、有主附件 kind 2 → 根与根 home），只插入。
  全局账每个切点整行写，不进脏集。

  **判脏**分三类，在线提交与启动回放同一规则：
  1. 唯一写入口登记：`Edits.put_overlay`、`Canonical.put_refined / put_attachments / drop_attachments / put_liquid / put_macro_owner / put_structure`、
     `Log.rebase_region`、`Canopy.refresh` 各自调用 `mark/2`（失败意图的 state 被丢弃，登记随之丢弃）；
  2. 事务自带的键（`remember/2`）：epochs、placed_by、property_states——日志回放本来就要求事务完整描述它们；
  3. 整表值与上次记住的值按引用比较（`remember/2`）：instances、attachment_owners、liquid_active、thermal.sources。
     `append_log` 只在日志副本里写实例 / 归属增量，在线事务不带，所以不按事务字段判（评审 R1）。
  覆盖页集合由写入口登记的“碰过的身份”（`touch/2`）在 `remember/2` 里按根重算，变了才判脏；活动单元在开切点时按本批涉及的页补入（`with_activity/1`）。

  **装页**（M2b `adopt/4`）：接纳的页经同一写入口装入、恢复 `snapshots`、增量补页索引与 `remembered`，不判脏；
  再按“驻留闭合”（实例树完整）给出后续要装的页与要定位的身份。
  """
  alias VoxelRegion.{Attachments, CollisionSource, Combustion, Damage, LogProjection, Prefab, ThermalWork}
  alias VoxelRegion.World.{Canonical, Edits, Payloads}
  import VoxelRegion.World.Canonical, only: [region_of: 1]
  import Bitwise

  @remembered [:instances, :attachment_owners, :liquid_active, :sources]
  @max_level 5

  @doc "空索引：World 构造时放入；回放经 `remember/2` 增量建满。"
  def new, do: %{damage_home: %{}, unit_damage: %{}, instance_home: %{}, home_instances: %{}, aid_home: %{}, home_aids: %{},
    children: %{}, covers: %{}, remembered: Map.new(@remembered, &{&1, nil})}

  @doc "登记一个脏单元（写入口调用）。缺 `page_dirty` 的局部 state（单测夹具）也可用。"
  def mark(state, unit), do: Map.update(state, :page_dirty, MapSet.new([unit]), &MapSet.put(&1, unit))

  @doc """
  登记本笔写到的 L0 宏格：授权写集，提交时由 `VoxelRegion.Access.authorize_writes/3` 判定。
  与 `mark/2` 由同一批写入口调用；每笔提交后清空（`Log.remember_entry/2`），装页接纳不算写（`install/3` 恢复原值）。
  """
  def wrote(state, cell), do: Map.update(state, :written, MapSet.new([cell]), &MapSet.put(&1, cell))

  @doc "登记本笔碰过的身份（实例 id 或 `{:aid, aid}`）：`remember/2` 按根重算覆盖页集合。"
  def touch(state, id), do: Map.update(state, :owners_touched, MapSet.new([id]), &MapSet.put(&1, id))

  @doc "宏格所在逐格段子块。"
  def cell_unit(segment, cell), do: {:chunk, segment, CollisionSource.chunk_coord(cell)}

  @doc "附件槽归锚点宏格的子块（`attachments.ex:34`：事实归 anchor 所在 core）。"
  def slot_unit(slot), do: cell_unit(:attachments, slot_cell(slot))

  @doc "附件槽的锚点宏格。"
  def slot_cell(slot), do: elem(Prefab.macro_slot(elem(slot, 2)), 0)

  @doc "某级稀疏格的单元：L0 进逐格子块，L1+ 进该级页。"
  def overlay_unit(0, cell), do: cell_unit(:overlay, cell)
  def overlay_unit(level, cell), do: {:page, :coarse_overlay, {level, region_of(cell)}}

  @doc "L1–L5 一格（该级坐标）所在的 L0 页：粗层片段的行键 `(level, L0 页)`。"
  def fragment_page(level, {x, y, z}), do: region_of({x <<< level, y <<< level, z <<< level})

  @doc "L0 页在 `level` 级所属的粗层页区域。"
  def coarse_region(level, {x, y, z}), do: {x >>> level, y >>> level, z >>> level}

  @doc "structure 项 `{level, cell}` 的片段单元。"
  def structure_unit({level, cell}), do: {:fragment, :structure, {level, fragment_page(level, cell)}}

  @doc "实例的 home：anchor（微格）所在宏格的 L0 区域。"
  def instance_home(%{anchor: anchor}), do: region_of(elem(Prefab.macro_slot(anchor), 0))

  @doc "定位行的身份键：实例 `{1, birth, occurrence}`，附件 `{2, aid, 0}`。"
  def locator_key({:aid, aid}), do: {2, aid, 0}
  def locator_key({birth, occurrence}), do: {1, birth, occurrence}

  # ---- 驻留（M2b）

  @doc "页是否驻留（`:all` = 内存即全部真值）。"
  def resident?(%{resident: :all}, _key), do: true
  def resident?(%{resident: resident}, key), do: MapSet.member?(resident, key)

  @doc "粗层片段 `(level, L0 页)` 是否驻留：L0 页或该级粗层页之一驻留。"
  def fragment_resident?(state, level, page), do: resident?(state, {0, page}) or resident?(state, {level, coarse_region(level, page)})

  @doc "L0 区域键连同它们在 L1–L5 的粗层祖页（与 `Edits.edit_keys/1` 同一归属）：会做几何提交的入口，逐级归约读写这些粗层页。"
  def with_ancestors(keys),
    do: Enum.uniq(for({0, page} = key <- keys, level <- 0..@max_level, do: if(level == 0, do: key, else: {level, coarse_region(level, page)})) ++
      Enum.reject(keys, &match?({0, _}, &1)))

  @doc """
  身份在内存且所在实例树闭合（父链到根都在、根的覆盖页都已驻留）；附件 id 看其 owner。不闭合的（孤儿）仍要定位补根。
  """
  def tree_complete?(state, {:aid, aid}) do
    case Map.get(state.attachment_owners, aid) do
      {owner, _} -> tree_complete?(state, owner)
      nil -> false
    end
  end

  def tree_complete?(state, id) do
    case chain_root(state.instances, id) do
      nil -> false
      root -> Enum.all?(Map.get(state.pages.covers, root, MapSet.new()), &resident?(state, {0, &1}))
    end
  end

  @doc """
  装页任务按已读的 PG 行求树闭包（纯函数，任务进程里用）：`closure_add/2` 只并入本轮新读的单元（增量，评审后统筹第四轮），
  `closure_next/4` 给出还缺的 `{页, 身份}`。身份 = 页上引用的实例 / 附件 id 与已读实例的父 id，去掉已读到记录的与已问过的；
  页 = 定位到的根 home 与已读根记录的覆盖页，去掉已读的页。World 的 `need` 再滤掉内存里已闭合的身份与已驻留页。
  """
  def closure_new, do: %{records: MapSet.new(), aids: MapSet.new(), covers: MapSet.new(), referenced: MapSet.new()}

  def closure_add(c, units) do
    Enum.reduce(units, c, fn
      {{:page, :identity, _}, v}, c ->
        parents = for {_, record} <- v.instances, (p = Map.get(record, :parent_id, {0, 0})) != {0, 0}, do: p
        %{c | records: Enum.into(Map.keys(v.instances), c.records), aids: Enum.into(Map.keys(v.attachment_owners), c.aids),
          referenced: Enum.into(parents, c.referenced)}

      {{:page, :covers, _}, v}, c -> %{c | covers: Enum.reduce(v, c.covers, fn {_, pages}, acc -> MapSet.union(acc, pages) end)}
      {{:chunk, :refined, _}, cells}, c -> %{c | referenced: Enum.into(for({_, slots} <- cells, {_, {_, owner}} <- slots, do: owner), c.referenced)}
      {{:chunk, :macro_owners, _}, cells}, c -> %{c | referenced: Enum.into(Map.values(cells), c.referenced)}
      {{:chunk, :attachments, _}, slots}, c -> %{c | referenced: Enum.into(for({_, {aid, _}} <- slots, do: {:aid, aid}), c.referenced)}
      _, c -> c
    end)
  end

  def closure_next(c, located, have, asked) do
    ids = for id <- c.referenced, not known_in(c, id), not MapSet.member?(asked, id), do: id
    homes = for {_, %{home: home}} <- located, do: home
    pages = for page <- Enum.uniq(MapSet.to_list(c.covers) ++ homes), not MapSet.member?(have, {0, page}), do: {0, page}
    {pages, ids}
  end

  defp known_in(c, {:aid, aid}), do: MapSet.member?(c.aids, aid)
  defp known_in(c, id), do: MapSet.member?(c.records, id)

  @doc "同级 27 邻页（含自身）：区域载荷的 core 与 ring 读这些页。"
  def expand(keys) do
    for {level, {x, y, z}} <- keys, dx <- -1..1, dy <- -1..1, dz <- -1..1, uniq: true, do: {level, {x + dx, y + dy, z + dz}}
  end

  @doc "驻留需求按既有整树/附件归属闭合；未知身份显式失败，不能把半棵树当空。"
  def residency_closure(state, keys, ids), do: close_residency(state, MapSet.new(keys), MapSet.new(), ids)

  defp close_residency(state, keys, seen, ids) do
    fresh = MapSet.difference(keys, seen)
    referenced = for {0, page} <- fresh,
      id <- Enum.concat([MapSet.to_list(Map.get(state.pages.home_instances, page, MapSet.new())),
        Map.keys(Map.get(state.refined_region_owners, page, %{})),
        Map.values(Map.get(state.macro_owner_regions, page, %{})),
        for({_, {aid, _}} <- Map.get(state.attachment_regions, page, %{}), Map.has_key?(state.attachment_owners, aid), do: {:aid, aid})]), do: id

    roots = Enum.reduce_while(Enum.uniq(ids ++ referenced), {:ok, MapSet.new()}, fn id, {:ok, roots} ->
      instance = case id do {:aid, aid} -> case state.attachment_owners[aid] do {owner, _} -> owner; nil -> nil end; id -> id end
      case instance && chain_root(state.instances, instance) do
        nil -> {:halt, {:error, {:identity_not_resident, id}}}
        root -> {:cont, {:ok, MapSet.put(roots, root)}}
      end
    end)

    with {:ok, roots} <- roots do
      more = for root <- roots, page <- Map.get(state.pages.covers, root, MapSet.new()), do: {0, page}
      keys = Enum.into(more, keys)
      seen = MapSet.union(seen, fresh)
      if MapSet.subset?(keys, seen), do: {:ok, keys}, else: close_residency(state, keys, seen, [])
    end
  end

  @doc "脏/冻结单元对页的投影；共享粗层片段同时阻止两个表示owner退休。"
  def units_pages(state, units) do
    Enum.flat_map(units, fn
      {:chunk, _, chunk} -> [{0, chunk_region(chunk)}]
      {:page, _, key} -> [key]
      {:fragment, _, {level, page}} -> [{0, page}, {level, coarse_region(level, page)}]
      {:locator, _} = unit -> case extract(state, unit) do nil -> []; %{home: home} -> [{0, home}] end
    end)
    |> Enum.uniq()
  end

  @doc "全量迁移首次发布后的有限驻留页；只在:all转有限表示时枚举一次。"
  def loaded_keys(state) do
    units_pages(state, units(state)) ++ Map.keys(state.decoded) ++ MapSet.to_list(state.snapshots) ++
      Map.keys(state.served_headers) ++ Enum.map(Map.keys(state.liquid_adopted), &{0, &1})
    |> MapSet.new()
  end

  @doc "批量退休已证明可退的内存表示；不走业务删除、不判脏、不删除持久页或定位行。"
  def retire(state, keys) do
    resident = MapSet.difference(state.resident, keys)
    l0 = for {0, page} <- keys, into: MapSet.new(), do: page
    region_keys = MapSet.to_list(keys)
    cells = for page <- l0, cell <- Map.keys(Map.get(state.refined_regions, page, %{})), into: MapSet.new(), do: cell
    refined_ids = for page <- l0, owner <- Map.keys(Map.get(state.refined_region_owners, page, %{})), into: MapSet.new(), do: owner
    macros = for page <- l0, cell <- Map.keys(Map.get(state.macro_owner_regions, page, %{})), into: MapSet.new(), do: cell
    macro_ids = for page <- l0, owner <- Map.values(Map.get(state.macro_owner_regions, page, %{})), into: MapSet.new(), do: owner
    liquids = for page <- l0, cell <- Map.keys(Map.get(state.liquid_regions, page, %{})), do: cell
    slots = for page <- l0, slot <- Map.keys(Map.get(state.attachment_regions, page, %{})), do: slot
    slot_aids = for slot <- slots, {aid, _} = Map.fetch!(state.attachments, slot), into: MapSet.new(), do: aid
    instances = for page <- l0, id <- Map.get(state.pages.home_instances, page, MapSet.new()), do: id
    aids = for page <- l0, aid <- Map.get(state.pages.home_aids, page, MapSet.new()), do: aid
    # overlay_regions同时索引邻页ring；只退休core归本页的值，邻页索引仍由存活core拥有。
    overlay = for {level, page} = key <- keys, cell <- Map.get(state.overlay_regions, key, MapSet.new()), region_of(cell) == page, do: {level, cell}
    dropped_overlay = Enum.group_by(overlay, &elem(&1, 0), &elem(&1, 1)) |> Map.new(fn {level, cells} -> {level, MapSet.new(cells)} end)
    overlay_neighbors = overlay |> Enum.map(fn {level, cell} -> {level, region_of(cell)} end) |> Enum.uniq() |> expand()
    overlay_regions = Enum.reduce(Map.take(state.overlay_regions, overlay_neighbors), state.overlay_regions, fn {{level, _} = key, cells}, index ->
      remaining = MapSet.difference(cells, Map.get(dropped_overlay, level, MapSet.new()))
      if MapSet.size(remaining) == 0, do: Map.delete(index, key), else: Map.put(index, key, remaining)
    end)
    chunks = for {x, y, z} <- l0, dx <- 0..3, dy <- 0..3, dz <- 0..3, do: {x * 4 + dx, y * 4 + dy, z * 4 + dz}
    damage_units = (Enum.map(chunks, &{:chunk, :damage, &1}) ++ Enum.map(l0, &{:page, :identity, {0, &1}}))
      |> Enum.filter(&Map.has_key?(state.pages.unit_damage, &1))
    damage = for unit <- damage_units, id <- Map.fetch!(state.pages.unit_damage, unit), do: id
    owners = subtract_cells(state.refined_owners, cells, refined_ids)
    macro_owners = subtract_cells(state.macro_owner_cells, macros, macro_ids)
    aid_regions = Enum.reduce(slot_aids, state.aid_regions, fn aid, index ->
      remaining = Map.drop(Map.fetch!(index, aid), MapSet.to_list(l0))
      if map_size(remaining) == 0, do: Map.delete(index, aid), else: Map.put(index, aid, remaining)
    end)
    fragments = Map.keys(state.structure_pages) ++ Map.keys(state.canopy) |> Enum.uniq() |> Enum.filter(fn {level, page} ->
      not MapSet.member?(resident, {0, page}) and not MapSet.member?(resident, {level, coarse_region(level, page)})
    end)
    structure = for {level, _} = key <- fragments, cell <- Map.get(state.structure_pages, key, MapSet.new()), do: {level, cell}
    index = state.pages
    remembered = index.remembered
    index = %{index | instance_home: Map.drop(index.instance_home, instances), home_instances: Map.drop(index.home_instances, MapSet.to_list(l0)),
      aid_home: Map.drop(index.aid_home, aids), home_aids: Map.drop(index.home_aids, MapSet.to_list(l0)),
      children: Map.drop(index.children, instances), covers: Map.drop(index.covers, instances),
      damage_home: Map.drop(index.damage_home, damage), unit_damage: Map.drop(index.unit_damage, damage_units),
      remembered: %{remembered | instances: Map.drop(remembered.instances || %{}, instances),
        attachment_owners: Map.drop(remembered.attachment_owners || %{}, aids),
        liquid_active: MapSet.reject(remembered.liquid_active || MapSet.new(), &MapSet.member?(l0, region_of(&1))),
        sources: Map.reject(remembered.sources || %{}, fn {cell, _} -> MapSet.member?(l0, region_of(cell)) end)}}
    state = %{state | resident: resident,
      page_load: %{state.page_load | staged: MapSet.difference(state.page_load.staged, keys)},
      page_generation: Enum.reduce(keys, state.page_generation, &Map.update(&2, &1, 1, fn gen -> gen + 1 end)),
      decoded: Map.drop(state.decoded, region_keys), region_bases: Map.drop(state.region_bases, region_keys),
      snapshots: MapSet.difference(state.snapshots, keys), served_headers: Map.drop(state.served_headers, region_keys),
      liquid_adopted: Map.drop(state.liquid_adopted, MapSet.to_list(l0)),
      overlay: Map.drop(state.overlay, overlay), overlay_regions: overlay_regions,
      refined: Map.drop(state.refined, MapSet.to_list(cells)),
      refined_regions: Map.drop(state.refined_regions, MapSet.to_list(l0)), refined_owners: owners,
      refined_region_owners: Map.drop(state.refined_region_owners, MapSet.to_list(l0)),
      macro_owners: Map.drop(state.macro_owners, MapSet.to_list(macros)), macro_owner_cells: macro_owners,
      macro_owner_regions: Map.drop(state.macro_owner_regions, MapSet.to_list(l0)),
      liquid_units: Map.drop(state.liquid_units, liquids), liquid_regions: Map.drop(state.liquid_regions, MapSet.to_list(l0)),
      attachments: Map.drop(state.attachments, slots), attachment_regions: Map.drop(state.attachment_regions, MapSet.to_list(l0)),
      aid_regions: aid_regions,
      instances: Map.drop(state.instances, instances), attachment_owners: Map.drop(state.attachment_owners, aids),
      epochs: Map.drop(state.epochs, chunks), placed_by: Map.drop(state.placed_by, chunks), damage: Map.drop(state.damage, damage), pages: index,
      structure: Map.drop(state.structure, structure), structure_pages: Map.drop(state.structure_pages, fragments), canopy: Map.drop(state.canopy, fragments)}
    dead = Enum.reject(refined_ids, &Map.has_key?(owners, &1))
    state = Map.update(state, :component_cache, %{}, &Map.drop(&1, dead))
    state
  end

  defp subtract_cells(index, cells, owners) do
    Enum.reduce(owners, index, fn owner, index ->
      remaining = MapSet.difference(Map.fetch!(index, owner), cells)
      if MapSet.size(remaining) == 0, do: Map.delete(index, owner), else: Map.put(index, owner, remaining)
    end)
  end

  @doc """
  一笔事务的读写页（启动重放后缀前装入；按事务内容静态求出，不需当时的状态）：`{页键, 要定位的身份}`。
  后缀里新建身份的 home 由 anchor 直接得出；引用的旧身份查定位表。整表实例格式（M2a 之前的日志）不能在分页重放里出现。
  """
  def txn_needs(txn) do
    if Map.has_key?(txn, :prefab_instances) or Map.has_key?(txn, :attachment_owners) do
      raise "voxel page replay: seq #{txn.seq} carries a whole-table instance / attachment-owner map (pre-M2b log format); restore from the log dump and re-migrate"
    end

    l0 = fn cells -> Enum.map(cells, &{0, region_of(&1)}) end
    coarse = fn rows -> Enum.map(rows, &{&1.level, region_of(&1.cell)}) end

    # 旧单格入口的裸条目（文件后端原样存帧）本身就是一个 kind0 条目。
    entries = if Map.has_key?(txn, :entries), do: txn.entries, else: [txn]

    entry_keys =
      Enum.flat_map(entries, fn
        %{payload: bytes} ->
          {:ok, h} = MmoContracts.Voxel.Codec.decode_payload_header(bytes)
          [{h.level, h.region}]

        %{structure: _, level: level, cell: cell} -> [{level, region_of(cell)}]
        %{coord: cell} = entry -> [{0, region_of(cell)} | coarse.(Map.get(entry, :coarse, []))]
      end)

    rows = Map.get(txn, :property_states, [])
    deltas = Map.get(txn, :instances_delta, %{})
    owners = Map.get(txn, :attachment_owners_delta, %{})

    keys =
      Enum.concat([
        entry_keys,
        coarse.(Map.get(txn, :coarse, [])),
        l0.(Map.keys(Map.get(txn, :liquid_units, %{}))),
        l0.(for(%{granularity: g} = t <- rows, g in [0, 1, 3, 4], do: Damage.macro(t))),
        l0.(Map.keys(Map.get(txn, :epochs, %{}))),
        l0.(Map.keys(Map.get(txn, :placed_by, %{}))),
        l0.(Map.keys(Map.get(txn, :macro_owners, %{}))),
        l0.(Map.get(txn, :liquid_active, [])),
        l0.(if(thermal = Map.get(txn, :thermal), do: Map.keys(thermal.sources), else: [])),
        for({_, %{} = i} <- deltas, do: {0, instance_home(i)})
      ])

    ids =
      Enum.concat([
        for(%{granularity: 2, owner: owner} <- rows, do: owner),
        for(%{granularity: 3, incarnation: aid} <- rows, do: {:aid, aid}),
        for({_, owner} <- Map.get(txn, :macro_owners, %{}), owner != nil, do: owner),
        for({id, i} <- deltas, id <- [id | if(i, do: [Map.get(i, :parent_id, {0, 0})], else: [])], id != {0, 0}, do: id),
        for({aid, v} <- owners, id <- [{:aid, aid} | if(v, do: [elem(v, 0)], else: [])], do: id)
      ])

    {Enum.uniq(keys), Enum.uniq(ids)}
  end

  @doc """
  一笔已成功提交（或回放）的事务之后：按事务键与整表比较登记脏单元，维护页索引。`state` 是提交后的状态。
  """
  def remember(state, txn) do
    index = state.pages
    dirty = Map.get(state, :page_dirty, MapSet.new())
    dirty = Enum.reduce(Map.keys(Map.get(txn, :epochs, %{})), dirty, &MapSet.put(&2, cell_unit(:epochs, &1)))
    dirty = Enum.reduce(Map.keys(Map.get(txn, :placed_by, %{})), dirty, &MapSet.put(&2, cell_unit(:placed_by, &1)))
    old_instances = index.remembered.instances || %{}
    old_owners = index.remembered.attachment_owners || %{}

    # 整表：实例与附件归属先于属性行，g=2/3 行的 home 读更新后的归属。
    {index, dirty, changed_ids} = instances(index, dirty, state.instances)
    {index, dirty, changed_aids} = aids(index, dirty, state.attachment_owners)
    {index, dirty} = cells(index, dirty, :liquid_active, state.liquid_active, &MapSet.to_list/1)
    sources = if state.thermal, do: state.thermal.sources, else: %{}
    {index, dirty} = cells(index, dirty, :sources, sources, &Map.keys/1)

    {index, dirty} =
      Enum.reduce(Map.get(txn, :property_states, []), {index, dirty}, fn t, acc ->
        damage(acc, Damage.key(t), Map.get(state.damage, Damage.key(t)))
      end)

    touched = Map.get(state, :owners_touched, MapSet.new()) |> Enum.concat(changed_ids) |> Enum.concat(Enum.map(changed_aids, &{:aid, &1}))
    {index, dirty} = covers(state, index, dirty, touched, old_instances, old_owners)

    Map.merge(state, %{pages: index, page_dirty: dirty, owners_touched: MapSet.new()})
  end

  defp instances(%{remembered: %{instances: same}} = index, dirty, same), do: {index, dirty, []}

  defp instances(index, dirty, now) do
    old = index.remembered.instances || %{}
    changed = for {id, _} <- Map.merge(old, now), Map.get(old, id) != Map.get(now, id), do: id

    {homes, members, children, dirty} =
      Enum.reduce(changed, {index.instance_home, index.home_instances, index.children, dirty}, fn id, {homes, members, children, dirty} ->
        {homes, members, dirty} = unhome(homes, members, dirty, id)
        children = case Map.fetch(old, id) do
          {:ok, i} -> unlink(children, Map.get(i, :parent_id, {0, 0}), id)
          :error -> children
        end
        # 新身份写定位行（根与根 home 自创建起不变，只插入）。
        dirty = if Map.has_key?(old, id), do: dirty, else: MapSet.put(dirty, {:locator, locator_key(id)})

        case Map.fetch(now, id) do
          {:ok, instance} ->
            {homes, members, dirty} = home(homes, members, dirty, id, instance_home(instance))
            {homes, members, link(children, Map.get(instance, :parent_id, {0, 0}), id), dirty}

          :error ->
            {homes, members, children, dirty}
        end
      end)

    {%{index | instance_home: homes, home_instances: members, children: children, remembered: %{index.remembered | instances: now}},
      dirty, changed}
  end

  defp link(children, {0, 0}, _id), do: children
  defp link(children, parent, id), do: Map.update(children, parent, MapSet.new([id]), &MapSet.put(&1, id))
  defp unlink(children, {0, 0}, _id), do: children
  defp unlink(children, parent, id), do: drop_member(children, parent, id)

  # 有主附件 id 的 home = owner 实例的 home（m2a §3，对父稿 P1 的修订）。
  defp aids(%{remembered: %{attachment_owners: same}} = index, dirty, same), do: {index, dirty, []}

  defp aids(index, dirty, now) do
    old = index.remembered.attachment_owners || %{}
    changed = for {aid, _} <- Map.merge(old, now), Map.get(old, aid) != Map.get(now, aid), do: aid

    {homes, members, dirty} =
      Enum.reduce(changed, {index.aid_home, index.home_aids, dirty}, fn aid, {homes, members, dirty} ->
        {homes, members, dirty} = unhome(homes, members, dirty, aid)
        dirty = if Map.has_key?(old, aid), do: dirty, else: MapSet.put(dirty, {:locator, locator_key({:aid, aid})})

        case Map.fetch(now, aid) do
          {:ok, {owner, _}} -> home(homes, members, dirty, aid, Map.fetch!(index.instance_home, owner))
          :error -> {homes, members, dirty}
        end
      end)

    {%{index | aid_home: homes, home_aids: members, remembered: %{index.remembered | attachment_owners: now}}, dirty, changed}
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
    rest = MapSet.delete(Map.get(members, key, MapSet.new()), id)
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

  # ---- 覆盖页集合（M2b home 汇总）：根实例 => 整树的成员 home 页、细化格 / 归属格所在页、有主附件槽所在页。

  defp covers(state, index, dirty, touched, old_instances, old_owners) do
    roots =
      touched
      |> Enum.map(fn
        {:aid, aid} ->
          case Map.get(state.attachment_owners, aid) || Map.get(old_owners, aid) do
            {owner, _} -> root(owner, state.instances, old_instances)
            nil -> nil
          end

        id -> root(id, state.instances, old_instances)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce(roots, {index, dirty}, fn root, {index, dirty} ->
      case Map.fetch(state.instances, root) do
        {:ok, record} ->
          pages = tree_pages(state, index, root)
          if Map.get(index.covers, root) == pages,
            do: {index, dirty},
            else: {%{index | covers: Map.put(index.covers, root, pages)}, MapSet.put(dirty, {:page, :covers, {0, instance_home(record)}})}

        :error ->
          case Map.fetch(old_instances, root) do
            {:ok, record} -> {%{index | covers: Map.delete(index.covers, root)}, MapSet.put(dirty, {:page, :covers, {0, instance_home(record)}})}
            :error -> {%{index | covers: Map.delete(index.covers, root)}, dirty}
          end
      end
    end)
  end

  # 沿父链到根；删除的身份用提交前的实例表。链断（不该发生：驻留闭合）返回 nil。
  defp root(id, now, old) do
    case Map.get(now, id) || Map.get(old, id) do
      nil -> nil
      record ->
        case Map.get(record, :parent_id, {0, 0}) do
          {0, 0} -> id
          parent -> root(parent, now, old)
        end
    end
  end

  @doc "根实例整树当前覆盖的 L0 页（成员 home、细化格 / 归属格、有主附件槽）。"
  def tree_pages(state, index, root) do
    members = descendants(index.children, [root], MapSet.new())

    Enum.reduce(members, MapSet.new(), fn m, acc ->
      record = Map.fetch!(state.instances, m)
      home = instance_home(record)
      cells = MapSet.union(Map.get(state.refined_owners, m, MapSet.new()), Map.get(state.macro_owner_cells, m, MapSet.new()))
      acc = MapSet.put(acc, home) |> then(&Enum.reduce(cells, &1, fn cell, acc -> MapSet.put(acc, region_of(cell)) end))

      for aid <- Map.get(index.home_aids, home, MapSet.new()), match?({^m, _}, Map.get(state.attachment_owners, aid)),
          region <- Map.keys(Map.get(Map.get(state, :aid_regions, %{}), aid, %{})), reduce: acc, do: (acc -> MapSet.put(acc, region))
    end)
  end

  defp descendants(_, [], ids), do: ids
  defp descendants(children, [id | rest], ids),
    do: descendants(children, MapSet.to_list(Map.get(children, id, MapSet.new())) ++ rest, MapSet.put(ids, id))

  # ---- 活动索引（M2b §2.5）

  @doc "开切点时：本批涉及液体活动集、热源、属性行的页补上活动单元（值在抽取时按冻结状态判）。"
  def with_activity(units) do
    activity = for unit <- units, page = activity_page(unit), page != nil, uniq: true, do: {:page, :activity, {0, page}}
    Enum.uniq(units ++ activity)
  end

  defp activity_page({:chunk, segment, chunk}) when segment in [:liquid_active, :sources, :damage], do: chunk_region(chunk)
  defp activity_page({:page, :identity, {0, page}}), do: page
  defp activity_page(_unit), do: nil

  # 有活动液体格、有限热源或热行（燃烧 / 偏离环境 / 燃料耗尽待结算 / 电路候选）的页：启动后要恢复模拟的页。
  defp active?(state, page) do
    in_page = &(region_of(&1) == page)
    sources = if state.thermal, do: Map.keys(state.thermal.sources), else: []

    Enum.any?(state.liquid_active, in_page) or Enum.any?(sources, in_page) or
      (state.thermal != nil and
         (rows = page_damage(state, page)
          map_size(ThermalWork.hot_rows(rows, state.thermal.config)) > 0 or
            Enum.any?(rows, fn {_, row} -> Combustion.exhausted?(row) or VoxelRegion.Circuit.candidate?(row, state.properties) end)))
  end

  defp page_damage(state, {px, py, pz} = page) do
    units = [{:page, :identity, {0, page}} |
      for(x <- 0..3, y <- 0..3, z <- 0..3, do: {:chunk, :damage, {px * 4 + x, py * 4 + y, pz * 4 + z}})]
    keys = Enum.flat_map(units, &MapSet.to_list(Map.get(state.pages.unit_damage, &1, MapSet.new())))
    Map.take(state.damage, keys)
  end

  # ---- 抽取（写回与测试共用）：只读给定 state（切点冻结的引用），单元的值 O(单元内容)。

  @doc "单元当前的值（空单元为空 map / 空集合；已删除的身份的定位行为 nil，不写）。"
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
      :epochs -> Map.get(state.epochs, chunk, VoxelRegion.EpochChunk.empty(chunk))
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

  def extract(state, {:page, :covers, {0, region}}),
    do: for(id <- Map.get(state.pages.home_instances, region, MapSet.new()), {:ok, pages} <- [Map.fetch(state.pages.covers, id)],
      into: %{}, do: {id, pages})

  def extract(state, {:page, :activity, {0, page}}), do: active?(state, page)

  def extract(state, {:fragment, :structure, key}),
    do: Map.take(state.structure, Enum.map(Map.get(state.structure_pages, key, MapSet.new()), &{elem(key, 0), &1}))

  def extract(state, {:fragment, :canopy, key}), do: Map.get(state.canopy, key)

  def extract(state, {:locator, {kind, a, b}}) do
    owner = if kind == 1, do: {a, b}, else: (case Map.get(state.attachment_owners, a) do {owner, _} -> owner; nil -> nil end)

    with true <- owner != nil, root when root != nil <- root(owner, state.instances, %{}),
         {:ok, record} <- Map.fetch(state.instances, root) do
      %{root: root, home: instance_home(record)}
    else
      _ -> nil
    end
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
      for({root, _} <- state.pages.covers, do: {:page, :covers, {0, Map.fetch!(state.pages.instance_home, root)}}),
      for(key <- Map.keys(state.region_bases), do: {:page, :base, key}),
      for(key <- Map.keys(state.structure_pages), do: {:fragment, :structure, key}),
      for(key <- Map.keys(state.canopy), do: {:fragment, :canopy, key}),
      for(id <- Map.keys(state.instances), do: {:locator, locator_key(id)}),
      for(aid <- Map.keys(state.attachment_owners), do: {:locator, locator_key({:aid, aid})})
    ]
    |> Enum.concat()
    |> with_activity()
    |> MapSet.new()
  end

  @doc "攒下的脏单元。"
  def dirty(state), do: Map.get(state, :page_dirty, MapSet.new())

  @doc "构造一个写回自然单元并冻结其非空ETF列表上界；过大由产生端显式拒绝，不交消费者另路处理。"
  def write_unit(state, unit, maximum) do
    value = {unit, extract(state, unit)}
    bytes = :erlang.external_size([value])
    if maximum == :infinity or bytes <= maximum,
      do: {value, bytes},
      else: raise(ArgumentError, "voxel write unit #{inspect(unit)} exceeds declared ETF budget: #{bytes} > #{maximum}; refine the upstream natural unit")
  end

  # ---- 存储行（段编码的唯一定义；后端只存取行）

  @segment_codes %{overlay: 1, refined: 2, attachments: 3, liquid_units: 4, liquid_active: 5, epochs: 6, placed_by: 7,
    macro_owners: 8, sources: 9, damage: 10, base: 20, coarse_overlay: 21, identity: 22, covers: 23, activity: 24,
    structure: 30, canopy: 31}
  @segments Map.new(@segment_codes, fn {k, v} -> {v, k} end)
  @fragment_segments [:structure, :canopy]

  @doc "活动索引段的存储编码（启动按它读活动页）。"
  def activity_code, do: @segment_codes.activity

  @doc "粗层片段段的存储编码（装页时按 `(level, L0 页)` 选行）。"
  def fragment_codes, do: Enum.map(@fragment_segments, &Map.fetch!(@segment_codes, &1))

  # 页存储格式：2 = M2b（覆盖页、活动、粗层片段、定位行）。M2a 写的库缺这些段，读到即显式失败。
  @page_format 2

  # 全局账：每个切点一行（m2a §3）；thermal 去掉逐格的 sources（进页）。
  @globals [:seq, :material_balances, :caster_energy, :material_supplies, :craft_ledger, :food_ledger, :food_receipts,
    :beacons, :beacon_attunements, :phase_inventory, :attachment_serial, :material_units_per_micro, :interaction_history, :interaction_floor]

  @doc "单元与值 → 存储行（`term_to_binary` 压缩；空值也写，表示该单元已清空，不以缺行表示）。已删除身份的定位单元返回 nil（不写）。"
  def row({:chunk, :refined, chunk}, value) do
    # format2 的旧 map 只在 writer 编码边界展开；运输预算仍计实际紧凑输入的 ETF。
    legacy = Map.new(value, fn {cell, slots} -> {cell, RefinedSlots.to_map(slots)} end)
    %{level: 0, region: chunk_region(chunk), segment: Map.fetch!(@segment_codes, :refined), chunk: chunk, payload: encode(legacy)}
  end

  def row({:chunk, :epochs, chunk}, value),
    do: %{level: 0, region: chunk_region(chunk), segment: Map.fetch!(@segment_codes, :epochs), chunk: chunk,
      payload: encode(VoxelRegion.EpochChunk.to_map(value))}

  def row({:chunk, segment, chunk} = _unit, value),
    do: %{level: 0, region: chunk_region(chunk), segment: Map.fetch!(@segment_codes, segment), chunk: chunk, payload: encode(value)}

  def row({:page, segment, {level, region}}, value),
    do: %{level: level, region: region, segment: Map.fetch!(@segment_codes, segment), chunk: {0, 0, 0}, payload: encode(value)}

  def row({:fragment, segment, {level, page}}, value),
    do: %{level: level, region: page, segment: Map.fetch!(@segment_codes, segment), chunk: {0, 0, 0}, payload: encode(value)}

  def row({:locator, _key}, nil), do: nil
  def row({:locator, key}, %{root: root, home: home}), do: %{locator: key, root: root, home: home}

  @doc "存储行 → `{单元, 值}`。"
  def unit_value(%{level: level, region: region, segment: code, chunk: chunk, payload: payload}) do
    unit =
      case Map.fetch!(@segments, code) do
        segment when code < 20 -> {:chunk, segment, chunk}
        segment when segment in @fragment_segments -> {:fragment, segment, {level, region}}
        segment -> {:page, segment, {level, region}}
      end

    value = decode(payload)
    value = case unit do
      {:chunk, :refined, _} -> Map.new(value, fn {cell, slots} -> {cell, RefinedSlots.from_map(slots)} end)
      {:chunk, :epochs, chunk} -> VoxelRegion.EpochChunk.from_map(chunk, value)
      _ -> value
    end
    {unit, value}
  end

  @doc "切点冻结的持久字段引用（同进程零拷贝；不钉住订阅、保留历史与任务，评审 A4.1）。"
  def frozen(state),
    do: Map.take(state, [:overlay, :overlay_regions, :refined_regions, :liquid_regions, :macro_owner_regions, :attachment_regions,
      :liquid_active, :thermal, :epochs, :placed_by, :damage, :pages, :region_bases, :instances, :attachment_owners, :protection,
      :structure, :structure_pages, :canopy, :properties | @globals])

  @doc "冻结状态的全局账行。"
  def globals(state) do
    encode(state |> Map.take(@globals) |> Map.put(:protection, state.protection.regions)
      |> Map.put(:thermal, state.thermal && Map.delete(state.thermal, :sources)) |> Map.put(:page_format, @page_format))
  end

  defp encode(value), do: :erlang.term_to_binary(%{format: 1, value: value}, compressed: 6)
  @doc "存储行载荷解码。"
  def decode(bytes), do: VoxelRegion.OverlayLog.term(bytes).value

  @doc "全局行装入（启动读头部之后）：格式不是本版即显式失败（M2a 库缺覆盖页 / 片段 / 定位段，不能按需装页）。"
  def install_globals(state, globals) do
    g = decode(globals)

    if Map.get(g, :page_format) != @page_format do
      raise "voxel page store format #{inspect(Map.get(g, :page_format, 1))} != #{@page_format}: restore from the log dump and re-migrate"
    end

    %{Map.merge(state, Map.take(g, @globals)) |
      protection: VoxelRegion.Protection.apply(state.protection, g.protection),
      thermal: g.thermal && Map.put(g.thermal, :sources, %{})}
  end

  # ---- 装页接纳（M2b）

  @doc """
  接纳装页结果：只收令牌代数仍匹配且仍未驻留的页（父稿 P4 装页令牌；P1退休同回合推进代数）。行按 PageStore 选行规则归属到页；
  已驻留的粗层片段跳过（内存为准）。返回 `{state, {后续页, 要定位的身份}, 装入的属性行}`：后续页 = 定位到的根 home 页、
  新驻留根的覆盖页中未驻留者；要定位的 = 新页上引用、内存里没有记录的实例 / 附件 id。
  """
  def adopt(state, tokens, rows, located) do
    keys = for {key, gen} <- tokens, not resident?(state, key), gen == Map.get(state.page_generation, key, 0), uniq: true, do: key
    {state, new_instances, loaded_rows} = install(state, MapSet.new(keys), Enum.map(rows, &unit_value/1))
    state = mark_resident(state, keys)
    {state, follow_ups(state, keys, new_instances, located), loaded_rows}
  end

  @doc """
  分批接纳（M2b 统筹第四轮）：装页任务把已解码的单元按固定规模分批交来，World 每批只装入、不标驻留（`wanted` = 该任务暂存中的页）；
  整树闭合后由 `commit_missing/2` 复核、`mark_resident/2` 一次标记驻留。暂存页不驻留，别的请求过闸时仍要等它（不放行半棵树，评审必改 2）。
  返回 `{state, 装入的属性行}`。
  """
  def stage(state, wanted, units) do
    {state, _new_instances, loaded_rows} = install(state, wanted, units)
    {state, loaded_rows}
  end

  @tree_segments [:identity, :covers, :refined, :macro_owners, :attachments]

  @doc """
  分批暂存时可以随批标驻留的页（统筹第五轮 / 评审 Fable §2.4）：粗层页，以及本轮读到的单元里不带任何树身份 / 引用
  （identity、covers、refined、macro_owners、attachments）的 L0 页——它们的闭包是平凡的，不必等整树闭合。按批给出：
  页的最后一个单元所在的批（没有单元的页在第一批）装完即可标驻留。带树身份或覆盖关系的页仍等 `:page_commit`。
  """
  def ready_batches(keys, batches) do
    wanted = MapSet.new(keys)
    tree = for batch <- batches, {{_, segment, _} = unit, _} <- batch, segment in @tree_segments, into: MapSet.new(), do: unit_key(unit)

    last =
      batches
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {batch, i}, acc ->
        Enum.reduce(batch, acc, fn {unit, _}, acc -> Enum.reduce(unit_owners(unit, wanted), acc, &Map.put(&2, &1, i)) end)
      end)

    for i <- 0..(length(batches) - 1)//1,
        do: for(key <- keys, not MapSet.member?(tree, key), Map.get(last, key, 0) == i, do: key)
  end

  defp unit_owners({:fragment, _, {level, page}}, wanted),
    do: Enum.filter([{0, page}, {level, coarse_region(level, page)}], &MapSet.member?(wanted, &1))

  defp unit_owners(unit, wanted), do: Enum.filter([unit_key(unit)], &MapSet.member?(wanted, &1))

  @doc "一次标记驻留（闭包已闭合的整批页）。"
  def mark_resident(%{resident: :all} = state, _keys), do: state
  def mark_resident(state, keys), do: %{state | resident: Enum.into(keys, state.resident)}

  @doc """
  提交前复核暂存页的树闭包：home 在这些页的实例，其根的覆盖页都已驻留或在本批里；缺的页返回（任务继续读）。
  不重扫页内引用（引用的身份已由任务按 PG 行求闭包时定位过）。
  """
  def commit_missing(state, keys) do
    pending = MapSet.new(keys)

    for {0, page} <- keys, id <- Map.get(state.pages.home_instances, page, MapSet.new()), root = chain_root(state.instances, id),
        root != nil, cover <- Map.get(state.pages.covers, root, MapSet.new()), key = {0, cover},
        not resident?(state, key), not MapSet.member?(pending, key), uniq: true, do: key
  end

  # 装入单元（只装 `wanted` 里的页的单元，已驻留的粗层片段跳过）：经同一写入口、不判脏，补页索引与 `remembered`。
  defp install(state, wanted, all_units) do
    units = for {unit, _} = pair <- all_units, adopt_unit?(state, wanted, unit), do: pair
    dirty = Map.get(state, :page_dirty, MapSet.new())
    touched = Map.get(state, :owners_touched, MapSet.new())
    written = Map.get(state, :written, MapSet.new())
    before_instances = state.instances
    before_owners = state.attachment_owners

    # 身份先于属性行（g=2/3 行的单元读 owner 的 home）。
    {identity, rest} = Enum.split_with(units, fn {unit, _} -> match?({:page, segment, _} when segment in [:identity, :covers], unit) end)
    state = Enum.reduce(identity ++ rest, state, fn {unit, value}, s -> put_unit(s, unit, value) end)

    new_instances = Map.drop(state.instances, Map.keys(before_instances))
    new_aids = Map.drop(state.attachment_owners, Map.keys(before_owners))
    loaded_rows = for {unit, value} <- units, row <- unit_rows(unit, value), do: row
    state = index_loaded(state, new_instances, new_aids, loaded_rows)
    loaded = %{instances: new_instances, attachment_owners: new_aids,
      liquid_active: for({{:chunk, :liquid_active, _}, cells} <- units, cell <- cells, into: MapSet.new(), do: cell),
      sources: for({{:chunk, :sources, _}, cells} <- units, kv <- cells, into: %{}, do: kv)}
    state = %{state | pages: remember_loaded(state.pages, loaded)}
    # 只有真装入了内容的页才可能让此前按 baseline 物化的缓存过时（PG 无行 = 从未编辑 = baseline）。
    filled = for {unit, _} <- units, uniq: true, do: unit_key(unit)
    state = Enum.reduce(filled, state, &invalidate(&2, &1))
    {Map.merge(state, %{page_dirty: dirty, owners_touched: touched, written: written}), new_instances, loaded_rows}
  end

  defp adopt_unit?(state, wanted, {:fragment, _, {level, page}}),
    do: not fragment_resident?(state, level, page) and
      (MapSet.member?(wanted, {0, page}) or MapSet.member?(wanted, {level, coarse_region(level, page)}))

  defp adopt_unit?(_state, wanted, {:chunk, _, chunk}), do: MapSet.member?(wanted, {0, chunk_region(chunk)})
  defp adopt_unit?(_state, wanted, {:page, _, key}), do: MapSet.member?(wanted, key)

  defp unit_key({:chunk, _, chunk}), do: {0, chunk_region(chunk)}
  defp unit_key({:fragment, _, {_, page}}), do: {0, page}
  defp unit_key({:page, _, key}), do: key

  defp unit_rows({:chunk, :damage, _}, rows), do: Map.values(rows)
  defp unit_rows({:page, :identity, _}, value), do: Map.values(value.damage)
  defp unit_rows(_unit, _value), do: []

  # 装入的身份与属性行进页索引（与 `remember/2` 同一归属规则，不判脏）；`remembered` 换成装入后的整表，下一笔提交只比较其后的改动。
  defp index_loaded(state, instances, aids, rows) do
    index = state.pages

    {homes, members, children} =
      Enum.reduce(instances, {index.instance_home, index.home_instances, index.children}, fn {id, i}, {homes, members, children} ->
        region = instance_home(i)
        {Map.put(homes, id, region), Map.update(members, region, MapSet.new([id]), &MapSet.put(&1, id)),
          link(children, Map.get(i, :parent_id, {0, 0}), id)}
      end)

    index = %{index | instance_home: homes, home_instances: members, children: children}

    {homes, members} =
      Enum.reduce(aids, {index.aid_home, index.home_aids}, fn {aid, {owner, _}}, {homes, members} ->
        region = Map.fetch!(index.instance_home, owner)
        {Map.put(homes, aid, region), Map.update(members, region, MapSet.new([aid]), &MapSet.put(&1, aid))}
      end)

    index = %{index | aid_home: homes, home_aids: members}

    {index, _} =
      Enum.reduce(rows, {index, MapSet.new()}, fn row, acc -> damage(acc, Damage.key(row), row) end)

    %{state | pages: index}
  end

  # 装入的键并入 `remembered`（评审 A3 / F5）：只加本次接纳的页带来的键，不把别处自上次记住以来、尚未提交的差异（如热步中途耗尽的热源）
  # 一起抹成“已记住”——否则那笔提交收尾时比较不出差异、漏判脏，重启会复活旧值。
  defp remember_loaded(index, loaded) do
    r = index.remembered
    %{index | remembered: %{r | instances: Map.merge(r.instances || %{}, loaded.instances),
      attachment_owners: Map.merge(r.attachment_owners || %{}, loaded.attachment_owners),
      liquid_active: MapSet.union(r.liquid_active || MapSet.new(), loaded.liquid_active),
      sources: Map.merge(r.sources || %{}, loaded.sources)}}
  end

  # 新驻留页及其邻页的载荷缓存可能是装页前按缺页物化的：丢掉（粗层载荷读 L0 页上的片段，一并丢）。
  defp invalidate(state, {0, page} = key) do
    coarse = for level <- 1..@max_level, do: {level, coarse_region(level, page)}
    Enum.reduce(expand([key | coarse]), state, fn k, s ->
      %{Payloads.cache_delete(s, k) | liquid_adopted: Map.delete(s.liquid_adopted, elem(k, 1))}
    end)
  end

  defp invalidate(state, key), do: Enum.reduce(expand([key]), state, &Payloads.cache_delete(&2, &1))

  defp follow_ups(state, keys, new_instances, located) do
    homes = for {_, %{home: home}} <- located, not resident?(state, {0, home}), do: {0, home}

    # 新页上引用的身份：细化槽与归属格的实例、附件槽的 aid；内存里没有记录的去定位。
    l0 = for {0, page} <- keys, do: page
    referenced =
      Enum.concat([
        for(page <- l0, {_, slots} <- Map.get(state.refined_regions, page, %{}), {_, {_, owner}} <- slots, do: owner),
        for(page <- l0, {_, owner} <- Map.get(state.macro_owner_regions, page, %{}), do: owner),
        for(page <- l0, {_, {aid, _}} <- Map.get(state.attachment_regions, page, %{}), do: {:aid, aid})
      ])
      |> Enum.uniq()

    unknown = for id <- referenced, not known?(state, id), do: id

    # 新装入的实例：整树要完整——父链走到根且根的覆盖页都驻留；链断（父在别页）就按该实例定位根。
    {orphans, roots} =
      Enum.reduce(new_instances, {[], MapSet.new()}, fn {id, _}, {orphans, roots} ->
        case chain_root(state.instances, id) do
          nil -> {[id | orphans], roots}
          root -> {orphans, MapSet.put(roots, root)}
        end
      end)

    covered = for root <- roots, page <- Map.get(state.pages.covers, root, MapSet.new()), not resident?(state, {0, page}), do: {0, page}
    {Enum.uniq(homes ++ covered), Enum.uniq(unknown ++ orphans)}
  end

  defp known?(state, {:aid, aid}), do: Map.has_key?(state.attachment_owners, aid)
  defp known?(state, id), do: Map.has_key?(state.instances, id)

  defp chain_root(instances, id) do
    case Map.fetch(instances, id) do
      :error -> nil
      {:ok, record} ->
        case Map.get(record, :parent_id, {0, 0}) do
          {0, 0} -> id
          parent -> chain_root(instances, parent)
        end
    end
  end

  defp put_unit(s, _unit, nil), do: s
  defp put_unit(s, {:chunk, :overlay, _}, cells), do: Enum.reduce(cells, s, fn {cell, v}, s -> Edits.put_overlay(s, 0, cell, v) end)
  defp put_unit(s, {:page, :coarse_overlay, {level, _}}, cells), do: Enum.reduce(cells, s, fn {cell, v}, s -> Edits.put_overlay(s, level, cell, v) end)
  defp put_unit(s, {:chunk, :refined, _}, cells), do: cells |> Enum.reduce(s, fn {cell, slots}, s -> Canonical.put_refined(s, cell, slots) end) |> snapshot(Map.keys(cells))
  defp put_unit(s, {:chunk, :attachments, _}, slots), do: s |> Canonical.put_attachments(slots) |> snapshot(Attachments.macros(Map.keys(slots)))
  defp put_unit(s, {:chunk, :liquid_units, _}, cells), do: s |> Canonical.put_liquid(cells) |> snapshot(Map.keys(cells))
  defp put_unit(s, {:chunk, :macro_owners, _}, cells), do: cells |> Enum.reduce(s, fn {cell, o}, s -> Canonical.put_macro_owner(s, cell, o) end) |> snapshot(Map.keys(cells))
  defp put_unit(s, {:chunk, :liquid_active, _}, cells), do: %{s | liquid_active: MapSet.union(s.liquid_active, cells)}
  defp put_unit(s, {:chunk, :sources, _}, cells), do: %{s | thermal: %{s.thermal | sources: Map.merge(s.thermal.sources, cells)}}
  defp put_unit(s, {:chunk, :epochs, chunk}, %VoxelRegion.EpochChunk{count: count} = cells) when count > 0,
    do: %{s | epochs: Map.put(s.epochs, chunk, cells)}
  defp put_unit(s, {:chunk, :placed_by, chunk}, cells) when map_size(cells) > 0, do: %{s | placed_by: Map.put(s.placed_by, chunk, cells)}
  defp put_unit(s, {:chunk, segment, _}, _empty) when segment in [:epochs, :placed_by], do: s
  defp put_unit(s, {:chunk, :damage, _}, rows), do: %{s | damage: Map.merge(s.damage, rows)}

  defp put_unit(s, {:page, :identity, _}, v),
    do: %{s | instances: Map.merge(s.instances, v.instances), attachment_owners: Map.merge(s.attachment_owners, v.attachment_owners),
      damage: Map.merge(s.damage, v.damage)}

  defp put_unit(s, {:page, :covers, _}, covers), do: %{s | pages: %{s.pages | covers: Map.merge(s.pages.covers, covers)}}
  defp put_unit(s, {:page, :activity, _}, _active), do: s

  # 地形基底与旧检查点换基底同一语义（`Log.rebase_region/2`）：进 `region_bases`、记为完整快照、丢源解码与缓存。
  defp put_unit(s, {:page, :base, key}, base),
    do: %{Payloads.cache_delete(s, key) | region_bases: Map.put(s.region_bases, key, base),
      snapshots: MapSet.put(s.snapshots, key), decoded: Map.delete(s.decoded, key)}

  # 粗层片段：structure 项经唯一写入口装入；有 structure 或树冠的粗层区域（含 ring）按完整快照物化（与回放 structure 条目同一规则）。
  defp put_unit(s, {:fragment, :structure, _}, entries) do
    s = Enum.reduce(entries, s, fn {key, grid}, s -> Canonical.put_structure(s, key, grid) end)
    %{s | snapshots: Enum.into(LogProjection.region_keys(Map.keys(entries)), s.snapshots)}
  end

  defp put_unit(s, {:fragment, :canopy, {level, _} = key}, fragment) do
    cells = for {cell, _} <- fragment.anchors, uniq: true, do: {level, VoxelRegion.World.Canopy.at_level(cell, level)}
    %{s | canopy: Map.put(s.canopy, key, fragment), snapshots: Enum.into(LogProjection.region_keys(cells), s.snapshots)}
  end

  # 有细节的格所在及以其为 ring 的 L0 区域都按完整快照物化（与回放区域后像、液体数量增量同一规则）。
  defp snapshot(s, cells),
    do: %{s | snapshots: Enum.into(LogProjection.region_keys(Enum.map(cells, &{0, &1})), s.snapshots)}

  @doc "从全量状态重建页索引与覆盖页集合并清空脏集（迁移与全新世界启动；O(世界)，只在启动）。"
  def rebuild(state) do
    state = remember(Map.merge(state, %{pages: new(), owners_touched: MapSet.new()}), %{property_states: Map.values(state.damage)})
    %{state | page_dirty: MapSet.new()}
  end
end
