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
        call("probe_toward", %{dx: 3, dy: 0, dz: 4})
      ]
    }

    assert [
             %{id: 7, verb: :move_to, position: {14, 10.5}, tolerance: 0.5},
             %{id: 8, verb: :probe_toward, tool_id: 1, direction: {0.6, 0.0, 0.8}}
           ] == Llm.commands(response, 1, nil, 7)
  end

  test "use_tool carries the last successful probe; without one it is left for the Body to reject" do
    probe = %{direction: {1.0, 0.0, 0.0}, target: @target}
    response = %{"output" => [call("use_tool", %{})]}

    assert [%{verb: :use_tool, direction: {1.0, 0.0, 0.0}, target: @target, tool_id: 1}] =
             Llm.commands(response, 1, probe, 1)

    assert [%{verb: :use_tool, direction: nil, target: nil}] = Llm.commands(response, 1, nil, 1)
  end

  test "request body is plain JSON: tuples become lists, outcomes oldest first, one required tool call" do
    observation = %{self: %{position: {1.0, 2.0, 3.0}, tick: 9}, entities: [], pending: []}
    outcomes = [%{id: 2, reason: {:stale, 1}}, %{id: 1, reason: nil}]
    profile = %{goal: "g", endpoint: %{model: "m"}}
    body = Llm.body(profile, observation, outcomes)
    input = Jason.decode!(body.input)

    assert [1.0, 2.0, 3.0] == input["self"]["position"]
    assert [1, 2] == Enum.map(input["outcomes"], & &1["id"])
    assert ["stale", 1] == List.last(input["outcomes"])["reason"]
    assert {"required", false, "m"} == {body.tool_choice, body.parallel_tool_calls, body.model}
    assert ~w(move_to probe_toward stop use_tool wait) == body.tools |> Enum.map(& &1.name) |> Enum.sort()
  end

  test "asks only when idle with news: not while a command is pending, not again until a new outcome" do
    test = self()

    request = fn _endpoint, body ->
      send(test, {:asked, Jason.decode!(body.input)})
      {:ok, %{"output" => [call("move_to", %{x: 5, z: 6})]}}
    end

    profile = %{goal: "g", tool_id: 1, endpoint: %{model: "m"}, request: request}
    # init 在 Body 进程里调用：这里测试进程就是 Body，命令以 cast 投回。
    brain = Llm.init(profile)
    idle = %{self: %{tick: 1, position: {0.0, 0.0, 0.0}}, entities: [], pending: []}

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

  test "wait is not a Body command: nothing is sent, and the model is asked again only after the wait" do
    test = self()
    answers = :counters.new(1, [])

    request = fn _endpoint, _body ->
      :counters.add(answers, 1, 1)
      send(test, {:asked, :counters.get(answers, 1)})
      {:ok, %{"output" => [call("wait", %{seconds: 1})]}}
    end

    brain = Llm.init(%{goal: "g", tool_id: 1, endpoint: %{model: "m"}, request: request})
    idle = %{self: %{tick: 1, position: {0.0, 0.0, 0.0}}, entities: [], pending: []}
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
