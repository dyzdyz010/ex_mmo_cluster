defmodule VoxelRegion.World.HeatCommit do
  @moduledoc """
  全局系统功能：热提交的世界后果：写属性事务、液相提交、受热材料转化与部件损伤迁移。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.Prefab
  alias VoxelRegion.{Combustion, Protection, Transform}
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Observation, Log, Edits, Prefabs, Liquids}

  @micro VoxelRegion.Spatial.micro_resolution()

  # 一次热提交的记录写成一笔事务，再处理其几何后果（材料转化）。
  def commit_thermal(state, %{rows: rows, dead: dead, phase_changes: phase_changes, semblances: extra} = commit) do
    committing = System.monotonic_time(:microsecond)

    state =
      cond do
        dead == [] and map_size(phase_changes) > 0 ->
          {:ok, state} = Liquids.commit_liquid(state, phase_changes, Map.merge(%{property_states: rows}, extra))
          state

        dead == [] ->
          thermal_commit(state, rows, extra)

        true ->
          # 归零与占用删除在原宏格损伤事务中一起持久化，不能留下已提交的零血量实体。
          # 同一步其他节点的温度、热源余量也属于这笔事务；热损伤不发放采掘奖励。
          rows = Enum.map(rows, fn t -> if t.hp == 0.0, do: %{t | flags: 1}, else: t end)
          state = %{state | damage: Enum.reduce(rows, state.damage, fn t, all -> Map.put(all, Damage.key(t), t) end)}
          macros = for t <- dead, t.granularity == 0, do: {Damage.macro(t), 0}
          owners = MapSet.new(for t <- dead, t.granularity == 2, do: t.owner)
          attachments = MapSet.new(for t <- dead, t.granularity == 3, do: t.incarnation)
          {:ok, state} = Liquids.commit_liquid(state, phase_changes, Map.merge(%{property_states: rows}, extra),
            macros, owners, attachments)
          state
      end

    # 零功率电路记到本事务为止；此后任何事务（含下面的转化）都使下一拍重新求解（`Thermal.begin/1`）。
    state = if commit.quiet, do: %{state | thermal_quiet_seq: state.seq}, else: state
    transformed = System.monotonic_time(:microsecond)
    state = transform_heated_materials(state)
    now = System.monotonic_time(:microsecond)

    if state.thermal.active,
      do:
        Logger.info(
          "voxel_thermal_callback elapsed_us=#{commit.busy_us + now - committing} wall_us=#{now - commit.started} kernel_steps=#{commit.steps} transform_us=#{now - transformed} sim_s=#{state.thermal.elapsed_s} seq=#{state.seq}"
        )

    state
  end

  def thermal_commit(state, rows, extra \\ %{}) do
    state = %{
      state
      | seq: state.seq + 1,
        damage: Map.merge(state.damage, Map.new(rows, &{Damage.key(&1), &1}))
    }

    txn = %{
      seq: state.seq,
      entries: [],
      coarse: [],
      property_states: rows,
      thermal: state.thermal
    } |> Map.merge(extra)

    start = System.monotonic_time(:microsecond)
    :ok = Log.append_log(state, txn)
    persisted = System.monotonic_time(:microsecond)
    state = Log.remember_entry(state, txn)
    Observation.fanout(state, txn)
    Observation.fanout_canonical(state, txn, [], [], state)
    broadcast = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_thermal_commit seq=#{state.seq} sim_s=#{state.thermal.elapsed_s} states=#{length(rows)} persist_us=#{persisted - start} broadcast_us=#{broadcast - persisted} active=#{state.thermal.active} supplied_j=#{state.thermal.supplied_j} environment_j=#{state.thermal.environment_j}"
    )

    state
  end

  # R8 单向转化：热提交落盘后，达到转化温度（规则要求还原剂时还须面接触足量还原剂）的节点在一笔几何事务里换成产物。
  # 占用、归属与完整度比例保留；相对环境的显热减去反应热后按产物热容折算；还原剂按化学燃料比例扣减。
  def transform_heated_materials(state) do
    materials = state.properties.materials

    due = Enum.sort(for {key, t} <- state.damage, Transform.due?(t, materials[t.material]), do: {key, t})

    {next, products, carried} =
      Enum.reduce(due, {state, %{}, %{}}, fn {_, ore}, {s, products, carried} ->
        material = materials[ore.material]
        volume = Damage.volume(ore.granularity) * finite_volume(s, ore)

        # 无还原剂的规则（Sand→Glass）只看温度：不找接触、不扣燃料。
        {rows, s, used} =
          if Transform.reductant?(material) do
            reductant_id = material["transform_reductant_material_id"]
            {rows, s} = touching_reductants(s, ore, reductant_id)
            {rows, s, Transform.reductant_j(material, volume, materials[reductant_id])}
          else
            {[], s, 0.0}
          end

        case Transform.draw(Enum.map(rows, &elem(&1, 1)), used) do
          :insufficient ->
            {s, products, carried}

          {:ok, taken} ->
            # 从未点燃的还原剂首次建立燃料余量，与点火同一初始化账。
            drawn = MapSet.new(taken, &Damage.key/1)
            initialized =
              for {true, row} <- rows, MapSet.member?(drawn, Damage.key(row)), reduce: 0.0,
                do: (sum -> sum + row.remaining_fuel_j)

            thermal =
              s.thermal
              |> Map.update(:fuel_initialized_j, initialized, &(&1 + initialized))
              |> Map.update(:transform_reductant_fuel_j, used, &(&1 + used))
              |> Map.update(:transform_j, volume * material["transform_heat_per_macro_j"],
                &(&1 + volume * material["transform_heat_per_macro_j"]))
              |> Map.update(:transform_units, round(volume * liquid_capacity(s)),
                &(&1 + round(volume * liquid_capacity(s))))

            product_id = material["transform_material_id"]
            {cell, slot} = Prefab.macro_slot(ore.micro)

            s =
              if ore.granularity == 0,
                do: Edits.put_overlay(s, 0, cell, {product_id, MmoContracts.Voxel.Skins.uniform(product_id)}),
                else: %{s | refined: Map.update!(s.refined, cell,
                  &Map.update!(&1, slot, fn {_, owner} -> {product_id, owner} end))}

            temperature = Transform.product_temperature(ore.temperature_kelvin, material, materials[product_id],
              ambient_at(s, cell))
            damage = Map.merge(s.damage, Map.new(taken, &{Damage.key(&1), &1}))

            {%{s | damage: damage, thermal: thermal},
             Map.put(products, ore.micro, %{temperature_kelvin: temperature, integrity: ore.hp / ore.max_hp}),
             Map.merge(carried, Map.new(taken, &{Damage.key(&1), %{&1 | seq: state.seq + 1, request_id: 0}}))}
        end
      end)

    if map_size(products) == 0 do
      next
    else
      cells = products |> Map.keys() |> Enum.map(&elem(Prefab.macro_slot(&1), 0)) |> Enum.uniq()
      preserved = MapSet.new(for {_, ore} <- due, Map.has_key?(products, ore.micro), do: Damage.key(ore))
      settlement = %{transform_products: products, property_states: Map.values(carried),
        prefab_phase_preserved: preserved}

      case Prefabs.prefab_reply(state, next, cells, settlement) do
        {:reply, {:ok, _}, committed} ->
          Logger.info("voxel_transform seq=#{committed.seq} nodes=#{map_size(products)} transform_j=#{committed.thermal.transform_j}")
          committed

        {:reply, {:error, reason}, _} ->
          Logger.error("voxel_transform failed=#{inspect(reason)}")
          state
      end
    end
  end

  # 面接触的还原剂节点（宏格或精确微格），按键排序；{是否首次初始化燃料, 带 remaining_fuel_j 的行}。
  # 接触按 1/8 m 实占用（R8-07）：有限宏格按数量向上取整到微格层（与射线、碰撞同一截断）。下方邻格取紧贴本格
  # 底面的那一层微格（不满 7/8 的散体煤与上方矿之间有空隙）；上方邻格要求本格顶层有料。
  def touching_reductants(state, ore, reductant) do
    {_, neighbors} =
      Enum.find(VoxelRegion.ThermalGeometry.faces(Damage.macro(ore), state.refined), &(elem(&1, 0) == ore.micro))

    y = elem(ore.micro, 1)
    rows = if ore.granularity == 0, do: filled_rows(state, Damage.macro(ore)), else: @micro
    # 侧面只在本格有料的层接触，上面只在本格满到顶层时接触（微格矿的面采样本身就是紧邻）。
    neighbors = Enum.filter(neighbors, fn {point, axis, _} ->
      if axis == 1, do: elem(point, 1) < y or rows == @micro, else: elem(point, 1) - y < rows
    end)

    {targets, state} =
      Enum.reduce(neighbors, {%{}, state}, fn {point, axis, _}, {found, s} ->
        point = if axis == 1 and elem(point, 1) < elem(ore.micro, 1),
          do: put_elem(point, 1, elem(ore.micro, 1) - 1), else: point
        {target, s} = target_at(point, s)
        target = if target && target.granularity == 2, do: %{target | granularity: 1}, else: target
        if target && target.material == reductant &&
             Protection.same_holder?(s.protection, Damage.macro(ore), Damage.macro(target)),
          do: {Map.put(found, Damage.key(target), target), s},
          else: {found, s}
      end)

    rows =
      for {key, target} <- Enum.sort(targets),
          row = Map.get_lazy(state.damage, key, fn -> property_state(state, target) end),
          row.hp > 0 and not Combustion.exhausted?(row) do
        capacity = Combustion.capacity_j(state.properties.materials[reductant], combustion_volume(state, target))
        {not Map.has_key?(row, :remaining_fuel_j), Map.put_new(row, :remaining_fuel_j, capacity)}
      end

    {rows, state}
  end

  # 有限宏格按数量向上取整的实占用微格层数；无数量记录为满格。
  def filled_rows(state, cell) do
    case Map.fetch(state.liquid_units, cell) do
      {:ok, q} -> div(q * @micro + liquid_capacity(state) - 1, liquid_capacity(state))
      :error -> @micro
    end
  end

  # 产物行在几何事务的新身份（宏格新纪元、微格原出生与归属）下建立；宏格按源完整度比例折算 HP。
  def put_transform_products(state, products) do
    Enum.reduce(products, {state, []}, fn {micro, product}, {s, rows} ->
      {target, s} = target_at(micro, s)
      target = if target.granularity == 2, do: %{target | granularity: 1}, else: target
      row = property_state(s, target) |> Map.put(:temperature_kelvin, product.temperature_kelvin)
      row = if row.granularity == 0, do: %{row | hp: row.max_hp * product.integrity}, else: row
      s = %{s | damage: Map.put(s.damage, Damage.key(row), row)}
      {s, [row | rows]}
    end)
  end

  # Saved micro damage becomes one leaf pool without restoring missing geometry or HP.
  def migrate_component_damage(state) do
    legacy =
      state.damage
      |> Map.values()
      |> Enum.filter(&(&1.granularity == 1 and not Map.has_key?(&1, :temperature_kelvin)))
      |> Enum.group_by(& &1.owner)

    Enum.reduce(legacy, state, fn {owner, rows}, s ->
      hp = component_max_hp(s, owner)
      lost = Enum.reduce(rows, 0.0, fn t, sum -> sum + t.max_hp - t.hp end)
      target = %{hd(rows) | granularity: 2, max_hp: hp, hp: hp - lost, seq: s.seq, request_id: 0}

      damage =
        Map.drop(s.damage, Enum.map(rows, &Damage.key/1)) |> Map.put(Damage.key(target), target)

      %{s | damage: damage}
    end)
  end
end
