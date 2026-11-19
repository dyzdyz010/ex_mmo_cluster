defmodule NpcServer.NpcOffersTest do
  @moduledoc """
  只测试：统一形态的候选覆盖登记与生成器 `NpcServer.Offers`（稿 A `docs/10-active/cross-cutting/2026-11-18-npc-full-capability-coverage-decision.md`
  §4 A-1、A-2，批 0a；测试矩阵 T-A1、T-A2）。

  契约：
  - **覆盖登记完整（T-A1）**：`Offers.coverage/0` 的键恰是“全授予 profile”算出的 `Abilities.entries/1` 名字集合；每个条目只归一类
    （`{:offer, 生成器}` / `{:inside, [技能]}` / `{:withheld, 理由}`）；offer 的生成器是 `Offers` 导出的二元函数；withheld 理由非空；
    inside 点名的技能本身在集合里且是 offer。常驻反例：经现有 `skills:` 扩展点加一个测试技能，差集恰为它（新增能力不登记即红）。
    **覆盖边界**：“全授予 profile”只拼得出现有的授予方式——工具带（`tools`）、法术带（`spells`）、创世（`genesis`）、技能（`skills`）
    与候选表（`activities`）。能力库若新增别的授予方式（profile 里一个新键才放出的条目），这里拼不出它，覆盖测试也就看不见；
    加授予方式时要同时把它加进 `full_profile/0`。
  - **候选只从覆盖登记生成**：`Offers.generators/1` 取登记里 offer 一类的生成器（去重、按名字排序），`candidates/4` 只按它生成；
    次序锁定为登记项在前、说话在后；把条目改成 withheld，它的生成器（没有别的 offer 共用时）就消失。用参数化的登记表测这个纯函数，
    生产代码不为测试加开关。真实 Scene 求交后的整轮候选次序另由 `npc_selector_test` 的真实 Runtime 用例（`npc_select … candidates=…` 日志）锁定。
  - **批 0 不改行为**：offer 只有 build / gather / expand / travel（登记项生成器 `registered/2`）与 speak（`speak_to/2`）。
  - **生成器（T-A2）**：`registered/2` 按建筑条件保序过滤（从 `Selector` 迁来，期望照迁移前的输出手写）；`speak_to/2` 与 `reply/2`
    （从 `Dialogue.topic_candidates/2`、`Dialogue.reply_candidate/2` 迁来）的范围、自身排除、观察次序、目标冻结、`speak_to:<id>` 的避让。
    所有候选都带 `kind` 与 `object`（登记项 `kind` = 候选名、`object` = nil；说话项 `kind` = `"speak_to"`、`object` = `%{"actor" => cid}`），
    说话项保留 `target`（Runtime 交给 speak 技能的参数，`runtime.ex` 的 `finish_select/2` 读它）。

  层次与替身：纯函数，直接构造输入（profile、观察、Life 的建筑视图与来话都按产品形状手写：观察同 `Body.observe/1`，
  建筑同 `Life.mind/2` 的 `buildings`，来话同 Scene 交给 Runtime 的 Speech）。不启动 World、Scene、Life 或数据库。
  说话范围读 Scene 的唯一参数 `SceneServer.Dialogue.limits/0`，不在测试里另写一个数。
  不证明：候选进请求体的字节（`npc_selector_test` 的 request body 用例）、Scene 新话题冷却的求交（`npc_registry_test` 的真实对话用例）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias NpcServer.{Abilities, Offers, Skills}

  # 作者法术带（同 npc_abilities_test：Test-only 魔法目录的预设 ignite_near 原样）。
  @ignite ~s({"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":"act.heat","args":{"energy_j":400000,"power_w":200000}}]})

  defmodule ProbeSkill do
    @moduledoc "只测试：最小的自定义技能，经 profile 的 `skills:` 扩展点（`%{module: 模块}`）加进条目，作覆盖登记的常驻反例。"
    @behaviour NpcServer.Skill

    @impl true
    def definition(_profile),
      do: %{
        description: "只测试的技能。",
        parameters: %{type: "object", properties: %{}, required: [], additionalProperties: false}
      }

    @impl true
    def run(_context, _args, _config),
      do: {:ok, %{metrics: %{request_count: 0, jev_request_count: 0}}}
  end

  # 全授予 profile（`Abilities.entries/1` 的契约就是 profile map）：工具带、法术带、创世、全部内置技能（`Skills.builtin_names/0`，
  # 新增内置技能自动进来），以及非空的候选表（让 choose_activity 进集合）。候选的形状同 `Registry.brain("npc", _)` 构造的。
  defp full_profile do
    %{
      tools: %{1 => "镐", 9 => "点火器"},
      spells: %{"ignite" => @ignite},
      genesis: true,
      skills: Map.new(Skills.builtin_names(), &{&1, %{}}),
      activities: [
        %{
          name: "rest_at_home",
          criterion: "Go home and rest.",
          run: {:place, [2, -3.5], 600},
          place_name: nil
        }
      ]
    }
  end

  defp entry_names(profile), do: profile |> Abilities.entries() |> Enum.map(& &1.name)

  describe "coverage/0（T-A1）" do
    test "登记的键恰是全授予 profile 的条目名集合：不多不少" do
      names = entry_names(full_profile())
      registered = Map.keys(Offers.coverage())

      assert names -- registered == [], "未登记的能力条目：#{inspect(names -- registered)}"
      assert registered -- names == [], "登记了却不存在的条目：#{inspect(registered -- names)}"
    end

    test "常驻反例：经 skills 扩展点加一个未登记的测试技能，差集恰为它" do
      full = full_profile()
      profile = %{full | skills: Map.put(full.skills, :offers_probe, %{module: ProbeSkill})}

      assert entry_names(profile) -- Map.keys(Offers.coverage()) == ["offers_probe"]
    end

    test "每个条目只归三类之一；offer 的生成器已导出为二元函数；withheld 理由非空；inside 的技能在集合里且是 offer" do
      coverage = Offers.coverage()
      Code.ensure_loaded!(Offers)

      for {name, class} <- coverage do
        case class do
          {:offer, generator} when is_atom(generator) ->
            assert function_exported?(Offers, generator, 2),
                   "#{name} 的生成器 Offers.#{generator}/2 没有导出"

          {:withheld, reason} when is_binary(reason) ->
            assert String.trim(reason) != "", "#{name} 的不给理由为空"

          {:inside, [_ | _] = skills} ->
            for skill <- skills do
              assert {:offer, _} = Map.get(coverage, Atom.to_string(skill)),
                     "#{name} 归 inside #{inspect(skill)}，但该技能不在登记里或不是 offer"
            end

          other ->
            flunk("#{name} 的归类不是三类之一：#{inspect(other)}")
        end
      end
    end

    test "批 0 不改行为：offer 恰为四个登记技能（registered/2）与 speak（speak_to/2）" do
      offers =
        for {name, {:offer, generator}} <- Offers.coverage(), into: %{}, do: {name, generator}

      assert offers == %{
               "build" => :registered,
               "gather" => :registered,
               "expand" => :registered,
               "travel" => :registered,
               "speak" => :speak_to
             }
    end
  end

  # 评审修正：`candidates/4` 原来写死 `registered ++ speak`、不读 `coverage/0`，登记表与真实候选来源是两份互不约束的事实。
  describe "generators/1：候选只从覆盖登记生成" do
    test "现在的登记：[:registered, :speak_to]——登记项在前、说话在后；四个登记技能共用的生成器只出现一次" do
      assert Offers.generators(Offers.coverage()) == [:registered, :speak_to]
    end

    test "把 speak 改成 withheld：说话生成器消失，它的候选不再出现" do
      coverage = Map.put(Offers.coverage(), "speak", {:withheld, "只测试：不给说话。"})
      assert Offers.generators(coverage) == [:registered]
    end

    test "登记项的生成器由四个条目共用：只改一个仍在（过渡形态），四个都改成 withheld 才消失" do
      withhold = fn coverage, names ->
        Enum.reduce(names, coverage, &Map.put(&2, &1, {:withheld, "只测试。"}))
      end

      assert Offers.generators(withhold.(Offers.coverage(), ["build"])) == [
               :registered,
               :speak_to
             ]

      all_four = withhold.(Offers.coverage(), ["build", "gather", "expand", "travel"])
      assert Offers.generators(all_four) == [:speak_to]
    end

    test "次序与登记表的遍历次序无关；inside / withheld 条目不产生生成器" do
      coverage = [
        {"speak", {:offer, :speak_to}},
        {"say", {:inside, [:speak]}},
        {"travel", {:offer, :registered}},
        {"eat", {:withheld, "只测试。"}},
        {"build", {:offer, :registered}}
      ]

      assert Offers.generators(coverage) == [:registered, :speak_to]
      assert Offers.generators(Enum.reverse(coverage)) == [:registered, :speak_to]
    end
  end

  # —— 生成器（T-A2） ——

  # 登记候选：形状同 `Registry.brain("npc", _)` 构造的（name / criterion / run / place_name，place 项可带 requires_building）。
  @gather %{
    name: "gather_stone",
    criterion: "Cut stone at the quarry.",
    run:
      {:skill, "gather",
       %{"box" => [[10, 64, 4], [13, 64, 6]], "material" => 11, "units" => 512, "tool_id" => 1}},
    place_name: nil
  }
  @guard_hut %{
    name: "guard_hut",
    criterion: "Stand beside the small hut for a while and keep an eye on it.",
    run: {:place, [25, 36], 600},
    place_name: "the small hut",
    requires_building: "small hut"
  }
  @guard_shed %{
    name: "guard_shed",
    criterion: "Stand beside the shed.",
    run: {:place, [-3, -12], 600},
    place_name: "the shed",
    requires_building: "shed"
  }
  @rest %{
    name: "rest_at_home",
    criterion: "Go home and rest.",
    run: {:place, [2, -3.5], 600},
    place_name: "home"
  }

  describe "registered/2" do
    test "保序筛掉建筑条件不满足的项；留下的原样加 kind（= 候选名）与 object（nil）" do
      registered = [@gather, @guard_shed, @guard_hut, @rest]
      # Life.mind/2 的 buildings：小屋站着，棚子倒了。
      buildings = [
        %{name: "small hut", anchor: {25, 518, 37}, standing: true},
        %{name: "shed", anchor: {-3, 64, -12}, standing: false}
      ]

      assert Offers.registered(registered, buildings) == [
               Map.merge(@gather, %{kind: "gather_stone", object: nil}),
               Map.merge(@guard_hut, %{kind: "guard_hut", object: nil}),
               Map.merge(@rest, %{kind: "rest_at_home", object: nil})
             ]
    end

    test "同名建筑有一座站着就列；一座都没有（含没有建筑）就不列；没有建筑条件的项总在" do
      registered = [@guard_hut, @rest]

      two_huts = [
        %{name: "small hut", anchor: {25, 518, 37}, standing: false},
        %{name: "small hut", anchor: {40, 518, 37}, standing: true}
      ]

      assert Enum.map(Offers.registered(registered, two_huts), & &1.name) == [
               "guard_hut",
               "rest_at_home"
             ]

      assert Enum.map(Offers.registered(registered, []), & &1.name) == ["rest_at_home"]
    end
  end

  # 观察：形状同 `Body.observe/1`（entities 含自己，每人带 entity_epoch 与完整 XYZ 位置）。自己（7）在 (1, 2, 3)。
  # 次序故意不是距离序：Brann 恰在说话范围上、Corvin 在范围外 0.5 米、Mara 5 米、无名者 2 米。
  defp observation do
    range = SceneServer.Dialogue.limits().range_m

    %{
      self: %{entity_id: 7, position: {1.0, 2.0, 3.0}, tick: 1, grounded: true, body_state: nil},
      pending: [],
      entities: [
        %{entity_id: 7, entity_epoch: 1, kind: 1, name: "Lin", position: {1.0, 2.0, 3.0}},
        %{
          entity_id: 23,
          entity_epoch: 4,
          kind: 0,
          name: "Brann",
          position: {1.0 + range, 2.0, 3.0}
        },
        %{
          entity_id: 24,
          entity_epoch: 1,
          kind: 0,
          name: "Corvin",
          position: {1.0 + range + 0.5, 2.0, 3.0}
        },
        %{entity_id: 21, entity_epoch: 2, kind: 0, name: "Mara", position: {4.0, 2.0, 7.0}},
        %{entity_id: 22, entity_epoch: 9, kind: 1, name: "", position: {1.0, 2.0, 5.0}}
      ],
      balances: nil
    }
  end

  defp topic(id, epoch, name, candidate_name \\ nil) do
    %{
      name: candidate_name || "speak_to:#{id}",
      kind: "speak_to",
      object: %{"actor" => id},
      criterion: "Walk up to #{name} (actor #{id}) and say one thing to them.",
      place_name: nil,
      target: %{"entity_id" => id, "entity_epoch" => epoch, "name" => name}
    }
  end

  describe "speak_to/2" do
    test "说话范围内（含恰在范围上）的他人，按观察次序；不含自己与范围外的人；目标身份与代次冻结在候选里" do
      assert Offers.speak_to([@gather, @rest], observation()) == [
               topic(23, 4, "Brann"),
               topic(21, 2, "Mara"),
               topic(22, 9, "someone unnamed")
             ]
    end

    test "登记名占了 speak_to:<id> 就往后加下划线避让，直到不重名；kind 与目标不变" do
      registered = [%{@rest | name: "speak_to:21"}, %{@gather | name: "speak_to:21_"}]

      assert [_, mara, _] = Offers.speak_to(registered, observation())
      assert mara == topic(21, 2, "Mara", "speak_to:21__")
    end

    test "观察里只有自己：没有说话候选" do
      alone = %{observation() | entities: [hd(observation().entities)]}
      assert Offers.speak_to([@rest], alone) == []
    end
  end

  # 来话：Scene 交给 Runtime 的 Speech 的形状（同 `Selector.turn_question/6` 读的键）。
  @speech %{
    speaker_id: 21,
    speaker_epoch: 2,
    speaker_name: "Mara",
    speaker_kind: 0,
    target_id: 7,
    conversation_id: 88,
    turn: 1,
    text: "Is this hut yours?"
  }

  describe "reply/2" do
    test "目标是来话者本人，带本次 conversation_id；kind / object 同说话候选；不要求来话者在观察里" do
      assert Offers.reply([@rest], @speech) == %{
               name: "speak_to:21",
               kind: "speak_to",
               object: %{"actor" => 21},
               criterion: "Stop what I am doing, go over to Mara and talk with them.",
               place_name: nil,
               target: %{
                 "entity_id" => 21,
                 "entity_epoch" => 2,
                 "name" => "Mara",
                 "conversation_id" => 88
               }
             }
    end

    test "与 speak_to/2 同一避让规则；空名写 someone unnamed" do
      registered = [%{@rest | name: "speak_to:21"}]

      assert %{name: "speak_to:21_", object: %{"actor" => 21}} =
               Offers.reply(registered, @speech)

      assert %{
               criterion: "Stop what I am doing, go over to someone unnamed and talk with them.",
               target: %{"name" => "someone unnamed"}
             } = Offers.reply([], %{@speech | speaker_name: ""})
    end
  end
end
