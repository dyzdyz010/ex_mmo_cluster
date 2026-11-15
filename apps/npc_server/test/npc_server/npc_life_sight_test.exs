defmodule NpcServer.NpcLifeSightTest do
  @moduledoc """
  只测试：“看到的”（`NpcServer.Life.Sight`）的纯函数——相遇与附近建造 / 拆除的每条门槛、每种句型、频率上限、观察中断、
  游戏钟换算、多人同时在场、分组与距离 / 时刻筛选、已写成“动我的建筑”的事件不重复成所见。受控时刻，无 World、数据库、网络。

  输入照产品形状：观察帧 `%{self: %{entity_id:, position:}, entities: [%{entity_id:, name:, position:}]}`（Body 观察的子集，
  每 50 毫秒一帧）；World 事件照 `VoxelRegion.World.Interactions.capture/5` 加提交处补的 `instance_removed`，
  涉及建筑时 Life 的读取 worker 补的 `building`。自己是 cid 7，站在原点。
  """
  use ExUnit.Case, async: true
  alias NpcServer.Life.{Sight, State}

  @frame_ms 50

  # —— 时长 ——

  test "durations are written on the game clock: rounded minutes below an hour, rounded hours above" do
    # 现实 150 秒 = 游戏 1 小时（×24）：现实 1 秒 = 游戏 0.4 分钟；游戏分钟 = ⌊(毫秒 × 24 + 30000) ÷ 60000⌋，手算。
    assert Sight.duration(0) == "about 1 minute"
    # 1 秒 = 0.4 分钟，四舍五入到 0，最小写 1。
    assert Sight.duration(1000) == "about 1 minute"
    # 2 秒 = 0.8 分钟 → 1。
    assert Sight.duration(2000) == "about 1 minute"
    # 5 秒 = 2 分钟；10 秒 = 4 分钟；60 秒 = 24 分钟。
    assert Sight.duration(5000) == "about 2 minutes"
    assert Sight.duration(10_000) == "about 4 minutes"
    assert Sight.duration(60_000) == "about 24 minutes"
    # 148 秒 = 59.2 分钟 → 59；148.75 秒 = 59.5 分钟 → 60 分钟 → 1 小时。
    assert Sight.duration(148_000) == "about 59 minutes"
    assert Sight.duration(148_750) == "about 1 hour"
    assert Sight.duration(150_000) == "about 1 hour"

    # 300 秒 = 120 分钟 = 2 小时；375 秒 = 150 分钟 → 小时数四舍五入 2.5 → 3。
    assert Sight.duration(300_000) == "about 2 hours"
    assert Sight.duration(375_000) == "about 3 hours"
  end

  # —— A 相遇 ——

  test "someone who came within 6 m is written once, 10 s after they left sight, with the closest distance rounded up" do
    {_ledger, entries, []} =
      start()
      |> feed(0, 2000, [person(21, "Brann", 2.5)])
      |> feed(2050, 11_950, [])
      |> tap(fn {_, entries, _} -> assert entries == [] end)
      |> feed(12_000, 13_000, [])

    assert [
             %{
               "id" => "sight:encounter:21:0",
               "at_ms" => 2000,
               "text" =>
                 "Brann (actor 21) was around for about 1 minute; came within 3 m of me, then left.",
               "tags" => ["kind:sight", "actor:21"]
             }
           ] == entries
  end

  test "someone who stayed beyond 6 m is written only after 50 s in sight, with the distance rounded down" do
    {_ledger, entries, []} =
      start()
      |> feed(0, 49_000, [person(22, "Arlo", 20.4), person(23, "Cora", 20.4)])
      |> feed(49_050, 60_000, [person(23, "Cora", 20.4)])
      |> feed(60_050, 75_000, [])

    assert [
             %{
               "id" => "sight:encounter:23:0",
               "at_ms" => 60_000,
               "text" =>
                 "Cora (actor 23) was around for about 24 minutes; stayed at least 20 m away, then left.",
               "tags" => ["kind:sight", "actor:23"]
             }
           ] == entries
  end

  test "a gap under 10 s is the same encounter (the gap does not count as time in sight); 10 s or more starts a new one" do
    # 15 米外：30 秒 + 22 秒在视野里 = 52 秒，够 50 秒；中间离开的 8 秒不算。
    {_ledger, entries, []} =
      start()
      |> feed(0, 30_000, [person(21, "Brann", 15.0)])
      |> feed(30_050, 37_950, [])
      |> feed(38_000, 60_000, [person(21, "Brann", 15.0)])
      |> feed(60_050, 71_000, [])

    assert [%{"id" => "sight:encounter:21:0", "at_ms" => 60_000, "text" => text}] = entries

    assert text ==
             "Brann (actor 21) was around for about 24 minutes; stayed at least 15 m away, then left."

    # 离开满 10 秒后再来：两次相遇，各一条。
    {_ledger, entries, []} =
      start()
      |> feed(0, 1000, [person(21, "Brann", 3.0)])
      |> feed(1050, 12_950, [])
      |> feed(13_000, 14_000, [person(21, "Brann", 4.2)])
      |> feed(14_050, 25_000, [])

    assert [
             %{"id" => "sight:encounter:21:0", "text" => first},
             %{"id" => "sight:encounter:21:13000", "text" => second}
           ] = entries

    assert first =~ "came within 3 m of me, then left."
    assert second =~ "came within 5 m of me, then left."
  end

  test "someone still around after 5 minutes gets one still-here entry, then one more when they leave" do
    {_ledger, entries, []} =
      start()
      |> feed(0, 400_000, [person(21, "Brann", 3.0), person(22, "Arlo", 12.7)])
      |> feed(400_050, 411_000, [])

    assert [
             %{
               "id" => "sight:encounter:21:0:still",
               "at_ms" => 300_000,
               "text" =>
                 "Brann (actor 21) has been around for about 2 hours and is still here; has come within 3 m of me.",
               "tags" => ["kind:sight", "actor:21"]
             },
             %{
               "id" => "sight:encounter:22:0:still",
               "at_ms" => 300_000,
               "text" =>
                 "Arlo (actor 22) has been around for about 2 hours and is still here; has stayed at least 12 m away.",
               "tags" => ["kind:sight", "actor:22"]
             },
             %{
               "id" => "sight:encounter:21:0",
               "at_ms" => 400_000,
               "text" =>
                 "Brann (actor 21) was around for about 3 hours; came within 3 m of me, then left."
             },
             %{
               "id" => "sight:encounter:22:0",
               "at_ms" => 400_000,
               "text" =>
                 "Arlo (actor 22) was around for about 3 hours; stayed at least 12 m away, then left."
             }
           ] = entries
  end

  test "observations stopping for over 5 s end encounters at the last sighting without saying they left" do
    # 由每秒的到点检查发现：最后一帧 3000，8100 时已断了 5.1 秒。
    {ledger, [], []} = feed(start(), 0, 3000, [person(21, "Brann", 2.0)])
    assert {ledger, [], []} = Sight.due(ledger, nil, 7_900)
    {ledger, [lost], []} = Sight.due(ledger, nil, 8_100)

    assert lost == %{
             "id" => "sight:encounter:21:0",
             "at_ms" => 3000,
             "text" => "Brann (actor 21) was around for about 1 minute; came within 2 m of me.",
             "tags" => ["kind:sight", "actor:21"]
           }

    # 之后再出现算新的一次，那一次不再重复写上一次。
    {ledger, [], []} = Sight.due(ledger, nil, 9_100)
    {ledger, [], []} = Sight.see(ledger, seen([person(21, "Brann", 2.0)]), 9_200)
    assert ledger.encounters[21].first_ms == 9_200

    # 由下一帧观察发现（中间没有到点检查）：同样不说离开。
    {ledger, [], []} = feed(start(), 0, 3000, [person(21, "Brann", 30.0)])
    {_ledger, [], []} = Sight.see(ledger, seen([person(21, "Brann", 30.0)]), 9_000)

    {ledger, [], []} = feed(start(), 0, 1000, [person(21, "Brann", 5.0)])
    {_ledger, [lost], []} = Sight.see(ledger, seen([]), 7_000)

    assert lost["text"] ==
             "Brann (actor 21) was around for about 1 minute; came within 5 m of me."
  end

  test "several people at once are tracked independently; unnamed people use the shared fallback; entries come out in cid order" do
    {_ledger, entries, []} =
      start()
      |> feed(0, 3000, [
        person(21, "Brann", 4.0),
        person(22, "Arlo", 25.0),
        person(23, "", 5.5)
      ])
      |> feed(3050, 14_000, [])

    assert [
             %{
               "id" => "sight:encounter:21:0",
               "text" => brann,
               "tags" => ["kind:sight", "actor:21"]
             },
             %{
               "id" => "sight:encounter:23:0",
               "text" => unnamed,
               "tags" => ["kind:sight", "actor:23"]
             }
           ] = entries

    assert brann ==
             "Brann (actor 21) was around for about 1 minute; came within 4 m of me, then left."

    assert unnamed ==
             "someone unnamed (actor 23) was around for about 1 minute; came within 6 m of me, then left."
  end

  test "at most 4 encounter entries per person per 20 minutes; the rest are reported as capped" do
    visits =
      Enum.reduce(0..4, start(), fn visit, acc ->
        at = visit * 12_000

        acc
        |> feed(at, at + 1000, [person(21, "Brann", 3.0)])
        |> feed(at + 1050, at + 11_950, [])
      end)

    {ledger, entries, capped} = visits

    assert Enum.map(entries, & &1["id"]) ==
             for(at <- [0, 12_000, 24_000, 36_000], do: "sight:encounter:21:#{at}")

    assert capped == [%{actor: 21, kind: :encounter}]
    assert ledger.capped == %{encounter: 1, construction: 0}

    # 第一条写出 20 分钟之后，窗口里的旧条目都过期了，再来一次照常写出。
    {_ledger, later, []} =
      {ledger, [], []}
      |> feed(1_300_000, 1_301_000, [person(21, "Brann", 3.0)])
      |> feed(1_301_050, 1_312_000, [])

    assert [%{"id" => "sight:encounter:21:1300000"}] = later
  end

  # —— B 附近的建造 / 拆除 ——

  test "placements by one person are merged into one entry 30 s after the last one" do
    names = seen([person(9, "Mara", 20.0)])

    {ledger, [], []} =
      Sight.witness(
        Sight.new(),
        [event(1, 1000, 9, :build, {3, 0, 0}), event(2, 1000, 9, :build, {4, 0, 0})],
        names,
        1000
      )

    {ledger, [], []} = Sight.witness(ledger, [event(3, 2000, 9, :build, {5, 0, 0})], names, 2000)
    {ledger, [], []} = Sight.due(ledger, names, 31_999)
    {ledger, [entry], []} = Sight.due(ledger, names, 32_000)

    assert entry == %{
             "id" => "sight:place:9:1",
             "at_ms" => 2000,
             "text" => "Mara (actor 9) placed 3 blocks about 4 m from me.",
             "tags" => ["kind:sight", "actor:9"]
           }

    assert ledger.groups == %{}
  end

  test "only other people's events within 30 m and at most 5 s old count, each seq once, and nothing without knowing where I am" do
    batch = [
      event(1, 10_000, 7, :build, {1, 0, 0}),
      event(2, 10_000, 9, :build, {30, 0, 0}),
      event(3, 4_000, 9, :build, {2, 0, 0}),
      event(4, 10_000, 9, :build, {29, 0, 0}),
      event(5, 5_000, 9, :build, {6, 0, 0})
    ]

    me = seen([])
    {ledger, [], []} = Sight.witness(Sight.new(), batch, me, 10_000)

    # 存储失败后 World 游标没前进，同一批事件会再来一次：按 seq 不再算。
    {ledger, [], []} = Sight.witness(ledger, batch, me, 10_500)
    {_ledger, [entry], []} = Sight.due(ledger, me, 40_500)

    # 第 4 格中心离我 29.5 米、第 5 格的事件刚好落后 5 秒：都算；第 1 件是我自己，第 2 件 30.5 米，第 3 件落后 6 秒。
    assert entry["text"] == "actor 9 placed 2 blocks about 7 m from me."
    assert entry["id"] == "sight:place:9:4"

    assert {%{groups: groups}, [], []} =
             Sight.witness(Sight.new(), [event(6, 10_000, 9, :build, {3, 0, 0})], nil, 10_000)

    assert groups == %{}
  end

  test "named and unnamed buildings: placement, and removal as entire / part / damaged, naming the original placer when there is one" do
    me = seen([person(9, "Mara", 25.0), person(12, "Brann", 28.0)])
    hut = %{prefab: 3, instance: {5, 1}, anchor: {2, 0, 0}, building: "small hut"}
    well = %{prefab: 4, instance: {6, 1}, anchor: {8, 0, 0}, building: "well"}
    shed = %{prefab: 5, instance: {8, 1}, anchor: {0, 0, 5}, building: nil}
    cabin = %{prefab: 5, instance: {9, 1}, anchor: {4, 0, 4}, building: nil}
    # 被拆时事件带的是实例记录里的放置者（Mara 放下的那座）。
    maras_hut = Map.put(hut, :placed_by, 9)

    batch = [
      event(1, 1000, 9, :build, {2, 0, 0}, hut),
      event(2, 1000, 9, :build, {3, 0, 0}, hut),
      event(3, 1000, 12, :damage, {2, 0, 0}, maras_hut),
      event(4, 1000, 12, :destroy, {3, 0, 0}, Map.put(maras_hut, :instance_removed, true)),
      event(5, 1000, 12, :destroy, {8, 0, 0}, Map.put(well, :placed_by, 9)),
      event(6, 1000, 12, :damage, {0, 0, 5}, shed),
      event(7, 1000, 12, :damage, {0, 0, 4}, %{placed_by: 30, building: nil}),
      event(8, 1000, 12, :damage, {0, 0, 4}, %{placed_by: 30, building: nil}),
      event(9, 1000, 12, :destroy, {0, 0, 3}, %{placed_by: 30, building: nil}),
      event(10, 1000, 13, :damage, {1, 0, 4}, %{placed_by: 9, building: nil}),
      event(11, 1000, 13, :damage, {1, 0, 3}, %{placed_by: nil, building: nil}),
      event(12, 1000, 14, :build, {4, 0, 4}, cabin)
    ]

    {ledger, [], []} = Sight.witness(Sight.new(), batch, me, 1000)
    {_ledger, entries, []} = Sight.due(ledger, me, 31_000)

    # 按组内第一个 seq 的次序。
    assert Enum.map(entries, & &1["id"]) == [
             "sight:place:9:1",
             "sight:remove:12:3",
             "sight:remove:12:5",
             "sight:remove:12:6",
             "sight:remove:12:7",
             "sight:remove:13:10",
             "sight:place:14:12"
           ]

    assert Enum.map(entries, & &1["text"]) == [
             ~s|Mara (actor 9) placed the building "small hut" about 3 m from me.|,
             ~s|Brann (actor 12) removed the entire building "small hut" that Mara (actor 9) placed, about 3 m from me.|,
             ~s|Brann (actor 12) broke off part of the building "well" that Mara (actor 9) placed, about 9 m from me.|,
             "Brann (actor 12) damaged part of the unnamed building about 6 m from me.",
             "Brann (actor 12) removed 1 block that actor 30 placed, about 4 m from me.",
             "actor 13 damaged 2 blocks about 4 m from me.",
             "actor 14 placed an unnamed building about 7 m from me."
           ]

    assert Enum.map(entries, & &1["tags"]) == [
             ["kind:sight", "actor:9", "place:small hut"],
             ["kind:sight", "actor:12", "place:small hut"],
             ["kind:sight", "actor:12", "place:well"],
             ["kind:sight", "actor:12"],
             ["kind:sight", "actor:12"],
             ["kind:sight", "actor:13"],
             ["kind:sight", "actor:14"]
           ]
  end

  test "a group closes 5 minutes after it opened even while events keep coming" do
    me = seen([person(9, "Mara", 2.0)])

    {ledger, entries, []} =
      Enum.reduce(0..31, {Sight.new(), [], []}, fn i, {ledger, entries, capped} ->
        at = i * 10_000
        block = event(i + 1, at, 9, :build, {rem(i, 10), 0, div(i, 10)})
        {ledger, new, more} = Sight.witness(ledger, [block], me, at)
        {ledger, entries ++ new, capped ++ more}
      end)

    assert [%{"id" => "sight:place:9:1", "at_ms" => 300_000, "text" => text}] = entries
    assert text == "Mara (actor 9) placed 31 blocks about 1 m from me."
    {_ledger, [next], []} = Sight.due(ledger, me, 340_000)
    assert next["id"] == "sight:place:9:32"
    assert next["text"] == "Mara (actor 9) placed 1 block about 4 m from me."
  end

  test "at most 4 construction entries per person per 20 minutes; the rest are reported as capped" do
    me = seen([])

    {ledger, entries, capped} =
      Enum.reduce(0..4, {Sight.new(), [], []}, fn i, {ledger, entries, capped} ->
        at = i * 40_000
        {ledger, a, x} = Sight.witness(ledger, [event(i + 1, at, 9, :build, {2, 0, i})], me, at)
        {ledger, b, y} = Sight.due(ledger, me, at + 30_000)
        {ledger, entries ++ a ++ b, capped ++ x ++ y}
      end)

    assert Enum.map(entries, & &1["id"]) == for(seq <- 1..4, do: "sight:place:9:#{seq}")
    assert capped == [%{actor: 9, kind: :construction}]
    assert ledger.capped == %{encounter: 0, construction: 1}
  end

  test "events Life.State already wrote as damage to my construction are not repeated as sights; later hits are, with me as the placer" do
    me = seen([person(9, "Mara", 2.0)])
    names = %{9 => "Mara"}

    batch = [
      event(1, 1000, 9, :damage, {2, 0, 0}, %{placed_by: 7}),
      event(2, 1000, 9, :damage, {2, 0, 0}, %{placed_by: 7})
    ]

    # 一次毁坏过程只评价首个：第 1 件写成“动我的建筑”经历，第 2 件不写。
    {_state, [episode]} =
      State.advance(State.new(7, "world", 0, 0), batch, 2, 1000, :rules, names)

    assert episode["seq"] == 1
    assert Enum.map(Sight.unwritten(batch, [episode]), & &1.seq) == [2]

    {ledger, [], []} = Sight.witness(Sight.new(), Sight.unwritten(batch, [episode]), me, 1000)
    {_ledger, [entry], []} = Sight.due(ledger, me, 31_000)

    assert entry == %{
             "id" => "sight:remove:9:2",
             "at_ms" => 1000,
             "text" => "Mara (actor 9) damaged 1 block that I placed, about 3 m from me.",
             "tags" => ["kind:sight", "actor:9"]
           }
  end

  # —— 输入 ——

  defp start, do: {Sight.new(), [], []}

  # 从 from 到 to（含）每 50 毫秒喂一帧同样的人，攒下写出的条目与被挡下的。
  defp feed(acc, from, to, people) do
    Enum.reduce(from..to//@frame_ms, acc, fn at, {ledger, entries, capped} ->
      {ledger, new, more} = Sight.see(ledger, seen(people), at)
      {ledger, entries ++ new, capped ++ more}
    end)
  end

  defp seen(people), do: %{self: %{entity_id: 7, position: {0.0, 0.0, 0.0}}, entities: people}
  defp person(id, name, x), do: %{entity_id: id, name: name, position: {x, 0.0, 0.0}}

  # 散格的事件（没有所属建筑）；extra 覆盖字段，涉及建筑时给 prefab / instance / anchor / building。
  defp event(seq, at_ms, actor, kind, cell, extra \\ %{}),
    do:
      Map.merge(
        %{
          seq: seq,
          at_ms: at_ms,
          actor: actor,
          kind: kind,
          cell: cell,
          material: 11,
          placed_by: nil,
          prefab: nil,
          instance: nil,
          anchor: nil,
          instance_removed: false
        },
        extra
      )
end
