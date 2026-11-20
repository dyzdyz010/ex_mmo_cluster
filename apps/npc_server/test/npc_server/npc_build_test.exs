Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcBuildTest do
  @moduledoc """
  只测试：建造技能 `NpcServer.Skills.Build` 自己走到射程内再放置（真实 World / Scene / Player / Body，`NpcServer.NpcWorld` 夹具）。

  契约：`build` 先照原样发一次 `prefab_place`，够不够得着只由权威裁决；被拒 `out_of_reach` 时按这份定义在这个锚点与朝向的
  足迹（`World.prefab_cells/4`）求站位（`Blueprint.stands/2`），由近到远走过去再放；已在射程内时不走路；一个站位走不到就换下一个；
  站位都走不到时以 `unreachable` 结束；站位都走到了仍够不着时逐个试完、以 `out_of_reach` 结束。不覆盖：只有附件的定义（没有定义格，
  直接 `out_of_reach`）、长途分段的寻路细节（`Skills.Travel` 自己的测试）。

  定义是两格高的石柱（材料单 2 × 512 = 1024），作者目录载入；余额只经 `World.material_supply/4` 一次供给并记账，世界格只经 World 的
  公共只读入口观察。锚点格 (24, 64, 10)：站位（足迹四条边中点外 1.5 米）是 (22.5, 10.5)、(24.5, 8.5)、(24.5, 12.5)、(26.5, 10.5)；
  从出生点 (4, 10) 看由近到远依次是 (22.5, 10.5)（距离² 324）、(24.5, 8.5)、(24.5, 12.5)（同为 404，按 stands 的列出次序）、
  (26.5, 10.5)（484）。镐的射程 6 米（夹具目录）。地形障碍只经作者入口 `World.apply_edits/2` 写入。
  """
  use ExUnit.Case, async: false
  alias NpcServer.{Actions, Body}
  alias NpcServer.NpcWorld
  alias VoxelRegion.{Prefab, World}

  @stone 11
  @npc 9101
  @pillar Prefab.encode(%{
            cells: [],
            macro_cells: [{{0, 0, 0}, @stone}, {{0, 1, 0}, @stone}],
            children: [],
            attachments: []
          })
  @cells [{24, 64, 10}, {24, 65, 10}]
  @args %{"anchor_micro" => [192, 512, 80], "orientation" => 0}

  defp start(spawn) do
    fixture = NpcWorld.start(prefab_access: true, prefabs: [@pillar])
    {:ok, _} = World.material_supply(fixture.world, @npc, "build-supply", %{@stone => 1024})
    profile = %{steps: [], tools: %{1 => "镐"}, skills: %{build: %{}}, memory: NpcWorld.Memory}
    %{body: body} = NpcWorld.body(fixture, {NpcServer.Brain.Routine, profile}, spawn: spawn)
    {fixture, body}
  end

  # 落地站稳（胶囊中心 = 地面 64 + 半高 0.9）；出生只沿 y 找落脚点，x / z 就是出生点。
  defp settled(body) do
    NpcWorld.await(fn ->
      with {_, y, _} = position <- Body.observe(body).position,
           true <- abs(y - 64.9) < 0.05,
           do: position
    end)
  end

  defp build(body, id, args \\ @args) do
    args = Map.put(args, "definition", NpcWorld.hex(@pillar))
    Body.command(body, %{id: id, verb: :skill, skill: :build, args: args})

    NpcWorld.await(
      fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == id)) end,
      120_000
    )
  end

  @tag timeout: 300_000
  test "out of reach: build walks to the nearest stand of the footprint and places there" do
    # 出生 (4.0, 10.0)：眼点 (4, 65.5, 10) 到锚点格心约 20.5 米，远在 6 米射程外。
    {fixture, body} = start({4.0, 66.0, 10.0})
    assert {4.0, _, 10.0} = settled(body)

    assert %{verb: :build, status: :done, data: %{seq: _}} = build(body, :far)

    # 从 (4.5, 10.5) 看最近的站位是西侧 (22.5, 10.5)（距离² 324，其余 ≥ 404）：在那里放下。
    {x, _, z} = Body.observe(body).position
    assert :math.sqrt((x - 22.5) ** 2 + (z - 10.5) ** 2) <= Actions.tolerance()
    assert 0 == NpcWorld.balance(fixture.world, @npc)

    assert Enum.all?(
             Map.values(NpcWorld.cells(fixture.world, @cells)),
             &match?(%{material: @stone, placed_by: @npc}, &1)
           )
  end

  @tag timeout: 300_000
  test "already in reach: build places from where it stands, without moving" do
    # 出生 (21.0, 9.0)：眼点到锚点格心 √(3.5² + 1² + 1.5²) ≈ 3.94 米，在射程内；离最近的站位 (22.5, 10.5) 约 2.1 米，
    # 一旦走过去 x / z 就会变。
    {fixture, body} = start({21.0, 66.0, 9.0})
    assert {21.0, _, 9.0} = settled(body)

    assert %{verb: :build, status: :done} = build(body, :near)
    assert {21.0, _, 9.0} = Body.observe(body).position
    assert 0 == NpcWorld.balance(fixture.world, @npc)

    assert Enum.all?(
             Map.values(NpcWorld.cells(fixture.world, @cells)),
             &match?(%{material: @stone, placed_by: @npc}, &1)
           )
  end

  @tag timeout: 300_000
  test "the nearest stand is unreachable: build falls back to the next stand and places there" do
    {fixture, body} = start({4.0, 66.0, 10.0})
    # 只在最近的站位列 (22, 10) 立一根三格高的石柱：站立层在柱顶 y = 67，离地 3 格，上不去。
    {:ok, _} =
      World.apply_edits(fixture.world, for(y <- 64..66, do: {{22, y, 10}, @stone}))

    assert {4.0, _, 10.0} = settled(body)

    assert %{verb: :build, status: :done} = build(body, :fallback)

    # 次近的是南侧 (24.5, 8.5)：眼点到锚点格心 √(0 + 1 + 4) ≈ 2.24 米，在射程内，就在那里放下。
    {x, _, z} = Body.observe(body).position
    assert :math.sqrt((x - 24.5) ** 2 + (z - 8.5) ** 2) <= Actions.tolerance()
    assert 0 == NpcWorld.balance(fixture.world, @npc)

    assert Enum.all?(
             Map.values(NpcWorld.cells(fixture.world, @cells)),
             &match?(%{material: @stone, placed_by: @npc}, &1)
           )
  end

  @tag timeout: 300_000
  test "every stand reached but still out of reach: build tries them all and ends with out_of_reach" do
    {fixture, body} = start({4.0, 66.0, 10.0})
    # 锚点格 (24, 64, 10) 那一列砌到 y = 70，石柱定义放在柱顶 (24, 71, 10)。四个站位都在平地上走得到；站立时眼高 65.5，
    # 到最低那格心的距离 = √(2² + 6² + 0²) = √40 ≈ 6.32 米（四个站位对称），超过 6 米射程。
    {:ok, _} =
      World.apply_edits(fixture.world, for(y <- 64..70, do: {{24, y, 10}, @stone}))

    assert {4.0, _, 10.0} = settled(body)

    high = %{@args | "anchor_micro" => [192, 568, 80]}
    assert %{verb: :build, status: :rejected, reason: :out_of_reach} = build(body, :high, high)

    # 四个站位都试过：停在最后一个 (26.5, 10.5)，不是第一个就放弃。
    {x, _, z} = Body.observe(body).position
    assert :math.sqrt((x - 26.5) ** 2 + (z - 10.5) ** 2) <= Actions.tolerance()
    assert 1024 == NpcWorld.balance(fixture.world, @npc)

    assert Enum.all?(
             Map.values(NpcWorld.cells(fixture.world, [{24, 71, 10}, {24, 72, 10}])),
             &(&1.material == 0)
           )
  end

  @tag timeout: 300_000
  test "every stand unreachable: build ends with unreachable and places nothing" do
    {fixture, body} = start({4.0, 66.0, 10.0})
    # 四个站位列各立一根三格高的石柱（作者写入）：站立层在柱顶 y = 67，离地 3 格，上不去。
    pillars = for {x, z} <- [{22, 10}, {24, 8}, {24, 12}, {26, 10}], y <- 64..66, do: {x, y, z}
    {:ok, _} = World.apply_edits(fixture.world, Enum.map(pillars, &{&1, @stone}))
    assert {4.0, _, 10.0} = settled(body)

    assert %{verb: :build, status: :rejected, reason: :unreachable} = build(body, :walled)
    assert 1024 == NpcWorld.balance(fixture.world, @npc)
    assert Enum.all?(Map.values(NpcWorld.cells(fixture.world, @cells)), &(&1.material == 0))
  end
end
