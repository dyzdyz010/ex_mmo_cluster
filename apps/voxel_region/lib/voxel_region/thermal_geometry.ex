defmodule VoxelRegion.ThermalGeometry do
  @moduledoc "全局系统功能：从 canonical 实占用生成可丢弃的热容量、接触面积和导热摘要。"
  alias VoxelRegion.{Prefab, Thermal}
  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "温度节点身份：宏格或精确微格；生命期身份保留在 target 中。"
  def key(t), do: {t.granularity,t.micro}

  @doc "构造一个宏格内的热节点；at 只读取权威占用，返回目标及读取后的世界。"
  def cell(cell,refined,materials,state,at) do
    {targets,state}=case Map.fetch(refined,cell) do
      {:ok,slots} ->
        {for({slot,{material,{birth,_}=owner}}<-slots,do:
          %{micro: Prefab.micro_coord(cell,slot),granularity: 1,incarnation: birth,owner: owner,material: material}),state}
      :error ->
        {target,s}=at.(scale(cell,@micro),state)
        {if(target,do: [target],else: []),s}
    end
    Enum.map_reduce(Enum.filter(targets,&Map.has_key?(materials[&1.material],"heat_capacity_per_macro")),state,fn target,s ->
      material=Map.fetch!(materials,target.material)
      size=if target.granularity==0,do: 1.0,else: 1.0/@micro
      faces=if target.granularity==1 do
        for micro<-Thermal.neighbors(target.micro),do: {micro,size*size}
      else
        for axis<-0..2,sign<-[-1,1],reduce: [] do
          acc ->
            neighbor=put_elem(cell,axis,elem(cell,axis)+sign)
            if Map.has_key?(refined,neighbor) do
              axes=Enum.reject(0..2,&(&1==axis))
              samples=for a<-0..(@micro-1),b<-0..(@micro-1) do
                micro=target.micro |> put_elem(axis,elem(target.micro,axis)+if(sign==1,do: @micro,else: -1))
                  |> put_elem(Enum.at(axes,0),elem(target.micro,Enum.at(axes,0))+a)
                  |> put_elem(Enum.at(axes,1),elem(target.micro,Enum.at(axes,1))+b)
                {micro,1.0/(@micro*@micro)}
              end
              samples++acc
            else
              [{scale(neighbor,@micro),1.0}|acc]
            end
        end
      end
      {{exposed,contacts},s}=Enum.map_reduce(faces,s,fn {micro,area},s ->
        {other,s}=at.(micro,s)
        other=if other && other.granularity==2,do: %{other | granularity: 1},else: other
        {{other,area},s}
      end) |> then(fn {faces,s}->
        exposed=Enum.reduce(faces,0.0,fn {other,a},sum->sum+if(other==nil,do: a,else: 0.0) end)
        contacts=for {other,area}<-faces,other != nil,
          Map.has_key?(materials[other.material],"heat_capacity_per_macro") do
          k=material["thermal_conductivity"]; ko=materials[other.material]["thermal_conductivity"]
          other_size=if other.granularity==0,do: 1.0,else: 1.0/@micro
          g=if k==0 or ko==0,do: 0.0,else: area/(size/(2*k)+other_size/(2*ko))
          {key(other),g}
        end
        {{exposed,contacts},s}
      end)
      {{key(target),%{target: target,material: material,capacity: material["heat_capacity_per_macro"]*size*size*size,
          exposed_faces: exposed,contacts: contacts}},s}
    end)
  end

  @doc "每个真实接触只结算一次，边界不依赖 chunk 或 region。"
  def contacts(nodes) do
    for {id,n}<-nodes,{other,g}<-n.contacts,id<other,Map.has_key?(nodes,other),do: {id,other,g}
  end

  defp scale({x,y,z},n),do: {x*n,y*n,z*n}
end
