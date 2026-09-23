defmodule VoxelRegion.ThermalRadiation do
  @moduledoc """
  全局系统功能：灰体辐射换热的派生视线与内核项；纯值输入输出，不读取 World。

  每个暴露面沿外法线看至多 `view_range_cells` 个宏格（World 读取 canonical 实占用）：
  首个命中的热节点构成半对，面积 A/2、灰体平行板因子 ε/(2−ε)，互逆两条视线合成
  σA(T_b⁴−T_a⁴)/(2/ε−1)；未命中或命中无热容量占用则对天空 εσA(T_amb⁴−T⁴)。
  每个半对自身反对称，宏/微格尺寸不同也严格守恒。线性环境换热保持原语义不变。
  """

  @doc "环境是否启用辐射；发射率为 0 时不做视线读取，内核与无辐射版本逐位相同。"
  def enabled?(config), do: config["emissivity"] > 0

  @doc "把一个节点全部视线的命中按目标合并：`[{节点键, :sky | {目标键, 目标宏格}, 面积}]`。"
  def sights(key, hits) do
    hits
    |> Enum.reduce(%{}, fn {hit, area}, sum -> Map.update(sum, hit, area, &(&1 + area)) end)
    |> Enum.map(fn {hit, area} -> {key, hit, area} end)
  end

  @doc "热种子的视线伙伴宏格；它们加入候选域但只有真实升温越过容差才成为种子。"
  def partners(sights, seeds) do
    for seed <- seeds, {_, {_, cell}, _} <- Map.get(sights, seed, []), into: MapSet.new(), do: cell
  end

  @doc "按内核节点顺序生成 `{半对, 对天空}`；伙伴不在本次节点集内时按域边界绝热处理。"
  def terms(ordered, sights, emissivity) do
    indices = ordered |> Enum.with_index() |> Map.new(fn {{key, _}, i} -> {key, i} end)
    grey = emissivity / (2 - emissivity)

    rows = for {_, rows} <- sights, {key, hit, area} <- rows, Map.has_key?(indices, key),
      do: {Map.fetch!(indices, key), hit, area}

    {pairs, sky} =
      rows
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn
        {i, :sky, area}, {pairs, sky} -> {pairs, [{i, emissivity * area} | sky]}
        {i, {other, _}, area}, {pairs, sky} ->
          case Map.fetch(indices, other) do
            {:ok, j} -> {[{i, j, grey * area / 2} | pairs], sky}
            :error -> {pairs, sky}
          end
      end)

    {Enum.reverse(pairs), Enum.reverse(sky)}
  end
end
