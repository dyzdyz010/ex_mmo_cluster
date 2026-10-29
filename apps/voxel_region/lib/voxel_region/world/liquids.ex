defmodule VoxelRegion.World.Liquids do
  @moduledoc """
  全局系统功能：液体：活跃集合调度、接纳来源、流动与提交。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.World.Clock
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.Prefab
  alias VoxelRegion.{Liquid, Phase, Protection}
  alias MmoContracts.Voxel.Payload
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Payloads, Edits, Tools, Production, Phases, Log, Observation}

  # Global system: material21 and its finite units share the existing World commit.
  def liquid_enabled?(state), do: state.liquid_bounds != nil and state.properties != nil and Map.get(state.properties, :liquid) != nil

  @doc "当前活动下一自然步会读取的完整 XYZ 两层邻域；due／装页失败不释放原活动需求。"
  def residency_dependencies(state), do: {:ok, {seed_keys(state), [], []}}

  @doc "步前装页与驻留共用实际读取种子；域外唤醒格只参与原活动调度，不额外要求其邻页。"
  def seed_keys(state) do
    state.liquid_active |> step_cells(state.liquid_bounds)
      |> Enum.map(&{0, region_of(&1)}) |> Enum.uniq() |> VoxelRegion.World.Pages.with_ancestors()
  end

  # 活动步与驻留投影共用实际读取单元，不各自维护一套邻域。
  defp step_cells(active, bounds) do
    for {x,y,z} <- active, dy <- [0,-1],
      {dx,dz} <- [{0,0},{-1,0},{1,0},{0,-1},{0,1}],
      cell={x+dx,y+dy,z+dz}, liquid_inside?(cell,bounds), uniq: true, do: cell
  end
  @doc "按世界活动前沿或上一拍下落帧排程；自然达稳态且清帧后休眠，与玩家窗口无关。"
  def schedule_liquid(%{page_load: %{sim: %{status: :failed}}} = state) do
    if state.liquid_timer, do: Clock.cancel_timer(state, state.liquid_timer)
    %{state | liquid_timer: nil}
  end
  def schedule_liquid(state) do
    pending = liquid_enabled?(state) and
      (MapSet.size(state.liquid_active) > 0 or Enum.any?(state.liquid_falls, fn {_, falls} -> falls != [] end))
    cond do
      pending and state.liquid_timer == nil ->
        now = Clock.monotonic(state)
        due = state.liquid_due || now + interval_ms(state)
        %{state | liquid_due: due, liquid_timer: Clock.send_after(state, self(), {:liquid_tick, due}, max(due - now, 0))}
      not pending ->
        if state.liquid_timer, do: Clock.cancel_timer(state, state.liquid_timer)
        %{state | liquid_timer: nil, liquid_due: nil}
      true -> state
    end
  end

  @doc "液体目录所定义的自然步时长；投递与完成进度使用同一值。"
  def interval_ms(state), do: max(1, round(state.properties.liquid["step_seconds"] * 1000))

  @doc "自然步提交完成后消费该到期事件；显式强制步不消费未来定时事件。"
  def completed(state, scheduled_due) do
    if state.liquid_timer, do: Clock.cancel_timer(state, state.liquid_timer)
    due = if scheduled_due, do: scheduled_due + interval_ms(state), else: state.liquid_due
    %{state | liquid_due: due, liquid_timer: nil} |> schedule_liquid()
  end

  @doc "只读液体调度前沿与欠账，不代表历史世界状态；单调毫秒仅同VM可比，自然稳态无待推进时间。"
  def progress(state) do
    due = state.liquid_due
    now = Clock.monotonic(state)
    interval = if due, do: interval_ms(state), else: 0
    through = if due, do: due - interval
    reason = cond do
      VoxelRegion.World.PageLoad.failure(state) != nil -> :page_io_failed
      due == nil -> :rest
      state.page_store.level in [:mid, :hard] -> :writeback
      state.page_load.sim != nil -> :page_io
      true -> :timer
    end
    %{next_due_ms: due, simulated_through_ms: through, target_through_ms: if(due, do: now),
      lag_ms: if(through, do: max(now - through, 0), else: 0),
      pending_steps: if(due && now >= due, do: div(now - due, interval) + 1, else: 0),
      wait_reason: reason, active_cells: MapSet.size(state.liquid_active)}
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
  defp in_box?(cell, lo, hi), do: liquid_inside?(cell, {lo, hi})

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
    case Payloads.checked_liquid(state, region) do
      {:checked, state} -> state
      :unchecked -> check_liquid_sources(state, region)
    end
  end

  defp check_liquid_sources(state, region) do
    # 全局系统：只接纳本次加载区域（含 ring）的有限液体；地图边界不是启动扫描任务。
    # 地形只给保守候选，最终仍按 canonical owner core 读取；不为筛材质编完整 refined 载荷。
    {{lx,ly,lz},{hx,hy,hz}}=state.liquid_bounds
    {ox,oy,oz}=Payload.origin(region)
    extent=Payload.extent()
    lo={max(lx,ox),max(ly,oy),max(lz,oz)}
    hi={min(hx,ox+extent),min(hy,oy+extent),min(hz,oz+extent)}
    {ax,ay,az}=lo
    {bx,by,bz}=hi
    if ax<bx and ay<by and az<bz do
      with {:ok,materials,overrides,loaded} <- Payloads.terrain_materials(state,0,region),
           # 完整内容身份仅保留32字节；不能持有展开的ring map或源材料段的大父二进制。
           # 材料平面长度由Payload合同固定；分段喂同一摘要，不为指纹再复制整段材料到ETF。
           terrain = :crypto.hash_init(:sha256)
             |> :crypto.hash_update(materials)
             |> :crypto.hash_update(:erlang.term_to_binary(overrides, [:deterministic]))
             |> :crypto.hash_final(),
           {:unchecked,_} <- if(Map.get(loaded.liquid_adopted,region) == terrain, do: {:checked,loaded}, else: {:unchecked,loaded}) do
        state = loaded
        pending = fn cell -> in_box?(cell,lo,hi) and not Map.has_key?(state.liquid_units,cell) end
        # 液体材料只有 21／22（Phase.liquid?/1）；材料 id 是 u16 小端，只取偶数偏移处的匹配，按 x、y、z 字典序。
        baseline=for({at,_} <- :binary.matches(materials,[<<21,0>>,<<22,0>>]), rem(at,2) == 0,
          index = div(at,2), cell = {ox+rem(index,extent),oy+rem(div(index,extent),extent),oz+div(index,extent*extent)},
          pending.(cell), do: cell)
        changed=for {{x,y,z},{material,_}} <- overrides, Phase.liquid?(material),
          cell={ox+x,oy+y,oz+z}, pending.(cell), do: cell
        cells=(baseline ++ changed) |> Enum.uniq() |> Enum.sort()
        state = if cells == [] do
          %{state | liquid_adopted: Map.put(state.liquid_adopted,region,terrain)}
          |> Payloads.mark_liquid_checked(region)
        else
          state
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
        {:checked,loaded} -> Payloads.mark_liquid_checked(loaded, region)
        # 保留实际请求入口的 missing/canonical_incomplete 错误，不把缺失源当空气。
        {:error,_,state} -> state
        {:error,_} -> state
      end
    else
      state
    end
  end

  @doc """
  作者 / GM 编辑不得直接改写液体或相态格（改走液体工具）：`{:ok, state}`（带回本次读到的 baseline 解码缓存，
  同一冷区不再逐格重读重解码，M2a 遗留项）或 `{:error, :use_liquid_tool}`。
  """
  def raw_liquid_edit(state, edits) do
    Enum.reduce_while(edits, {:ok, state}, fn {cell, material}, {:ok, s} ->
      case cell_value(s, 0, cell) do
        {:ok, {old,_}, s} ->
          if Phase.liquid?(old) or Phase.liquid?(material) or phase_material?(s,old) or phase_material?(s,material),
            do: {:halt, {:error,:use_liquid_tool}}, else: {:cont,{:ok,s}}
        {:error, _, s} -> {:cont, {:ok, s}}
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

  # 只测试作者注水（`World.liquid_fill/7`）：洪泛、扣量、相态库存与数量同一笔提交，回执与 material_supply 共用防重表。
  def liquid_fill_commit(before,cid,key,material,seed,level_y,max_cells) do
    receipt_key={cid,{:liquid_fill,key}}
    with true <- (is_integer(cid) and cid > 0 and is_binary(key) and byte_size(key) > 0) || {:error,:invalid_liquid_fill},
         {:ok,moved,state} <- fill_plan(before,material,seed,level_y,max_cells,cid),
         units = Enum.sum(Enum.map(moved,&elem(&1,1))),
         balance = Production.balance_state(state,cid,material).balance,
         true <- balance >= units || {:error,:insufficient_material} do
      # 逐格沿正式倾倒的相态搬运（库存焓按实际量分给每格），最后一次结算余额。
      {state,values,inventory,_}=Enum.reduce(moved,{state,%{},%{},balance},fn {cell,n},{s,values,inventory,left} ->
        {s,carried,held,_}=Phases.transfer_phase_inventory(s,cid,cell,material,3,n,left)
        {s,Map.merge(values,carried),Map.merge(inventory,held),left-n}
      end)
      {state,settlement}=Production.settle_material(state,cid,material,-units)
      receipt=%{seq: state.seq+1,material: material,units: units,cells: length(moved)}
      fill_commit(state,moved,receipt_key,receipt,Map.merge(settlement,%{phase_values: values,phase_inventory: inventory}))
    else
      {:error,_}=error -> error
    end
  end

  # 只测试 GM 灌满（`World.Gm`）：同一洪泛与液体提交，不扣库存、不受保护区域限制；注入量按作者供给记相态焓
  # （液相温度取 max(环境, 转变点)，计入 phase_authored 账），与 material_supply 同一口径。
  def gm_liquid_fill(before,material,seed,level_y,max_cells,receipt_key,receipt) do
    with {:ok,moved,state} <- fill_plan(before,material,seed,level_y,max_cells,nil) do
      units=Enum.sum(Enum.map(moved,&elem(&1,1)))
      {state,values}=if phase_material?(state,material) do
        m=state.properties.materials[material]
        energy=Phase.energy(%{material: material},units/liquid_capacity(state),m,max(Phases.phase_ambient(state),m["phase_transition_kelvin"]))
        {values,state}=Phases.phase_values(state,Enum.map(moved,&elem(&1,0)))
        {values,_}=Enum.reduce(moved,{values,{{energy,units*1.0},units}},fn {cell,n},{values,{carried,left}} ->
          {e,i,b,f}=Map.fetch!(values,cell)
          {{e,i},carried}=Phase.transfer({e,i},carried,left,n,:pour)
          {Map.put(values,cell,{e,i,b,f}),{carried,left-n}}
        end)
        thermal=state.thermal |> Map.update(:phase_authored_energy_j,energy,&(&1+energy))
          |> Map.update(:phase_authored_units,units,&(&1+units))
        {%{state | thermal: thermal},Map.take(values,Enum.map(moved,&elem(&1,0)))}
      else
        {state,%{}}
      end
      fill_commit(state,moved,receipt_key,Map.merge(receipt,%{units: units,cells: length(moved)}),%{phase_values: values})
    end
  end

  # 洪泛并算出每格还差多少；cid 非 nil 时洪泛不跨受保护持有者、且须可在其中建造。
  defp fill_plan(before,material,{_,sy,_}=seed,level_y,max_cells,cid) do
    capacity=liquid_capacity(before)
    with true <- (liquid_enabled?(before) and Phase.liquid?(material) and material in before.production_materials and
             is_integer(level_y) and sy <= level_y and liquid_inside?(seed,before.liquid_bounds)) || {:error,:invalid_liquid_fill},
         {:ok,cells,state} <- flood(before,material,seed,level_y,max_cells,cid != nil),
         # 注入格的提交（后像 ring、逐级归约）读这些格所在页的邻页与各级粗层页：同样要已驻留。
         [] <- closure_missing(state,cells),
         true <- cid == nil or Protection.permitted?(state.protection,{:character,cid},cells) || {:error,:protected_region},
         {_open,water,state} = liquid_cells(state,cells,material),
         moved = for(cell <- cells, q = Map.get(water,cell,0), q < capacity, do: {cell,capacity-q}),
         true <- moved != [] || {:error,:no_liquid_transfer} do
      {:ok,moved,state}
    end
  end

  defp fill_commit(state,moved,receipt_key,receipt,settlement) do
    material=receipt.material
    state=%{state | material_supplies: Map.put(state.material_supplies,receipt_key,receipt)}
    settlement=Map.merge(settlement,%{liquid_material: material,material_supplies: %{receipt_key => receipt}})
    with {:ok,next} <- commit_liquid(state,Map.new(moved,fn {cell,_}->{cell,liquid_capacity(state)} end),settlement) do
      true=next.seq==receipt.seq
      {:ok,receipt,next}
    end
  end

  defp closure_missing(%{resident: :all},_cells), do: []
  defp closure_missing(state,cells) do
    case VoxelRegion.World.PageLoad.missing_keys(state,{Edits.edit_keys(cells),[],[]}) do
      [] -> []
      keys -> {:error,{:pages_missing,keys}}
    end
  end

  # 六邻洪泛：只走该液体可进入的开放格（liquid_cells 的 open?），y ≤ level_y、计算域内、不跨受保护区域持有者。
  defp flood(state,material,seed,level_y,max_cells,protected?) do
    {open,_,state}=liquid_cells(state,[seed],material)
    if Map.fetch!(open,seed),
      do: flood(state,material,[seed],MapSet.new([seed]),MapSet.new([seed]),level_y,max_cells,protected?),
      else: {:error,:occupied}
  end

  defp flood(state,_material,[],_seen,cells,_level_y,_max_cells,_protected?),do: {:ok,Enum.sort(cells),state}
  defp flood(state,material,frontier,seen,cells,level_y,max_cells,protected?) do
    candidates=for {x,y,z}=from <- frontier,
      to <- [{x-1,y,z},{x+1,y,z},{x,y-1,z},{x,y+1,z},{x,y,z-1},{x,y,z+1}],
      elem(to,1) <= level_y, liquid_inside?(to,state.liquid_bounds), not MapSet.member?(seen,to),
      not protected? or Protection.same_holder?(state.protection,from,to), uniq: true, do: to
    # 洪泛没有离 seed 的空间上界：伸进未驻留页就停下，交调用方装页后从头重新裁决（父稿 P4，评审 A2），不把冷页当空气继续。
    cold=for cell <- candidates, key={0,region_of(cell)}, not VoxelRegion.World.Pages.resident?(state,key), uniq: true, do: key
    if cold != [] do
      {:error,{:pages_missing,cold}}
    else
      flood_step(state,material,candidates,cells,seen,level_y,max_cells,protected?)
    end
  end

  defp flood_step(state,material,candidates,cells,seen,level_y,max_cells,protected?) do
    {open,_,state}=liquid_cells(state,candidates,material)
    reached=Enum.filter(candidates,&Map.fetch!(open,&1))
    cells=MapSet.union(cells,MapSet.new(reached))
    if MapSet.size(cells) > max_cells,
      do: {:error,:liquid_fill_too_large},
      else: flood(state,material,reached,MapSet.union(seen,MapSet.new(candidates)),cells,level_y,max_cells,protected?)
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
  # 侧向阈值按材料取：散体用目录 loose_threshold_units 作休止角（atan(t / 容量)）；液体的 side_threshold_units
  # 只作润湿门槛（流向干格须超出它），湿格之间按静水平衡摊平（`Liquid` 模块说明）。
  @doc """
  步进后活动集变了而没有数量变化（趋静、唤醒）时提交一笔无几何事务记下它（m2a §4.2，评审 R4）：活动集决定液体是否继续排程，
  日志与页表里的活动集须与在线一致，恢复后不靠相邻改动重新激活。有数量变化的步进已由其事务带上活动集，与上次记住的值相同即不提交。
  """
  def commit_active(%{liquid_active: active, pages: %{remembered: %{liquid_active: active}}} = state), do: state

  def commit_active(state) do
    before = state
    state = %{state | seq: state.seq + 1}
    txn = %{seq: state.seq, entries: [], coarse: []}
    :ok = Log.append_log(before, state, txn)
    state = Log.remember_entry(state, txn)
    Observation.fanout(state, txn)
    Observation.fanout_canonical(state, txn, [], [], state)
    state
  end

  @doc "从实际活动前沿的物理邻域构造输入；空活动集仍清除上一拍下落帧。"
  def advance_liquid(state, active) do
    # 两阶段读取下层以及两层的水平邻格，与驻留依赖共用同一足迹。
    cells=step_cells(active,state.liquid_bounds)
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
    threshold=if Phase.liquid?(material),do: {:wetting,Map.get(config,"side_threshold_units",0)},
      else: {:repose,state.properties.materials[material]["loose_threshold_units"]}
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
