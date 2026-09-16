defmodule VoxelRegion.Attachments do
  @moduledoc "全局系统功能：附件规范足迹、共享支撑与区域投影；World 唯一持有槽事实。"
  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "宏规格与微规格展开到同一个占用索引。"
  def footprint(kind,axis,anchor,size) do
    other = Enum.reject(0..2,&(&1==axis))
    case kind do
      0 -> for u <- 0..(size-1), v <- 0..(size-1),
        do: {kind,axis,anchor |> offset(Enum.at(other,0),u) |> offset(Enum.at(other,1),v)}
      1 -> for u <- 0..(size-1), do: {kind,axis,offset(anchor,axis,u)}
    end
  end

  @doc "面两侧／棱四周候选支撑。"
  def neighbors({0,axis,p}), do: [p,offset(p,axis,-1)]
  def neighbors({1,axis,p}) do
    [u,v]=Enum.reject(0..2,&(&1==axis))
    for a <- [-1,0],b <- [-1,0],do: p |> offset(u,a) |> offset(v,b)
  end

  @doc "支撑按已有阻挡目录判断，完整采样由 World 提供。"
  def supported?(slot,samples), do: Enum.any?(neighbors(slot),fn p ->
    MmoContracts.VoxelMaterialCatalog.blocks_movement?(Map.fetch!(samples,p))
  end)

  @doc "规范槽归属区域，仅 anchor 所在 core 拥有事实。"
  def region({_,_,p}), do: map(p,&Integer.floor_div(&1,64*@micro))
  @doc "载荷包含 core 及既有一宏格 ring。"
  def extract(slots,{rx,ry,rz}) do
    {ox,oy,oz}={rx*64*@micro,ry*64*@micro,rz*64*@micro}
    for {{_,_,{x,y,z}},_}=entry <- slots,
      x>=ox-@micro and x<ox+65*@micro and
      y>=oy-@micro and y<oy+65*@micro and
      z>=oz-@micro and z<oz+65*@micro,into: %{},do: entry
  end

  @doc "一次扫描为本次变更的 L1 支撑格分组；仅作投影输入，不保存第二份真值。"
  def l1_faces(slots,parents) do
    wanted=MapSet.new(parents)
    Enum.reduce(slots,%{},fn
      {{0,_,_}=slot,_}=entry,groups ->
        slot |> neighbors() |> Enum.map(&map(&1,fn x -> Integer.floor_div(x,2*@micro) end))
        |> Enum.uniq() |> Enum.reduce(groups,fn parent,acc ->
          if MapSet.member?(wanted,parent),do: Map.update(acc,parent,[entry],&[entry|&1]),else: acc
        end)
      _,groups -> groups
    end)
  end
  @doc "足迹实际涉及的宏格，包括支撑侧。"
  def macros(slots), do: slots |> Enum.flat_map(fn slot -> [elem(slot,2)|neighbors(slot)] end)
    |> Enum.map(&map(&1,fn x -> Integer.floor_div(x,@micro) end)) |> Enum.uniq()
  @doc "实际规范槽按发布厚度/截面结算整数材料量，显示宽度不参与。旧目录仅用于历史测试。"
  def units(slots,%{attachments: %{}=specification}) do
    Enum.reduce(slots,0,fn {kind,_,_},sum ->
      sum+Map.fetch!(specification,if(kind==0,do: "face_units",else: "edge_units"))
    end)
  end
  def units(slots,_),do: length(slots)

  @doc "L1 外露面按微面积投票到既有表皮；更粗层继续使用同一个 Reducer。不改变占用。"
  def project_l1(cell,base,slots,sample,state) do
    min=map(cell,&(&1*2*@micro))
    inside=fn p -> Enum.all?(0..2,fn a -> elem(p,a)>=elem(min,a) and elem(p,a)<elem(min,a)+2*@micro end) end
    {columns,state}=Enum.reduce(slots,{%{},state},fn
      {{0,axis,p},{_,material}},{columns,s} ->
        Enum.reduce([-1,1],{columns,s},fn sign,{cols,s} ->
          host=if sign>0,do: offset(p,axis,-1),else: p
          if inside.(host) do
            {m,s}=sample.(host,s)
            outside=offset(host,axis,sign)
            {visible,s}=exposed(outside,axis,sign,inside,sample,s)
            if MmoContracts.VoxelMaterialCatalog.blocks_movement?(m) and visible do
              u=rem(axis+1,3);v=rem(axis+2,3);face=axis*2+if(sign>0,do: 1,else: 0)
              key={face,elem(host,u)-elem(min,u),elem(host,v)-elem(min,v)}
              old=Map.get(cols,key)
              if old==nil or sign*(elem(p,axis)-elem(old,0))>0,
                do: {Map.put(cols,key,{elem(p,axis),material}),s},else: {cols,s}
            else
              {cols,s}
            end
          else
            {cols,s}
          end
        end)
      _,acc -> acc
    end)
    votes=Enum.reduce(columns,%{},fn {{face,u,v},{_,m}},acc ->
      Map.update(acc,{face,div(u,@micro),div(v,@micro)},%{m=>1},&Map.update(&1,m,1,fn n->n+1 end))
    end)
    if map_size(votes)==0 do
      {base,state}
    else
      {base_ext,_}=base
      faces=for f<-0..5 do
        texels=for y<-0..1,x<-0..1,into: <<>> do
          host=VoxelRegion.Reducer.texel(base,f,div(x*base_ext,2),div(y*base_ext,2))
          counts=Map.get(votes,{f,x,y},%{})
          covered=Enum.sum(Map.values(counts))
          counts=Map.update(counts,host,@micro*@micro-covered,&(&1+@micro*@micro-covered))
          {m,_}=Enum.min_by(counts,fn {id,n}->{-n,id} end)
          <<m>>
        end
        {VoxelRegion.Reducer.mode(texels),texels}
      end
      {MmoContracts.Voxel.Skins.canonical({2,List.to_tuple(faces)}),state}
    end
  end

  defp exposed(p,axis,sign,inside,sample,state) do
    # 紧邻格即使在父格外仍会遮挡；后续只扫描同一父格内的列。
    {m,state}=sample.(p,state)
    if MmoContracts.Voxel.Attachments.material?(m) do
      {false,state}
    else
      next=offset(p,axis,sign)
      if inside.(next),do: exposed(next,axis,sign,inside,sample,state),else: {true,state}
    end
  end
  defp offset(p,axis,n), do: put_elem(p,axis,elem(p,axis)+n)
  defp map(p,f), do: p |> Tuple.to_list() |> Enum.map(f) |> List.to_tuple()
end
