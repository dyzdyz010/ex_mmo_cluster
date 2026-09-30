defmodule VoxelRegion.World.AttachmentOps do
  @moduledoc """
  全局系统功能：附着物意图：取目标、拆除、提交与几何、可达性与剪枝。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.Attachments
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.World.Thermal
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Payloads, Observation, Log, Edits, Tools, Production, Claims}

  @micro VoxelRegion.Spatial.micro_resolution()

  # 全局系统功能：复用 B2 请求会话、余额和同步日志提交；只生成既有完整区域事务。
  def attachment_target(before, actor, request) do
    previous = Map.get(before.build_sessions, actor.gate)

    cond do
      previous != nil and previous.request == request ->
        {:reply, previous.result, before}

      previous != nil and request.client_intent_seq <= previous.request.client_intent_seq ->
        {:reply, {:error, :replayed_build}, before}

      true ->
        result =
          with {:ok, tool} <- Map.fetch(before.properties.tools, request.tool_id),
               :ok <- Claims.attachment_protection(before, actor, request),
               :ok <- attachment_reach(before, actor, request, tool),
               {:ok, state, slots, settlement} <- attachment_change(before, actor, request) do
            commit_attachment(before, state, slots, settlement)
          else
            :error -> {:error, :invalid_tool}
            error -> error
          end

        {reply, state} =
          case result do
            {:ok, state} -> {{:ok, state.seq}, state}
            {:error, _} = error -> {error, before}
          end

        unless previous != nil, do: Process.monitor(actor.gate)

        state = %{
          state
          | build_sessions:
              Map.put(state.build_sessions, actor.gate, %{request: request, result: reply})
        }

        {:reply, reply, state}
    end
  end

  def destroy_attachment(before, state, actor, target) do
    slots = attachment_slots(state, target.incarnation)

    {state, settlement} =
      Production.settle_material(
        state,
        actor.cid,
        target.material,
        Tools.attachment_recovery(state, slots)
      )

    state = %{state | attachments: Map.drop(state.attachments, slots)}
    tombstone = %{target | hp: 0.0, flags: 1, seq: before.seq + 1, request_id: 0}
    state = %{state | damage: Map.delete(state.damage, Damage.key(target))}

    case commit_attachment(
           before,
           state,
           slots,
           Map.put(settlement, :property_states, [tombstone])
         ) do
      {:ok, next} -> {:reply, {:ok, next.seq}, next}
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  def commit_attachment(before, state, slots, settlement) do
    state = %{state | seq: before.seq + 1}
    {state, rows} = Tools.attachment_damage(before, state)
    settlement = Map.update(settlement, :property_states, rows, &(&1 ++ rows))

    state =
      if state.thermal,
        do: Thermal.rebuild_work(%{state | thermal: %{state.thermal | active: true}}),
        else: state

    settlement =
      if state.thermal, do: Map.put(settlement, :thermal, state.thermal), else: settlement

    {txn, keys, state} = attachment_geometry(before, state, slots)
    txn = Map.merge(txn, settlement)

    case Log.append_log(state, txn) do
      :ok ->
        state = Log.remember_entry(state, txn)
        Observation.fanout(state, txn)
        Observation.fanout_canonical(state, txn, [], keys, before)

        Logger.info(
          "voxel_attachment seq=#{state.seq} changed_slots=#{length(slots)} total=#{map_size(state.attachments)}"
        )

        {:ok, state}

      error ->
        error
    end
  end

  # 附件槽变化的派生几何（粗层表皮投票、core 区域与结构 afterimage），与槽事实同一事务写出。
  def attachment_geometry(before, state, slots) do
    dirty = Enum.map(Attachments.macros(slots), &{0, &1})
    {:ok, coarse, state, _} = Edits.reduce_batch(state, dirty, 1, [], 0)
    {coarse_txn, state} = Log.select_transaction(state, coarse)
    keys = Payloads.region_keys(dirty)

    {state, structure_keys, structure_cells} =
      Payloads.refresh_structure(state, Enum.map(dirty, &elem(&1, 1)))

    {entries, state} = Payloads.region_afterimages(state, keys, before.payloads)
    entries = entries ++ Payloads.structure_entries(state, structure_cells)
    {%{coarse_txn | entries: entries ++ coarse_txn.entries}, Enum.uniq(keys ++ structure_keys), state}
  end

  def attachment_reach(state, actor, r, tool) do
    # 检查到附件几何中心之前的遮挡；斜视共享棱时，向宿主内部偏移会误中邻格。
    size = if r.action == 0, do: r.size, else: 1

    center =
      for i <- 0..2 do
        offset =
          if (r.kind == 0 and i != r.axis) or (r.kind == 1 and i == r.axis),
            do: div(size - 1, 2) + 0.5,
            else: 0.0

        (elem(r.anchor, i) + offset) / @micro
      end

    delta = Enum.zip_with(center, Tuple.to_list(actor.eye), &(&1 - &2))
    distance = :math.sqrt(Enum.sum(Enum.map(delta, &(&1 * &1))))

    if distance > tool["range_macro"] or distance == 0 do
      {:error, :out_of_reach}
    else
      direction = delta |> Enum.map(&(&1 / distance)) |> List.to_tuple()

      case Damage.raycast(actor.eye, direction, max(0.0, distance - 1.0e-7), state, &target_at/2) do
        {:error, :no_target, _} -> :ok
        {:ok, _, _} -> {:error, :occluded_attachment}
      end
    end
  end

  def attachment_change(state, actor, %{action: 0} = r) do
    slots = Attachments.footprint(r.kind, r.axis, r.anchor, r.size)
    {samples, state} = attachment_samples(state, slots)
    cost = Attachments.units(slots, state.properties)

    cond do
      r.id != 0 ->
        {:error, :invalid_attachment}

      not MmoContracts.Voxel.Attachments.material?(r.material) or
          r.material not in state.production_materials ->
        {:error, :unknown_resource}

      r.size == @micro and Enum.any?(Tuple.to_list(r.anchor), &(rem(&1, @micro) != 0)) ->
        {:error, :invalid_attachment}

      Enum.any?(slots, &Map.has_key?(state.attachments, &1)) ->
        {:error, :occupied}

      not Enum.all?(slots, &Attachments.supported?(&1, samples)) ->
        {:error, :unsupported_attachment}

      Production.balance_state(state, actor.cid, r.material).balance < cost ->
        {:error, :insufficient_material}

      true ->
        {state, settlement} = Production.settle_material(state, actor.cid, r.material, -cost)
        id = max(state.attachment_serial, state.seq) + 1
        slots_map = Map.new(slots, &{&1, {id, r.material}})

        {:ok,
         %{state | attachment_serial: id, attachments: Map.merge(state.attachments, slots_map)},
         slots, settlement}
    end
  end

  def attachment_change(state, actor, %{action: 1} = r) do
    case Map.get(state.attachments, {r.kind, r.axis, r.anchor}) do
      {id, material} when id == r.id and material == r.material ->
        slots = for {s, {^id, _}} <- state.attachments, do: s

        {state, settlement} =
          Production.settle_material(state, actor.cid, material, Tools.attachment_recovery(state,slots))

        {:ok, %{state | attachments: Map.drop(state.attachments, slots)}, slots, settlement}

      _ ->
        {:error, :stale_target}
    end
  end

  def attachment_samples(state, slots) do
    Enum.map_reduce(slots |> Enum.flat_map(&Attachments.neighbors/1) |> Enum.uniq(), state, fn p,
                                                                                               s ->
      {t, s} = target_at(p, s)
      {{p, if(t, do: t.material, else: 0)}, s}
    end)
    |> then(fn {rows, s} -> {Map.new(rows), s} end)
  end

  def prune_attachments(before, state, cells, settlement) do
    slots = affected_attachments(state, cells)
    {samples, state} = attachment_samples(state, slots)

    removed =
      (Map.keys(before.attachments) -- Map.keys(state.attachments)) ++
        Enum.reject(slots, &Attachments.supported?(&1, samples))

    cid = Map.get(settlement, :recovery_cid)

    {state, balances} =
      Enum.reduce(removed, {state, Map.get(settlement, :material_balances, %{})}, fn slot,
                                                                                     {s, b} ->
        {_, material} = Map.get(s.attachments, slot) || Map.fetch!(before.attachments, slot)

        if cid && material in s.production_materials do
          {s, paid} = Production.settle_material(s, cid, material, Tools.attachment_recovery(before,[slot]))
          {s, Map.merge(b, paid.material_balances)}
        else
          {s, b}
        end
      end)

    settlement = Map.delete(settlement, :recovery_cid)

    settlement =
      if map_size(balances) > 0,
        do: Map.put(settlement, :material_balances, balances),
        else: settlement

    {%{state | attachments: Map.drop(state.attachments, removed)},
     Payloads.region_keys(Enum.map(Attachments.macros(removed), &{0, &1})), settlement}
  end

  def affected_attachments(state, cells) do
    touched = MapSet.new(cells)

    Enum.filter(Map.keys(state.attachments), fn slot ->
      Enum.any?(Attachments.macros([slot]), &MapSet.member?(touched, &1))
    end)
  end

  # 邻格遮挡／支撑改变可能跨父格；仍存活的附件也必须重算两侧表皮。
  def attachment_dirty(state, cells),
    do:
      (cells ++ Attachments.macros(affected_attachments(state, cells)))
      |> Enum.uniq()
      |> Enum.map(&{0, &1})
end
