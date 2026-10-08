defmodule GateServer.NpcAbilitiesTest do
  @moduledoc """
  只测试：能力库 `GateServer.Npc.Abilities` 的纯函数部分（设计稿 2026-10-07-character-capability-library.md T2.1）。
  期望命令字面量按 Brain moduledoc 的命令表与设计稿 §6 手写，不由 build 生成；strict 不变量按 OpenAI Structured Outputs
  的 strict 规则（https://platform.openai.com/docs/guides/structured-outputs#supported-schemas）：每个 object
  `additionalProperties: false` 且全部属性进 required，可空用 type 联合 "null"，枚举的可空值须在 enum 里。
  """
  use ExUnit.Case, async: true
  alias GateServer.Npc.Abilities

  @hex String.duplicate("2a", 32)
  @id :binary.copy(<<42>>, 32)
  # 作者法术带（D-10）：名字 → 0x82 程序字节；这里是 Test-only 魔法目录 19c513f9… 的预设 ignite_near 原样。
  @ignite ~s({"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":"act.heat","args":{"energy_j":400000,"power_w":200000}}]})
  @profile %{
    tools: %{1 => "镐", 9 => "点火器"},
    skills: %{build: %{}},
    spells: %{"ignite" => @ignite}
  }
  # 每个技能都配上：strict 不变量要覆盖内置技能的 schema。
  @full %{
    tools: %{1 => "镐", 9 => "点火器"},
    skills: %{build: %{}, design_house: %{}, wilderness: %{}},
    spells: %{"ignite" => @ignite, "light" => "{}"}
  }
  # D-3：Demo LLM NPC 的分组（Voxim Docs/Gameplay/npc.exs 的 LLM 后端；工具带同 Demo）。
  @demo %{
    tools: %{1 => "镐：挖掘固体，射程 8 米"},
    groups: [:move, :sense, :act, :build, :memory, :skill]
  }

  # 句柄（JSON 写法，与 probe_toward 结果 / inspect 行里的 target 同形）。
  defp handle(g, micro, incarnation, owner, material, direction),
    do: %{
      "granularity" => g,
      "micro" => micro,
      "incarnation" => incarnation,
      "owner" => owner,
      "material" => material,
      "direction" => direction
    }

  # 每个条目一组手写 JSON 参数 → 手写期望命令（id 统一 1）。
  defp table do
    pillar = handle(0, [128, 520, 80], 3, [0, 0], 11, [1, 0, 0])
    leaf = handle(2, [40, 512, 80], 10, [10, 0], 19, nil)
    face = handle(3, [120, 512, 80], 41, [41, 5], 11, nil)
    target = %{target: %{entity_id: 7, entity_epoch: 9}}

    [
      {"move_to", %{"x" => 14, "z" => 10.5, "y" => nil},
       %{verb: :move_to, position: {14, 10.5}, tolerance: 0.5, y: nil}},
      {"stop", %{}, %{verb: :stop}},
      # 方向 [3,0,4] 长 5 → 单位向量 (0.6, 0, 0.8)。
      {"probe_toward", %{"direction" => [3, 0, 4], "tool_id" => 1},
       %{verb: :probe_toward, tool_id: 1, direction: {0.6, 0.0, 0.8}}},
      {"use_tool", %{"tool_id" => 1, "target" => pillar},
       %{
         verb: :use_tool,
         tool_id: 1,
         direction: {1.0, 0.0, 0.0},
         target: %{
           granularity: 0,
           micro: {128, 520, 80},
           incarnation: 3,
           owner: {0, 0},
           material: 11
         }
       }},
      {"dismantle", %{"tool_id" => 1, "target" => leaf},
       %{
         verb: :dismantle,
         tool_id: 1,
         direction: nil,
         target: %{
           granularity: 2,
           micro: {40, 512, 80},
           incarnation: 10,
           owner: {10, 0},
           material: 19
         }
       }},
      {"place", %{"x" => 16, "y" => 65, "z" => -10, "material" => 11, "tool_id" => 1},
       %{verb: :place, coord: {16, 65, -10}, material: 11, tool_id: 1}},
      {"scoop", %{"x" => 50, "y" => 519, "z" => 64, "material" => 21, "tool_id" => 9},
       %{verb: :scoop, coord: {50, 519, 64}, material: 21, tool_id: 9}},
      {"pour", %{"x" => 50, "y" => 519, "z" => 64, "material" => 21, "tool_id" => 9},
       %{verb: :pour, coord: {50, 519, 64}, material: 21, tool_id: 9}},
      {"craft", %{"material" => 21}, %{verb: :craft, material: 21}},
      {"eat", %{"material" => 22}, %{verb: :eat, material: 22}},
      # edge = 1、z = 2（Codec 0x81 的 kind / axis 码）。
      {"attach",
       %{
         "kind" => "edge",
         "axis" => "z",
         "size" => 8,
         "x" => 120,
         "y" => 512,
         "z" => -80,
         "material" => 11,
         "tool_id" => 1
       },
       %{
         verb: :attach,
         kind: 1,
         axis: 2,
         size: 8,
         anchor: {120, 512, -80},
         material: 11,
         tool_id: 1
       }},
      # owner {41, 5}：kind = div(5, 3) = 1，axis = rem(5, 3) = 2；attachment_id = incarnation 41，anchor = micro。
      {"detach", %{"tool_id" => 1, "target" => face},
       %{
         verb: :detach,
         kind: 1,
         axis: 2,
         size: 1,
         anchor: {120, 512, 80},
         material: 11,
         attachment_id: 41,
         tool_id: 1
       }},
      {"prefab",
       %{
         "op" => "place",
         "definition" => @hex,
         "x" => 15,
         "y" => 64,
         "z" => 12,
         "orientation" => 5,
         "instance" => nil
       }, %{verb: :prefab_place, definition_id: @id, anchor: {15, 64, 12}, orientation: 5}},
      # I4：spell 名字 → 法术带里的程序字节；目标句柄同 use_tool（direction 单位化后提到命令上）。
      {"cast_spell", %{"spell" => "ignite", "target" => pillar},
       %{
         verb: :cast_spell,
         program: @ignite,
         direction: {1.0, 0.0, 0.0},
         target: %{
           granularity: 0,
           micro: {128, 520, 80},
           incarnation: 3,
           owner: {0, 0},
           material: 11
         }
       }},
      {"cancel_cast", %{}, %{verb: :cancel_cast}},
      {"look", %{"x0" => 15, "y0" => 63, "z0" => -9, "x1" => 17, "y1" => 66, "z1" => 11},
       %{verb: :look, min: {15, 63, -9}, max: {17, 66, 11}}},
      {"inspect", %{}, %{verb: :inspect}},
      {"query_balances", %{}, %{verb: :query_balances}},
      {"read_catalog", %{"what" => "prefab", "definition" => String.upcase(@hex)},
       %{verb: :read_catalog, what: :prefab, definition: @id}},
      {"get_view", %{}, %{verb: :get_view}},
      {"look_at", %{"entity_id" => 7, "entity_epoch" => 9, "x" => nil, "y" => nil, "z" => nil},
       Map.put(target, :verb, :look_at)},
      {"get_aim", %{}, %{verb: :get_aim}},
      {"get_visible_entities", %{}, %{verb: :get_visible_entities}},
      {"get_target_status", %{"entity_id" => 7, "entity_epoch" => 9},
       Map.put(target, :verb, :get_target_status)},
      {"select_target", %{"entity_id" => 7, "entity_epoch" => 9, "group" => "enemy"},
       Map.merge(target, %{verb: :select_target, group: :enemy})},
      {"remove_target", %{"entity_id" => 7, "entity_epoch" => 9},
       Map.put(target, :verb, :remove_target)},
      {"get_targets", %{}, %{verb: :get_targets}},
      {"set_focus", %{"entity_id" => 7, "entity_epoch" => 9, "group" => "friendly"},
       Map.merge(target, %{verb: :set_focus, group: :friendly})},
      {"cycle_focus", %{"group" => "enemy", "direction" => -1},
       %{verb: :cycle_focus, group: :enemy, direction: -1}},
      {"remove_focus", %{"group" => "friendly"}, %{verb: :remove_focus, group: :friendly}},
      {"clear_targets", %{}, %{verb: :clear_targets}},
      {"toggle_mark", %{}, %{verb: :toggle_mark}},
      {"remember", %{"key" => "plan", "text" => "先挖后砌"},
       %{verb: :remember, key: "plan", text: "先挖后砌"}},
      {"recall", %{"key" => "plan"}, %{verb: :recall, key: "plan"}},
      {"search_memory", %{"query" => "西门"}, %{verb: :search_memory, query: "西门"}},
      {"build", %{"definition" => @hex, "anchor_micro" => [8, 16, 24], "orientation" => 3},
       %{
         verb: :skill,
         skill: :build,
         args: %{"definition" => @hex, "anchor_micro" => [8, 16, 24], "orientation" => 3}
       }}
    ]
  end

  test "every entry: hand-written JSON arguments become the hand-written canonical command" do
    names = Enum.map(Abilities.entries(@profile), & &1.name)
    # 表覆盖全部条目：新增条目必须同时补一行手写期望。
    assert Enum.sort(names) == Enum.sort(for {name, _, _} <- table(), do: name)

    for {name, args, expected} <- table() do
      assert Abilities.command(name, args, 1, @profile) == Map.put(expected, :id, 1), name
    end
  end

  test "other prefab ops, a nullable y, and the other catalog kinds" do
    assert %{id: 2, verb: :prefab_remove, instance_id: {10, 0}} ==
             Abilities.command(
               "prefab",
               %{
                 "op" => "remove",
                 "definition" => nil,
                 "x" => nil,
                 "y" => nil,
                 "z" => nil,
                 "orientation" => nil,
                 "instance" => [10, 0]
               },
               2,
               @profile
             )

    assert %{id: 3, verb: :prefab_replace, instance_id: {10, 0}, definition_id: @id} ==
             Abilities.command(
               "prefab",
               %{
                 "op" => "replace",
                 "definition" => @hex,
                 "x" => nil,
                 "y" => nil,
                 "z" => nil,
                 "orientation" => nil,
                 "instance" => [10, 0]
               },
               3,
               @profile
             )

    assert %{y: 523, position: {49.5, 64.5}} =
             Abilities.command("move_to", %{"x" => 49.5, "z" => 64.5, "y" => 523}, 4, @profile)

    assert %{id: 5, verb: :read_catalog, what: :tools, definition: nil} ==
             Abilities.command(
               "read_catalog",
               %{"what" => "tools", "definition" => nil},
               5,
               @profile
             )

    assert %{id: 6, verb: :look_at, position: {1.5, 66.0, -3.0}} ==
             Abilities.command(
               "look_at",
               %{"entity_id" => nil, "entity_epoch" => nil, "x" => 1.5, "y" => 66.0, "z" => -3.0},
               6,
               @profile
             )
  end

  test "missing nullable keys are null and extra keys are ignored" do
    {"use_tool", json, expected} = Enum.find(table(), &(elem(&1, 0) == "use_tool"))
    # probe_toward 结果原样当句柄：多出的 current_hp 忽略。
    extra = put_in(json, ["target", "current_hp"], 72.0)
    assert Map.put(expected, :id, 1) == Abilities.command("use_tool", extra, 1, @profile)

    assert %{id: 7, verb: :move_to, position: {1, 2}, tolerance: 0.5, y: nil} ==
             Abilities.command("move_to", %{"x" => 1, "z" => 2}, 7, @profile)
  end

  test "wrong shapes are rejected locally as invalid_tool_arguments; unknown names as unknown_tool" do
    pillar = handle(0, [128, 520, 80], 3, [0, 0], 11, nil)

    for {name, args} <- [
          {"move_to", %{"x" => 14}},
          {"move_to", %{"x" => 14, "z" => 10, "y" => 64.5}},
          {"move_to", [14, 10]},
          {"probe_toward", %{"direction" => [1, 0], "tool_id" => 1}},
          {"probe_toward", %{"direction" => ["a", 0, 0], "tool_id" => 1}},
          {"use_tool", %{"tool_id" => 1.0, "target" => pillar}},
          # 人物 g5 句柄不在 LLM 投影里（D-13）。
          {"use_tool", %{"tool_id" => 1, "target" => %{pillar | "granularity" => 5}}},
          {"use_tool", %{"tool_id" => 1, "target" => %{pillar | "micro" => [128.0, 520, 80]}}},
          {"use_tool", %{"tool_id" => 1}},
          # detach 只接附件句柄（g3）。
          {"detach", %{"tool_id" => 1, "target" => pillar}},
          {"attach",
           %{
             "kind" => "corner",
             "axis" => "y",
             "size" => 1,
             "x" => 0,
             "y" => 0,
             "z" => 0,
             "material" => 11,
             "tool_id" => 1
           }},
          {"attach",
           %{
             "kind" => "face",
             "axis" => "y",
             "size" => 4,
             "x" => 0,
             "y" => 0,
             "z" => 0,
             "material" => 11,
             "tool_id" => 1
           }},
          {"prefab", %{"op" => "place", "definition" => "zz", "instance" => nil}},
          {"prefab", %{"op" => "remove", "instance" => "abc"}},
          {"read_catalog", %{"what" => "everything", "definition" => nil}},
          {"read_catalog", %{"what" => "prefab", "definition" => String.duplicate("2a", 31)}},
          {"remember", %{"key" => "plan"}},
          {"cycle_focus", %{"group" => "enemy", "direction" => 2}},
          {"build", "not an object"},
          # 法术带外的名字；0x82 的目标只有 g0..g2（附件 g3、人物 g5 都表达不了）。
          {"cast_spell", %{"spell" => "fireball", "target" => pillar}},
          {"cast_spell", %{"spell" => "ignite", "target" => %{pillar | "granularity" => 3}}},
          {"cast_spell", %{"spell" => "ignite", "target" => %{pillar | "granularity" => 5}}},
          {"cast_spell", %{"spell" => "ignite"}}
        ] do
      assert %{id: 1, verb: :invalid_tool_arguments, tool: ^name} =
               Abilities.command(name, args, 1, @profile),
             inspect({name, args})
    end

    for name <- ["say", "dance", "cancel_skill", "wait", "design_house"],
        do:
          assert(
            %{id: 1, verb: :unknown_tool, tool: name} ==
              Abilities.command(name, %{}, 1, @profile)
          )
  end

  test "grant conditions only shape the projection: groups, a non-empty belt, configured skills" do
    # 分组之外的条目对这个 profile 不存在。
    assert %{verb: :unknown_tool} = Abilities.command("scoop", %{}, 1, @demo)
    assert %{verb: :unknown_tool} = Abilities.command("get_view", %{}, 1, @demo)
    # 没有工具带：带 tool_id 的条目都不投影。
    belt_free = Enum.map(Abilities.tools(%{}), & &1.name)

    for name <- ~w(probe_toward use_tool dismantle place scoop pour attach detach),
        do: refute(name in belt_free)

    assert "craft" in belt_free and "prefab" in belt_free and "look" in belt_free

    # 工具带外的 id 不出现在 schema 里，但译码只要求整数：World 受理目录里任何 tool_id。
    probe = Enum.find(Abilities.tools(@profile), &(&1.name == "probe_toward"))
    assert [1, 9] == probe.parameters.properties.tool_id.enum

    assert %{verb: :probe_toward, tool_id: 3} =
             Abilities.command(
               "probe_toward",
               %{"direction" => [1, 0, 0], "tool_id" => 3},
               1,
               @profile
             )

    # 施法条目只在 profile.spells 非空时投影；schema 只列法术名，不列程序字节。
    for profile <- [%{}, %{spells: %{}}, @demo] do
      names = Enum.map(Abilities.tools(profile), & &1.name)
      refute "cast_spell" in names or "cancel_cast" in names
      assert %{verb: :unknown_tool} = Abilities.command("cancel_cast", %{}, 1, profile)
    end

    cast = Enum.find(Abilities.tools(@full), &(&1.name == "cast_spell"))
    assert ["ignite", "light"] == cast.parameters.properties.spell.enum
    assert [0, 1, 2] == cast.parameters.properties.target.properties.granularity.enum
    assert "cancel_cast" in Enum.map(Abilities.tools(@full), & &1.name)
  end

  test "names are unique and each one is the verb its build produces (prefab: prefab_<op>; skills: the skill name)" do
    entries = Abilities.entries(@full)
    names = Enum.map(entries, & &1.name)
    assert names == Enum.uniq(names)

    for {name, _, expected} <- table() do
      case expected do
        %{verb: :skill, skill: skill} -> assert Atom.to_string(skill) == name
        %{verb: :prefab_place} -> assert name == "prefab"
        %{verb: verb} -> assert Atom.to_string(verb) == name
      end
    end
  end

  test "every projected tool is a strict function whose schema satisfies the strict invariants recursively" do
    tools = Abilities.tools(@full)
    assert length(tools) == length(Abilities.entries(@full))

    for tool <- tools do
      assert %{type: "function", strict: true, name: name, description: description} = tool
      assert is_binary(description) and description =~ "完成："
      assert %{type: "object"} = tool.parameters, name
      strict!(tool.parameters, name)
    end
  end

  test "the Demo LLM profile projects exactly the hand-listed tools, and say is in no projection" do
    assert ~w(move_to stop probe_toward use_tool dismantle place attach detach prefab look inspect query_balances read_catalog remember recall search_memory) ==
             Enum.map(Abilities.tools(@demo), & &1.name)

    llm = %{goal: "g", endpoint: %{model: "m"}} |> Map.merge(@demo)

    observation = %{
      self: %{entity_id: 1, position: {0.0, 0.0, 0.0}},
      entities: [],
      balances: nil
    }

    assert ~w(move_to stop probe_toward use_tool dismantle place attach detach prefab look inspect query_balances read_catalog remember recall search_memory wait) ==
             Enum.map(GateServer.Npc.Brain.Llm.body(llm, observation, []).tools, & &1.name)

    # instructions 只依赖 profile 的工具表：不点名被 groups 裁掉的工具（Demo 没有 :attend 组，也没配技能）。
    instructions = GateServer.Npc.Brain.Llm.body(llm, observation, []).instructions

    pruned =
      Enum.map(Abilities.entries(@full), & &1.name) --
        String.split(
          "move_to stop probe_toward use_tool dismantle place attach detach prefab look inspect query_balances read_catalog remember recall search_memory"
        )

    assert "get_aim" in pruned and "design_house" in pruned

    for name <- pruned,
        do: refute(instructions =~ ~r/(?<![a-z_])#{name}(?![a-z_])/, name)

    # 全部组时，只关乎关注动词的提示照常写进 instructions。
    full = Map.merge(%{goal: "g", endpoint: %{model: "m"}}, @full)
    instructions = GateServer.Npc.Brain.Llm.body(full, observation, []).instructions
    assert instructions =~ "get_visible_entities" and instructions =~ "get_aim"

    for profile <- [@full, @profile, @demo, %{}] do
      refute "say" in Enum.map(Abilities.tools(profile), & &1.name)
    end
  end

  test "descriptions no longer carry the retired circuit install / feed wording or 'pickaxe = attack'" do
    text = Enum.map_join(Abilities.tools(@full), "\n", & &1.description)
    refute text =~ "镐 = 攻击"
    refute text =~ "电路安装"
    refute text =~ "投料"
  end

  # strict 不变量（递归）：object 必须 additionalProperties false 且 required = 全部属性；可空 = type 联合 "null"，
  # 可空枚举的 enum 含 nil；数组必须有 items。
  defp strict!(%{type: type} = schema, path) do
    types = List.wrap(type)

    if "object" in types do
      assert schema.additionalProperties == false, path

      assert Enum.sort(schema.required) ==
               schema.properties |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
             path

      for {key, property} <- schema.properties, do: strict!(property, "#{path}.#{key}")
    end

    if "array" in types do
      assert Map.has_key?(schema, :items), path
      strict!(schema.items, path <> "[]")
    end

    if Map.has_key?(schema, :enum) and "null" in types, do: assert(nil in schema.enum, path)
    :ok
  end
end
