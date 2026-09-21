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

  @doc "由共享体素盒编译器展开有序宏格操作，保留荒野施工的 2000 格上限。"
  defdelegate cells(ops), to: VoxelRegion.Blueprint

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
