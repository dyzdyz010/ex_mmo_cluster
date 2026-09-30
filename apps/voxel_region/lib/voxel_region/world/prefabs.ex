defmodule VoxelRegion.World.Prefabs do
  @moduledoc """
  全局系统功能：预制件：定义取格、对齐、放置树、部件子树、支付与回执、目录持久化。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.Attachments
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.Prefab
  alias VoxelRegion.{Liquid, Phase}
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Payloads, Observation, Log, Edits, Tools, Production, Phases, Liquids, AttachmentOps, HeatCommit}

  @micro VoxelRegion.Spatial.micro_resolution()

  def definition_cells(state, id, anchor, orientation) do
    with {:ok, definition} <- Map.fetch(state.prefabs, id), true <- orientation in 0..23,
         :ok <- prefab_alignment(definition, anchor) do
      # Callers use these samples to prepare/check macro bounds, never as micro volume.
      cells = Prefab.footprint(definition, anchor, orientation) ++
        Enum.map(Prefab.macro_footprint(definition, anchor, orientation), fn {cell,m} -> {Prefab.micro_coord(cell,0),m} end)
      macros = footprint_macros(cells)

      if Enum.all?(macros, &Edits.valid_edit_coord?/1),
        do: {:ok, cells, macros},
        else: {:error, :invalid_coordinate}
    else
      :error -> {:error, :definition_not_found}
      false -> {:error, :invalid_orientation}
      {:error, reason} -> {:error, reason}
    end
  end

  def prefab_alignment(%{has_macro_cells: true}, {x,y,z}) when rem(x,@micro) != 0 or rem(y,@micro) != 0 or rem(z,@micro) != 0,
    do: {:error, :misaligned}
  def prefab_alignment(_, _), do: :ok

  def footprint_macros(cells) do
    cells |> Enum.map(fn {micro, _} -> elem(Prefab.macro_slot(micro), 0) end) |> Enum.uniq()
  end

  def fetch_instance(state, id) do
    case Map.fetch(state.instances, id) do
      {:ok, instance} -> {:ok, instance}
      :error -> {:error, :instance_not_found}
    end
  end

  def subtree_ids(state, id) do
    children =
      Enum.group_by(
        state.instances,
        fn {_, i} -> Map.get(i, :parent_id, {0, 0}) end,
        &elem(&1, 0)
      )

    descendants(children, [id], MapSet.new())
  end

  def descendants(_, [], ids), do: ids

  def descendants(children, [id | rest], ids),
    do: descendants(children, Map.get(children, id, []) ++ rest, MapSet.put(ids, id))

  def owner_cells(state, id) do
    subtree_cells(state, subtree_ids(state, id))
  end

  def subtree_cells(state, ids) do
    macro = for {cell, owner} <- state.macro_owners, MapSet.member?(ids, owner), do: cell
    Enum.uniq(micro_owner_cells(state,ids) ++ macro)
  end

  def clear_subtree(state, ids, cells) do
    next =
      Enum.reduce(cells, state, fn cell, s ->
        slots =
          Map.get(s.refined, cell, %{})
          |> Map.reject(fn {_, {_, owner}} -> MapSet.member?(ids, owner) end)

        refined =
          if map_size(slots) == 0,
            do: Map.delete(s.refined, cell),
            else: Map.put(s.refined, cell, slots)

        Edits.put_overlay(%{s | refined: refined, macro_owners: Map.delete(s.macro_owners,cell),
          placed_by: Map.delete(s.placed_by,cell), liquid_units: Map.delete(s.liquid_units,cell)},
          0, cell, {0, MmoContracts.Voxel.Skins.uniform(0)})
      end)

    live = Payloads.live_instance_ids(next.refined,next.instances,next.macro_owners) |> MapSet.new()
    dead = MapSet.difference(ids,live)
    owned =
      Map.filter(next.attachment_owners, fn {_, {owner, _}} -> MapSet.member?(dead, owner) end)
      |> Map.keys()
      |> MapSet.new()

    %{
      next
      | instances: Map.drop(next.instances, MapSet.to_list(dead)),
        attachments:
          Map.reject(next.attachments, fn {_, {id, _}} -> MapSet.member?(owned, id) end),
        attachment_owners: Map.drop(next.attachment_owners, MapSet.to_list(owned))
    }
  end

  def player_prefab(state, actor, :voxel_prefab_place_v1, r) do
    with {:ok, definition} <- Map.fetch(state.prefabs, r.definition_id) do
      place_tree(state, state, definition, r.anchor, r.orientation, {0, 0}, 0, [], actor)
    else
      :error -> {:reply, {:error, :definition_not_found}, state}
    end
  end

  def player_prefab(state, actor, kind, r) do
    with {:ok, instance} <- fetch_instance(state, r.instance_id) do
      ids = subtree_ids(state, r.instance_id)
      cells = subtree_cells(state, ids)
      next = clear_subtree(state, ids, cells)

      case kind do
        :voxel_prefab_remove_v1 ->
          prefab_settle(state, next, cells, actor)

        :voxel_prefab_replace_v1 ->
          case Map.fetch(state.prefabs, r.definition_id) do
            {:ok, definition} ->
              place_tree(
                state,
                next,
                definition,
                instance.anchor,
                instance.orientation,
                instance.parent_id,
                instance.component_slot,
                cells,
                actor
              )

            :error ->
              {:reply, {:error, :definition_not_found}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def prefab_settle(before, state, cells, nil), do: prefab_reply(before, state, cells)

  def prefab_settle(before, state, cells, actor) do
    case prefab_reach(state, actor, cells) do
      :ok -> prefab_reply(before, state, cells, %{prefab_actor: actor})
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  def prefab_payment(before, state, cells, %{prefab_actor: actor}) do
    # 支撑裁剪完成后，只按实际前后差额一次结算；可用本次回收支付替换，不从模板退款。
    removed_macros = changed_prefab_macros(before,state,cells)
    added_macros = changed_prefab_macros(state,before,cells)
    delta = Enum.reduce(removed_macros,%{},fn {cell,m},delta ->
      units = if Phase.liquid?(m) or phase_material?(before,m) do
        Map.get(before.liquid_units,cell,liquid_capacity(before))
      else
        {target,_} = target_at(Prefab.micro_coord(cell,0),before)
        Tools.recover_units(before,target,liquid_capacity(before))
      end
      Map.update(delta,m,units,&(&1+units))
    end)
    delta = Enum.reduce(added_macros,delta,fn {_,m},delta ->
      Map.update(delta,m,-liquid_capacity(state),&(&1-liquid_capacity(state)))
    end)
    delta =
      Enum.reduce(cells, delta, fn cell, delta ->
        n = state.material_units_per_micro

        delta =
          Enum.reduce(Map.get(before.refined, cell, %{}), delta, fn {slot, {m, owner}=value}, d ->
            if Map.get(Map.get(state.refined,cell,%{}),slot)==value do
              Map.update(d,m,n,&(&1+n))
            else
              row=%{micro: Prefab.micro_coord(cell,slot),granularity: 1,incarnation: elem(owner,0),owner: owner,material: m}
              recovered=Tools.recover_units(before,row,n)
              Map.update(d,m,recovered,&(&1+recovered))
            end
          end)

        Enum.reduce(Map.get(state.refined, cell, %{}), delta, fn {_, {m, _}}, d ->
          Map.update(d, m, -n, &(&1 - n))
        end)
      end)

    delta =
      Enum.reduce(state.attachments, delta, fn {slot, {_, m}} = entry, d ->
        n = Attachments.units([slot], state.properties)

        if Map.get(before.attachments, slot) == elem(entry, 1),
          do: d,
          else: Map.update(d, m, -n, &(&1 - n))
      end)

    old_changed =
      Map.filter(before.attachments, fn {slot, value} ->
        Map.get(state.attachments, slot) != value
      end)

    delta =
      Enum.reduce(old_changed, delta, fn {slot, {_, m}}, d ->
        n = Tools.attachment_recovery(before,[slot])
        Map.update(d, m, n, &(&1 + n))
      end)

    delta = Map.reject(delta, fn {_, n} -> n == 0 end)

    with :ok <-
           if(Enum.all?(delta, fn {m, _} -> m in state.production_materials end),
             do: :ok,
             else: {:error, :unknown_resource}
           ),
         :ok <-
           if(
             Enum.all?(delta, fn {m, n} -> Production.balance_state(state, actor.cid, m).balance + n >= 0 end),
             do: :ok,
             else: {:error, :insufficient_material}
           ),
         {:ok,state,phase} <- prefab_phase_payment(before,state,removed_macros,added_macros,cells,actor.cid) do
      {next, balances} =
        Enum.reduce(delta, {state, %{}}, fn {m, n}, {s, b} ->
          {s, paid} = Production.settle_material(s, actor.cid, m, n)
          {s, Map.merge(b, paid.material_balances)}
        end)

      {:ok, next, Map.put(phase,:material_balances,balances)}
    else
      {:error, _} = error -> error
    end
  end

  def prefab_payment(before, state, cells, settlement) do
    # 作者入口与既有 liquid_experiment 一样，首次给宏格建立有限相态。
    added = changed_prefab_macros(state,before,cells)
    values = for {cell,m} <- added,phase_material?(state,m),into: %{},
      do: {cell,{Phase.energy(%{material: m},1.0,state.properties.materials[m],ambient_at(state,cell)),liquid_capacity(state)*1.0}}
    quantities = for {cell,m} <- added,Phase.liquid?(m) or phase_material?(state,m),into: %{},
      do: {cell,liquid_capacity(state)}
    thermal = if state.thermal,do: Enum.reduce(values,state.thermal,fn {_,{energy,integrity}},thermal ->
      thermal |> Map.update(:phase_authored_energy_j,energy,&(&1+energy))
        |> Map.update(:phase_authored_units,round(integrity),&(&1+round(integrity)))
    end)
    {:ok,%{state | liquid_units: Liquid.apply_changes(state.liquid_units,quantities),thermal: thermal},
      Map.put(settlement,:prefab_phase_values,values)}
  end

  def changed_prefab_macros(state, other, cells) do
    for cell <- cells, Map.has_key?(state.macro_owners,cell),
      Map.get(state.macro_owners,cell) != Map.get(other.macro_owners,cell) do
      {:ok,{material,_},_} = cell_value(state,0,cell)
      {cell,material}
    end
  end

  # 余额继续由 prefab_payment 一次结算；micro 复用既有逐槽温度及整件 HP。
  def prefab_phase_payment(before,state,removed,added,cells,cid) do
    quantities = for {cell,m} <- added,Phase.liquid?(m) or phase_material?(state,m),into: %{},
      do: {cell,liquid_capacity(state)}
    removed = Enum.filter(removed,fn {_,m} -> phase_material?(before,m) end)
    added = Enum.filter(added,fn {_,m} -> phase_material?(state,m) end)
    {old_values,_} = Phases.phase_values(before,Enum.map(removed,&elem(&1,0)))
    removed_micro = changed_phase_micro(before,state,cells)
    added_micro = changed_phase_micro(state,before,cells)
    ratios = removed_micro |> Enum.uniq_by(& &1.owner) |> Map.new(fn target ->
      component = property_state(before,%{target | granularity: 2})
      {target.owner,component.hp/component.max_hp}
    end)
    removed = Enum.map(removed,fn {cell,m} ->
      {m,Map.get(before.liquid_units,cell,liquid_capacity(before)),Phase.pair(Map.fetch!(old_values,cell))}
    end) ++ Enum.map(removed_micro,fn target ->
      row = property_state(before,target)
      energy = Phase.energy(row,Damage.volume(1),before.properties.materials[target.material],ambient_at(before,Damage.macro(target)))
      {target.material,before.material_units_per_micro,{energy,before.material_units_per_micro*ratios[target.owner]}}
    end)
    {inventory,balances} = Enum.reduce(removed,{%{},state.material_balances},fn {m,q,value},{inventory,balances} ->
      key = {cid,m}
      balance = Map.get(balances,key,0)
      carried = Map.get_lazy(inventory,key,fn -> Phases.inventory_phase(state,cid,m,balance) end)
      {_,carried} = Phase.transfer(value,carried,q,q,:scoop)
      {Map.put(inventory,key,carried),Map.put(balances,key,balance+q)}
    end)
    added = Enum.map(added,fn {cell,m} -> {{:macro,cell},m,liquid_capacity(state)} end) ++
      Enum.map(added_micro,fn target -> {{:micro,target},target.material,state.material_units_per_micro} end)
    Enum.reduce_while(added,{:ok,inventory,balances,%{},[]},fn {address,m,q},{:ok,inventory,balances,values,micro_values} ->
      key = {cid,m}
      balance = Map.get(balances,key,0)
      carried = Map.get_lazy(inventory,key,fn -> Phases.inventory_phase(state,cid,m,balance) end)
      if not Phase.liquid?(m) and elem(carried,1) <= 0 do
        {:halt,{:error,:broken_material}}
      else
        {value,carried} = Phase.transfer({0.0,0.0},carried,balance,q,:pour)
        {values,micro_values} = case address do
          {:macro,cell} -> {Map.put(values,cell,value),micro_values}
          {:micro,target} -> {values,[{target,value} | micro_values]}
        end
        {:cont,{:ok,Map.put(inventory,key,carried),Map.put(balances,key,balance-q),values,micro_values}}
      end
    end)
    |> case do
      {:ok,inventory,_balances,values,micro_values} ->
        {:ok,%{state | phase_inventory: Map.merge(state.phase_inventory,inventory),
          liquid_units: Liquid.apply_changes(state.liquid_units,quantities)},
          %{phase_inventory: inventory,prefab_phase_values: values,prefab_phase_micro: micro_values,
            prefab_phase_preserved: MapSet.new(removed_micro,&Damage.key/1)}}
      {:error,_}=error -> error
    end
  end

  def changed_phase_micro(state,other,cells) do
    for cell <- cells,{slot,{material,{birth,_}=owner}=value} <- Map.get(state.refined,cell,%{}),
      Map.get(Map.get(other.refined,cell,%{}),slot) != value,phase_material?(state,material),
      do: %{micro: Prefab.micro_coord(cell,slot),granularity: 1,incarnation: birth,owner: owner,material: material}
  end

  def put_prefab_phase_micro(state,values) do
    {state,rows,pools} = Enum.reduce(values,{state,[],%{}},fn {target,{energy,integrity}},{s,rows,pools} ->
      material = s.properties.materials[target.material]
      volume = Damage.volume(1)
      latent = if Phase.liquid?(target.material),do: material["latent_heat_per_macro_j"],else: 0.0
      # Micro 仍是既有显热节点；平台内的焓转回等量显热，不能新增第二套微格相变模型。
      temperature = material["phase_transition_kelvin"] + (energy/volume-latent)/material["heat_capacity_per_macro"]
      row = property_state(s,target) |> Map.put(:temperature_kelvin,temperature)
      loss = row.max_hp*(1.0-max(0.0,min(1.0,integrity/s.material_units_per_micro)))
      pools = Map.update(pools,target.owner,{target,loss},fn {previous,total} -> {previous,total+loss} end)
      s = %{s | damage: Map.put(s.damage,Damage.key(row),row)}
      s = %{s | thermal: %{s.thermal | active: true},
        thermal_work: %{s.thermal_work | hot: MapSet.put(s.thermal_work.hot,Damage.macro(target))}}
      {s,[row | rows],pools}
    end)
    Enum.reduce(pools,{state,rows},fn {_owner,{target,loss}},{s,rows} ->
      row = property_state(s,%{target | granularity: 2})
      row = %{row | hp: row.max_hp-loss}
      {%{s | damage: Map.put(s.damage,Damage.key(row),row)},[row | rows]}
    end)
  end

  def prefab_reach(state, actor, cells) do
    range = state.properties.tools[1]["range_macro"]

    if Enum.any?(cells, &(Production.build_reach(actor.eye, &1, range) == :ok)),
      do: :ok,
      else: {:error, :out_of_reach}
  end

  def place_tree(
         before,
         state,
         definition,
         anchor,
         orientation,
         parent,
         slot,
         changed,
         actor \\ nil
       ) do
    case prefab_alignment(definition, anchor) do
      :ok -> place_aligned_tree(before,state,definition,anchor,orientation,parent,slot,changed,actor)
      {:error,reason} -> {:reply,{:error,reason},before}
    end
  end

  def place_aligned_tree(before,state,definition,anchor,orientation,parent,slot,changed,actor) do
    nodes = Prefab.occurrences(definition, anchor, orientation, before.seq + 1, parent, slot)
    macro_nodes = Prefab.macro_occurrences(definition, anchor, orientation, before.seq + 1, parent, slot)
    macro_additions = for {owner,_,cells} <- macro_nodes, {cell,m} <- cells, into: %{}, do: {cell,{m,owner}}

    # 已发布定义保证 slot 不重叠；按 canonical macro 汇集后，每格只更新一次世界索引和缓存。
    additions =
      for {owner, _, cells} <- nodes, {micro, material} <- cells, reduce: %{} do
        acc ->
          {cell, micro_slot} = Prefab.macro_slot(micro)

          Map.update(
            acc,
            cell,
            %{micro_slot => {material, owner}},
            &Map.put(&1, micro_slot, {material, owner})
          )
      end

    # 在当前权威提交中检查这次实际构造的占用，不另展开一份模板作预检。
    result =
      if Enum.all?(Map.keys(additions) ++ Map.keys(macro_additions), &Edits.valid_edit_coord?/1) do
        Enum.reduce_while(macro_additions, {:ok,state}, fn {cell,{m,owner}}, {:ok,s} ->
          case cell_value(s,0,cell) do
            {:ok,{0,_},s} when not is_map_key(s.refined,cell) ->
              s = %{s | macro_owners: Map.put(s.macro_owners,cell,owner),
                placed_by: if(actor,do: Map.put(s.placed_by,cell,actor.cid),else: Map.delete(s.placed_by,cell))}
              {:cont,{:ok,Edits.put_overlay(s,0,cell,{m,MmoContracts.Voxel.Skins.uniform(m)})}}
            {:ok,_,_} -> {:halt,{:error,:occupied}}
            {:error,reason,_} -> {:halt,{:error,reason}}
          end
        end)
        |> then(fn result -> Enum.reduce_while(additions, result, fn
          _, {:error,_}=error -> {:halt,error}
          {cell, added}, {:ok, s} ->
          slots = Map.get(s.refined, cell, %{})

          case cell_value(s, 0, cell) do
            {:ok, {0, _}, s} ->
              if Enum.any?(added, fn {slot, _} -> Map.has_key?(slots, slot) end) do
                {:halt, {:error, :occupied}}
              else
                s = %{s | refined: Map.put(s.refined, cell, Map.merge(slots, added))}
                {:cont, {:ok, Edits.put_overlay(s, 0, cell, {0, MmoContracts.Voxel.Skins.uniform(0)})}}
              end

            {:ok, _, _} ->
              {:halt, {:error, :occupied}}

            {:error, reason, _} ->
              {:halt, {:error, reason}}
          end
        end) end)
      else
        {:error, :invalid_coordinate}
      end

    case result do
      {:ok, next} ->
        instances =
          Enum.reduce(nodes, next.instances, fn {owner, instance, _}, acc ->
            Map.put(acc, owner, Map.put(instance,:placed_by,if(actor,do: actor.cid)))
          end)

        groups = Prefab.attachments(definition, anchor, orientation, before.seq + 1)
        slots = Enum.flat_map(groups, & &1.slots)

        if Enum.any?(slots, &Map.has_key?(next.attachments, &1)) do
          {:reply, {:error, :occupied}, before}
        else
          next =
            Enum.reduce(groups, %{next | instances: instances}, fn g, s ->
              id = max(s.attachment_serial, before.seq) + 1
              values = Map.new(g.slots, &{&1, {id, g.material}})

              %{
                s
                | attachment_serial: id,
                  attachments: Map.merge(s.attachments, values),
                  attachment_owners: Map.put(s.attachment_owners, id, {g.owner, g.slot})
              }
            end)

          prefab_settle(
            before,
            next,
            Enum.uniq(Map.keys(additions) ++ Map.keys(macro_additions) ++ changed ++ Attachments.macros(slots)),
            actor
          )
        end

      {:error, reason} ->
        {:reply, {:error, reason}, before}
    end
  end

  def prefab_reply(before, state, cells, settlement \\ %{}) do
    started = System.monotonic_time(:microsecond)
    removed = Map.keys(before.attachments) -- Map.keys(state.attachments)
    cells = Enum.uniq(cells ++ Attachments.macros(removed))

    state = %{
      state
      | seq: before.seq + 1,
        instances: Map.take(state.instances, Payloads.live_instance_ids(state.refined, state.instances, state.macro_owners))
    }

    macro_changes = Enum.filter(cells, fn cell ->
      {:ok,old,_} = cell_value(before,0,cell)
      {:ok,new,_} = cell_value(state,0,cell)
      old != new
    end)
    macro_identity_changes = Enum.uniq(macro_changes ++
      Enum.filter(cells,&(Map.get(before.macro_owners,&1) != Map.get(state.macro_owners,&1))))

    # owner 更换仍发布完整 L0；只有实际 slot/材质变化才重建结构和碰撞。
    material_changes =
      Enum.filter(cells, fn cell ->
        old = Map.get(before.refined, cell, %{})
        new = Map.get(state.refined, cell, %{})

        cell in macro_changes or map_size(old) != map_size(new) or
          Enum.any?(old, fn {slot, {material, _}} ->
            case Map.get(new, slot) do
              {^material, _} -> false
              _ -> true
            end
          end)
      end)

    state = Liquids.wake_liquid(state, cells)
    {state, attachment_keys, settlement} = AttachmentOps.prune_attachments(before, state, cells, settlement)

    with {:ok, state, settlement} <- prefab_payment(before, state, cells, settlement) do
      {phase_values,settlement} = Map.pop(settlement,:prefab_phase_values,%{})
      {phase_micro,settlement} = Map.pop(settlement,:prefab_phase_micro,[])
      {phase_preserved,settlement} = Map.pop(settlement,:prefab_phase_preserved,MapSet.new())
      {products,settlement} = Map.pop(settlement,:transform_products,%{})
      {carried_rows,settlement} = Map.pop(settlement,:property_states,[])
      # 同材质替换也可能把半格相态补满；碰撞必须消费最终有限数量。
      material_changes = Enum.uniq(material_changes ++ Enum.filter(cells,fn cell ->
        Map.get(before.liquid_units,cell) != Map.get(state.liquid_units,cell)
      end))
      {:ok, coarse, state, _} = Edits.reduce_batch(state, AttachmentOps.attachment_dirty(state, cells), 1, [], 0)
      {coarse_txn, state} = Log.select_transaction(state, coarse)
      macro_dirty = Enum.map(macro_changes,&{0,&1})
      state = Edits.refresh_macro_payloads(before,state,macro_dirty)
      terrain_payloads = Map.merge(before.payloads,state.payloads)
      {state, structure_keys, structure_cells} = Payloads.refresh_structure(state, cells)
      structure_done = System.monotonic_time(:microsecond)
      l0_keys = Enum.uniq(Payloads.region_keys(Enum.map(cells, &{0, &1})) ++ attachment_keys)
      keys = l0_keys ++ structure_keys
      {entries, state} = Payloads.region_afterimages(state, l0_keys, terrain_payloads,macro_dirty)
      region_count = length(entries)

      entries = entries ++ Payloads.structure_entries(state, structure_cells)

      regions_done = System.monotonic_time(:microsecond)
      {state, metadata} = Tools.damage_geometry(before, state, cells, macro_identity_changes,phase_preserved)
      {state,phase_rows} = Phases.put_phase_values(state,phase_values)
      {state,micro_rows} = put_prefab_phase_micro(state,phase_micro)
      {state,product_rows} = HeatCommit.put_transform_products(state,products)
      rows = metadata.property_states ++ phase_rows ++ micro_rows ++ product_rows
      # 调用方随带的行只补本笔几何未改写的键；几何移除与新身份行为准。
      written = MapSet.new(rows,&Damage.key/1)
      metadata = %{metadata | property_states:
        Enum.reject(carried_rows,&MapSet.member?(written,Damage.key(&1))) ++ rows}
      metadata = if state.thermal,do: Map.put(metadata,:thermal,state.thermal),else: metadata

      txn =
        Map.merge(%{coarse_txn | entries: entries ++ coarse_txn.entries}, metadata)
        |> Map.merge(settlement)
        |> Production.ownership_metadata(before,state,cells)

      with {:ok, chunks} <- Observation.canonical_changes(before, state, Enum.map(material_changes, &{0, &1})),
           collision_done = System.monotonic_time(:microsecond),
           :ok <- Log.append_log(state, txn) do
        log_done = System.monotonic_time(:microsecond)
        state = Log.remember_entry(state, txn)
        Observation.fanout(state, txn)
        Observation.fanout_canonical(state, txn, chunks, keys, before)

        Logger.info(
          "voxel_prefab seq=#{state.seq} cells=#{length(cells)} regions=#{region_count} structure_cells=#{length(structure_cells)} " <>
            "state_structure_us=#{structure_done - started} regions_us=#{regions_done - structure_done} " <>
            "collision_us=#{collision_done - regions_done} log_us=#{log_done - collision_done} " <>
            "fanout_us=#{System.monotonic_time(:microsecond) - log_done}"
        )

        {:reply, {:ok, state.seq}, Liquids.schedule_liquid(state)}
      else
        {:error, reason} -> {:reply, {:error, reason}, before}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  # 世界串行接纳；先 .vxpd 后 .pub（<<序号::32, cid::64, 名称::binary>>）：两步之间崩溃只让定义暂不列出，重发即补记；
  # 重发保留首个发布者、名称与序号。
  def persist_prefab(state, cid, name, id, bytes) do
    stem = Path.join(state.prefab_dir, Base.encode16(id, case: :lower))
    listed = Enum.any?(state.published, &(&1.id == id))
    ordinal = length(state.published) + 1

    with :ok <- write_new(stem <> ".vxpd", bytes),
         :ok <-
           if(listed, do: :ok, else: write_new(stem <> ".pub", <<ordinal::32, cid::64, name::binary>>)) do
      if listed,
        do: {:ok, state.published},
        else: {:ok, state.published ++ [%{id: id, publisher: cid, name: name, bytes: bytes}]}
    end
  end

  # 完整文件原子改名成功后才暴露，临时文件不参与恢复。
  def write_new(target, bytes) do
    if File.exists?(target) do
      :ok
    else
      temporary = target <> ".tmp"

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(temporary, bytes, [:binary, :sync]),
           :ok <- File.rename(temporary, target) do
        :ok
      else
        {:error, reason} ->
          File.rm(temporary)
          {:error, {:prefab_persist, reason}}
      end
    end
  end

  # Prefab 放置看足迹，拆除/替换看整棵子树现有格（替换再加新足迹）。
  def prefab_intent_cells(state, :voxel_prefab_place_v1, r) do
    case definition_cells(state, r.definition_id, r.anchor, r.orientation) do
      {:ok, _, macros} -> macros
      _ -> []
    end
  end

  def prefab_intent_cells(state, kind, r) do
    replacement =
      with :voxel_prefab_replace_v1 <- kind,
           {:ok, instance} <- fetch_instance(state, r.instance_id),
           {:ok, _, macros} <- definition_cells(state, r.definition_id, instance.anchor, instance.orientation),
           do: macros,
           else: (_ -> [])

    owner_cells(state, r.instance_id) ++ replacement
  end
end
