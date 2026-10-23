defmodule MmoContracts.Voxel.Canopy do
  @moduledoc "VXRD v1 稀疏树冠呈现段；真实宏格、既有实例身份与纯呈现残余，不参与碰撞或结算。"
  import Bitwise
  alias MmoContracts.Voxel.{Refined, Skins}

  @doc "编码规范排序的锚点、VXR7 实例表与稀疏残余表皮。"
  def encode(anchors, instances, residual, structure \\ %{}) do
    IO.iodata_to_binary([
      <<1::32-little>>, Refined.encode(%{}, instances, 7), <<map_size(anchors)::32-little>>,
      for({{x,y,z},{material,{birth,occurrence},presentation}} <- Enum.sort(anchors), do:
        <<x::signed-little-64,y::signed-little-64,z::signed-little-64,birth::64-little,occurrence::32-little,material::16-little,presentation::16-little>>),
      <<map_size(residual)::32-little>>,
      for({index,{material,skins}} <- Enum.sort(residual), do: [<<index::32-little,material::16-little>>,encode_skins(skins)]),
      MmoContracts.Voxel.Structure.encode(structure)
    ])
  end

  defp encode_skins(skins) do
    {extent,faces}=Skins.canonical(skins)
    faces=Tuple.to_list(faces)
    mask=faces |> Enum.with_index() |> Enum.reduce(0,fn {{_,texels},i},mask -> if texels,do: mask ||| (1 <<< i),else: mask end)
    [<<extent>>,for({id,_}<-faces,do: <<id>>),<<mask>>,for({_,texels}<-faces,texels != nil,do: texels)]
  end

  @doc "完整信任边界：拒绝重复、乱序、悬空身份、坏贴图、未知版本及多余字节。"
  def decode(<<1::32-little,rest::binary>>) do
    with {:ok,refined,instances,<<count::32-little,rest::binary>>} <- Refined.decode_prefix(rest,7),
         true <- map_size(refined)==0,
         {:ok,anchors,<<count::32-little,rest::binary>>} <- anchors(rest,count,nil,%{},instances),
         {:ok,residual,rest} <- residual(rest,count,-1,%{}),
         {:ok,structure} <- decode_structure(rest),
         true <- Enum.all?(structure,fn {index,_}->Map.has_key?(residual,index) end) do
      {:ok,anchors,instances,residual,structure}
    else
      _ -> {:error,:invalid_canopy}
    end
  end
  def decode(_),do: {:error,:invalid_canopy}
  defp decode_structure(<<2::32-little,0::32>>),do: {:ok,%{}}
  defp decode_structure(rest),do: MmoContracts.Voxel.Structure.decode(rest)

  defp anchors(rest,0,_,acc,_),do: {:ok,acc,rest}
  defp anchors(<<x::signed-little-64,y::signed-little-64,z::signed-little-64,birth::64-little,occurrence::32-little,material::16-little,presentation::16-little,rest::binary>>,count,previous,acc,instances)
    when count>0 and material>0 and presentation>0 do
    point={x,y,z}; owner={birth,occurrence}
    if (previous==nil or point>previous) and Map.has_key?(instances,owner),
      do: anchors(rest,count-1,point,Map.put(acc,point,{material,owner,presentation}),instances),else: :error
  end
  defp anchors(_,_,_,_,_),do: :error
  defp residual(rest,0,_,acc),do: {:ok,acc,rest}
  defp residual(<<index::32-little,material::16-little,extent,ids::binary-size(6),mask,rest::binary>>,count,previous,acc)
    when count>0 and index>previous and index<66*66*66 and extent in [1,2,4] and mask<64 and (extent != 1 or mask==0) do
    with {:ok,faces,rest} <- faces(rest,:binary.bin_to_list(ids),mask,extent,0,[]) do
      skins={extent,List.to_tuple(Enum.reverse(faces))}
      if Skins.canonical(skins)==skins,do: residual(rest,count-1,index,Map.put(acc,index,{material,skins})),else: :error
    end
  end
  defp residual(_,_,_,_),do: :error
  defp faces(rest,[],_,_,_,acc),do: {:ok,acc,rest}
  defp faces(rest,[id|ids],mask,extent,i,acc) do
    if (mask &&& (1 <<< i))==0 do
      faces(rest,ids,mask,extent,i+1,[{id,nil}|acc])
    else
      size=extent*extent
      case rest do
        <<texels::binary-size(^size),rest::binary>> -> faces(rest,ids,mask,extent,i+1,[{id,texels}|acc])
        _ -> :error
      end
    end
  end
end