defmodule VoxelRegion.Circuit do
  @moduledoc "全局系统功能：从规范占用重建直流拓扑，生成独立电气观察与按热节点分配的功率。"
  alias VoxelRegion.{Attachments,Damage,DCNetwork,ThermalGeometry}
  @micro VoxelRegion.Spatial.micro_resolution()
  @length 1.0/@micro

  @doc "设备完整方形足迹；两端口沿第一切向轴，支持宏面和微面。"
  def shape(slots) do
    [{0,axis,p}|_]=Enum.sort(slots)
    size=round(:math.sqrt(length(slots)))
    if size in [1,@micro] and MapSet.new(slots)==MapSet.new(Attachments.footprint(0,axis,p,size)),do: {:ok,p,size},else: {:error,:broken_device_face}
  end

  @doc "仅当前已安装设备参与模拟；设备真值在整件附件属性记录中。R8-04 增量 2 起只有电源（kind 1）还是设备。"
  def devices(damage),do: for {_,%{granularity: 3,circuit: c}=t}<-damage,t.flags==0,into: %{},do: {t.incarnation,{t,c}}

  @doc """
  目标此刻的体积电导率 S/m。开关材料（目录 `circuit_switch`）只在其属性行 `closed` 为真时按目录值导电，
  缺省（没有行或未闭合）断开、绝缘；格用自身行（微格用 granularity 1 热行），附件用整件行。
  """
  def sigma(catalog,damage,target) do
    m=catalog.materials[target.material]
    if Map.get(m,"circuit_switch",false) and not Map.get(Map.get(damage,Damage.key(target),%{}),:closed,false),
      do: 0.0,else: Map.get(m,"electrical_conductivity",0.0)
  end

  @doc """
  由已安装设备、目录和附件导体准备网络；不读取 canonical 占用。
  domain（可选）把附件槽映射到其受保护区域持有者：端点按持有者分开，跨持有者边界的导线/设备不在端点处相连；
  nil 时端点为 `{:point, p}`，与无此参数时逐位相同。
  """
  def prepare(slots,damage,catalog,duration,domain \\ nil) do
    started=System.monotonic_time(:microsecond)
    devices=devices(damage)
    grouped=Enum.group_by(slots,fn {_,{id,_}}->id end,fn {slot,_}->slot end)
    {edges,faces}=Enum.reduce(devices,{[],MapSet.new()},fn {id,{target,c}},{edges,faces}->
      footprint=Attachments.footprint(0,rem(elem(target.owner,1),3),c.anchor,c.size)
      intact=MapSet.new(Map.get(grouped,id,[]))==MapSet.new(footprint)
      u=Enum.find(0..2,&(&1 != rem(elem(target.owner,1),3)))
      tool=catalog.tools[c.tool_id]
      o=domain && owner(domain,footprint)
      # 电源内阻的 I²R 均分到足迹各槽，不发光。退役工具的设备行（迁移前）没有能源，不导电。
      edge=%{a: node(c.anchor,domain,o),b: node(offset(c.anchor,u,c.size),domain,o),r: tool["circuit_resistance_ohm"],
        emf: tool["circuit_voltage_v"],device: id,heat: for(s<-footprint,do: {VoxelRegion.ThermalAttachments.key(s),1.0/length(footprint),0.0})}
      {if(intact and c.remaining_j>0,do: [edge|edges],else: edges),Enum.reduce(footprint,faces,&MapSet.put(&2,&1))}
    end)
    section=catalog.attachments["line_section_m2"]
    {edges,luminous}=Enum.reduce(slots,{edges,%{}},fn {slot={kind,axis,p},{id,material}},{edges,luminous}->
      sigma=sigma(catalog,damage,Attachments.identity(slot,{id,material}))
      if sigma>0 and not MapSet.member?(faces,slot) do
        key=VoxelRegion.ThermalAttachments.key(slot)
        lum=luminous_fraction(catalog,material)
        heat=[{key,1.0,lum}]
        luminous=if lum>0,do: Map.put(luminous,key,Attachments.identity(slot,{id,material}) |> Map.put(:granularity,4)),else: luminous
        o=domain && domain.(slot)
        edges=if kind==1 do
          [edge(node(p,domain,o),node(offset(p,axis,1),domain,o),@length/(sigma*section),heat)|edges]
        else
          [u,v]=Enum.reject(0..2,&(&1==axis))
          corners=[p,offset(p,u,1),offset(p,v,1),p |> offset(u,1) |> offset(v,1)]
          r=2.0/(sigma*catalog.attachments["face_thickness_m"])
          for {a,b}<-[{0,1},{0,2},{1,3},{2,3}],reduce: edges do
            acc->[edge(node(Enum.at(corners,a),domain,o),node(Enum.at(corners,b),domain,o),r,heat)|acc]
          end
        end
        {edges,luminous}
      else
        {edges,luminous}
      end
    end)
    %{devices: devices, grouped: grouped, catalog: catalog, edges: edges, luminous: luminous,
      duration: duration, started: started}
  end

  @doc "需要接入实体导体的端点节点（`{:point, p}` 或带持有者的 `{:point, p, holder}`）；保持原边顺序。"
  def points(input), do: input.edges |> Enum.flat_map(&[&1.a,&1.b]) |> Enum.uniq()

  @doc "端点节点周围的八个 canonical 微格采样点。"
  def near_points(point), do: for(x<-[-1,0],y<-[-1,0],z<-[-1,0],do: add(elem(point,1),{x,y,z}))

  @doc "按首次命中身份保留此刻导电的真实导体（断开的开关不算），微格使用独立热身份。"
  def conductors(targets,catalog,damage) do
    targets |> Enum.reject(&is_nil/1) |> Enum.map(&thermal_target/1)
      |> Enum.uniq_by(&ThermalGeometry.key/1)
      |> Enum.filter(&(sigma(catalog,damage,&1)>0))
  end

  @doc """
  求解冻结的端点宿主与实占用接触摘要，输出功率和设备状态，不返回世界。

  每条支路的 I²R 按两侧各自的电阻份额分给两侧热节点（接触边 r = r_a + r_b，a 得 r_a/r）；节点所在材料的
  `luminous_fraction` λ 那一份离开热账记为光（`light_j`），其余进热节点。发光节点另给出电功率与通过电流
  （`electric`：热键 → {目标, W, A}；A = 该节点全部非设备支路 |i| 之和的一半，即两端导体的穿过电流）。
  """
  def plan(input,hosts,contacts) do
    %{devices: devices,grouped: grouped,catalog: catalog,edges: edges,luminous: luminous,
      duration: duration,started: started}=input
    section=catalog.attachments["line_section_m2"]
    {edges,luminous}=Enum.reduce(points(input),{edges,luminous},fn p,acc ->
      Enum.reduce(Map.fetch!(hosts,p),acc,fn target,{edges,luminous} ->
        key=ThermalGeometry.key(target)
        sigma=catalog.materials[target.material]["electrical_conductivity"]
        lum=luminous_fraction(catalog,target.material)
        {[edge(p,{:solid,key},size(target)/2/(sigma*section),[{key,1.0,lum}])|edges],glowing(luminous,key,target,lum)}
      end)
    end)
    # owner 保留原遍历和前插次序；纯计算按同一边顺序求解，避免浮点累加漂移。
    {contact_edges,luminous}=Enum.map_reduce(contacts,luminous,fn {target,other,area},luminous ->
      a=ThermalGeometry.key(target); b=ThermalGeometry.key(other)
      ra=size(target)/catalog.materials[target.material]["electrical_conductivity"]/2/area
      rb=size(other)/catalog.materials[other.material]["electrical_conductivity"]/2/area
      la=luminous_fraction(catalog,target.material); lb=luminous_fraction(catalog,other.material)
      {edge({:solid,a},{:solid,b},ra+rb,[{a,ra/(ra+rb),la},{b,rb/(ra+rb),lb}]),
        luminous |> glowing(a,target,la) |> glowing(b,other,lb)}
    end)
    edges=contact_edges++edges
    result=DCNetwork.solve(edges)
    reset=Map.new(devices,fn {id,{t,c}} ->
      intact=MapSet.new(Map.get(grouped,id,[]))==MapSet.new(Attachments.footprint(0,rem(elem(t.owner,1),3),c.anchor,c.size))
      {id,%{c | voltage_v: 0.0,current_a: 0.0,power_w: 0.0,fault: if(intact,do: 0,else: 1)}}
    end)
    {outputs,powers,source_w,light_w,electric}=Enum.zip(edges,result.currents) |> Enum.with_index() |> Enum.reduce({reset,%{},%{},0.0,%{}},fn {{e,i},index},{out,heat,sources,light,electric}->
      # 实跑开路残差约 8e-11 A；低于 1e-10 A 的消元舍入不作为供能。
      i=if abs(i)<1.0e-10,do: 0.0,else: i
      watts=i*i*e.r
      {heat,light}=Enum.reduce(e.heat,{heat,light},fn {key,weight,lum},{h,light}->
        {Map.update(h,key,watts*weight*(1.0-lum),&(&1+watts*weight*(1.0-lum))),light+watts*weight*lum}
      end)
      electric=if e.device,do: electric,else: Enum.reduce(e.heat,electric,fn {key,weight,lum},acc->
        if lum>0,do: Map.update(acc,key,{watts*weight,abs(i)},fn {w,a}->{w+watts*weight,a+abs(i)} end),else: acc
      end)
      if e.device do
        c=Map.fetch!(out,e.device)
        v=result.volts[e.a]-result.volts[e.b]
        power=max(0.0,-e.emf*i)
        c=%{c | voltage_v: v,current_a: abs(i),power_w: power,fault: if(MapSet.member?(result.faults,index),do: 2,else: 0)}
        sources=if power>0,do: Map.put(sources,e.device,power),else: sources
        {Map.put(out,e.device,c),heat,sources,light,electric}
      else
        {out,heat,sources,light,electric}
      end
    end)
    done=Enum.reduce(source_w,duration,fn {id,power},dt->min(dt,outputs[id].remaining_j/power) end)
    outputs=Enum.reduce(source_w,outputs,fn {id,power},all->update_in(all[id].remaining_j,fn energy->
      if done==energy/power,do: 0.0,else: max(0.0,energy-power*done)
    end) end)
    electric=for {key,{w,a}}<-electric,w>0.0,into: %{},do: {key,{Map.fetch!(luminous,key),w,a/2}}
    %{duration: done,outputs: outputs,powers: Map.reject(powers,fn {_,w}->w==0.0 end),
      supplied_j: Enum.sum(Map.values(source_w))*done,light_j: light_w*done,electric: electric,
      nodes: map_size(result.volts),edges: length(edges),elapsed_us: System.monotonic_time(:microsecond)-started}
  end

  @doc """
  体积导体六个面的微格采样，每面一组（宏格每面 8×8 点，都落在同一个相邻宏格里；微格每面 1 点）；
  不依赖热接触缓存或区域划分。
  """
  def solid_faces(target) do
    n=if target.granularity==0,do: @micro,else: 1
    for axis<-0..2,sign<-[-1,1] do
      [u,v]=Enum.reject(0..2,&(&1==axis))
      for a<-0..(n-1),b<-0..(n-1),
        do: target.micro |> offset(axis,if(sign<0,do: -1,else: n)) |> offset(u,a) |> offset(v,b)
    end
  end

  @doc """
  将各面实际采样按此刻导电的导体身份累计接触面积；重复微面保留实际面积贡献。
  采样以 `{目标, 点数}` 成段给出（同一相邻宏格的一整面是一段）；每点面积 1/64 m²，段面积 = 点数 × 1/64，
  与逐点累加的二进制值相同（全是 1/64 的整数倍）。
  """
  def solid_contacts(runs,catalog,damage) do
    Enum.reduce(runs,%{},fn {target,count},contacts ->
      target=target && thermal_target(target)
      if target && sigma(catalog,damage,target)>0 do
        key=ThermalGeometry.key(target)
        Map.update(contacts,key,{target,count*@length*@length},fn {other,area}->{other,area+count*@length*@length} end)
      else
        contacts
      end
    end)
  end

  defp node(p,nil,_),do: {:point,p}
  defp node(p,_domain,holder),do: {:point,p,holder}
  # 足迹跨持有者的设备自成一域，不与任何一侧相连。
  defp owner(domain,slots) do
    case slots |> Enum.map(domain) |> Enum.uniq() do
      [holder] -> holder
      _ -> {:mixed,slots}
    end
  end
  defp edge(a,b,r,heat),do: %{a: a,b: b,r: r,emf: 0.0,device: nil,heat: heat}
  defp luminous_fraction(catalog,material),do: Map.get(catalog.materials[material],"luminous_fraction",0.0)
  defp glowing(luminous,key,target,lum),do: if(lum>0,do: Map.put(luminous,key,target),else: luminous)
  defp thermal_target(%{granularity: 2}=t),do: %{t | granularity: 1}
  defp thermal_target(t),do: t
  defp size(%{granularity: 0}),do: 1.0
  defp size(_),do: @length
  defp offset(p,axis,n),do: put_elem(p,axis,elem(p,axis)+n)
  defp add({x,y,z},{a,b,c}),do: {x+a,y+b,z+c}
end
