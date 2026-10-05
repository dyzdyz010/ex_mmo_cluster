defmodule SceneServer.Movement.CastActionTest do
  use ExUnit.Case, async: true
  alias SceneServer.Movement.Player
  alias SceneServer.Body
  alias MmoContracts.{Session, Movement}

  defmodule Sink do
    def reliable(pid, _, _, event), do: send(pid, {:wire, event})
  end

  # Test-only：直接驱动 owner 回调和消息顺序；World 支付另由真实 World 测试证明。
  setup do
    id = %Session.Identity{session_epoch: 7, scene_id: 1, scene_epoch: 2}

    state = %{
      identity: id,
      id: 10,
      epoch: 1,
      ready: true,
      transfer: nil,
      failure: nil,
      state: %{position: {1.0, 2.0, 3.0}},
      config: %{profile: %{half_height: 0.9}},
      gate: self(),
      authority_ref: self(),
      sink: Sink,
      body: Body.new(),
      tick: 40,
      movement_scales: [{0, 1.0, 1.0}],
      action: nil,
      action_seq: 0,
      scene_id: 1,
      scene_epoch: 2,
      clock: {SceneServer.Movement.Clock, nil},
      time_origin: 0,
      time_mono_origin: 0,
      mono_origin: 0,
      updates: %{transaction_seq: 0, revision: 1}
    }

    request = %{action: 1, client_intent_seq: 11, request_id: 15, direction: {1.0, 0.0, 0.0}}
    %{state: state, request: request, id: id, from: {self(), make_ref()}}
  end

  test "准备立即互斥工具；取消先于授权时旧到期消息不能释放", c do
    recipient = {self(), make_ref()}
    assert {:noreply, s} = Player.handle_call({:spell, c.id, c.request, %{caster_recipient: recipient}}, c.from, c.state)
    assert_receive {:prepare_cast, key, %{caster_recipient: ^recipient}, _, _}
    assert {:reply, {:error, :casting}, _} = Player.handle_call({:tool_context, c.id}, c.from, s)
    assert_receive {:wire, %{input_limit: 0.35, apply_tick: 41}}

    assert {:reply, {:ok, :controlled}, s} =
             Player.handle_call({:spell, c.id, %{c.request | action: 2}, %{}}, c.from, s)

    assert_receive {:cancel_cast, ^key, :cast_cancelled}
    assert {:noreply, s} = Player.handle_info({:cast_prepared, key, 10.0}, s)
    assert {:noreply, _} = Player.handle_info({:release_cast, key}, s)
    refute_receive {:authorize_cast, _, _, _}, 0
    assert_receive {:wire, %{input_limit: 1.0}}
  end

  test "报价保留入口连接的回执目标，不创建施法动作", c do
    recipient = {self(), make_ref()}
    request = %{c.request | action: 0}
    assert {:noreply, state} = Player.handle_call({:spell, c.id, request, %{caster_recipient: recipient}}, c.from, c.state)
    assert_receive {:quote_cast, %{caster_recipient: ^recipient}, ^request, _}
    assert state.action == nil
    assert state.action_seq == 0
    refute_received {:prepare_cast, _, _, _, _}
  end

  test "授权冻结当前位置和瞄准；重复到期不重复释放，之后取消返回已释放", c do
    {:noreply, s} = Player.handle_call({:spell, c.id, c.request, %{}}, c.from, c.state)
    assert_receive {:prepare_cast, key, _, _, _}
    {:noreply, s} = Player.handle_info({:cast_prepared, key, 10.0}, s)
    aim = %{c.request | action: 3, direction: {0.0, 1.0, 0.0}}
    {:reply, {:ok, :controlled}, s} = Player.handle_call({:spell, c.id, aim, %{}}, c.from, s)
    s = %{s | state: %{position: {4.0, 5.0, 6.0}}}
    {:noreply, s} = Player.handle_info({:release_cast, key}, s)
    assert_receive {:authorize_cast, ^key, actor, request}
    assert actor.eye == {4.0, 5.6, 6.0}
    assert actor.coherence_factor == 1.0
    assert request.direction == {0.0, 1.0, 0.0}

    assert {:reply, {:error, :already_released}, _} =
             Player.handle_call({:spell, c.id, %{c.request | action: 2}, %{}}, c.from, s)

    {:noreply, _} = Player.handle_info({:release_cast, key}, s)
    refute_receive {:authorize_cast, _, _, _}, 0
  end

  test "前摇输入限幅保留较小输入，阻止跳跃，与冻伤速度正交" do
    assert Movement.Codec.constrain({1.0, 0.0, 1}, 0.35) == {0.35, 0.0, 0}
    assert Movement.Codec.constrain({0.2, 0.0, 1}, 0.35) == {0.2, 0.0, 0}
    assert Movement.Codec.constrain({1.0, 0.0, 1}, 1.0) == {1.0, 0.0, 1}
  end

  test "死亡先于授权则只取消，旧身份控制不能改变本次施法", c do
    {:noreply, s} = Player.handle_call({:spell, c.id, c.request, %{}}, c.from, c.state)
    assert_receive {:prepare_cast, key, _, _, _}
    {:noreply, s} = Player.handle_info({:cast_prepared, key, 10.0}, s)
    old = %{c.id | session_epoch: 6}

    assert {:reply, {:error, :invalid_state}, ^s} =
             Player.handle_call({:spell, old, %{c.request | action: 2}, %{}}, c.from, s)

    {:noreply, _} =
      Player.handle_info({:release_cast, key}, %{s | body: %{s.body | status: :dead}})

    assert_receive {:cancel_cast, ^key, :cast_cancelled}
    refute_receive {:authorize_cast, _, _, _}, 0
  end
end
