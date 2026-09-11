defmodule VoxelRegion.Structure do
  @moduledoc "结构派生 V1 的纯采样算法；World 提供唯一真值，不持有实例或可变缓存。"
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

  @doc "八个子格（uniform terrain 材质或完整派生格）规约；结构存在即保留，否则 terrain V1。"
  def reduce(children) do
    children = List.to_tuple(children)
    for z <- 0..(@n-1), y <- 0..(@n-1), x <- 0..(@n-1), into: <<>> do
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
  end
end
