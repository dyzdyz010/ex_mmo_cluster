defmodule SceneServer.Movement.Authority do
  @moduledoc "Scene 分工与碰撞驻留窗口正交；当前相邻两区沿共同平面分工。"
  @doc "判断坐标属于有限 probe 区域或正式地图的 Scene 半空间。"
  def contains?(point, {:halfspace, axis, border, :below}), do: elem(point, axis) < border
  def contains?(point, {:halfspace, axis, border, :above}), do: elem(point, axis) >= border

  def contains?(point, {min, max}),
    do: Enum.all?(0..2, &(elem(point, &1) >= elem(min, &1) and elem(point, &1) < elem(max, &1)))

  @doc "从两块相邻 Scene 的共同平面推导互补的全域分工。"
  def partition({lo, hi}, {other_lo, other_hi}) do
    axis =
      Enum.find(0..2, &(elem(hi, &1) == elem(other_lo, &1) or elem(lo, &1) == elem(other_hi, &1)))

    if elem(hi, axis) == elem(other_lo, axis),
      do:
        {{:halfspace, axis, elem(hi, axis), :below}, {:halfspace, axis, elem(hi, axis), :above}},
      else:
        {{:halfspace, axis, elem(lo, axis), :above}, {:halfspace, axis, elem(lo, axis), :below}}
  end
end
