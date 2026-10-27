defmodule VoxelRegion.World.WindowSnapshot do
  @moduledoc """
  全局系统功能：窗口观察切点的只读输入。World 冻结引用，发送进程按信用 1 拉取条目，
  在自己的堆里重建派生索引并调用既有观察算法。运输批次不改变输入或快照语义。
  不捕获日志、模拟工作态或其他窗口的几何；跨窗整件保留完整微格／附件槽。
  """
  alias VoxelRegion.{CollisionSource, PropertyObservation}
  alias VoxelRegion.World.{Canonical, Observation, Payloads}

  # r125 运输回合非 GC 最长 21 ms；64 条减少同步往返，回合耗时与峰值仍由同一基准验证。
  @batch 64

  @doc "在 World 堆上冻结窗口输入引用；不编码，不跨进程复制。"
  def freeze(state, box) do
    coords = CollisionSource.regions(box)

    near =
      for {x, y, z} <- coords,
          dx <- -1..1,
          dy <- -1..1,
          dz <- -1..1,
          into: MapSet.new(),
          do: {x + dx, y + dy, z + dz}

    keys = Enum.map(near, &{0, &1})
    whole = Canonical.refined_owners_in_regions(state, coords)
    geometry = Observation.cached_component_geometry(state, whole)
    missing = MapSet.difference(whole, MapSet.new(Map.keys(geometry)))
    missing = if state.properties == nil, do: MapSet.new(), else: missing

    # 完整载荷命中后不再携带它的原始几何；属性汇总只取缓存未命中的完整整件。
    payload_near =
      for {x, y, z} <- coords,
          not Map.has_key?(state.payloads, {0, {x, y, z}}),
          dx <- -1..1,
          dy <- -1..1,
          dz <- -1..1,
          into: MapSet.new(),
          do: {x + dx, y + dy, z + dz}

    local_cells = Canonical.refined_in_regions(state, payload_near)

    cells =
      Enum.reduce(missing, local_cells, &MapSet.union(&2, Map.fetch!(state.refined_owners, &1)))

    owners = Canonical.refined_owners_in_regions(state, near)

    macros = Map.new(Canonical.macro_owners_in_regions(state, near))

    # 宏格观察沿原 target_at 语义读取槽 0；若宏／微记录同格，保留相同的实际目标与整件汇总输入。
    cells =
      Enum.reduce(macros, cells, fn {cell, _}, cells ->
        case Map.fetch(state.refined, cell) do
          {:ok, %{0 => {_, owner}}} ->
            MapSet.union(MapSet.put(cells, cell), Map.fetch!(state.refined_owners, owner))

          {:ok, _} ->
            MapSet.put(cells, cell)

          :error ->
            cells
        end
      end)

    ids =
      MmoContracts.Voxel.Refined.ancestors(
        state.instances,
        Enum.uniq(MapSet.to_list(owners) ++ Map.values(macros))
      )

    slots = Canonical.attachments_in_regions(state, near)
    aids = MapSet.new(slots, fn slot -> elem(Map.fetch!(state.attachments, slot), 0) end)

    attachment_regions =
      Enum.reduce(aids, MapSet.new(), fn aid, regions ->
        Enum.into(Map.keys(Map.fetch!(state.aid_regions, aid)), regions)
      end)

    attachments =
      for region <- attachment_regions,
          {slot, {aid, _} = value} <- Map.fetch!(state.attachment_regions, region),
          MapSet.member?(aids, aid),
          into: %{},
          do: {slot, value}

    chunks = Enum.flat_map(coords, &CollisionSource.chunk_coords/1)

    overlay_keys =
      for key <- keys, cell <- Map.get(state.overlay_regions, key, MapSet.new()), do: {0, cell}

    view =
      state
      |> Map.take([
        :cv,
        :seq,
        :source,
        :source_state,
        :cache_limit,
        :material_units_per_micro,
        :properties,
        :food_receipts
      ])
      |> Map.merge(%{
        refined: Map.take(state.refined, MapSet.to_list(cells)),
        snapshot_geometry: geometry,
        snapshot_owners: missing,
        macro_owners: macros,
        attachments: attachments,
        instances: Map.take(state.instances, ids),
        prefabs:
          Map.new(
            Map.take(
              state.prefabs,
              Enum.uniq(for id <- ids, do: state.instances[id].definition_id)
            ),
            fn {id, prefab} ->
              {id, %{definition: Map.take(prefab.definition, [:presentation_bindings])}}
            end
          ),
        liquid_units: Map.new(Canonical.liquid_in_regions(state, near)),
        overlay: Map.take(state.overlay, overlay_keys),
        overlay_regions: Map.take(state.overlay_regions, keys),
        region_bases: Map.take(state.region_bases, keys),
        decoded: Map.take(state.decoded, keys),
        snapshots: MapSet.new(Enum.filter(keys, &MapSet.member?(state.snapshots, &1))),
        payloads: Map.take(state.payloads, Enum.map(coords, &{0, &1})),
        # 热 run 的 flush 可在日志提交前增加属性行，持久页索引尚未接纳它们；冻结引用，按运输条目筛选，不能只读该索引。
        damage: state.damage,
        epochs: Map.take(state.epochs, chunks),
        protection: %{regions: state.protection.regions},
        thermal: state.thermal && Map.take(state.thermal, [:config, :semblances]),
        pending_casts:
          Map.new(state.pending_casts, fn {cid, pending} -> {cid, %{record: pending.record}} end)
      })

    %{
      fields: transport_fields(view),
      entries: nil,
      box: box,
      owners: MapSet.new(owners),
      aids: aids
    }
  end

  # 这些容器中的自然记录表单独运输；保留原始输入形状，不引入通用递归序列化器。
  defp transport_fields(view) do
    {view, tables} =
      Enum.reduce(
        [[:source_state, :index, :bounds], [:protection, :regions], [:thermal, :semblances]],
        {view, []},
        fn path, {view, tables} ->
          case get_in(view, path) do
            table when is_map(table) ->
              {_, view} = pop_in(view, path)
              {view, [{{:table, path}, table} | tables]}

            _ ->
              {view, tables}
          end
        end
      )

    Map.to_list(view) ++ Enum.reverse(tables)
  end

  @doc "抽取至多一批冻结条目；游标仅承担运输，不读取当前世界。"
  def next(cursor), do: take(cursor, @batch, [])

  defp take(cursor, 0, items), do: {Enum.reverse(items), cursor}
  defp take(%{fields: [], entries: nil}, _, []), do: :done
  defp take(%{fields: [], entries: nil} = cursor, _, items), do: {Enum.reverse(items), cursor}

  defp take(%{entries: {field, iterator}} = cursor, left, items) do
    case :maps.next(iterator) do
      :none ->
        take(%{cursor | entries: nil}, left, items)

      {key, value, rest} ->
        items =
          if selected?(field, key, value, cursor),
            do: [{:entry, field, key, value} | items],
            else: items

        take(%{cursor | entries: {field, rest}}, left - 1, items)
    end
  end

  defp take(%{fields: [{field, value} | rest], entries: nil} = cursor, left, items) do
    if is_map(value) and not is_struct(value) do
      take(%{cursor | fields: rest, entries: {field, :maps.iterator(value)}}, left - 1, [
        {:value, field, %{}} | items
      ])
    else
      take(%{cursor | fields: rest}, left - 1, [{:value, field, value} | items])
    end
  end

  defp selected?(:damage, {2, owner}, _, cursor), do: MapSet.member?(cursor.owners, owner)
  defp selected?(:damage, {3, aid}, _, cursor), do: MapSet.member?(cursor.aids, aid)
  defp selected?(:damage, _, row, cursor), do: PropertyObservation.relevant?(row, cursor.box)
  defp selected?(_, _, _, _), do: true

  @doc "发送进程接纳冻结条目；不验证或推断上游已冻结的事实。"
  def accept(view, items) do
    Enum.reduce(items, view, fn
      {:value, {:table, path}, value}, acc ->
        put_in(acc, path, value)

      {:entry, {:table, path}, key, value}, acc ->
        update_in(acc, path, &Map.put(&1, key, value))

      {:value, field, value}, acc ->
        Map.put(acc, field, value)

      {:entry, field, key, value}, acc ->
        Map.update!(acc, field, &Map.put(&1, key, value))
    end)
  end

  @doc "在发送进程重建可丢弃索引，沿唯一观察算法组装快照。"
  def build(view, box) do
    cached = view.payloads

    view =
      Map.merge(view, %{
        payloads: %{},
        lru: :gb_trees.empty(),
        lru_ticks: %{},
        tick: 0,
        lru_bytes: 0,
        resident_bytes: 0,
        cache_stats: %{hits: 0, misses: 0, evictions: 0}
      })

    view =
      view
      |> Canonical.index_refined()
      |> Canonical.index_macro_owners()
      |> Canonical.index_liquid()
      |> Canonical.index_attachments()

    view =
      Enum.reduce(cached, view, fn {key, {bytes, header}}, acc ->
        Payloads.cache_put(acc, key, bytes, header)
      end)

    geometry =
      Map.merge(
        view.snapshot_geometry,
        Observation.snapshot_component_geometry(view, box, view.snapshot_owners)
      )

    Observation.capture_canonical_snapshot(
      %{view | snapshot_geometry: geometry},
      box,
      geometry,
      cached
    )
  end
end
