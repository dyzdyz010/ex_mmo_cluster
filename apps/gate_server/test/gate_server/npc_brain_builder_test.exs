defmodule GateServer.NpcBrainBuilderTest do
  @moduledoc "只测试：建设者混合后端的纯状态机（手工排的事件序列）与规划请求的形状。真实 World / 模型见 npc_body_world_test 的 :builder_brain 用例。"
  use ExUnit.Case, async: true
  alias GateServer.Npc.Brain.Builder

  # 一根两格高的柱子 + 旁边一格：3 格，两层。包围盒 x 0..1、y 0..1、z 0..0。
  @ops [
    %{"op" => "fill", "min" => [0, 0, 0], "max" => [0, 1, 0], "material" => 11},
    %{"op" => "fill", "min" => [1, 0, 0], "max" => [1, 0, 0], "material" => 19}
  ]
  @profile %{goal: "a pillar", tool_id: 1}
  @observation {:observation, %{self: %{position: {5.0, 0.9, 5.0}}, balances: nil}}

  defp done(id, verb, data \\ nil), do: {:outcome, %{id: id, verb: verb, status: :done, reason: nil, data: data}}
  defp rejected(id, verb, reason), do: {:outcome, %{id: id, verb: verb, status: :rejected, reason: reason, data: nil}}

  defp layer(y, materials) do
    cells = for {x, material} <- Enum.with_index(materials) |> Enum.map(fn {m, x} -> {x, m} end), do: %{cell: [x, y, 0], material: material}
    %{probe_occupancy: cells}
  end

  # 把事件依次喂进去，返回最终状态和每一步的效果。
  defp run(state, events), do: Enum.map_reduce(events, state, fn event, state -> {effects, state} = swap(Builder.step(state, event)); {effects, state} end)
  defp swap({state, effects}), do: {effects, state}

  test "fresh start: balances, one plan request, remember the blueprint, approach, survey per layer, build bottom-up, verify, journal and forget" do
    {effects, state} =
      run(Builder.new(@profile, nil), [
        @observation,
        done(1, :query_balances, %{balances: [%{material: 11, balance: 1024, cost: 512}]}),
        {:blueprint, @ops},
        done(2, :move_to),
        done(3, :look, layer(0, [0, 0])),
        done(4, :look, layer(1, [0, 0])),
        done(5, :place),
        done(6, :place),
        done(7, :place),
        done(8, :look, layer(0, [11, 19])),
        done(9, :look, layer(1, [11, 0]))
      ])

    assert [
             [{:command, %{id: 1, verb: :query_balances}}],
             # 背包取自 query_balances 的结果本身：规划者第一次被问时就看得到材料。
             [{:plan, %{goal: "a pillar", note: nil, position: {5.0, 0.9, 5.0}, balances: [%{material: 11, balance: 1024}]}}],
             # 盒子 x∈[0,2)、z∈[0,1)，最小角格的格心 (0.5, 0.5)：到西侧站位 (−1.5, 0.5) 的距离² = 4.0，到南 / 北 (1.0, ∓…) = 0.25 + 4 = 4.25 → 西侧。
             [{:remember, @ops}, {:command, %{id: 2, verb: :move_to, position: {-1.5, 0.5}}}],
             [{:command, %{id: 3, verb: :look, min: {0, 0, 0}, max: {1, 0, 0}}}],
             [{:command, %{id: 4, verb: :look, min: {0, 1, 0}, max: {1, 1, 0}}}],
             # 自下而上、同层按 x：先底层两格（石、木），再上层。
             [{:command, %{id: 5, verb: :place, coord: {0, 0, 0}, material: 11, tool_id: 1}}],
             [{:command, %{id: 6, verb: :place, coord: {1, 0, 0}, material: 19}}],
             [{:command, %{id: 7, verb: :place, coord: {0, 1, 0}, material: 11}}],
             # 放完不信自己：再看一遍世界。
             [{:command, %{id: 8, verb: :look}}],
             [{:command, %{id: 9, verb: :look}}],
             [{:journal, "Finished building: 3 blocks" <> _}, :forget]
           ] = effects

    assert :idle == state.phase
  end

  test "resume from memory: no plan request; only the cells the world is missing are placed" do
    {effects, _} =
      run(Builder.new(@profile, @ops), [
        @observation,
        done(1, :query_balances),
        done(2, :move_to),
        done(3, :look, layer(0, [11, 19])),
        done(4, :look, layer(1, [0, 0]))
      ])

    assert [_, [{:command, %{verb: :move_to}}], _, _, [{:command, %{id: 5, verb: :place, coord: {0, 1, 0}, material: 11}}]] = effects
    refute Enum.any?(List.flatten(effects), &match?({:plan, _}, &1))
  end

  test "out of reach: walk to the stands one by one and retry; when none is left the scheduler is asked" do
    ready = [@observation, done(1, :query_balances), done(2, :move_to), done(3, :look, layer(0, [0, 19])), done(4, :look, layer(1, [11, 0]))]
    {_, state} = run(Builder.new(@profile, @ops), ready)

    {effects, state} =
      run(state, [rejected(5, :place, :out_of_reach), done(6, :move_to), rejected(7, :place, :out_of_reach), rejected(8, :move_to, :no_path)])

    assert [
             [{:command, %{id: 6, verb: :move_to}}],
             [{:command, %{id: 7, verb: :place, coord: {0, 0, 0}}}],
             [{:command, %{id: 8, verb: :move_to}}],
             [{:command, %{id: 9, verb: :place, coord: {0, 0, 0}}}]
           ] = effects

    # 四个站位：已经用掉两个，再够不着两次之后没有可换的了。
    {effects, state} =
      run(state, [rejected(9, :place, :out_of_reach), done(10, :move_to), rejected(11, :place, :out_of_reach), done(12, :move_to), rejected(13, :place, :out_of_reach)])

    assert [{:triage, "The cell {0, 0, 0} of the blueprint cannot be reached" <> _}] = List.last(effects)
    assert :triage == state.phase
  end

  test "shortage goes to the scheduler; 'fetch material' stops with a journal entry and keeps the blueprint" do
    ready = [@observation, done(1, :query_balances), done(2, :move_to), done(3, :look, layer(0, [0, 0])), done(4, :look, layer(1, [0, 0]))]
    {_, state} = run(Builder.new(@profile, @ops), ready)
    {[[{:triage, problem}]], state} = run(state, [rejected(5, :place, :insufficient_material)])
    assert problem =~ "not enough material" and problem =~ "3 blocks are still missing"

    {[[{:journal, "Stopped building: not enough material" <> _}]], state} = run(state, [{:verdict, {:act, :fetch_material}}])
    assert :idle == state.phase
  end

  test "occupied once re-surveys; foreign material in the way is escalated to the planner with the problem as the note; plans are capped" do
    ready = [@observation, done(1, :query_balances), done(2, :move_to), done(3, :look, layer(0, [0, 0])), done(4, :look, layer(1, [0, 0]))]
    {_, state} = run(Builder.new(@profile, @ops), ready)
    {[[{:command, %{id: 6, verb: :look}}]], state} = run(state, [rejected(5, :place, :occupied)])

    # 重新对账：底层那格现在是金块（6）。
    {effects, state} = run(state, [done(6, :look, layer(0, [6, 0])), done(7, :look, layer(1, [0, 0]))])
    assert [{:triage, problem}] = List.last(effects)
    assert problem =~ "{0, 0, 0} holds material 6"

    {[[{:plan, %{note: ^problem}}]], state} = run(state, [{:verdict, {:escalate, :unexpected}}])
    {[[{:plan, %{note: "The previous blueprint was rejected" <> _}}]], state} = run(state, [{:blueprint, [%{"op" => "paint"}]}])
    {[[{:plan, _}]], state} = run(state, [{:plan_failed, :timeout}])
    # 第四次不再问：记一笔，停。
    {[[{:journal, "Stopped: no usable blueprint after 3 planning attempts" <> _}]], state} = run(state, [{:plan_failed, :timeout}])
    assert :idle == state.phase
  end

  test "planning request: one required tool, English instructions, backpack as whole cells; the answer is the ops list" do
    balances = [%{material: 11, balance: 1536, cost: 512, seq: 1}, %{material: 19, balance: 100, cost: 512, seq: 1}, %{material: 3, balance: 0, cost: 512, seq: 1}]
    body = Builder.plan_body(%{model: "m", effort: "high"}, %{goal: "g", position: {1.0, 2.0, 3.0}, balances: balances, note: nil})

    assert {"m", "required", %{effort: "high"}} == {body.model, body.tool_choice, body.reasoning}
    assert ["submit_blueprint"] == Enum.map(body.tools, & &1.name)
    assert %{"goal" => "g", "npc_position" => [1.0, 2.0, 3.0], "backpack_cells" => [%{"material" => 11, "cells" => 3}, %{"material" => 19, "cells" => 0}]} =
             Jason.decode!(body.input)

    call = %{"type" => "function_call", "name" => "submit_blueprint", "arguments" => Jason.encode!(%{ops: @ops})}
    assert {:ok, @ops} == Builder.plan_ops(%{"output" => [%{"type" => "reasoning"}, call]})
    assert :error == Builder.plan_ops(%{"output" => [%{"type" => "message"}]})
  end
end
