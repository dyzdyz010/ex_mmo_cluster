defmodule SceneServer.Movement.PathTest do
  @moduledoc "全局系统功能的算法层测试：冻结样例的期望路径是手算的，不由被测算法生成。"
  use ExUnit.Case, async: true
  alias SceneServer.Movement.Path, as: Walk

  @suite Path.expand("../../fixtures/movement_path_cases.json", __DIR__) |> File.read!() |> Jason.decode!()

  defp grid(%{"rows" => rows} = c) do
    columns =
      for {row, z} <- Enum.with_index(rows), {char, x} <- Enum.with_index(String.to_charlist(row)), y <- 0..11, into: %{} do
        solid = if char in ?0..?9, do: char - ?0, else: if(char == ?~, do: 1, else: 0)

        cond do
          y < solid -> {{x, y, z}, :solid}
          char == ?~ and y == 1 -> {{x, y, z}, :liquid}
          true -> {{x, y, z}, :open}
        end
      end

    for([x, y, z] <- c["extra_solid"] || [], into: columns, do: {{x, y, z}, :solid})
    |> Map.reject(fn {_, kind} -> kind == :liquid end)
  end

  for c <- @suite["cases"] do
    test "frozen case: #{c["name"]}" do
      c = unquote(Macro.escape(c))
      [sx, sy, sz] = c["start"]
      [gx, gz] = c["goal"]
      expected = if c["path"], do: {:ok, Enum.map(c["path"], &List.to_tuple/1)}, else: :no_path
      assert expected == Walk.find(grid(c), {sx, sy, sz}, {gx, gz}, c["goal_y"], @suite["step"], @suite["height"])
    end
  end

  test "the suite is not empty and covers both outcomes" do
    assert length(@suite["cases"]) >= 16
    assert Enum.any?(@suite["cases"], &(&1["path"] == nil)) and Enum.any?(@suite["cases"], &is_list(&1["path"]))
  end

  # smooth/7 的期望点列是手算的：半径 0.35 的胶囊只有在扫过的每一列都是同层站立格时才能抄近路。
  defp flat(xs, zs, walls \\ []) do
    for x <- xs, z <- zs, y <- 0..4, into: %{} do
      {{x, y, z}, if(y == 0 or ({x, z} in walls and y <= 2), do: :solid, else: :open)}
    end
  end

  test "smooth: open flat ground collapses to the exact target, even along a cell boundary" do
    grid = flat(0..9, 0..3)
    {:ok, cells} = Walk.find(grid, {0, 1, 2}, {8, 2}, nil, 1, 2)
    # 起点与目标都在 z = 2.0 的格边界上：胶囊压着第 1、2 两行，两行都是站立格 → 一条直线。
    assert [{8.0, 2.0}] == Walk.smooth(grid, {0.5, 2.0}, 1, cells, {8.0, 2.0}, 0.35, 2)
  end

  test "smooth: in a one-cell corridor only the turns remain, through cell centres" do
    grid = flat(0..2, 0..2, [{1, 0}, {1, 1}])
    {:ok, cells} = Walk.find(grid, {0, 1, 0}, {2, 0}, nil, 1, 2)
    assert [{0.5, 2.5}, {2.5, 2.5}, {2.5, 0.4}] == Walk.smooth(grid, {0.5, 0.5}, 1, cells, {2.5, 0.4}, 0.35, 2)
  end

  test "smooth: a level change is never skipped; each stair cell centre stays" do
    grid = for x <- 0..3, y <- 0..7, into: %{}, do: {{x, y, 0}, if(y <= x, do: :solid, else: :open)}
    {:ok, cells} = Walk.find(grid, {0, 1, 0}, {3, 0}, nil, 1, 2)
    assert [{1.5, 0.5}, {2.5, 0.5}, {3.6, 0.5}] == Walk.smooth(grid, {0.5, 0.5}, 1, cells, {3.6, 0.5}, 0.35, 2)
  end

  test "smooth: already in the goal cell → just the target" do
    assert [{0.7, 0.6}] == Walk.smooth(flat(0..1, 0..1), {0.5, 0.5}, 1, [], {0.7, 0.6}, 0.35, 2)
  end

  test "a taller body needs more headroom: the same corridor passes at height 2 and not at height 3" do
    grid = for(x <- 0..2, y <- 0..4, into: %{}, do: {{x, y, 0}, if(y == 0 or y == 3, do: :solid, else: :open)})
    assert {:ok, [{1, 1, 0}, {2, 1, 0}]} == Walk.find(grid, {0, 1, 0}, {2, 0}, nil, 1, 2)
    assert :no_path == Walk.find(grid, {0, 1, 0}, {2, 0}, nil, 1, 3)
  end

  test "coordinate query uses the same walking rules without materializing an air map" do
    query = fn
      {x, 0, 0} when x in 0..3 -> :solid
      {x, y, 0} when x in 0..3 and y in 1..3 -> :open
      _ -> :unknown
    end

    assert {:ok, [{1, 1, 0}, {2, 1, 0}, {3, 1, 0}]} == Walk.find(query, {0, 1, 0}, {3, 0}, 1, 0, 2)
    assert :no_path == Walk.find(query, {0, 1, 0}, {4, 0}, 1, 0, 2)
  end

  test "an explicit search budget returns exhaustion rather than claiming no route" do
    query = fn
      {x, 0, 0} when x in 0..3 -> :solid
      {x, y, 0} when x in 0..3 and y in 1..3 -> :open
      _ -> :unknown
    end

    assert {:error, :search_limit} == Walk.find(query, {0, 1, 0}, {3, 0}, 1, 0, 2, max_nodes: 1)
  end
end
