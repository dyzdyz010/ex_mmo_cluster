defmodule VoxelRegion.World.Tools do
  @moduledoc """
  全局系统功能：工具意图：目标判定、攻击与采掘、开关、燃烧操作、拆解与破坏的几何后果。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.Attachments
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.Prefab
  alias VoxelRegion.{Combustion, Phase}
  alias VoxelRegion.World.Thermal
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Observation, Log, Edits, Prefabs, Production, Phases, AttachmentOps, Claims}

  @micro VoxelRegion.Spatial.micro_resolution()

  # ??????????????? B1 ????????
  def tool_target(state, actor, %{granularity: 3, owner: {id, address}} = r, tool)
       when address in 0..5 do
    slot = {div(address, 3), rem(address, 3), r.micro}

    case Map.get(state.attachments, slot) do
      {^id, material} when material == r.material and id == r.incarnation ->
        reach = %{action: 1, size: 1, kind: elem(slot, 0), axis: elem(slot, 1), anchor: r.micro}

        case AttachmentOps.attachment_reach(state, actor, reach, tool) do
          :ok -> {:ok, Observation.attachment_identity(slot, {id, material}), state}
          {:error, reason} -> {:error, reason, state}
        end

      _ ->
        {:error, :stale_target, state}
    end
  end

  def tool_target(state, _actor, %{granularity: 3}, _tool),
    do: {:error, :invalid_attachment, state}

  def tool_target(state, actor, r, tool) do
    at=fn micro,s ->
      {target,s}=target_at(micro,s)
      cond do
        target==nil -> {nil,s}
        Phase.liquid?(target.material) and r.material != target.material and tool["action"] not in ["phase.cool","phase.heat"] -> {nil,s}
        finite_target?(s,target) and Map.has_key?(s.liquid_units,Damage.macro(target)) and
            not finite_phase_ray?(actor.eye,r.direction,tool["range_macro"],Damage.macro(target),
              s.liquid_units[Damage.macro(target)]/liquid_capacity(s)) -> {nil,s}
        true -> {target,s}
      end
    end
    Damage.raycast(actor.eye,r.direction,tool["range_macro"],state,at)
  end

  # Real B7 thin water must not occlude the stone below, and a phase/ice aim
  # above the actual surface must not hit the collision slab's rounded top.
  def finite_phase_ray?(eye,direction,range,cell,height) do
    Enum.reduce_while(0..2,{0.0,range},fn axis,{enter,leave}->
      low=elem(cell,axis)*1.0
      high=low+if(axis==1,do: height,else: 1.0)
      origin=elem(eye,axis); d=elem(direction,axis)
      if d==0 do
        if origin>=low and origin<=high,do: {:cont,{enter,leave}},else: {:halt,false}
      else
        a=(low-origin)/d; b=(high-origin)/d
        enter=max(enter,min(a,b)); leave=min(leave,max(a,b))
        if enter<=leave,do: {:cont,{enter,leave}},else: {:halt,false}
      end
    end)!=false
  end

  # 附件槽改变时，同笔更新整件 HP、逐槽显热和设备剩余能源。
  def attachment_damage(before, state) do
    live = MapSet.new(state.attachments, fn {_, {id, _}} -> id end)
    state = %{state | attachment_owners: Map.take(state.attachment_owners, MapSet.to_list(live))}

    Enum.reduce(before.damage, {state, []}, fn
      {key, %{granularity: 4} = t}, {s, rows} ->
        if Map.get(s.attachments, Attachments.slot(t)) == {t.incarnation, t.material} do
          {s, rows}
        else
          energy =
            VoxelRegion.ThermalAttachments.volume(Attachments.slot(t), s.properties) *
              s.properties.materials[t.material]["heat_capacity_per_macro"] *
              (t.temperature_kelvin - ambient_at(s, Damage.macro(t)))

          thermal = s.thermal |> Map.update(:removed_j, energy, &(&1 + energy))
            |> Map.update(:discarded_fuel_j,Map.get(t,:remaining_fuel_j,0.0),&(&1+Map.get(t,:remaining_fuel_j,0.0)))

          {%{s | damage: Map.delete(s.damage, key), thermal: thermal},
           [%{t | hp: 0.0, flags: 1, seq: s.seq, request_id: 0} | rows]}
        end

      {key, %{granularity: 3} = t}, {s, rows} ->
        maximum = attachment_max_hp(s, t)

        cond do
          maximum == t.max_hp ->
            {s, rows}

          maximum == 0 ->
            {%{s | damage: Map.delete(s.damage, key)},
             [%{t | hp: 0.0, flags: 1, seq: s.seq, request_id: 0} | rows]}

          true ->
            row = %{t | max_hp: maximum, hp: t.hp * maximum / t.max_hp, seq: s.seq, request_id: 0}
            {%{s | damage: Map.put(s.damage, key, row)}, [row | rows]}
        end

      _, acc ->
        acc
    end)
  end

  # 权威射线决定实际微格和材料；实例操作不能穿透遮挡或跨代。
  def same_tool_target?(%{granularity: g} = hit, %{granularity: g} = request) when g in [1, 2],
    do: hit.owner == request.owner and hit.incarnation == request.incarnation
  def same_tool_target?(hit, request), do: same_target?(hit, request)

  def attack_target(before, state, actor, request, target, tool) do
    # 同一会话只比较 Gate 入口时钟；World/Player 的处理抖动不改变输入相位。
    now = actor.received_us
    previous = Map.get(state.tool_sessions, actor.player)
    interval = ceil(tool["interval_seconds"] * 1_000_000)

    case Damage.admit_attack(previous, request.client_intent_seq, now, interval, actor.tick_us) do
      {:error, reason} ->
        Logger.info(
          "voxel_tool_rate request_id=#{request.request_id} client_seq=#{request.client_intent_seq} result=#{reason} clock_node=#{actor.clock_node} received_us=#{now} tat_us=#{previous.next_us} tick_us=#{actor.tick_us}"
        )

        {:reply, {:error, reason}, state}

      {:ok, session} ->
        unless previous != nil, do: Process.monitor(actor.player)

        Logger.info(
          "voxel_tool_rate request_id=#{request.request_id} client_seq=#{request.client_intent_seq} result=admitted clock_node=#{actor.clock_node} received_us=#{now} next_us=#{session.next_us} borrowed_us=#{max(0, session.next_us - interval - now)} tick_us=#{actor.tick_us}"
        )

        state = %{state | tool_sessions: Map.put(state.tool_sessions, actor.player, session)}

        cond do
          tool["action"] == "protection.claim" ->
            Claims.claim_region(before, state, actor, request, target, tool)

          tool["action"] == "circuit.toggle" ->
            toggle_switch(before, state, actor, request, target)

          # R8-04 增量 3：电源安装、补能与加热器投料退役（目录 retired_tools）。迁移前的旧目录仍可加载，其工具只被拒绝。
          tool["action"] in ["circuit.install", "circuit.feed", "heat"] ->
            {:reply, {:error, :retired_tool}, state}

          String.starts_with?(tool["action"], "combustion.") ->
            operate_combustion(before, state, actor, request, target, tool)

          tool["action"] in ["phase.cool", "phase.heat"] ->
            Phases.operate_phase(before, state, actor, request, target, tool)

          phase_target?(state,target) and not Phase.liquid?(target.material) ->
            Phases.damage_phase_solid(before, state, actor, request, target, tool)

          true ->
            material = Map.fetch!(state.properties.materials, target.material)

            amount =
              if target.granularity == 3,
                do:
                  Damage.amount(material, tool, 0) * target.max_hp / material["max_hp_per_macro"],
                else: Damage.amount(material, tool, target.granularity)

            target = %{target | hp: max(0.0, target.hp - amount), seq: state.seq + 1}

            cond do
              target.granularity == 2 and not leaf_component?(state, target.owner) ->
                {:reply, {:error, :not_a_leaf_component}, before}

              amount == 0.0 ->
                {:reply, {:error, :ineffective_tool}, state}

              target.granularity == 3 and (request.action == 2 or target.hp == 0.0) ->
                AttachmentOps.destroy_attachment(before, state, actor, request, target)

              request.action == 2 ->
                dismantle_target(before, state, actor, request, target)

              target.hp == 0.0 and target.granularity == 2 ->
                dismantle_target(before, state, actor, request, target)

              target.hp == 0.0 ->
                {state, settlement} =
                  if target.material in state.production_materials and Production.drop_table(state, target.material) == nil do
                    Production.settle_material(
                      state,
                      actor.cid,
                      target.material,
                      recover_units(state,target,@micro * @micro * @micro * state.material_units_per_micro)
                    )
                  else
                    {state, %{}}
                  end

                destroy_target(
                  before,
                  %{state | damage: Map.put(state.damage, Damage.key(target), target)},
                  target,
                  Map.merge(settlement, %{recovery_cid: actor.cid, operation: Observation.operation(actor,request,1,target)})
                )

              true ->
                state = %{
                  state
                  | seq: state.seq + 1,
                    damage: Map.put(state.damage, Damage.key(target), target)
                }

                txn = %{
                  seq: state.seq,
                  entries: [],
                  coarse: [],
                  property_states: [target],
                  operation: Observation.operation(actor,request,0,target),
                  epochs: %{}
                }

                case Log.append_log(state, txn) do
                  :ok ->
                    state = Log.remember_entry(state, txn)
                    Observation.fanout(state, txn)
                    Observation.fanout_canonical(state, txn, [], [], state)

                    Logger.info(
                      "voxel_damage seq=#{state.seq} target=#{inspect(target.micro)} material=#{target.material} hp=#{target.hp} max_hp=#{target.max_hp} geometry=false"
                    )

                    {:reply, {:ok, state.seq}, state}

                  {:error, reason} ->
                    {:reply, {:error, reason}, before}
                end
            end
        end
    end
  end

  # 全局系统功能（R8-04 增量 2）：开关是材料（目录 circuit_switch），不是设备。G 翻转命中格（微格按 granularity 1
  # 热身份）或附件整件属性行上的 closed，缺省断开；与其他属性一样随日志持久化并复制，电路在下一次求解时读取。
  def toggle_switch(before, state, actor, request, target) do
    if request.action == 1 and Map.get(state.properties.materials[target.material], "circuit_switch", false) do
      identity = Map.take(target, [:micro, :granularity, :incarnation, :owner, :material])
      identity = if identity.granularity == 2, do: %{identity | granularity: 1}, else: identity
      row = property_state(state, identity)
      # 复制记录不带请求号（属性批次要求 0，客户端据此拒收整帧；switch-02 实跑）。
      row = Map.merge(row, %{closed: not Map.get(row, :closed, false), seq: state.seq + 1, request_id: 0})
      next = %{state | seq: state.seq + 1, damage: Map.put(state.damage, Damage.key(row), row)}
      txn = %{seq: next.seq, entries: [], coarse: [], property_states: [row], epochs: %{}}

      case Log.append_log(next, txn) do
        :ok ->
          next = Log.remember_entry(next, txn)
          Observation.fanout(next, txn)
          Observation.fanout_canonical(next, txn, [], [], before)

          Logger.info(
            "voxel_switch seq=#{next.seq} cid=#{actor.cid} granularity=#{row.granularity} micro=#{inspect(row.micro)} incarnation=#{row.incarnation} closed=#{row.closed}"
          )

          {:reply, {:ok, next.seq}, next}

        {:error, reason} ->
          {:reply, {:error, reason}, before}
      end
    else
      {:reply, {:error, :not_a_switch}, state}
    end
  end

  # Global system: a tool operates on the exact hit thermal node; HP continues
  # to belong to the existing macro / leaf / attachment damage authority.
  def operate_combustion(before, state, actor, request, target, tool) do
    material = Map.fetch!(state.properties.materials, target.material)

    cond do
      request.action != 1 or state.thermal == nil ->
        {:reply, {:error, :thermal_unavailable}, before}

      not Combustion.combustible?(material) or not is_number(material["heat_capacity_per_macro"]) ->
        {:reply, {:error, :not_combustible}, before}

      true ->
        granularity =
          case target.granularity do
            2 -> 1
            3 -> 4
            other -> other
          end

        row =
          property_state(
            state,
            %{target | granularity: granularity}
            |> Map.take([:micro, :granularity, :incarnation, :owner, :material])
          )

        row = Map.put(row, :request_id, request.request_id)
        combustion_operation(before, state, actor, row, tool, material)
    end
  end

  def combustion_operation(before, state, actor, target, tool, material) do
    volume = combustion_volume(state, target)
    capacity = material["heat_capacity_per_macro"] * volume
    ambient = ambient_at(state, Damage.macro(target))
    temperature = Map.get(target, :temperature_kelvin, ambient)
    units = ceil(tool["fuel_units"] * state.material_units_per_micro * volume)
    action = tool["action"]

    cond do
      action == "combustion.ignite" and Map.get(target, :burning, false) ->
        {:reply, {:error, :already_burning}, before}

      action == "combustion.ignite" and Map.get(target, :remaining_fuel_j, 1.0) <= 0 ->
        {:reply, {:error, :fuel_exhausted}, before}

      action == "combustion.extinguish" and not Map.get(target, :burning, false) ->
        {:reply, {:error, :not_burning}, before}

      Map.get(state.material_balances, {actor.cid, tool["fuel_material_id"]}, 0) < units ->
        {:reply, {:error, :insufficient_material}, before}

      true ->
        {state, settlement} = Production.settle_material(state, actor.cid, tool["fuel_material_id"], -units)

        {row, thermal} =
          if action == "combustion.ignite" do
            energy = tool["heat_energy_j"] * volume
            row = Map.put(target, :temperature_kelvin, temperature + energy / capacity)

            row =
              if row.temperature_kelvin >= material["ignition_kelvin"],
                do: Combustion.ignite(row, material, volume),
                else: row

            thermal =
              state.thermal
              |> Map.update!(:supplied_j, &(&1 + energy))
              |> Map.update(:ignition_j, energy, &(&1 + energy))

            {row, thermal}
          else
            removed =
              min(max(0.0, capacity * (temperature - ambient)), tool["cooling_energy_j"] * volume)

            row =
              target
              |> Combustion.extinguish()
              |> Map.put(:temperature_kelvin, temperature - removed / capacity)

            thermal =
              state.thermal
              |> Map.update(:removed_j, removed, &(&1 + removed))
              |> Map.update(:combustion_removed_j, removed, &(&1 + removed))

            {row, thermal}
          end

        commit_combustion(before, %{state | thermal: thermal}, row, settlement)
    end
  end

  def commit_combustion(before, state, row, settlement) do
    row = %{row | seq: state.seq + 1, request_id: 0}
    thermal = %{state.thermal | active: true}

    next =
      %{
        state
        | seq: state.seq + 1,
          damage: Map.put(state.damage, Damage.key(row), row),
          thermal: thermal
      }
      |> Thermal.rebuild_work()

    initialized = if Map.has_key?(row,:remaining_fuel_j) and not Map.has_key?(Map.get(before.damage,Damage.key(row),%{}),:remaining_fuel_j),do: row.remaining_fuel_j,else: 0.0
    next = %{next | thermal: Map.update(next.thermal,:fuel_initialized_j,initialized,&(&1+initialized))}
    txn =
      Map.merge(
        %{seq: next.seq, entries: [], coarse: [], property_states: [row], thermal: next.thermal},
        settlement
      )

    case Log.append_log(next, txn) do
      :ok ->
        next = Log.remember_entry(next, txn)
        Observation.fanout(next, txn)
        Observation.fanout_canonical(next, txn, [], [], before)

        Logger.info(
          "voxel_combustion_input seq=#{next.seq} target=#{inspect(row.micro)} granularity=#{row.granularity} burning=#{Map.get(row, :burning, false)} remaining_fuel_j=#{Map.get(row, :remaining_fuel_j, 0.0)} power_w=#{Map.get(row, :power_w, 0.0)}"
        )

        {:reply, {:ok, next.seq}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, before}
    end
  end

  def leaf_component?(state, owner),
    do: not Enum.any?(state.instances, fn {_, i} -> Map.get(i, :parent_id, {0, 0}) == owner end)

  def dismantle_target(before, _state, _actor, _request, %{granularity: 0, owner: {0,0}}) do
    {:reply, {:error, :not_a_component}, before}
  end

  def dismantle_target(before, state, actor, request, %{granularity: 0} = target) do
    units = recover_units(state,target,@micro*@micro*@micro*state.material_units_per_micro)
    {state,settlement} = Production.settle_material(state,actor.cid,target.material,units)
    destroy_target(before,state,target,Map.merge(settlement,%{recovery_cid: actor.cid,operation: Observation.operation(actor,request,1,target)}))
  end

  def dismantle_target(before, state, actor, request, target) do
    # 拆卸只认权威射线命中的叶子 occurrence，不采用客户端选中的父级。
    if not leaf_component?(state, target.owner) do
      {:reply, {:error, :not_a_leaf_component}, before}
    else
      ids = MapSet.new([target.owner])
      cells = micro_owner_cells(state, ids)

      amounts = for cell <- cells, {slot,{material,owner}} <- Map.fetch!(state.refined,cell),
        owner==target.owner and material in state.production_materials, reduce: %{} do
          counts ->
            row=%{micro: Prefab.micro_coord(cell,slot),granularity: 1,incarnation: elem(owner,0),owner: owner,material: material}
            units=recover_units(state,row,state.material_units_per_micro)
            Map.update(counts,material,units,&(&1+units))
        end
      {state,balances}=Enum.reduce(amounts,{state,%{}},fn {material,units},{s,balances}->
        {s,settlement}=Production.settle_material(s,actor.cid,material,units)
        {s,Map.merge(balances,settlement.material_balances)}
      end)

      settlement = %{material_balances: balances, recovery_cid: actor.cid,operation: Observation.operation(actor,request,1,target)}
      # Include a tombstone even when a small leaf dies on its first hit.
      damaged = %{before | damage: Map.put(before.damage, Damage.key(target), target)}

      case Prefabs.prefab_reply(damaged, Prefabs.clear_subtree(state, ids, cells), cells, settlement) do
        {:reply, {:error, reason}, _} -> {:reply, {:error, reason}, before}
        result -> result
      end
    end
  end

  # 只读取实际剩余燃料；回收比例和取整规则由燃烧模块统一定义。
  def recover_units(state, target, units) do
    row = Map.get(state.damage, Damage.key(target), target)
    volume = if Map.has_key?(row, :remaining_fuel_j), do: combustion_volume(state, target)
    Combustion.recover_units(row, state.properties.materials[target.material], volume, units)
  end

  def attachment_recovery(state, slots) do
    Enum.reduce(slots,0,fn slot,total ->
      row=Attachments.identity(slot,Map.fetch!(state.attachments,slot)) |> Map.put(:granularity,4)
      total+recover_units(state,row,Attachments.units([slot],state.properties))
    end)
  end

  def destroy_target(before, state, %{granularity: 0} = target, settlement) do
    case Edits.apply_batch(state, [{Damage.macro(target), 0}], false, settlement) do
      {:ok, next} -> {:reply, {:ok, next.seq}, next}
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  # Macro epochs track replacement even back to the same material. Refined identity
  # is its exact micro + occurrence birth; neighbouring damage survives local edits.
  def damage_geometry(before, state, cells, macro_cells, preserved_phase) do
    cells = MapSet.new(cells)
    epochs = Map.new(macro_cells, &{&1, state.seq})

    removed =
      before.damage
      |> Map.values()
      |> Enum.filter(fn t ->
        if t.granularity not in [3, 4] and MapSet.member?(cells, Damage.macro(t)) do
          {current, _} = target_at(t.micro, %{state | epochs: Map.merge(state.epochs, epochs)})

          current == nil or
            if t.granularity == 1,
              do: not same_target?(current, t),
              else: Damage.key(current) != Damage.key(t)
        else
          false
        end
      end)

    damage = Map.drop(state.damage, Enum.map(removed, &Damage.key/1))
    states = Enum.map(removed, &%{&1 | hp: 0.0, flags: 1, seq: state.seq, request_id: 0})

    thermal =
      if state.thermal do
        removed_j =
          Enum.reduce(removed, 0.0, fn t, sum ->
            if Map.has_key?(t, :temperature_kelvin) and not phase_target?(before,t) and
                 not MapSet.member?(preserved_phase,Damage.key(t)),
              do:
                sum +
                  state.properties.materials[t.material]["heat_capacity_per_macro"] *
                    Damage.volume(t.granularity) * finite_volume(before, t) *
                    (t.temperature_kelvin - ambient_at(state, Damage.macro(t))),
              else: sum
          end)

        sources =
          Map.reject(state.thermal.sources, fn {cell, source} ->
            if MapSet.member?(cells, cell) do
              {current, _} = target_at(source.target.micro, state)
              current == nil or not same_target?(current, source.target)
            else
              false
            end
          end)

        discarded =
          Enum.reduce(state.thermal.sources, 0.0, fn {cell, s}, sum ->
            sum + if(Map.has_key?(sources, cell), do: 0.0, else: s.remaining_j)
          end)

        # 蓄能石随格移除时储能不进库存（材料单位不带电），记入移除账。
        stored_j = Enum.reduce(removed, 0.0, fn t, sum -> sum + Map.get(t, :stored_j, 0.0) end)

        %{state.thermal | active: true, sources: sources}
        |> Map.update(:removed_j, removed_j, &(&1 + removed_j))
        |> Map.update(:circuit_removed_j, stored_j, &(&1 + stored_j))
        |> Map.update(:discarded_source_j, discarded, &(&1 + discarded))
        |> Map.update(:discarded_fuel_j,discarded_fuel(removed,preserved_phase),&(&1+discarded_fuel(removed,preserved_phase)))
      end

    {state, attachment_states} =
      attachment_damage(before, %{state | damage: damage, thermal: thermal})

    thermal = state.thermal
    metadata = %{property_states: states ++ attachment_states, epochs: epochs}
    metadata = if thermal, do: Map.put(metadata, :thermal, thermal), else: metadata
    affected = cells |> Enum.flat_map(&[&1 | VoxelRegion.Thermal.neighbors(&1)])

    state =
      Thermal.drop_geometry(%{state | epochs: Map.merge(state.epochs, epochs), thermal: thermal}, affected)

    state =
      if before.attachments == state.attachments, do: state, else: Thermal.rebuild_work(state)

    {state, metadata}
  end

  def discarded_fuel(removed, preserved),
    do: Enum.reduce(removed, 0.0, fn t, sum ->
      if MapSet.member?(preserved, Damage.key(t)), do: sum, else: sum + Map.get(t, :remaining_fuel_j, 0.0)
    end)

  def current_actor(actor) do
    try do
      with {:ok, current} <- actor.refresh.(actor.player, actor.identity) do
        {:ok, Map.merge(current, Map.take(actor, [:received_us, :clock_node]))}
      end
    catch
      :exit, _ -> {:error, :invalid_session}
    end
  end

  def tool_range(state, id) do
    result = with %{tools: tools} <- state.properties, {:ok, tool} <- Map.fetch(tools, id),
      do: tool["range_macro"]
    if is_number(result), do: result, else: {:error, :invalid_tool}
  end

  def intent_keys(state, {:tool_intent, actor, request}) do
    with range when is_number(range) <- tool_range(state, request.tool_id),
         true <- Edits.valid_edit_coord?(Damage.macro(request)) do
      {:ok, tool_regions(actor, range) ++ if(request.action == 1, do: Edits.edit_keys([Damage.macro(request)]), else: [])}
    else
      false -> {:error, :invalid_coordinate}
      error -> error
    end
  end

  def intent_keys(state, {:production_intent, actor, %{action: action} = request}) when action in [2, 3] do
    case tool_range(state, request.tool_id) do
      range when is_number(range) -> {:ok, Edits.edit_keys([request.coord]) ++ tool_regions(actor, range)}
      error -> error
    end
  end
  def intent_keys(_, {:production_intent, _, %{action: 1} = request}), do: {:ok, Edits.edit_keys([request.coord])}
  def intent_keys(_, {:production_intent, _, _}), do: {:ok, []}

  def tool_regions(%{eye: {x, y, z}}, range) do
    for rx <- floor((x - range) / 64)..floor((x + range) / 64),
        ry <- floor((y - range) / 64)..floor((y + range) / 64),
        rz <- floor((z - range) / 64)..floor((z + range) / 64),
        do: {0, {rx, ry, rz}}
  end
end
