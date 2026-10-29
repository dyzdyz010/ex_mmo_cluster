defmodule VoxelRegion.World.Closure do
  @moduledoc """
  全局系统功能（M2b 读取闭包，`m2b-on-demand-pages.md` §2.2）：World 入口裁决前要驻留的页。

  `needs(state, message)` 只按当前状态与消息求“种子”——区域键（`{level, region}`，装页时各扩同级 26 邻页）与只带 id 的身份；
  整棵实例树由装页接纳（`Pages.adopt/4`）按驻留闭合补齐，不在这里展开。返回 `:none`（不读页）、`:all`（读整表的维护入口）
  或 `{keys, ids}`。键沿用各入口既有的预备键（`edit_keys`、`tool_regions`、`intent_keys`、prefab 足迹、窗口盒），只是改在 World 内求，
  这样接纳时按当前状态重算即是父稿 P4 的“按依赖版本复核”；P1仅按仍有owner的需求保留驻留。
  """
  alias VoxelRegion.{Attachments, CollisionSource}
  alias VoxelRegion.World.{Edits, Pages, Prefabs, Tools}
  import VoxelRegion.World.Canonical, only: [region_of: 1]

  @doc "开发期登记的 World 消息形状，区分页需求与显式无页；原子长度为 0，任务引用为 `:reference`。"
  def registered_entries do
    page = [
      {:prepare, 2}, {:adopt_liquid, 2}, {:prepare_intent, 2}, {:prepared_intent, 4},
      {:publish_properties, 2}, {:publish_parameters, 3}, {:thermal_experiment, 2},
      {:sight_snapshot, 3}, {:material_snapshot, 3}, {:material_snapshot, 4}, {:simulation_snapshot, 3},
      {:liquid_experiment, 2}, {:spell_intent, 3}, {:body_tool, 4}, {:gm, 4}, {:gm, 5},
      {:parcel_export, 2}, {:parcel_install, 5}, {:beacon_install, 3}, {:liquid_fill, 7},
      {:production_intent, 3}, {:attachment_intent, 3}, {:tool_intent, 3}, {:instance_cells, 2}, {:gm_prepare, 3},
      {:replacement_cells, 3}, {:place_prefab, 5}, {:prefab_intent, 5}, {:remove_prefab, 2},
      {:replace_prefab, 3}, {:serve_item, 3}, {:apply_edit, 3}, {:canonical_snapshot, 5}, {:canonical_snapshot, 6},
      {:replica_snapshot, 3}, {:apply_edits, 2}, {:reference, 2}, {:body_contact, 4},
      {:body_death, 3}, {:quote_cast, 4}, {:prepare_cast, 5}, {:authorize_cast, 4},
      {:prepare_beacon, 4}, {:commit_beacon, 4}, {:liquid_commit, 0}, {:thermal_commit, 0}
    ]

    none = [
      {:page_need, 4}, {:page_need, 5}, {:page_stage, 5}, {:page_commit, 2},
      {:page_yield, 3}, {:page_adopt, 4}, {:page_resident_all, 0}, {:content_version, 0},
      {:seq, 0}, {:simulation_windows, 0}, {:simulation_windows, 2}, {:interactions_since, 2}, {:admission_status, 0}, {:retry_simulation_io, 0},
      {:liquid_activity, 0}, {:source, 0}, {:author_regions, 2}, {:magic_range, 0},
      {:magic_digest, 0}, {:caster_state, 2}, {:send_caster_state, 4}, {:tool_range, 2},
      {:tool_definition, 2}, {:material_balances, 2}, {:material_supply, 4}, {:beacon_directory, 2},
      {:publish_prefabs, 2}, {:prefab_catalog, 0}, {:published_prefab_metadata, 0}, {:material_catalog, 0},
      {:parcel_prepare, 2}, {:prefab_request, 2}, {:prefab_inputs, 3}, {:prefab_loaded, 4}, {:prefab_ready, 3}, {:prefab_known, 3},
      {:publish_prefab, 4}, {:stats, 0}, {:residency_status, 0}, {:maintain_residency, 0}, {:subscribe, 5},
      {:entries_after, 2}, {:window_input, 2}, {:window_finished, 4}, {:window_geometry, 3},
      {:compact, 0}, {:timeout, 3}, {:projectile_tick, 0}, {:thermal_tick, 0}, {:thermal_tick, 2}, {:input_continue, 0}, {:retry_death_drop, 2},
      {:liquid_tick, 2}, {:body_detach, 4}, {:body_coherence, 5},
      {:cancel_cast, 3}, {:thermal_step, 2}, {:DOWN, 5},
      {:simulation_windows, 4}
    ]

    %{page: page, none: none}
  end

  @doc "消息的读取闭包种子：`:none`、`:all` 或 `{扩 26 邻页的区域键, 只装本页的区域键, 身份}`。"
  def needs(state, message) do
    case seeds(state, message) do
      {keys, ids} -> {keys, [], ids}
      other -> other
    end
  end

  # 读整张属性 / 热表的维护入口（目录与参数发布、热实验）：装全部有行的页（父稿 P7 允许 O(范围)）。
  defp seeds(_state, {tag, _}) when tag in [:publish_properties, :thermal_experiment], do: :all
  defp seeds(_state, {:publish_parameters, _, _}), do: :all

  # 预备之后的有限液体接纳（`adopt_liquid_regions`）会提交液体：L0 键带粗层祖页。
  defp seeds(_state, {:prepare, keys}), do: {Pages.with_ancestors(keys), []}
  defp seeds(_state, {:adopt_liquid, regions}), do: {Pages.with_ancestors(Enum.map(regions, &{0, &1})), []}
  defp seeds(state, {:prepare_intent, message}), do: intent(state, message)
  defp seeds(_state, {:prepared_intent, keys, _message, _decoded}), do: {keys, []}
  defp seeds(_state, {:serve_item, _version, %{level: level, region: region}}), do: {[{level, region}], []}
  defp seeds(_state, {:canonical_snapshot, box, _pid, _request, _chunks}), do: box(box)
  defp seeds(_state, {:canonical_snapshot, box, _pid, _request, _chunks, _token}), do: box(box)
  defp seeds(_state, {:replica_snapshot, box, _pid}), do: box(box)
  defp seeds(_state, {:apply_edit, coord, _material}), do: {Edits.edit_keys([coord]), []}
  defp seeds(_state, {:apply_edits, edits}), do: {Edits.edit_keys(Enum.map(edits, &elem(&1, 0))), []}
  defp seeds(_state, {:liquid_experiment, edits}), do: {Edits.edit_keys(Enum.map(edits, &elem(&1, 0))), []}
  defp seeds(_state, {:liquid_fill, _cid, _key, _material, seed, _level, _max}), do: {Edits.edit_keys([seed]), []}
  defp seeds(state, :liquid_commit) do
    {:ok, needs} = VoxelRegion.World.Liquids.residency_dependencies(state)
    needs
  end
  # 显式热步与液体步同为已到达的物理输入：步前读取集即热 owner 的唯一种子投影（含祖页），缺页挂闸后重放。
  defp seeds(state, :thermal_commit), do: {VoxelRegion.World.Thermal.seed_keys(state), []}
  # 只读快照不物化区域载荷（不读 ring）：只要盒 / 格 / 射线范围内的页本身。
  defp seeds(_state, {:material_snapshot, _characters, cells}), do: exact(cells(cells))
  defp seeds(_state, {:material_snapshot, _characters, cells, _detail}), do: exact(cells(cells))
  defp seeds(_state, {:simulation_snapshot, _characters, box}), do: exact(box(box))

  defp seeds(_state, {:sight_snapshot, origin, rays}) do
    range = rays |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    {[], Tools.tool_regions(%{eye: origin}, range), []}
  end

  defp seeds(state, {:tool_intent, _actor, _request} = message), do: intent(state, message)
  defp seeds(state, {:production_intent, _actor, _request} = message), do: intent(state, message)

  defp seeds(state, {:attachment_intent, actor, request}) do
    cells = Attachments.macros(Attachments.footprint(request.kind, request.axis, request.anchor, request.size))

    case Tools.tool_range(state, request.tool_id) do
      range when is_number(range) -> {Tools.tool_regions(actor, range) ++ Edits.edit_keys(cells), []}
      _ -> {Edits.edit_keys(cells), []}
    end
  end

  defp seeds(_state, {:body_tool, actor, _request, distance}), do: {Tools.tool_regions(actor, distance), []}
  defp seeds(state, {:spell_intent, actor, %{action: 1}}), do: magic(state, actor)
  defp seeds(state, {:place_prefab, _id, anchor, orientation, geometry}), do: definition(state, geometry, anchor, orientation)

  defp seeds(state, {:prefab_intent, _actor, :voxel_prefab_place_v1, r, geometry}), do: definition(state, geometry, r.anchor, r.orientation)
  defp seeds(state, {:prefab_intent, _actor, :voxel_prefab_remove_v1, r, _geometry}), do: tree(state, r.instance_id)
  defp seeds(state, {:prefab_intent, _actor, :voxel_prefab_replace_v1, r, geometry}), do: replacement(state, r.instance_id, geometry)
  defp seeds(state, {:remove_prefab, id}), do: tree(state, id)
  defp seeds(state, {:replace_prefab, id, definition}), do: replacement(state, id, definition)
  defp seeds(state, {:instance_cells, id}), do: tree(state, id)
  defp seeds(state, {:gm_prepare, key, args}) do
    with :ready <- VoxelRegion.World.Gm.preflight(state, key),
         {:ok, id} <- VoxelRegion.World.Gm.move_reference(args), do: tree(state, id), else: (_ -> :none)
  end
  defp seeds(state, {:replacement_cells, id, definition}), do: replacement(state, id, definition)

  defp seeds(state, {:gm, _key, :move_instance, args, geometry}) do
    {keys, ids} = tree(state, args.instance)
    case definition(state, geometry, args.anchor, args.orientation) do
      {more, _} -> {keys ++ more, ids}
      :none -> {keys, ids}
    end
  end

  defp seeds(state, {:gm, _key, op, args}) do
    case op do
      op when op in [:clear, :fill] -> {Edits.edit_keys(VoxelRegion.World.Gm.macros(args)), []}
      :liquid_fill -> {Edits.edit_keys([args.seed]), []}
      :drain -> box_macros(args.box)
      :recolor ->
        case VoxelRegion.World.Gm.recolor_cells(args) do
          {:ok, cells} -> {Edits.edit_keys(cells), []}
          {:error, _} -> :none
        end

      _ -> :none
    end
  end

  defp seeds(_state, {:parcel_export, box}), do: box_macros(box)

  defp seeds(_state, {:parcel_install, _key, %{box: {lo, hi}}, delta, _definitions}),
    do: box_macros({shift(lo, delta), shift(hi, delta)})

  defp seeds(state, {:beacon_install, _key, %{core: core}}), do: micro(state, [core])

  # 异步消息（Player / Scene 发来，经 handle_info）。
  defp seeds(state, {:prepare_cast, _key, actor, %{action: 1}, _from}), do: magic(state, actor)
  defp seeds(state, {:quote_cast, actor, _request, _from}), do: magic(state, actor)
  defp seeds(state, {:prepare_beacon, _key, _actor, %{from: from, to: to}}), do: beacons(state, [from, to])
  defp seeds(state, {:commit_beacon, _key, _actor, %{to: to}}), do: beacons(state, [to])
  defp seeds(_state, {:body_contact, _cid, _pid, %{feet: feet}}), do: {[{0, region_of(meters(feet))}], []}
  defp seeds(_state, {:body_death, _cid, feet}), do: {Edits.edit_keys([meters(feet)]), []}
  # 已取消 / 已结算的旧授权在入口是空操作，不读页；否则前摇取消后施法区域已退休，旧授权会白白起一个冷装页任务。
  # 同序排队先于闭包（`PageLoad.held?/2`），挂起中的准备之后到达的授权仍排在其后，不会因这里返回 :none 越过它。
  defp seeds(state, {:authorize_cast, key, actor, _request}) do
    if VoxelRegion.World.Casting.authorized_pending(state, key, actor), do: magic(state, actor), else: :none
  end

  # 投射物采样结果：飞行段两端所在区域（`Projectiles.apply_result/4` 沿段求交）。
  defp seeds(state, {ref, results}) when is_reference(ref) do
    semblances = VoxelRegion.World.Thermal.semblances(state)

    keys =
      for {id, _age, {:sample, age, _actor, _target, _at}} <- results, s = Map.get(semblances, id), s != nil,
          {_, _, a, b} <- VoxelRegion.Magic.Semblance.flight_segments(s, age), point <- [a, b], uniq: true,
          do: {0, region_of(meters(point))}

    {Pages.with_ancestors(keys), []}
  end

  defp seeds(_state, _message), do: :none

  defp exact({keys, ids}), do: {[], keys, ids}

  defp intent(state, message) do
    case Tools.intent_keys(state, message) do
      {:ok, keys} -> {keys, []}
      _ -> :none
    end
  end

  defp magic(state, actor) do
    case state.magic do
      # 施法会提交（扣能、作用格、走火落地）：射程区域带粗层祖页。
      %{range_m: range} -> {Pages.with_ancestors(Tools.tool_regions(actor, range)), []}
      _ -> :none
    end
  end

  defp box(box), do: {Enum.map(CollisionSource.regions(box), &{0, &1}), []}
  defp cells(cells), do: {Enum.uniq(Enum.map(cells, &{0, region_of(&1)})), []}
  defp footprint(cells), do: Edits.edit_keys(Prefabs.footprint_macros(cells))

  # 半开宏格盒的全部各级区域（地块导出 / 安装、排水）。
  defp box_macros({{x0, y0, z0}, {x1, y1, z1}}) do
    corners = for x <- [x0, x1 - 1], y <- [y0, y1 - 1], z <- [z0, z1 - 1], do: {x, y, z}
    keys = Edits.edit_keys(corners)

    full =
      for level <- 0..5, regions = Enum.filter(keys, &(elem(&1, 0) == level)) |> Enum.map(&elem(&1, 1)),
          {lx, ly, lz} = Enum.min(regions), {hx, hy, hz} = Enum.max(regions),
          x <- lx..hx, y <- ly..hy, z <- lz..hz, do: {level, {x, y, z}}

    {full, []}
  end

  defp shift({x, y, z}, {dx, dy, dz}), do: {x + dx, y + dy, z + dz}

  defp definition(_state, geometry, anchor, orientation) do
    case Prefabs.definition_cells(geometry, anchor, orientation) do
      {:ok, _cells, macros} -> {Edits.edit_keys(macros), []}
      _ -> :none
    end
  end

  # 按 id 的入口：内存里有就取整树的格（树已驻留闭合），否则交装页查定位表（父稿 P1 身份定位表）。
  defp tree(state, id) do
    if Pages.tree_complete?(state, id),
      do: {Edits.edit_keys(Prefabs.owner_cells(state, id)), []},
      else: {[], [id]}
  end

  defp replacement(state, id, definition) do
    case Map.fetch(state.instances, id) do
      {:ok, instance} ->
        {keys, _} = tree(state, id)
        case definition(state, definition, instance.anchor, instance.orientation) do
          {more, _} -> {keys ++ more, []}
          :none -> {keys, []}
        end

      :error ->
        {[], [id]}
    end
  end

  defp beacons(state, ids) do
    cores = for id <- ids, {:ok, beacon} <- [Map.fetch(state.beacons, id)], do: beacon.core
    micro(state, cores)
  end

  defp micro(_state, points), do: {Edits.edit_keys(Enum.map(points, &elem(VoxelRegion.Prefab.macro_slot(&1), 0))), []}

  defp meters({x, y, z}), do: {floor(x), floor(y), floor(z)}
end
