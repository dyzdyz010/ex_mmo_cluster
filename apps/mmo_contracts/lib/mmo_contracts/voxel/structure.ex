defmodule MmoContracts.Voxel.Structure do
  @moduledoc "全局系统：VXR6 结构派生；占用网格及可选六方向表面材料，均不是世界真值。"
  import Bitwise
  @resolution 16
  @samples @resolution * @resolution * @resolution
  @flag 256

  @doc "派生格每轴采样数。"
  def resolution, do: @resolution
  @doc "结构实体标记。"
  def flag, do: @flag
  @doc "最大后缀容量来自 region 格数和每格完整网格。"
  def max_bytes, do: 8 + 66*66*66*(8+@samples*14)
  @doc "排序写出派生后缀；只接受已构造的合法结构网格。"
  def encode(grids), do: IO.iodata_to_binary([<<2::32-little,map_size(grids)::32-little>>,for({i,g} <- Enum.sort(grids),do: [<<i::32-little,div(byte_size(g),2)::32-little>>,g])])
  @doc "协议边界一次校验版本、排序、材质位和实际结构占用。"
  def decode(<<1::32-little,n::32-little,rest::binary>>) when n > 0, do: records(rest,n,-1,%{})
  def decode(<<2::32-little,n::32-little,rest::binary>>) when n > 0, do: records_v2(rest,n,-1,%{})
  def decode(_), do: {:error,:invalid_structure}
  defp records(<<>>,0,_,grids), do: {:ok,grids}
  defp records(<<i::32-little,g::binary-size(@samples*2),rest::binary>>,n,previous,grids) when n>0 and i>previous and i<66*66*66 do
    values = for <<v::16-little <- g>>,do: v
    if Enum.all?(values,&(&1 <= 511 and &1 != @flag)) and Enum.any?(values,&((&1 &&& @flag) != 0)),
      do: records(rest,n-1,i,Map.put(grids,i,g)),else: {:error,:invalid_structure}
  end
  defp records(_,_,_,_), do: {:error,:invalid_structure}

  @doc "占用与方向性材质的协议边界校验；旧网格可直接读取。"
  def valid?(g) when byte_size(g) in [@samples*2,@samples*14] do
    <<occupancy::binary-size(@samples*2),faces::binary>> = g
    values = for <<v::16-little <- occupancy>>, do: v
    Enum.all?(values,&(&1 <= 511 and &1 != @flag)) and
      Enum.any?(values,&((&1 &&& @flag) != 0)) and
      Enum.all?(for(<<v::16-little <- faces>>,do: v),&(&1 <= 255))
  end
  def valid?(_), do: false
  defp records_v2(<<>>,0,_,grids), do: {:ok,grids}
  defp records_v2(<<i::32-little,count::32-little,rest::binary>>,n,previous,grids)
       when n>0 and i>previous and i<66*66*66 and count in [@samples,@samples*7] and byte_size(rest)>=count*2 do
    <<g::binary-size(count*2),tail::binary>> = rest
    if valid?(g),do: records_v2(tail,n-1,i,Map.put(grids,i,g)),else: {:error,:invalid_structure}
  end
  defp records_v2(_,_,_,_), do: {:error,:invalid_structure}
end
