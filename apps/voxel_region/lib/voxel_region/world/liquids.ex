defmodule VoxelRegion.World.Liquids do
  @moduledoc """
  全局系统功能：液体：活跃集合调度、接纳来源、流动与提交。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.Prefab
  alias VoxelRegion.{Liquid, Phase, Protection}
  alias MmoContracts.Voxel.Payload
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Payloads, Edits, Tools, Production, Phases}

  # Global system: material21 and its finite units share the existing World commit.
  def liquid_enabled?(state), do: state.liquid_bounds != nil and state.properties != nil and Map.get(state.properties, :liquid) != nil
  def schedule_liquid(state) do
    if liquid_enabled?(state) and state.liquid_timer == nil and MapSet.size(state.liquid_active) > 0 do
      %{state | liquid_timer: Process.send_after(self(), :liquid_commit,
        max(1, round(state.properties.liquid["step_seconds"] * 1000)))}
    else
      state
    end
  end

  def wake_liquid(state, cells) do
    if liquid_enabled?(state) do
      active = cells |> Liquid.neighborhood() |> Enum.filter(&liquid_inside?(&1, state.liquid_bounds)) |> MapSet.new()
      %{state | liquid_active: MapSet.union(state.liquid_active, active)}
    else
      state
    end
  end
  def liquid_inside?({x,y,z}, {{lx,ly,lz},{hx,hy,hz}}), do: x>=lx and x<hx and y>=ly and y<hy and z>=lz and z<hz

  def enable_liquid(before, state) do
    if not liquid_enabled?(before) and liquid_enabled?(state) do
      schedule_liquid(state)
    else
      state
    end
  end

  def adopt_liquid_regions(state, regions) do
    if liquid_enabled?(state),
      do: Enum.reduce(regions, state, &adopt_liquid_sources(&2, &1)), else: state
  end

  def adopt_liquid_sources(state, region) do
    # 全局系统：只接纳本次加载区域（含 ring）的有限液体；地图边界不是启动扫描任务。
    # 从当前 canonical 载荷筛选，再按 owner core 读取，已耗尽源的空气覆盖不会补水。
    {{lx,ly,lz},{hx,hy,hz}}=state.liquid_bounds
    {ox,oy,oz}=Payload.origin(region)
    extent=Payload.extent()
    lo={max(lx,ox),max(ly,oy),max(lz,oz)}
    hi={min(hx,ox+extent),min(hy,oy+extent),min(hz,oz+extent)}
    {ax,ay,az}=lo
    {bx,by,bz}=hi
    if ax<bx and ay<by and az<bz do
      with {:ok,bytes,_,state} <- Payloads.payload_bytes(state,0,region),
           {:ok,payload} <- Payload.decode(bytes) do
        cells=if :binary.match(payload.cells,[<<21,0>>,<<22,0>>]) == :nomatch do
          []
        else
          for x<-ax..(bx-1),y<-ay..(by-1),z<-az..(bz-1),
            not Map.has_key?(state.liquid_units,{x,y,z}),
            Phase.liquid?(Payload.material(payload,Payload.local(region,{x,y,z}))),do: {x,y,z}
        end
        Enum.reduce([21,22],state,fn material,s ->
          {_open,water,s}=liquid_cells(s,cells,material)
          if map_size(water)==0 do
            s
          else
            {:ok,s}=commit_liquid(s,water,%{liquid_wake: false,liquid_material: material})
            s
          end
        end)
      else
        # 保留实际请求入口的 missing/canonical_incomplete 错误，不把缺失源当空气。
        {:error,_,state} -> state
        {:error,_} -> state
      end
    else
      state
    end
  end

  def raw_liquid_edit(state, edits) do
    Enum.reduce_while(edits, :ok, fn {cell, material}, :ok ->
      case cell_value(state, 0, cell) do
        {:ok, {old,_}, _} ->
          if Phase.liquid?(old) or Phase.liquid?(material) or phase_material?(state,old) or phase_material?(state,material),
            do: {:halt, {:error,:use_liquid_tool}}, else: {:cont,:ok}
        _ -> {:cont, :ok}
      end
    end)
  end

  def liquid_cells(state, cells, liquid_material) do
    Enum.reduce(Enum.uniq(cells), {%{},%{},state}, fn cell,{open,water,s} ->
      region=region_of(cell)
      if Edits.needs_source?(s,{0,region}), do: :ok=s.source.ensure(s.source_state,0,region)
      {:ok,{material,_},s}=cell_value(s,0,cell)
      # Legacy Water21 without a suffix is a full macro, not an empty cell.
      # 散体只有带数量记录的同种格参与流动；天然与建造的同种满格静止，与其他材料一样是墙（D1）。
      same=material==liquid_material and (Phase.liquid?(material) or Map.has_key?(s.liquid_units,cell))
      # 地面花草可被替换：流入时视同空气，写入即覆盖它。refined 宏格不带数量（D8）。
      available=(material==0 or same or MmoContracts.VoxelMaterialCatalog.flora?(material)) and not Map.has_key?(s.refined,cell)
      water=if same, do: Map.put(water,cell,Map.get(s.liquid_units,cell,liquid_capacity(s))), else: water
      {Map.put(open,cell,available),water,s}
    end)
  end

  # 工具 11/12（liquid.scoop / liquid.pour）同时服务液体与散体；倾倒即建造（受保护区域许可在 build_target 先裁决）。
  def transfer_liquid(before, actor, request) do
    expected=if request.action==2,do: "liquid.scoop",else: "liquid.pour"
    with true <- liquid_enabled?(before),
         true <- Phases.flowing_material?(before,request.material) and request.material in before.production_materials,
         true <- liquid_inside?(request.coord,before.liquid_bounds),
         {:ok,tool} <- Map.fetch(before.properties.tools,request.tool_id),
         true <- tool["action"] == expected,
         :ok <- Production.build_reach(actor.eye,request.coord,tool["range_macro"]),
         :ok <- liquid_sight(before,actor.eye,request.coord),
         # D8：数量按宏格存储，细分宏格（micro 开口）不带数量；客户端据此提示“开口需至少 1 m”。
         :ok <- if(Map.has_key?(before.refined,request.coord),do: {:error,:needs_macro_opening},else: :ok),
         {:ok,session} <- Damage.admit_attack(Map.get(before.tool_sessions,actor.player),
           request.client_intent_seq,actor.received_us,ceil(tool["interval_seconds"]*1_000_000),actor.tick_us) do
      state=%{before | tool_sessions: Map.put(before.tool_sessions,actor.player,session)}
      with {:ok,_}=result <- move_flowing(state,actor.cid,request.coord,request.material,request.action,tool["liquid_transfer_units"]) do
        unless Map.has_key?(before.tool_sessions,actor.player), do: Process.monitor(actor.player)
        result
      end
    else
      false -> {:error,:invalid_liquid_operation}
      :error -> {:error,:invalid_tool}
      {:error,_}=error -> error
    end
  end

  # 盛取（action 2）/ 倾倒（action 3）一格至多 limit 单位的流动材料：数量、相态账与余额同一笔提交。
  # 玩家盛倒（`transfer_liquid/3`）与死亡掉落（`death_drop/3`）共用。
  def move_flowing(state,cid,cell,material,action,limit) do
    {open,water,state}=liquid_cells(state,[cell],material)
    balance=Production.balance_state(state,cid,material).balance
    transfer=case action do
      2 -> Liquid.scoop(water,cell,balance,limit)
      3 -> Liquid.pour(water,cell,balance,limit,liquid_capacity(state),state.liquid_bounds,&Map.fetch!(open,&1))
    end
    if transfer.transferred_units == 0 or not Map.fetch!(open,cell) do
      {:error,:no_liquid_transfer}
    else
      {state,carried,inventory,units}=Phases.transfer_phase_inventory(state,cid,cell,material,action,transfer.transferred_units,balance)
      {state,settlement}=Production.settle_material(state,cid,material,units)
      settlement=Map.merge(settlement,%{phase_values: carried,phase_inventory: inventory,liquid_material: material})
      commit_liquid(state,transfer.changes,settlement)
    end
  end

  def liquid_sight(state,eye,coord) do
    delta=Enum.zip_with(Tuple.to_list(coord),Tuple.to_list(eye),&(&1+0.5-&2))
    distance=:math.sqrt(Enum.sum(Enum.map(delta,&(&1*&1))))
    if distance==0 do
      :ok
    else
      direction=delta |> Enum.map(&(&1/distance)) |> List.to_tuple()
      # Water itself is transparent; canonical solid macro/refined cells occlude.
      # 目标格本身不算遮挡：往部分装填的散体格上继续倾倒时，射线终点（格心）可能低于料面（R8-07）。
      at=fn micro,s ->
        case if(elem(Prefab.macro_slot(micro),0)==coord,do: {nil,s},else: target_at(micro,s)) do
          {%{material: material},s} when material in [21,22]->{nil,s}
          {%{granularity: 0}=target,s}->
            if finite_target?(s,target) do
              cell=Damage.macro(target)
              height=Map.get(s.liquid_units,cell,liquid_capacity(s))/liquid_capacity(s)
              {if(Tools.finite_phase_ray?(eye,direction,distance,cell,height),do: target,else: nil),s}
            else
              {target,s}
            end
          other->other
        end
      end
      case Damage.raycast(eye,direction,distance,state,at) do
        {:error,:no_target,_}->:ok
        {:ok,_,_}->{:error,:occluded_liquid}
      end
    end
  end

  def commit_liquid(state, changes, settlement, extra_edits \\ [], owners \\ MapSet.new(), attachments \\ MapSet.new()) do
    liquid_material=Map.get(settlement,:liquid_material,21)
    for {level,region}=key <- Enum.uniq(Edits.edit_keys(Map.keys(changes))), Edits.needs_source?(state,key),
      do: :ok=state.source.ensure(state.source_state,level,region)
    {values,state}=Phases.phase_values(state,Map.keys(changes))
    supplied_values=Map.get(settlement,:phase_values,%{})
    {edits,next_values}=if Phases.finite_enabled?(state) do
      current=Map.new(changes,fn {cell,_q}->
        {:ok,{old,_},_}=cell_value(state,0,cell)
        {cell,{old,Map.fetch!(values,cell)}}
      end)
      Phase.settle(changes,current,supplied_values,%{materials: state.properties.materials,
        capacity: liquid_capacity(state),ambient: state.thermal && Phases.phase_ambient(state),material: liquid_material})
    else
      {Enum.map(changes,fn {cell,q}->{cell,if(q==0,do: 0,else: liquid_material)} end),
        Map.merge(values,supplied_values)}
    end
    state=fuel_ledger(state,liquid_material,values,next_values,changes)
    settlement=Map.merge(settlement,%{liquid_changes: changes,phase_values: next_values})
    Edits.apply_batch(state,edits++extra_edits,false,settlement,owners,attachments)
  end

  # 燃料账：已初始化剩余燃料随数量搬运时总量不变；隐含满燃料的格与带燃料的量相遇即初始化（记入初始化账），
  # 舀出已初始化燃料离开世界（记入弃置账）。前后之差只在可燃散体上非零。
  def fuel_ledger(%{thermal: nil}=state,_material,_before,_after,_changes), do: state
  def fuel_ledger(state,material,before,next,changes) do
    m=state.properties.materials[material]
    capacity=liquid_capacity(state)
    delta=Enum.reduce(next,0.0,fn {cell,value},sum ->
      old=Map.get(before,cell,{0.0,0.0,0.0,nil})
      sum+Phase.explicit_fuel(value,m,Map.get(changes,cell,0)/capacity)-
        Phase.explicit_fuel(old,m,Map.get(state.liquid_units,cell,capacity)/capacity)
    end)
    cond do
      delta > 0.0 -> %{state | thermal: Map.update(state.thermal,:fuel_initialized_j,delta,&(&1+delta))}
      delta < 0.0 -> %{state | thermal: Map.update(state.thermal,:discarded_fuel_j,-delta,&(&1-delta))}
      true -> state
    end
  end

  # 多材料调度：活跃集合周边出现的每种流动材料（液体、带数量记录的散体）各跑一次同一个数量内核，
  # 侧向阈值按材料取（液体用液体参数，散体用目录 loose_threshold_units，决定静止休止角 atan(t / 容量)）。
  def advance_liquid(state, active) do
    # Two stages need the downward cell and the horizontal neighbors of both levels.
    cells=for {x,y,z} <- active, dy <- [0,-1],
      {dx,dz} <- [{0,0},{-1,0},{1,0},{0,-1},{0,1}],
      cell={x+dx,y+dy,z+dz}, liquid_inside?(cell,state.liquid_bounds), do: cell
    cells=Enum.uniq(cells)
    falling=for {m,[_|_]} <- state.liquid_falls, into: MapSet.new(), do: m
    {kinds,state}=Enum.reduce(cells,{falling,state},fn cell,{kinds,s} ->
      if Edits.needs_source?(s,{0,region_of(cell)}), do: :ok=s.source.ensure(s.source_state,0,region_of(cell))
      {:ok,{m,_},s}=cell_value(s,0,cell)
      {if(Phase.liquid?(m) or (loose_material?(s,m) and Map.has_key?(s.liquid_units,cell)),
        do: MapSet.put(kinds,m),else: kinds),s}
    end)
    Enum.reduce(Enum.sort(kinds),state,&advance_liquid(&2,&1,active,cells))
  end

  def advance_liquid(state,material,active,cells) do
    {open,water,state}=liquid_cells(state,cells,material)
    config=state.properties.liquid
    threshold=if Phase.liquid?(material),do: Map.get(config,"side_threshold_units",0),
      else: state.properties.materials[material]["loose_threshold_units"]
    # 下落留在同一列（同一持有者）；侧流不跨受保护区域边界。
    connected = if not Protection.empty?(state.protection),
      do: fn a, b -> Protection.same_holder?(state.protection, a, b) end
    {changes,stages}=Liquid.step_transfers(water,state.liquid_bounds,liquid_capacity(state),
      config["gravity_units_per_step"],config["side_units_per_step"],&Map.get(open,&1,false),
      threshold,active,connected)
    {values,state}=Phases.phase_values(state,Map.keys(water))
    {changes,values}=if Phases.finite_enabled?(state),do: Phase.transport_stages(values,water,changes,stages),else: {changes,%{}}
    state = %{state | liquid_active: MapSet.union(state.liquid_active, Liquid.next_active(stages))}
    settlement = %{phase_values: values, liquid_material: material}
    # 下落帧只描述液体（codec 契约）；散体下落不发帧。
    falls = if Phase.liquid?(material), do: Liquid.fall_transfers(stages), else: []
    previous = Map.get(state.liquid_falls, material, [])
    settlement = if falls != [] or previous != [],
      do: Map.put(settlement, :liquid_falls, %{material: material, transfers: falls}), else: settlement
    case commit_liquid(state,changes,settlement) do
      {:ok,next}->%{next | liquid_falls: Map.put(next.liquid_falls, material, falls)}
      {:error,reason}->Logger.error("voxel_liquid_commit failed=#{inspect(reason)}"); state
    end
  end
end
