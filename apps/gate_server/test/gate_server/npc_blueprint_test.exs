defmodule GateServer.NpcBlueprintTest do
  @moduledoc "全局系统功能的算法层测试：期望值都是手数的小例子。"
  use ExUnit.Case, async: true
  alias GateServer.Npc.Blueprint

  # 3×3 占地、两格高的空心墙（y 0..1），再挖一个一格宽、两格高的门洞。
  @hut [
    %{"op" => "fill", "min" => [0, 0, 0], "max" => [2, 1, 2], "material" => 11},
    %{"op" => "clear", "min" => [1, 0, 1], "max" => [1, 1, 1]},
    %{"op" => "clear", "min" => [1, 0, 0], "max" => [1, 1, 0]}
  ]

  test "ops apply in order: fill, then clear the inside and the door" do
    {:ok, cells} = Blueprint.cells(@hut)
    # 3×3×2 = 18，屋内 2，门洞 2 → 14。
    assert 14 == map_size(cells)
    refute is_map_key(cells, {1, 0, 1}) or is_map_key(cells, {1, 1, 0})
    assert Enum.all?(Map.values(cells), &(&1 == 11))
    assert {{0, 0, 0}, {2, 1, 2}} == Blueprint.bounds(cells)
  end

  test "hollow keeps the six faces only; a later fill overrides the material" do
    {:ok, cells} =
      Blueprint.cells([
        %{"op" => "fill", "min" => [0, 0, 0], "max" => [3, 3, 3], "material" => 11, "hollow" => true},
        %{"op" => "fill", "min" => [0, 3, 0], "max" => [3, 3, 3], "material" => 19}
      ])

    # 4³ = 64，内部 2³ = 8 → 壳 56；顶面 16 格换成木材。
    assert 56 == map_size(cells)
    assert 16 == Enum.count(cells, fn {_, m} -> m == 19 end)
    assert 11 == cells[{0, 0, 0}] and 19 == cells[{0, 3, 0}]
  end

  test "malformed blueprints are rejected as a whole" do
    assert :error == Blueprint.cells([])
    assert :error == Blueprint.cells("fill everything")
    assert :error == Blueprint.cells([%{"op" => "fill", "min" => [2, 0, 0], "max" => [0, 0, 0], "material" => 11}])
    assert :error == Blueprint.cells([%{"op" => "fill", "min" => [0, 0, 0], "max" => [0, 0, 0], "material" => 0}])
    assert :error == Blueprint.cells([%{"op" => "paint", "min" => [0, 0, 0], "max" => [0, 0, 0]}])
    assert :error == Blueprint.cells([%{"op" => "fill", "min" => [0, 0, 0], "max" => [99, 99, 99], "material" => 11}])
    # 一条坏操作作废整份，不留下前面的半截。
    assert :error == Blueprint.cells(@hut ++ [%{"op" => "fill", "min" => [0.5, 0, 0], "max" => [1, 0, 0], "material" => 11}])
  end

  test "remaining is computed from the world: bottom layer first, foreign material is reported, never scheduled" do
    {:ok, cells} = Blueprint.cells(@hut)
    air = for x <- 0..2, y <- 0..1, z <- 0..2, into: %{}, do: {{x, y, z}, 0}

    assert %{todo: todo, wrong: []} = Blueprint.remaining(cells, air)
    assert 14 == length(todo)
    assert [0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1] == Enum.map(todo, fn {{_, y, _}, _} -> y end)
    assert {{0, 0, 0}, 11} == hd(todo)

    # 世界里已经有两格砌好了、一格被金块（6）占着：todo 少三格，金块那格进 wrong。
    world = Map.merge(air, %{{0, 0, 0} => 11, {0, 1, 0} => 11, {2, 0, 2} => 6})
    assert %{todo: todo, wrong: [{{2, 0, 2}, 6, 11}]} = Blueprint.remaining(cells, world)
    assert 11 == length(todo)
    refute {{0, 0, 0}, 11} in todo

    done = Map.merge(air, cells)
    assert %{todo: [], wrong: []} == Blueprint.remaining(cells, done)
  end

  test "stands are outside the bounding box, nearest side first" do
    {:ok, cells} = Blueprint.cells(@hut)
    # 盒子 x,z ∈ [0,3)：四个站位分别在 z = −1.5 / 4.5、x = −1.5 / 4.5，另一轴在中线 1.5。
    # 格 (1,0,0) 的格心 (1.5, 0.5)：到南侧站位的距离² = 4，到北侧 = 16，东西两侧都是 10（并列，不断言先后）。
    stands = Blueprint.stands(cells, {1, 0, 0})
    assert {{1.5, -1.5}, {1.5, 4.5}} == {hd(stands), List.last(stands)}
    assert [{-1.5, 1.5}, {1.5, -1.5}, {1.5, 4.5}, {4.5, 1.5}] == Enum.sort(stands)
    # 格 (0,0,1) 的格心 (0.5, 1.5)：西侧最近（4），东侧最远（16）。
    assert {{-1.5, 1.5}, {4.5, 1.5}} == {hd(Blueprint.stands(cells, {0, 0, 1})), List.last(Blueprint.stands(cells, {0, 0, 1}))}
    assert {1.5, 4.5} == hd(Blueprint.stands(cells, {1, 1, 2}))
  end
end
