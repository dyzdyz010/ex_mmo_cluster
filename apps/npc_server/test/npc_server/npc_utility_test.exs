defmodule NpcServer.NpcUtilityTest do
  @moduledoc """
  只测试：效用选择器的纯规则与 Scheduler／Tree 接缝。不启动网络、不调用模型。
  期望值来自手算的小例子和声明的不变量（惯性区间、紧急覆盖、次序平局），不复用被测打分代码生成期望。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias NpcServer.{Scheduler, Utility}
  alias NpcServer.Brain.Tree
  alias NpcServer.Life.State

  @acts ["avoid", "work", "rest", "social"]
  @day Utility.default_schedule()
  @day_ms 1_440_000

  defp inputs(slot, mode \\ :work, nearby \\ false), do: %{slot: slot, mode: mode, nearby: nearby}

  describe "choose/3" do
    test "休息时段无威胁：选 rest" do
      {chosen, _} = Utility.choose(@acts, inputs(%{"rest" => 0.8, "work" => 0.2, "social" => 0.1}), nil)
      assert chosen == "rest"
    end

    test "分差小于惯性：留在正在做的活动；分差大于惯性：切换" do
      gap = Utility.inertia() / 2
      stay = inputs(%{"work" => 0.5, "rest" => 0.5 + gap})
      assert {"work", _} = Utility.choose(@acts, stay, "work")

      big = Utility.inertia() * 2
      go = inputs(%{"work" => 0.5, "rest" => 0.5 + big})
      assert {"rest", _} = Utility.choose(@acts, go, "work")
    end

    test "紧急覆盖：惯性本可留住 social，但 avoid 达到紧急线时必须选 avoid" do
      # social 1.4 + 惯性 > avoid 威胁分 1.5；没有紧急覆盖就会留下。
      slot = %{"social" => 1.4}
      assert {"avoid", _} = Utility.choose(@acts, inputs(slot, :avoid), "social")
      assert {"social", _} = Utility.choose(@acts, inputs(slot, :work), "social")
    end

    test "平局按活动列表次序，靠前者胜；次序反过来结果反过来" do
      tie = inputs(%{})
      assert {"work", _} = Utility.choose(["work", "rest"], tie, nil)
      assert {"rest", _} = Utility.choose(["rest", "work"], tie, nil)
    end

    test "感谢来源在场：social 的分数高于同时段的 work" do
      # 时段 work 0.8；感谢加成使 social 0.3 + thank > 0.8（thank 在 0.5 以上即成立）。
      slot = %{"work" => 0.8, "social" => 0.3}
      assert {"social", _} = Utility.choose(@acts, inputs(slot, :thank), nil)
      assert {"work", _} = Utility.choose(@acts, inputs(slot, :work), nil)
    end
  end

  describe "slot/3" do
    test "游戏时刻由 now_ms 对 day_ms 取余，按日程千分位落段" do
      # 0.10 日 = 夜间 rest 段；0.40 日 = 白天 work 段；跨日同样成立。
      assert %{"rest" => 0.8} = Map.take(Utility.slot(@day, @day_ms, 144_000), ["rest"])
      assert %{"work" => 0.8} = Map.take(Utility.slot(@day, @day_ms, 576_000), ["work"])
      assert %{"work" => 0.8} = Map.take(Utility.slot(@day, @day_ms, 3 * @day_ms + 576_000), ["work"])
    end
  end

  describe "decide/2 与 Scheduler" do
    setup do
      Logger.put_module_level(Utility, :info)
      on_exit(fn -> Logger.delete_module_level(Utility) end)
    end

    test "愤怒 0.9 且来源在 5 米内：中断为 avoid" do
      now = 576_000
      obs = observation(angry(now, 0.9), now, {3.0, 64.0, 0.0})
      assert {:interrupt, "avoid"} == Utility.decide(%{skill: "build", observation: obs, heard: []}, %{})
    end

    test "夜间、无威胁：把正在做的 work 中断为 rest" do
      now = 144_000
      obs = observation(calm(now), now, nil)
      assert {:interrupt, "rest"} == Utility.decide(%{skill: "build", observation: obs, heard: []}, %{})
    end

    test "白天、无威胁：继续" do
      now = 576_000
      obs = observation(calm(now), now, nil)
      assert :continue == Utility.decide(%{skill: "build", observation: obs, heard: []}, %{})
    end

    test "每次决定一行 npc_utility_decision，且不经过任何请求函数" do
      now = 576_000
      obs = observation(calm(now), now, nil)

      log =
        capture_log([level: :info], fn ->
          Utility.decide(%{skill: "build", observation: obs, heard: []}, %{})
        end)

      assert log =~ "npc_utility_decision cid=1 current=work chosen=work switched=false plan_source=authored scores="
      assert log =~ "avoid:0.0,work:0.8"
    end

    test "没有配置 interrupt_policy：Scheduler 不创建策略（现有行为不变）" do
      assert nil == Scheduler.configured(%{})
      assert {Utility, %{}} == Scheduler.configured(%{interrupt_policy: {Utility, %{}}})
    end
  end

  describe "Tree 根部守卫" do
    test "同一棵树：状态变化后选中的分支改变" do
      cfg = %{}
      tree = {:sel, [
        Utility.gate("avoid", {:act, "travel", %{"x" => -10, "z" => 0}}, cfg),
        Utility.gate("work", {:act, "travel", %{"x" => 10, "z" => 0}}, cfg)
      ]}

      profile = %{tree: fn _ -> {tree, %{}} end, tools: %{}, skills: %{travel: %{}}}
      now = 576_000

      {[calm_cmd], _} =
        Tree.handle_event({:observation, observation(calm(now), now, nil)}, Tree.init(profile))

      {[angry_cmd], _} =
        Tree.handle_event(
          {:observation, observation(angry(now, 0.9), now, {3.0, 64.0, 0.0})},
          Tree.init(profile)
        )

      assert %{skill: :travel, args: %{"x" => 10}} = calm_cmd
      assert %{skill: :travel, args: %{"x" => -10}} = angry_cmd
    end
  end

  describe "Trees.settler_daily" do
    @hex String.duplicate("AB", 32)
    @site %{anchor_micro: [64, 512, 112], orientation: 0, stand: [8.5, 11.5]}
    @home [-20, 5]
    @plaza [30.0, -4.0]

    defp daily,
      do:
        Tree.init(%{
          tree: &NpcServer.Trees.settler_daily/1,
          definition: @hex,
          sites: [@site],
          revisit_ticks: 600,
          tools: %{},
          skills: %{build: %{}, gather: %{}, travel: %{}},
          home: @home,
          plaza: @plaza,
          utility: %{}
        })

    defp at(now, tick) do
      {:observation, %{observation(calm(now), now, nil) | self: %{entity_id: 1, tick: tick, position: {0.0, 64.0, 0.0}}}}
    end

    test "夜里（日程 rest 段）第一条命令是回家；回家后等一个节拍，到白天再开始原 Settler 的第一步" do
      # 144_000 ms = 千分位 100，落在 0–250 的 rest 段；576_000 = 400，落在 work 段。
      {[home], state} = Tree.handle_event(at(144_000, 1), daily())
      assert %{verb: :skill, skill: :travel, args: %{"x" => -20, "z" => 5}} = home

      {[], state} = Tree.handle_event(done(home.id, :travel), state)

      # 回家后的等待（600 tick）从 tick 1 起算，在 tick 601 到期；等待到期后要再来一个事件才开下一轮，
      # 白天的这两个事件里应出现且只出现一条 read_catalog。
      {c1, state} = Tree.handle_event(at(576_000, 700), state)
      {c2, _} = Tree.handle_event(at(576_000, 701), state)
      assert [%{verb: :read_catalog}] = c1 ++ c2
    end

    test "白天直接开始工作，与未加守卫的 settler 第一条命令相同" do
      {[plain], _} =
        Tree.handle_event(
          at(576_000, 1),
          Tree.init(%{
            tree: &NpcServer.Trees.settler/1,
            definition: @hex,
            sites: [@site],
            revisit_ticks: 600,
            tools: %{},
            skills: %{build: %{}, gather: %{}, travel: %{}}
          })
        )

      {[gated], _} = Tree.handle_event(at(576_000, 1), daily())
      assert Map.delete(gated, :id) == Map.delete(plain, :id)
    end

    # 回归（2026-11-10 本机实跑）：work 分支曾是 settler/1 的 repeat :forever，一轮做完不回根，
    # 时段换到 rest 后仍反复开新一轮。没有工地时一轮 = read_catalog + 回访等待。
    test "一轮工作做完、等待到期后回到选择器：已到 rest 段就不再开新一轮" do
      state =
        Tree.init(%{
          tree: &NpcServer.Trees.settler_daily/1,
          definition: @hex,
          sites: [],
          revisit_ticks: 10,
          tools: %{},
          skills: %{build: %{}, gather: %{}, travel: %{}},
          home: @home,
          plaza: @plaza,
          utility: %{}
        })

      {[%{id: id, verb: :read_catalog}], state} = Tree.handle_event(at(576_000, 1), state)

      {[], state} =
        Tree.handle_event(
          {:outcome, %{id: id, verb: :read_catalog, status: :done, reason: nil, data: %{}}},
          state
        )

      # 回访等待（10 tick）在 tick 20 已到期；此时日程是 rest 段：不再开新一轮工作，而是回家。
      {c1, state} = Tree.handle_event(at(144_000, 20), state)
      {c2, _} = Tree.handle_event(at(144_000, 21), state)
      assert [%{verb: :skill, skill: :travel, args: %{"x" => -20, "z" => 5}}] = c1 ++ c2
    end

    # social 段：日程 700–850 千分位；1_080_000 ms = 千分位 750。
    @evening 1_080_000

    defp social_at(tick, others) do
      {:observation,
       %{
         observation(calm(@evening), @evening, nil)
         | self: %{entity_id: 1, tick: tick, position: {0.0, 64.0, 0.0}},
           entities: others
       }}
    end

    defp done(id, verb),
      do: {:outcome, %{id: id, verb: verb, status: :done, reason: nil, data: %{}}}

    test "social：走到最近的人前方 2 米（沿水平连线），然后说台词表第一句" do
      # 自己在 (0, 0)；玩家 7 在 (6, 8)，水平距离 10 → 停在 8/10 处 = (4.8, 6.4)。NPC 9 在 (0, 20) 更远，不选。
      others = [
        %{entity_id: 9, kind: 1, position: {0.0, 64.0, 20.0}},
        %{entity_id: 7, kind: 0, position: {6.0, 70.0, 8.0}}
      ]

      {[move], state} = Tree.handle_event(social_at(1, others), daily())
      assert %{verb: :move_to, position: {x, z}} = move
      assert_in_delta x, 4.8, 1.0e-9
      assert_in_delta z, 6.4, 1.0e-9

      {[say], _} = Tree.handle_event(done(move.id, :move_to), state)
      assert %{verb: :say, text: "今天天气不错。", target_id: 0, conversation_id: 0} = say
    end

    test "social：台词按列表次序轮换；被 Scene 拒绝时不换句；说完末句回到第一句" do
      lines = ["今天天气不错。", "最近还顺利吗？", "我刚忙完一阵。", "这附近挺安静的。", "有空一起歇会儿。"]
      assert NpcServer.Trees.lines() == lines
      others = [%{entity_id: 7, kind: 0, position: {1.0, 64.0, 0.0}}]

      # 每轮：观察 → move_to（已在 2 米内，原地）→ done → say → 结果 → 等 600 tick → 下一轮。
      round = fn state, tick, result ->
        {[move], state} = Tree.handle_event(social_at(tick, others), state)
        assert %{verb: :move_to, position: {+0.0, +0.0}} = move
        {[say], state} = Tree.handle_event(done(move.id, :move_to), state)

        outcome =
          case result do
            :done -> %{id: say.id, verb: :say, status: :done, reason: nil, data: %{text: say.text}}
            reason -> %{id: say.id, verb: :say, status: :rejected, reason: reason, data: nil}
          end

        {[], state} = Tree.handle_event({:outcome, outcome}, state)
        # 等待从 tick 起 600 tick 后到期，再来一个事件开下一轮。
        {[], state} = Tree.handle_event(social_at(tick + 600, others), state)
        {say.text, state}
      end

      {said, _} =
        Enum.map_reduce(
          [:done, :topic_rate_limited, :done, :done, :done, :done, :done],
          {daily(), 1},
          fn result, {state, tick} ->
            {text, state} = round.(state, tick, result)
            {text, {state, tick + 601}}
          end
        )

      assert said == [
               "今天天气不错。",
               "最近还顺利吗？",
               "最近还顺利吗？",
               "我刚忙完一阵。",
               "这附近挺安静的。",
               "有空一起歇会儿。",
               "今天天气不错。"
             ]
    end

    test "social：观察里没有别人时去广场" do
      {[plaza], _} = Tree.handle_event(social_at(1, []), daily())
      assert %{verb: :skill, skill: :travel, args: %{"x" => 30.0, "z" => -4.0}} = plaza
    end
  end

  # 夹具：与 npc_social_test 同款，actor 3 毁坏了 NPC（cid 1）放置的格。
  defp angry(now, anger) do
    {state, _} =
      State.advance(
        State.new(1, "world", 0, now),
        [%{seq: 1, at_ms: now, actor: 3, kind: :damage, cell: {0, 64, 1}, material: 11, placed_by: 1}],
        1,
        now
      )

    put_in(state, ["emotions", "anger"], anger)
  end

  defp calm(now), do: State.new(1, "world", 0, now)

  defp observation(state, now, other_position) do
    %{
      self: %{entity_id: 1, tick: 1, position: {0.0, 64.0, 0.0}},
      entities: if(other_position, do: [%{entity_id: 3, position: other_position}], else: []),
      life: %{state: state, now_ms: now},
      pending: []
    }
  end
end
