defmodule VoxelRegion.PropertyObservation do
  @moduledoc "全局系统功能：按 canonical 窗口投影不可变属性观察；不持有世界或模拟状态。"
  alias VoxelRegion.{CollisionSource, Damage}

  @doc "宏格是否位于完整 XYZ tile 窗口。"
  def contains?(cell, box), do: CollisionSource.in_box?(CollisionSource.chunk_coord(cell), box)

  @doc "普通格按位置、叶子按实际占用区域与删除前区域并集筛选。"
  def relevant?(%{granularity: g, observation_cells: cells}, box) when g in [2,3],
    do: Enum.any?(cells, &contains?(&1, box))
  def relevant?(row, box), do: contains?(Damage.macro(row), box)

  @doc "投影属性与身份；保留事务本身及其进度。"
  def project(value, box) do
    value
    |> Map.update(:property_states, [], &Enum.filter(&1, fn row -> relevant?(row, box) end))
    |> project_falls(fn cell -> contains?(cell, box) end)
    |> project_operation(fn cell -> contains?(cell, box) end)
    |> Map.update(:epochs, %{}, &Map.filter(&1, fn {cell, _} -> contains?(cell, box) end))
    |> project_protection(box)
    |> project_structures(box)
    |> project_casts(box)
  end

  # 受保护区域：新建/现有区域按矩形与窗口相交筛选；删除（nil）不知旧范围，总是保留。
  defp project_protection(%{protection: regions} = value, box),
    do: %{value | protection: Map.filter(regions, fn {_, r} -> r == nil or VoxelRegion.Protection.relevant?(r, box) end)}
  defp project_protection(value, _box), do: value

  # 结构记录与状态增量（魔法 v2 切片 4c）：出发点或落点宏格在窗口内的保留；删除（nil）不知旧位置，总是保留。
  # 状态增量随完整记录一起运输（`World.Structures`），按同一位置筛选，编码时才投影成 20 B 增量。
  defp project_structures(value, box) do
    keep = fn records -> Map.filter(records, fn {_, r} -> r == nil or in_window?(r, box) end) end

    value
    |> then(&if(Map.has_key?(&1, :structures), do: Map.update!(&1, :structures, keep), else: &1))
    |> then(&if(Map.has_key?(&1, :structure_states), do: Map.update!(&1, :structure_states, keep), else: &1))
  end

  defp in_window?(record, box), do: Enum.any?(VoxelRegion.Magic.Semblance.cells(record), &contains?(&1, box))

  # 待施放（施放前摇）：前摇中的记录按手边出发点宏格投影；已结算记录不带位置，总是保留。
  defp project_casts(%{casts: casts} = value, box),
    do: %{value | casts: Map.filter(casts, fn {_, c} ->
      c.live == 0 or contains?(VoxelRegion.Magic.Semblance.macro(c.origin), box) end)}
  defp project_casts(value, _box), do: value
  @doc "实时整帧按接收方空间谓词投影；空帧仍表示清除。"
  def project_falls(%{liquid_falls: frame} = value, contains?) do
    %{value | liquid_falls: %{frame | transfers: Enum.filter(frame.transfers, fn {cell, _units} -> contains?.(cell) end)}}
  end
  def project_falls(value, _contains?), do: value
  @doc "Global system: one live operation scoped by its full canonical XYZ position."
  def project_operation(%{operation: operation} = value, contains?) do
    if contains?.(Damage.macro(operation)), do: value, else: Map.delete(value,:operation)
  end
  def project_operation(value, _contains?), do: value

end
