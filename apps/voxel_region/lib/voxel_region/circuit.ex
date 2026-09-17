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

  @doc "求解一次当前网络；输出本段有效时长、各热节点瓦数及更新后的设备状态。"
  def plan(slots,damage,catalog,state,at,duration) do
    started=System.monotonic_time(:microsecond)
    devices=devices(damage)
    cooling_duration=min(duration,0.05)
    grouped=Enum.group_by(slots,fn {_,{id,_}}->id end,fn {slot,_}->slot end)
    {edges,faces}=Enum.reduce(devices,{[],MapSet.new()},fn {id,{target,c}},{edges,faces}->
      footprint=Attachments.footprint(0,rem(elem(target.owner,1),3),c.anchor,c.size)
      intact=MapSet.new(Map.get(grouped,id,[]))==MapSet.new(footprint)
      u=Enum.find(0..2,&(&1 != rem(elem(target.owner,1),3)))
      tool=catalog.tools[c.tool_id]
      edge=%{a: {:point,c.anchor},b: {:point,offset(c.anchor,u,c.size)},r: tool["circuit_resistance_ohm"],
        emf: if(c.kind==1 and c.remaining_j>0,do: tool["circuit_voltage_v"],else: 0.0),
        device: id,heat: for(s<-footprint,do: {VoxelRegion.ThermalAttachments.key(s),1.0/length(footprint)}),
        light: tool["circuit_light_fraction"],
        cooling: if(c.kind==5,do: cooling_limits(footprint,id,target.material,tool,damage,catalog,state,cooling_duration),else: %{})}
      conducting=intact and c.closed and (c.kind != 1 or c.remaining_j>0) and
        (c.kind != 5 or Enum.all?(edge.cooling,fn {_,{limit,_}}->limit>0 end))
      {if(conducting,do: [edge|edges],else: edges),Enum.reduce(footprint,faces,&MapSet.put(&2,&1))}
    end)
    section=catalog.attachments["line_section_m2"]
    edges=Enum.reduce(slots,edges,fn {slot={kind,axis,p},{_id,material}},edges->
      sigma=Map.get(catalog.materials[material],"electrical_conductivity",0.0)
      if sigma>0 and not MapSet.member?(faces,slot) do
        heat=[{VoxelRegion.ThermalAttachments.key(slot),1.0}]
        if kind==1 do
          [edge({:point,p},{:point,offset(p,axis,1)},@length/(sigma*section),heat)|edges]
        else
          [u,v]=Enum.reject(0..2,&(&1==axis))
          corners=[p,offset(p,u,1),offset(p,v,1),p |> offset(u,1) |> offset(v,1)]
          r=2.0/(sigma*catalog.attachments["face_thickness_m"])
          for {a,b}<-[{0,1},{0,2},{1,3},{2,3}],reduce: edges do
            acc->[edge({:point,Enum.at(corners,a)},{:point,Enum.at(corners,b)},r,Enum.map(heat,fn {k,w}->{k,w} end))|acc]
          end
        end
      else
        edges
      end
    end)
    # 端点触及实体导体时接入体积节点；实体再按共享面遍历，完全不复用热接触图。
    points=edges |> Enum.flat_map(&[&1.a,&1.b]) |> Enum.uniq()
    {edges,solids,state}=Enum.reduce(points,{edges,%{},state},fn {:point,p},{edges,solids,s}->
      {near,s}=Enum.map_reduce(for(x<-[-1,0],y<-[-1,0],z<-[-1,0],do: add(p,{x,y,z})),s,fn p,s->at.(p,s) end)
      near=near |> Enum.reject(&is_nil/1) |> Enum.map(&thermal_target/1) |> Enum.uniq_by(&ThermalGeometry.key/1)
      Enum.reduce(near,{edges,solids,s},fn t,{edges,solids,s}->
        sigma=Map.get(catalog.materials[t.material],"electrical_conductivity",0.0)
        if sigma>0 do
          key=ThermalGeometry.key(t)
          e=edge({:point,p},{:solid,key},size(t)/2/(sigma*section),[{key,1.0}])
          {[e|edges],Map.put(solids,key,t),s}
        else
          {edges,solids,s}
        end
      end)
    end)
    {edges,_solids,state}=solid_edges(Map.values(solids),MapSet.new(),edges,solids,catalog,state,at)
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
      cooling_j: cooling_w*done,rejected_j: rejected_w*done,state: state,
      nodes: map_size(result.volts),edges: length(edges),elapsed_us: System.monotonic_time(:microsecond)-started}
  end

  # 冷板从自身槽吸热，目标通过既有接触冷却；下限来自同一目录。
  defp cooling_limits(slots,id,material,tool,damage,catalog,state,duration) do
    Map.new(slots,fn slot->
      target=Attachments.identity(slot,{id,material}) |> Map.put(:granularity,4)
      row=Map.get(damage,Damage.key(target),%{})
      temperature=Map.get(row,:temperature_kelvin,state.thermal.config["ambient_kelvin"])
      capacity=catalog.materials[material]["heat_capacity_per_macro"]*VoxelRegion.ThermalAttachments.volume(slot,catalog)
      {VoxelRegion.ThermalAttachments.key(slot),
        {capacity*max(0.0,temperature-tool["circuit_min_kelvin"])/duration,tool["circuit_cooling_cop"]}}
    end)
  end

  defp solid_edges([],_,edges,solids,_catalog,state,_at),do: {edges,solids,state}
  defp solid_edges([t|queue],seen,edges,solids,catalog,state,at) do
    key=ThermalGeometry.key(t)
    if MapSet.member?(seen,key),do: solid_edges(queue,seen,edges,solids,catalog,state,at),else:
      expand_solid(t,queue,MapSet.put(seen,key),edges,solids,catalog,state,at)
  end
  defp expand_solid(t,queue,seen,edges,solids,catalog,state,at) do
    n=if t.granularity==0,do: @micro,else: 1
    {contacts,state}=Enum.reduce(for(axis<-0..2,sign<-[-1,1],do: {axis,sign}),{%{},state},fn {axis,sign},{contacts,s}->
      [u,v]=Enum.reject(0..2,&(&1==axis))
      Enum.reduce(for(a<-0..(n-1),b<-0..(n-1),do: {a,b}),{contacts,s},fn {a,b},{contacts,s}->
        p=t.micro |> offset(axis,if(sign<0,do: -1,else: n)) |> offset(u,a) |> offset(v,b)
        {other,s}=at.(p,s)
        if other && Map.get(catalog.materials[other.material],"electrical_conductivity",0)>0 do
          other=thermal_target(other); k=ThermalGeometry.key(other)
          {Map.update(contacts,k,{other,@length*@length},fn {o,area}->{o,area+@length*@length} end),s}
        else
          {contacts,s}
        end
      end)
    end)
    {queue,edges,solids}=Enum.reduce(contacts,{queue,edges,solids},fn {k,{o,area}},{q,edges,solids}->
      if MapSet.member?(seen,k) do
        {q,edges,solids}
      else
        key=ThermalGeometry.key(t)
        r=(size(t)/catalog.materials[t.material]["electrical_conductivity"]+size(o)/catalog.materials[o.material]["electrical_conductivity"])/2/area
        e=edge({:solid,key},{:solid,k},r,[{key,0.5},{k,0.5}])
        {[o|q],[e|edges],Map.put(solids,k,o)}
      end
    end)
    solid_edges(queue,seen,edges,solids,catalog,state,at)
  end
  defp edge(a,b,r,heat),do: %{a: a,b: b,r: r,emf: 0.0,device: nil,heat: heat,light: 0.0,cooling: %{}}
  defp thermal_target(%{granularity: 2}=t),do: %{t | granularity: 1}
  defp thermal_target(t),do: t
  defp size(%{granularity: 0}),do: 1.0
  defp size(_),do: @length
  defp offset(p,axis,n),do: put_elem(p,axis,elem(p,axis)+n)
  defp add({x,y,z},{a,b,c}),do: {x+a,y+b,z+c}
end
