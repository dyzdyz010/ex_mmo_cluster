defmodule VoxelRegion.World.CoarseRebuild do
  @moduledoc """
  全局系统维护：World 离线重建 L>0 派生物的单次状态变换。
  只由 World.rebuild_coarse/1 在完整恢复后调用；没有在线开关或新持久格式。
  独占维护（m2a §4.3）：重派生后提交一笔维护事务推进 seq，再同步发布覆盖它的页表切点（全部旧 / 新粗层单元与恢复后缀的脏单元）；
  发布即成功边界，发布前失败整体重跑。
  """
  require Logger
  alias VoxelRegion.{Attachments, Thermal}
  alias VoxelRegion.World.{AttachmentOps, Canonical, Edits, Log, PageCut, Pages, Payloads}

  @metadata [:seq, :cv, :refined, :instances, :macro_owners, :macro_owner_regions, :macro_owner_cells, :attachments, :attachment_regions,
    :attachment_serial, :attachment_owners, :liquid_units, :liquid_regions, :liquid_active,
    :damage, :epochs, :material_balances, :caster_energy, :material_supplies,
    :craft_ledger, :food_ledger, :food_receipts, :placed_by, :protection,
    :phase_inventory, :thermal, :material_units_per_micro,
    :interaction_history, :interaction_floor]

  @doc "由唯一离线 World owner 重派生、精确核对 canonical，然后原子替换日志前缀。"
  def run(state) do
    started = System.monotonic_time(:millisecond)
    metadata = Map.take(state, @metadata)
    l0_overlay = l0(state.overlay)
    l0_bases = l0(state.region_bases)
    regions =
      (Map.keys(state.region_bases) ++ Map.keys(state.overlay_regions) ++ MapSet.to_list(state.snapshots))
      |> Enum.flat_map(fn {0, r} -> [r]; _ -> [] end)
      |> Enum.uniq()
      |> Enum.sort()

    cells = Enum.map(Map.keys(l0_overlay), &elem(&1, 1)) ++ Map.keys(state.refined) ++
      Map.keys(state.macro_owners) ++ Attachments.macros(Map.keys(state.attachments))
    cells = cells |> Enum.flat_map(&[&1 | Thermal.neighbors(&1)]) |> Enum.uniq()
    dirty = AttachmentOps.attachment_dirty(state, cells)
    regions = (regions ++ Enum.map(dirty, fn {0, c} -> Canonical.region_of(c) end)) |> Enum.uniq() |> Enum.sort()
    {before_bytes, state} = l0_bytes(state, regions)
    # 被丢弃的旧粗层单元也要写（写成空），否则页表里的旧粗层会在恢复时复活。
    discarded = for({level, cell} <- Map.keys(state.overlay), level > 0, do: Pages.overlay_unit(level, cell)) ++
      for({level, _} = key <- Map.keys(state.region_bases), level > 0, do: {:page, :base, key})
    state = discard_coarse(state)
    state = Enum.reduce(discarded, state, &Pages.mark(&2, &1))

    # 完整 L0 base 的 core 不能由稀疏 overlay 代表；流式展开，每批最多 4096 格。
    core_regions = Map.keys(l0_bases) |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    sparse = Enum.reject(dirty, fn {0, cell} -> MapSet.member?(core_regions, Canonical.region_of(cell)) end)
    cores = Stream.flat_map(Enum.sort(core_regions), fn {rx, ry, rz} ->
      Stream.flat_map(0..63, fn y ->
        for z <- 0..63, x <- 0..63, do: {0, {rx * 64 + x, ry * 64 + y, rz * 64 + z}}
      end)
    end)

    {state, visits, batches} =
      Stream.concat(cores, sparse)
      |> Stream.chunk_every(4096)
      |> Enum.reduce({state, 0, 0}, fn batch, {s, visits, n} ->
        # reduce_batch 对 FileStore 的 missing 会停止归约；离线重建必须在写 checkpoint 前显式拒绝缺基底。
        for {level, region} = key <- Edits.edit_keys(Enum.map(batch, &elem(&1, 1))) |> Enum.uniq(),
            not Map.has_key?(s.region_bases, key) do
          :ok = s.source.ensure(s.source_state, level, region)
        end
        {:ok, _, s, count} = Edits.reduce_batch(s, batch, 1, [], 0)
        if rem(n + 1, 64) == 0, do: Logger.info("coarse_rebuild batches=#{n + 1} visits=#{visits + count}")
        {s, visits + count, n + 1}
      end)

    {state, _, _} = Payloads.refresh_structure(state, cells)
    # 树冠片段读粗层值：粗层重派生后全部重算（变了的判脏，随同步切点写出）。
    state = VoxelRegion.World.Canopy.refresh_all(state)
    true = Map.take(state, @metadata) === metadata
    true = l0(state.overlay) === l0_overlay
    true = l0(state.region_bases) === l0_bases
    {after_bytes, state} = l0_bytes(state, regions)
    true = before_bytes === after_bytes
    coarse_cells = Enum.count(state.overlay, fn {{level, _}, _} -> level > 0 end)
    structure_cells = map_size(state.structure)
    before = state
    state = %{state | seq: state.seq + 1}
    txn = %{seq: state.seq, entries: [], coarse: []}
    :ok = Log.append_log(before, state, txn, :system)
    state = Log.remember_entry(state, txn)
    published = PageCut.publish_now(state)
    true = Map.delete(Map.take(state, @metadata), :seq) === Map.delete(metadata, :seq)
    # 维护事务推进了 seq，载荷头随之盖新序号；比较去掉序号后的内容。
    {saved_bytes, _state} = l0_bytes(state, regions)
    true = unstamped(saved_bytes) === unstamped(before_bytes)

    report = %{seq: state.seq, canonical_equal: true, l0_regions: length(regions),
      l0_bases: map_size(l0_bases), coarse_cells: coarse_cells, structure_cells: structure_cells,
      visits: visits, batches: batches, published_units: published,
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      instances: map_size(state.instances), attachments: map_size(state.attachments),
      l0_sha256: Enum.map(before_bytes, fn {region, bytes} ->
        %{region: Tuple.to_list(region), sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
      end),
      metadata_sha256: Map.new(metadata, fn {k, v} ->
        {k, :crypto.hash(:sha256, :erlang.term_to_binary(v, [:deterministic])) |> Base.encode16(case: :lower)}
      end)}
    Logger.info("coarse_rebuild complete seq=#{state.seq} coarse=#{coarse_cells} elapsed_ms=#{report.elapsed_ms}")
    {:ok, report}
  end

  defp l0(map), do: Map.filter(map, fn {{level, _}, _} -> level == 0 end)

  defp unstamped(regions),
    do: Enum.map(regions, fn {region, bytes} -> {:ok, p} = MmoContracts.Voxel.Payload.decode(bytes); {region, %{p | seq: 0}} end)

  defp discard_coarse(state) do
    state = Enum.reduce(Payloads.cached_keys(state), state, fn {level, _} = key, s ->
      if level > 0, do: Payloads.cache_delete(s, key), else: s
    end)
    # 丢弃的 structure 片段也要写（写成空），否则页表里的旧片段会在装页时复活。
    state = Enum.reduce(Map.keys(state.structure_pages), state, &Pages.mark(&2, {:fragment, :structure, &1}))
    state = %{state | structure_pages: %{}}
    %{state | overlay: l0(state.overlay), overlay_regions: l0(state.overlay_regions),
      region_bases: l0(state.region_bases), decoded: l0(state.decoded),
      snapshots: MapSet.filter(state.snapshots, fn {level, _} -> level == 0 end),
      served_headers: l0(state.served_headers), structure: %{}}
  end

  defp l0_bytes(state, regions) do
    Enum.map_reduce(regions, state, fn region, s ->
      {:ok, bytes, s} = Payloads.canonical_region_bytes(s, region)
      {{region, bytes}, s}
    end)
  end
end
