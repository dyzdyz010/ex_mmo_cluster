defmodule MmoContracts.Voxel.Refined do
  @moduledoc "VXR5 actual occupancy and identity suffix. No definition reconstruction."

  def encode(refined, instances) do
    IO.iodata_to_binary([
      <<map_size(refined)::32-little>>,
      for {index, slots} <- Enum.sort(refined) do
        [<<index::32-little, map_size(slots)::32-little>>,
         for {slot, {material, {birth, occurrence}}} <- Enum.sort(slots) do
           <<slot::16-little, material::16-little, birth::64-little, occurrence::32-little>>
         end]
      end,
      <<map_size(instances)::32-little>>,
      for {{birth, occurrence}, %{definition_id: id, anchor: {x,y,z}, orientation: o}} <- Enum.sort(instances) do
        <<birth::64-little, occurrence::32-little, id::binary-size(32), x::signed-little-64,
          y::signed-little-64, z::signed-little-64, o::8>>
      end
    ])
  end

  def decode(<<>>), do: {:ok, %{}, %{}, 4}
  def decode(<<count::32-little, rest::binary>>) do
    with {:ok, refined, <<n::32-little, rest::binary>>} <- cells(rest, count, -1, %{}),
         {:ok, instances, <<>>} <- instances(rest, n, {-1, -1}, %{}),
         true <- Enum.all?(refined, fn {_, slots} -> Enum.all?(slots, fn {_, {_, id}} -> Map.has_key?(instances, id) end) end) do
      {:ok, refined, instances, 5}
    else
      _ -> {:error, :invalid_refined}
    end
  end
  def decode(_), do: {:error, :invalid_refined}

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
  defp instances(rest, 0, _, acc), do: {:ok, acc, rest}
  defp instances(<<birth::64-little, occurrence::32-little, id::binary-size(32), x::signed-little-64,
                   y::signed-little-64, z::signed-little-64, o::8, rest::binary>>, n, previous, acc)
       when n > 0 and {birth,occurrence} > previous and o < 24 do
    key = {birth,occurrence}
    instances(rest,n-1,key,Map.put(acc,key,%{definition_id: id, anchor: {x,y,z}, orientation: o}))
  end
  defp instances(_, _, _, _), do: {:error, :invalid_refined}
end
