defmodule VoxelRegion.World.Phases do
  @moduledoc """
  全局系统功能：相态材料：有限数量、相态库存与相变操作。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.{Combustion, Phase}
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Production, Liquids, Observation}

  @micro VoxelRegion.Spatial.micro_resolution()

  # Global system: phase energy/HP live in existing property rows. Inventory
  # carries only their extensive sums; material_balances remains quantity SSOT.
  def phase_enabled?(s), do: s.properties != nil and Enum.any?(s.properties.materials,fn {_,m}->Phase.enabled?(m) end)
  # 无位置的库存（供给、背包里的相态材料）按全局环境；落在格上的一律按该格气候区（ambient_at）。
  def phase_ambient(s), do: s.thermal.config["ambient_kelvin"]

  @doc "作者初态的相态焓与数量记入 phase_authored 账（独立参考账，不算模拟供热）；浮点和按格键序累加，不取 map 遍历次序。"
  def authored(nil, _values), do: nil
  def authored(thermal, values) do
    values |> Enum.sort() |> Enum.reduce(thermal, fn {_, value}, t ->
      {energy, integrity} = Phase.dequantize(value)
      t |> Map.update(:phase_authored_energy_j, energy, &(&1 + energy))
        |> Map.update(:phase_authored_units, round(integrity), &(&1 + round(integrity)))
    end)
  end
  # 随数量流动的材料：液体与可倾倒散体（一格一种材料，互不混合）。
  def flowing_material?(s,m), do: Phase.liquid?(m) or loose_material?(s,m)
  def finite_enabled?(s), do: phase_enabled?(s) or (s.properties != nil and
    Enum.any?(s.properties.materials,fn {_,m}->Map.has_key?(m,"loose_threshold_units") end))

  # 整数格值 {能量, 完整度, 已烧燃料, 火}（单位与取整见 Phase）；读行时量化一次，非有限格为零值。
  def phase_values(state,cells) do
    if finite_enabled?(state) do
      Enum.reduce(Enum.uniq(cells),{%{},state},fn cell,{values,s}->
        micro=cell |> Tuple.to_list() |> Enum.map(&(&1*@micro)) |> List.to_tuple()
        {target,s}=target_at(micro,s)
        value=if target && finite_target?(s,target) do
          row=property_state(s,target)
          m=s.properties.materials[row.material]
          volume=finite_volume(s,target)
          q=Map.get(s.liquid_units,cell,liquid_capacity(s))
          fuel=Map.get(row,:remaining_fuel_j)
          Phase.quantize({Phase.finite_energy(row,volume,m,s.thermal && ambient_at(s,cell)),q*row.hp/row.max_hp,
            fuel && fuel/Combustion.capacity_j(m,volume),
            if(fuel,do: Map.get(row,:burning,false),else: nil)},q)
        else
          {0,0,0,nil}
        end
        {Map.put(values,cell,value),s}
      end)
    else
      {%{},state}
    end
  end

  def inventory_phase(state,cid,material,balance) do
    Map.get_lazy(state.phase_inventory,{cid,material},fn ->
      m=state.properties.materials[material]
      {Phase.energy(%{material: material},balance/liquid_capacity(state),m,phase_ambient(state)),balance*1.0}
    end)
  end

  # 舀取／倾倒的格值与库存结算，返回 {state, 格值, 相态库存, 入库单位}。
  # 相态材料：焓与完整度在格与库存之间守恒搬运（既有 B7）。散体：库存不带热与完整度——
  # 倾倒按环境温度、完整材料并入格；舀取带走的显热记入移除账，已点燃的燃料按剩余比例折算入库单位
  # floor(moved × 剩余燃料 / 满燃料)，被带走的剩余燃料由 commit_liquid 按燃料差记入弃置账。
  def transfer_phase_inventory(state,cid,cell,material,action,moved,balance) do
    cond do
      phase_material?(state,material) ->
        {values,state}=phase_values(state,[cell])
        carried=inventory_phase(state,cid,material,balance)
        q=if action==2,do: Map.fetch!(state.liquid_units,cell),else: balance
        {e,i,b,f}=Map.fetch!(values,cell)
        {{e,i},carried}=Phase.transfer({e,i},carried,q,moved,if(action==2,do: :scoop,else: :pour))
        values=Map.put(values,cell,{e,i,b,f})
        inventory=%{{cid,material}=>carried}
        state=%{state | phase_inventory: Map.merge(state.phase_inventory,inventory)}
        {state,values,inventory,if(action==2,do: moved,else: -moved)}

      not loose_material?(state,material) ->
        {state,%{},%{},if(action==2,do: moved,else: -moved)}

      action==2 ->
        {values,state}=phase_values(state,[cell])
        value=Map.fetch!(values,cell)
        q=Map.fetch!(state.liquid_units,cell)
        m=state.properties.materials[material]
        units=if elem(value,3)==nil,do: moved,
          else: div(moved*Phase.explicit_fuel(value,m,q),Phase.full_fuel(q))
        portion=Phase.split(value,moved,q)
        {removed,_}=Phase.dequantize(Phase.pair(portion))
        state=if state.thermal != nil and removed != 0.0,
          do: %{state | thermal: Map.update(state.thermal,:removed_j,removed,&(&1+removed))},else: state
        {state,%{cell=>Phase.merge(value,Phase.scale(portion,-1))},%{},units}

      true ->
        {values,state}=phase_values(state,[cell])
        {state,%{cell=>Phase.merge(Map.fetch!(values,cell),Phase.quantize({0.0,moved,nil,nil},moved))},%{},-moved}
    end
  end

  def put_phase_values(state,values) do
    Enum.reduce(values,{state,[]},fn {cell,value},{s,rows}->
      case Map.get(s.liquid_units,cell) do
        nil -> {s,rows}
        q ->
          micro=cell |> Tuple.to_list() |> Enum.map(&(&1*@micro)) |> List.to_tuple()
          {target,s}=target_at(micro,s)
          existing=Map.has_key?(s.damage,Damage.key(target))
          row=property_state(s,target)
          row=Phase.restore(row,value,q,liquid_capacity(s),s.properties.materials,s.thermal && ambient_at(s,cell))
            |> Map.merge(%{seq: s.seq,request_id: 0})
          # 散体在环境温度、完整、燃料未动时就是默认记录，不为每个流动格写属性行。
          resting=not phase_target?(s,target) and at_rest?(value,q)
          if resting and not existing do
            {s,rows}
          else
            s=%{s | damage: Map.put(s.damage,Damage.key(row),row)}
            # 搬运后的热节点成为普通热种子，净数量不变也需要重新推进。
            s=if s.thermal != nil and not resting,do: %{s | thermal: %{s.thermal | active: true},
              thermal_work: %{s.thermal_work | hot: MapSet.put(s.thermal_work.hot,cell)}},else: s
            {s,[row|rows]}
          end
      end
    end)
  end

  # 整数等式：零焓、满完整度、燃料未初始化。
  def at_rest?({energy,integrity},q), do: at_rest?({energy,integrity,0,nil},q)
  def at_rest?(value,q), do: value == Phase.quantize({0.0,q,nil,nil},q)

  def operate_phase(before,state,actor,request,target,tool) do
    with true <- request.action==1 and phase_target?(state,target) and state.thermal != nil,
         true <- (tool["action"]=="phase.cool" and Phase.liquid?(target.material)) or
           (tool["action"]=="phase.heat" and not Phase.liquid?(target.material)),
         fuel=tool["fuel_material_id"], units=tool["fuel_units"],
         true <- Map.get(state.material_balances,{actor.cid,fuel},0)>=units do
      cell=Damage.macro(target)
      q=Map.get(state.liquid_units,cell,liquid_capacity(state))
      {values,state}=phase_values(state,[cell])
      {energy,integrity}=Phase.dequantize(Phase.pair(Map.fetch!(values,cell)))
      result=Phase.tool_energy(energy,q/liquid_capacity(state),state.properties.materials[target.material],tool)
      thermal=state.thermal |> Map.update(:phase_supplied_j,result.supplied_j,&(&1+result.supplied_j))
        |> Map.update(:phase_paid_j,result.paid_j,&(&1+result.paid_j))
        |> Map.update(:phase_unused_j,result.unused_j,&(&1+result.unused_j))
      {state,settlement}=Production.settle_material(%{state | thermal: thermal},actor.cid,fuel,-units)
      settlement=Map.merge(settlement,%{phase_values: %{cell=>Phase.quantize({result.energy,integrity})}})
      case Liquids.commit_liquid(state,{:character,actor.cid},%{cell=>q},settlement) do
        {:ok,next}->
          Logger.info("voxel_phase seq=#{next.seq} action=#{tool["action"]} cell=#{inspect(cell)} units=#{q} used_j=#{abs(result.supplied_j)} unused_j=#{result.unused_j}")
          {:reply,{:ok,next.seq},next}
        {:error,reason}->{:reply,{:error,reason},before}
      end
    else
      false -> {:reply,{:error,:invalid_phase_operation},before}
    end
  end

  # Pick 进度不消耗材料完整度；真实损伤仍扣减首次采掘时的基准，不能通过采回修复。
  # 固体采回携带操作前焓；Pick 用持续维护的基准，recover 用当前 HP 比例。
  def damage_phase_solid(before,state,actor,request,target,tool) do
    material=state.properties.materials[target.material]
    cell=Damage.macro(target)
    q=Map.get(state.liquid_units,cell,liquid_capacity(state))
    {values,state}=phase_values(state,[cell])
    pick=request.action==1 and tool["action"]=="damage.impact.pick"
    target=if pick,do: Map.put_new(target,:pick_baseline_hp,target.hp),else: target
    # 库存侧是浮点 {J, 数量单位}：格值反量化一次后入库，格上剩余按新 HP 量化回格值。
    {energy,_}=current=Phase.dequantize(Phase.pair(values[cell]))
    carried=if pick and target.hp>0.0,
      do: {energy,q*target.pick_baseline_hp/target.max_hp},else: current
    amount=Damage.amount(material,tool,0)*q/liquid_capacity(state)
    # 新 HP 先落到整数完整度格点上（与写回行同一换算），基准扣减与行上 HP 用同一个值。
    {e,_}=Phase.pair(values[cell])
    {_,integrity}=Phase.quantize({0.0,q*max(0.0,target.hp-amount)/target.max_hp})
    hp=Phase.hp(target.max_hp,integrity,q)
    target=if pick or request.action==2,do: target,else: Damage.pick_baseline(target,hp)
    target=%{target | hp: hp,seq: state.seq+1,request_id: 0}
    state=%{state | damage: Map.put(state.damage,Damage.key(target),target)}
    values=Map.put(values,cell,{e,integrity})
    settlement=if request.action==2 or target.hp==0.0 do
      carried=if pick or request.action==2,do: carried,else: Phase.dequantize({e,integrity})
      balance=Map.get(state.material_balances,{actor.cid,target.material},0)
      inventory=Phase.add(%{{actor.cid,target.material}=>inventory_phase(state,actor.cid,target.material,balance)},
        {actor.cid,target.material},carried)
      state=%{state | phase_inventory: Map.merge(state.phase_inventory,inventory)}
      {state,paid}=Production.settle_material(state,actor.cid,target.material,q)
      {state,%{cell=>0},Map.merge(paid,%{phase_inventory: inventory,phase_values: %{cell=>{0,0}}})}
    else
      {state,%{cell=>q},%{phase_values: values}}
    end
    {state,changes,settlement}=settlement
    settlement=Map.merge(settlement,Observation.operation_metadata(before,actor,request,if(request.action==2 or target.hp==0.0,do: 1,else: 0),target))
    case Liquids.commit_liquid(state,{:character,actor.cid},changes,settlement) do
      {:ok,next}->{:reply,{:ok,next.seq},next}
      {:error,reason}->{:reply,{:error,reason},before}
    end
  end
end
