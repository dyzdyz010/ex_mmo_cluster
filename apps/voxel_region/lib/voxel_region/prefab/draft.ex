defmodule VoxelRegion.Prefab.Draft do
  @moduledoc """
  全局系统功能：无状态 prefab 编辑内核。草稿就是 decoded VXPD v3 定义，无独立操作历史或世界进度。
  宏格盒沿用 Blueprint；目录部件按 slot 增改删，锚点是 micro 坐标。编辑暂存可留空或未通过结构检查，
  发布时统一交给 Prefab.compile 的展开预算、对齐、占用与支撑检查。玩家与 NPC 可共用这些纯函数。
  """
  alias MmoContracts.VoxelMaterialCatalog
  alias VoxelRegion.Prefab

  @doc "新建可编辑的空定义。"
  def new, do: %{cells: [], macro_cells: [], children: [], attachments: []}

  @doc "原子执行有序操作；错误不返回半成品。材料 0 的 micro 操作删除该格。"
  def edit(draft, ops) when is_list(ops) do
    Enum.reduce_while(ops, {:ok, draft}, fn op, {:ok, current} ->
      case operation(current, op) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end
  def edit(_, _), do: {:error, :invalid_edit}

  defp operation(d, %{"op" => op, "min" => lo, "max" => hi} = box) when op in ["fill","walls","clear"] do
    extent = div(Prefab.limits().extent_micro, VoxelRegion.Spatial.micro_resolution())
    scratch_cells = extent * extent * extent
    with true <- coord?(lo) and coord?(hi),
         true <- op == "clear" or material?(box["material"]),
         {:ok, cells} <- VoxelRegion.Blueprint.edit(Map.new(d.macro_cells), box, scratch_cells),
         true <- map_size(cells) <= scratch_cells do
      {:ok, %{d | macro_cells: Enum.sort(cells)}}
    else
      _ -> {:error, :invalid_edit}
    end
  end

  defp operation(d, %{"op" => "micro", "cell" => cell, "material" => m}) do
    with true <- coord?(cell) and (m == 0 or material?(m)),
         cells = Map.new(d.cells),
         point = List.to_tuple(cell),
         cells = if(m == 0, do: Map.delete(cells,point), else: Map.put(cells,point,m)),
         true <- map_size(cells) <= Prefab.limits().micro_cells do
      {:ok, %{d | cells: Enum.sort(cells)}}
    else
      _ -> {:error, :invalid_edit}
    end
  end

  defp operation(d, %{"op" => "prefab", "slot" => slot, "id" => id, "anchor_micro" => anchor, "orientation" => o}) do
    with true <- slot?(slot) and coord?(anchor) and is_integer(o) and o in 0..23 and is_binary(id),
         {:ok, <<definition::binary-size(32)>>} <- Base.decode16(id, case: :mixed),
         child = %{slot: slot, definition_id: definition, anchor: List.to_tuple(anchor), orientation: o},
         children = [child | Enum.reject(d.children, &(&1.slot == slot))],
         true <- length(children) < Prefab.limits().nodes do
      {:ok, %{d | children: Enum.sort_by(children,& &1.slot)}}
    else
      _ -> {:error, :invalid_edit}
    end
  end

  defp operation(d, %{"op" => "remove_prefab", "slot" => slot}) do
    if Enum.any?(d.children, &(&1.slot == slot)),
      do: {:ok, %{d | children: Enum.reject(d.children,&(&1.slot == slot))}},
      else: {:error, :component_not_found}
  end
  defp operation(_, _), do: {:error, :invalid_edit}

  defp coord?([x,y,z]), do: Enum.all?([x,y,z], &(is_integer(&1) and &1 >= -2_147_483_648 and &1 <= 2_147_483_647))
  defp coord?(_), do: false
  defp slot?(s), do: is_integer(s) and s >= 0 and s <= 4_294_967_295
  defp material?(m), do: is_integer(m) and m > 0 and VoxelMaterialCatalog.valid_id?(m)
end
