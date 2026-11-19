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
  - **候选只从覆盖登记生成**：`Offers.generators/1` 取登记里 offer 一类的生成器，按模块里显式写下的生成器次序排列（批 1 前置：
    原来按名字排序，新增 `:eat` / `:craft` 会排到 `:registered` 之前、改变候选次序），`candidates/4` 只按它生成；次序锁定为
    登记项、说话、进食、合成；登记里出现次序表没有的生成器是登记写错，直接 raise；把条目改成 withheld，它的生成器（没有别的
    offer 共用时）就消失。用参数化的登记表测这个纯函数，生产代码不为测试加开关。真实 Scene 求交后的整轮候选次序另由
    `npc_selector_test` 的真实 Runtime 用例锁定；带背包候选的整轮次序由 `npc_offers_integration_test` 读请求体里的有序候选锁定
    （合成用例另断言 `npc_select … candidates=…` 这一行日志）。
  - **批 1 的 offer**：build / gather / expand / travel（登记项生成器 `registered/2`）、speak（`speak_to/2`）、eat（`eat/2`）、
    craft（`craft/2`）。
  - **生成器（T-A2）**：`registered/2` 按建筑条件保序过滤（从 `Selector` 迁来，期望照迁移前的输出手写）；`speak_to/2` 与 `reply/2`
    （从 `Dialogue.topic_candidates/2`、`Dialogue.reply_candidate/2` 迁来）的范围、自身排除、观察次序、目标冻结、`speak_to:<id>` 的避让。
    所有候选都带 `kind` 与 `object`（登记项 `kind` = 候选名、`object` = nil；说话项 `kind` = `"speak_to"`、`object` = `%{"actor" => cid}`），
    说话项保留 `target`（Runtime 交给 speak 技能的参数，`runtime.ex` 的 `finish_select/2` 读它）。
    `eat/2` / `craft/2`（批 1，评审修正后）：可行性**不在这里判**——World 的 `production_options/2` 用与提交同一组判定列出能吃 /
    能合成的材料（一致性由 voxel_region 的 `production_options_test` 证明），生成器只把列出的每一项投影成候选：按材料号升序
    （与 World 给的次序无关）、生成器给完整列表（每类前 k 项由 `candidates/4` 截断，截断在 `npc_offers_integration_test` 里由真实
    World 证明）、名字避让、判据的写法、冻结的世界动作 `action: {动作名, %{"material" => id}}`（与登记项的分支规格 `run` 分开，
    背包候选没有 `run` 键）；`acts/0` 与生成器给出的动作名一致（`Trees.npc/1` 按它建分支）。
    读库存只测 happy path（用户 2026-11-19 方向）：路由 / World 失败照常退出，不在这里预建失败用例。

  层次与替身：纯函数，直接构造输入（profile、观察、Life 的建筑视图与来话都按产品形状手写：观察同 `Body.observe/1`，
  建筑同 `Life.mind/2` 的 `buildings`，来话同 Scene 交给 Runtime 的 Speech；库存同 `World.production_options/2` 的结果，
  取值照真实目录）。不启动 World、Scene、Life 或数据库。
  说话范围读 Scene 的唯一参数 `SceneServer.Dialogue.limits/0`，不在测试里另写一个数。
  不证明：候选进请求体的字节（`npc_selector_test` 的 request body 用例）、Scene 新话题冷却的求交（`npc_registry_test` 的真实对话用例）、
  库存读自真实 World 与每类截断（`npc_offers_integration_test`）。
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

    test "批 1：offer 恰为四个登记技能（registered/2）、speak（speak_to/2）、eat（eat/2）与 craft（craft/2）" do
      offers =
        for {name, {:offer, generator}} <- Offers.coverage(), into: %{}, do: {name, generator}

      assert offers == %{
               "build" => :registered,
               "gather" => :registered,
               "expand" => :registered,
               "travel" => :registered,
               "speak" => :speak_to,
               "eat" => :eat,
               "craft" => :craft
             }
    end
  end

  # 评审修正：`candidates/4` 原来写死 `registered ++ speak`、不读 `coverage/0`，登记表与真实候选来源是两份互不约束的事实。
  # 批 1 前置：生成器次序改为显式声明（原来按名字排序：加上 eat / craft 会得 `[:craft, :eat, :registered, :speak_to]`）。
  describe "generators/1：候选只从覆盖登记生成，按显式次序" do
    test "现在的登记：[:registered, :speak_to, :eat, :craft]——登记项、说话、进食、合成；四个登记技能共用的生成器只出现一次" do
      assert Offers.generators(Offers.coverage()) == [:registered, :speak_to, :eat, :craft]
    end

    test "把 speak 改成 withheld：说话生成器消失，它的候选不再出现；其余次序不变" do
      coverage = Map.put(Offers.coverage(), "speak", {:withheld, "只测试：不给说话。"})
      assert Offers.generators(coverage) == [:registered, :eat, :craft]
    end

    test "登记项的生成器由四个条目共用：只改一个仍在（过渡形态），四个都改成 withheld 才消失" do
      withhold = fn coverage, names ->
        Enum.reduce(names, coverage, &Map.put(&2, &1, {:withheld, "只测试。"}))
      end

      assert Offers.generators(withhold.(Offers.coverage(), ["build"])) == [
               :registered,
               :speak_to,
               :eat,
               :craft
             ]

      all_four = withhold.(Offers.coverage(), ["build", "gather", "expand", "travel"])
      assert Offers.generators(all_four) == [:speak_to, :eat, :craft]
    end

    test "次序取显式次序表，与登记表的遍历次序、生成器名的字典序都无关；inside / withheld 条目不产生生成器" do
      coverage = [
        {"craft", {:offer, :craft}},
        {"speak", {:offer, :speak_to}},
        {"say", {:inside, [:speak]}},
        {"eat", {:offer, :eat}},
        {"travel", {:offer, :registered}},
        {"dismantle", {:withheld, "只测试。"}},
        {"build", {:offer, :registered}}
      ]

      assert Offers.generators(coverage) == [:registered, :speak_to, :eat, :craft]
      assert Offers.generators(Enum.reverse(coverage)) == [:registered, :speak_to, :eat, :craft]
    end

    test "登记里有、次序表里没有的生成器是登记写错：raise，不悄悄排到哪里" do
      coverage = Map.put(Offers.coverage(), "dismantle", {:offer, :dismantle})

      assert_raise ArgumentError, ~r/:dismantle/, fn -> Offers.generators(coverage) end
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

  # —— 批 1：背包生成器（eat / craft） ——

  # 库存：`World.production_options/2` 的结果（能不能吃 / 合成由 World 与提交同一处判定，生成器不再过滤）。
  # 取值照真实目录（Voxim `Content/Voxel/Properties/Playable/Published/e6db8dee…json`，2026-11-10 最新一份）：可食只有
  # Fern 34 / Dandelion 36 / Allium 39（一份 = place_units 262144）；Switch 41 = 铜 24 × 8192 + 石 11 × 4096 → 4096、
  # 灰褐砌石 46 = 石 × 2097152、石质饰面 47 = 石灰石 10 × 2097152。另有一行没有显示名（World 对目录没有 `display_name`
  # 的材料给 nil，如 npc_world 夹具的基础材料行），测 `material <id>` 的写法。
  # 行的次序故意不是材料号序：输出的次序只能来自生成器自己的排序（候选次序是本模块的策略，不靠 World 的次序）。
  @options %{
    seq: 17,
    eat: [
      %{material: 39, name: "Allium", units: 262_144},
      %{material: 34, name: "Fern", units: 262_144},
      %{material: 36, name: "Dandelion", units: 262_144}
    ],
    craft: [
      %{
        material: 47,
        name: "石质饰面",
        inputs: [%{material: 10, units: 2_097_152}],
        units: 2_097_152
      },
      %{
        material: 41,
        name: "Switch",
        inputs: [%{material: 24, units: 8192}, %{material: 11, units: 4096}],
        units: 4096
      },
      %{material: 46, name: nil, inputs: [%{material: 11, units: 2_097_152}], units: 2_097_152}
    ]
  }

  defp eat_candidate(id, label, name \\ nil),
    do: %{
      name: name || "eat:#{id}",
      kind: "eat",
      object: %{"material" => id},
      criterion: "Eat one serving of #{label} from my inventory.",
      place_name: nil,
      action: {"eat", %{"material" => id}}
    }

  defp craft_candidate(id, label, name \\ nil),
    do: %{
      name: name || "craft:#{id}",
      kind: "craft",
      object: %{"material" => id},
      criterion: "Craft #{label} from materials in my inventory.",
      place_name: nil,
      action: {"craft", %{"material" => id}}
    }

  describe "eat/2（批 1）" do
    test "World 列出的能吃一份的材料各成一个候选，按材料号升序；冻结的世界动作在 action（不占登记项的 run）" do
      assert Offers.eat([@rest], @options) == [
               eat_candidate(34, "Fern (material 34)"),
               eat_candidate(36, "Dandelion (material 36)"),
               eat_candidate(39, "Allium (material 39)")
             ]

      # 评审修正：背包候选的冻结命令与登记项的分支规格不共用一个键。
      refute Enum.any?(Offers.eat([@rest], @options), &Map.has_key?(&1, :run))
    end

    test "登记名占了 eat:<id> 就往后加下划线避让；种类、对象与执行参数不变" do
      registered = [%{@rest | name: "eat:39"}, %{@gather | name: "eat:39_"}]

      assert [_, _, allium] = Offers.eat(registered, @options)
      assert allium == eat_candidate(39, "Allium (material 39)", "eat:39__")
    end

    test "World 什么都没列：没有进食候选" do
      assert Offers.eat([@rest], %{@options | eat: []}) == []
    end
  end

  describe "craft/2（批 1）" do
    test "World 列出的能合成一次的产物各成一个候选，按材料号升序；没有显示名写 material <id>；生成器给完整列表（截断在 candidates/4）" do
      assert Offers.craft([@rest], @options) == [
               craft_candidate(41, "Switch (material 41)"),
               craft_candidate(46, "material 46"),
               craft_candidate(47, "石质饰面 (material 47)")
             ]
    end

    test "登记名占了 craft:<id> 就往后加下划线避让" do
      assert [switch, _, _] = Offers.craft([%{@rest | name: "craft:41"}], @options)
      assert switch == craft_candidate(41, "Switch (material 41)", "craft:41_")
    end
  end

  describe "acts/0（批 1）" do
    test "acts/0 恰是背包生成器冻结的动作名（Trees.npc 按它建分支，两边不能各写一份）" do
      generated =
        for candidate <- Offers.eat([], @options) ++ Offers.craft([], @options),
            {act, %{"material" => _}} = candidate.action,
            uniq: true,
            do: act

      assert Offers.acts() == ["eat", "craft"]
      assert generated == Offers.acts()
    end
  end
end
