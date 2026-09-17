defmodule VoxelRegion.ThermalAttachments do
  @moduledoc "全局系统功能：规范附件槽的独立热容量及接触摘要；不持有温度或世界真值。"
  alias VoxelRegion.{Attachments, ThermalGeometry}
  @micro VoxelRegion.Spatial.micro_resolution()
  @length 1.0/@micro

  @doc "槽热身份不随 greedy、附件共享 HP 或区域划分合并。"
  def key({kind,axis,p}),do: {4,{kind*3+axis,p}}

  @doc "每槽实际体积，单位 m³。"
  def volume(slot,catalog),do: Attachments.units([slot],catalog)/(@micro*@micro*@micro*catalog.attachments["material_units_per_micro"])

  @doc "在当前权威固体摘要上加入面层／方截面线；at 只读取 canonical 占用。"
  def add(nodes,slots,catalog,state,at,volume \\ fn _,_ -> 1.0 end) do
    thermal=Map.filter(slots,fn {_,{_,m}}->Map.has_key?(catalog.materials[m],"heat_capacity_per_macro") end)
    thickness=if map_size(thermal)>0,do: catalog.attachments["face_thickness_m"],else: 0.0
    width=if map_size(thermal)>0,do: :math.sqrt(catalog.attachments["line_section_m2"]),else: 0.0
    nodes=Enum.reduce(thermal,nodes,fn {slot,value},all ->
      material=catalog.materials[elem(value,1)]
      target=Attachments.identity(slot,value) |> Map.put(:granularity,4)
      surface=case elem(slot,0) do
        0 -> 2*@length*@length+4*@length*thickness
        1 -> 4*@length*width+2*width*width
      end
      Map.put(all,key(slot),%{target: target,material: material,capacity: material["heat_capacity_per_macro"]*volume(slot,catalog),
        exposed_faces: surface,contacts: []})
    end)
    {nodes,state}=Enum.reduce(thermal,{nodes,state},fn {slot,_},{all,s}->
      {targets,s}=Enum.map_reduce(Attachments.neighbors(slot),s,fn p,s ->
        {t,s}=at.(p,s)
        t=if t && t.granularity==2,do: %{t | granularity: 1},else: t
        {t,s}
      end)
      bounds=Enum.map(targets,fn target->if target,do: ThermalGeometry.bounds(target,volume.(s,target)) end)
      all=host_contacts(all,slot,targets,bounds,thickness,width)
      {all,s}
    end)
    # 共边薄片／面线及共端点线段各生成一条热接触，和电连接语义无关。
    ports=Enum.reduce(thermal,%{},fn {slot,_},ports ->
      Enum.reduce(ports(slot),ports,fn p,acc->Map.update(acc,p,[slot],&[slot|&1]) end)
    end)
    nodes=Enum.reduce(ports,nodes,fn {_,members},all ->
      for a<-members,b<-members,a<b,reduce: all do
        all ->
          {area,da,db}=join_geometry(a,b,thickness,width)
          area=area/(length(members)-1)
          all |> connect(key(a),key(b),area,da,db)
            |> exposed(key(a),-area) |> exposed(key(b),-area)
      end
    end)
    {nodes,state}
  end

  defp host_contacts(nodes,slot,targets,bounds,t,w) do
    id=key(slot); kind=elem(slot,0)
    distance=if kind==0,do: t/2,else: w/2
    patches=Enum.map(bounds,fn box->if box,do: host_patches(slot,box,w),else: [] end)
    nodes=targets |> Enum.with_index() |> Enum.reduce(nodes,fn {target,index},all ->
      if target do
        other=ThermalGeometry.key(target)
        contact=Enum.at(patches,index)
        area=Enum.sum(for {a,_}<-contact,do: a)
        all=exposed(all,id,-area)
        if Map.has_key?(all,other) do
          all=Enum.reduce(contact,all,fn {a,d},all->connect(all,id,other,a,distance,d) end)
          # 一侧为空气时，薄片替代该侧宿主暴露面；棱每象限覆盖两个半边。
          uncovered=if kind==0 do
            other_area=Enum.at(patches,1-index) |> Enum.reduce(0.0,fn {a,_},sum->sum+a end)
            max(0.0,area-other_area)
          else
            # 象限沿两个横轴的另一侧为空气时，对应半边才是原本暴露的宿主面。
            for peer<-[Bitwise.bxor(index,1),Bitwise.bxor(index,2)],reduce: 0.0 do
              sum -> sum+if(Enum.at(patches,peer)==[],do: area/2,else: 0.0)
            end
          end
          exposed(all,other,-uncovered)
        else
          all
        end
      else
        all
      end
    end)
    if kind==0 and Enum.all?(targets,&(&1!=nil)) do
      [a,b]=targets; ka=ThermalGeometry.key(a); kb=ThermalGeometry.key(b)
      if ka != kb and Map.has_key?(nodes,ka) and Map.has_key?(nodes,kb) do
        {area,da,db}=ThermalGeometry.contact(Enum.at(bounds,0),Enum.at(bounds,1),elem(slot,1))
        # Only the slot-sized portion of the host/host face is replaced.
        slot_area=patches |> Enum.map(fn ps->Enum.sum(for {a,_}<-ps,do: a) end) |> Enum.min()
        g=conductance(nodes[ka],nodes[kb],min(area,slot_area),da,db)
        nodes |> subtract_contact(ka,kb,g) |> subtract_contact(kb,ka,g)
      else
        nodes
      end
    else
      nodes
    end
  end

  defp host_patches({0,axis,p},bounds,_w) do
    low=metres(p)
    high=for a<-0..2,do: elem(low,a)+if(a==axis,do: 0.0,else: @length)
    {area,d}=ThermalGeometry.surface_contact(bounds,axis,elem(low,axis),{low,List.to_tuple(high)})
    if area>0,do: [{area,d}],else: []
  end
  defp host_patches({1,axis,p},{blo,bhi}=bounds,w) do
    origin=metres(p)
    # Each neighboring quadrant touches two half-width strips. Clip each strip
    # against actual host bounds, including a finite Y-up liquid column.
    for normal<-0..2,normal != axis,reduce: [] do
      out->
        tangent=3-axis-normal
        sign=if elem(bhi,tangent)<=elem(origin,tangent),do: -1,else: 1
        edge=elem(origin,tangent)+sign*w/2
        low=origin |> put_elem(tangent,min(elem(origin,tangent),edge))
        high=origin |> put_elem(tangent,max(elem(origin,tangent),edge)) |> put_elem(axis,elem(origin,axis)+@length)
        {area,d}=ThermalGeometry.surface_contact({blo,bhi},normal,elem(origin,normal),{low,high})
        if area>0,do: [{area,d}|out],else: out
    end
  end
  defp metres(p),do: p |> Tuple.to_list() |> Enum.map(&(&1/@micro)) |> List.to_tuple()

  defp subtract_contact(nodes,a,b,g) do
    update_in(nodes[a].contacts,fn contacts ->
      {same,rest}=Enum.split_with(contacts,fn {id,_}->id==b end)
      remaining=Enum.reduce(same,0.0,fn {_,v},sum->sum+v end)-g
      if remaining>1.0e-12,do: [{b,remaining}|rest],else: rest
    end)
  end
  defp exposed(nodes,id,delta),do: update_in(nodes[id].exposed_faces,&max(0.0,&1+delta))
  defp connect(nodes,a,b,area,da,db) do
    g=conductance(nodes[a],nodes[b],area,da,db)
    nodes |> update_in([a,:contacts],&[{b,g}|&1]) |> update_in([b,:contacts],&[{a,g}|&1])
  end
  defp conductance(a,b,area,da,db) do
    ka=a.material["thermal_conductivity"]; kb=b.material["thermal_conductivity"]
    if ka==0 or kb==0,do: 0.0,else: area/(da/ka+db/kb)
  end
  defp offset(p,a,n),do: put_elem(p,a,elem(p,a)+n)
  defp ports({1,axis,p}),do: [{:edge,axis,p},{:point,p},{:point,offset(p,axis,1)}]
  defp ports({0,axis,p}) do
    [u,v]=Enum.reject(0..2,&(&1==axis))
    [{:edge,u,p},{:edge,u,offset(p,v,1)},{:edge,v,p},{:edge,v,offset(p,u,1)}]
  end
  defp join_geometry({1,_,_},{1,_,_},_t,w),do: {w*w,@length/2,@length/2}
  defp join_geometry({0,_,_},{0,_,_},t,_w),do: {t*@length,@length/2,@length/2}
  defp join_geometry({0,_,_},{1,_,_},t,w),do: {min(t,w)*@length,@length/2,w/2}
end
