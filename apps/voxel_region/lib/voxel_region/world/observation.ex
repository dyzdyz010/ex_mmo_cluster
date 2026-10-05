defmodule VoxelRegion.World.Observation do
  @moduledoc """
  全局系统功能：订阅者看到的世界：窗口快照的属性部分、属性事务投影、canonical 增量与下发。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.Attachments
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.{CollisionSource, Prefab}
  alias VoxelRegion.Magic
  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot, Codec}
  alias VoxelRegion.World.Thermal
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Payloads}

  # ---- 订阅

  # Global system: the committing player path supplies the fact; no geometry inference.
  def operation(actor, request, kind, %{material: material} = target) do
    micro = if Map.get(target,:granularity) == 0,
      do: center_micro(Damage.macro(target)), else: target.micro
    %{character: actor.cid, client_seq: request.client_intent_seq,
      kind: kind, material: material, micro: micro}
  end
  def center_micro({x,y,z}) do
    n = VoxelRegion.Spatial.micro_resolution()
    {x*n+div(n,2), y*n+div(n,2), z*n+div(n,2)}
  end

  def fanout(state, entry) do
    Enum.each(state.subs, fn {pid, filter} -> send_filtered(pid, entry, filter) end)
  end

  # 采掘基准只属于服务端持久状态，对外属性观察不携带该内部字段。
  def public_property(row), do: Map.delete(row, :pick_baseline_hp)
  def public_properties(%{property_states: rows} = value),
    do: %{value | property_states: Enum.map(rows, &public_property/1)}
  def public_properties(value), do: value

  # 窗口快照的 World 部分：区域字节与属性快照（同一 seq）；碰撞 chunk 由调用方另行投影。
  def capture_canonical_snapshot(state, {l0_min, l0_max} = box) do
    started = System.monotonic_time(:microsecond)

    with {:ok, regions, state} <- Payloads.canonical_regions(state, CollisionSource.regions(box)) do
      regions_done = System.monotonic_time(:microsecond)

      snapshot =
        %CanonicalSnapshot{content_version: state.cv, transaction_seq: state.seq, l0_min: l0_min,
          l0_max_exclusive: l0_max, regions: regions, chunks: []}
        |> Map.merge(property_snapshot(state, box))
        |> Map.put(:food_receipts, state.food_receipts)

      Logger.info(
        "voxel_window_prepare seq=#{state.seq} box=#{inspect(box)} regions=#{length(regions)} " <>
          "payload_bytes=#{Enum.sum(Enum.map(regions, &byte_size(elem(&1, 1))))} regions_us=#{regions_done - started} " <>
          "properties_us=#{System.monotonic_time(:microsecond) - regions_done}"
      )

      {:ok, snapshot, state}
    end
  end

  def balance_projection(balances, characters) do
    for {{cid, material}, units} <- Enum.sort(balances), cid in characters,
      do: %{character: cid, material: material, units: units}
  end

  def thermal_accounting(nil, _in_box), do: nil
  # 佩尔捷两键缺失表示尚未引入（片 1 之前的世界）；核对“吸热 − 放热 = 热电做功”时取它们出现之后的增量。
  def thermal_accounting(thermal, in_box) do
    ledger = Map.take(thermal, [:active, :elapsed_s, :supplied_j, :environment_j,
      :removed_j, :discarded_source_j, :combustion_j, :combustion_removed_j,
      :fuel_initialized_j, :discarded_fuel_j, :circuit_supplied_j, :circuit_charged_j, :circuit_thermoelectric_j,
      :circuit_peltier_absorbed_j, :circuit_peltier_released_j, :circuit_light_j, :circuit_removed_j, :parameter_rebase_j, :fuel_rebase_j,
      :phase_paid_j, :phase_unused_j, :phase_supplied_j, :phase_authored_units, :phase_authored_energy_j,
      :transform_j, :transform_units, :transform_reductant_fuel_j,
      :caster_drawn_j, :draw_loss_j, :cast_waste_j, :spell_heat_j,
      :semblance_created_j, :semblance_exchanged_j, :semblance_light_j, :semblance_released_j, :body_exchange_j])
    sources = for {cell, source} <- thermal.sources, in_box.(cell), into: %{},
      do: {cell, Map.take(source, [:remaining_j, :power_w])}
    ledger = Map.put(ledger, :sources, sources)

    # 拟态账的剩余项是整个世界的快照：显热 ΣC(T − T_amb) 与其余存量（飞行动能 + 发光余量）；只在出现过拟态的世界里有。
    # 闭合：semblance_created_j = exchanged + light + released + thermal + stored。
    case thermal do
      %{semblances: semblances} ->
        live = Map.values(semblances)
        ambient = thermal.config["ambient_kelvin"]
        thermal_j = Enum.sum(Enum.map(live, &Magic.Semblance.thermal_j(&1, ambient))) * 1.0
        stored_j = Enum.sum(Enum.map(live, &Magic.Semblance.stored_j(&1, ambient))) * 1.0
        Map.merge(ledger, %{semblance_thermal_j: thermal_j, semblance_stored_j: stored_j - thermal_j})

      _ ->
        ledger
    end
  end

  # 全局系统功能：占用与属性在同一 GenServer 提交点采样。
  # 有气候区时附上同一份区表（Scene 的身体按所在格取空气温度，VoxelRegion.Climate.air_k/2）；没有时不加键。
  def property_context(state) do
    context = %{
      hp_enabled: state.properties != nil,
      digest: if(state.properties, do: state.properties.digest, else: <<0::256>>),
      thermal_enabled: state.thermal != nil,
      ambient_kelvin: if(state.thermal, do: state.thermal.config["ambient_kelvin"], else: 0.0)
    }

    if state.thermal && VoxelRegion.Climate.zoned?(state.thermal.config),
      do: Map.put(context, :climate_zones, state.thermal.config["climate_zones"]),
      else: context
  end

  def component_observations(%{properties: nil}, _box), do: []

  def component_observations(state, box) do
    # Request-local projection: each exact leaf's full geometry is scanned once.
    # The window selects representatives, not which slots contribute to leaf HP.
    owners = Enum.reduce(state.refined, %{}, fn {cell, slots}, owners ->
      visible = box == nil or VoxelRegion.PropertyObservation.contains?(cell, box)
      Enum.reduce(slots, owners, fn {slot, {material, {birth, _} = owner}}, acc ->
        target = if visible, do: %{micro: Prefab.micro_coord(cell, slot), granularity: 2,
          incarnation: birth, owner: owner, material: material}
        hp = Damage.max_hp(Map.fetch!(state.properties.materials, material), 1)
        case Map.fetch(acc, owner) do
          :error -> Map.put(acc, owner, {target, MapSet.new([cell]), hp})
          {:ok, {previous, cells, total}} ->
            Map.put(acc, owner, {if(visible, do: target, else: previous), MapSet.put(cells, cell), total + hp})
        end
      end)
    end)

    for {_, {target, cells, hp}} <- owners, target != nil do
      property_state(state, target, hp)
      |> Map.put(:observation_cells, MapSet.to_list(cells))
    end
  end

  def property_snapshot(state, box) do
    macros =
      for {_, t} <- state.damage,
          t.granularity in [0, 1, 4],
          VoxelRegion.PropertyObservation.relevant?(t, box),
          do: %{t | seq: state.seq, request_id: 0}

    macros = (macros ++ owned_macro_observations(state,box)) |> Map.new(&{Damage.key(&1),&1}) |> Map.values()
    %{
      property_states:
        macros ++ component_observations(state, box) ++ attachment_observations(state, box),
      property_context: property_context(state),
      epochs: state.epochs,
      protection: state.protection.regions,
      semblances: Thermal.semblances(state),
      casts: Map.new(state.pending_casts, fn {cid, pending} -> {cid, pending.record} end)
    }
    |> public_properties()
    |> VoxelRegion.PropertyObservation.project(box)
  end

  def owned_macro_observations(%{properties: nil}, _box), do: []
  def owned_macro_observations(state, box) do
    for {cell,_} <- state.macro_owners,
        micro = Prefab.micro_coord(cell,0),
        box == nil or VoxelRegion.PropertyObservation.relevant?(%{micro: micro,granularity: 0},box) do
      {target,_} = target_at(micro,state)
      property_state(state,target)
    end
  end

  def property_transaction(before, state, txn) do
    # 几何变化发布统一叶子汇总；删除保留提交前实际占用范围。
    changed_owners =
      if Map.get(txn, :entries, []) == [],
        do: MapSet.new(),
        else:
          MapSet.new(
            for cell <- Enum.uniq(Map.keys(before.refined) ++ Map.keys(state.refined)),
                Map.get(before.refined, cell) != Map.get(state.refined, cell),
                {_, {_, owner}} <-
                  Map.to_list(Map.get(before.refined, cell, %{})) ++
                    Map.to_list(Map.get(state.refined, cell, %{})),
                do: owner
          )

    fresh =
      if MapSet.size(changed_owners) == 0,
        do: [],
        else:
          Enum.filter(
            component_observations(state, nil),
            &MapSet.member?(changed_owners, &1.owner)
          )

    removed =
      if MapSet.size(changed_owners) == 0,
        do: [],
        else:
          component_observations(before, nil)
          |> Enum.filter(
            &(MapSet.member?(changed_owners, &1.owner) and
                not Map.has_key?(state.instances, &1.owner))
          )
          |> Enum.map(&%{&1 | seq: state.seq, hp: 0.0, flags: 1, request_id: 0})

    # 纯属性提交由唯一目标集合产生；只有几何变化合并三种来源时才需要按身份去重。
    rows =
      if MapSet.size(changed_owners) == 0,
        do: Map.get(txn, :property_states, []),
        else:
          (removed ++ Map.get(txn, :property_states, []) ++ fresh)
          |> Map.new(&{Damage.key(&1), &1})
          |> Map.values()

    rows =
      if before.attachments == state.attachments,
        do: rows,
        else:
          (rows ++ attachment_observations(state, nil))
          |> Map.new(&{Damage.key(&1), &1})
          |> Map.values()

    changed_macros = Enum.uniq(Map.keys(before.macro_owners) ++ Map.keys(state.macro_owners))
      |> Enum.filter(fn cell -> Map.get(before.macro_owners,cell) != Map.get(state.macro_owners,cell) or
        Map.get(before.epochs,cell) != Map.get(state.epochs,cell) end)
      |> MapSet.new()
    rows = if MapSet.size(changed_macros) == 0 do
      rows
    else
      removed = owned_macro_observations(before,nil)
        |> Enum.filter(&MapSet.member?(changed_macros,Damage.macro(&1)))
        |> Enum.map(&%{&1 | seq: state.seq,hp: 0.0,flags: 1,request_id: 0})
      fresh = owned_macro_observations(state,nil)
        |> Enum.filter(&MapSet.member?(changed_macros,Damage.macro(&1)))
      (removed ++ rows ++ fresh) |> Map.new(&{Damage.key(&1),&1}) |> Map.values()
    end

    rows =
      Enum.map(rows, fn
        %{granularity: 3} = row ->
          cells =
            Attachments.macros(
              attachment_slots(before, row.incarnation) ++
                attachment_slots(state, row.incarnation)
            )

          Map.put(row, :observation_cells, cells)

        %{granularity: 2} = row ->
          cells =
            micro_owner_cells(before, MapSet.new([row.owner])) ++
              micro_owner_cells(state, MapSet.new([row.owner]))

          Map.put(row, :observation_cells, Enum.uniq(cells))

        row ->
          row
      end)

    Map.merge(txn, %{property_states: rows, property_context: property_context(state)})
    |> public_properties()
  end

  # Capture both versions while the pre-commit state still exists. Never sample after fanout.
  def canonical_changes(%{canonical_subs: subs, replica_subs: replicas}, _after, _changed)
       when map_size(subs) == 0 and map_size(replicas) == 0, do: {:ok, []}

  def canonical_changes(before, after_state, changed) do
    started = System.monotonic_time(:microsecond)
    boxes = (Map.values(before.canonical_subs) ++ Map.values(before.replica_subs)) |> Enum.uniq()

    coords =
      changed
      |> Enum.map(fn {0, cell} -> CollisionSource.chunk_coord(cell) end)
      |> Enum.uniq()
      |> Enum.filter(fn coord -> Enum.any?(boxes, &CollisionSource.in_box?(coord, &1)) end)
      |> Enum.sort()

    with {:ok, old} <- Payloads.canonical_chunks(before, coords),
         {:ok, new} <- Payloads.canonical_chunks(after_state, coords) do
      chunks =
        Enum.zip(old, new)
        |> Enum.flat_map(fn {a, b} -> if a.cells == b.cells, do: [], else: [b] end)

      Logger.info(
        "voxel_region canonical_delta seq=#{after_state.seq} chunks=#{length(chunks)} occupancy_bytes=#{Enum.sum(Enum.map(chunks, &byte_size(&1.cells)))} capture_us=#{System.monotonic_time(:microsecond) - started}"
      )

      {:ok, chunks}
    end
  end

  def fanout_canonical(
         %{canonical_subs: subs, replica_subs: replicas},
         _txn,
         _chunks,
         _keys,
         _before
       )
       when map_size(subs) == 0 and map_size(replicas) == 0, do: :ok

  def fanout_canonical(state, %{coord: _} = entry, chunks, keys, before) do
    fanout_canonical(
      state,
      Map.merge(
        %{seq: entry.seq, entries: [%{entry | coarse: []}], coarse: entry.coarse},
        Map.take(entry, [:property_states, :epochs])
      ),
      chunks,
      keys,
      before
    )
  end

  def fanout_canonical(state, transaction, chunks, keys, before) do
    transaction = property_transaction(before, state, transaction)

    Enum.each(state.canonical_subs, fn {pid, box} ->
      # 只读验收证据：真实 canonical 订阅的投影前流动帧，保留排他上界。
      if falls = Map.get(transaction, :liquid_falls) do
        {lo, hi} = box
        Logger.info(Jason.encode!(%{event: "liquid_projection", path: "canonical", stream_pid: inspect(pid),
          seq: transaction.seq, material: falls.material, box_min: Tuple.to_list(lo),
          box_max: Tuple.to_list(hi),
          source: Enum.map(falls.transfers, fn {{x,y,z},units} -> [x,y,z,units] end)}))
      end
      delta = %CanonicalDelta{
        transaction_seq: state.seq,
        transaction: VoxelRegion.PropertyObservation.project(transaction, box),
        chunks: Enum.filter(chunks, &CollisionSource.in_box?(&1.coord, box))
      }

      send(Map.fetch!(state.canonical_feeds, pid), {:canonical_delta, delta})
    end)

    # 两种提交入口都按实际变动格提供区域集合；条目的压缩形式不决定更新范围。
    wanted =
      state.replica_subs
      |> Map.values()
      |> Enum.flat_map(&CollisionSource.regions/1)
      |> MapSet.new()

    afterimages =
      Enum.reduce(transaction.entries, %{}, fn
        %{payload: bytes}, ready ->
          {:ok, h} = Codec.decode_payload_header(bytes)
          if h.level == 0, do: Map.put(ready, h.region, bytes), else: ready

        %{coord: _}, ready ->
          ready

        %{structure: _}, ready ->
          ready
      end)

    coords = for {0, region} <- keys, MapSet.member?(wanted, region), do: region
    coords = coords |> Enum.uniq() |> Enum.sort()
    # Replica 只消费字节；需要占用投影的快照/碰撞调用方才解码。
    {regions, _} =
      Enum.map_reduce(coords, state, fn coord, s ->
        case Map.fetch(afterimages, coord) do
          {:ok, bytes} ->
            {{coord, bytes}, s}

          :error ->
            {:ok, bytes, s} = Payloads.canonical_region_bytes(s, coord)
            {{coord, bytes}, s}
        end
      end)

    Enum.each(state.replica_subs, fn {pid, box} ->
      wanted = MapSet.new(CollisionSource.regions(box))

      delta = %CanonicalDelta{
        transaction_seq: state.seq,
        transaction: VoxelRegion.PropertyObservation.project(transaction, box),
        chunks: Enum.filter(chunks, &CollisionSource.in_box?(&1.coord, box))
      }

      send(
        pid,
        {:canonical_replica_delta, delta,
         Enum.filter(regions, &MapSet.member?(wanted, elem(&1, 0)))}
      )
    end)
  end

  def send_filtered(pid, entry, filter) do
    if message = VoxelRegion.LogProjection.message(entry, filter), do: send(pid, message)
  end

  def attachment_identity(slot, value), do: Attachments.identity(slot, value)
  def attachment_observations(%{properties: nil}, _box), do: []

  def attachment_observations(state, box) do
    state.attachments
    |> Enum.group_by(fn {_, {id, _}} -> id end)
    |> Enum.flat_map(fn {_, entries} ->
      cells = Attachments.macros(Enum.map(entries, &elem(&1, 0)))

      if box == nil or Enum.any?(cells, &VoxelRegion.PropertyObservation.contains?(&1, box)) do
        {slot, value} = Enum.min(entries)

        [
          property_state(state, attachment_identity(slot, value))
          |> Map.put(:observation_cells, cells)
        ]
      else
        []
      end
    end)
  end
end
