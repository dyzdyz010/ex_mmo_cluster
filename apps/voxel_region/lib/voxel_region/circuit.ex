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

  @doc "仅当前已安装设备参与模拟；设备真值在整件附件属性记录中。"
  def devices(damage),do: for {_,%{granularity: 3,circuit: c}=t}<-damage,t.flags==0,into: %{},do: {t.incarnation,{t,c}}

  @doc """
  由已安装设备、目录和环境温度准备网络；不读取 canonical 占用。
  domain（可选）把附件槽映射到其受保护区域持有者：端点按持有者分开，跨持有者边界的导线/设备不在端点处相连；
  nil 时端点为 `{:point, p}`，与无此参数时逐位相同。
  """
  def prepare(slots,damage,catalog,ambient,duration,domain \\ nil) do
    started=System.monotonic_time(:microsecond)
    devices=devices(damage)
    cooling_duration=min(duration,0.05)
    grouped=Enum.group_by(slots,fn {_,{id,_}}->id end,fn {slot,_}->slot end)
    {edges,faces}=Enum.reduce(devices,{[],MapSet.new()},fn {id,{target,c}},{edges,faces}->
      footprint=Attachments.footprint(0,rem(elem(target.owner,1),3),c.anchor,c.size)
      intact=MapSet.new(Map.get(grouped,id,[]))==MapSet.new(footprint)
      u=Enum.find(0..2,&(&1 != rem(elem(target.owner,1),3)))
      tool=catalog.tools[c.tool_id]
      o=domain && owner(domain,footprint)
      edge=%{a: node(c.anchor,domain,o),b: node(offset(c.anchor,u,c.size),domain,o),r: tool["circuit_resistance_ohm"],
        emf: if(c.kind==1 and c.remaining_j>0,do: tool["circuit_voltage_v"],else: 0.0),
        device: id,heat: for(s<-footprint,do: {VoxelRegion.ThermalAttachments.key(s),1.0/length(footprint)}),
        light: tool["circuit_light_fraction"],
        cooling: if(c.kind==5,do: cooling_limits(footprint,id,target.material,tool,damage,catalog,ambient,cooling_duration),else: %{})}
      conducting=intact and c.closed and (c.kind != 1 or c.remaining_j>0) and
        (c.kind != 5 or Enum.all?(edge.cooling,fn {_,{limit,_}}->limit>0 end))
      {if(conducting,do: [edge|edges],else: edges),Enum.reduce(footprint,faces,&MapSet.put(&2,&1))}
    end)
    section=catalog.attachments["line_section_m2"]
    edges=Enum.reduce(slots,edges,fn {slot={kind,axis,p},{_id,material}},edges->
      sigma=Map.get(catalog.materials[material],"electrical_conductivity",0.0)
      if sigma>0 and not MapSet.member?(faces,slot) do
        heat=[{VoxelRegion.ThermalAttachments.key(slot),1.0}]
        o=domain && domain.(slot)
        if kind==1 do
          [edge(node(p,domain,o),node(offset(p,axis,1),domain,o),@length/(sigma*section),heat)|edges]
        else
          [u,v]=Enum.reject(0..2,&(&1==axis))
          corners=[p,offset(p,u,1),offset(p,v,1),p |> offset(u,1) |> offset(v,1)]
          r=2.0/(sigma*catalog.attachments["face_thickness_m"])
          for {a,b}<-[{0,1},{0,2},{1,3},{2,3}],reduce: edges do
            acc->[edge(node(Enum.at(corners,a),domain,o),node(Enum.at(corners,b),domain,o),r,Enum.map(heat,fn {k,w}->{k,w} end))|acc]
          end
        end
      else
        edges
      end
    end)
    %{devices: devices, grouped: grouped, catalog: catalog, edges: edges,
      duration: duration, cooling_duration: cooling_duration, started: started}
  end

  @doc "需要接入实体导体的端点节点（`{:point, p}` 或带持有者的 `{:point, p, holder}`）；保持原边顺序。"
  def points(input), do: input.edges |> Enum.flat_map(&[&1.a,&1.b]) |> Enum.uniq()

  @doc "端点节点周围的八个 canonical 微格采样点。"
  def near_points(point), do: for(x<-[-1,0],y<-[-1,0],z<-[-1,0],do: add(elem(point,1),{x,y,z}))

  @doc "按首次命中身份保留当前目录中的真实导体，微格使用独立热身份。"
  def conductors(targets,catalog) do
    targets |> Enum.reject(&is_nil/1) |> Enum.map(&thermal_target/1)
      |> Enum.uniq_by(&ThermalGeometry.key/1)
      |> Enum.filter(&(Map.get(catalog.materials[&1.material],"electrical_conductivity",0.0)>0))
  end

  @doc "求解冻结的端点宿主与实占用接触摘要，输出功率和设备状态，不返回世界。"
  def plan(input,hosts,contacts) do
    %{devices: devices,grouped: grouped,catalog: catalog,edges: edges,
      duration: duration,cooling_duration: cooling_duration,started: started}=input
    section=catalog.attachments["line_section_m2"]
    edges=Enum.reduce(points(input),edges,fn p,edges ->
      Enum.reduce(Map.fetch!(hosts,p),edges,fn target,edges ->
        key=ThermalGeometry.key(target)
        sigma=catalog.materials[target.material]["electrical_conductivity"]
        [edge(p,{:solid,key},size(target)/2/(sigma*section),[{key,1.0}])|edges]
      end)
    end)
    # owner 保留原遍历和前插次序；纯计算按同一边顺序求解，避免浮点累加漂移。
    edges=Enum.map(contacts,fn {target,other,area} ->
      a=ThermalGeometry.key(target); b=ThermalGeometry.key(other)
      r=(size(target)/catalog.materials[target.material]["electrical_conductivity"]+
         size(other)/catalog.materials[other.material]["electrical_conductivity"])/2/area
      edge({:solid,a},{:solid,b},r,[{a,0.5},{b,0.5}])
    end)++edges
    result=DCNetwork.solve(edges)
    reset=Map.new(devices,fn {id,{t,c}} ->
      intact=MapSet.new(Map.get(grouped,id,[]))==MapSet.new(Attachments.footprint(0,rem(elem(t.owner,1),3),c.anchor,c.size))
      {id,%{c | voltage_v: 0.0,current_a: 0.0,power_w: 0.0,fault: if(intact,do: 0,else: 1)}}
    end)
    {outputs,powers,source_w,light_w,cooling_w,rejected_w}=Enum.zip(edges,result.currents) |> Enum.with_index() |> Enum.reduce({reset,%{},%{},0.0,0.0,0.0},fn {{e,i},index},{out,heat,sources,light,cooling,rejected}->
      # 实跑开路残差约 8e-11 A；低于 1e-10 A 的消元舍入不作为供能。
      i=if abs(i)<1.0e-10,do: 0.0,else: i
      watts=i*i*e.r
      light_power=watts*e.light
      {heat,extracted}=Enum.reduce(e.heat,{heat,0.0},fn {key,weight},{h,extracted}->
        q=case Map.get(e.cooling,key) do
          nil -> (watts-light_power)*weight
          {limit,cop} -> -min(limit,watts*weight*cop)
        end
        {Map.update(h,key,q,&(&1+q)),extracted+if(map_size(e.cooling)>0,do: -q,else: 0.0)}
      end)
      rejected=rejected+if(map_size(e.cooling)>0,do: watts+extracted,else: 0.0)
      cooling=cooling+extracted
      if e.device do
        c=Map.fetch!(out,e.device)
        v=result.volts[e.a]-result.volts[e.b]
        power=if c.kind==1,do: max(0.0,-e.emf*i),else: watts
        c=%{c | voltage_v: v,current_a: abs(i),power_w: power,fault: if(MapSet.member?(result.faults,index),do: 2,else: 0)}
        sources=if c.kind==1 and power>0,do: Map.put(sources,e.device,power),else: sources
        {Map.put(out,e.device,c),heat,sources,light+light_power,cooling,rejected}
      else
        {out,heat,sources,light+light_power,cooling,rejected}
      end
    end)
    # 仅实际移热需要冷板控制段；停止移热时仍由真实源余量决定截断。
    duration=if cooling_w>0.0,do: cooling_duration,else: duration
    done=Enum.reduce(source_w,duration,fn {id,power},dt->min(dt,outputs[id].remaining_j/power) end)
    outputs=Enum.reduce(source_w,outputs,fn {id,power},all->update_in(all[id].remaining_j,fn energy->
      if done==energy/power,do: 0.0,else: max(0.0,energy-power*done)
    end) end)
    %{duration: done,outputs: outputs,powers: Map.reject(powers,fn {_,w}->w==0.0 end),
      supplied_j: Enum.sum(Map.values(source_w))*done,light_j: light_w*done,
      cooling_j: cooling_w*done,rejected_j: rejected_w*done,
      nodes: map_size(result.volts),edges: length(edges),elapsed_us: System.monotonic_time(:microsecond)-started}
  end

  # 冷板从自身槽吸热，目标通过既有接触冷却；下限来自同一目录。
  defp cooling_limits(slots,id,material,tool,damage,catalog,ambient,duration) do
    Map.new(slots,fn slot->
      target=Attachments.identity(slot,{id,material}) |> Map.put(:granularity,4)
      row=Map.get(damage,Damage.key(target),%{})
      temperature=Map.get(row,:temperature_kelvin,ambient)
      capacity=catalog.materials[material]["heat_capacity_per_macro"]*VoxelRegion.ThermalAttachments.volume(slot,catalog)
      {VoxelRegion.ThermalAttachments.key(slot),
        {capacity*max(0.0,temperature-tool["circuit_min_kelvin"])/duration,tool["circuit_cooling_cop"]}}
    end)
  end

  @doc "体积导体各面微格采样；不依赖热接触缓存或区域划分。"
  def solid_points(target) do
    n=if target.granularity==0,do: @micro,else: 1
    for axis<-0..2,sign<-[-1,1],a<-0..(n-1),b<-0..(n-1) do
      [u,v]=Enum.reject(0..2,&(&1==axis))
      target.micro |> offset(axis,if(sign<0,do: -1,else: n)) |> offset(u,a) |> offset(v,b)
    end
  end

  @doc "将各面实际采样按导体身份累计接触面积；重复微面保留实际面积贡献。"
  def solid_contacts(targets,catalog) do
    Enum.reduce(targets,%{},fn target,contacts ->
      if target && Map.get(catalog.materials[target.material],"electrical_conductivity",0)>0 do
        target=thermal_target(target)
        key=ThermalGeometry.key(target)
        Map.update(contacts,key,{target,@length*@length},fn {other,area}->{other,area+@length*@length} end)
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
  defp edge(a,b,r,heat),do: %{a: a,b: b,r: r,emf: 0.0,device: nil,heat: heat,light: 0.0,cooling: %{}}
  defp thermal_target(%{granularity: 2}=t),do: %{t | granularity: 1}
  defp thermal_target(t),do: t
  defp size(%{granularity: 0}),do: 1.0
  defp size(_),do: @length
  defp offset(p,axis,n),do: put_elem(p,axis,elem(p,axis)+n)
  defp add({x,y,z},{a,b,c}),do: {x+a,y+b,z+c}
end
