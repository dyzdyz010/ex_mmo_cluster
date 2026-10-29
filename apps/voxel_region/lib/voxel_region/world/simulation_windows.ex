defmodule VoxelRegion.World.SimulationWindows do
  @moduledoc """
  全局系统功能：窗口贡献的观察元数据，由 World 唯一写入。来源通常为随 Gate 存活的 CollisionStream。
  保留当前、未来和请求中的完整 XYZ 盒，以及既有外扩页统计，便于观察流送生命周期。
  窗口不授予或撤销物理演化资格；热、液体、电路与拟态由世界实际活动推进。
  """

  @doc "在接纳边界校验并规范化完整 XYZ 窗口；空集合表示释放该来源。"
  def normalize(boxes) do
    if valid_boxes?(boxes),
      do: {:ok, boxes |> Enum.uniq() |> Enum.sort()},
      else: {:error, :invalid_simulation_windows}
  end

  defp valid_boxes?([]), do: true

  defp valid_boxes?([{lo, hi} | tail])
       when is_tuple(lo) and tuple_size(lo) == 3 and is_tuple(hi) and tuple_size(hi) == 3 do
    Enum.all?(0..2, fn axis ->
      is_integer(elem(lo, axis)) and is_integer(elem(hi, axis)) and
        elem(lo, axis) < elem(hi, axis)
    end) and
      valid_boxes?(tail)
  end

  defp valid_boxes?(_), do: false

  @doc "由 World 接纳合法集合并维护来源 monitor；返回是否改变。"
  def put(sources, source, []), do: remove(sources, source)

  def put(sources, source, boxes) do
    case Map.get(sources, source) do
      %{windows: ^boxes} -> {sources, false}
      nil -> {Map.put(sources, source, %{windows: boxes, monitor: Process.monitor(source)}), true}
      entry -> {Map.put(sources, source, %{entry | windows: boxes}), true}
    end
  end

  @doc "World 收到来源 DOWN 或显式释放时退休；重复通知不产生第二次变化。"
  def remove(sources, source) do
    case Map.pop(sources, source) do
      {nil, _} ->
        {sources, false}

      {%{monitor: monitor}, remaining} ->
        Process.demonitor(monitor, [:flush])
        {remaining, true}
    end
  end

  @doc "窗口贡献的页并集，完整三维外扩一圈；只在消费者请求时派生。"
  def pages(sources) do
    for {_, %{windows: boxes}} <- sources,
        {{lx, ly, lz}, {hx, hy, hz}} <- boxes,
        x <- (lx - 1)..hx,
        y <- (ly - 1)..hy,
        z <- (lz - 1)..hz,
        into: MapSet.new(),
        do: {x, y, z}
  end

  @doc "供 CLI／日志验证的可 JSON 编码窗口报告；window_pages 仅是窗口元数据，不是世界活动集。"
  def observe(sources) do
    pages = pages(sources)

    %{
      source_count: map_size(sources),
      window_page_count: MapSet.size(pages),
      window_pages: pages |> Enum.sort() |> Enum.map(&Tuple.to_list/1),
      sources:
        Enum.map(sources, fn {source, %{windows: boxes}} ->
          %{
            source: inspect(source),
            source_node: Atom.to_string(node(source)),
            windows:
              Enum.map(boxes, fn {lo, hi} ->
                %{min: Tuple.to_list(lo), max_exclusive: Tuple.to_list(hi)}
              end)
          }
        end)
        |> Enum.sort_by(& &1.source)
    }
  end
end
