defmodule MmoContracts.Voxel.Refined do
  @moduledoc "VXR5 actual occupancy and identity suffix. No definition reconstruction."

  def encode(refined, instances, version \\ 5) do
    IO.iodata_to_binary([
      <<map_size(refined)::32-little>>,
      for {index, slots} <- Enum.sort(refined) do
        [<<index::32-little, map_size(slots)::32-little>>,
         for {slot, {material, {birth, occurrence}}} <- Enum.sort(slots), into: <<>> do
           <<slot::16-little, material::16-little, birth::64-little, occurrence::32-little>>
         end]
      end,
      <<map_size(instances)::32-little>>,
      for {{birth, occurrence}, %{definition_id: id, anchor: {x,y,z}, orientation: o}=instance} <- Enum.sort(instances) do
        base = <<birth::64-little, occurrence::32-little, id::binary-size(32), x::signed-little-64,
          y::signed-little-64, z::signed-little-64, o::8>>
        if version == 7 do
          {pb,po} = Map.get(instance,:parent_id,{0,0})
          base <> <<pb::64-little,po::32-little,Map.get(instance,:component_slot,0)::32-little>>
        else
          base
        end
      end
    ])
  end

  def decode(bytes, version \\ 5)
  def decode(<<>>, _), do: {:ok, %{}, %{}, 4}
  def decode(<<count::32-little, rest::binary>>, version) do
    with {:ok, refined, <<n::32-little, rest::binary>>} <- cells(rest, count, -1, %{}),
         {:ok, instances, <<>>} <- instances(rest, n, {-1, -1}, %{}, version),
         true <- Enum.all?(refined, fn {_, slots} -> Enum.all?(slots, fn {_, {_, id}} -> Map.has_key?(instances, id) end) end) do
      if version != 7 or valid_hierarchy?(instances), do: {:ok, refined, instances, version}, else: {:error,:invalid_refined}
    else
      _ -> {:error, :invalid_refined}
    end
  end
  def decode(_, _), do: {:error, :invalid_refined}

  defp cells(rest, 0, _, acc), do: {:ok, acc, rest}
  defp cells(<<index::32-little, n::32-little, rest::binary>>, count, previous, acc)
       when count > 0 and index > previous and index < 66*66*66 and n in 1..512 do
    with {:ok, slots, rest} <- slots(rest, n, -1, %{}), do: cells(rest, count-1, index, Map.put(acc,index,slots))
  end
  defp cells(_, _, _, _), do: {:error, :invalid_refined}
  defp slots(rest, 0, _, acc), do: {:ok, acc, rest}
  defp slots(<<slot::16-little, material::16-little, birth::64-little, occurrence::32-little, rest::binary>>, n, previous, acc)
       when slot > previous and slot < 512 and material > 0 do
    slots(rest, n-1, slot, Map.put(acc,slot,{material,{birth,occurrence}}))
  end
  defp slots(_, _, _, _), do: {:error, :invalid_refined}
  defp instances(rest, 0, _, acc, _), do: {:ok, acc, rest}
  defp instances(<<birth::64-little, occurrence::32-little, id::binary-size(32), x::signed-little-64,
                   y::signed-little-64, z::signed-little-64, o::8, rest::binary>>, n, previous, acc, version)
       when n > 0 and {birth,occurrence} > previous and o < 24 do
    key = {birth,occurrence}
    value = %{definition_id: id, anchor: {x,y,z}, orientation: o}
    case {version,rest} do
      {7,<<pb::64-little,po::32-little,slot::32-little,tail::binary>>} ->
        instances(tail,n-1,key,Map.put(acc,key,Map.merge(value,%{parent_id: {pb,po},component_slot: slot})),version)
      {5,_} -> instances(rest,n-1,key,Map.put(acc,key,value),version)
      _ -> {:error,:invalid_refined}
    end
  end
  defp instances(_, _, _, _, _), do: {:error, :invalid_refined}
  def ancestors(instances, ids) do
    Enum.reduce(ids,MapSet.new(),fn id,acc -> include_ancestors(instances,id,acc) end) |> MapSet.to_list()
  end
  defp include_ancestors(_, {0,0}, acc), do: acc
  defp include_ancestors(instances,id,acc) do
    if MapSet.member?(acc,id), do: acc,
      else: include_ancestors(instances,Map.get(Map.fetch!(instances,id),:parent_id,{0,0}),MapSet.put(acc,id))
  end
  defp valid_hierarchy?(instances) do
    Enum.all?(instances,fn {{birth,_}=id,instance} ->
      parent = instance.parent_id
      birth > 0 and if(parent == {0,0},do: instance.component_slot == 0,else: parent < id and Map.has_key?(instances,parent))
    end) and
    (instances |> Enum.reject(fn {_,i} -> i.parent_id == {0,0} end) |> Enum.map(fn {_,i} -> {i.parent_id,i.component_slot} end) |> then(&(length(&1)==MapSet.size(MapSet.new(&1)))))
  end
end
