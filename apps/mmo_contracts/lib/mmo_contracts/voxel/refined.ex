defmodule MmoContracts.Voxel.Refined do
  @moduledoc "VXR5 actual occupancy and identity suffix. No definition reconstruction."

  alias MmoContracts.Voxel.Refined.Encoding

  @doc "VXR5/7 后缀；输入是 decoded map 或唯一显式编码投影，线上字节相同。"
  def encode(refined, instances, version \\ 5),
    do: refined |> encode_iodata(instances, version) |> IO.iodata_to_binary()

  @doc "相同后缀的有序iodata；完整载荷复用槽记录，在最终Codec边界统一物化。"
  def encode_iodata(refined, instances, version \\ 5) do
    {count, cells} = case refined do
      %Encoding{cells: cells} ->
        {map_size(cells), for({index, {count, bytes}} <- Enum.sort(cells),
          do: [<<index::32-little, count::32-little>>, bytes])}
      slots_by_cell when is_map(slots_by_cell) ->
        {map_size(slots_by_cell), for(cell <- Enum.sort(slots_by_cell), do: decoded_cell(cell))}
    end
    [
      <<count::32-little>>,
      cells,
      <<map_size(instances)::32-little>>,
      for {{birth, occurrence},
           %{definition_id: id, anchor: {x, y, z}, orientation: o} = instance} <-
            Enum.sort(instances) do
        base =
          <<birth::64-little, occurrence::32-little, id::binary-size(32), x::signed-little-64,
            y::signed-little-64, z::signed-little-64, o::8>>

        if version == 7 do
          {pb, po} = Map.get(instance, :parent_id, {0, 0})

          base <>
            <<pb::64-little, po::32-little, Map.get(instance, :component_slot, 0)::32-little>>
        else
          base
        end
      end
    ]
  end

  # decoded 输入每格必须是普通槽 map：槽数取 map_size。结构体也满足 is_map，但其 map_size 是字段数
  # 而非槽数（如 voxel_region 的紧凑 RefinedSlots），会写出计数与记录不符的不可解码字节；
  # 紧凑记录只经 Encoding 投影进入。每格一次守卫，不逐槽扫描。
  defp decoded_cell({index, slots}) when is_map(slots) and not is_struct(slots),
    do: [<<index::32-little, map_size(slots)::32-little>>, slot_records(slots)]

  defp decoded_cell({index, slots}),
    do: raise(ArgumentError, "refined cell #{index} requires a decoded slot map or Refined.Encoding projection, got: #{inspect(slots)}")

  @doc "一个宏格的槽记录（按槽号升序）：VXR5/7 refined 后缀中该格头之后的字节。"
  def slot_records(slots), do: slots |> Enum.sort() |> Enum.map(&slot_record/1) |> IO.iodata_to_binary()

  @doc "一个合法槽的 wire 记录；有序投影与 decoded-map 编码共用字段定义。"
  def slot_record({slot, {material, {birth, occurrence}}}),
    do: <<slot::16-little, material::16-little, birth::64-little, occurrence::32-little>>

  def decode(bytes, version \\ 5)
  def decode(<<>>, _), do: {:ok, %{}, %{}, 4}

  def decode(bytes, version) do
    case decode_prefix(bytes, version) do
      {:ok, refined, instances, <<>>} -> {:ok, refined, instances, version}
      _ -> {:error, :invalid_refined}
    end
  end

  @doc "解析 VXR7 后缀的前缀，供 VXR8 继续读取附件段。"
  def decode_prefix(<<count::32-little, rest::binary>>, version) do
    with {:ok, refined, <<n::32-little, rest::binary>>} <- cells(rest, count, -1, %{}),
         {:ok, instances, tail} <- instances(rest, n, {-1, -1}, %{}, version),
         true <-
           Enum.all?(refined, fn {_, slots} ->
             Enum.all?(slots, fn {_, {_, id}} -> Map.has_key?(instances, id) end)
           end) do
      if version != 7 or valid_hierarchy?(instances),
        do: {:ok, refined, instances, tail},
        else: {:error, :invalid_refined}
    else
      _ -> {:error, :invalid_refined}
    end
  end

  def decode_prefix(_, _), do: {:error, :invalid_refined}

  defp cells(rest, 0, _, acc), do: {:ok, acc, rest}

  defp cells(<<index::32-little, n::32-little, rest::binary>>, count, previous, acc)
       when count > 0 and index > previous and index < 66 * 66 * 66 and n in 1..512 do
    with {:ok, slots, rest} <- slots(rest, n, -1, %{}),
         do: cells(rest, count - 1, index, Map.put(acc, index, slots))
  end

  defp cells(_, _, _, _), do: {:error, :invalid_refined}
  defp slots(rest, 0, _, acc), do: {:ok, acc, rest}

  defp slots(
         <<slot::16-little, material::16-little, birth::64-little, occurrence::32-little,
           rest::binary>>,
         n,
         previous,
         acc
       )
       when slot > previous and slot < 512 and material > 0 do
    slots(rest, n - 1, slot, Map.put(acc, slot, {material, {birth, occurrence}}))
  end

  defp slots(_, _, _, _), do: {:error, :invalid_refined}
  defp instances(rest, 0, _, acc, _), do: {:ok, acc, rest}

  defp instances(
         <<birth::64-little, occurrence::32-little, id::binary-size(32), x::signed-little-64,
           y::signed-little-64, z::signed-little-64, o::8, rest::binary>>,
         n,
         previous,
         acc,
         version
       )
       when n > 0 and {birth, occurrence} > previous and o < 24 do
    key = {birth, occurrence}
    value = %{definition_id: id, anchor: {x, y, z}, orientation: o}

    case {version, rest} do
      {7, <<pb::64-little, po::32-little, slot::32-little, tail::binary>>} ->
        instances(
          tail,
          n - 1,
          key,
          Map.put(acc, key, Map.merge(value, %{parent_id: {pb, po}, component_slot: slot})),
          version
        )

      {5, _} ->
        instances(rest, n - 1, key, Map.put(acc, key, value), version)

      _ ->
        {:error, :invalid_refined}
    end
  end

  defp instances(_, _, _, _, _), do: {:error, :invalid_refined}

  def ancestors(instances, ids) do
    Enum.reduce(ids, MapSet.new(), fn id, acc -> include_ancestors(instances, id, acc) end)
    |> MapSet.to_list()
  end

  defp include_ancestors(_, {0, 0}, acc), do: acc

  defp include_ancestors(instances, id, acc) do
    if MapSet.member?(acc, id),
      do: acc,
      else:
        include_ancestors(
          instances,
          Map.get(Map.fetch!(instances, id), :parent_id, {0, 0}),
          MapSet.put(acc, id)
        )
  end

  defp valid_hierarchy?(instances) do
    Enum.all?(instances, fn {{birth, _} = id, instance} ->
      parent = instance.parent_id

      birth > 0 and
        if(parent == {0, 0},
          do: instance.component_slot == 0,
          else: parent < id and Map.has_key?(instances, parent)
        )
    end) and
      instances
      |> Enum.reject(fn {_, i} -> i.parent_id == {0, 0} end)
      |> Enum.map(fn {_, i} -> {i.parent_id, i.component_slot} end)
      |> then(&(length(&1) == MapSet.size(MapSet.new(&1))))
  end
end
