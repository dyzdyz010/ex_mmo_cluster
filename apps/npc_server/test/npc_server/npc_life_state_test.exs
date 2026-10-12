defmodule NpcServer.NpcLifeStateTest do
  @moduledoc """
  只测试：纯规则入口，受控时钟，无 World、数据库、网络或模型替身。
  证明因果评价、同一毁坏过程去重、衰减、JSON 恢复及各维度的行为用途；不证明身体移动。
  """
  use ExUnit.Case, async: true
  alias NpcServer.Life.State

  defp new, do: State.new(7, "world-a", 0, 0)

  test "模型路径的建设事件仍更新关系，但不会预先施加规则情绪" do
    {state, [episode]} = State.advance(new(), [event(1, :damage, 11)], 1, 0, :model)
    assert state["relationships"]["11"]["trust"] == -0.35
    assert state["emotions"]["anger"] == 0.0
    assert state["evidence"]["anger"] == nil
    assert episode["actor"] == 11
    assert episode["text"] =~ "emotional appraisal is pending"
  end

  test "Social 兼容策略不会把模型评价序号当作 World 感谢事务号" do
    state =
      new()
      |> put_in(["emotions", "gratitude"], 0.9)
      |> put_in(["evidence", "gratitude"], %{"kind" => "appraisal", "actor" => 12, "seq" => 999})

    choice = State.behavior(state, observation([%{entity_id: 12, position: {2.0, 0.0, 0.0}}]), 0)
    refute choice.acknowledge
    refute choice.source_seq == 999
  end

  test "亲和倾向第三次经历才慢变，来源明确，安静时间和JSON恢复不漂移" do
    events =
      for seq <- 1..6,
          do:
            event(
              seq,
              if(rem(seq, 2) == 1, do: :destroy, else: :build),
              if(rem(seq, 2) == 1, do: 11, else: 12)
            )

    {twice, _} = State.advance(new(), Enum.take(events, 4), 4, 0)
    assert twice["traits"]["sociability"] == 0.5
    {third, _} = State.advance(twice, Enum.drop(events, 4), 6, 0)
    assert_in_delta third["traits"]["sociability"], 0.54, 1.0e-12
    assert third["evidence"]["sociability"] == %{"actor" => 12, "seq" => 6}
    {batch, _} = State.advance(new(), events, 6, 0)
    assert batch == third
    restored = third |> Jason.encode!() |> Jason.decode!()
    assert State.view(restored, 30 * 86_400_000)["traits"] == third["traits"]
    assert {^restored, []} = State.advance(restored, events, 6, 30 * 86_400_000)
  end

  test "仅亲和不同改变感谢接近幅度，不改变陌生人谨慎距离" do
    {state, _} = State.advance(new(), [event(1, :destroy, 11), event(2, :build, 12)], 2, 0)
    low = put_in(state, ["traits", "sociability"], 0.0)
    high = put_in(state, ["traits", "sociability"], 1.0)
    helper = observation([%{entity_id: 12, position: {8.0, 0.0, 0.0}}])
    assert State.behavior(low, helper, 0).distance > State.behavior(high, helper, 0).distance
    assert State.behavior(low, helper, 0).mode == :thank
    stranger = observation([%{entity_id: 99, position: {2.0, 0.0, 0.0}}])
    assert State.behavior(low, stranger, 0) == State.behavior(high, stranger, 0)
  end

  test "旧合法心智仅补亲和初值，不追算历史，不修改已有认识或证据" do
    old = new() |> update_in(["traits"], &Map.delete(&1, "sociability"))
    migrated = State.upgrade(old)
    assert migrated["traits"]["sociability"] == 0.5
    assert update_in(migrated, ["traits"], &Map.delete(&1, "sociability")) == old
    assert State.upgrade(migrated) == migrated
  end

  defp event(seq, kind, actor, opts \\ []) do
    Map.merge(
      %{seq: seq, at_ms: 0, actor: actor, kind: kind, cell: {1, 2, 3}, material: 4, placed_by: 7},
      Map.new(opts)
    )
  end

  defp step(state, event), do: State.advance(state, [event], event.seq, event.at_ms)

  defp observation(entities) do
    %{self: %{entity_id: 7, position: {0.0, 0.0, 0.0}}, entities: entities}
  end

  test "每条伤害与帮助经历直接给出权威 UTC 毫秒时刻并保留事件身份" do
    events = [
      event(6, :damage, 11, at_ms: 1_791_698_780_067),
      event(22, :build, 12, at_ms: 1_791_699_081_234, placed_by: nil)
    ]

    {_, [damage, help]} = State.advance(new(), events, 22, 1_791_699_120_000)

    assert damage["text"] =~ "2026-10-11T06:06:20.067Z (UTC)"
    assert help["text"] =~ "2026-10-11T06:11:21.234Z (UTC)"
    refute damage["text"] =~ "1791698780067 ms"
    refute help["text"] =~ "1791699081234 ms"

    assert Map.take(damage, ["id", "seq", "at_ms"]) ==
             %{"id" => "world-a:6", "seq" => 6, "at_ms" => 1_791_698_780_067}

    assert Map.take(help, ["id", "seq", "at_ms"]) ==
             %{"id" => "world-a:22", "seq" => 22, "at_ms" => 1_791_699_081_234}
  end

  test "伤害、修复、再次伤害分别归因，第三轮才缓慢漂移" do
    events = [
      event(1, :destroy, 11),
      event(2, :build, 12, placed_by: nil),
      event(3, :destroy, 11, placed_by: 12),
      event(4, :build, 12, placed_by: nil),
      event(5, :destroy, 11, placed_by: 12)
    ]

    {state, episodes} = State.advance(new(), events, 5, 0)
    assert state["cursor"] == 5
    assert state["emotions"] == %{"anger" => 1.0, "gratitude" => 1.0}
    assert_in_delta state["traits"]["caution"], 0.25, 1.0e-12
    assert state["relationships"]["11"]["trust"] == -1.0
    assert state["relationships"]["12"]["trust"] == 0.5
    assert state["evidence"]["damage_count"] == 3
    assert Enum.map(episodes, & &1["id"]) == Enum.map(1..5, &"world-a:#{&1}")
    assert hd(episodes)["text"] =~ "Actor 11"
    assert hd(episodes)["seq"] == 1
    assert hd(episodes)["at_ms"] == 0
    assert state["evidence"]["anger"]["seq"] == 5
  end

  test "自操作、自然地形、无关建造仅消费游标" do
    events = [
      event(1, :destroy, 7),
      event(2, :destroy, 11, placed_by: nil),
      event(3, :build, 12, placed_by: nil),
      event(4, :damage, 11, placed_by: 13)
    ]

    {state, episodes} = State.advance(new(), events, 4, 0)
    assert state == Map.put(new(), "cursor", 4)
    assert episodes == []
  end

  test "修复须同格同材料且不能重复奖励，自己修复只消除损坏" do
    {hurt, _} = step(new(), event(1, :destroy, 11))
    {wrong, []} = step(hurt, event(2, :build, 12, material: 5, placed_by: nil))
    assert wrong["emotions"] == hurt["emotions"]
    {elsewhere, []} = step(wrong, event(3, :build, 12, cell: {1, 9, 3}, placed_by: nil))
    {fixed, [_]} = step(elsewhere, event(4, :build, 12, placed_by: nil))
    {again, []} = step(fixed, event(5, :build, 13, placed_by: nil))
    assert again["relationships"]["13"] == nil
    {own_fixed, []} = step(hurt, event(2, :build, 7, placed_by: nil))
    {not_help, []} = step(own_fixed, event(3, :build, 12, placed_by: nil))
    assert not_help["emotions"]["gratitude"] == 0.0
    assert not_help["relationships"]["12"] == nil
  end

  test "连续镐击和最终destroy属于一个毁坏过程，来源保留首击" do
    {state, episodes} =
      State.advance(
        new(),
        [event(1, :damage, 11), event(2, :damage, 11), event(3, :destroy, 11)],
        3,
        0
      )

    assert state["emotions"]["anger"] == 0.6
    assert state["evidence"]["damage_count"] == 1
    assert state["evidence"]["anger"]["seq"] == 1
    assert length(episodes) == 1
  end

  test "已消费seq重复出现不评价，batch和逐条推进一致" do
    events = [
      event(1, :destroy, 11),
      event(2, :build, 12, at_ms: 60_000, placed_by: nil),
      event(3, :destroy, 11, at_ms: 120_000, placed_by: 12)
    ]

    {batch, episodes} = State.advance(new(), events, 3, 120_000)

    {linear, parts} =
      Enum.reduce(events, {new(), []}, fn e, {s, es} ->
        {next, more} = step(s, e)
        {next, es ++ more}
      end)

    assert batch == linear
    assert episodes == parts
    assert State.advance(batch, events, 3, 120_000) == {batch, []}
  end

  test "120秒半衰期包含离线时间，负时间差不逆转，view不修改源" do
    {hurt, _} = step(new(), event(1, :destroy, 11))
    {state, _} = step(hurt, event(2, :build, 12, placed_by: nil))
    assert State.view(state, -1) == state
    half = State.view(state, 120_000)
    assert_in_delta half["emotions"]["anger"], 0.3, 1.0e-12
    assert_in_delta half["emotions"]["gratitude"], 0.3, 1.0e-12
    assert State.view(state, 120_000 * 1000)["emotions"]["anger"] < 1.0e-20
    assert state["emotions"]["anger"] == 0.6
    assert half["relationships"] == state["relationships"]
    assert half["traits"] == state["traits"]
  end

  test "人格与关系有界，多次帮助缓慢降低谨慎" do
    cycles =
      for n <- 0..24,
          e <- [event(n * 2 + 1, :destroy, 11), event(n * 2 + 2, :build, 12, placed_by: nil)],
          do: e

    {state, _} = State.advance(new(), cycles, 50, 0)
    assert state["traits"]["caution"] >= 0.0
    assert state["traits"]["caution"] <= 1.0
    assert state["relationships"]["11"]["trust"] == -1.0
    assert state["relationships"]["12"]["trust"] == 1.0
    {two_help, _} = State.advance(new(), Enum.take(cycles, 4), 4, 0)
    assert two_help["traits"]["caution"] == 0.2
    {three_help, _} = State.advance(two_help, Enum.slice(cycles, 4, 2), 6, 0)
    assert_in_delta three_help["traits"]["caution"], 0.24, 1.0e-12
  end

  test "JSON冷恢复延续关心格、关系、人格和衰减而非新生" do
    events =
      for n <- 0..2,
          e <- [event(n * 2 + 1, :destroy, 11), event(n * 2 + 2, :build, 12, placed_by: nil)],
          do: e

    {state, _} = State.advance(new(), events, 6, 0)
    restored = state |> Jason.encode!() |> Jason.decode!()
    assert restored == state
    {next, [_]} = step(restored, event(7, :destroy, 11, at_ms: 120_000, placed_by: 12))
    assert next["relationships"]["11"]["trust"] == -1.0
    assert_in_delta next["traits"]["caution"], 0.29, 1.0e-12
    assert_in_delta next["emotions"]["gratitude"], 0.5, 1.0e-12
    assert next["evidence"]["damage_count"] == 4
  end

  test "anger单独使可见来源角色被回避，离开观察后不凭记忆定位" do
    state =
      new()
      |> put_in(["emotions", "anger"], 0.6)
      |> put_in(["evidence", "anger"], %{"actor" => 11, "seq" => 1})

    near = observation([%{entity_id: 11, position: {1.0, 0.0, 0.0}}])
    assert State.behavior(state, near, 0).mode == :avoid
    assert State.behavior(state, near, 0).source_seq == 1

    assert State.behavior(state, observation([%{entity_id: 11, position: {8.0, 0.0, 0.0}}]), 0).mode ==
             :avoid

    assert State.behavior(state, observation([]), 0).mode == :work
    assert State.behavior(new(), near, 0).mode == :cautious
    assert State.behavior(state, near, 1_200_000).mode == :cautious
  end

  test "gratitude单独使来源帮助者被接近，接近完成后回到工作" do
    state =
      new()
      |> put_in(["emotions", "gratitude"], 0.6)
      |> put_in(["evidence", "gratitude"], %{"actor" => 12, "seq" => 2})

    far = observation([%{entity_id: 12, position: {8.0, 0.0, 0.0}}])
    assert State.behavior(state, far, 0).mode == :thank
    assert State.behavior(state, far, 0).actor == 12
    assert State.behavior(new(), far, 0).mode == :work

    assert State.behavior(state, observation([%{entity_id: 12, position: {1.0, 0.0, 0.0}}]), 0).mode ==
             :work
  end

  test "caution改变陌生人期望距离，使用完整XYZ且安全距离恢复工作" do
    near = observation([%{entity_id: 13, position: {0.0, 2.0, 0.0}}])
    cautious = put_in(new(), ["traits", "caution"], 0.7)
    assert_in_delta State.behavior(new(), near, 0).distance, 3.2, 1.0e-12
    assert_in_delta State.behavior(cautious, near, 0).distance, 6.2, 1.0e-12

    assert State.behavior(new(), observation([%{entity_id: 13, position: {0.0, 8.0, 0.0}}]), 0).mode ==
             :work
  end

  test "trust没有情绪也独立改变期望距离，选择顺序不依赖entities顺序" do
    near = observation([%{entity_id: 11, position: {1.0, 0.0, 0.0}}])
    negative = put_in(new(), ["relationships", "11"], %{"trust" => -0.5, "source_seq" => 9})
    positive = put_in(new(), ["relationships", "11"], %{"trust" => 0.5, "source_seq" => 10})
    assert State.behavior(negative, near, 0).distance > State.behavior(new(), near, 0).distance
    assert State.behavior(positive, near, 0).distance < State.behavior(new(), near, 0).distance
    assert State.behavior(negative, near, 0).source_seq == 9

    two =
      observation([
        %{entity_id: 12, position: {1.0, 0.0, 0.0}},
        %{entity_id: 11, position: {1.0, 0.0, 0.0}}
      ])

    assert State.behavior(negative, two, 0) ==
             State.behavior(negative, %{two | entities: Enum.reverse(two.entities)}, 0)
  end

  test "陌生人的谨慎行为可以追溯到人格漂移来源" do
    events =
      for n <- 0..2,
          e <- [event(n * 2 + 1, :destroy, 11), event(n * 2 + 2, :build, 7, placed_by: nil)],
          do: e

    {state, _} = State.advance(new(), events, 6, 0)
    stranger = observation([%{entity_id: 13, position: {1.0, 0.0, 0.0}}])
    assert State.behavior(state, stranger, 0).source_seq == 5
  end

  test "持续伤害上界饱和，记住多格后连续帮助可抵达下界" do
    cells = for x <- 1..102, do: {x, 2, 3}

    damage =
      for {cell, seq} <- Enum.with_index(cells, 1), do: event(seq, :destroy, 11, cell: cell)

    {hurt, _} = State.advance(new(), damage, 102, 0)
    assert hurt["traits"]["caution"] == 1.0

    helps =
      for {cell, seq} <- Enum.with_index(cells, 103),
          do: event(seq, :build, 12, cell: cell, placed_by: nil)

    {helped, _} = State.advance(hurt, helps, 204, 0)
    assert helped["traits"]["caution"] == 0.0
    assert helped["relationships"]["12"]["trust"] == 1.0
  end

  test "感谢已达距离不能遮蔽更近陌生人的谨慎动作" do
    state =
      new()
      |> put_in(["emotions", "gratitude"], 0.6)
      |> put_in(["evidence", "gratitude"], %{"actor" => 12, "seq" => 2})

    mixed =
      observation([
        %{entity_id: 12, position: {1.0, 0.0, 0.0}},
        %{entity_id: 13, position: {0.5, 0.0, 0.0}}
      ])

    choice = State.behavior(state, mixed, 0)
    assert choice.mode == :cautious
    assert choice.actor == 13
    assert choice == State.behavior(state, %{mixed | entities: Enum.reverse(mixed.entities)}, 0)
  end

  test "相同延迟观察时刻消费历史batch和逐条消费状态与片段相同" do
    first = event(1, :destroy, 11)
    second = event(2, :destroy, 11, at_ms: 120_000, cell: {2, 2, 3})
    {batch, episodes} = State.advance(new(), [first, second], 2, 240_000)
    {partial, first_episodes} = State.advance(new(), [first], 1, 240_000)
    {linear, second_episodes} = State.advance(partial, [second], 2, 240_000)
    assert_in_delta State.view(batch, 240_000)["emotions"]["anger"], 0.45, 1.0e-12
    assert_in_delta State.view(linear, 240_000)["emotions"]["anger"], 0.45, 1.0e-12
    assert batch == linear
    assert episodes == first_episodes ++ second_episodes
  end

  test "空轮询推进时间后旧事件不能被当作新鲜情绪" do
    historical = event(1, :destroy, 11)
    {idle, []} = State.advance(new(), [], 0, 120_000)
    assert idle == new()
    {late, late_episodes} = State.advance(idle, [historical], 1, 120_000)
    {direct, direct_episodes} = State.advance(new(), [historical], 1, 120_000)
    assert_in_delta State.view(late, 120_000)["emotions"]["anger"], 0.3, 1.0e-12
    assert late == direct
    assert late_episodes == direct_episodes
  end

  test "事件时刻饱和不依赖分批，轮询视图不回写canonical锚" do
    first = event(1, :destroy, 11)
    second = event(2, :destroy, 11, cell: {2, 2, 3})
    {batch, episodes} = State.advance(new(), [first, second], 2, 120_000)
    {partial, first_episodes} = State.advance(new(), [first], 1, 120_000)
    {linear, second_episodes} = State.advance(partial, [second], 2, 120_000)
    assert_in_delta State.view(batch, 120_000)["emotions"]["anger"], 0.5, 1.0e-12
    assert_in_delta State.view(linear, 120_000)["emotions"]["anger"], 0.5, 1.0e-12
    assert batch == linear
    assert batch["last_at_ms"] == 0
    assert batch["emotions"]["anger"] == 1.0
    assert episodes == first_episodes ++ second_episodes
  end
end
