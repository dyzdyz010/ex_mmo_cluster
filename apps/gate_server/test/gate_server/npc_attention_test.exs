defmodule GateServer.NpcAttentionTest do
  @moduledoc "只测试：目标身份、独立观察、视锥及所有后端共用命令。"
  use ExUnit.Case, async: true
  alias GateServer.Npc.Attention

  @entities %{
    7 => %{entity_epoch: 9, position: {4.0, 0.0, 0.0}, tick: 12, kind: 0},
    8 => %{entity_epoch: 2, position: {0.0, 0.0, 4.0}, tick: 13, kind: 1}
  }
  defp cmd(verb, args), do: Map.merge(%{id: 1, verb: verb}, args)
  defp target(id, epoch), do: %{entity_id: id, entity_epoch: epoch}

  test "双组焦点独立，选择不改变观察，已选轮换不吸入候选" do
    a = Attention.new()

    {:ok, b, _} =
      Attention.apply(
        a,
        cmd(:select_target, %{target: target(7, 9), group: :enemy}),
        @entities,
        {0.0, 0.0, 0.0}
      )

    {:ok, c, _} =
      Attention.apply(
        b,
        cmd(:select_target, %{target: target(8, 2), group: :friendly}),
        @entities,
        {0.0, 0.0, 0.0}
      )

    assert c.direction == a.direction
    assert c.enemy.focus == target(7, 9)
    assert c.friendly.focus == target(8, 2)

    {:ok, d, _} =
      Attention.apply(
        c,
        cmd(:cycle_focus, %{group: :enemy, direction: 1}),
        @entities,
        {0.0, 0.0, 0.0}
      )

    assert d.enemy == c.enemy

    {:error, :stale_target} =
      Attention.apply(
        c,
        cmd(:select_target, %{target: target(7, 8), group: :enemy}),
        @entities,
        {0.0, 0.0, 0.0}
      )

    assert Attention.forget(c, 7).enemy == %{members: [], focus: nil}
    assert Attention.forget(c, 7).friendly == c.friendly
  end

  test "看向坐标独立于焦点，包含负坐标和 Y-up 俯仰；零方向拒绝" do
    a = Attention.new()

    {:ok, b, _} =
      Attention.apply(a, cmd(:look_at, %{position: {-2.0, 2.0, 0.0}}), @entities, {0.0, 0.0, 0.0})

    {x, y, z} = b.direction
    assert_in_delta x, -:math.sqrt(0.5), 1.0e-12
    assert_in_delta y, :math.sqrt(0.5), 1.0e-12
    assert z == 0.0
    assert b.enemy == a.enemy

    assert {:error, :zero_direction} =
             Attention.apply(a, cmd(:look_at, %{position: {0, 0, 0}}), @entities, {0.0, 0.0, 0.0})

    assert Attention.in_view?(a, {0, 0, 0}, {5, 0, 0})
    refute Attention.in_view?(a, {0, 0, 0}, {-5, 0, 0})
    refute Attention.in_view?(a, {0, 0, 0}, {1, 5, 0})
    refute Attention.in_view?(a, {0, 0, 0}, {33, 0, 0})
  end

  test "模型适配使用同一命令；未知名字不制造原子" do
    [c] =
      GateServer.Npc.Brain.Llm.commands(
        %{
          "output" => [
            %{
              "type" => "function_call",
              "name" => "select_target",
              "arguments" => Jason.encode!(%{entity_id: 7, entity_epoch: 9, group: "enemy"})
            }
          ]
        },
        nil,
        %{},
        1,
        %{skills: %{}}
      )

    assert c == cmd(:select_target, %{target: target(7, 9), group: :enemy})
    assert Enum.any?(Attention.tools(), &(&1.name == "get_view"))
    assert Attention.command("missing", %{}, 1) == nil
  end

  test "独立标记保留到实体失效；移除焦点确定地选首个剩余成员" do
    a = Attention.new()

    {:ok, a, _} =
      Attention.apply(
        a,
        cmd(:select_target, %{target: target(7, 9), group: :enemy}),
        @entities,
        {0, 0, 0}
      )

    {:ok, a, _} =
      Attention.apply(
        a,
        cmd(:select_target, %{target: target(8, 2), group: :enemy}),
        @entities,
        {0, 0, 0}
      )

    {:ok, a, _} = Attention.apply(a, cmd(:toggle_mark, %{}), @entities, {0, 0, 0})
    {:ok, a, _} = Attention.apply(a, cmd(:remove_focus, %{group: :enemy}), @entities, {0, 0, 0})
    assert a.enemy.focus == target(7, 9)
    assert a.mark == target(8, 2)

    assert {:error, :not_selected} =
             Attention.apply(
               a,
               cmd(:set_focus, %{target: target(8, 2), group: :enemy}),
               @entities,
               {0, 0, 0}
             )

    {:ok, a, _} = Attention.apply(a, cmd(:clear_targets, %{}), @entities, {0, 0, 0})
    assert a.enemy.members == []
    assert a.mark == target(8, 2)
    assert Attention.forget(a, 8).mark == nil
  end

  test "共享 DDA 的首次距离、负坐标、边角同时跨越及旧返回形状" do
    at = fn cell, state -> {Map.get(state, cell), state} end
    world = %{{-9, 0, 0} => :stone}

    assert {:ok, :stone, 1.0, ^world} =
             VoxelRegion.Damage.trace({0.0, 0.01, 0.01}, {-1.0, 0.0, 0.0}, 2.0, world, at)

    assert {:ok, :stone, ^world} =
             VoxelRegion.Damage.raycast({0.0, 0.01, 0.01}, {-1.0, 0.0, 0.0}, 2.0, world, at)

    assert {:error, :no_target, ^world} =
             VoxelRegion.Damage.trace({0.0, 0.01, 0.01}, {-1.0, 0.0, 0.0}, 0.9, world, at)

    world = %{{0, 0, 0} => :stone}

    assert {:ok, :stone, 0.0, ^world} =
             VoxelRegion.Damage.trace({0.01, 0.01, 0.01}, {0.0, 1.0, 0.0}, 1.0, world, at)

    world = %{{1, 0, 0} => :edge_only, {1, 1, 1} => :corner}
    d = 1 / :math.sqrt(3)

    assert {:ok, :corner, distance, ^world} =
             VoxelRegion.Damage.trace({0.0, 0.0, 0.0}, {d, d, d}, 1.0, world, at)

    assert_in_delta distance, :math.sqrt(3) / 8, 1.0e-12
  end

  test "观察坐标遵循现有感知边界，极大模型数值不会使 Body 算术崩溃" do
    assert {:error, :out_of_range} =
             Attention.apply(
               Attention.new(),
               cmd(:look_at, %{position: {1.0e200, 0, 0}}),
               @entities,
               {0.0, 0.0, 0.0}
             )
  end

  test "可见性结果可直接当作目标，身份只由 id 与 epoch 决定" do
    full = Map.put(@entities[7], :entity_id, 7)

    {:ok, a, _} =
      Attention.apply(
        Attention.new(),
        cmd(:select_target, %{target: full, group: :enemy}),
        @entities,
        {0, 0, 0}
      )

    {:ok, b, _} =
      Attention.apply(
        a,
        cmd(:select_target, %{target: target(7, 9), group: :enemy}),
        @entities,
        {0, 0, 0}
      )

    assert b.enemy.members == [target(7, 9)]

    assert {:ok, _, _} =
             Attention.apply(
               a,
               cmd(:set_focus, %{target: target(7, 9), group: :enemy}),
               @entities,
               {0, 0, 0}
             )
  end

  test "实体代次替换清理关注，迟到的旧代次离开不误删新实体" do
    alias MmoContracts.Session

    {:ok, a, _} =
      Attention.apply(
        Attention.new(),
        cmd(:select_target, %{target: target(7, 9), group: :enemy}),
        @entities,
        {0, 0, 0}
      )

    state = %{identity: :session, entities: @entities, attention: a}

    enter = %Session.EntityEnter{
      identity: :session,
      entity_id: 7,
      entity_epoch: 10,
      interest_generation: 1,
      server_tick: 20,
      kind: 0,
      state: %Session.State{position: {4, 0, 0}, velocity: {0, 0, 0}, grounded: true, yaw: 0}
    }

    assert {:noreply, changed} =
             GateServer.Npc.Body.handle_info({:mmo_reliable, :session, 1, enter}, state)

    assert changed.attention.enemy.members == []

    leave = %Session.EntityLeave{
      identity: :session,
      entity_id: 7,
      entity_epoch: 9,
      interest_generation: 1,
      server_tick: 21
    }

    assert {:noreply, ^changed} =
             GateServer.Npc.Body.handle_info({:mmo_reliable, :session, 1, leave}, changed)
  end

  test "命令缺少调用号明确拒绝；会话未就绪不读世界" do
    s = %{position: nil, outcomes: [], mind: self()}

    assert {:noreply, rejected} =
             GateServer.Npc.Body.handle_cast({:command, %{verb: :get_view}}, s)

    assert [%{status: :rejected, reason: :invalid_command}] = rejected.outcomes

    assert {:noreply, rejected} =
             GateServer.Npc.Body.handle_cast({:command, %{id: 1, verb: :get_aim}}, s)

    assert [%{status: :rejected, reason: :invalid_session}] = rejected.outcomes
  end
end
