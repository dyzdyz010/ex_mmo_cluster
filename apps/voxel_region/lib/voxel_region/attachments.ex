defmodule VoxelRegion.Attachments do
  @moduledoc "全局系统功能：附件规范足迹、共享支撑与区域投影；World 唯一持有槽事实。"
  @micro VoxelRegion.Spatial.micro_resolution()
  @region VoxelRegion.Spatial.region_size()

  @doc "附件权威身份：整件 HP 与逐槽热状态共用 kind／axis 及出生 ID。"
  def identity({kind,axis,anchor},{id,material}),do:
    %{micro: anchor,granularity: 3,incarnation: id,owner: {id,kind*3+axis},material: material}

  @doc "由属性身份恢复规范槽地址。"
  def slot(%{owner: {_,type},micro: p}),do: {div(type,3),rem(type,3),p}

  @doc "宏规格与微规格展开到同一个占用索引。"
  def footprint(kind,axis,anchor,size) do
    other = Enum.reject(0..2,&(&1==axis))
    case kind do
      0 -> for u <- 0..(size-1), v <- 0..(size-1),
        do: {kind,axis,anchor |> offset(Enum.at(other,0),u) |> offset(Enum.at(other,1),v)}
      1 -> for u <- 0..(size-1), do: {kind,axis,offset(anchor,axis,u)}
    end
  end

  @doc "规范槽的顶点：线按起点、终点；面按锚点、第一切向、第二切向、对角的既有电路顺序。"
  def vertices({1, axis, point}), do: [point, offset(point, axis, 1)]
  def vertices({0, axis, point}) do
    [u, v] = Enum.reject(0..2, &(&1 == axis))
    [point, offset(point, u, 1), offset(point, v, 1), point |> offset(u, 1) |> offset(v, 1)]
  end

  @doc "一个顶点关联的全部规范槽：各轴两条线、各法向四个面；只给地址，不判断槽是否存在或导电。"
  def incident_slots(point) do
    for {kind, axis, {xs, ys, zs}} <- incident_ranges(point, point), x <- xs, y <- ys, z <- zs,
      do: {kind, axis, {x, y, z}}
  end

  @doc """
  至少一个顶点落在完整XYZ闭盒 `[lo, hi]` 内的全部规范槽，按种类／轴给出锚点范围（各轴线、各法向面各一盒，互不重叠）：
  线锚点沿本轴向负方向多一格，面锚点沿两切向负方向多一格。单点盒逐盒展开即 `incident_slots/1` 的既有顺序。
  """
  def incident_ranges(lo, hi) do
    lines = for axis <- 0..2, do: {1, axis, anchor_ranges(lo, hi, [axis])}
    faces = for axis <- 0..2, do: {0, axis, anchor_ranges(lo, hi, Enum.reject(0..2, &(&1 == axis)))}
    lines ++ faces
  end

  defp anchor_ranges(lo, hi, widened),
    do: List.to_tuple(for(i <- 0..2, do: (elem(lo, i) - if(i in widened, do: 1, else: 0))..elem(hi, i)//1))

  @doc "面两侧／棱四周候选支撑。"
  def neighbors({0,axis,p}), do: [p,offset(p,axis,-1)]
  def neighbors({1,axis,p}) do
    [u,v]=Enum.reject(0..2,&(&1==axis))
    for a <- [-1,0],b <- [-1,0],do: p |> offset(u,a) |> offset(v,b)
  end

  @doc "支撑按独立附件资格目录判断，完整采样由 World 提供。"
  def supported?(slot,samples), do: Enum.any?(neighbors(slot),fn p ->
    MmoContracts.VoxelMaterialCatalog.supports_attachments?(Map.fetch!(samples,p))
  end)

  @doc "规范槽归属区域，仅 anchor 所在 core 拥有事实。"
  def region({_,_,p}), do: map(p,&Integer.floor_div(&1,@region*@micro))
  @doc "载荷包含 core 及既有一宏格 ring。"
  def extract(slots,{rx,ry,rz}) do
    {ox,oy,oz}={rx*@region*@micro,ry*@region*@micro,rz*@region*@micro}
    for {{_,_,{x,y,z}},_}=entry <- slots,
      x>=ox-@micro and x<ox+65*@micro and
      y>=oy-@micro and y<oy+65*@micro and
      z>=oz-@micro and z<oz+65*@micro,into: %{},do: entry
  end

  @doc "一次扫描为本次变更的 L1 支撑格分组；仅作投影输入，不保存第二份真值。"
  def l1_faces(slots,parents) do
    wanted=MapSet.new(parents)
    Enum.reduce(slots,%{},fn
      {{0,axis,{x,y,z}=p},_}=entry,groups ->
        parent={Integer.floor_div(x,2*@micro),Integer.floor_div(y,2*@micro),Integer.floor_div(z,2*@micro)}
        other=put_elem(parent,axis,Integer.floor_div(elem(p,axis)-1,2*@micro))
        groups=put_face(groups,wanted,parent,entry)
        if other==parent,do: groups,else: put_face(groups,wanted,other,entry)
      _,groups -> groups
    end)
  end
  defp put_face(groups,wanted,parent,entry) do
    if MapSet.member?(wanted,parent),do: Map.update(groups,parent,[entry],&[entry|&1]),else: groups
  end
  @doc "足迹实际涉及的宏格，包括支撑侧。"
  def macros(slots), do: slots |> Enum.flat_map(fn slot -> [elem(slot,2)|neighbors(slot)] end)
    |> Enum.map(&macro_coord/1) |> Enum.uniq()

  @doc "附件足迹是否与给定完整XYZ宏格集合相交；只求存在性，不构造去重足迹表。"
  def touches_macros?(slot, cells) do
    Enum.any?([elem(slot, 2) | neighbors(slot)], &MapSet.member?(cells, macro_coord(&1)))
  end

  defp macro_coord(point), do: map(point, &Integer.floor_div(&1, @micro))
  @doc "实际规范槽按发布厚度/截面结算整数材料量，显示宽度不参与。旧目录仅用于历史测试。"
  def units(slots,properties) do
    Enum.reduce(slots,0,fn {kind,_,_},sum ->
      sum+unit(kind,properties)
    end)
  end

  @doc "按种类聚合的规范槽数复用实际槽的同一材料量，不展开几何或复制厚度规则。"
  def units_for_counts(counts,properties),do:
    Enum.reduce(counts,0,fn {kind,count},sum -> sum+count*unit(kind,properties) end)

  defp unit(kind,%{attachments: %{}=specification}),do:
    Map.fetch!(specification,if(kind==0,do: "face_units",else: "edge_units"))
  defp unit(_,_),do: 1

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
            if MmoContracts.VoxelMaterialCatalog.supports_attachments?(m) and visible do
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
