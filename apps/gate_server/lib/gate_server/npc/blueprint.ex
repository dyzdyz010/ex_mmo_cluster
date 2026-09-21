defmodule GateServer.Npc.Blueprint do
  @moduledoc """
  全局系统功能：建造蓝图。规划者（LLM）只交一份结构化蓝图，不逐格下命令；展开、排序、与世界对账都是这里的纯函数，
  逐格施工由 `GateServer.Npc.Brain.Builder` 执行。

  蓝图是一串按顺序生效的操作（macro 格闭区间，纯数据，可以原样存进记忆）：

      %{"op" => "fill", "min" => [x, y, z], "max" => [x, y, z], "material" => id}                    # 实心盒
      %{"op" => "walls", "min" => ..., "max" => ..., "material" => id}                              # 只有四面竖墙（盒子的水平外圈），不含地板和顶
      %{"op" => "clear", "min" => ..., "max" => ...}                                               # 挖空（门洞、窗洞、屋内）

  后面的操作覆盖前面的：先 walls 一圈墙、fill 一层屋顶，再 clear 出门窗。没有“空心盒”：实测规划者会拿它砌墙，
  结果白得一层石地板和一层石天花板，屋内净高只剩一格。世界才是真值：蓝图只说“应该是什么”，进度永远由
  `remaining/2` 拿 `look` 的结果现算，不另记“做到第几格”。
  """

  @max_cells 2_000

  @doc "展开成 `%{{x, y, z} => material}`。不合法（形状不对、盒子颠倒、超过 #{@max_cells} 格）返回 `:error`。"
  def cells(ops) when is_list(ops) do
    Enum.reduce_while(ops, %{}, fn op, cells ->
      with coords when coords != nil <- box(op),
           %{} = cells <- apply_op(op, coords, cells) do
        {:cont, cells}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      %{} = cells when map_size(cells) > 0 and map_size(cells) <= @max_cells -> {:ok, cells}
      _ -> :error
    end
  end

  def cells(_), do: :error

  defp apply_op(%{"op" => "clear"}, coords, cells), do: Map.drop(cells, coords)

  defp apply_op(%{"op" => op, "material" => material} = box, coords, cells)
       when op in ["fill", "walls"] and is_integer(material) and material > 0 do
    coords = if op == "walls", do: ring(coords, box["min"], box["max"]), else: coords
    Enum.reduce(coords, cells, &Map.put(&2, &1, material))
  end

  defp apply_op(_, _, _), do: :error

  defp box(%{"min" => [x0, y0, z0], "max" => [x1, y1, z1]})
       when is_integer(x0) and is_integer(y0) and is_integer(z0) and is_integer(x1) and is_integer(y1) and
              is_integer(z1) and x0 <= x1 and y0 <= y1 and z0 <= z1 and
              (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) <= @max_cells,
       do: for(x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x, y, z})

  defp box(_), do: nil

  defp ring(coords, [x0, _, z0], [x1, _, z1]), do: Enum.filter(coords, fn {x, _, z} -> x in [x0, x1] or z in [z0, z1] end)

  @doc "包围盒 `{min, max}`。"
  def bounds(cells) do
    {xs, ys, zs} = cells |> Map.keys() |> Enum.map(&Tuple.to_list/1) |> Enum.zip() |> Enum.map(&Tuple.to_list/1) |> List.to_tuple()
    {{Enum.min(xs), Enum.min(ys), Enum.min(zs)}, {Enum.max(xs), Enum.max(ys), Enum.max(zs)}}
  end

  @doc """
  与世界对账。`world` 是 `%{{x, y, z} => material}`（`look` 的结果，0 = 空气；蓝图包围盒内的格都要有）。返回
  `%{todo: [{cell, material}], wrong: [{cell, 现有, 应有}]}`：`todo` 是还空着、该放的格，自下而上、同层按坐标排序（不会先封顶）；
  `wrong` 是已被别的材料占着的格——蓝图对世界的假设不成立，交给调度层，不擅自拆。
  """
  def remaining(cells, world) do
    {todo, wrong} =
      cells
      |> Enum.reject(fn {cell, material} -> Map.fetch!(world, cell) == material end)
      |> Enum.split_with(fn {cell, _} -> Map.fetch!(world, cell) == 0 end)

    %{
      todo: Enum.sort_by(todo, fn {{x, y, z}, _} -> {y, x, z} end),
      wrong: for({cell, material} <- Enum.sort(wrong), do: {cell, Map.fetch!(world, cell), material})
    }
  end

  @doc """
  站位：包围盒四条边中点外 2 格处（站在盒外，不会把自己砌进去、也不占着要放的格），按离 `cell` 的水平距离由近到远。
  返回水平点 `{x, z}`；够不够得着由权威的射程裁决，够不着就换下一个。
  """
  def stands(cells, {cx, _, cz}) do
    {{x0, _, z0}, {x1, _, z1}} = bounds(cells)
    {mx, mz} = {(x0 + x1 + 1) / 2, (z0 + z1 + 1) / 2}

    [{mx, z0 - 1.5}, {mx, z1 + 2.5}, {x0 - 1.5, mz}, {x1 + 2.5, mz}]
    |> Enum.sort_by(fn {x, z} -> (x - cx - 0.5) * (x - cx - 0.5) + (z - cz - 0.5) * (z - cz - 0.5) end)
  end
end
