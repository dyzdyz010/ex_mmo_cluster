defmodule MmoContracts.Voxel.Attachments do
  @moduledoc "全局系统功能：VXR8 规范微格面／棱槽字节，不持有世界或渲染状态。"

  @doc "按规范地址排序编码；每槽36字节。"
  def encode(slots) do
    # 槽键唯一，按键排序等于整条 tuple 排序；binary comprehension 避免逐槽的小 binary 列表。
    body =
      for {{kind, axis, {x, y, z}}, {id, material}} <- :lists.keysort(1, Map.to_list(slots)),
          into: <<>> do
        <<kind, axis, x::signed-little-64, y::signed-little-64, z::signed-little-64,
          id::little-64, material::little-16>>
      end

    <<map_size(slots)::little-32, body::binary>>
  end

  @doc "在载荷接纳边界检查排序、唯一占用及当前材料规格。"
  def decode(<<n::little-32, bytes::binary>>) when byte_size(bytes) == n * 36,
    do: slots(bytes, nil, %{})

  def decode(_), do: {:error, :invalid_attachments}

  defp slots(<<>>, _, acc), do: {:ok, acc}

  defp slots(
         <<kind, axis, x::signed-little-64, y::signed-little-64, z::signed-little-64,
           id::little-64, material::little-16, rest::binary>>,
         previous,
         acc
       )
       when kind in [0, 1] and axis in 0..2 and id > 0 do
    key = {kind, axis, {x, y, z}}

    if (previous == nil or key > previous) and material?(material),
      do: slots(rest, key, Map.put(acc, key, {id, material})),
      else: {:error, :invalid_attachments}
  end

  defp slots(_, _, _), do: {:error, :invalid_attachments}

  @doc "首片只允许目录中不透明实体材料（排除空气、水、冰）。"
  def material?(id), do: MmoContracts.VoxelMaterialCatalog.valid_id?(id) and id not in [0, 20, 21]
end
