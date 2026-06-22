defmodule SceneServer.Voxel.Field.LightPropagation do
  @moduledoc """
  纯光传播核(光学正交系统,2026-06-23)。**纯函数,无 Storage / NIF / IO**——给定光源、
  逐 cell 不透明度、邻接关系,算出每 cell 的权威光强。`LightPropagationKernel` 用它把
  `light_emission` 源 flood 成 `:light` 场层。

  ## 模型

  多源**最亮优先 flood**(= 在 `-log(衰减)` 权上的 Dijkstra,因每步增益 ≤ 1 故最亮路径
  即最小衰减路径,弹出最亮未定 cell 即其最终最大光强,与 Dijkstra 非负权同构):

    * 每个光源 cell 以其 `emission` 播种(自身不被自身 opacity 衰减——灯从自身发光)。
    * 从光强 L 的 cell c 向邻居 n 传:`candidate = L × attenuation × (1 - opacity(n))`
      (`attenuation` 每步距离衰减;`1-opacity(n)` 是 n 的透射率)。n 取所有来路 + 自身源的 max。
    * 全不透明 cell(opacity 1)透射 0 → 光强 0 且不再外传(墙挡光)。
    * 光强跌破 `threshold` 即停(不入队);`max_frontier` 熔断 settled cell 数(EMG 安全阀)。

  ## 形式不变量(light_propagation_test 严格守)

    1. **确定性**——同输入逐字节同输出;与源列表顺序无关(队列按 `{-light, idx}` 全序,无 Date/random)。
    2. **单调衰减**——单源沿任意路径光强非增;全透射直线上 `light[d] = emission × attenuation^d`。
    3. **有界**——任何 cell 光强 ∈ `[threshold, max(emission)]`,无凭空增亮。
    4. **源主导**——无源 → 全暗(空 map);加源使每 cell 光强单调不减。
    5. **遮挡**——仅经全不透明 cell 可达的 cell 光强为 0(不在结果中)。
  """

  @default_attenuation 0.7
  @default_threshold 1.0
  @default_max_frontier 4096
  @eps 1.0e-9

  @typedoc "macro 索引(或测试用任意可比较项)"
  @type idx :: term()

  @doc """
  从 `sources`(`%{idx => emission}`)flood 出每 cell 光强 `%{idx => light}`。

  `opacity` 是 `%{idx => 0.0..1.0}`(缺键 = 透明 0.0,即空气/空 cell);`neighbors_fn` 是
  `(idx -> [idx])` 邻接函数。opts:`:attenuation`(默认 0.7)、`:threshold`(默认 1.0)、
  `:max_frontier`(默认 4096)。
  """
  @spec flood(%{idx => number()}, %{idx => number()}, (idx -> [idx]), keyword()) :: %{
          idx => float()
        }
  def flood(sources, opacity, neighbors_fn, opts \\ [])
      when is_map(sources) and is_map(opacity) and is_function(neighbors_fn, 1) do
    attenuation = opts |> Keyword.get(:attenuation, @default_attenuation) |> clamp01()
    threshold = Keyword.get(opts, :threshold, @default_threshold) * 1.0
    max_frontier = opts |> Keyword.get(:max_frontier, @default_max_frontier) |> max(1)

    {queue, light} =
      Enum.reduce(sources, {:gb_sets.empty(), %{}}, fn {idx, emission}, {q, l} ->
        e = max(emission * 1.0, 0.0)

        if e >= threshold do
          {:gb_sets.add({-e, idx}, q), Map.update(l, idx, e, &max(&1, e))}
        else
          {q, l}
        end
      end)

    env = %{
      opacity: opacity,
      neighbors_fn: neighbors_fn,
      attenuation: attenuation,
      threshold: threshold,
      max_frontier: max_frontier
    }

    flood_loop(queue, light, MapSet.new(), 0, env)
  end

  defp flood_loop(queue, light, settled, frontier, env) do
    cond do
      :gb_sets.is_empty(queue) ->
        light

      frontier >= env.max_frontier ->
        light

      true ->
        {{neg_l, idx}, queue} = :gb_sets.take_smallest(queue)
        l = -neg_l

        cond do
          # 已定(更亮路径先弹出,首次弹出即最终最大)。
          MapSet.member?(settled, idx) ->
            flood_loop(queue, light, settled, frontier, env)

          # 陈旧队列项(已被更亮值取代)。
          l < Map.get(light, idx, 0.0) - @eps ->
            flood_loop(queue, light, settled, frontier, env)

          true ->
            settled = MapSet.put(settled, idx)

            {queue, light} =
              idx
              |> env.neighbors_fn.()
              |> Enum.reduce({queue, light}, fn n, {q, lt} ->
                relax(n, l, q, lt, settled, env)
              end)

            flood_loop(queue, light, settled, frontier + 1, env)
        end
    end
  end

  defp relax(n, l, queue, light, settled, env) do
    if MapSet.member?(settled, n) do
      {queue, light}
    else
      transmission = 1.0 - clamp01(Map.get(env.opacity, n, 0.0))
      candidate = l * env.attenuation * transmission

      if candidate >= env.threshold and candidate > Map.get(light, n, 0.0) + @eps do
        {:gb_sets.add({-candidate, n}, queue), Map.put(light, n, candidate)}
      else
        {queue, light}
      end
    end
  end

  defp clamp01(x) when x < 0.0, do: 0.0
  defp clamp01(x) when x > 1.0, do: 1.0
  defp clamp01(x), do: x * 1.0
end
