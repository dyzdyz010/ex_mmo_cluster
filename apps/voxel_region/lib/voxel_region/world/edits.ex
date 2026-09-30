defmodule VoxelRegion.World.Edits do
  @moduledoc """
  全局系统功能：逐格编辑批次：overlay 写入、逐级规约与父格去重、宏格载荷刷新。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.Attachments
  require Logger
  import Bitwise
  alias VoxelRegion.Damage
  alias VoxelRegion.Reducer
  alias VoxelRegion.Liquid
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.World.Thermal
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Payloads, Observation, Log, Prefabs, Tools, Production, Phases, Liquids, AttachmentOps}

  @max_level 5

  def valid_region?({x, y, z}, step) when is_integer(x) and is_integer(y) and is_integer(z) do
    Enum.all?([x, y, z], fn value ->
      min = (value * 64 - 1) * step - 4
      max = (value * 64 + 65) * step - 1 + 4
      min >= -2_147_483_648 and max <= 2_147_483_647
    end)
  end

  def valid_region?(_, _), do: false

  def valid_edit_coord?({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z) do
    Enum.all?(0..@max_level, fn level ->
      step = 1 <<< level
      cell = {floor_div(x, step), floor_div(y, step), floor_div(z, step)}
      valid_region?(region_of(cell), step)
    end)
  end

  def valid_edit_coord?(_), do: false

  def edit_keys(coords) do
    for {x, y, z} <- coords, level <- 0..@max_level do
      step = 1 <<< level
      {level, region_of({floor_div(x, step), floor_div(y, step), floor_div(z, step)})}
    end
  end

  # ---- 真值

  def parent_of({x, y, z}), do: {floor_div(x, 2), floor_div(y, 2), floor_div(z, 2)}

  def do_apply_edit(state, coord, material) do
    old_seq = state.seq

    case apply_batch(state, [{coord, material}], true) do
      {:ok, state} when state.seq == old_seq -> {:ok, :noop, state}
      {:ok, state} -> {:ok, Map.fetch!(state.entries, state.seq), state}
      error -> error
    end
  end

  def put_overlay(state, level, cell, value) do
    if Map.get(state.overlay, {level, cell}) == value do
      state
    else
      regions = Payloads.region_keys([{level, cell}])

      Enum.reduce(
        regions,
        %{state | overlay: Map.put(state.overlay, {level, cell}, value)},
        fn key, state ->
          %{
            Payloads.cache_delete(state, key)
            | overlay_regions:
                Map.update(state.overlay_regions, key, MapSet.new([cell]), &MapSet.put(&1, cell))
          }
        end
      )
    end
  end

  def apply_batch(
         state,
         edits,
         legacy \\ false,
         settlement \\ %{},
         removed_owners \\ MapSet.new(),
         removed_attachments \\ MapSet.new()
       ) do
    before = state
    started = System.monotonic_time(:microsecond)
    {phase_values, settlement} = Map.pop(settlement, :phase_values, %{})
    {liquid_changes, settlement} = Map.pop(settlement, :liquid_changes, %{})
    {liquid_wake, settlement} = Map.pop(settlement, :liquid_wake, true)
    {placed, settlement} = Map.pop(settlement, :placed, %{})

    liquid_dirty = Enum.map(Map.keys(liquid_changes), &{0,&1})
    state = %{state | liquid_units: Liquid.apply_changes(state.liquid_units, liquid_changes)}

    removed_slots =
      for {slot, {id, _}} <- state.attachments, MapSet.member?(removed_attachments, id), do: slot

    state = %{state | attachments: Map.drop(state.attachments, removed_slots)}

    removed_cells =
      if MapSet.size(removed_owners) == 0, do: [], else: micro_owner_cells(state, removed_owners)

    state =
      if removed_cells == [],
        do: state,
        else:
          Prefabs.clear_subtree(state, removed_owners, removed_cells)
          |> then(fn s ->
            %{s | instances: Map.take(s.instances, Payloads.live_instance_ids(s.refined, s.instances, s.macro_owners))}
          end)

    # 地面花草失去支撑即消失：下方格变成不挡移动的材质（挖空、液体、花草）时，同一事务里清掉上面的花草。
    with {:ok,unsupported,state} <-
      Enum.reduce_while(edits, {:ok,[],state}, fn {{x, y, z}, m}, {:ok,found,s} ->
        above = {x, y + 1, z}

        if MmoContracts.VoxelMaterialCatalog.blocks_movement?(m) or List.keymember?(edits, above, 0) or is_map_key(s.refined, above) do
          {:cont,{:ok,found,s}}
        else
          case cell_value(s,0,above) do
            {:ok,{top,_},s} ->
              {:cont,{:ok,if(MmoContracts.VoxelMaterialCatalog.flora?(top),do: [{above,0}|found],else: found),s}}
            {:error,:missing,_} -> {:halt,{:error,:missing_region}}
          end
        end
      end) do

    edits = edits ++ unsupported
    legacy = legacy and unsupported == []

    # 概率掉落：这一笔里被销毁 / 替换 / 失去支撑的、带掉落表的格，按表发给造成它的人（攻击者或放置者）；
    # 没有操作者（作者入口、液体、热）就直接消失。骰子由 (世界, 事务序号, 格, 表项) 决定，重放同一笔结果相同。
    drop_cid = settlement[:recovery_cid] || (placed |> Map.values() |> List.first())

    {state, settlement} =
      if drop_cid == nil do
        {state, settlement}
      else
        Enum.reduce(edits, {state, settlement}, fn {cell, m}, {s, paid} ->
          with false <- is_map_key(s.refined, cell),
               {:ok, {old, _}, s} when old != m <- cell_value(s, 0, cell),
               [_ | _] = table <- Production.drop_table(s, old) do
            table
            |> Enum.with_index()
            |> Enum.filter(fn {d, i} -> Production.drop_roll(s, cell, i) < d["probability"] end)
            |> Enum.reduce({s, paid}, fn {d, _}, {s, paid} ->
              {s, granted} = Production.settle_material(s, drop_cid, d["material_id"], d["units"])
              {s, Map.update(paid, :material_balances, granted.material_balances, &Map.merge(&1, granted.material_balances))}
            end)
          else
            {:ok, _, s} -> {s, paid}
            _ -> {s, paid}
          end
        end)
      end

    result =
      Enum.reduce_while(Map.new(edits), {Enum.map(removed_cells, &{0, &1}), state}, fn {cell, m},
                                                                                       {changed,
                                                                                        s} ->
        case if(Map.has_key?(s.refined, cell),
               do: {:error, :refined_cell, s},
               else: cell_value(s, 0, cell)
             ) do
          {:ok, {old, _}, s} when old == m ->
            {:cont, {changed, s}}

          {:ok, _, s} ->
            s = %{s | macro_owners: Map.delete(s.macro_owners,cell),
              placed_by: Production.merge_placed(s.placed_by,%{cell => Map.get(placed,cell)})}
            {:cont,
             {[{0, cell} | changed],
              put_overlay(s, 0, cell, {m, MmoContracts.Voxel.Skins.uniform(m)})}}

          {:error, :missing, _} ->
            {:halt, {:error, :missing_region}}

          {:error, reason, _} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, reason} ->
        {:error, reason}

      {[], state} when map_size(liquid_changes) == 0 ->
        cond do
          removed_slots != [] -> AttachmentOps.commit_attachment(before, state, removed_slots, settlement)
          Map.has_key?(settlement, :liquid_falls) ->
            next = %{state | seq: state.seq + 1}
            txn = %{seq: next.seq, entries: [], coarse: [], liquid_falls: settlement.liquid_falls}
            with :ok <- Log.append_log(next, txn) do
              next = Log.remember_entry(next, txn)
              Observation.fanout(next, txn)
              Observation.fanout_canonical(next, txn, [], [], before)
              {:ok, next}
            end
          true -> {:ok, state}
        end

      {geometry_changed, state} ->
        state = %{state | instances: Map.take(state.instances,Payloads.live_instance_ids(state.refined,state.instances,state.macro_owners))}
        # 换了材料却没有随笔数量的格（挖掉、热毁、作者覆盖）不再是那份有限量：删除其数量记录（R8-07）。
        stale = for {0, cell} <- geometry_changed, not Map.has_key?(liquid_changes, cell),
          Map.has_key?(state.liquid_units, cell), do: cell
        state = %{state | liquid_units: Map.drop(state.liquid_units, stale)}
        liquid_dirty = liquid_dirty ++ Enum.map(stale, &{0, &1})
        changed = Enum.uniq(geometry_changed ++ liquid_dirty)
        state = if liquid_wake, do: Liquids.wake_liquid(state, Enum.map(changed, &elem(&1,1))), else: state
        # Quantity-only changes require a new seq and full owner/ring afterimages,
        # but never a fresh solid identity, HP invalidation or collision edit.
        case reduce_batch(
               state,
               AttachmentOps.attachment_dirty(
                 state,
                 Enum.map(geometry_changed, &elem(&1, 1)) ++ Attachments.macros(removed_slots)
               ),
               1,
               geometry_changed,
               0
             ) do
          {:error, reason} ->
            {:error, reason}

          {:ok, all, state, visits} ->
            reduced = System.monotonic_time(:microsecond)

            {state, attachment_keys, settlement} =
              AttachmentOps.prune_attachments(before, state, Enum.map(geometry_changed, &elem(&1, 1)), settlement)

            state = %{state | seq: state.seq + 1}
            state = refresh_macro_payloads(before, state, geometry_changed)
            cached = System.monotonic_time(:microsecond)
            terrain_payloads = Map.merge(before.payloads, state.payloads)

            {state, _structure_keys, structure_cells} =
              Payloads.refresh_structure(
                state,
                Enum.uniq(Enum.map(geometry_changed, &elem(&1, 1)) ++ Attachments.macros(removed_slots))
              )

            afterimage_keys =
              Enum.uniq(
                attachment_keys ++
                  Payloads.region_keys(Enum.map(removed_cells, &{0, &1})) ++ Payloads.region_keys(liquid_dirty)
              )

            structured = System.monotonic_time(:microsecond)
            legacy = legacy and afterimage_keys == [] and structure_cells == []

            {txn, state} =
              if legacy do
                [{coord, material}] = edits

                coarse =
                  for {level, cell} <- Enum.sort(all), level > 0 do
                    {m, skins} = Map.fetch!(state.overlay, {level, cell})
                    %{level: level, cell: cell, material: m, skins: skins}
                  end

                {%{seq: state.seq, coord: coord, material: material, coarse: coarse}, state}
              else
                # afterimage 已包含该 core 的地形与结构；选择前排除，避免完整编码两次。
                covered = MapSet.new(afterimage_keys)

                sparse =
                  Enum.reject(all, fn {level, cell} ->
                    MapSet.member?(covered, {level, region_of(cell)})
                  end)

                Log.select_transaction(state, sparse)
              end

            {txn, state} =
              if legacy do
                {txn, state}
              else
                {afterimages, state} =
                  Payloads.region_afterimages(state, afterimage_keys, terrain_payloads, all)

                {%{txn | entries: txn.entries ++ afterimages ++ Payloads.structure_entries(state, structure_cells)}, state}
              end

            # 随笔搬运值覆盖的有限宏格：其热与燃料已随数量搬走或结算，清空时不再记为移除。
            carried = for {key, %{granularity: 0} = t} <- before.damage,
              Map.has_key?(phase_values, Damage.macro(t)), into: MapSet.new(), do: key

            {state, metadata} =
              Tools.damage_geometry(before, state, Enum.map(geometry_changed, &elem(&1, 1)), Enum.map(geometry_changed, &elem(&1, 1)), carried)

            {state, phase_rows} = Phases.put_phase_values(state, phase_values)
            metadata = Map.update!(metadata, :property_states, &(&1 ++ phase_rows))
            if_phase_dirty = Map.keys(phase_values) |> Enum.flat_map(&[&1 | VoxelRegion.Thermal.neighbors(&1)])
            state = Thermal.drop_geometry(state, if_phase_dirty)
            metadata = if state.thermal, do: Map.put(metadata,:thermal,state.thermal), else: metadata
            imaged = System.monotonic_time(:microsecond)
            txn = Map.merge(txn, metadata) |> Map.merge(settlement)
              |> Production.ownership_metadata(before,state,Enum.map(geometry_changed,&elem(&1,1)))

            txn =
              if Map.has_key?(settlement, :property_states),
                do:
                  Map.put(
                    txn,
                    :property_states,
                    Map.new(
                      settlement.property_states ++ metadata.property_states,
                      &{Damage.key(&1), &1}
                    )
                    |> Map.values()
                  ),
                else: txn

            with {:ok, collision_chunks} <- Observation.canonical_changes(before, state, Enum.uniq(geometry_changed ++
                   Enum.filter(liquid_dirty,fn {0,c}->
                     {:ok,{m,_},_}=cell_value(state,0,c); MmoContracts.VoxelMaterialCatalog.blocks_movement?(m)
                   end))),
                 collided = System.monotonic_time(:microsecond),
                 :ok <- Log.append_log(state, txn) do
              appended = System.monotonic_time(:microsecond)
              state = Log.remember_entry(state, txn)
              Observation.fanout(state, txn)

              Observation.fanout_canonical(
                state,
                txn,
                collision_chunks,
                Payloads.region_keys(changed) ++ attachment_keys,
                before
              )

              Logger.info(
                "voxel_macro_stages seq=#{state.seq} reduce_us=#{reduced - started} l0_cache_us=#{cached - reduced} structure_us=#{structured - cached} regions_us=#{imaged - structured} collision_us=#{collided - imaged} log_us=#{appended - collided} fanout_us=#{System.monotonic_time(:microsecond) - appended}"
              )

              region_count = Enum.count(Map.get(txn, :entries, []), &Map.has_key?(&1, :payload))

              Logger.info(
                "voxel_region transaction seq=#{state.seq} canonical=#{length(changed)} reduced=#{visits} changed=#{length(all)} regions=#{region_count} structure_cells=#{length(structure_cells)} bytes=#{IO.iodata_length(if legacy, do: Codec.encode_entry(txn), else: Codec.encode_transaction(txn))} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
              )

              {:ok, Liquids.schedule_liquid(state)}
            end
        end
    end
    end
  end

  def needs_source?(state, key),
    do: not Map.has_key?(state.region_bases, key) and not Map.has_key?(state.decoded, key)

  # 宏格编辑已排除refined cell，故L0细节后缀未变；仅更新已有热缓存，冷缺失仍由真值物化。
  def refresh_macro_payloads(before, state, changed) do
    Enum.reduce(Enum.uniq(Payloads.region_keys(changed)), state, fn {0, region} = key, s ->
      case Map.fetch(before.payloads, key) do
        {:ok, {prior, _}} ->
          materials =
            for {0, cell} <- changed,
                local = Payload.local(region, cell),
                Payload.in_span?(local),
                into: %{},
                do: {local, elem(Map.fetch!(s.overlay, {0, cell}), 0)}

          bytes = Payload.replace_uniform_cells(prior, materials, s.seq, s.cv)
          {:ok, header} = Codec.decode_payload_header(bytes)
          Payloads.cache_put(s, key, bytes, header)

        :error ->
          s
      end
    end)
  end

  def reduce_batch(state, [], _level, all, visits), do: {:ok, all, state, visits}

  def reduce_batch(state, _dirty, level, all, visits) when level > @max_level,
    do: {:ok, all, state, visits}

  def reduce_batch(state, dirty, level, all, visits) do
    parents = dirty |> Enum.map(fn {_, c} -> parent_of(c) end) |> Enum.uniq()
    faces = if level == 1, do: Attachments.l1_faces(state.attachments, parents), else: %{}

    result =
      Enum.reduce_while(parents, {[], state}, fn parent, {changed, s} ->
        case child_values(s, level, parent) do
          {:ok, children, s} ->
            case cell_value(s, level, parent) do
              {:ok, old, s} ->
                {material, skins} = Reducer.reduce_cell(children, level)

                {skins, s} =
                  if level == 1 do
                    Attachments.project_l1(
                      parent,
                      skins,
                      Map.get(faces, parent, []),
                      fn micro, world ->
                        {target, world} = target_at(micro, world)
                        {if(target, do: target.material, else: 0), world}
                      end,
                      s
                    )
                  else
                    {skins, s}
                  end

                new = {material, skins}

                next =
                  if new == old,
                    do: {changed, s},
                    else: {[{level, parent} | changed], put_overlay(s, level, parent, new)}

                {:cont, next}

              {:error, :missing, s} ->
                Logger.warning(
                  "voxel_region: L#{level} around #{inspect(parent)} not baked; reduce chain stops here"
                )

                {:cont, {changed, s}}

              {:error, reason, _s} ->
                {:halt, {:error, reason}}
            end

          {:error, :missing, s} ->
            Logger.warning(
              "voxel_region: L#{level} around #{inspect(parent)} not baked; reduce chain stops here"
            )

            {:cont, {changed, s}}

          {:error, reason, _s} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, reason} ->
        {:error, reason}

      {changed, state} ->
        reduce_batch(state, changed, level + 1, changed ++ all, visits + length(parents))
    end
  end

  def child_values(state, level, {px, py, pz}) do
    result =
      Enum.reduce_while(0..7, {[], state}, fn oct, {children, s} ->
        cell = {px * 2 + (oct &&& 1), py * 2 + (oct >>> 1 &&& 1), pz * 2 + (oct >>> 2 &&& 1)}

        case cell_value(s, level - 1, cell) do
          {:ok, value, s} -> {:cont, {[value | children], s}}
          {:error, reason, s} -> {:halt, {:error, reason, s}}
        end
      end)

    case result do
      {:error, reason, state} -> {:error, reason, state}
      {children, state} -> {:ok, Enum.reverse(children), state}
    end
  end
end
