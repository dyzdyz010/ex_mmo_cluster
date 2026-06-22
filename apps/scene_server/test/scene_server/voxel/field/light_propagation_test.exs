defmodule SceneServer.Voxel.Field.LightPropagationTest do
  # 光学正交系统:纯光传播核的**形式不变量**验证(确定性/单调衰减/有界/源主导/遮挡)。
  # 既有针对性单测(精确数值),也有 seeded 随机属性测试(200+ 随机拓扑覆盖不变量)。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.LightPropagation

  # 直线拓扑:索引 0..n,邻居 = i±1(界内)。
  defp line_neighbors(n) do
    fn i -> Enum.filter([i - 1, i + 1], &(&1 >= 0 and &1 <= n)) end
  end

  # 3D 网格拓扑(边长 s,索引 x + y*s + z*s*s),六向邻居。
  defp grid_neighbors(s) do
    fn i ->
      x = rem(i, s)
      y = rem(div(i, s), s)
      z = div(i, s * s)

      [{x - 1, y, z}, {x + 1, y, z}, {x, y - 1, z}, {x, y + 1, z}, {x, y, z - 1}, {x, y, z + 1}]
      |> Enum.filter(fn {nx, ny, nz} ->
        nx in 0..(s - 1) and ny in 0..(s - 1) and nz in 0..(s - 1)
      end)
      |> Enum.map(fn {nx, ny, nz} -> nx + ny * s + nz * s * s end)
    end
  end

  describe "针对性数值(精确)" do
    test "源 cell 以其 emission 点亮" do
      light = LightPropagation.flood(%{0 => 100.0}, %{}, line_neighbors(5), threshold: 1.0)
      assert light[0] == 100.0
    end

    test "全透射直线:light[d] = emission × attenuation^d(单调衰减,阈下截断)" do
      # emission 100, attenuation 0.5, threshold 1.0 → 100,50,25,12.5,6.25,3.125,1.5625,(0.78<1 停)。
      light =
        LightPropagation.flood(%{0 => 100.0}, %{}, line_neighbors(10),
          attenuation: 0.5,
          threshold: 1.0
        )

      for d <- 0..6 do
        expected = 100.0 * :math.pow(0.5, d)
        assert_in_delta light[d], expected, 1.0e-6, "cell #{d} 应为 #{expected}"
      end

      # 严格单调递减。
      for d <- 0..5, do: assert(light[d] > light[d + 1])
      # 阈下不点亮(cell 7 = 0.78 < 1)。
      assert light[7] == nil
    end

    test "无源 → 全暗(空 map)" do
      assert LightPropagation.flood(%{}, %{}, line_neighbors(5), []) == %{}
    end

    test "全不透明 cell 遮挡其后(墙挡光)" do
      # 直线 0..4,cell 2 全不透明(opacity 1.0),源在 0 → 唯一到 3/4 的路经 2 被挡。
      light =
        LightPropagation.flood(%{0 => 100.0}, %{2 => 1.0}, line_neighbors(4),
          attenuation: 0.8,
          threshold: 1.0
        )

      assert light[0] == 100.0
      assert light[1] > 0.0
      # cell 2 透射 0 → 不点亮,且不向后传。
      assert light[2] == nil
      assert light[3] == nil
      assert light[4] == nil
    end

    test "半透 cell 衰减但不全挡(玻璃)" do
      # cell 2 opacity 0.5(透射 0.5)→ 光可部分穿透到 3。
      light =
        LightPropagation.flood(%{0 => 100.0}, %{2 => 0.5}, line_neighbors(4),
          attenuation: 1.0,
          threshold: 0.1
        )

      # 0:100, 1:100, 2:100*1.0*0.5=50, 3:50*1.0*1.0=50。
      assert_in_delta light[2], 50.0, 1.0e-6
      assert light[3] != nil and light[3] > 0.0
    end

    test "多源:每 cell 取最亮来路(max)" do
      # 两端各一源,中间 cell 取较亮的一侧。
      light =
        LightPropagation.flood(%{0 => 100.0, 4 => 100.0}, %{}, line_neighbors(4),
          attenuation: 0.5,
          threshold: 1.0
        )

      # 对称 → cell 2 从两侧各 100*0.5^2=25,max=25;两端 100。
      assert light[0] == 100.0
      assert light[4] == 100.0
      assert_in_delta light[2], 25.0, 1.0e-6
    end

    test "加源使每 cell 光强单调不减(源主导)" do
      one = LightPropagation.flood(%{0 => 100.0}, %{}, line_neighbors(8), attenuation: 0.6)

      two =
        LightPropagation.flood(%{0 => 100.0, 8 => 50.0}, %{}, line_neighbors(8), attenuation: 0.6)

      for {idx, l1} <- one do
        assert Map.get(two, idx, 0.0) >= l1 - 1.0e-9, "加源后 cell #{idx} 不应变暗"
      end
    end

    test "有界:所有光强 ∈ [threshold, max(emission)]" do
      light =
        LightPropagation.flood(%{0 => 80.0, 30 => 120.0}, %{}, grid_neighbors(4),
          attenuation: 0.7,
          threshold: 1.0
        )

      for {_idx, l} <- light do
        assert l >= 1.0 - 1.0e-9 and l <= 120.0 + 1.0e-9
      end
    end

    test "确定性:重复求值逐字节同;等源对称拓扑产生对称光场" do
      args = [%{5 => 100.0}, %{}, line_neighbors(10), [attenuation: 0.6, threshold: 1.0]]
      a = apply(LightPropagation, :flood, args)
      b = apply(LightPropagation, :flood, args)
      assert a == b

      # 源在直线中点 → 左右对称。
      for d <- 1..5 do
        assert_in_delta Map.get(a, 5 - d, 0.0), Map.get(a, 5 + d, 0.0), 1.0e-9
      end
    end

    test "max_frontier 熔断(不无限扩散)" do
      # 大直线 + 极小预算 → 只 settle 少量 cell。
      light =
        LightPropagation.flood(%{0 => 1.0e6}, %{}, line_neighbors(1000),
          attenuation: 0.999,
          threshold: 0.001,
          max_frontier: 5
        )

      # settled ≤ max_frontier;邻居入队不算 settle,故点亮 cell 数有界(宽松断言)。
      assert map_size(light) <= 12
    end
  end

  describe "形式属性(seeded 随机,200 例)" do
    test "不变量在随机拓扑下恒成立:有界 + 局部单调 + 确定性" do
      :rand.seed(:exsss, {101, 202, 303})

      for _ <- 1..200 do
        s = Enum.random(2..5)
        cell_count = s * s * s
        neighbors_fn = grid_neighbors(s)
        attenuation = 0.4 + :rand.uniform() * 0.5

        # 随机源(1..3 个,emission 10..200)。
        sources =
          for _ <- 1..Enum.random(1..3), into: %{} do
            {Enum.random(0..(cell_count - 1)), 10.0 + :rand.uniform() * 190.0}
          end

        # 随机 opacity(约 1/4 cell 部分/全不透明)。
        opacity =
          for i <- 0..(cell_count - 1), :rand.uniform() < 0.25, into: %{} do
            {i, :rand.uniform()}
          end

        threshold = 1.0
        opts = [attenuation: attenuation, threshold: threshold, max_frontier: 100_000]
        light = LightPropagation.flood(sources, opacity, neighbors_fn, opts)
        max_emission = sources |> Map.values() |> Enum.max()

        for {idx, l} <- light do
          # 有界。
          assert l >= threshold - 1.0e-9
          assert l <= max_emission + 1.0e-6

          # 局部单调:非源 lit cell 严格暗于其最亮 lit 邻居(att<1 → 衰减)。
          unless Map.has_key?(sources, idx) do
            max_nb =
              idx
              |> neighbors_fn.()
              |> Enum.map(&Map.get(light, &1, 0.0))
              |> Enum.max(fn -> 0.0 end)

            assert max_nb > l - 1.0e-9, "非源 cell #{idx}(光 #{l})应有更亮邻居"
          end
        end

        # 确定性:同输入重算相等。
        assert light == LightPropagation.flood(sources, opacity, neighbors_fn, opts)
      end
    end
  end
end
