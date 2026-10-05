defmodule VoxelRegion.World.Production do
  @moduledoc """
  全局系统功能：生产：余额、掉落、建造取材与放置、合成、死亡掉落。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  require Logger
  alias VoxelRegion.{Liquid, Phase, Protection}
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Observation, Log, Edits, Phases, Liquids}

  @micro VoxelRegion.Spatial.micro_resolution()

  # nil = 这一格的放置记录被清掉。
  def merge_placed(placed_by, delta) do
    {cleared, set} = Enum.split_with(delta, fn {_, cid} -> cid == nil end)
    placed_by |> Map.drop(Enum.map(cleared, &elem(&1, 0))) |> Map.merge(Map.new(set))
  end

  # 收据按角色与 World 事务号唯一；创建、日志重放与只读 Replica 使用同一合并语义。
  def merge_food_receipts(receipts, delta),
    do: Map.merge(receipts, delta, fn _cid, old, added -> Map.merge(old, added) end)

  # Canonical ownership deltas share the transaction with the actual geometry edit.
  # No-op edits retain identity; nil removes a row on both replay backends.
  def ownership_metadata(txn,before,state,cells) do
    Enum.reduce([:placed_by,:macro_owners],txn,fn key,txn ->
      old = Map.fetch!(before,key)
      new = Map.fetch!(state,key)
      delta = for cell <- cells, Map.get(old,cell) != Map.get(new,cell), into: %{}, do: {cell,Map.get(new,cell)}
      if map_size(delta) == 0, do: txn, else: Map.put(txn,key,delta)
    end)
  end

  def balance_state(state, cid, material) do
    %{
      seq: state.seq,
      material: material,
      balance: Map.get(state.material_balances, {cid, material}, 0),
      cost: build_cost(state, material)
    }
  end

  def drop_table(state, material), do: get_in(state, [Access.key(:properties), Access.key(:materials, %{}), material, "drops"])

  # [0, 1) 的确定性骰子；seq + 1 是这一笔事务将要取得的序号。
  def drop_roll(state, {x, y, z}, index) do
    <<n::32, _::binary>> =
      :crypto.hash(:sha256, <<state.cv::64, state.seq + 1::64, x::64-signed, y::64-signed, z::64-signed, index::16>>)

    n / 4_294_967_296
  end

  def build_cost(state, material),
    do: get_in(state, [Access.key(:properties), Access.key(:materials, %{}), material, "place_units"]) ||
          @micro * @micro * @micro * state.material_units_per_micro

  def settle_material(state, cid, material, delta) do
    key = {cid, material}
    balance = Map.get(state.material_balances, key, 0) + delta

    {%{state | material_balances: Map.put(state.material_balances, key, balance)},
     %{material_balances: %{key => balance}}}
  end

  def supply_materials(before, {cid, _} = key, quantities) do
    {next, balances, inventory, energy, phase_units} =
      Enum.reduce(quantities, {before, %{}, %{}, 0.0, 0}, fn {material, units}, {s, balances, inventory, energy, phase_units} ->
        balance = Map.get(s.material_balances, {cid, material}, 0)
        {s, paid} = settle_material(s, cid, material, units)
        if phase_material?(s, material) do
          m = s.properties.materials[material]
          # 供给指定相态与完整度：环境温度限定在该相态的转变点一侧，
          # 例如液态岩浆和固态冰，新增焓随供给事务记账。
          temperature = if Phase.liquid?(material),
            do: max(Phases.phase_ambient(s), m["phase_transition_kelvin"]),
            else: min(Phases.phase_ambient(s), m["phase_transition_kelvin"])
          added = Phase.energy(%{material: material}, units / liquid_capacity(s), m, temperature)
          {e, i} = Phases.inventory_phase(before, cid, material, balance)
          {s, Map.merge(balances, paid.material_balances), Map.put(inventory, {cid, material}, {e + added, i + units}), energy + added, phase_units + units}
        else
          {s, Map.merge(balances, paid.material_balances), inventory, energy, phase_units}
        end
      end)
    thermal = if next.thermal, do: next.thermal
      |> Map.update(:phase_authored_energy_j, energy, &(&1 + energy))
      |> Map.update(:phase_authored_units, phase_units, &(&1 + phase_units)), else: nil
    receipt = %{seq: before.seq + 1, quantities: quantities, phase_energy_j: energy}
    next = %{next | seq: receipt.seq, thermal: thermal,
      material_supplies: Map.put(next.material_supplies, key, receipt),
      phase_inventory: Map.merge(next.phase_inventory, inventory)}
    txn = %{seq: next.seq, entries: [], coarse: [], material_balances: balances,
      material_supplies: %{key => receipt}, phase_inventory: inventory, thermal: thermal}
    case Log.append_log(next, txn) do
      :ok ->
        next = Log.remember_entry(next, txn)
        Observation.fanout(next, txn)
        Observation.fanout_canonical(next, txn, [], [], before)
        {:reply, {:ok, next.seq}, next}
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  def build_target(before, actor, request) do
    # Scene 移交会换 Player 与 epoch，同一已鉴权连接的请求序号仍继续递增。
    previous = Map.get(before.build_sessions, actor.gate)

    cond do
      previous != nil and previous.request == request ->
        {:reply, previous.result, before}

      previous != nil and request.client_intent_seq <= previous.request.client_intent_seq ->
        {:reply, {:error, :replayed_build}, before}

      true ->
        result = cond do
          request.action == 4 -> craft(before, actor, request)
          request.action == 5 -> consume(before, actor, request)
          not Protection.permitted?(before.protection, {:character, actor.cid}, [request.coord]) ->
            {:error, :protected_region}
          request.action in [2,3] -> Liquids.transfer_liquid(before, actor, request)
          true -> build_material(before, actor, request)
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

  # 全局系统功能（身体闭环 H1）：进食 = 生产意图 action 5，material = 可食材料（目录“可食”轴 food），一次吃一株 = place_units。
  # 余额足额才扣一株；food_ledger 记累计吃掉的单位，营养收据与扣料同笔持久化。
  # Scene 从 canonical snapshot/delta 按本角色的 World 游标吸收收据，身体真值仍在 Scene。
  def consume(before, actor, request) do
    food = get_in(before, [Access.key(:properties), Access.key(:materials, %{}), request.material, "food"])
    units = build_cost(before, request.material)

    cond do
      food == nil or request.material not in before.production_materials ->
        {:error, :not_edible}

      balance_state(before, actor.cid, request.material).balance < units ->
        {:error, :insufficient_material}

      true ->
        {state, paid} = settle_material(before, actor.cid, request.material, -units)
        ledger = Map.update(state.food_ledger, request.material, units, &(&1 + units))
        seq = before.seq + 1
        receipts = %{actor.cid => %{seq => %{protein_g: food["protein_g"], energy_j: food["energy_j"]}}}
        next = %{state | seq: seq, food_ledger: ledger,
          food_receipts: merge_food_receipts(state.food_receipts, receipts)}
        txn = %{seq: next.seq, entries: [], coarse: [], material_balances: paid.material_balances,
          food_ledger: ledger, food_receipts: receipts}

        case Log.append_log(next, txn) do
          :ok ->
            next = Log.remember_entry(next, txn)
            Observation.fanout(next, txn)
            Observation.fanout_canonical(next, txn, [], [], before)
            Logger.info("voxel_consume seq=#{next.seq} cid=#{actor.cid} material=#{request.material} units=#{units} protein_g=#{food["protein_g"]} energy_j=#{food["energy_j"]}")
            {:ok, next}

          error ->
            error
        end
    end
  end

  # 全局系统功能（R8-04 增量 2）：黑盒构件只能按目录配方从库存合成（生产意图 action 4，material = 产物，一次一份）。
  # 输入全部足额才整笔扣减、产物入库；合成账 craft_ledger 记各材料累计净变化。拆掉产物只返还产物本身（不可拆回原料）。
  def craft(before, actor, request) do
    product = Map.get(before.properties.materials, request.material, %{})

    cond do
      not Map.has_key?(product, "recipe_inputs") or request.material not in before.production_materials ->
        {:error, :unknown_recipe}

      Enum.any?(product["recipe_inputs"], &(balance_state(before, actor.cid, &1["material_id"]).balance < &1["units"])) ->
        {:error, :insufficient_material}

      true ->
        delta = Map.put(Map.new(product["recipe_inputs"], &{&1["material_id"], -&1["units"]}), request.material, product["recipe_units"])

        {state, balances} =
          Enum.reduce(delta, {before, %{}}, fn {material, units}, {s, balances} ->
            {s, paid} = settle_material(s, actor.cid, material, units)
            {s, Map.merge(balances, paid.material_balances)}
          end)

        ledger = Enum.reduce(delta, state.craft_ledger, fn {material, units}, l -> Map.update(l, material, units, &(&1 + units)) end)
        next = %{state | seq: before.seq + 1, craft_ledger: ledger}
        txn = %{seq: next.seq, entries: [], coarse: [], material_balances: balances, craft_ledger: ledger}

        case Log.append_log(next, txn) do
          :ok ->
            next = Log.remember_entry(next, txn)
            Observation.fanout(next, txn)
            Observation.fanout_canonical(next, txn, [], [], before)
            Logger.info("voxel_craft seq=#{next.seq} cid=#{actor.cid} product=#{request.material} delta=#{inspect(delta)}")
            {:ok, next}

          error ->
            error
        end
    end
  end

  # 身体闭环 H2（Voxim Docs/Magic.md §6.10，用户 2026-09-26 定）：死亡掉落。
  # 死亡点 = 脚所在宏格；死者在该格不被地块保护许可（他人地块 / 保留区）则不掉。确定性掷骰 `drop_roll(死亡格, 0)` <
  # 概率 `death_drop_probability`（启动参数，默认 0 = 不掉，用户 2026-09-27 定先留接口）才掉。候选 = 死者余额 ≥ 1/8 m³、且 1/8 m³ 在世界里有现成形态的可放置材料：散体（有休止阈值）
  # 倾倒成一格 1/8 m³ 的量（与玩家倾倒同一提交 `move_flowing/6`）；单次放置量恰为 1/8 m³ 的材料（花草）放置成一格
  # （与放置同一提交）。整格材料（石、土、木等，一次放置 = 1 m³）没有 1/8 m³ 的世界形态，不参选。候选按材料 id 排序，
  # `drop_roll(死亡格, 1)` 选一种；落点 = 死亡格周围 3×3×3 按（距离²、y、x、z）排序的第一个许可、非细分的空气格
  # （散体还须在流动域内，花草还须有草 / 苔 / 土托底）。余额同量扣除。返回 `{日志字段, state}`。
  def death_drop(state, cid, {fx, fy, fz}) do
    cell = {floor(fx), floor(fy), floor(fz)}
    eighth = div(liquid_capacity(state), 8)
    roll = drop_roll(state, cell, 0)

    candidates =
      state.material_balances
      |> Enum.flat_map(fn
        {{^cid, material}, balance} when balance >= eighth ->
          case drop_form(state, material, eighth) do
            nil -> []
            form -> [{material, form}]
          end

        _ ->
          []
      end)
      |> Enum.sort()

    cond do
      not Protection.permitted?(state.protection, {:character, cid}, [cell]) ->
        {%{outcome: :protected, cell: cell}, state}

      roll >= state.death_drop_probability ->
        {%{outcome: :no_drop, cell: cell, roll: roll}, state}

      candidates == [] ->
        {%{outcome: :no_material, cell: cell, roll: roll}, state}

      true ->
        {material, form} = Enum.at(candidates, floor(drop_roll(state, cell, 1) * length(candidates)))
        facts = %{cell: cell, roll: roll, material: material, units: eighth}

        case drop_cell(state, cid, cell, material, form) do
          {nil, state} ->
            {Map.put(facts, :outcome, :no_space), state}

          {target, state} ->
            committed =
              if form == :pour,
                do: Liquids.move_flowing(state, cid, target, material, 3, eighth),
                else: death_place(state, cid, target, material)

            case committed do
              {:ok, next} -> {Map.merge(facts, %{outcome: :dropped, target: target, seq: next.seq}), next}
              {:error, reason} -> {Map.merge(facts, %{outcome: :rejected, target: target, reason: reason}), state}
            end
        end
    end
  end

  def drop_form(state, material, eighth) do
    cond do
      material not in state.production_materials or Phase.liquid?(material) -> nil
      loose_material?(state, material) and Liquids.liquid_enabled?(state) -> :pour
      not loose_material?(state, material) and build_cost(state, material) == eighth -> :place
      true -> nil
    end
  end

  def drop_cell(state, cid, {x, y, z}, material, form) do
    offsets = Enum.sort_by(for(dx <- -1..1, dy <- -1..1, dz <- -1..1, do: {dx, dy, dz}),
      fn {dx, dy, dz} -> {dx * dx + dy * dy + dz * dz, dy, dx, dz} end)

    Enum.reduce_while(offsets, {nil, state}, fn {dx, dy, dz}, {nil, s} ->
      c = {x + dx, y + dy, z + dz}

      if Protection.permitted?(s.protection, {:character, cid}, [c]) and not Map.has_key?(s.refined, c) and
           (form == :place or Liquids.liquid_inside?(c, s.liquid_bounds)) do
        case cell_value(s, 0, c) do
          {:ok, {0, _}, s} ->
            if form == :pour or match?({:ok, _}, plant_support(s, %{material: material, coord: c})),
              do: {:halt, {c, s}}, else: {:cont, {nil, s}}

          {_, _, s} ->
            {:cont, {nil, s}}
        end
      else
        {:cont, {nil, s}}
      end
    end)
  end

  def death_place(state, cid, cell, material) do
    {state, settlement} = settle_material(state, cid, material, -build_cost(state, material))
    Edits.apply_batch(state, [{cell, material}], false, Map.put(settlement, :placed, %{cell => cid}))
  end

  def build_material(before, actor, request) do
          with :ok <-
                 if(request.action == 1 and not Phase.liquid?(request.material) and request.material in before.production_materials,
                   do: :ok,
                   else: {:error, :unknown_resource}
                 ),
               {:ok, tool} <- Map.fetch(before.properties.tools, request.tool_id),
               :ok <- build_reach(actor.eye, request.coord, tool["range_macro"]),
               :ok <-
                 if(
                   balance_state(before, actor.cid, request.material).balance >= build_cost(before, request.material),
                   do: :ok,
                   else: {:error, :insufficient_material}
                 ),
               :ok <- if(phase_material?(before,request.material) and
                   elem(Phases.inventory_phase(before,actor.cid,request.material,balance_state(before,actor.cid,request.material).balance),1)<=0,
                 do: {:error,:broken_material},else: :ok),
               false <- Map.has_key?(before.refined, request.coord),
               {:ok, {old, _}, state} <- cell_value(before, 0, request.coord),
               {:ok, state} <- plant_support(state, request),
               {:ok, state, displaced, displacement} <- displace_for_build(state, request.coord, old) do
            {state, settlement} =
              settle_material(
                state,
                actor.cid,
                request.material,
                -build_cost(state, request.material)
              )

            # 溯源：这一格是 actor 花自己的材料放下的。
            settlement = Map.put(settlement, :placed, %{request.coord => actor.cid})

            if phase_material?(state,request.material) do
              cost=liquid_capacity(state)
              balance=balance_state(before,actor.cid,request.material).balance
              carried=Phases.inventory_phase(before,actor.cid,request.material,balance)
              {portion,remaining}=Phase.transfer({0.0,0.0},carried,balance,cost,:pour)
              inventory=%{{actor.cid,request.material}=>remaining}
              state=%{state | phase_inventory: Map.merge(state.phase_inventory,inventory)}
              # Inventory Ice stays solid; any later thermal phase completion is ordinary simulation.
              Edits.apply_batch(state,displaced++[{request.coord,request.material}],false,Map.merge(settlement,%{
                liquid_changes: Map.put(displacement.liquid_changes,request.coord,cost),
                phase_values: Map.put(displacement.phase_values,request.coord,portion),phase_inventory: inventory}))
            else
              Edits.apply_batch(state, displaced++[{request.coord, request.material}], false, Map.merge(settlement,displacement))
            end
          else
            :error -> {:error, :invalid_tool}
            true -> {:error, :occupied}
            {:ok, _, _} -> {:error, :occupied}
            {:error, reason} -> {:error, reason}
          end
  end

  # 地面花草只能种在草、苔或土上；其余材料不看下方。
  def plant_support(state, %{material: material, coord: {x, y, z}}) when material in 32..39 do
    case cell_value(state, 0, {x, y - 1, z}) do
      {:ok, {below, _}, state} when below in [1, 3, 7] -> if(is_map_key(state.refined, {x, y - 1, z}), do: {:error, :unsupported}, else: {:ok, state})
      {:ok, _, _} -> {:error, :unsupported}
      {:error, reason, _} -> {:error, reason}
    end
  end

  def plant_support(state, _request), do: {:ok, state}

  # 先形成完整不可变计划，再与扣料及实体放置共同提交；拒绝时不留下部分排液。
  def displace_for_build(state, _cell, 0),
    do: {:ok,state,[],%{liquid_changes: %{},phase_values: %{}}}
  # 地面花草可被替换：建造直接覆盖，不产生排液。
  def displace_for_build(state, _cell, material) when material in 32..39,
    do: {:ok,state,[],%{liquid_changes: %{},phase_values: %{}}}
  def displace_for_build(state, cell, material) do
    if Phase.liquid?(material) and Liquids.liquid_enabled?(state) and Liquids.liquid_inside?(cell,state.liquid_bounds) do
      cells = cell |> then(&Liquid.neighborhood([&1])) |> Enum.filter(&Liquids.liquid_inside?(&1,state.liquid_bounds))
      {open,water,state} = Liquids.liquid_cells(state,cells,material)
      # 建造排液不排进持有者不同的格。
      with {:ok,changes,flows} <- Liquid.displace(water,cell,liquid_capacity(state),state.liquid_bounds,
             &(Map.fetch!(open,&1) and Protection.same_holder?(state.protection,cell,&1))) do
        {values,state} = Phases.phase_values(state,Map.keys(changes))
        values = if Phases.finite_enabled?(state),do: Phase.transport(values,water,flows),else: %{}
        edits = for {to,_} <- changes,to != cell,do: {to,material}
        {:ok,state,edits,%{liquid_changes: changes,phase_values: values}}
      end
    else
      {:error,:occupied}
    end
  end

  def build_reach(eye, coord, range) do
    squared =
      Enum.zip(Tuple.to_list(eye), Tuple.to_list(coord))
      |> Enum.reduce(0.0, fn {a, b}, sum -> sum + (a - b - 0.5) * (a - b - 0.5) end)

    if squared <= range * range, do: :ok, else: {:error, :out_of_reach}
  end
end
