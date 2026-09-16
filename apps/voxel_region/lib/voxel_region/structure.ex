defmodule VoxelRegion.Structure do
  @moduledoc "全局系统：结构占用与方向性外表面的纯派生算法；World 提供唯一真值。"
  import Bitwise
  alias MmoContracts.Voxel.Structure, as: Wire
  alias VoxelRegion.Reducer
  @n Wire.resolution()
  @micro div(@n,2)

  @doc "L1 的八个 canonical macro（uniform 材质或实际 slot map）精确拼为完整格。"
  def from_canonical(children) do
    children = List.to_tuple(children)
    for z <- 0..(@n-1), y <- 0..(@n-1), x <- 0..(@n-1), into: <<>> do
      child = elem(children,div(x,@micro)+2*div(y,@micro)+4*div(z,@micro))
      value = case child do
        material when is_integer(material) -> material
        slots -> case Map.get(slots,rem(x,@micro)+@micro*(rem(y,@micro)+@micro*rem(z,@micro))) do
          nil -> 0
          {material,_owner} -> material ||| Wire.flag()
        end
      end
      <<value::16-little>>
    end
  end

  @doc "L1 从实际规范槽投影六个方向的外露覆盖；不展开 Prefab 模板，不投影线元。"
  def project_attachments(grid,parent,attachments,sample,state) do
    origin = map(parent,&(&1*@n))
    inside = fn p -> Enum.all?(0..2,fn a -> elem(p,a)>=elem(origin,a) and elem(p,a)<elem(origin,a)+@n end) end
    {faces,state} = Enum.reduce(attachments,{%{},state},fn
      {{0,axis,p},{_,material}},{faces,s} ->
        Enum.reduce([-1,1],{faces,s},fn sign,{faces,s} ->
          host = if sign>0,do: offset(p,axis,-1),else: p
          if inside.(host) do
            {m,s} = sample.(host,s)
            {neighbor,s} = sample.(offset(host,axis,sign),s)
            if m != 0 and neighbor == 0 do
              local = for a<-0..2,do: elem(host,a)-elem(origin,a)
              [x,y,z] = local
              face = axis*2+if(sign>0,do: 1,else: 0)
              {Map.put(faces,{face,x+@n*(y+@n*z)},material),s}
            else
              {faces,s}
            end
          else
            {faces,s}
          end
        end)
      _,acc -> acc
    end)
    {append_faces(grid,faces),state}
  end

  @doc "八个子格（uniform terrain 材质或完整派生格）规约；结构存在即保留，否则 terrain V1。"
  def reduce(children) do
    children = List.to_tuple(children)
    grid = for z <- 0..(@n-1), y <- 0..(@n-1), x <- 0..(@n-1), into: <<>> do
      child = elem(children,div(x,@micro)+2*div(y,@micro)+4*div(z,@micro))
      value = case child do
        material when is_integer(material) -> material
        grid ->
          values = for dz <- 0..1,dy <- 0..1,dx <- 0..1 do
            index = 2*rem(x,@micro)+dx+@n*(2*rem(y,@micro)+dy+@n*(2*rem(z,@micro)+dz))
            <<v::16-little>> = binary_part(grid,index*2,2)
            v
          end
          structure = Enum.filter(values,&((&1 &&& Wire.flag()) != 0))
          if structure == [], do: Reducer.reduce_material(values), else: Reducer.mode(Enum.map(structure,&(&1 &&& 255))) ||| Wire.flag()
      end
      <<value::16-little>>
    end
    if Enum.any?(Tuple.to_list(children),&(is_binary(&1) and byte_size(&1)>@n*@n*@n*2)) do
      # 每方向四条射线取首先遇到的实体表面；空洞和另一面的涂层不能串色。
      faces = for z<-0..(@n-1),y<-0..(@n-1),x<-0..(@n-1),face<-0..5,reduce: %{} do
        acc ->
          child=elem(children,div(x,@micro)+2*div(y,@micro)+4*div(z,@micro))
          if is_integer(child) do
            acc
          else
            axis=div(face,2);u=rem(axis+1,3);v=rem(axis+2,3)
            base={2*rem(x,@micro),2*rem(y,@micro),2*rem(z,@micro)}
            order=if rem(face,2)==1,do: [1,0],else: [0,1]
            materials=for a<-0..1,b<-0..1 do
              Enum.find_value(order,0,fn d ->
                p=base |> offset(axis,d) |> offset(u,a) |> offset(v,b)
                i=elem(p,0)+@n*(elem(p,1)+@n*elem(p,2))
                m=value(child,i) &&& 255
                if m != 0,do: surface(child,i,face,m),else: nil
              end)
            end |> Enum.reject(&(&1==0))
            i=x+@n*(y+@n*z)
            material=if materials==[],do: 0,else: Reducer.mode(materials)
            if material==0 or material==(value(grid,i) &&& 255),do: acc,else: Map.put(acc,{face,i},material)
          end
      end
      append_faces(grid,faces)
    else
      grid
    end
  end

  defp value(grid,index) do
    <<v::16-little>> = binary_part(grid,index*2,2)
    v
  end
  defp surface(grid,index,face,material) do
    if byte_size(grid)==@n*@n*@n*2 do
      material
    else
      case value(grid,(face+1)*@n*@n*@n+index) do
        0 -> material
        m -> m
      end
    end
  end
  defp append_faces(grid,faces) when map_size(faces)==0,do: grid
  defp append_faces(grid,faces),do: grid <> (for face<-0..5,i<-0..(@n*@n*@n-1),into: <<>>,do: <<Map.get(faces,{face,i},0)::16-little>>)
  defp offset(p,axis,n),do: put_elem(p,axis,elem(p,axis)+n)
  defp map(p,f),do: p |> Tuple.to_list() |> Enum.map(f) |> List.to_tuple()
end
