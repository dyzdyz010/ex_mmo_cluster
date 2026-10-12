defmodule NpcServer.NpcSurveyTest do
  @moduledoc """
  只测试：地表勘察 survey 与列扫描（`NpcServer.Perception` 的 `walk_kind/1`、`floors/2`、`surfaces/2`、`prepare/3`、
  `project/3`）、travel 选段终点站立层（`Skills.Travel.stand_y/2`）。手写小世界，期望逐项手算（放置阶段决策稿 §7）。
  经真实 Body / World 的 survey 见 npc_expand_test 的台地用例与 npc_body_world_test 的接缝用例。
  """
  use ExUnit.Case, async: true
  alias NpcServer.{Abilities, Perception}
  alias NpcServer.Skills.Travel

  @stone 11
  # VoximMaterials（材质契约）：32 = 矮草（花草，不挡路），21 = 水（液体）。
  @grass 32
  @water 21

  # 一列 y 60..68 的格行（自下而上）：fun.(y) 给材料，或 {材料, 放置者}，或 :refined（细化格）。
  defp column({x, z}, fun) do
    for y <- 60..68 do
      row =
        case fun.(y) do
          {material, by} -> %{material: material, refined: false, placed_by: by}
          :refined -> %{material: 0, refined: true, placed_by: nil}
          material -> %{material: material, refined: false, placed_by: nil}
        end

      Map.merge(%{cell: [x, y, z], slots: []}, row)
    end
  end

  # 平地一列：y ≤ 63 石料，其上空气；edits 按 y 覆盖。
  defp ground(at, edits \\ %{}),
    do: column(at, fn y -> Map.get_lazy(edits, y, fn -> if y <= 63, do: @stone, else: 0 end) end)

  defp surface(column, floors, y, material, placed_by \\ nil, refined \\ false),
    do: %{
      column: column,
      floors: floors,
      y: y,
      material: material,
      placed_by: placed_by,
      refined: refined
    }

  test "walk_kind: blocking terrain is a floor, air and flora are passage, liquid and refined cells are neither" do
    assert :solid == Perception.walk_kind(%{material: @stone, refined: false})
    assert :open == Perception.walk_kind(%{material: 0, refined: false})
    assert :open == Perception.walk_kind(%{material: @grass, refined: false})
    assert nil == Perception.walk_kind(%{material: @water, refined: false})

    # 细化格（含 micro 内容，宏格材料常为 0）：碰撞按 micro，宏格网格整格挡住，也不能站在上面。
    assert nil == Perception.walk_kind(%{material: 0, refined: true})
    assert nil == Perception.walk_kind(%{material: @stone, refined: true})
  end

  test "surfaces: the highest floor with clearance per column, by hand on a small world (flora, liquid, refined, overhang)" do
    rows =
      Enum.concat([
        # (0,0) 平地：地面 63，其上 64、65 空气。
        ground({0, 0}),
        # (1,0) 地面上长草：草不挡路，地面仍是 63。
        ground({1, 0}, %{64 => @grass}),
        # (2,0) 地面上一层水（63 是水）：62 上面是液体、63 是液体 → 没有可站的地面。
        ground({2, 0}, %{63 => @water}),
        # (3,0) 地面上立着细化格（64）：63 的净空不够 → 没有可站的地面；这一列有细化格。
        ground({3, 0}, %{64 => :refined}),
        # (4,0) 悬空一格在 66、下面留两格：63 与 66 都站得下，地表取高的 66。
        ground({4, 0}, %{66 => @stone}),
        # (5,0) 悬空一格在 65、离地只有一格：63 净空不够，65 站得下。
        ground({5, 0}, %{65 => @stone}),
        # (6,0) 地面上有人放了一格（64）：地表是这一格，带放置者。
        ground({6, 0}, %{64 => {@stone, 7}}),
        # (7,0) 实心到 67：67 的净空伸出扫描范围（68 之上未知）→ 不算地面；66 以下都被压着。
        column({7, 0}, fn y -> if y <= 67, do: @stone, else: 0 end),
        # (8,0) 整列空气：范围内没有地面。
        column({8, 0}, fn _ -> 0 end)
      ])

    assert [
             surface([0, 0], [63], 63, @stone),
             surface([1, 0], [63], 63, @stone),
             surface([2, 0], [], nil, nil),
             surface([3, 0], [], nil, nil, nil, true),
             surface([4, 0], [63, 66], 66, @stone),
             surface([5, 0], [65], 65, @stone),
             surface([6, 0], [64], 64, @stone, 7),
             surface([7, 0], [], nil, nil),
             surface([8, 0], [], nil, nil)
           ] == Perception.surfaces(Enum.shuffle(rows), 2)

    # 身高 3 格：(4,0) 的 63 上面只有 64、65 两格空；66 的净空要到 69，伸出扫描范围（68 之上未知）→ 都不算。
    assert [63, 66] == Perception.floors(ground({4, 0}, %{66 => @stone}), 2)
    assert [] == Perception.floors(ground({4, 0}, %{66 => @stone}), 3)

    # 同一列下移悬空格（65 之下留 64 一格）：身高 1 格时 63 与 65 都站得下。
    assert [63, 65] == Perception.floors(ground({4, 0}, %{65 => @stone}), 1)
  end

  test "prepare: at most 32 × 32 columns, each edge within reach, vertical window centred on the body like look" do
    at = {10.5, 64.9, 10.5}

    # 竖直：ceil(64.9 − 32) = 33 .. floor(64.9 + 32) = 96；x、z：10.5 ± 32 = −21.5 .. 42.5。
    assert {:survey, %{columns: {{-21, 0}, {10, 31}}, y: {33, 96}, clearance: 2}} ==
             Perception.prepare(at, %{verb: :survey, min: {-21, 0}, max: {10, 31}}, 2)

    # 33 列、超出距离、倒置的区间：不访问 World。
    assert nil == Perception.prepare(at, %{verb: :survey, min: {0, 0}, max: {32, 0}}, 2)
    assert nil == Perception.prepare(at, %{verb: :survey, min: {-22, 0}, max: {0, 0}}, 2)
    assert nil == Perception.prepare(at, %{verb: :survey, min: {5, 0}, max: {4, 0}}, 2)
  end

  test "project: height rows, placed and refined stay available across successive surveys" do
    columns =
      Perception.surfaces(
        ground({0, 0}) ++
          ground({1, 0}, %{64 => {@stone, 7}}) ++
          ground({0, 1}, %{64 => :refined}) ++ ground({1, 1}, %{63 => @water}),
        2
      )

    survey = fn id ->
      %{
        id: id,
        verb: :survey,
        status: :done,
        reason: nil,
        data: %{
          seq: [5, 6],
          bounds_columns_inclusive: [[0, 0], [1, 1]],
          scanned_y: [60, 68],
          clearance: 2,
          columns: columns,
          outside: :unknown
        }
      }
    end

    assert [
             %{
               data: %{
                 seq: [5, 6],
                 bounds_columns_inclusive: [[0, 0], [1, 1]],
                 scanned_y: [60, 68],
                 outside: :unknown,
                 row_fields: [:ground_y, :material, :move_to_y],
                 rows: [[[63, @stone, 64], [64, @stone, 65]], [nil, nil]],
                 placed: [[1, 0, 7]],
                 refined: [[0, 1]]
               }
             }
           ] = Perception.project(survey.(1), [], nil)

    history =
      Enum.reduce(1..4, [], fn id, history -> Perception.project(survey.(id), history, nil) end)

    assert [4, 3, 2, 1] == Enum.map(history, & &1.id)
    assert [true, true, true, true] == Enum.map(history, &(&1.data != nil))
  end

  test "stand_y: the floor nearest the feet becomes the standing cell; a tie takes the lower; no floor is nil" do
    # 地面 63 → 站立格 64（离脚 64 为 0）、地面 71 → 72（离 8）。
    assert 64 == Travel.stand_y([63, 71], 64)
    # 脚在 70：64 离 6、72 离 2。
    assert 72 == Travel.stand_y([63, 71], 70)
    # 脚在 66：64、68 都离 2 → 取低的。
    assert 64 == Travel.stand_y([63, 67], 66)
    assert nil == Travel.stand_y([], 64)
  end

  test "the survey tool is strict and every argument is required" do
    tool = Enum.find(Abilities.tools(%{groups: [:sense]}), &(&1.name == "survey"))

    assert %{
             strict: true,
             parameters: %{
               additionalProperties: false,
               required: required,
               properties: %{
                 x0: %{type: "integer"},
                 z0: %{type: "integer"},
                 x1: %{type: "integer"},
                 z1: %{type: "integer"}
               }
             }
           } = tool

    assert Enum.sort(required) == ~w(x0 x1 z0 z1)
    # 数字由源常量插值（每边列数、距离）。
    assert tool.description =~ "每边最多 #{Perception.survey_columns()} 列"
    assert tool.description =~ "不超过 #{Perception.reach()} 米"
  end
end
