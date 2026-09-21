defmodule VoxelRegion.Blueprint do
  @moduledoc "全局系统功能：荒野蓝图与 prefab 草稿共用的宏格盒操作；坐标闭区间，墙不含地板与屋顶。"

  @doc "按顺序编译非空蓝图；荒野施工保留原有 2000 格限制。"
  def cells(ops) when is_list(ops) do
    Enum.reduce_while(ops, {:ok, %{}}, fn op, {:ok, cells} ->
      case edit(cells, op, 2_000) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, cells} when map_size(cells) > 0 and map_size(cells) <= 2_000 -> {:ok, cells}
      _ -> :error
    end
  end

  def cells(_), do: :error

  @doc "在已有宏格上执行一次 fill / walls / clear；允许清成空草稿。"
  def edit(cells, op, limit) do
    with coords when coords != nil <- box(op, limit),
         %{} = next <- apply_op(op, coords, cells) do
      {:ok, next}
    else
      _ -> :error
    end
  end

  defp apply_op(%{"op" => "clear"}, coords, cells), do: Map.drop(cells, coords)
  defp apply_op(%{"op" => op, "material" => material} = box, coords, cells)
       when op in ["fill", "walls"] and is_integer(material) and material > 0 do
    coords = if op == "walls", do: ring(coords, box["min"], box["max"]), else: coords
    Enum.reduce(coords, cells, &Map.put(&2, &1, material))
  end
  defp apply_op(_, _, _), do: :error

  defp box(%{"min" => [x0,y0,z0], "max" => [x1,y1,z1]}, limit)
       when is_integer(x0) and is_integer(y0) and is_integer(z0) and is_integer(x1) and
              is_integer(y1) and is_integer(z1) and x0 <= x1 and y0 <= y1 and z0 <= z1 and
              (x1-x0+1)*(y1-y0+1)*(z1-z0+1) <= limit,
       do: for(x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x,y,z})
  defp box(_, _), do: nil
  defp ring(coords, [x0,_,z0], [x1,_,z1]), do: Enum.filter(coords, fn {x,_,z} -> x in [x0,x1] or z in [z0,z1] end)
end
