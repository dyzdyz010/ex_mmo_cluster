defmodule GateServer.NpcBrainLlmTest do
  @moduledoc "只测试：LLM 决策后端的译码与询问时机。模型接口用冻结的 Responses 应答样本替身；真实接口见 :live_llm 用例。"
  use ExUnit.Case, async: false
  alias GateServer.Npc.Brain.Llm

  # 只测试：与正式 NpcMemory 同接口，生命周期独立于 Brain；真实表读写在 npc_memory_test 验证。
  defmodule Store do
    use Agent

    def start_link(observer),
      do:
        Agent.start_link(fn -> %{notes: %{}, events: [], observer: observer} end,
          name: __MODULE__
        )

    def put(cid, kind, key, body) do
      Agent.update(__MODULE__, fn s ->
        send(s.observer, {:memory_written, cid, key, body})
        put_in(s.notes[{cid, kind, key}], body)
      end)
    end

    def get(cid, kind, key), do: Agent.get(__MODULE__, & &1.notes[{cid, kind, key}])

    def recent_notes(cid, limit),
      do:
        Agent.get(__MODULE__, fn s ->
          for {{^cid, "note", key}, body} <- s.notes do
            %{
              id: key,
              kind: "note",
              key: key,
              body: body,
              at: ~U[2026-09-22 00:00:00Z],
              position: body["position"]
            }
          end
          |> Enum.take(limit)
        end)

    def search(cid, query, _limit) do
      Agent.get(__MODULE__, fn s -> send(s.observer, {:memory_search, cid, query}) end)
      []
    end

    def recent(cid, limit),
      do:
        Agent.get(__MODULE__, fn s ->
          send(s.observer, {:recent_read, cid, limit})
          Enum.take(s.events, limit)
        end)

    def events(events), do: Agent.update(__MODULE__, &%{&1 | events: events})
  end

  defmodule UnavailableStore do
    def recent(_, _),
      do: raise(DBConnection.ConnectionError, message: "private connection details")
  end

  setup do
    start_supervised!({Store, self()})
    :ok
  end

  defp brain(profile) do
    pid = GateServer.Npc.Runtime.init({Llm, Map.put_new(profile, :memory, Store)})
    on_exit(fn -> stop_brain(pid) end)
    pid
  end

  defp stop_brain(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  defp observations(pid, idle) do
    Llm.handle_event({:observation, idle}, pid)
    {:ok, timer} = :timer.send_interval(50, pid, {:observation, idle})
    on_exit(fn -> :timer.cancel(timer) end)
  end

  defp call(name, args),
    do: %{
      "type" => "function_call",
      "name" => name,
      "arguments" => Jason.encode!(args),
      "call_id" => "c"
    }

  # 只测试：带工具带与 build 技能的 profile；与 Llm.body 用的是同一份 Abilities 投影。
  @profile %{tools: %{1 => "镐", 7 => "电路开关", 9 => "点火器"}, skills: %{build: %{}}}

  # 能力库 T2.3：冻结的 Responses 应答（strict 形参数）→ 规范命令。期望字面量按 Brain moduledoc 手写。
  test "function calls become commands; reasoning items are ignored; probe direction is normalised" do
    response = %{
      "output" => [
        %{"type" => "reasoning", "summary" => []},
        call("move_to", %{x: 14, z: 10.5, y: nil}),
        call("probe_toward", %{direction: [3, 0, 4], tool_id: 1}),
        call("move_to", %{x: 49.5, z: 64.5, y: 523})
      ]
    }

    assert [
             %{id: 7, verb: :move_to, position: {14, 10.5}, tolerance: 0.5, y: nil},
             %{id: 8, verb: :probe_toward, tool_id: 1, direction: {0.6, 0.0, 0.8}},
             %{id: 9, verb: :move_to, position: {49.5, 64.5}, y: 523, tolerance: 0.5}
           ] == Llm.commands(response, 7, @profile)
  end

  test "use_tool carries the explicit target handle it was given, with no earlier probe" do
    target = %{
      granularity: 0,
      micro: [128, 520, 80],
      incarnation: 3,
      owner: [0, 0],
      material: 11,
      direction: [1, 0, 0]
    }

    response = %{"output" => [call("use_tool", %{tool_id: 1, target: target})]}

    assert [
             %{
               id: 1,
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
             }
           ] == Llm.commands(response, 1, @profile)

    # 句柄不带方向（inspect 行）：direction nil，由 Body 从眼点瞄准。
    response = %{
      "output" => [call("use_tool", %{tool_id: 1, target: %{target | direction: nil}})]
    }

    assert [%{verb: :use_tool, direction: nil, target: %{micro: {128, 520, 80}}}] =
             Llm.commands(response, 1, @profile)
  end

  test "building verbs: cells are integer macro coords and tool_id is the one the model names" do
    response = %{
      "output" => [
        call("look", %{x0: 15, y0: 63, z0: 9, x1: 17, y1: 66, z1: 11}),
        call("place", %{x: 16, y: 65, z: 10, material: 11, tool_id: 1}),
        call("scoop", %{x: 50, y: 519, z: 64, material: 21, tool_id: 9}),
        call("pour", %{x: 50, y: 519, z: 64, material: 21, tool_id: 9}),
        call("query_balances", %{}),
        call("probe_toward", %{direction: [1, 0, 0], tool_id: 9})
      ]
    }

    assert [
             %{id: 1, verb: :look, min: {15, 63, 9}, max: {17, 66, 11}},
             %{id: 2, verb: :place, coord: {16, 65, 10}, material: 11, tool_id: 1},
             %{id: 3, verb: :scoop, coord: {50, 519, 64}, material: 21, tool_id: 9},
             %{id: 4, verb: :pour, coord: {50, 519, 64}, material: 21, tool_id: 9},
             %{id: 5, verb: :query_balances},
             %{id: 6, verb: :probe_toward, tool_id: 9, direction: {1.0, 0.0, 0.0}}
           ] == Llm.commands(response, 1, @profile)
  end

  test "attachment and prefab tools: string enums become codes, hex ids 32-byte binaries; a bad hex is rejected locally" do
    id = String.duplicate("2a", 32)
    blank = %{x: nil, y: nil, z: nil, orientation: nil}

    response = %{
      "output" => [
        call("attach", %{
          kind: "face",
          axis: "y",
          size: 8,
          x: 120,
          y: 512,
          z: 80,
          material: 11,
          tool_id: 1
        }),
        call(
          "prefab",
          Map.merge(blank, %{
            op: "place",
            definition: id,
            x: 15,
            y: 64,
            z: 12,
            orientation: 5,
            instance: nil
          })
        ),
        call("prefab", Map.merge(blank, %{op: "remove", definition: nil, instance: [10, 0]})),
        call("prefab", Map.merge(blank, %{op: "replace", instance: [10, 0], definition: "zz"}))
      ]
    }

    assert [
             %{
               id: 1,
               verb: :attach,
               kind: 0,
               axis: 1,
               size: 8,
               anchor: {120, 512, 80},
               material: 11,
               tool_id: 1
             },
             %{
               id: 2,
               verb: :prefab_place,
               definition_id: :binary.copy(<<42>>, 32),
               anchor: {15, 64, 12},
               orientation: 5
             },
             %{id: 3, verb: :prefab_remove, instance_id: {10, 0}},
             %{id: 4, verb: :invalid_tool_arguments, tool: "prefab"}
           ] == Llm.commands(response, 1, @profile)
  end

  test "detach takes an inspect g3 handle: kind and axis come from its owner, the id from its incarnation" do
    # owner {41, 1}：kind = div(1, 3) = 0（面片），axis = rem(1, 3) = 1（Y）；{41, 5} → kind 1（棱条）、axis 2（Z）。
    handle = fn type ->
      %{
        granularity: 3,
        micro: [120, 512, 80],
        incarnation: 41,
        owner: [41, type],
        material: 11,
        direction: nil
      }
    end

    response = %{
      "output" => [
        call("detach", %{tool_id: 1, target: handle.(1)}),
        call("detach", %{tool_id: 1, target: handle.(5)})
      ]
    }

    assert [
             %{
               id: 1,
               verb: :detach,
               kind: 0,
               axis: 1,
               size: 1,
               anchor: {120, 512, 80},
               material: 11,
               attachment_id: 41,
               tool_id: 1
             },
             %{
               id: 2,
               verb: :detach,
               kind: 1,
               axis: 2,
               size: 1,
               anchor: {120, 512, 80},
               material: 11,
               attachment_id: 41,
               tool_id: 1
             }
           ] == Llm.commands(response, 1, @profile)
  end

  test "unknown tools, non-object arguments, wrong shapes and say are rejected locally" do
    response = %{
      "output" => [
        %{"type" => "function_call", "name" => "place", "arguments" => "[1,2]"},
        %{"type" => "function_call", "name" => "place", "arguments" => "{not json"},
        call("dance", %{style: "waltz"}),
        call("say", %{text: "墙砌好了"}),
        call("move_to", %{x: 1}),
        # 人物句柄（g5）不在 LLM 投影里（D-13）。
        call("use_tool", %{
          tool_id: 1,
          target: %{
            granularity: 5,
            micro: [0, 0, 0],
            incarnation: 2,
            owner: [77, 0],
            material: 0,
            direction: nil
          }
        })
      ]
    }

    assert [
             %{id: 1, verb: :invalid_tool_arguments, tool: "place"},
             %{id: 2, verb: :invalid_tool_arguments, tool: "place"},
             %{id: 3, verb: :unknown_tool, tool: "dance"},
             %{id: 4, verb: :unknown_tool, tool: "say"},
             %{id: 5, verb: :invalid_tool_arguments, tool: "move_to"},
             %{id: 6, verb: :invalid_tool_arguments, tool: "use_tool"}
           ] == Llm.commands(response, 1, @profile)
  end

  test "inspect: every row the model sees carries its target handle verbatim, and that handle drives use_tool" do
    row = %{
      granularity: 3,
      micro: {120, 512, 80},
      incarnation: 41,
      owner: {41, 1},
      material: 11,
      hp: 0.19,
      max_hp: 0.19,
      digest: <<1, 2>>,
      observation_cells: [{15, 63, 10}, {15, 64, 10}]
    }

    part = %{
      granularity: 2,
      micro: {8, 8, 8},
      incarnation: 10,
      owner: {10, 0},
      material: 3,
      observation_cells: [{1, 1, 1}]
    }

    outcome = %{
      id: 4,
      verb: :inspect,
      status: :done,
      reason: nil,
      data: %{seq: 9, property_states: [row, part]}
    }

    # owner {41, 1}：kind 码 div(1, 3) = 0、axis 码 rem(1, 3) = 1；模型看到的是 attach 参数里的同名字符串
    # （Codec 0x81：kind 0 = face、1 = edge；axis 0/1/2 = x/y/z），可以直接照抄去贴一件同向的。
    assert [
             %{
               data: %{
                 attachments: [
                   %{
                     attachment_id: 41,
                     kind: "face",
                     axis: "y",
                     micro: {120, 512, 80},
                     material: 11,
                     hp: 0.19,
                     target:
                       %{
                         granularity: 3,
                         micro: {120, 512, 80},
                         incarnation: 41,
                         owner: {41, 1},
                         material: 11,
                         direction: nil
                       } = thing
                   }
                 ],
                 components: [
                   %{
                     instance: [10, 0],
                     material: 3,
                     cells: [{1, 1, 1}],
                     target: %{
                       granularity: 2,
                       micro: {8, 8, 8},
                       incarnation: 10,
                       owner: {10, 0},
                       material: 3,
                       direction: nil
                     }
                   }
                 ]
               }
             }
           ] = GateServer.Npc.Perception.project(outcome, [], {15.0, 64.9, 10.0})

    # owner {41, 5}：kind 码 1（棱条）、axis 码 2 → "edge"、"z"。
    edge = %{outcome | data: %{seq: 9, property_states: [%{row | owner: {41, 5}}]}}

    assert [%{data: %{attachments: [%{kind: "edge", axis: "z"}]}}] =
             GateServer.Npc.Perception.project(edge, [], {15.0, 64.9, 10.0})

    # 建成区能有几百件：只给模型最近的 24 件，总数另报。
    # 第 i 件在 x = 10i 米；自己在 x = 12 → 最近的是第 1 件（2 米），第 24 件之后的被裁掉。
    many = for i <- 1..40, do: %{row | micro: {i * 80, 512, 80}, incarnation: i, owner: {i, 1}}
    far_first = %{outcome | data: %{seq: 9, property_states: Enum.reverse(many)}}

    assert [%{data: %{attachments: listed, total: %{attachments: 40, components: 0}}}] =
             GateServer.Npc.Perception.project(far_first, [], {12.0, 64.9, 10.0})

    assert Enum.to_list(1..24) == Enum.map(listed, & &1.attachment_id) |> Enum.sort()
    assert 1 == hd(listed).attachment_id

    # 模型看到的是 JSON（Context.plain：元组 → 数组）；原样抄回 target 就得到对这件附件的命令。
    copied = GateServer.Npc.Context.plain(thing)

    response = %{
      "output" => [call("use_tool", %{tool_id: 7, target: copied}), call("inspect", %{})]
    }

    assert [
             %{
               id: 1,
               verb: :use_tool,
               tool_id: 7,
               direction: nil,
               target: %{
                 granularity: 3,
                 micro: {120, 512, 80},
                 incarnation: 41,
                 owner: {41, 1},
                 material: 11
               }
             },
             %{id: 2, verb: :inspect}
           ] == Llm.commands(response, 1, @profile)
  end

  test "a probe hit the model sees carries a target handle with the probe's direction" do
    hit = %{
      granularity: 0,
      micro: {128, 520, 80},
      incarnation: 3,
      owner: {0, 0},
      material: 11,
      current_hp: 100.0,
      direction: {1.0, 0.0, 0.0}
    }

    outcome = %{id: 2, verb: :probe_toward, status: :done, reason: nil, data: hit}

    assert [
             %{
               data: %{
                 current_hp: 100.0,
                 target: %{
                   granularity: 0,
                   micro: {128, 520, 80},
                   incarnation: 3,
                   owner: {0, 0},
                   material: 11,
                   direction: {1.0, 0.0, 0.0}
                 }
               }
             }
           ] = GateServer.Npc.Perception.project(outcome, [], nil)
  end

  # 给模型的细化行：逐个 micro 换成按材质合并的闭区间盒，并起来恰好等于原占用（手算小例）。
  test "refined rows reach the model as per-material micro boxes whose union is exactly the occupied micro cells" do
    micro = fn x, y, z, m -> %{micro: {x, y, z}, material: m, instance: [3, 0]} end
    # 宏格 (1,0,0)：x = 8 这一面 8×8 石（材料 11）+ 一个木 micro（材料 19）在 (15,0,0)。
    face = for y <- 0..7, z <- 0..7, do: micro.(8, y, z, 11)
    row = %{cell: [1, 0, 0], material: 0, refined: true, slots: [], placed_by: nil, micro_cells: [micro.(15, 0, 0, 19) | face]}

    assert %{micro_boxes: [%{material: 11, box: [8, 0, 0, 8, 7, 7]}, %{material: 19, box: [15, 0, 0, 15, 0, 0]}]} =
             compact = GateServer.Npc.Perception.compact_refined(row)

    refute Map.has_key?(compact, :micro_cells)

    # L 形（不能一个盒装下）：盒互不重叠、并起来等于原集合。
    l = [{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {0, 1, 0}, {0, 2, 0}]
    %{micro_boxes: boxes} =
      GateServer.Npc.Perception.compact_refined(%{row | micro_cells: for({x, y, z} <- l, do: micro.(x, y, z, 11))})

    covered = for %{box: [x0, y0, z0, x1, y1, z1]} <- boxes, x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x, y, z}
    assert Enum.sort(covered) == Enum.sort(l)
    assert length(covered) == length(Enum.uniq(covered))

    # 没有 micro 明细的行原样返回。
    plain = Map.delete(row, :micro_cells)
    assert plain == GateServer.Npc.Perception.compact_refined(plain)
  end

  test "a look outcome is kept as solid columns only, and only the latest three looks keep their data" do
    cell = fn coord, material -> %{cell: coord, material: material, refined: false, slots: []} end

    look = fn id, cells ->
      %{id: id, verb: :look, status: :done, reason: nil, data: %{seq: 9, probe_occupancy: cells}}
    end

    first = GateServer.Npc.Perception.project(look.(1, [cell.([16, 64, 10], 11)]), [], nil)
    assert [%{data: %{solid: %{"16,10" => [[64, 11]]}}}] = first

    # (16,64,10) 是 9101 号角色花材料放下的：模型看到的那一项多一个放置者；其余是天然地形。
    cells = [
      cell.([16, 63, 10], 11),
      Map.put(cell.([16, 64, 10], 11), :placed_by, 9101),
      cell.([16, 65, 10], 0),
      cell.([15, 63, 10], 11)
    ]

    second = GateServer.Npc.Perception.project(look.(2, cells), first, nil)

    assert [
             %{
               id: 2,
               data: %{
                 solid: %{"16,10" => [[63, 11], [64, 11, 9101]], "15,10" => [[63, 11]]} = solid
               }
             },
             %{id: 1, verb: :look, data: %{solid: %{"16,10" => [[64, 11]]}}}
           ] = second

    assert 2 == map_size(solid)

    # 契约（2026-10-08 起）：最近三次 look 保留内容，第四次时最早那次只留结论——大于一次 look 上限的区域分几次看，
    # 模型要同时看得到几部分才不会回头反复看。
    fourth =
      GateServer.Npc.Perception.project(
        look.(4, [cell.([20, 64, 10], 11)]),
        GateServer.Npc.Perception.project(look.(3, [cell.([18, 64, 10], 11)]), second, nil),
        nil
      )

    assert [%{id: 4, data: %{}}, %{id: 3, data: %{}}, %{id: 2, data: %{}}, %{id: 1, data: nil}] = fourth
    assert Enum.all?(Enum.take(fourth, 3), &(&1.data != nil))
  end

  test "look never reports a refined occupied macro as air" do
    row = %{
      cell: [2, 3, 4],
      material: 0,
      refined: true,
      slots: [%{material: 19, instance: [41, 0], count: 1}],
      placed_by: nil
    }

    outcome = %{id: 1, verb: :look, status: :done, reason: nil, data: %{probe_occupancy: [row]}}

    assert [%{data: %{solid: %{}, refined: [^row]}}] =
             GateServer.Npc.Perception.project(outcome, [], nil)
  end

  test "published definition IDs remain hexadecimal even when the digest bytes are valid text" do
    observation = %{self: %{entity_id: 7, position: {1, 2, 3}}, balances: nil, entities: []}
    profile = %{goal: "g", tools: %{}, endpoint: %{model: "m"}}

    outcomes = [
      %{
        id: 1,
        verb: :design_house,
        status: :done,
        data: %{definition_id: :binary.copy(<<42>>, 32)}
      }
    ]

    input = Llm.body(profile, observation, outcomes).input |> Jason.decode!()
    assert hd(input["outcomes"])["data"]["definition_id"] == String.duplicate("2a", 32)
  end

  test "request body is plain JSON: tuples become lists, outcomes oldest first, one required tool call" do
    observation = %{
      self: %{entity_id: 77, position: {1.0, 2.0, 3.0}, tick: 9},
      entities: [],
      pending: [],
      balances: [
        %{material: 11, balance: 768, cost: 512, seq: 4},
        %{material: 3, balance: 0, cost: 512, seq: 4}
      ]
    }

    outcomes = [%{id: 2, reason: {:stale, 1}}, %{id: 1, reason: nil}]
    profile = %{goal: "g", tools: %{1 => "镐", 9 => "点火器"}, endpoint: %{model: "m"}}
    body = Llm.body(profile, observation, outcomes)
    input = Jason.decode!(body.input)

    assert [1.0, 2.0, 3.0] == input["self"]["position"]
    # 背包只报有余额的材料，折成还能放几个整格；没读过时是 null。
    assert [%{"material" => 11, "cells" => 1.5}] == input["balances"]

    assert nil ==
             Jason.decode!(Llm.body(profile, %{observation | balances: nil}, []).input)[
               "balances"
             ]

    assert [1, 2] == Enum.map(input["outcomes"], & &1["id"])
    assert ["stale", 1] == List.last(input["outcomes"])["reason"]
    assert {"required", false, "m"} == {body.tool_choice, body.parallel_tool_calls, body.model}
    # 思考强度随 endpoint 配置，缺省 low。
    assert %{effort: "low"} == body.reasoning

    assert %{effort: "high"} ==
             Llm.body(put_in(profile.endpoint[:effort], "high"), observation, outcomes).reasoning

    # 工具带是 tool_id 的唯一来源：输入里列出用途，schema 里必填且只能取带着的 id。
    assert %{"1" => "镐", "9" => "点火器"} == input["tools"]
    probe = Enum.find(body.tools, &(&1.name == "probe_toward")).parameters
    assert [1, 9] == probe.properties.tool_id.enum
    assert "tool_id" in probe.required

    # 能力库 I2b：工具表 = Abilities 全部组（未配置 groups、无技能）+ wait；say 不投影，新增 dismantle / craft / eat / read_catalog。
    assert ~w(attach clear_targets craft cycle_focus detach dismantle eat get_aim get_target_status get_targets get_view get_visible_entities inspect look look_at move_to place pour prefab probe_toward query_balances read_catalog recall remember remove_focus remove_target scoop search_memory select_target set_focus stop toggle_mark use_tool wait) ==
             body.tools |> Enum.map(& &1.name) |> Enum.sort()

    assert Enum.all?(body.tools, &(&1.strict == true))

    enriched =
      Map.merge(observation, %{
        view: %{origin: {-2.0, 4.6, 3.0}, direction: {1.0, 0.0, 0.0}},
        targets: %{
          enemy: %{
            members: [%{entity_id: 7, entity_epoch: 9}],
            focus: %{entity_id: 7, entity_epoch: 9}
          }
        }
      })

    input_with_view = Jason.decode!(Llm.body(profile, enriched, []).input)
    assert input_with_view["view"]["origin"] == [-2.0, 4.6, 3.0]

    assert input_with_view["targets"]["enemy"]["focus"] == %{
             "entity_id" => 7,
             "entity_epoch" => 9
           }

    refute Map.has_key?(input, "notes")
    assert input["experiences"] == []
    assert body.instructions =~ "记忆不是世界真值"
    assert body.instructions =~ "look/inspect"
    refute Enum.find(body.tools, &(&1.name == "prefab")).description =~ "建造者权限"

    experiences = [
      %{text: "Finished the west wall", position: [-1, 2, 3], at: "2026-09-22T00:00:00Z"}
    ]

    assert [
             %{
               "text" => "Finished the west wall",
               "position" => [-1, 2, 3],
               "at" => "2026-09-22T00:00:00Z"
             }
           ] ==
             Jason.decode!(Llm.body(profile, observation, [], experiences).input)["experiences"]

    failed =
      Jason.decode!(Llm.body(profile, observation, [], %{memory_error: :database_down}).input)

    assert failed["memory_error"] == "database_down"
    refute Map.has_key?(failed, "experiences")
  end

  test "asks only when idle with news: not while a command is pending, not again until a new outcome" do
    test = self()

    request = fn _endpoint, body ->
      send(test, {:asked, Jason.decode!(body.input)})
      {:ok, %{"output" => [call("move_to", %{x: 5, z: 6})]}}
    end

    profile = %{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request}
    # init 在 Body 进程里调用：这里测试进程就是 Body，命令以 cast 投回。
    brain = brain(profile)

    idle = %{
      self: %{entity_id: 77, tick: 1, position: {0.0, 0.0, 0.0}},
      entities: [],
      pending: [],
      balances: nil
    }

    {[], ^brain} =
      Llm.handle_event({:observation, %{idle | pending: [%{id: 9, verb: :move_to}]}}, brain)

    refute_receive {:asked, _}, 200

    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, %{"goal" => "g", "outcomes" => []}}
    assert_receive {:"$gen_cast", {:command, %{id: 1, verb: :move_to, position: {5, 6}}}}

    Llm.handle_event({:observation, idle}, brain)
    refute_receive {:asked, _}, 1_300

    Llm.handle_event(
      {:outcome, %{id: 1, verb: :move_to, status: :done, reason: nil, data: nil}},
      brain
    )

    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, %{"outcomes" => [%{"id" => 1, "status" => "done"}]}}, 2_000
  end

  test "remember and recall enter normal outcome history with original calls and refresh recent every round" do
    test = self()
    answers = :counters.new(1, [])

    request = fn _endpoint, body ->
      :counters.add(answers, 1, 1)
      send(test, {:asked, :counters.get(answers, 1), Jason.decode!(body.input)})

      case :counters.get(answers, 1) do
        1 -> {:ok, %{"output" => [call("remember", %{key: "plan", text: "先挖后砌"})]}}
        2 -> {:ok, %{"output" => [call("recall", %{key: "plan"})]}}
        _ -> {:ok, %{"output" => [call("wait", %{seconds: 300})]}}
      end
    end

    brain = brain(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})

    idle = %{
      self: %{entity_id: 77, tick: 1, position: {-1, 2, 3}},
      entities: [],
      pending: [],
      balances: nil
    }

    observations(brain, idle)
    assert_receive {:recent_read, 77, 5}
    assert_receive {:asked, 1, %{"experiences" => []}}
    assert_receive {:memory_written, 77, "plan", %{"text" => "先挖后砌", "position" => [-1, 2, 3]}}
    :ok = Store.events([%{text: "new event", place: {4, 5, 6}, at: ~U[2026-09-22 00:00:00Z]}])
    assert_receive {:asked, 2, input}, 2_000
    assert_receive {:recent_read, 77, 5}
    assert [%{"text" => "new event", "position" => [4, 5, 6]}] = input["experiences"]
    assert [%{"key" => "plan", "body" => %{"text" => "先挖后砌"}}] = input["memories"]
    assert_receive {:memory_search, 77, _}

    assert [
             %{
               "id" => 1,
               "verb" => "remember",
               "status" => "done",
               "command" => %{
                 "tool" => "remember",
                 "args" => %{"key" => "plan", "text" => "先挖后砌"}
               }
             }
           ] = input["outcomes"]

    assert_receive {:asked, 3, input}, 2_000
    assert_receive {:recent_read, 77, 5}
    assert [1, 2] == Enum.map(input["outcomes"], & &1["id"])

    assert %{
             "verb" => "recall",
             "command" => %{"tool" => "recall", "args" => %{"key" => "plan"}},
             "data" => %{"body" => %{"text" => "先挖后砌"}}
           } = List.last(input["outcomes"])

    refute_receive {:"$gen_cast", {:command, _}}, 100
  end

  test "a restarted Brain recalls the same cid's stored memory" do
    test = self()

    idle = %{
      self: %{entity_id: 77, tick: 1, position: {1, 2, 3}},
      entities: [],
      pending: [],
      balances: nil
    }

    first =
      brain(%{
        goal: "g",
        tools: %{1 => "镐"},
        endpoint: %{model: "m"},
        request: fn _, _ ->
          {:ok, %{"output" => [call("remember", %{key: "plan", text: "Restart survives"})]}}
        end
      })

    Llm.handle_event({:observation, idle}, first)
    assert_receive {:memory_written, 77, "plan", _}
    stop_brain(first)
    answers = :counters.new(1, [])

    request = fn _, body ->
      :counters.add(answers, 1, 1)
      send(test, {:restarted_input, Jason.decode!(body.input)})
      name = if :counters.get(answers, 1) == 1, do: "recall", else: "wait"

      {:ok,
       %{
         "output" => [call(name, if(name == "recall", do: %{key: "plan"}, else: %{seconds: 300}))]
       }}
    end

    second = brain(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})
    observations(second, idle)
    assert_receive {:restarted_input, %{"outcomes" => []}}

    assert_receive {:restarted_input,
                    %{
                      "outcomes" => [
                        %{
                          "verb" => "recall",
                          "data" => %{"body" => %{"text" => "Restart survives"}}
                        }
                      ]
                    }},
                   2_000
  end

  test "local calls including wait consume ids and Body outcomes keep their own original command" do
    test = self()
    answers = :counters.new(1, [])

    request = fn _, body ->
      :counters.add(answers, 1, 1)
      send(test, {:mixed_input, :counters.get(answers, 1), Jason.decode!(body.input)})

      output =
        case :counters.get(answers, 1) do
          1 ->
            [
              call("remember", %{key: "plan", text: "Keep this"}),
              call("move_to", %{x: 5, z: 6}),
              call("recall", %{key: "plan"})
            ]

          2 ->
            [call("wait", %{seconds: 1})]

          3 ->
            [call("stop", %{})]

          _ ->
            [call("wait", %{seconds: 300})]
        end

      {:ok, %{"output" => output}}
    end

    pid = brain(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})

    idle = %{
      self: %{entity_id: 77, tick: 1, position: {1, 2, 3}},
      entities: [],
      pending: [],
      balances: nil
    }

    observations(pid, idle)
    assert_receive {:mixed_input, 1, _}
    assert_receive {:"$gen_cast", {:command, %{id: 2, verb: :move_to}}}

    Llm.handle_event(
      {:outcome, %{id: 2, verb: :move_to, status: :done, reason: nil, data: nil}},
      pid
    )

    assert_receive {:mixed_input, 2, input}, 2_000
    assert [1, 2, 3] == input["outcomes"] |> Enum.map(& &1["id"]) |> Enum.sort()

    assert %{"command" => %{"tool" => "move_to", "args" => %{"x" => 5, "z" => 6}}} =
             Enum.find(input["outcomes"], &(&1["id"] == 2))

    assert_receive {:mixed_input, 3, _}, 2_000
    assert_receive {:"$gen_cast", {:command, %{id: 5, verb: :stop}}}
  end

  test "recent database failure appears explicitly in model input and is never empty history" do
    test = self()

    pid =
      brain(%{
        goal: "g",
        tools: %{1 => "镐"},
        memory: UnavailableStore,
        endpoint: %{model: "m"},
        request: fn _, body ->
          send(test, {:memory_failed, Jason.decode!(body.input)})
          {:ok, %{"output" => [call("wait", %{seconds: 300})]}}
        end
      })

    Llm.handle_event(
      {:observation,
       %{
         self: %{entity_id: 77, tick: 1, position: {1, 2, 3}},
         entities: [],
         pending: [],
         balances: nil
       }},
      pid
    )

    assert_receive {:memory_failed, input}
    assert ["memory_unavailable", "Elixir.DBConnection.ConnectionError"] == input["memory_error"]
    refute Map.has_key?(input, "experiences")
    refute Jason.encode!(input) =~ "private connection"
  end

  # 回归：真实模型砌了两格就原地反复 look —— 它看不到自己上次调用了什么，Outcome 里又只有 seq。
  test "the outcome shown to the model carries the call that caused it" do
    test = self()
    answers = :counters.new(1, [])

    request = fn _endpoint, body ->
      :counters.add(answers, 1, 1)
      send(test, {:asked, :counters.get(answers, 1), Jason.decode!(body.input)["outcomes"]})
      {:ok, %{"output" => [call("place", %{x: 8, y: 64, z: 14, material: 11, tool_id: 1})]}}
    end

    brain = brain(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})

    idle = %{
      self: %{entity_id: 77, tick: 1, position: {0.0, 0.0, 0.0}},
      entities: [],
      pending: [],
      balances: nil
    }

    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, 1, []}
    assert_receive {:"$gen_cast", {:command, %{id: 1, verb: :place, coord: {8, 64, 14}}}}

    Llm.handle_event(
      {:outcome, %{id: 1, verb: :place, status: :done, reason: nil, data: %{seq: 5}}},
      brain
    )

    Process.sleep(1_000)
    Llm.handle_event({:observation, idle}, brain)

    assert_receive {:asked, 2,
                    [
                      %{
                        "id" => 1,
                        "status" => "done",
                        "command" => %{
                          "tool" => "place",
                          "args" => %{
                            "x" => 8,
                            "y" => 64,
                            "z" => 14,
                            "material" => 11,
                            "tool_id" => 1
                          }
                        }
                      }
                    ]},
                   1_000
  end

  test "wait is not a Body command: nothing is sent, and the model is asked again only after the wait" do
    test = self()
    answers = :counters.new(1, [])

    request = fn _endpoint, _body ->
      :counters.add(answers, 1, 1)
      send(test, {:asked, :counters.get(answers, 1)})
      {:ok, %{"output" => [call("wait", %{seconds: 1})]}}
    end

    brain = brain(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})

    idle = %{
      self: %{entity_id: 77, tick: 1, position: {0.0, 0.0, 0.0}},
      entities: [],
      pending: [],
      balances: nil
    }

    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, 1}
    refute_receive {:"$gen_cast", {:command, _}}, 300

    # 等待期间的 Observation 不触发询问；约 1 秒后 wake，再来一个 Observation 才问第二次。
    Llm.handle_event({:observation, idle}, brain)
    refute_receive {:asked, 2}, 500
    Process.sleep(700)
    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, 2}, 1_000
  end

  # —— 2026-10-06 评审修复的回归：模型输出是外部输入，询问必须有界且不会永久沉默 ——

  defp idle(entities \\ []),
    do: %{
      self: %{entity_id: 77, tick: 1, position: {0.0, 0.0, 0.0}},
      entities: entities,
      pending: [],
      balances: nil
    }

  # 按顺序给出应答，每次询问都报给测试进程（第 n 次 → {:asked, n, input}）。
  defp scripted(answers) do
    test = self()
    count = :counters.new(1, [])

    fn _endpoint, body ->
      :counters.add(count, 1, 1)
      n = :counters.get(count, 1)
      send(test, {:asked, n, Jason.decode!(body.input)})
      Enum.at(answers, n - 1, {:ok, %{"output" => [call("wait", %{seconds: 300})]}})
    end
  end

  test "an answer without any tool call is asked again after a backoff instead of going silent" do
    request =
      scripted([
        {:ok,
         %{"status" => "incomplete", "output" => [%{"type" => "reasoning", "summary" => []}]}}
      ])

    brain = brain(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})
    observations(brain, idle())
    assert_receive {:asked, 1, _}
    # 第一次退避 2 秒：不会立刻重问，但一定会重问。
    refute_receive {:asked, 2, _}, 1_500
    assert_receive {:asked, 2, _}, 2_000
  end

  test "malformed arguments and unknown tools are rejected locally and shown to the model; nothing reaches Body" do
    request =
      scripted([
        {:ok,
         %{
           "output" => [
             %{
               "type" => "function_call",
               "name" => "place",
               "arguments" => "{not json",
               "call_id" => "a"
             }
           ]
         }},
        {:ok, %{"output" => [call("dance", %{style: "waltz"})]}}
      ])

    brain = brain(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})
    observations(brain, idle())
    assert_receive {:asked, 1, _}

    assert_receive {:asked, 2,
                    %{
                      "outcomes" => [
                        %{
                          "verb" => "invalid_tool_arguments",
                          "status" => "rejected",
                          "command" => %{"tool" => "place", "args" => "invalid_tool_arguments"}
                        }
                      ]
                    }},
                   3_000

    assert_receive {:asked, 3,
                    %{
                      "outcomes" => [
                        _,
                        %{"verb" => "unknown_tool", "command" => %{"tool" => "dance"}}
                      ]
                    }},
                   3_000

    refute_received {:"$gen_cast", {:command, _}}
    assert Process.alive?(brain)
  end

  test "a prefab instance that is not a list is rejected locally, not passed on and not a crash" do
    response = %{"output" => [call("prefab", %{op: "remove", instance: "abc"})]}

    assert [%{id: 1, verb: :invalid_tool_arguments, tool: "prefab"}] ==
             Llm.commands(response, 1, @profile)
  end

  # 滑动窗口（手算小例，分钟换成毫秒）：第 45–59 分钟 15 次、第 60–70 分钟 11 次。固定窗口（第 60 分钟清零）在第 71 分钟只算
  # 新窗口的 11 次，会放行；滑动窗口算第 11–71 分钟内的 26 次，额度 20 时拒绝。之后逐次滑出：第 106 分钟剩第 47–70 分钟的
  # 24 次，第 112 分钟剩第 53–70 分钟的 18 次，少于 20 才放行。
  test "the hourly budget is a sliding hour: any 60 minutes hold at most the limit" do
    min = 60_000
    asks = Enum.map(Enum.reverse(Enum.to_list(45..59) ++ Enum.to_list(60..70)), &(&1 * min))

    assert length(Llm.recent_asks(asks, 71 * min)) == 26
    # 第 106 分钟：恰好一小时前（第 46 分钟）及更早的都滑出。
    assert length(Llm.recent_asks(asks, 106 * min)) == 24
    # 第 112 分钟：第 52 分钟及以前滑出，剩第 53–70 分钟的 18 次，额度 20 放行。
    assert length(Llm.recent_asks(asks, 112 * min)) == 18
  end

  test "asks are capped per hour: after the budget is used the brain stays quiet" do
    request =
      scripted([
        {:ok, %{"output" => [call("stop", %{})]}},
        {:ok, %{"output" => [call("stop", %{})]}},
        {:ok, %{"output" => [call("stop", %{})]}}
      ])

    brain =
      brain(%{
        goal: "g",
        tools: %{1 => "镐"},
        endpoint: %{model: "m"},
        request: request,
        max_requests_per_hour: 2
      })

    observations(brain, idle())

    for id <- 1..2 do
      assert_receive {:asked, ^id, _}, 3_000
      assert_receive {:"$gen_cast", {:command, %{id: ^id, verb: :stop}}}

      Llm.handle_event(
        {:outcome, %{id: id, verb: :stop, status: :done, reason: nil, data: nil}},
        brain
      )
    end

    refute_receive {:asked, 3, _}, 2_500
  end

  test "someone walking up wakes a waiting brain; someone far away does not" do
    request = scripted([{:ok, %{"output" => [call("wait", %{seconds: 300})]}}])
    brain = brain(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})
    Llm.handle_event({:observation, idle()}, brain)
    assert_receive {:asked, 1, _}
    Process.sleep(1_100)

    far = %{entity_id: 5, entity_epoch: 1, kind: 0, tick: 1, position: {20.0, 0.0, 0.0}}
    Llm.handle_event({:observation, idle([far])}, brain)
    refute_receive {:asked, 2, _}, 500

    near = %{far | position: {3.0, 0.0, 0.0}}
    Llm.handle_event({:observation, idle([near])}, brain)
    assert_receive {:asked, 2, %{"entities" => [%{"entity_id" => 5}]}}, 1_000
  end
end
