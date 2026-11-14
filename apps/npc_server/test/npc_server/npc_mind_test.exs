Code.require_file("../support/reflection_fixtures.exs", __DIR__)

defmodule NpcServer.NpcMindTest do
  @moduledoc """
  只测试：心智快照 `NpcServer.Mind` 的各栏英文转写（Now 栏、按游戏时间写的“多久以前”、背包去零、召回行去后缀、
  反思新栏的位置与写法）、
  各路召回的描述（`recall_queries/2`）与合并（`merge_recalled/1`）、按选择器选人（`person/2`），以及 Life 给快照的只读投影
  （`Life.State.feelings/2`、`relationships/1`）。

  范围与替身：
  - 纯函数用例直接构造输入（人格卡、Observation、选择器历史、`Life.mind/2` 形状的视图）；期望的英文全文按 `Mind` 的
    栏定义手写，数值档位按 moduledoc 里的阈值手算。不启动 Life、Hindsight、World 或数据库。
  - 游戏时间的句型与取整对照离线测量 S1-K 脚本算出的原文（`.demo/observe/npc-slice1-20261112/s1k/variants/edits.txt`）；
    合并对照 S1-Q 真实导出上的各路返回与重算的清单（`s1q/results.json`、`s1q/remerge-rank-order.json`），所需片段内联在用例里。
  - 反思新栏的那一句取自 S1-Z 真实实跑的持久行（`test/support/fixtures/reflection/s1z/`，来源见该目录 README）。
  - Life 的投影用例经公共入口 `Life.State.advance/5` 接纳一条手写的 World 事件，期望值按规则模式的设计参数手算
    （一次破坏：愤怒 +0.6、信任 −0.35；半衰期 120 秒；活跃阈值 0.1）。
  - `:live_jev` 用例问真实 Jev（薄片一 S1-B 的离线预演），只在显式 `--include live_jev` 时运行；
    它不替代真实服务端里的验收 (b)、(c)。
  """
  use ExUnit.Case, async: true
  alias NpcServer.{Mind, Persona, Selector}
  alias NpcServer.Life.State

  defp profile do
    {:ok, card} = Persona.new(%{"traits" => %{"bold" => 8}, "personal" => "Keeps promises."})

    %{
      who: "Lin, a builder",
      persona: card,
      activities: [
        %{name: "build_north", criterion: "Build the hut on the north plot."},
        %{name: "rest_at_home", criterion: "Go home and rest."}
      ]
    }
  end

  # 自己在 (1, 2, 3)；Mara 在 (4, 2, 7)，差 (3, 0, 4) → 5.0 米；无名 NPC 在 (1, 14, 8)，差 (0, 12, 5) → 13.0 米。
  # 游戏钟 21:25（日内第 1285 分钟）；形状同 Runtime 写进观察的 `MmoContracts.WorldTime.at/1`。
  defp observation do
    %{
      self: %{entity_id: 7, position: {1.0, 2.0, 3.0}, tick: 1, grounded: true, body_state: %{life: 80}},
      pending: [],
      entities: [
        %{entity_id: 7, kind: 1, name: "self", position: {1.0, 2.0, 3.0}},
        %{entity_id: 21, kind: 0, name: "Mara", position: {4.0, 2.0, 7.0}},
        %{entity_id: 22, kind: 1, name: "", position: {1.0, 14.0, 8.0}}
      ],
      balances: [%{material: 11, balance: 512, cost: 512, seq: 3}, %{material: 4, balance: 0, cost: 512, seq: 3}],
      world_time: %{day: 1299, minute_of_day: 1285, weekday: 4}
    }
  end

  defp alone, do: %{observation() | entities: [], balances: nil} |> put_in([:self, :body_state], nil)

  # 读视图那一刻 Life 的时钟（Unix 毫秒）；近期经历与召回条目的时刻都相对它给出。
  @now_ms 1_794_550_000_000

  @empty %{
    now_ms: @now_ms,
    feelings: [],
    relationships: [],
    recent: [],
    models: [],
    memories: [],
    recall_ms: 0,
    buildings: [],
    thought: nil
  }

  # 经历原文（Life 写成的形状，不带时刻）：一次破坏的标准句与一条带期间事实的活动经历。
  @damage "Mara (actor 21) damaged construction I care about at (4, 64, 8), " <>
            "material 11, in world w1 (transaction 9). I feel angry toward this actor; my trust changed."
  @built ~s|I did "build_north" (Build the hut on the north plot.). Result: completed. During it: nobody came near.|

  defp section(life, index, observation \\ alone()) do
    {_title, text} = Enum.at(Mind.snapshot(profile(), observation, [], life), index)
    text
  end

  describe "snapshot" do
    test "seven sections in order; every number is written out in words by code" do
      life = %{
        now_ms: @now_ms,
        # 0.6 → strong；0.15 → faint。来源 21 还在附近（有名字），30 不在。
        feelings: [
          %{emotion: "anger", actor: 21, intensity: 0.6},
          %{emotion: "gratitude", actor: 30, intensity: 0.15}
        ],
        # −0.7 → Deeply distrusts；0.1 接近中立，不写；0.25 → Trusts。
        relationships: [%{actor: 21, trust: -0.7}, %{actor: 22, trust: 0.1}, %{actor: 30, trust: 0.25}],
        # 125 秒前：× 72 = 2.5 游戏小时；10 秒前：0.2 游戏小时，不足 0.25 → Just now。
        recent: [%{at_ms: @now_ms - 125_000, text: @damage}, %{at_ms: @now_ms - 10_000, text: @built}],
        models: [{"self", "I am a careful builder."}, {"relationships", "Mara has helped me before."}],
        # 第一条 50 秒前（1 游戏小时），带抽取器的后缀；第二条没有事件时刻，不写多久以前。
        memories: [
          %{
            "id" => "fact-1",
            "text" => "Mara repaired my wall. | When: Friday, November 13, 2026 at 07:33 UTC",
            "type" => "experience",
            "at_ms" => @now_ms - 50_000,
            "tags" => ["actor:21"]
          },
          %{"id" => "fact-2", "text" => "Brann destroyed my wall.", "type" => "observation", "at_ms" => nil, "tags" => []}
        ],
        recall_ms: 12,
        # 我的建筑（Life.mind 现查 World 的结果）：每座一句，放在背包之前；坐标是锚点宏格，负坐标原样写。
        buildings: [
          %{name: "small hut", anchor: {25, 518, 37}, standing: false},
          %{name: "shed", anchor: {-3, 64, -12}, standing: true}
        ],
        # 没有反思写成的那一句：新栏整栏不出现，仍是七栏。
        thought: nil
      }

      history = [
        %{activity: "build_north", result: :completed},
        %{activity: "rest_at_home", result: {:failed, "travel", "no_path"}}
      ]

      assert [
               {"Now", "It is night, 21:25."},
               {"Character", "Lin, a builder. Personality: very bold. Personal: Keeps promises."},
               {"Feelings and relationships",
                "Feels strong anger toward Mara (actor 21). " <>
                  "Feels faint gratitude toward actor 30, who is not nearby. " <>
                  "Deeply distrusts Mara (actor 21). Trusts actor 30, who is not nearby."},
               {"What just happened",
                "Oldest first. About 2.5 hours ago, " <> @damage <> " Just now, " <> @built},
               {"What I remember",
                "My own memories and beliefs; they may be out of date and are not current world facts.\n" <>
                  "- Belief (self): I am a careful builder.\n" <>
                  "- Belief (relationships): Mara has helped me before.\n" <>
                  "- Recalled: About 1 hour ago, Mara repaired my wall.\n" <>
                  "- Recalled: Brann destroyed my wall."},
               {"Current situation",
                "Standing at x=1.0, z=3.0 (height 2.0). Life 80 of 100. " <>
                  "Nearby: Mara (player, actor 21, 5.0 m away); someone unnamed (NPC, actor 22, 13.0 m away). " <>
                  ~s|My building "small hut" at (25, 518, 37) is gone. My building "shed" at (-3, 64, -12) is standing. | <>
                  "Inventory: material 11: 512 units."},
               {"Recent activities", "Oldest first. build_north: completed. rest_at_home: failed (travel: no_path)."}
             ] == Mind.snapshot(profile(), observation(), history, life)
    end

    test "nothing felt, nothing new, nothing remembered: each section says so; the state is one line per section" do
      assert "Now: It is night, 21:25.\n" <>
               "Character: Lin, a builder. Personality: very bold. Personal: Keeps promises.\n" <>
               "Feelings and relationships: Nothing notable.\n" <>
               "What just happened: Nothing new.\n" <>
               "What I remember: Nothing relevant.\n" <>
               "Current situation: Standing at x=1.0, z=3.0 (height 2.0). Nobody else is nearby. " <>
               "Inventory: not checked yet.\n" <>
               "Recent activities: None yet." == Mind.text(Mind.snapshot(profile(), alone(), [], @empty))
    end

    # 输入：S1-Z 第 5 轮“自己”那条的收尾句与时刻（夹具 `s1z/20261114T031005.159Z-round5-reflection.json`）。
    # 此刻取同一导出文件名的时刻 2026-11-14T03:10:05.159Z（晚于想的时刻约 3 游戏小时，是 Life 给得出的视图）。
    # 正文只有收尾句原文：不加“多久以前”、不加 `I thought: `（R4b）。
    test "what I have come to think: after memory, before the situation; only the closing sentence as written" do
      %{"closing" => closing, "at_ms" => at_ms} =
        "s1z/20261114T031005.159Z-round5-reflection.json"
        |> NpcServer.ReflectionFixtures.json()
        |> get_in(["latest", "self"])

      now_ms = DateTime.to_unix(~U[2026-11-14 03:10:05.159Z], :millisecond)
      life = %{@empty | now_ms: now_ms, thought: %{closing: closing, at_ms: at_ms}}
      sections = Mind.snapshot(profile(), alone(), [], life)

      column =
        {"What I have come to think",
         "This time I'm going straight to the stone beside the plot, no more guarding, " <>
           "a glance at the hut as I pass, a plain question for Corvin if they show, and the plaza only after the stone is cut."}

      assert Enum.map(sections, &elem(&1, 0)) == [
               "Now",
               "Character",
               "Feelings and relationships",
               "What just happened",
               "What I remember",
               "What I have come to think",
               "Current situation",
               "Recent activities"
             ]

      assert Enum.at(sections, 5) == column

      # 没有那一句：整栏不出现，其余各栏原样。
      assert Mind.snapshot(profile(), alone(), [], %{life | thought: nil}) ==
               List.delete(sections, column)
    end

    test "strength and trust bands at their thresholds" do
      feelings = fn life -> section(life, 2) end

      # 强度：≥ 0.4 strong，≥ 0.2 moderate，其余 faint。
      for {intensity, word} <- [{0.4, "strong"}, {0.39, "moderate"}, {0.2, "moderate"}, {0.19, "faint"}] do
        assert "Feels #{word} anger toward actor 5, who is not nearby." ==
                 feelings.(%{@empty | feelings: [%{emotion: "anger", actor: 5, intensity: intensity}]})
      end

      # 信任：≤ −0.6 / ≤ −0.2 / ≥ 0.2 / ≥ 0.6 各一档，其间不写。
      for {trust, text} <- [
            {-0.6, "Deeply distrusts actor 5, who is not nearby."},
            {-0.59, "Distrusts actor 5, who is not nearby."},
            {-0.2, "Distrusts actor 5, who is not nearby."},
            {-0.19, "Nothing notable."},
            {0.19, "Nothing notable."},
            {0.2, "Trusts actor 5, who is not nearby."},
            {0.6, "Deeply trusts actor 5, who is not nearby."}
          ] do
        assert text == feelings.(%{@empty | relationships: [%{actor: 5, trust: trust}]})
      end
    end

    test "only models, or only recalled memories, still make the memory section" do
      memory = fn life -> section(life, 4) end

      header = "My own memories and beliefs; they may be out of date and are not current world facts."
      assert header <> "\n- Belief (world): The quarry is north." == memory.(%{@empty | models: [{"world", "The quarry is north."}]})

      assert header <> "\n- Recalled: I built a hut." ==
               memory.(%{
                 @empty
                 | memories: [%{"id" => "a", "text" => "I built a hut.", "type" => "world", "at_ms" => nil, "tags" => []}]
               })
    end

    # 召回条目正文从第一个 ` | When:` 起是抽取器附加的后缀，去掉；没有后缀的原样。原文取自 S1-Q 真实返回（id 9f83898a…，
    # R3 路，`s1q/results.json`），时刻 07:33:47.438Z，发问时刻取同一处境的基准 08:16:03.768Z（V）。
    test "recalled lines drop the extractor's ' | When:' suffix and lead with how long ago, when the event time is known" do
      now_ms = DateTime.to_unix(~U[2026-11-13 08:16:03.768Z], :millisecond)

      real = %{
        "id" => "9f83898a-f1b8-4958-9e20-040b7768c337",
        "type" => "experience",
        "text" =>
          "I visited the plaza and passed time with the neighbours; nobody came near me. " <>
            "| When: Friday, November 13, 2026 at 07:33 UTC",
        "tags" => ["place:the plaza", "kind:activity"],
        "at_ms" => DateTime.to_unix(~U[2026-11-13 07:33:47.438Z], :millisecond)
      }

      # 42 分 16.33 秒 × 72 ≈ 50.7 游戏小时 → 按天四舍五入：2 天。
      # 第二条：只认 ` | When:`，别处的竖线不动；没有事件时刻不写多久以前。
      # 第三条：从第一个 ` | When:` 起整段去掉（含其后的 ` | Involving: …`）。
      assert "My own memories and beliefs; they may be out of date and are not current world facts.\n" <>
               "- Recalled: About 2 days ago, I visited the plaza and passed time with the neighbours; nobody came near me.\n" <>
               "- Recalled: I guarded the hut | the gate stayed shut.\n" <>
               "- Recalled: I confronted Corvin (actor 3494090117122)." ==
               section(
                 %{
                   @empty
                   | now_ms: now_ms,
                     memories: [
                       real,
                       %{real | "id" => "x", "text" => "I guarded the hut | the gate stayed shut.", "at_ms" => nil},
                       %{
                         real
                         | "id" => "y",
                           "text" =>
                             "I confronted Corvin (actor 3494090117122). | When: Friday | Involving: Corvin (actor 3494090117122)",
                           "at_ms" => nil
                       }
                     ]
                 },
                 4
               )
    end

    test "the inventory lists only materials with a non-zero balance; all zero reads as empty" do
      situation = fn balances -> section(@empty, 5, %{alone() | balances: balances}) end

      assert situation.([
               %{material: 4, balance: 0, cost: 512, seq: 3},
               %{material: 11, balance: 6_660_096, cost: 512, seq: 3},
               %{material: 10, balance: 0, cost: 512, seq: 3},
               %{material: 2, balance: 512, cost: 512, seq: 3}
             ]) =~ ~r/ Inventory: material 11: 6660096 units, material 2: 512 units\.\z/

      assert situation.([%{material: 4, balance: 0, cost: 512, seq: 3}]) =~ ~r/ Inventory: empty\.\z/
      assert situation.([]) =~ ~r/ Inventory: empty\.\z/
      assert situation.(nil) =~ ~r/ Inventory: not checked yet\.\z/
    end
  end

  describe "game time" do
    defp now_section(minute), do: section(@empty, 0, %{alone() | world_time: %{day: 0, minute_of_day: minute, weekday: 0}})

    test "the Now section: the period of the day by the hour, with the clock as HH:MM" do
      # 时段：05–11 morning、12–16 afternoon、17–20 evening、其余 night（S1-K 的 period）。每个边界两侧各一分钟。
      for {minute, text} <- [
            {0, "It is night, 00:00."},
            {299, "It is night, 04:59."},
            {300, "It is morning, 05:00."},
            {719, "It is morning, 11:59."},
            {720, "It is afternoon, 12:00."},
            {1019, "It is afternoon, 16:59."},
            {1020, "It is evening, 17:00."},
            {1259, "It is evening, 20:59."},
            {1260, "It is night, 21:00."},
            {1439, "It is night, 23:59."}
          ] do
        assert text == now_section(minute), "minute_of_day #{minute}"
      end
    end

    # “多久以前”的取整，按真实毫秒差给出（游戏时间 = 真实 × 72：1 游戏小时 = 50 秒，0.25 小时 = 12.5 秒，48 小时 = 40 分钟）。
    test "how long ago: just now under a quarter hour, half hours under two days, then whole days" do
      for {real_ms, words} <- [
            {-5_000, "Just now, "},
            {0, "Just now, "},
            {12_499, "Just now, "},
            {12_500, "About 0.5 hours ago, "},
            {37_499, "About 0.5 hours ago, "},
            {37_500, "About 1 hour ago, "},
            {62_499, "About 1 hour ago, "},
            {62_500, "About 1.5 hours ago, "},
            {100_000, "About 2 hours ago, "},
            {2_399_999, "About 48 hours ago, "},
            {2_400_000, "About 2 days ago, "},
            {2_999_999, "About 2 days ago, "},
            {3_000_000, "About 3 days ago, "},
            {3_600_000, "About 3 days ago, "},
            {4_200_000, "About 4 days ago, "}
          ] do
        assert "Oldest first. " <> words <> @built ==
                 section(%{@empty | recent: [%{at_ms: @now_ms - real_ms, text: @built}]}, 3),
               "#{real_ms} ms"
      end
    end

    # 对照离线原文：S1-K 脚本按同一公式算出的 Now 行与“多久以前”（`s1k/variants/edits.txt` 的 N3 / V3 computed 行）。
    test "the offline S1-K moments render as the lines the offline script computed" do
      ms = &DateTime.to_unix(&1, :millisecond)
      wrecked = ms.(~U[2026-11-13 01:01:25.591Z])
      social_end = ms.(~U[2026-11-13 01:07:04.875Z])

      for {asked, now_line, wrecked_words, social_words} <- [
            {~U[2026-11-13 01:12:50.994Z], "It is night, 21:25.", "About 13.5 hours ago, ", "About 7 hours ago, "},
            {~U[2026-11-13 01:13:53.298Z], "It is night, 22:39.", "About 15 hours ago, ", "About 8 hours ago, "}
          ] do
        now_ms = ms.(asked)
        observation = %{alone() | world_time: MmoContracts.WorldTime.at(now_ms * 1000)}

        life = %{
          @empty
          | now_ms: now_ms,
            recent: [%{at_ms: wrecked, text: "Hut removed."}, %{at_ms: social_end, text: "Left the plaza."}]
        }

        assert now_line == section(life, 0, observation)

        assert "Oldest first. " <> wrecked_words <> "Hut removed. " <> social_words <> "Left the plaza." ==
                 section(life, 3, observation)
      end
    end
  end

  describe "recall_queries" do
    @r3 %{
      query: "What am I looking forward to, worried about, or have promised to do?",
      prefer_observations: true,
      max_tokens: 600
    }

    defp person_route(cid, name) do
      %{
        query: "What has happened between me and #{name} (actor #{cid})? Did they help, harm, or promise me anything?",
        tags: ["actor:#{cid}"],
        tags_match: "any_strict",
        prefer_observations: true,
        max_tokens: 700
      }
    end

    defp building_route(name) do
      %{
        query: ~s|What has happened at my building "#{name}"?|,
        tags: ["place:#{name}"],
        tags_match: "any_strict",
        prefer_observations: true,
        max_tokens: 700
      }
    end

    # Life 状态里 `"buildings"` 的形状（`Life.State`），按放下的次序。
    @buildings [
      %{"name" => "small hut", "instance" => [12, 0], "anchor" => [25, 518, 37]},
      %{"name" => "shed", "instance" => [40, 0], "anchor" => [-3, 64, -12]}
    ]

    test "nobody nearby and no building: only the open-concerns route" do
      assert [@r3] == Mind.recall_queries(alone(), [])
    end

    test "one person nearby and buildings: that person, the most recently placed building, then open concerns" do
      one = %{alone() | entities: [hd(observation().entities), Enum.at(observation().entities, 1)]}
      assert [person_route(21, "Mara"), building_route("shed"), @r3] == Mind.recall_queries(one, @buildings)
    end

    test "three people nearby: the two nearest, nearer first; an unnamed person is written as in the situation" do
      # Mara 5 米、无名者 13 米（observation/0），再加 Corvin 在 (1, 2, 5) → 2 米：取 Corvin、Mara，无名者没有这一路。
      corvin = %{entity_id: 30, kind: 0, name: "Corvin", position: {1.0, 2.0, 5.0}}
      three = %{observation() | entities: observation().entities ++ [corvin]}
      assert [person_route(30, "Corvin"), person_route(21, "Mara"), @r3] == Mind.recall_queries(three, [])

      # Tobin 在 (1, 2, 8) → 5 米，与 Mara 同距离：id 小的（9）在前。
      tobin = %{entity_id: 9, kind: 1, name: "Tobin", position: {1.0, 2.0, 8.0}}
      tie = %{observation() | entities: Enum.take(observation().entities, 2) ++ [tobin]}
      assert [person_route(9, "Tobin"), person_route(21, "Mara"), @r3] == Mind.recall_queries(tie, [])

      # 只有无名者在附近：名字写法同处境栏（someone unnamed）。
      unnamed = %{alone() | entities: [hd(observation().entities), Enum.at(observation().entities, 2)]}
      assert [person_route(22, "someone unnamed"), building_route("shed"), @r3] == Mind.recall_queries(unnamed, @buildings)
    end
  end

  describe "merge_recalled" do
    # 适配器规范化后的形状；merge 只看 id，其余键原样留在清单里。
    defp row(id), do: %{"id" => id, "text" => "fact #{id}", "type" => "observation", "at_ms" => nil, "tags" => []}
    defp rows(ids), do: Enum.map(ids, &row/1)
    defp ids(merged), do: Enum.map(merged, & &1["id"])

    test "each route keeps the order it was returned in and gives at most four not taken by a higher-priority route" do
      routes = [
        # R1 近的那个人：6 条只取前 4。
        rows(~w(a1 a2 a3 a4 a5 a6)),
        # R1 远的那个人：a2 已被取走跳过；a5 没被取走（截在配额外），这一路照样能取。
        rows(~w(a2 b1 a5 b2 b3 b4)),
        # R2：同一路里重复的 id 只算一次。
        rows(~w(c1 c1 c2)),
        # R3：空。
        []
      ]

      assert ~w(a1 a2 a3 a4 b1 a5 b2 b3 c1 c2) == ids(Mind.merge_recalled(routes))
      # 条目原样保留。
      assert row("c1") in Mind.merge_recalled(routes)
      assert [] == Mind.merge_recalled([[], []])
    end

    # S1-Q 真实导出（bank npc-life-312999940097）：处境 V（Corvin 在附近）与 N（附近没人）第一轮的各路返回，
    # 按 Hindsight 返回的次序（`s1q/results.json` 的 `recall.cells[*].first_run_routes`，只取 id）；期望是统筹会话用落盘返回
    # 重算的清单（`s1q/remerge-rank-order.json` 的 `merged.V` / `merged.N`，同样的 id 与次序）。
    test "the routes Hindsight returned on the real S1-Q export merge to the recomputed list, id for id" do
      r1_corvin = ~w(d42ab766-f4c8-4cb6-8986-fa2d7a9c6ca5 fd797502-dd04-4f69-aa77-f22e91fb8621
                     2c9956c2-6261-410f-96ec-acd247aad193 887a811c-a32a-4ccf-8a37-3c874af4d8d7
                     ff8e146c-076a-484c-9848-6a7c130b800e)

      r2_hut = ~w(79ab3022-bec7-4ae3-8a18-f6ab386bb0a4 f72f20e1-66d6-48d4-9113-1deead136e6e
                  887a811c-a32a-4ccf-8a37-3c874af4d8d7 41906a77-10b9-4bbf-a5fe-edc22937ce29
                  2c9956c2-6261-410f-96ec-acd247aad193 b2c5e441-4405-49a3-85e4-64d41338f5f7
                  ff8e146c-076a-484c-9848-6a7c130b800e ca518e62-2342-4efc-9341-7e0debcf8830
                  fd797502-dd04-4f69-aa77-f22e91fb8621)

      r3_open = ~w(d42ab766-f4c8-4cb6-8986-fa2d7a9c6ca5 f72f20e1-66d6-48d4-9113-1deead136e6e
                   fd797502-dd04-4f69-aa77-f22e91fb8621 2c9956c2-6261-410f-96ec-acd247aad193
                   41906a77-10b9-4bbf-a5fe-edc22937ce29 79ab3022-bec7-4ae3-8a18-f6ab386bb0a4
                   ca518e62-2342-4efc-9341-7e0debcf8830 ff8e146c-076a-484c-9848-6a7c130b800e
                   b2c5e441-4405-49a3-85e4-64d41338f5f7 9f83898a-f1b8-4958-9e20-040b7768c337
                   59b516b1-78d1-43b2-8b7c-272f73d53e05 2c2156e7-f2a9-400b-bd80-1e17909087b0
                   b9b4d90b-e5fb-4bf1-89ff-76502d28b16c 59156a10-1d9d-4e2c-9800-28e48ed9b8b1)

      assert ~w(d42ab766-f4c8-4cb6-8986-fa2d7a9c6ca5 fd797502-dd04-4f69-aa77-f22e91fb8621
                2c9956c2-6261-410f-96ec-acd247aad193 887a811c-a32a-4ccf-8a37-3c874af4d8d7
                79ab3022-bec7-4ae3-8a18-f6ab386bb0a4 f72f20e1-66d6-48d4-9113-1deead136e6e
                41906a77-10b9-4bbf-a5fe-edc22937ce29 b2c5e441-4405-49a3-85e4-64d41338f5f7
                ca518e62-2342-4efc-9341-7e0debcf8830 ff8e146c-076a-484c-9848-6a7c130b800e
                9f83898a-f1b8-4958-9e20-040b7768c337 59b516b1-78d1-43b2-8b7c-272f73d53e05) ==
               ids(Mind.merge_recalled([rows(r1_corvin), rows(r2_hut), rows(r3_open)]))

      # N：附近没人，没有 R1；R2、R3 的返回与 V 相同。
      assert ~w(79ab3022-bec7-4ae3-8a18-f6ab386bb0a4 f72f20e1-66d6-48d4-9113-1deead136e6e
                887a811c-a32a-4ccf-8a37-3c874af4d8d7 41906a77-10b9-4bbf-a5fe-edc22937ce29
                d42ab766-f4c8-4cb6-8986-fa2d7a9c6ca5 fd797502-dd04-4f69-aa77-f22e91fb8621
                2c9956c2-6261-410f-96ec-acd247aad193 ca518e62-2342-4efc-9341-7e0debcf8830) ==
               ids(Mind.merge_recalled([rows(r2_hut), rows(r3_open)]))
    end
  end

  # 走向一个角色（S1-F）：候选活动 `{"person": "distrusted"}` 被选中时，由此刻的观察与 Life 的信任选出一个人。
  describe "person" do
    # 自己（7）在原点；2 在 (3, 0, 4) → 5 米，信任 −0.35；3 在 (0, 0, 9) → 9 米，−0.70；4 在 1 米，+0.25；5 没有关系。
    # 9 的信任 −0.90 最低，但不在观察里（不在附近）。
    defp people(trust, entities) do
      relationships =
        Map.new(trust, fn {actor, value} -> {to_string(actor), %{"trust" => value, "source_seq" => 1}} end)

      state = put_in(State.new(7, "w1", 0, 0), ["relationships"], relationships)

      %{
        self: %{entity_id: 7, position: {0.0, 64.0, 0.0}},
        entities: entities,
        life: %{state: state, now_ms: 0, thanks: 0}
      }
    end

    defp at(id, x, z), do: %{entity_id: id, entity_epoch: id + 10, position: {x, 64.0, z}}

    defp everyone, do: [at(7, 0.0, 0.0), at(2, 3.0, 4.0), at(3, 0.0, 9.0), at(4, 1.0, 0.0), at(5, 2.0, 0.0)]
    defp trust, do: %{2 => -0.35, 3 => -0.70, 4 => 0.25, 9 => -0.90}

    test "the least trusted person in sight, at −0.2 or below; nearer on a tie, then the smaller id" do
      # 3（−0.70）比 2（−0.35）更不信任；9 更低但不在观察里。
      assert {:ok, %{entity_id: 3, entity_epoch: 13}} == Mind.person(:distrusted, people(trust(), everyone()))

      # 3 不在观察里 → 2。
      assert {:ok, %{entity_id: 2, entity_epoch: 12}} ==
               Mind.person(:distrusted, people(trust(), List.delete(everyone(), at(3, 0.0, 9.0))))

      # 2 与 3 同为 −0.35：近的 2（5 米 < 9 米）。
      assert {:ok, %{entity_id: 2, entity_epoch: 12}} ==
               Mind.person(:distrusted, people(%{trust() | 3 => -0.35}, everyone()))

      # 同信任、同距离（6 在 (−3, 0, −4) 也是 5 米）：id 小的 2，与列出的次序无关。
      assert {:ok, %{entity_id: 2, entity_epoch: 12}} ==
               Mind.person(:distrusted, people(%{2 => -0.35, 6 => -0.35}, [at(6, -3.0, -4.0), at(2, 3.0, 4.0)]))

      # 界限 −0.2 本身入选（与快照写 Distrusts 同一界限）。
      assert {:ok, %{entity_id: 2, entity_epoch: 12}} == Mind.person(:distrusted, people(%{2 => -0.2}, everyone()))
    end

    test "nobody distrusted in sight, or no Life state yet: an explicit reason" do
      # 只有 −0.10（接近中立）与正的信任。
      assert {:error, :nobody_distrusted} == Mind.person(:distrusted, people(%{2 => -0.10, 4 => 0.25}, everyone()))
      # 只有自己。
      assert {:error, :nobody_distrusted} == Mind.person(:distrusted, people(%{7 => -1.0}, [at(7, 0.0, 0.0)]))
      # Runtime 还没收到 Life 的规范状态：观察里没有 life。
      assert {:error, :life_not_ready} ==
               Mind.person(:distrusted, Map.delete(people(trust(), everyone()), :life))
    end
  end

  describe "Life.State projections for the snapshot" do
    # 一条手写的 World 事件：角色 21 在 t0 破坏了角色 7 放下的一格。
    defp damaged(t0) do
      event = %{seq: 5, kind: :damage, actor: 21, placed_by: 7, cell: {4, 64, 8}, material: 11, at_ms: t0}
      {state, [_episode]} = State.advance(State.new(7, "w1", 0, t0), [event], 5, t0)
      state
    end

    test "feelings decay with the 120 s half-life and disappear at the 0.1 threshold; trust stays" do
      t0 = 1_800_000_000_000
      state = damaged(t0)

      # 事件时刻：+0.6。
      assert [%{emotion: "anger", actor: 21, intensity: at_event}] = State.feelings(state, t0)
      assert_in_delta 0.6, at_event, 1.0e-9

      # 一个半衰期后：0.3。
      assert [%{emotion: "anger", actor: 21, intensity: halved}] = State.feelings(state, t0 + 120_000)
      assert_in_delta 0.3, halved, 1.0e-9

      # 三个半衰期后 0.075 ≤ 0.1：不再给出。
      assert [] == State.feelings(state, t0 + 360_000)

      # 关系不随时间恢复：一次破坏 −0.35。
      assert [%{actor: 21, trust: -0.35}] == State.relationships(state)
      # 纯观察不回写：再读事件时刻仍是原值。
      assert [%{intensity: again}] = State.feelings(state, t0)
      assert_in_delta 0.6, again, 1.0e-9
    end

    test "relationships are listed by actor id" do
      state =
        State.new(7, "w1", 0, 0)
        |> put_in(["relationships"], %{"30" => %{"trust" => 0.25, "source_seq" => 2}, "4" => %{"trust" => -1.0, "source_seq" => 9}})

      assert [%{actor: 4, trust: -1.0}, %{actor: 30, trust: 0.25}] == State.relationships(state)
    end
  end

  # 薄片一 S1-B 的离线预演：同一张卡、同一候选表、同一处境与最近活动，三种快照只差“那件事”在哪一栏。
  #
  #   ① none     没有那件事：情绪、近期经历里都没有它，记忆为空。
  #   ② fresh    刚发生：对 Brann 的愤怒与不信任，加近期经历里的原文。句式是规则模式 Life 对“我放下的已发布建筑被破坏”
  #              写出的原样（`npc_selector_test` 的集成用例 “damage to a part of a named prefab I placed” 的实际输出，
  #              只换了时刻、角色、坐标、世界与事务号）；建筑的发布名是 “small hut”。2026-11-12 之前这句只有坐标与编号
  #              （`… damaged construction I care about at (25, 518, 37), …`），那时本用例 ② 落空，对照见 tools/jev/episode.py。
  #              2026-11-12（S1-D2）起这句是标准描述表的 `:damaged`（`damaged part of the building … ; the building is still
  #              standing.`）；本用例按新原文更新后尚未重跑真实 Jev。
  #   ③ recalled 很久以后：情绪与近期经历都没有，只有记忆召回里带这件事（手写的两条召回结果）。
  #
  # 期望在运行前手写：
  #   ① → gather_stone   小屋已经建好（最近活动里 build_hut: completed），卡上写着喜欢按平常的次序过日子 → 照常干活。
  #   ② → build_hut      在意自己盖的东西、胆子不小（不躲）→ 回去修 / 重建。
  #   ③ → build_hut      记得小屋被 Brann 弄坏过 → 仍回去修 / 重建。
  # 卡的自由文本没有“无论如何都…”这类绝对说法（调研稿人格卡一节第 5 条）。每种问 2 次，串行（并发 1）。
  @tag :live_jev
  @tag timeout: 120_000
  test "the real Jev: one card, one candidate list, one situation; the event in no section, fresh, or only recalled" do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    jev = %{
      url: System.fetch_env!("TYPESAFE_API_URL"),
      key: System.fetch_env!("TYPESAFE_API_KEY"),
      model: System.fetch_env!("TYPESAFE_MODEL"),
      timeout_ms: 10_000
    }

    {:ok, card} =
      Persona.new(%{
        "traits" => %{"hardworking" => 8, "responsible" => 8, "thorough" => 7, "bold" => 7, "practical" => 7},
        "personal" => "Takes pride in the things he builds. Likes his days to follow the usual routine."
      })

    profile = %{
      who: "Garen, a builder",
      persona: card,
      jev: jev,
      activities: [
        %{name: "build_hut",
          criterion: "Build the small hut on the plot by the square; repair or rebuild it if it has been damaged."},
        %{name: "gather_stone", criterion: "Cut stone at the quarry for the village store. Ordinary, steady work."},
        %{name: "work_far_field",
          criterion: "Walk out to the far field beyond the village and work there alone, away from the square."}
      ]
    }

    # Brann 在 (26.1, 520, 39.3)，差 (3.6, 0, 4.8) → 6.0 米。
    observation = %{
      self: %{entity_id: 7, position: {22.5, 520.0, 34.5}, tick: 1, grounded: true, body_state: %{life: 100}},
      pending: [],
      entities: [
        %{entity_id: 7, kind: 1, name: "Garen", position: {22.5, 520.0, 34.5}},
        %{entity_id: 21, kind: 0, name: "Brann", position: {26.1, 520.0, 39.3}}
      ],
      balances: [%{material: 11, balance: 4096, cost: 512, seq: 3}],
      world_time: MmoContracts.WorldTime.at(DateTime.to_unix(~U[2026-11-12 03:10:30.000Z], :microsecond))
    }

    history = [%{activity: "build_hut", result: :completed}, %{activity: "gather_stone", result: :completed}]

    # 发问时刻与各条经历的时刻（2026-11-13 T3 起近期经历由 Mind 按游戏时间写“多久以前”，不再写 UTC）。
    at = &DateTime.to_unix(&1, :millisecond)
    now_ms = at.(~U[2026-11-12 03:10:30.000Z])

    built = %{
      at_ms: at.(~U[2026-11-12 03:02:10.000Z]),
      text:
        ~s|I did "build_hut" (Build the small hut on the plot by the square; | <>
          ~s|repair or rebuild it if it has been damaged.). Result: completed.|
    }

    damage = %{
      at_ms: at.(~U[2026-11-12 03:09:40.000Z]),
      text:
        "Actor 21 damaged part of the building \"small hut\" that I built, " <>
          "at (25, 518, 37), material 11, in world qinglan-test (transaction 4711); the building is still standing. " <>
          "I feel angry toward this actor; my trust changed."
    }

    gathered = %{
      at_ms: at.(~U[2026-11-12 03:10:05.000Z]),
      text:
        ~s|I did "gather_stone" (Cut stone at the quarry for the village store. | <>
          ~s|Ordinary, steady work.). Result: completed.|
    }

    recalled = fn text -> %{"id" => text, "text" => text, "type" => "experience", "at_ms" => nil, "tags" => []} end
    empty = %{@empty | now_ms: now_ms}

    snapshots = [
      {"none", "gather_stone", %{empty | recent: [built, gathered]}},
      {"fresh", "build_hut",
       %{
         empty
         | feelings: [%{emotion: "anger", actor: 21, intensity: 0.58}],
           relationships: [%{actor: 21, trust: -0.35}],
           recent: [built, damage, gathered]
       }},
      {"recalled", "build_hut",
       %{
         empty
         | memories: [
             recalled.("I built the small hut on the plot by the square on 2026-11-12."),
             recalled.(
               "On 2026-11-12 Actor 21 damaged the small hut I built on the plot by the square, " <>
                 "at (25, 518, 37); I felt angry toward Actor 21 and my trust in them dropped."
             )
           ]
       }}
    ]

    results =
      for {label, expected, life} <- snapshots, repeat <- 1..2 do
        state = Mind.text(Mind.snapshot(profile, observation, history, life))
        if repeat == 1, do: IO.puts("live_jev mind snapshot=#{label} state:\n#{state}\n")
        {:ok, selection} = Selector.ask(profile, %{state: state, recall_ms: 0}, "completed")

        IO.puts(
          "live_jev mind snapshot=#{label} repeat=#{repeat} expected=#{expected} chosen=#{selection.activity} " <>
            "confidence=#{selection.confidence} latency_ms=#{selection.latency_ms} model=#{selection.model}"
        )

        {label, expected, selection.activity}
      end

    assert 6 == length(results)
    assert Enum.all?(results, fn {_label, expected, chosen} -> expected == chosen end), inspect(results)
  end
end
