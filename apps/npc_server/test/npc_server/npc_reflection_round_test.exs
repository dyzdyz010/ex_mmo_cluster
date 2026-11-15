Code.require_file("../support/reflection_fixtures.exs", __DIR__)

defmodule NpcServer.NpcReflectionRoundTest do
  @moduledoc """
  只测试：一轮反思的流程 `NpcServer.Life.Reflection.Round`（不起 Life、不起 World）与反思“此刻”的渲染 `Mind.right_now/2`。
  输入全是真实导出（S1-X2 第 4 轮：S1-T 的经历序列、那一刻的原始观察、两次召回的真实条目、之前的日记、真实应答；
  见 `test/support/fixtures/reflection/README.md`）。替身只有两处：Hindsight 适配器（召回回放那两次召回的真实条目——按 `types`
  各回各的、或同一份原始经历条目两路各回放一次、或返回适配器真实形状的失败——并把每路描述交给测试进程）与写日记的函数
  （回放真实应答，并把系统提示词与用户消息交给测试进程）。
  我的建筑给空表（现查 World 不发生，所以不问建筑），有关系的人给 Corvin：问 Corvin 与“自己”两问。
  证明：“发生过的事”的次序与各条正文与离线测量逐字一致（句首的多久以前按游戏钟 × 24 手算，离线是 × 72）；召回条目按 id 去重（同一条在两路里各出现一次只写一次）；召回的参数；
  “之前的想法”只带此刻还在的对象、次序人 → 自己（含本轮刚写成的）；进持久行的那一份（时刻是这一轮的此刻，问题原文）；
  召回失败时这一轮即止；存档文档。
  不证明：未封存经历在前、建筑一问与现查 World、建筑 → 人的次序（Life 用例）；真实模型与真实 Hindsight。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  import NpcServer.ReflectionFixtures
  alias NpcServer.Life.Reflection.Round
  alias NpcServer.Mind

  defmodule Hindsight do
    @moduledoc """
    只测试：召回按 `config.replay` 回放第 4 轮 Q_place 那一次召回的真实条目——`:by_types` 按这一路的 types 各回各的，
    `:raw_twice` 两路都回放同一份原始经历条目，`:fail` 返回适配器真实形状的失败（`Life.Hindsight` 的 HTTP 非 2xx）；
    每路描述都交给测试进程。存档把 bank 与文档交给测试进程。
    """
    alias NpcServer.ReflectionFixtures

    def recall(config, description, now_ms) do
      send(config.owner, {:recall, config.bank, description, now_ms})

      case config.replay do
        :fail ->
          {:error, {:http_status, 503}}

        :raw_twice ->
          {:ok, %{results: ReflectionFixtures.recalled("raw"), latency_ms: 1}}

        :by_types ->
          kind = if description.types == ["observation"], do: "observation", else: "raw"
          {:ok, %{results: ReflectionFixtures.recalled(kind), latency_ms: 1}}
      end
    end

    def ensure_bank(config, name) do
      send(config.owner, {:ensure_bank, config.bank, name})
      {:ok, %{bank: config.bank}}
    end

    def retain(config, documents) do
      send(config.owner, {:retain, config.bank, documents})
      {:ok, %{retained: length(documents), facts: 1}}
    end
  end

  test "第 4 轮：两问依次写成；“发生过的事”与离线逐字一致，“之前的想法”只带此刻还在的对象，存档进反思库" do
    %{"wrecker" => corvin, "names" => names} = moments()
    now_ms = round_now(4)
    before = json("round4-before.json")
    reply = json("check-samples.json")["1-Q_place"]
    snapshot = snapshot(:by_types)

    result = Round.write(snapshot)

    assert result.asked == ["person:#{corvin}", "self"]
    assert Enum.map(result.written, & &1.key) == ["person:#{corvin}", "self"]

    assert %{discarded: [], failed: [], reasked: 0, error: nil, thought_at_ms: thought_at_ms} =
             result

    # 这一轮“想的时刻”是起槽那一刻（此刻 t′），不是触发那条经历的时刻。
    assert thought_at_ms == now_ms and thought_at_ms != snapshot.round.at_ms

    # 每问两路召回，串行、次序固定；“自己”不带 tags 两个键（nil，适配器不放进请求体）。时刻参数是这一轮的此刻。
    person_tags = %{tags: ["actor:#{corvin}"], tags_match: "any_strict"}
    self_tags = %{tags: nil, tags_match: nil}
    person = "#{names[corvin]} (actor #{corvin})"

    for {tags, text} <- [
          {person_tags, person <> ": what have they actually done around me"},
          {self_tags, "How I have been spending my time lately"}
        ],
        {types, max_tokens} <- [{["experience", "world"], 1500}, {["observation"], 800}] do
      assert_received {:recall, "npc-life-" <> _, description, ^now_ms}
      assert String.starts_with?(description.query, text)

      assert Map.drop(description, [:query]) ==
               Map.merge(tags, %{types: types, max_tokens: max_tokens})
    end

    # 发生过的事：没有未封存的，先第一次召回、再第二次召回的各条；正文与离线渲染的逐字相同（去掉后缀），
    # 句首的多久以前按 × 24 手算（见 `expected_bodies/0`）。
    assert_received {:write, system, person_message}
    assert system == fixture("system-prompt.txt")
    assert happened(person_message) == expected_bodies()

    assert_received {:write, _system, self_message}
    assert happened(self_message) == expected_bodies()

    # 之前的想法：同一问题上一轮的那条；其它问题各自最新的，只取此刻还在的对象（记得的建筑、关系表里的人、自己），
    # 次序 建筑 → 人 → 自己，本轮刚写成的 Corvin 那条在内。持久行里有小屋上一轮的日记，但此刻记得的建筑里没有它
    # （本用例给空表），所以它不进材料。
    # （这几条真实日记本来就是一行、没有多余空白，压成一行之后不变，所以直接比原文。）
    assert thoughts(person_message) == {before["Q_person"], [before["Q_self"]]}
    assert thoughts(self_message) == {before["Q_self"], [reply["journal"]]}

    # 进持久行的那一份：时刻是这一轮的此刻，问题原文就是离线第 4 轮问的那一句，正文是真实日记（离线检查读出的正文），
    # 收尾一句是这篇真实日记的最后一句（照原文抄出；检查的收尾一句与离线真实读数一致，由 npc_reflection_test 的 4-Q_self 用例证明）。
    closing =
      "I'll go to the stone pile and cut stone again, then rebuild the hut, and I'll keep an eye on whether Corvin comes near it again."

    assert String.ends_with?(reply["journal"], " " <> closing)

    for {%{key: key, entry: entry}, offline} <-
          Enum.zip(result.written, ["Q_person", "Q_self"]) do
      assert entry == %{
               "at_ms" => now_ms,
               "journal" => reply["journal"],
               "closing" => closing,
               "text" => offline_question(offline)
             },
             key
    end

    # 存档：反思库建库、每条一份文档，id 与正文前缀的时刻都是这一轮的此刻。
    assert {:ok, %{retained: 2}} = Round.archive(snapshot, result)
    assert_received {:ensure_bank, "npc-reflect-" <> _, "NPC " <> _}
    assert_received {:retain, "npc-reflect-" <> _, [first, second]}
    assert first["id"] == "reflection:person:#{corvin}:#{now_ms}"
    assert second["id"] == "reflection:self:#{now_ms}"
    assert first["at_ms"] == now_ms

    assert first["text"] ==
             "At #{DateTime.to_iso8601(DateTime.from_unix!(now_ms, :millisecond))} (UTC), I thought it over: " <>
               reply["journal"]

    # 一条都没写成就不存，不发请求。
    assert Round.archive(snapshot, %{result | written: []}) == :none
    refute_received {:ensure_bank, _, _}
  end

  test "召回条目按 id 去重：同一份真实条目在两路里各回放一次，“发生过的事”里每条只出现一次" do
    # 两路召回的类型不相交（experience/world 与 observation），真实 Hindsight 不会两路回同一个 id；这里是把同一份
    # 真实条目在两路各回放一次（替身构造的情形），证明的是“按 id 去重”这条从离线脚本移植来的规则确实在生效。
    result = Round.write(snapshot(:raw_twice))
    assert result.error == nil

    # 两路都回放同样的 21 条原始经历：不去重会是 42 条。离线渲染里这 21 条就是前 21 条正文。
    raw = length(recalled("raw"))
    assert_received {:write, _system, message}
    assert happened(message) == Enum.take(expected_bodies(), raw)
  end

  test "召回失败：这一问记失败、这一轮到此为止，后面的问题不再发请求、不写日记" do
    %{"wrecker" => corvin} = moments()
    person = "person:#{corvin}"
    result = Round.write(snapshot(:fail))

    assert %{
             asked: [^person, "self"],
             written: [],
             discarded: [],
             failed: [^person],
             reasked: 0,
             error: {:http_status, 503}
           } = result

    # 只发出了第一问的第一路召回；没有任何写日记的请求。
    assert_received {:recall, _, %{types: ["experience", "world"]}, _}
    refute_received {:recall, _, _, _}
    refute_received {:write, _, _}
    assert Round.archive(snapshot(:fail), result) == :none
  end

  test "“此刻”的日号一句与身体一句：由第 1、4 轮的真实原始观察渲染，与离线 right-now 的那两句相同" do
    for k <- [1, 4] do
      [line1, _situation, line3] = Mind.right_now(rawobs(k), [])

      ["Right now:", real1, _real_situation, real3] =
        String.split(fixture("round#{k}-right-now.txt"), "\n")

      # Now 栏取的是离线那一刻 state 的钟点，不在本测试里比；日号一句取自这份原始观察。
      [day] = Regex.run(~r/ It is day \d+\.$/, real1)
      assert String.ends_with?(line1, day), "第 #{k} 轮"
      assert line3 == real3, "第 #{k} 轮"
    end
  end

  # 第 4 轮的快照：触发时刻与累计分是 S1-X2 算出的第 4 个时刻，此刻是离线第 4 轮的 t′；写日记的函数回放真实应答。
  defp snapshot(replay) do
    test = self()
    %{"wrecker" => corvin, "names" => names, "self_cid" => cid} = moments()
    moment = Enum.at(moments()["moments"], 3)
    now_ms = round_now(4)
    before = json("round4-before.json")
    reply = json("check-samples.json")["1-Q_place"]

    %{
      cid: cid,
      round: %{at_ms: moment["t_ms"], score: moment["score"], causes: [:score]},
      # 新经历 = 第 3 轮此刻（不含）到第 4 轮此刻（含）之间的真实经历（S1-X2 运行前补记第 4 条）。
      new:
        for(
          e <- json("s1t-experiences.json"),
          e["at_ms"] > round_now(3) and e["at_ms"] <= now_ms,
          do: Map.take(e, ["at_ms", "tags"])
        ),
      now_ms: now_ms,
      observation: rawobs(4),
      recent: [],
      buildings: [],
      people: [corvin],
      names: names,
      latest: %{
        "place:small hut" => %{"journal" => before["Q_place"]},
        "person:#{corvin}" => %{"journal" => before["Q_person"]},
        "self" => %{"journal" => before["Q_self"]}
      },
      adapter: Hindsight,
      config: %{bank: "npc-life-#{cid}", owner: test, replay: replay},
      archive: %{bank: "npc-reflect-#{cid}", owner: test},
      archive_name: "NPC #{cid} journal",
      write: fn system, user ->
        send(test, {:write, system, user})
        {:ok, %{text: reply["response"], usage: %{}}}
      end,
      character: fixture("character.txt"),
      context: %{cid: cid}
    }
  end

  defp moments, do: json("s1x2-moments.json")
  defp round_now(k), do: iso_ms(Enum.at(moments()["rounds"], k - 1)["now"])

  # 离线第 4 轮真实问到的问题原文。
  defp offline_question(key) do
    %{"text" => text} =
      Enum.find(Enum.at(moments()["rounds"], 3)["questions"], &(&1["key"] == key))

    text
  end

  # 用户消息里 What happened 一块的各条正文（去掉编号，编号从 1 起连续）。
  # 夹具里每条的离线渲染 `body` 是 × 72 算出的句首（“About 20.5 hours ago, …”）。游戏钟 2026-11-15 改为 × 24 后句首变了，
  # 正文（句首之后的部分）与倍率无关、仍取夹具原文；句首换成下面按 × 24 手算的值：29 条各自 此刻 − 条目时刻（毫秒）
  # × 24 换成游戏小时，不足 0.25 小时写 Just now，不足 48 小时按 0.5 小时四舍五入，否则按天。
  # 这份值由与被测代码无关的 Python 脚本从夹具的 `at` 与第 4 轮此刻算出；同一脚本在 × 72 下复现了夹具里全部 29 个离线句首，
  # 才用它出 × 24 的值。
  @ago_x24 [
    "About 7 hours ago",
    "About 7 hours ago",
    "About 5.5 hours ago",
    "About 5.5 hours ago",
    "About 2 hours ago",
    "About 6.5 hours ago",
    "About 4.5 hours ago",
    "About 4 hours ago",
    "About 2 hours ago",
    "About 7 hours ago",
    "About 3 hours ago",
    "About 4.5 hours ago",
    "About 2.5 hours ago",
    "About 3.5 hours ago",
    "About 3 hours ago",
    "About 4 hours ago",
    "About 2.5 hours ago",
    "About 4.5 hours ago",
    "About 8 hours ago",
    "About 6 hours ago",
    "About 3 hours ago",
    "About 7 hours ago",
    "About 7 hours ago",
    "About 7 hours ago",
    "About 5.5 hours ago",
    "About 6.5 hours ago",
    "About 8 hours ago",
    "About 5.5 hours ago",
    "About 8 hours ago"
  ]

  defp expected_bodies do
    bodies = recalled_bodies()
    assert length(bodies) == length(@ago_x24)

    for {ago, body} <- Enum.zip(@ago_x24, bodies) do
      rest = String.replace(body, ~r/^(?:Just now|About [\d.]+ (?:hours?|days?) ago), /, "")
      ago <> ", " <> rest
    end
  end

  defp happened(message) do
    [_, block] = Regex.run(~r/\nWhat happened:\n(.*?)\n\n/s, message)

    block
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, n} ->
      prefix = "[#{n}] "
      assert String.starts_with?(line, prefix)
      String.replace_prefix(line, prefix, "")
    end)
  end

  # 之前的想法：{About this 的那一行, About other things 的各行}。
  defp thoughts(message) do
    [_, this, others] =
      Regex.run(~r/\nAbout this: (.*)\nAbout other things: (.*?)\n\nTo think over now:/s, message)

    {this, String.split(others, "\n")}
  end
end
