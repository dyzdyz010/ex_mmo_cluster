defmodule GateServer.NpcTreeTest do
  @moduledoc """
  只测试：行为树后端 `GateServer.Npc.Brain.Tree` 的纯函数语义（角色能力函数库设计稿 T3.1，§8.2 节点表）。
  每个用例手排事件序列，逐个事件断言树发出的命令；期望命令字面量按 `GateServer.Npc.Brain` 的命令表与设计稿 §6 手写，
  不由被测函数生成。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias GateServer.Npc.Brain.Tree

  @profile %{tools: %{1 => "镐"}, skills: %{build: %{}, gather: %{}}}
  @look %{"x0" => 1, "y0" => 64, "z0" => -3, "x1" => 1, "y1" => 64, "z1" => -3}
  @looked %{verb: :look, min: {1, 64, -3}, max: {1, 64, -3}}

  defp tree(tree, blackboard \\ %{}),
    do: Tree.init(Map.put(@profile, :tree, fn _ -> {tree, blackboard} end))

  defp obs(tick), do: {:observation, %{self: %{entity_id: 7, tick: tick}}}

  defp done(id, verb, data \\ %{}),
    do: {:outcome, %{id: id, verb: verb, status: :done, reason: nil, data: data}}

  defp rejected(id, verb, reason),
    do: {:outcome, %{id: id, verb: verb, status: :rejected, reason: reason, data: nil}}

  # 逐个事件断言命令；返回最终状态。
  defp script(state, steps) do
    Enum.reduce(steps, state, fn {event, expected}, state ->
      {commands, state} = Tree.handle_event(event, state)
      assert commands == expected, "after #{inspect(event)}"
      state
    end)
  end

  test "seq resumes its RUNNING child, stores done data and stops at the first failure with last_failure" do
    state =
      tree({:seq, [{:act, "query_balances", %{}, store: :wallet}, {:act, "stop", %{}}, {:act, "inspect", %{}}]})
      |> script([
        {obs(0), [%{id: 1, verb: :query_balances}]},
        # 叶子 RUNNING 时观察只推进时间，不重发。
        {obs(1), []},
        {done(1, :query_balances, %{balances: []}), [%{id: 2, verb: :stop}]},
        {obs(2), []},
        {rejected(2, :stop, :no_path), []},
        {obs(3), []}
      ])

    assert state.finished == :failure
    assert state.blackboard.wallet == %{balances: []}
    assert state.blackboard.last_failure == %{act: "stop", reason: :no_path}
  end

  test "sel tries children in order, resumes the RUNNING one and succeeds on the first success" do
    state =
      tree({:sel, [{:act, "stop", %{}}, {:act, "inspect", %{}}, {:act, "query_balances", %{}}]})
      |> script([
        {obs(0), [%{id: 1, verb: :stop}]},
        {rejected(1, :stop, :stuck), [%{id: 2, verb: :inspect}]},
        {obs(1), []},
        {done(2, :inspect), []}
      ])

    assert state.finished == :success
    # superseded 也是失败，原因记 :superseded。
    state =
      tree({:sel, [{:act, "stop", %{}}]})
      |> script([
        {obs(0), [%{id: 1, verb: :stop}]},
        {{:outcome, %{id: 1, verb: :stop, status: :superseded, reason: nil, data: nil}}, []}
      ])

    assert state.finished == :failure
    assert state.blackboard.last_failure == %{act: "stop", reason: :superseded}
  end

  test "each writes every item to the blackboard before acting on it; a failing item fails the loop" do
    walk =
      {:each, :points, :point,
       {:act, "move_to", fn %{point: [x, z]} -> %{"x" => x, "z" => z, "y" => nil} end}}

    state =
      tree(walk, %{points: [[1, 2], [3.5, -4]]})
      |> script([
        {obs(0), [%{id: 1, verb: :move_to, position: {1, 2}, tolerance: 0.5, y: nil}]},
        {done(1, :move_to), [%{id: 2, verb: :move_to, position: {3.5, -4}, tolerance: 0.5, y: nil}]},
        {done(2, :move_to), []}
      ])

    assert state.finished == :success
    assert state.blackboard.point == [3.5, -4]

    state =
      tree(walk, %{points: [[1, 2], [3, 4]]})
      |> script([
        {obs(0), [%{id: 1, verb: :move_to, position: {1, 2}, tolerance: 0.5, y: nil}]},
        {rejected(1, :move_to, :no_path), []}
      ])

    assert state.finished == :failure
    assert tree(walk, %{points: []}) |> script([{obs(0), []}]) |> Map.fetch!(:finished) == :success
  end

  test "repeat ends each round RUNNING and opens the next round on the next event; n rounds then SUCCESS" do
    state =
      tree({:repeat, 2, {:act, "stop", %{}}})
      |> script([
        {obs(0), [%{id: 1, verb: :stop}]},
        # 一轮结束：同一事件里不开下一轮。
        {done(1, :stop), []},
        {obs(1), [%{id: 2, verb: :stop}]},
        {done(2, :stop), []},
        {obs(2), []}
      ])

    assert state.finished == :success

    state =
      tree({:repeat, :forever, {:act, "stop", %{}}})
      |> script([
        {obs(0), [%{id: 1, verb: :stop}]},
        {done(1, :stop), []},
        {obs(1), [%{id: 2, verb: :stop}]},
        {done(2, :stop), []},
        {obs(2), [%{id: 3, verb: :stop}]},
        {rejected(3, :stop, :stuck), []}
      ])

    # 子节点失败即失败，forever 也一样。
    assert state.finished == :failure
  end

  test "wait counts observation ticks from its first tick; cond reads the blackboard and the observation" do
    state =
      tree(
        {:seq, [{:wait, 10}, {:cond, fn bb, o -> o.self.tick >= bb.from end}, {:act, "stop", %{}}]},
        %{from: 105}
      )
      |> script([
        {obs(100), []},
        {obs(109), []},
        {obs(110), [%{id: 1, verb: :stop}]}
      ])

    assert state.finished == nil

    # 函数形 wait 读黑板；cond 为假即失败，不写 last_failure（只有 act 写）。
    state =
      tree(
        {:seq, [{:wait, fn bb -> bb.pause end}, {:cond, fn _, o -> o.self.tick > 50 end}, {:act, "stop", %{}}]},
        %{pause: 3}
      )
      |> script([{obs(10), []}, {obs(12), []}, {obs(13), []}])

    assert state.finished == :failure
    refute Map.has_key?(state.blackboard, :last_failure)
  end

  test "retry resends the same command under a new id for each transient reason; other reasons fail" do
    for reason <- [:invalid_session, :dead, :session_lost] do
      state =
        tree({:act, "look", @look, retry: 60})
        |> script([
          {obs(1000), [Map.put(@looked, :id, 1)]},
          {rejected(1, :look, reason), []},
          {obs(1059), []},
          {obs(1060), [Map.put(@looked, :id, 2)]},
          # 旧 id 的迟到结果不属于任何在途叶子。
          {done(1, :look), []},
          {done(2, :look), []}
        ])

      assert state.finished == :success, inspect(reason)
    end

    state =
      tree({:act, "look", @look, retry: 60})
      |> script([{obs(0), [Map.put(@looked, :id, 1)]}, {rejected(1, :look, :too_far), []}, {obs(61), []}])

    assert state.finished == :failure
    assert state.blackboard.last_failure == %{act: "look", reason: :too_far}

    # 不带 retry 的叶子把瞬态原因也当失败。
    state = tree({:act, "look", @look}) |> script([{obs(0), [Map.put(@looked, :id, 1)]}, {rejected(1, :look, :dead), []}])
    assert state.finished == :failure
  end

  test "succeed logs a failing child with the last failure and its context, then carries on; fail forces failure" do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log(fn ->
        state =
          tree(
            {:seq,
             [
               {:succeed, {:act, "look", @look}, log: "npc_test_idle", context: :site},
               {:act, "stop", %{}}
             ]},
            %{site: %{name: "A"}}
          )
          |> script([
            {obs(0), [Map.put(@looked, :id, 1)]},
            {rejected(1, :look, :too_far), [%{id: 2, verb: :stop}]}
          ])

        assert state.blackboard.last_failure == %{act: "look", reason: :too_far}
      end)

    assert log =~ ~s(npc_test_idle entity=7 act=look reason=too_far context=%{name: "A"})

    state =
      tree({:fail, {:act, "stop", %{}}})
      |> script([{obs(0), [%{id: 1, verb: :stop}]}, {done(1, :stop), []}])

    assert state.finished == :failure
  end

  test "halt cancels a RUNNING skill, stops a RUNNING move, keeps world transactions; drained outcomes are dropped" do
    args = %{
      "box" => [[10, 64, 4], [13, 64, 6]],
      "material" => 11,
      "units" => 724,
      "tool_id" => 1
    }

    gather = %{verb: :skill, skill: :gather, args: args}
    state = tree({:act, "gather", args}) |> script([{obs(0), [Map.put(gather, :id, 1)]}])
    assert {[%{id: 2, verb: :cancel_skill, call: 1}], state} = Tree.halt(state)

    state =
      script(state, [
        # 下一个事件从根重来，但被取消的技能还没回终态：不启动新的技能叶子（避免 skill_busy）。
        {obs(1), []},
        {done(2, :cancel_skill, %{call: 1}), []},
        {obs(2), []},
        {rejected(1, :gather, :cancelled), []},
        {obs(3), [Map.put(gather, :id, 3)]}
      ])

    assert state.finished == nil

    move = %{verb: :move_to, position: {8.5, 11.5}, tolerance: 0.5, y: nil}

    state =
      tree({:act, "move_to", %{"x" => 8.5, "z" => 11.5, "y" => nil}})
      |> script([{obs(0), [Map.put(move, :id, 1)]}])

    assert {[%{id: 2, verb: :stop}], state} = Tree.halt(state)

    script(state, [
      {{:outcome, %{id: 1, verb: :move_to, status: :superseded, reason: nil, data: nil}}, []},
      # 移动不受 draining 限制，重来即发。
      {obs(1), [Map.put(move, :id, 3)]}
    ])

    state = tree({:act, "query_balances", %{}}) |> script([{obs(0), [%{id: 1, verb: :query_balances}]}])
    assert {[], state} = Tree.halt(state)
    script(state, [{done(1, :query_balances), []}, {obs(1), [%{id: 2, verb: :query_balances}]}])
  end

  test "new/2 rejects unknown names, bad static arguments, g5 handles and unknown nodes at construction" do
    for {tree, message} <- [
          {{:act, "dance", %{}}, ~r/not an ability/},
          # 没配置的技能不在这个 profile 的能力里。
          {{:act, "design_house", %{}}, ~r/not an ability/},
          {{:seq, [{:act, "look", %{"x0" => 1}}]}, ~r/invalid arguments/},
          # 经 Abilities 的句柄只允许 granularity 0..3（D-13）。
          {{:act, "use_tool",
            %{
              "tool_id" => 1,
              "target" => %{
                "granularity" => 5,
                "micro" => [0, 0, 0],
                "incarnation" => 1,
                "owner" => [42, 0],
                "material" => 0,
                "direction" => nil
              }
            }}, ~r/invalid arguments/},
          {{:parallel, [{:act, "stop", %{}}]}, ~r/unknown behaviour tree node/},
          {{:repeat, 0, {:act, "stop", %{}}}, ~r/unknown behaviour tree node/}
        ] do
      assert_raise ArgumentError, message, fn -> Tree.new(tree, @profile) end
    end

    # 技能叶子的参数原样透传（由技能运行时以 invalid_skill_arguments 拒绝），建树时不校验。
    assert %{finished: nil} = Tree.new({:act, "gather", %{"box" => "bad"}}, @profile)

    # 函数形参数在 tick 时译码：不合法就本地失败，不发给 Body。
    state = tree({:act, "look", fn _ -> %{"x0" => 1} end}) |> script([{obs(0), []}])
    assert state.finished == :failure
    assert state.blackboard.last_failure == %{act: "look", reason: :invalid_tool_arguments}
  end
end
