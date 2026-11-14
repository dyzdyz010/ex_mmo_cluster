defmodule NpcServer.NpcReflectionTest do
  @moduledoc """
  只测试：反思纯函数核心 `NpcServer.Life.Reflection` 的契约——计分与触发、定问题、提示词拼装、应答检查、存档文档。
  输入全部是真实导出或对它的删减（S1-T 实跑的 108 份文档、S1-X2 真实发出的提示词与真实应答；来源与重新生成见
  `test/support/fixtures/reflection/README.md`），期望取自 S1-X2 / S1-X3 的真实读数或契约原文。
  不证明：取材料、写日记的网络调用、Life 的接线与持久化（R2、R3）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias NpcServer.Life.Reflection

  @fixtures Path.expand("../support/fixtures/reflection", __DIR__)

  test "S1-T 的真实经历逐条记入：触发的时刻、累计分与原因就是 S1-X2 算出的 7 个，触发状态每步过 JSON 不变形" do
    {_trigger, rounds} =
      Enum.reduce(experiences(), {Reflection.new_trigger(), []}, fn entry, {trigger, rounds} ->
        # 触发状态进 Life 持久行：每步先过一遍 JSON，证明它是能原样存取的普通 map。
        trigger = trigger |> Jason.encode!() |> Jason.decode!()

        case Reflection.record(trigger, entry) do
          {trigger, nil} -> {trigger, rounds}
          {trigger, round} -> {trigger, [{entry["id"], round} | rounds]}
        end
      end)

    expected =
      for m <- moments()["moments"],
          do:
            {m["doc_id"],
             %{at_ms: m["t_ms"], score: m["score"], causes: Enum.map(m["causes"], &cause/1)}}

    assert Enum.reverse(rounds) == expected
  end

  test "计分表：真实经历按 tags 各得 8 / 5 / 3 / 3 / 1" do
    # 每类取夹具里第一条（按 tags 找）：带 actor: 的活动 = 期间有人进过 6 米。
    entries = experiences()
    first = fn wanted -> Enum.find(entries, &wanted.(&1["tags"])) end
    with_people = fn tags -> Enum.any?(tags, &String.starts_with?(&1, "actor:")) end

    assert Reflection.score(first.(&("kind:event" in &1))) == 8
    assert Reflection.score(first.(&("kind:conversation" in &1))) == 5
    assert Reflection.score(first.(&("kind:sight" in &1))) == 3
    assert Reflection.score(first.(&("kind:activity" in &1 and with_people.(&1)))) == 3
    assert Reflection.score(first.(&("kind:activity" in &1 and not with_people.(&1)))) == 1
  end

  test "定问题：S1-X2 每一轮按“自上一轮以来的新经历”问的就是当时问的（第 2、3、5 轮 Corvin 没有新经历被跳过）" do
    %{"wrecker" => corvin, "rounds" => rounds} = moments()

    for {round, k} <- Enum.with_index(rounds, 1) do
      expected =
        for %{"asked" => true} = q <- round["questions"],
            do: %{
              "key" => key(q["key"], corvin),
              "text" => q["text"],
              "tags" => ["kind:reflection" | q["tags"]]
            }

      assert asked(k) == expected, "第 #{k} 轮"
    end

    assert Reflection.questions(["small hut"], [corvin], moments()["names"], []) == []
  end

  test "超过 3 问时“自己”保留，另两个名额给新经历最近的对象，留下的仍按 建筑 → 人 → 自己" do
    # 整场 108 条都算新经历；假设我的建筑有 small hut 与 the plaza、有关系的人有 Corvin 与 Tobin（tags 都是真实的）。
    # 各对象最近一条新经历（手查夹具）：small hut 17:18:54.700，Tobin 16:47:43.784，Corvin 16:45:35.244，
    # the plaza 16:30:18.148。所以留 small hut 与 Tobin，Corvin 排在 Tobin 前面也不留。
    %{"names" => names, "wrecker" => corvin, "visitor" => tobin} = moments()

    asked =
      Reflection.questions(["small hut", "the plaza"], [corvin, tobin], names, experiences())

    assert Enum.map(asked, & &1["key"]) == ["place:small hut", "person:#{tobin}", "self"]
  end

  test "系统提示词与 S1-X2 真实发出的逐字节相同" do
    assert Reflection.system_prompt(fixture("character.txt")) == fixture("system-prompt.txt")
  end

  test "用户消息：第 4 轮 Q_place 由真实各部分拼出，与真实发出的逐字节相同" do
    before = json("round4-before.json")

    message =
      Reflection.user_message(place_question(4), %{
        right_now: right_now(4),
        happened: json("round4-happened-Q_place.json"),
        thought_before: before["Q_place"],
        other_thoughts: [before["Q_person"], before["Q_self"]]
      })

    assert message == fixture("round4-user-Q_place.txt")
  end

  test "用户消息：第 1 轮没有之前的想法，两处都写 nothing yet，与真实发出的逐字节相同" do
    message =
      Reflection.user_message(place_question(1), %{
        right_now: right_now(1),
        happened: json("round1-happened-Q_place.json"),
        thought_before: nil,
        other_thoughts: []
      })

    assert message == fixture("round1-user-Q_place.txt")
  end

  test "应答检查：真实的 4 句应答通过，正文、编号、句数与离线检查相同，收尾一句同 S1-X3 新栏里的原文" do
    sample = samples()["4-Q_self"]

    assert {:ok, result} = Reflection.check(sample["response"], sample["items"])
    assert result.journal == sample["journal"]
    assert result.used == sample["used"]
    assert result.sentences == 4
    assert result.closing == sample["closing"]
  end

  test "应答检查：S1-X2 第 5 轮 Q_place 两次都写了 5 句，上限 5 时通过，句数读数为 5" do
    for name <- ["5-Q_place-1", "5-Q_place-2"] do
      sample = samples()[name]

      assert {:ok, %{sentences: 5, used: used}} =
               Reflection.check(sample["response"], sample["items"])

      assert used == sample["used"], name
    end
  end

  test "应答检查：对真实应答删改得到的反例各报出可写进日志的原因" do
    %{"4-Q_self" => four, "5-Q_place-1" => five, "1-Q_place" => one} = samples()

    # 去掉 Used 行：就是 S1-X2 存下的那条日记正文。
    assert Reflection.check(four["journal"], four["items"]) == {:error, :used_line_missing}

    # 最后一个编号 43（材料共 43 条）改成 44。
    out_of_range = String.replace_suffix(four["response"], ", 43", ", 44")
    assert Reflection.check(out_of_range, four["items"]) == {:error, {:used_out_of_range, [44]}}

    # 两条真实应答前后相接：4 句的日记 + 5 句的应答（Used 编号都在 36 条内），共 9 句。
    joined = one["journal"] <> "\n\n" <> five["response"]
    assert Reflection.check(joined, five["items"]) == {:error, {:too_many_sentences, 9}}
  end

  test "存档文档与经历条目同形；Life 加上时刻前缀后就是 S1-X2 存进反思库的原文" do
    sample = samples()["1-Q_place"]
    at_ms = iso_ms(Enum.at(moments()["rounds"], 0)["now"])
    doc = Reflection.archive(place_question(1), at_ms, sample["journal"])

    assert doc == %{
             "id" => "reflection:place:small hut:1794587418632",
             "at_ms" => at_ms,
             "text" => "I thought it over: " <> sample["journal"],
             "tags" => sample["stored_tags"]
           }

    # Life 写库时在前面加 `At <UTC> (UTC), `（Life.dated/1）。
    assert "At 2026-11-13T16:30:18.632Z (UTC), " <> doc["text"] == sample["stored_text"]
  end

  # 第 k 轮问的问题：新经历 = 时刻落在上一轮的此刻 t′（不含）与本轮 t′（含）之间（S1-X2 plan.md 运行前补记第 4 条）；
  # 我的建筑只有 small hut，有关系的人只有 Corvin（S1-T 实跑的事实）。
  defp asked(k) do
    %{"names" => names, "wrecker" => corvin, "rounds" => rounds} = moments()
    now = iso_ms(Enum.at(rounds, k - 1)["now"])
    since = if k > 1, do: iso_ms(Enum.at(rounds, k - 2)["now"])

    fresh =
      Enum.filter(experiences(), &((since == nil or &1["at_ms"] > since) and &1["at_ms"] <= now))

    Reflection.questions(["small hut"], [corvin], names, fresh)
  end

  defp place_question(k), do: Enum.find(asked(k), &(&1["key"] == "place:small hut"))

  # S1-X2 的问题名 -> 本模块的问题键。
  defp key("Q_place", _corvin), do: "place:small hut"
  defp key("Q_person", corvin), do: "person:" <> corvin
  defp key("Q_self", _corvin), do: "self"

  # moments.json 里的触发原因原文 -> 本模块的原因。
  defp cause(%{"cause" => "immediate (kind:event)"}), do: :event
  defp cause(%{"cause" => "score " <> _}), do: :score

  # 此刻一块：真实文件的第一行是 `Right now:` 标题（由被测函数加），其后各行是输入。
  defp right_now(k) do
    ["Right now:" | lines] = String.split(fixture("round#{k}-right-now.txt"), "\n")
    lines
  end

  defp experiences, do: json("s1t-experiences.json")
  defp moments, do: json("s1x2-moments.json")
  defp samples, do: json("check-samples.json")
  defp json(name), do: name |> fixture() |> Jason.decode!()
  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp iso_ms(iso) do
    {:ok, at, 0} = DateTime.from_iso8601(iso)
    DateTime.to_unix(at, :millisecond)
  end
end
