defmodule SceneServer.Movement.ToolActionTest do
  use ExUnit.Case, async: true
  alias SceneServer.{Body, Movement.Player}
  alias MmoContracts.Session

  defmodule Sink do
    def reliable(pid, _, _, message), do: send(pid, {:wire, message})
  end

  # Test-only：受控 owner 回调，不冒充真实网络／World 集成。
  setup do
    identity = %Session.Identity{session_epoch: 7, scene_id: 1, scene_epoch: 2}
    body_store = start_supervised!({MmoTest.BodyStore, []})
    {:ok, nil} = MmoTest.BodyStore.claim(20, identity.session_epoch, store: body_store)

    state = %{
      identity: identity,
      id: 20,
      epoch: 1,
      ready: true,
      transfer: nil,
      failure: nil,
      state: %{position: {2.0, 0.0, 0.0}},
      scene: self(),
      gate: self(),
      sink: Sink,
      config: %{
        profile: %{half_height: 0.9, radius: 0.3},
        combat_scope: {{-5.0, -5.0, -5.0}, {5.0, 5.0, 5.0}}
      },
      body: Body.new(),
      body_store: {MmoTest.BodyStore, store: body_store},
      body_owned: true,
      body_fence: nil,
      body_heat: %{q_j: 0.0, tissue_j: 0.0, max_contact_k: nil, sole_k: nil, immersed: 0.0},
      body_exchange_j: 0.0,
      food_cursors: %{},
      body_sent: nil,
      life_generation: 99,
      body_hits: %{},
      tool_action: nil,
      action: nil,
      tick: 40,
      scene_id: 1,
      scene_epoch: 2,
      updates: %{transaction_seq: 0, revision: 1},
      clock: {SceneServer.Movement.Clock, nil},
      time_origin: 0,
      time_mono_origin: 0,
      mono_origin: 0
    }

    actor = %{identity: identity, position: {0.0, 0.0, 0.0}, cid: 10, life_generation: 98}

    hit = %{
      key: MmoContracts.Action.key(identity, 11),
      actor: actor,
      target: %{life_generation: 99, position: state.state.position},
      part: :torso,
      impact: %{depth: 0.2, protein_g: 2.0, heal_s: 100.0},
      request_id: 42
    }

    %{state: state, hit: hit, identity: identity, from: {self(), make_ref()}}
  end

  test "同一作用重投只返回原回执，新生命拒绝旧作用", c do
    {:reply, {:ok, receipt}, after_hit} =
      Player.handle_call({:receive_hit, c.hit}, c.from, c.state)

    assert receipt.body.life == 80
    assert receipt.action_seq == 11 and receipt.target_id == 20 and receipt.source_id == 10
    assert_receive {:wire, %Session.ToolState{request_id: 42, target_life: 99, life: 80}}
    assert_receive {:wire, %Session.BodyState{life: 80, recoverable: 20}}

    assert {:reply, {:ok, ^receipt}, ^after_hit} =
             Player.handle_call({:receive_hit, c.hit}, c.from, after_hit)

    refute_receive {:wire, _}, 0
    revived = %{after_hit | life_generation: 100, body: Body.revive(), body_hits: %{}}

    assert {:reply, {:error, :stale_life}, ^revived} =
             Player.handle_call({:receive_hit, c.hit}, c.from, revived)
  end

  test "范围外和关闭战斗场拒绝，本次采样后继续移动不撤回即时命中", c do
    for state <- [
          %{c.state | config: %{c.state.config | combat_scope: nil}},
          %{c.state | state: %{position: {6.0, 0.0, 0.0}}}
        ] do
      assert {:reply, {:error, :combat_not_permitted}, ^state} =
               Player.handle_call({:receive_hit, c.hit}, c.from, state)
    end

    moved = %{c.state | state: %{position: {2.1, 0.0, 0.0}}}

    assert {:reply, {:ok, %{body: %{life: 80}}}, _} =
             Player.handle_call({:receive_hit, c.hit}, c.from, moved)
  end

  test "工具登记绑定完整会话与请求，完成后重投不再授权", c do
    request = %{action: 1, client_intent_seq: 11, request_id: 42}

    {:reply, {:ok, actor}, state} =
      Player.handle_call({:authorize_tool, c.identity, request, %{}}, c.from, c.state)

    assert actor.action_key == {c.identity, 11}

    {:reply, {:ok, 123}, state} =
      Player.handle_call({:finish_tool, actor.action_key, {:ok, 123}}, c.from, state)

    assert {:reply, {:done, {:ok, 123}}, ^state} =
             Player.handle_call({:authorize_tool, c.identity, request, %{}}, c.from, state)

    assert {:reply, {:error, :replayed_attack}, ^state} =
             Player.handle_call(
               {:authorize_tool, c.identity, %{request | request_id: 43}, %{}},
               c.from,
               state
             )

    assert {:reply, {:error, :invalid_state}, ^state} =
             Player.handle_call(
               {:authorize_tool, %{c.identity | session_epoch: 6}, request, %{}},
               c.from,
               state
             )
  end

  test "candidate geometry omits Body report except the queried target", c do
    for requested <- [nil, c.state.id + 1] do
      assert {:reply, {:ok, %{body: nil, position: position}}, _} =
               Player.handle_call({:hit_context, requested}, c.from, c.state)

      assert position == c.state.state.position
    end

    assert {:reply, {:ok, %{body: %{life: 100}}}, _} =
             Player.handle_call({:hit_context, c.state.id}, c.from, c.state)
  end

  test "target owner leaving rejects both calls without exiting the attacker", c do
    {target, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^target, :normal}
    assert {:error, :invalid_state} = Player.hit_context(target)
    assert {:error, :invalid_state} = Player.receive_hit(target, c.hit)
  end
end
