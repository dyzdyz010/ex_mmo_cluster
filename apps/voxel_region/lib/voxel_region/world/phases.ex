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
  # 随数量流动的材料：液体与可倾倒散体（一格一种材料，互不混合）。
  def flowing_material?(s,m), do: Phase.liquid?(m) or loose_material?(s,m)
  def finite_enabled?(s), do: phase_enabled?(s) or (s.properties != nil and
    Enum.any?(s.properties.materials,fn {_,m}->Map.has_key?(m,"loose_threshold_units") end))

  # 格值 {能量, 完整度, 已烧燃料 J, 火}（见 Phase）；非有限格为零值。
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
          {Phase.finite_energy(row,volume,m,s.thermal && ambient_at(s,cell)),q*row.hp/row.max_hp,
            if(fuel,do: Combustion.capacity_j(m,volume)-fuel,else: 0.0),
            if(fuel,do: Map.get(row,:burning,false),else: nil)}
        else
          {0.0,0.0,0.0,nil}
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
        explicit=Phase.explicit_fuel(value,m,q/liquid_capacity(state))
        units=if elem(value,3)==nil,do: moved,
          else: floor(moved*explicit/Combustion.capacity_j(m,q/liquid_capacity(state)))
        removed=elem(value,0)*moved/q
        state=if state.thermal != nil and removed != 0.0,
          do: %{state | thermal: Map.update(state.thermal,:removed_j,removed,&(&1+removed))},else: state
        {state,%{cell=>Phase.scale(value,1-moved/q)},%{},units}

      true ->
        {values,state}=phase_values(state,[cell])
        {state,%{cell=>Phase.merge(Map.fetch!(values,cell),{0.0,moved*1.0,0.0,nil})},%{},-moved}
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

  def at_rest?({energy,integrity},q), do: at_rest?({energy,integrity,0.0,nil},q)
  def at_rest?({energy,integrity,burnt,fire},q),
    do: energy == 0.0 and abs(integrity-q) <= 1.0e-9*q and burnt == 0.0 and fire == nil

  def operate_phase(before,state,actor,request,target,tool) do
    with true <- request.action==1 and phase_target?(state,target) and state.thermal != nil,
         true <- (tool["action"]=="phase.cool" and Phase.liquid?(target.material)) or
           (tool["action"]=="phase.heat" and not Phase.liquid?(target.material)),
         fuel=tool["fuel_material_id"], units=tool["fuel_units"],
         true <- Map.get(state.material_balances,{actor.cid,fuel},0)>=units do
      cell=Damage.macro(target)
      q=Map.get(state.liquid_units,cell,liquid_capacity(state))
      {values,state}=phase_values(state,[cell])
      {energy,integrity,_,_}=Map.fetch!(values,cell)
      result=Phase.tool_energy(energy,q/liquid_capacity(state),state.properties.materials[target.material],tool)
      thermal=state.thermal |> Map.update(:phase_supplied_j,result.supplied_j,&(&1+result.supplied_j))
        |> Map.update(:phase_paid_j,result.paid_j,&(&1+result.paid_j))
        |> Map.update(:phase_unused_j,result.unused_j,&(&1+result.unused_j))
      {state,settlement}=Production.settle_material(%{state | thermal: thermal},actor.cid,fuel,-units)
      settlement=Map.merge(settlement,%{phase_values: %{cell=>{result.energy,integrity}}})
      case Liquids.commit_liquid(state,%{cell=>q},settlement) do
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
    carried=if pick and target.hp>0.0,
      do: {elem(values[cell],0),q*target.pick_baseline_hp/target.max_hp},else: Phase.pair(values[cell])
    amount=Damage.amount(material,tool,0)*q/liquid_capacity(state)
    hp=max(0.0,target.hp-amount)
    target=if pick or request.action==2,do: target,else: Damage.pick_baseline(target,hp)
    target=%{target | hp: hp,seq: state.seq+1,request_id: 0}
    state=%{state | damage: Map.put(state.damage,Damage.key(target),target)}
    values=Map.put(values,cell,{elem(values[cell],0),q*target.hp/target.max_hp})
    settlement=if request.action==2 or target.hp==0.0 do
      carried=if pick or request.action==2,do: carried,else: Phase.pair(values[cell])
      balance=Map.get(state.material_balances,{actor.cid,target.material},0)
      inventory=Phase.add(%{{actor.cid,target.material}=>inventory_phase(state,actor.cid,target.material,balance)},
        {actor.cid,target.material},carried)
      state=%{state | phase_inventory: Map.merge(state.phase_inventory,inventory)}
      {state,paid}=Production.settle_material(state,actor.cid,target.material,q)
      {state,%{cell=>0},Map.merge(paid,%{phase_inventory: inventory,phase_values: %{cell=>{0.0,0.0}}})}
    else
      {state,%{cell=>q},%{phase_values: values}}
    end
    {state,changes,settlement}=settlement
    settlement=Map.put(settlement,:operation,Observation.operation(actor,request,if(request.action==2 or target.hp==0.0,do: 1,else: 0),target))
    case Liquids.commit_liquid(state,changes,settlement) do
      {:ok,next}->{:reply,{:ok,next.seq},next}
      {:error,reason}->{:reply,{:error,reason},before}
    end
  end
end
