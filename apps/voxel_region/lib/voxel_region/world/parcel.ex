defmodule VoxelRegion.World.Parcel do
  @moduledoc """
  全局系统功能：地块导出与维护安装（Voxim `Docs/Playtest/terrain-transplant-design.md`）。

  - **导出** `export/2`：在同一个 seq 上读源世界半开宏格盒 `[lo, hi)` 的完整 L0 真值——每格 `{material, skins}`
    （空气也是内容）、细化槽、宏格归属、有限数量、实例树、附件（实例带的与玩家直接挂的无主附件）、相关属性行，
    以及实例用到的定义字节。盒内每棵实例树与每个附件必须完整落在盒内，否则拒绝，不切半座建筑。
  - **安装** `install/4`：一笔正常 World 提交（`Prefabs.prefab_reply`：后像、粗层、结构、碰撞、日志、广播），
    把目标盒 `[lo+Δ, hi+Δ)` 整体换成地块内容，盒外不变；与当前有效值相同的格不写 overlay。Δ 为整米；实例与附件取目标世界的新身份，锚点平移 8Δ 微格，
    放置者归作者（nil）。有限数量、HP 与部件状态随地块带入；温度与相态焓按目标环境温度重设（作者初态，
    计入 phase_authored 账）。目标盒触及受保护区域、或目标原有实例／附件伸出盒外时整笔拒绝。
    同 key 只装一次：回执记在 `material_supplies[{0, {:parcel, key}}]`，随事务进日志与检查点，重试返回原回执。
    缺失的定义只写进世界 prefabs 目录的 `.vxpd`（重启可加载），不进玩家发布列表。

  只经 release rpc 在维护窗口调用，不接 Gate；目标世界不应有玩家在线。
  """
  import VoxelRegion.World.Canonical
  alias VoxelRegion.{Attachments, Damage, Phase, Prefab, Protection}
  alias VoxelRegion.World.{Edits, Prefabs}

  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "源世界盒内地块；返回 `{{:ok, parcel} | {:error, reason}, state}`（state 只多了解码缓存）。"
  def export(state, {lo, hi} = box) do
    cells = box_cells(box)
    state = Edits.ensure_sources(state, cells)
    {values, state} = Enum.map_reduce(cells, state, fn cell, s ->
      {:ok, value, s} = cell_value(s, 0, cell)
      {{cell, value}, s}
    end)
    inside? = &inside?(&1, box)
    refined = for cell <- refined_in_regions(state, regions(box)), inside?.(cell), into: %{}, do: {cell, state.refined[cell]}
    macro_owners = Map.filter(state.macro_owners, fn {cell, _} -> inside?.(cell) end)

    with {:ok, ids} <- trees(state, refined, macro_owners, inside?, :instance_crosses_boundary) do
      owned = for {aid, {owner, _}} <- state.attachment_owners, MapSet.member?(ids, owner), into: MapSet.new(), do: aid
      # 玩家直接挂在格面上的附件没有主人：碰到盒内就随地块走（跨出盒界照样拒绝）。
      owned = for {slot, {aid, _}} <- state.attachments, not Map.has_key?(state.attachment_owners, aid),
        Enum.any?(Attachments.macros([slot]), inside?), into: owned, do: aid
      attachments = Map.filter(state.attachments, fn {_, {aid, _}} -> MapSet.member?(owned, aid) end)
      foreign = for {slot, {aid, _}} <- state.attachments, not MapSet.member?(owned, aid),
        Enum.any?(Attachments.macros([slot]), inside?), do: aid

      cond do
        not Enum.all?(Attachments.macros(Map.keys(attachments)), inside?) ->
          {{:error, :attachment_crosses_boundary}, state}

        foreign != [] ->
          {{:error, {:foreign_attachment, hd(foreign)}}, state}

        true ->
          instances = Map.take(state.instances, MapSet.to_list(ids))
          rows = for row <- Map.values(state.damage), exported_row?(row, inside?, ids, owned), do: row
          definitions = Map.new(Enum.uniq(for {_, i} <- instances, do: i.definition_id), &{&1, definition_bytes(state, &1)})

          {{:ok, %{format: 1, cv: state.cv, seq: state.seq, units_per_micro: state.material_units_per_micro,
              box: {lo, hi}, cells: Map.new(values), refined: refined, macro_owners: macro_owners,
              liquid_units: Map.filter(state.liquid_units, fn {cell, _} -> inside?.(cell) end),
              instances: instances, attachments: attachments,
              attachment_owners: Map.take(state.attachment_owners, MapSet.to_list(owned)),
              property_rows: rows, definitions: definitions}}, state}
      end
    else
      {:error, _} = error -> {error, state}
    end
  end

  @doc "World 调用：同 key 防重后安装；返回 GenServer reply 三元组。"
  def install(state, key, parcel, {_, _, _} = delta) when is_binary(key) and byte_size(key) > 0 do
    rkey = {0, {:parcel, key}}

    case Map.fetch(state.material_supplies, rkey) do
      {:ok, receipt} -> {:reply, {:ok, receipt}, state}
      :error -> install_new(state, rkey, parcel, delta)
    end
  end

  defp install_new(state, rkey, parcel, delta) do
    {lo, hi} = parcel.box
    target = {shift(lo, delta), shift(hi, delta)}
    {{x0, _, z0} = tlo, {x1, y1, z1}} = target
    cells = box_cells(target)
    unknown = parcel |> materials() |> Enum.reject(&Map.has_key?(state.properties.materials, &1))

    with true <- parcel.units_per_micro == state.material_units_per_micro || {:error, :units_mismatch},
         true <- unknown == [] || {:error, {:unknown_materials, unknown}},
         true <- (Edits.valid_edit_coord?(tlo) and Edits.valid_edit_coord?({x1 - 1, y1 - 1, z1 - 1})) || {:error, :invalid_coordinate},
         false <- Protection.overlaps?(state.protection, {x0, z0}, {x1 - 1, z1 - 1}) && {:error, :protected},
         state = Edits.ensure_sources(state, cells) |> warm(target),
         {:ok, removed} <- target_trees(state, target),
         {:ok, state} <- publish_definitions(state, Map.drop(parcel.definitions, Map.keys(state.prefabs))) do
      before = state
      seq = before.seq + 1
      next = Prefabs.clear_subtree(state, removed, Prefabs.subtree_cells(state, removed))

      next = Enum.reduce(cells, next, fn cell, s ->
        s = %{s |> put_macro_owner(cell, nil) |> put_liquid(%{cell => 0}) | placed_by: Map.delete(s.placed_by, cell)}
        value = Map.fetch!(parcel.cells, shift(cell, neg(delta)))
        # 与当前有效值（含生成底图）相同的格不另写 overlay：整园迁入时高处两边同为空气、深处同为岩石，
        # 每格一条会让目标世界白添约千万条 overlay。
        case cell_value(s, 0, cell) do
          {:ok, ^value, s} -> s
          {:ok, _, s} -> Edits.put_overlay(s, 0, cell, value)
        end
      end)

      ids = parcel.instances |> Map.keys() |> Enum.sort() |> Enum.with_index() |> Map.new(fn {id, n} -> {id, {seq, n}} end)
      base = max(next.attachment_serial, before.seq)
      aids = for({_, {aid, _}} <- parcel.attachments, do: aid) |> Enum.uniq() |> Enum.sort() |> Enum.with_index(1)
        |> Map.new(fn {id, n} -> {id, base + n} end)
      micro = map3(delta, &(&1 * @micro))

      next = Enum.reduce(parcel.refined, next, fn {cell, slots}, s ->
        put_refined(s, shift(cell, delta), Map.new(slots, fn {slot, {m, owner}} -> {slot, {m, ids[owner]}} end))
      end)

      next = put_attachments(next, Map.new(parcel.attachments, fn {{kind, axis, p}, {aid, m}} ->
        {{kind, axis, shift(p, micro)}, {aids[aid], m}}
      end))

      next = Enum.reduce(parcel.macro_owners, next, fn {cell, owner}, s -> put_macro_owner(s, shift(cell, delta), ids[owner]) end)
      next = put_liquid(next, Map.new(parcel.liquid_units, fn {cell, q} -> {shift(cell, delta), q} end))

      next = %{next |
        instances: Map.merge(next.instances, Map.new(parcel.instances, fn {id, i} ->
          {ids[id], %{i | anchor: shift(i.anchor, micro), parent_id: Map.get(ids, i.parent_id, {0, 0})} |> Map.put(:placed_by, nil)}
        end)),
        attachment_owners: Map.merge(next.attachment_owners, Map.new(parcel.attachment_owners, fn {aid, {owner, slot}} ->
          {aids[aid], {ids[owner], slot}}
        end)),
        attachment_serial: base + map_size(aids)}

      # 带数量记录的相态宏格：数量随地块，焓按目标环境温度重设（与作者填相同的初态与 phase_authored 账）；
      # 无记录的天然相态地形仍是默认满格、环境温度，不新建记录。
      phase = for {cell, q} <- parcel.liquid_units, {m, _} = parcel.cells[cell], phase_material?(next, m),
        into: %{}, do: {shift(cell, delta), {m, q}}
      capacity = liquid_capacity(next)
      values = Map.new(phase, fn {cell, {m, q}} ->
        {cell, {Phase.energy(%{material: m}, q / capacity, next.properties.materials[m], ambient_at(next, cell)), q * 1.0}}
      end)
      thermal = if next.thermal, do: Enum.reduce(values, next.thermal, fn {_, {energy, integrity}}, t ->
        t |> Map.update(:phase_authored_energy_j, energy, &(&1 + energy))
          |> Map.update(:phase_authored_units, round(integrity), &(&1 + round(integrity)))
      end)
      next = %{next | thermal: thermal}

      rows = for row <- parcel.property_rows, not (row.granularity == 0 and Map.has_key?(phase, shift(Damage.macro(row), delta))),
        do: carried_row(before, next, row, delta, ids, aids)

      receipt = %{seq: seq, source: %{cv: parcel.cv, seq: parcel.seq, box: parcel.box}, delta: delta, box: target,
        cells: length(cells), instances: map_size(ids), removed_instances: MapSet.size(removed),
        attachments: map_size(aids), liquid_cells: map_size(parcel.liquid_units),
        units: units_delta(units(before, cells, target), units(next, cells, target))}

      next = %{next | damage: Map.merge(next.damage, Map.new(rows, &{Damage.key(&1), &1})),
        material_supplies: Map.put(next.material_supplies, rkey, receipt)}

      case Prefabs.prefab_reply(before, next, cells,
             %{material_supplies: %{rkey => receipt}, parcel_phase_values: values, property_states: rows}) do
        {:reply, {:ok, ^seq}, next} -> {:reply, {:ok, receipt}, next}
        {:reply, {:error, reason}, _} -> {:reply, {:error, reason}, before}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # 盒内实例（细化槽与宏格归属的部件及其祖先）整棵树必须在盒内；返回这些树的全部实例身份。
  defp trees(state, refined, macro_owners, inside?, error) do
    owners = for({_, slots} <- refined, {_, {_, owner}} <- slots, do: owner) ++ Map.values(macro_owners)
    roots = for id <- MmoContracts.Voxel.Refined.ancestors(state.instances, Enum.uniq(owners)),
      Map.get(state.instances[id], :parent_id, {0, 0}) == {0, 0}, do: id

    Enum.reduce_while(Enum.sort(roots), {:ok, MapSet.new()}, fn root, {:ok, acc} ->
      tree = Prefabs.subtree_ids(state, root)
      if Enum.all?(Prefabs.subtree_cells(state, tree), inside?),
        do: {:cont, {:ok, MapSet.union(acc, tree)}},
        else: {:halt, {:error, {error, root}}}
    end)
  end

  # 目标盒里要被替换的原有实例：整树在盒内才可清；盒外实例的附件不得伸进盒内。
  defp target_trees(state, box) do
    inside? = &inside?(&1, box)
    refined = for cell <- refined_in_regions(state, regions(box)), inside?.(cell), into: %{}, do: {cell, state.refined[cell]}

    with {:ok, ids} <- trees(state, refined, Map.filter(state.macro_owners, fn {cell, _} -> inside?.(cell) end),
           inside?, :target_instance_crosses_boundary) do
      # 先按盒筛：独立附件（玩家所挂）没有主人记录；盒内的这类附件不随任何被清的树移除，按越界拒绝。
      kept = for {slot, {aid, _}} <- state.attachments, Enum.any?(Attachments.macros([slot]), inside?),
        not removed_with_tree?(state.attachment_owners[aid], ids), do: aid
      if kept == [], do: {:ok, ids}, else: {:error, {:target_attachment_crosses_boundary, hd(kept)}}
    end
  end

  defp removed_with_tree?({owner, _slot}, ids), do: MapSet.member?(ids, owner)
  defp removed_with_tree?(nil, _ids), do: false

  defp exported_row?(%{granularity: g} = row, inside?, _ids, _owned) when g in [0, 1], do: inside?.(Damage.macro(row))
  defp exported_row?(%{granularity: 2, owner: owner}, _inside?, ids, _owned), do: MapSet.member?(ids, owner)
  defp exported_row?(%{incarnation: aid}, _inside?, _ids, owned), do: MapSet.member?(owned, aid)

  # 属性行换到目标身份：坐标平移，部件／附件身份映射，宏格身份取本笔之后的世代；温度按目标环境重设。
  defp carried_row(before, next, row, delta, ids, aids) do
    cell = shift(Damage.macro(row), delta)
    seq = before.seq + 1

    {owner, incarnation} =
      case row.granularity do
        0 ->
          changed = elem(cell_value(before, 0, cell), 1) != elem(cell_value(next, 0, cell), 1) or
            Map.get(before.macro_owners, cell) != Map.get(next.macro_owners, cell)
          {Map.get(next.macro_owners, cell, {0, 0}), if(changed, do: seq, else: Map.get(next.epochs, cell, 0))}

        g when g in [1, 2] ->
          {ids[row.owner], elem(ids[row.owner], 0)}

        _ ->
          {aid, type} = row.owner
          {{aids[aid], type}, aids[aid]}
      end

    row = %{row | micro: shift(row.micro, map3(delta, &(&1 * @micro))), owner: owner, incarnation: incarnation,
      seq: seq, request_id: 0, digest: next.properties.digest}
    if Map.has_key?(row, :temperature_kelvin), do: %{row | temperature_kelvin: ambient_at(next, cell)}, else: row
  end

  # 依赖先于引用者编译；只写 .vxpd（World 重启时 Prefab.load 读取），不进玩家发布列表。
  defp publish_definitions(state, pending) when map_size(pending) == 0, do: {:ok, state}

  defp publish_definitions(state, pending) do
    ready = for {id, bytes} <- pending, {:ok, ^id, compiled} <- [Prefab.compile(bytes, state.prefabs)], do: {id, compiled}

    if ready == [] do
      {:error, :definition_dependencies}
    else
      Enum.each(ready, fn {id, _} ->
        :ok = Prefabs.write_new(Path.join(state.prefab_dir, Base.encode16(id, case: :lower) <> ".vxpd"), pending[id])
      end)
      publish_definitions(%{state | prefabs: Map.merge(state.prefabs, Map.new(ready))}, Map.drop(pending, Enum.map(ready, &elem(&1, 0))))
    end
  end

  defp definition_bytes(state, id) do
    case Enum.find(state.published, &(&1.id == id)) do
      %{bytes: bytes} -> bytes
      nil ->
        bytes = Prefab.encode(state.prefabs[id].definition)
        ^id = :crypto.hash(:sha256, bytes)
        bytes
    end
  end

  defp materials(parcel) do
    (for({_, {m, _}} <- parcel.cells, do: m) ++ for({_, slots} <- parcel.refined, {_, {m, _}} <- slots, do: m) ++
      for({_, {_, m}} <- parcel.attachments, do: m))
    |> Enum.uniq() |> Enum.reject(&(&1 == 0))
  end

  # 盒内材料量（宏格按有限数量、细化槽、附件槽）；回执记安装前后的净差，供作者安装记账。
  # 盒内 L0 区域先解码进缓存：之后 `before`／`next` 都带着它，回执的材料差额与属性行逐格读当前值时不再每格现场生成并解码整个区域
  # （320 万格的如园分批安装曾因此卡在 GeneratedStore.read 上）。
  defp warm(state, box) do
    Enum.reduce(regions(box), state, fn region, s ->
      case decoded(s, 0, region) do
        {:ok, _, s} -> s
        {:error, _, s} -> s
      end
    end)
  end

  defp units(state, cells, box) do
    capacity = liquid_capacity(state)
    acc = Enum.reduce(cells, %{}, fn cell, acc ->
      acc = case cell_value(state, 0, cell) do
        {:ok, {0, _}, _} -> acc
        {:ok, {m, _}, _} -> Map.update(acc, m, Map.get(state.liquid_units, cell, capacity), &(&1 + Map.get(state.liquid_units, cell, capacity)))
      end
      Enum.reduce(Map.get(state.refined, cell, %{}), acc, fn {_, {m, _}}, acc ->
        Map.update(acc, m, state.material_units_per_micro, &(&1 + state.material_units_per_micro))
      end)
    end)
    Enum.reduce(state.attachments, acc, fn {{_, _, p} = slot, {_, m}}, acc ->
      if inside?(map3(p, &Integer.floor_div(&1, @micro)), box) do
        n = Attachments.units([slot], state.properties)
        Map.update(acc, m, n, &(&1 + n))
      else
        acc
      end
    end)
  end

  defp units_delta(old, new),
    do: Map.merge(Map.new(old, fn {m, n} -> {m, -n} end), new, fn _, a, b -> a + b end) |> Map.reject(fn {_, n} -> n == 0 end)

  defp box_cells({{x0, y0, z0}, {x1, y1, z1}}),
    do: for(x <- x0..(x1 - 1)//1, y <- y0..(y1 - 1)//1, z <- z0..(z1 - 1)//1, do: {x, y, z})

  defp regions({{x0, y0, z0}, {x1, y1, z1}}),
    do: for(x <- floor_div(x0, 64)..floor_div(x1 - 1, 64)//1, y <- floor_div(y0, 64)..floor_div(y1 - 1, 64)//1,
      z <- floor_div(z0, 64)..floor_div(z1 - 1, 64)//1, do: {x, y, z})

  defp inside?({x, y, z}, {{x0, y0, z0}, {x1, y1, z1}}),
    do: x >= x0 and x < x1 and y >= y0 and y < y1 and z >= z0 and z < z1

  defp shift({x, y, z}, {dx, dy, dz}), do: {x + dx, y + dy, z + dz}
  defp neg(p), do: map3(p, &(-&1))
  defp map3({x, y, z}, f), do: {f.(x), f.(y), f.(z)}
end
