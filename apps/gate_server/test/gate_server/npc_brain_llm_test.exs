defmodule GateServer.NpcBrainLlmTest do
  @moduledoc "只测试：LLM 决策后端的译码与询问时机。模型接口用冻结的 Responses 应答样本替身；真实接口见 :live_llm 用例。"
  use ExUnit.Case, async: false
  alias GateServer.Npc.Brain.Llm

  @target %{micro: {128, 520, 80}, incarnation: 3, owner: {0, 0}, material: 11, current_hp: 100.0}
  defp call(name, args),
    do: %{"type" => "function_call", "name" => name, "arguments" => Jason.encode!(args), "call_id" => "c"}

  test "function calls become commands; reasoning items are ignored; probe direction is normalised" do
    response = %{
      "output" => [
        %{"type" => "reasoning", "summary" => []},
        call("move_to", %{x: 14, z: 10.5}),
        call("probe_toward", %{dx: 3, dy: 0, dz: 4, tool_id: 1}),
        call("move_to", %{x: 49.5, z: 64.5, y: 523})
      ]
    }

    assert [
             %{id: 7, verb: :move_to, position: {14, 10.5}, tolerance: 0.5},
             %{id: 8, verb: :probe_toward, tool_id: 1, direction: {0.6, 0.0, 0.8}},
             %{id: 9, verb: :move_to, position: {49.5, 64.5}, y: 523, tolerance: 0.5}
           ] == Llm.commands(response, nil, %{}, 7)
  end

  test "use_tool carries the last successful probe; without one it is left for the Body to reject" do
    probe = %{direction: {1.0, 0.0, 0.0}, target: @target}
    response = %{"output" => [call("use_tool", %{tool_id: 1})]}

    assert [%{verb: :use_tool, direction: {1.0, 0.0, 0.0}, target: @target, tool_id: 1}] =
             Llm.commands(response, probe, %{}, 1)

    assert [%{verb: :use_tool, direction: nil, target: nil}] = Llm.commands(response, nil, %{}, 1)
  end

  test "building verbs: cells are integer macro coords, the default tool applies unless the model names another" do
    response = %{
      "output" => [
        call("look", %{x0: 15, y0: 63, z0: 9, x1: 17, y1: 66, z1: 11}),
        call("place", %{x: 16, y: 65, z: 10, material: 11, tool_id: 1}),
        call("scoop", %{x: 50, y: 519, z: 64, material: 21, tool_id: 11}),
        call("pour", %{x: 50, y: 519, z: 64, material: 21, tool_id: 12}),
        call("query_balances", %{}),
        call("probe_toward", %{dx: 1, dy: 0, dz: 0, tool_id: 9})
      ]
    }

    assert [
             %{id: 1, verb: :look, min: {15, 63, 9}, max: {17, 66, 11}},
             %{id: 2, verb: :place, coord: {16, 65, 10}, material: 11, tool_id: 1},
             %{id: 3, verb: :scoop, coord: {50, 519, 64}, material: 21, tool_id: 11},
             %{id: 4, verb: :pour, coord: {50, 519, 64}, material: 21, tool_id: 12},
             %{id: 5, verb: :query_balances},
             %{id: 6, verb: :probe_toward, tool_id: 9, direction: {1.0, 0.0, 0.0}}
           ] == Llm.commands(response, nil, %{}, 1)
  end

  test "attachment and prefab tools: hex definition ids become 32-byte binaries, a bad one is left for the Body to reject" do
    id = String.duplicate("2a", 32)

    response = %{
      "output" => [
        call("attach", %{kind: 0, axis: 1, size: 8, x: 120, y: 512, z: 80, material: 11, tool_id: 1}),
        call("detach", %{kind: 0, axis: 1, x: 120, y: 512, z: 80, material: 11, attachment_id: 7, tool_id: 3}),
        call("prefab", %{op: "place", definition: id, x: 15, y: 64, z: 12, orientation: 5}),
        call("prefab", %{op: "remove", instance: [10, 0]}),
        call("prefab", %{op: "replace", instance: [10, 0], definition: "zz"})
      ]
    }

    assert [
             %{verb: :attach, kind: 0, axis: 1, size: 8, anchor: {120, 512, 80}, material: 11, attachment_id: 0, tool_id: 1},
             %{verb: :detach, size: 1, attachment_id: 7, tool_id: 3},
             %{verb: :prefab_place, definition_id: definition, anchor: {15, 64, 12}, orientation: 5},
             %{verb: :prefab_remove, instance_id: {10, 0}},
             %{verb: :prefab_replace, instance_id: {10, 0}, definition_id: nil}
           ] = Llm.commands(response, nil, %{}, 1)

    assert :binary.copy(<<42>>, 32) == definition
  end

  test "inspect: attachments become addressable targets for use_tool, and the model sees ids, not raw rows" do
    row = %{
      granularity: 3, micro: {120, 512, 80}, incarnation: 41, owner: {41, 1}, material: 11,
      hp: 0.19, max_hp: 0.19, digest: <<1, 2>>, observation_cells: [{15, 63, 10}, {15, 64, 10}]
    }

    part = %{granularity: 2, micro: {8, 8, 8}, incarnation: 10, owner: {10, 0}, material: 3, observation_cells: [{1, 1, 1}]}
    outcome = %{id: 4, verb: :inspect, status: :done, reason: nil, data: %{seq: 9, property_states: [row, part]}}

    assert [
             %{
               data: %{
                 attachments: [%{attachment_id: 41, kind: 0, axis: 1, micro: {120, 512, 80}, material: 11, hp: 0.19}],
                 components: [%{instance: [10, 0], material: 3, cells: [{1, 1, 1}]}]
               }
             }
           ] = Llm.remember(outcome, [], {15.0, 64.9, 10.0})

    # 建成区能有几百件：只给模型最近的 24 件，总数另报。
    # 第 i 件在 x = 10i 米；自己在 x = 12 → 最近的是第 1 件（2 米），第 24 件之后的被裁掉。
    many = for i <- 1..40, do: %{row | micro: {i * 80, 512, 80}, incarnation: i, owner: {i, 1}}
    far_first = %{outcome | data: %{seq: 9, property_states: Enum.reverse(many)}}
    assert [%{data: %{attachments: listed, total: %{attachments: 40, components: 0}}}] = Llm.remember(far_first, [], {12.0, 64.9, 10.0})
    assert Enum.to_list(1..24) == Enum.map(listed, & &1.attachment_id) |> Enum.sort()
    assert 1 == hd(listed).attachment_id

    things = %{41 => Map.take(row, [:granularity, :micro, :incarnation, :owner, :material])}

    response = %{
      "output" => [
        call("use_tool", %{tool_id: 7, attachment_id: 41}),
        call("inspect", %{}),
        call("say", %{text: "墙砌好了"})
      ]
    }

    assert [
             %{verb: :use_tool, tool_id: 7, direction: {1.0, 0.0, 0.0}, target: %{granularity: 3, incarnation: 41, owner: {41, 1}}},
             %{id: 2, verb: :inspect},
             %{id: 3, verb: :say, text: "墙砌好了"}
           ] = Llm.commands(response, nil, things, 1)
  end

  test "a look outcome is kept as solid columns only, and only the latest look keeps its data" do
    cell = fn coord, material -> %{cell: coord, material: material, refined: false, slots: []} end
    look = fn id, cells -> %{id: id, verb: :look, status: :done, reason: nil, data: %{seq: 9, probe_occupancy: cells}} end

    first = Llm.remember(look.(1, [cell.([16, 64, 10], 11)]), [], nil)
    assert [%{data: %{solid: %{"16,10" => [[64, 11]]}}}] = first

    cells = [cell.([16, 63, 10], 11), cell.([16, 64, 10], 11), cell.([16, 65, 10], 0), cell.([15, 63, 10], 11)]

    assert [
             %{id: 2, data: %{solid: %{"16,10" => [[63, 11], [64, 11]], "15,10" => [[63, 11]]} = solid}},
             %{id: 1, verb: :look, data: nil}
           ] = Llm.remember(look.(2, cells), first, nil)

    assert 2 == map_size(solid)
  end

  test "request body is plain JSON: tuples become lists, outcomes oldest first, one required tool call" do
    observation = %{
      self: %{position: {1.0, 2.0, 3.0}, tick: 9},
      entities: [],
      pending: [],
      balances: [%{material: 11, balance: 768, cost: 512, seq: 4}, %{material: 3, balance: 0, cost: 512, seq: 4}]
    }

    outcomes = [%{id: 2, reason: {:stale, 1}}, %{id: 1, reason: nil}]
    profile = %{goal: "g", tools: %{1 => "镐", 9 => "点火器"}, endpoint: %{model: "m"}}
    body = Llm.body(profile, observation, outcomes)
    input = Jason.decode!(body.input)

    assert [1.0, 2.0, 3.0] == input["self"]["position"]
    # 背包只报有余额的材料，折成还能放几个整格；没读过时是 null。
    assert [%{"material" => 11, "cells" => 1.5}] == input["balances"]
    assert nil == Jason.decode!(Llm.body(profile, %{observation | balances: nil}, []).input)["balances"]
    assert [1, 2] == Enum.map(input["outcomes"], & &1["id"])
    assert ["stale", 1] == List.last(input["outcomes"])["reason"]
    assert {"required", false, "m"} == {body.tool_choice, body.parallel_tool_calls, body.model}
    # 思考强度随 endpoint 配置，缺省 low。
    assert %{effort: "low"} == body.reasoning
    assert %{effort: "high"} == Llm.body(put_in(profile.endpoint[:effort], "high"), observation, outcomes).reasoning

    # 工具带是 tool_id 的唯一来源：输入里列出用途，schema 里必填且只能取带着的 id。
    assert %{"1" => "镐", "9" => "点火器"} == input["tools"]
    probe = Enum.find(body.tools, &(&1.name == "probe_toward")).parameters
    assert [1, 9] == probe.properties.tool_id.enum
    assert "tool_id" in probe.required
    assert ~w(attach detach inspect look move_to note place pour prefab probe_toward query_balances say scoop stop use_tool wait) ==
             body.tools |> Enum.map(& &1.name) |> Enum.sort()
  end

  test "asks only when idle with news: not while a command is pending, not again until a new outcome" do
    test = self()

    request = fn _endpoint, body ->
      send(test, {:asked, Jason.decode!(body.input)})
      {:ok, %{"output" => [call("move_to", %{x: 5, z: 6})]}}
    end

    profile = %{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request}
    # init 在 Body 进程里调用：这里测试进程就是 Body，命令以 cast 投回。
    brain = Llm.init(profile)
    idle = %{self: %{tick: 1, position: {0.0, 0.0, 0.0}}, entities: [], pending: [], balances: nil}

    {[], ^brain} = Llm.handle_event({:observation, %{idle | pending: [%{id: 9, verb: :move_to}]}}, brain)
    refute_receive {:asked, _}, 200

    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, %{"goal" => "g", "outcomes" => []}}
    assert_receive {:"$gen_cast", {:command, %{id: 1, verb: :move_to, position: {5, 6}}}}

    Llm.handle_event({:observation, idle}, brain)
    refute_receive {:asked, _}, 1_300

    Llm.handle_event({:outcome, %{id: 1, verb: :move_to, status: :done, reason: nil, data: nil}}, brain)
    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, %{"outcomes" => [%{"id" => 1, "status" => "done"}]}}, 2_000
  end

  test "note is the adapter's own memory: nothing reaches the Body, the next request carries it, and it is asked again at once" do
    test = self()
    answers = :counters.new(1, [])

    request = fn _endpoint, body ->
      :counters.add(answers, 1, 1)
      send(test, {:asked, :counters.get(answers, 1), Jason.decode!(body.input)["notes"]})

      case :counters.get(answers, 1) do
        1 -> {:ok, %{"output" => [call("note", %{text: "计划：先挖后砌。已完成：无。"})]}}
        _ -> {:ok, %{"output" => [call("wait", %{seconds: 300})]}}
      end
    end

    brain = Llm.init(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})
    idle = %{self: %{tick: 1, position: {0.0, 0.0, 0.0}}, entities: [], pending: [], balances: nil}
    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, 1, nil}
    refute_receive {:"$gen_cast", {:command, _}}, 300

    # 没有新的 Outcome，但便签本身就是新情况：过了最小间隔、来一个 Observation 就再问，输入里带着便签。
    Process.sleep(1_000)
    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, 2, "计划：先挖后砌。已完成：无。"}, 1_000
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

    brain = Llm.init(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})
    idle = %{self: %{tick: 1, position: {0.0, 0.0, 0.0}}, entities: [], pending: [], balances: nil}
    Llm.handle_event({:observation, idle}, brain)
    assert_receive {:asked, 1, []}
    assert_receive {:"$gen_cast", {:command, %{id: 1, verb: :place, coord: {8, 64, 14}}}}

    Llm.handle_event({:outcome, %{id: 1, verb: :place, status: :done, reason: nil, data: %{seq: 5}}}, brain)
    Process.sleep(1_000)
    Llm.handle_event({:observation, idle}, brain)

    assert_receive {:asked, 2,
                    [%{"id" => 1, "status" => "done", "command" => %{"tool" => "place", "args" => %{"x" => 8, "y" => 64, "z" => 14, "material" => 11, "tool_id" => 1}}}]},
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

    brain = Llm.init(%{goal: "g", tools: %{1 => "镐"}, endpoint: %{model: "m"}, request: request})
    idle = %{self: %{tick: 1, position: {0.0, 0.0, 0.0}}, entities: [], pending: [], balances: nil}
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

end
