defmodule SceneServer.Movement.CastActionTest do
  use ExUnit.Case, async: true
  @moduletag :t0
  alias SceneServer.Movement.Player
  alias SceneServer.Body
  alias MmoContracts.{Session, Movement}

  defmodule Sink do
    def reliable(pid, _, _, event), do: send(pid, {:wire, event})
  end

  # Test-only：直接驱动 owner 回调和消息顺序；World 支付另由真实 World 测试证明。
  # World 前摇计划里的各步 {调整, 注能} 秒（取灯的报价样本 `quote-v2-samples.json` lamp，四舍五入到 0.1 ms）。
  @steps [
    %{adjust_s: 0.1434, inject_s: 0.0},
    %{adjust_s: 0.201, inject_s: 0.0},
    %{adjust_s: 0.0944, inject_s: 0.0},
    %{adjust_s: 0.1185, inject_s: 0.05}
  ]

  setup do
    id = %Session.Identity{session_epoch: 7, scene_id: 1, scene_epoch: 2}

    state = %{
      identity: id,
      id: 10,
      epoch: 1,
      ready: true,
      transfer: nil,
      failure: nil,
      state: %{position: {1.0, 2.0, 3.0}, yaw: 0},
      # 真实 Player 状态恒有该字段；actor_context 把它作为确认位置的 tick 交给观察日志。
      simulation_tick: 0,
      config: %{profile: %{half_height: 0.9}},
      gate: self(),
      authority_ref: self(),
      sink: Sink,
      body: Body.new(),
      tick: 40,
      movement_scales: [{0, 1.0, 1.0}],
      action: nil,
      action_seq: 0,
      spell_requests: %{},
      # Player.init 恒设生命代次（player.ex init），actor_context 读它；夹具补上同一字段。
      life_generation: 1,
      # Scene.join 恒给角色 kind（0 玩家、1 NPC）；actor_context 据此给出施法快照的 controller（魔法 v2 切片 7）。
      kind: 0,
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

    assert {:noreply, s} =
             Player.handle_call(
               {:spell, c.id, c.request, %{caster_recipient: recipient}},
               c.from,
               c.state
             )

    assert_receive {:player_spell_request, _, _,
                    {:prepare_cast, key, %{caster_recipient: ^recipient}, _, _}}

    assert {:reply, {:error, :casting}, _} = Player.handle_call({:tool_context, c.id}, c.from, s)
    assert_receive {:wire, %{input_limit: 0.35, apply_tick: 41}}

    assert {:reply, {:ok, :controlled}, s} =
             Player.handle_call({:spell, c.id, %{c.request | action: 2}, %{}}, c.from, s)

    # 准备中（World 尚未接纳前摇）的主动取消：本进程收尾，k = 0（魔法 v2 切片 6，原因 Q6-4）。
    assert_receive {:cancel_cast, ^key, :interrupted_cancelled, 0}

    assert {:noreply, s} =
             Player.handle_info(
               {:cast_prepared, key,
                %{windup_s: 10.0, checkpoint_s: nil, steps: @steps, basic_attack: false}},
               s
             )

    assert {:noreply, _} = Player.handle_info({:release_cast, key}, s)
    refute_receive {:authorize_cast, _, _, _}, 0
    assert_receive {:wire, %{input_limit: 1.0}}
  end

  test "报价保留入口连接的回执目标，不创建施法动作", c do
    recipient = {self(), make_ref()}
    request = %{c.request | action: 0}

    assert {:noreply, state} =
             Player.handle_call(
               {:spell, c.id, request, %{caster_recipient: recipient}},
               c.from,
               c.state
             )

    assert_receive {:player_spell_request, _, _,
                    {:quote_cast, %{caster_recipient: ^recipient}, ^request, _}}

    assert state.action == nil
    assert state.action_seq == 0
    refute_received {:player_spell_request, _, _, {:prepare_cast, _, _, _, _}}
  end

  test "授权冻结当前位置和瞄准；重复到期不重复释放，之后取消返回已释放", c do
    {:noreply, s} = Player.handle_call({:spell, c.id, c.request, %{}}, c.from, c.state)
    assert_receive {:player_spell_request, _, _, {:prepare_cast, key, _, _, _}}

    {:noreply, s} =
      Player.handle_info(
        {:cast_prepared, key,
         %{windup_s: 10.0, checkpoint_s: nil, steps: @steps, basic_attack: false}},
        s
      )

    aim = %{c.request | action: 3, direction: {0.0, 1.0, 0.0}}
    {:reply, {:ok, :controlled}, s} = Player.handle_call({:spell, c.id, aim, %{}}, c.from, s)
    s = %{s | state: %{position: {4.0, 5.0, 6.0}, yaw: 0}}
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

  # W1（设计 v2.11、落地稿 D7）：World 预判第 k 步中断时给出 checkpoint_s，计时器先到 t_k 发检查，World 只回判定；
  # continue 后只计剩余前摇，ended 清动作槽。若 Player 仍只按前摇终点计时，检查不会发出，中断只能拖到出手才结算。
  test "W1 第 k 步检查：先到 t_k 发 check_cast（带当前快照），continue 后只计剩余前摇再授权", c do
    {:noreply, s} = Player.handle_call({:spell, c.id, c.request, %{}}, c.from, c.state)
    assert_receive {:player_spell_request, _, _, {:prepare_cast, key, _, _, _}}

    {:noreply, s} =
      Player.handle_info(
        {:cast_prepared, key,
         %{windup_s: 0.06, checkpoint_s: 0.02, steps: @steps, basic_attack: false}},
        s
      )

    assert_receive {:cast_checkpoint, ^key}, 1_000
    refute_received {:release_cast, ^key}

    s = %{s | state: %{position: {4.0, 5.0, 6.0}, yaw: 0}}
    {:noreply, s} = Player.handle_info({:cast_checkpoint, key}, s)
    assert_receive {:check_cast, ^key, actor, request}
    assert {actor.eye, actor.coherence_factor, request} == {{4.0, 5.6, 6.0}, 1.0, c.request}
    assert s.action.phase == :checking
    # 检查中到达的旧到期消息不释放。
    {:noreply, s} = Player.handle_info({:release_cast, key}, s)
    refute_received {:authorize_cast, _, _, _}

    {:noreply, s} = Player.handle_info({:cast_checked, key, :continue}, s)
    assert s.action.phase == :windup
    assert_receive {:release_cast, ^key}, 1_000
    {:noreply, s} = Player.handle_info({:release_cast, key}, s)
    assert_receive {:authorize_cast, ^key, _, _}
    assert s.action == nil
  end

  test "W1 第 k 步检查后 World 已结算（ended）：动作槽清空，之后的到期与旧回复都不再授权", c do
    {:noreply, s} = Player.handle_call({:spell, c.id, c.request, %{}}, c.from, c.state)
    assert_receive {:player_spell_request, _, _, {:prepare_cast, key, _, _, _}}

    {:noreply, s} =
      Player.handle_info(
        {:cast_prepared, key,
         %{windup_s: 10.0, checkpoint_s: 5.0, steps: @steps, basic_attack: false}},
        s
      )

    {:noreply, s} = Player.handle_info({:cast_checkpoint, key}, s)
    assert_receive {:check_cast, ^key, _, _}

    {:noreply, s} = Player.handle_info({:cast_checked, key, :ended}, s)
    assert s.action == nil
    assert {:noreply, ^s} = Player.handle_info({:cast_checked, key, :continue}, s)
    {:noreply, _} = Player.handle_info({:release_cast, key}, s)
    refute_receive {:authorize_cast, _, _, _}, 0
  end

  test "前摇输入限幅保留较小输入，阻止跳跃，与冻伤速度正交" do
    assert Movement.Codec.constrain({1.0, 0.0, 1}, 0.35) == {0.35, 0.0, 0}
    assert Movement.Codec.constrain({0.2, 0.0, 1}, 0.35) == {0.2, 0.0, 0}
    assert Movement.Codec.constrain({1.0, 0.0, 1}, 1.0) == {1.0, 0.0, 1}
  end

  # D-1（docs/10-active/cross-cutting/2026-10-07-character-capability-library.md §13）：死亡统一回 dead。
  # 改前 tool_context 在死亡时照样给出 actor（放置、合成、附件、prefab、发布都能进 World），施放回 cast_too_soon。
  test "死亡时非工具世界意图的接纳与施放都回 dead；施法互斥仍先于死亡", c do
    dead = %{c.state | body: %{c.state.body | status: :dead}}

    assert {:reply, {:ok, %{cid: 10, refresh: _}}, _} =
             Player.handle_call({:tool_context, c.id}, c.from, c.state)

    assert {:reply, {:error, :dead}, ^dead} =
             Player.handle_call({:tool_context, c.id}, c.from, dead)

    assert {:reply, {:error, :dead}, ^dead} =
             Player.handle_call({:spell, c.id, c.request, %{}}, c.from, dead)

    refute_received {:player_spell_request, _, _, {:prepare_cast, _, _, _, _}}

    # 前摇中（action 非空）死亡：tool_context 仍按施法互斥回 casting，与 authorize_tool 同序。
    {:noreply, casting} = Player.handle_call({:spell, c.id, c.request, %{}}, c.from, c.state)
    assert_receive {:player_spell_request, _, _, {:prepare_cast, _, _, _, _}}

    assert {:reply, {:error, :casting}, _} =
             Player.handle_call(
               {:tool_context, c.id},
               c.from,
               %{casting | body: %{casting.body | status: :dead}}
             )
  end

  test "死亡先于授权则只取消，旧身份控制不能改变本次施法", c do
    {:noreply, s} = Player.handle_call({:spell, c.id, c.request, %{}}, c.from, c.state)
    assert_receive {:player_spell_request, _, _, {:prepare_cast, key, _, _, _}}

    {:noreply, s} =
      Player.handle_info(
        {:cast_prepared, key,
         %{windup_s: 10.0, checkpoint_s: nil, steps: @steps, basic_attack: false}},
        s
      )

    old = %{c.id | session_epoch: 6}

    assert {:reply, {:error, :invalid_state}, ^s} =
             Player.handle_call({:spell, old, %{c.request | action: 2}, %{}}, c.from, s)

    {:noreply, _} =
      Player.handle_info({:release_cast, key}, %{s | body: %{s.body | status: :dead}})

    # 系统撤销（死亡、会话失败、移交）不是玩家的打断：免费，k = 0。
    assert_receive {:cancel_cast, ^key, :cast_cancelled, 0}
    refute_receive {:authorize_cast, _, _, _}, 0
  end

  # I4（docs/10-active/cross-cutting/2026-10-07-character-capability-library.md §7.8、T4.4、S4）：施放的公共入口
  # cast_spell/5 异步排进同一施法处理；立即拒绝（这里是 D-1 的死亡）经 reply_to 回 {tag, 结果}，与 World 结算回复同一目标。
  # 函数头要求 caster_recipient 与 reply_to 都是 {pid, tag}：缺 caster_recipient 时 World 在结算出口 KeyError（F26）。
  # 真实 NPC 场景造不出死亡（身体要在热环境里推进 130 s，且不得注入身体真值），Body 侧的立即拒绝由
  # gate_server npc_cast_world_test 的 cast_too_soon 证明。
  test "cast_spell/5：异步排进同一施法处理，死亡立即拒绝经 reply_to 回；函数头要求两个 {pid, tag}", c do
    recipient = {self(), make_ref()}
    reply_to = {self(), {:npc_cast, 3}}
    :ok = Player.cast_spell(self(), c.id, c.request, %{caster_recipient: recipient}, reply_to)
    assert_receive {:"$gen_cast", {:spell, _, _, _, ^reply_to} = message}

    dead = %{c.state | body: %{c.state.body | status: :dead}}
    assert {:noreply, ^dead} = Player.handle_cast(message, dead)
    assert_receive {{:npc_cast, 3}, {:error, :dead}}
    refute_received {:player_spell_request, _, _, {:prepare_cast, _, _, _, _}}

    # 存活：World回复先回唯一Player等待owner，原reply_to只收到一次转交结果。
    assert {:noreply, s} = Player.handle_cast(message, c.state)

    assert_receive {:player_spell_request, ref, relay,
                    {:prepare_cast, _key, %{caster_recipient: ^recipient}, _, relay}}

    assert %{phase: :preparing} = s.action
    assert relay == {self(), {:spell_reply, ref}}
    assert {:noreply, done} = Player.handle_info({{:spell_reply, ref}, {:ok, :fixture_result}}, s)
    assert_receive {{:npc_cast, 3}, {:ok, :fixture_result}}
    assert done.spell_requests == %{}

    assert {:noreply, ^done} =
             Player.handle_info({{:spell_reply, ref}, {:ok, :fixture_result}}, done)

    refute_receive {{:npc_cast, 3}, _}, 0

    assert_raise FunctionClauseError, fn ->
      Player.cast_spell(self(), c.id, c.request, %{}, reply_to)
    end

    assert_raise FunctionClauseError, fn ->
      Player.cast_spell(self(), c.id, c.request, %{caster_recipient: recipient}, :nowhere)
    end
  end

  # ---------------------------------------------------------------------------
  # 魔法 v2 切片 6：前摇打断（设计 §5.5 打断行、§14.0 Q6；决策稿 §6.1、Q6-1、Q6-4；落地稿 D7）
  # ---------------------------------------------------------------------------

  # 期望按步界手算：灯各步结束于 0.1434、0.3444、0.4388、0.6073 s（第 4 步注能 0.05 s），之后是出手前置段。
  test "进行中的步 k：第 1 步调整段内为 0（第一笔注能前）；之后取所在步，调整段也算该步；出手前置段算最后一步" do
    assert Player.step_in_progress(@steps, 0.0) == 0
    assert Player.step_in_progress(@steps, 0.1433) == 0
    assert Player.step_in_progress(@steps, 0.1435) == 2
    assert Player.step_in_progress(@steps, 0.40) == 3
    assert Player.step_in_progress(@steps, 0.58) == 4
    assert Player.step_in_progress(@steps, 0.9) == 4
    # 第 1 步带注能时，注能段内即 k = 1。
    assert Player.step_in_progress([%{adjust_s: 0.1, inject_s: 0.2}], 0.15) == 1
  end

  test "前摇中主动取消：按已流逝时间求 k 发给 World，动作槽立即释放；等待方只收 World 的一次回复", c do
    {:noreply, s} = Player.handle_call({:spell, c.id, c.request, %{}}, c.from, c.state)
    assert_receive {:player_spell_request, ref, _, {:prepare_cast, key, _, _, _}}

    # 第 1 步从 0 s 起注能 60 s：任何时刻取消都在第 1 步，k = 1（须结账）。
    plan = %{
      windup_s: 60.3,
      checkpoint_s: nil,
      steps: [%{adjust_s: 0.0, inject_s: 60.0}],
      basic_attack: false
    }

    {:noreply, s} = Player.handle_info({:cast_prepared, key, plan}, s)

    assert {:reply, {:ok, :controlled}, s} =
             Player.handle_call({:spell, c.id, %{c.request | action: 2}, %{}}, c.from, s)

    assert_receive {:cancel_cast, ^key, :interrupted_cancelled, 1}
    assert s.action == nil
    {_, tag} = c.from
    refute_received {^tag, _}

    # 结账回复由 World 给出（outcome 即打断原因、fail_step = k），经本进程原样转交一次。
    settled = {:ok, %{seq: 9, outcome: :interrupted_cancelled, fail_step: 1, caster: %{}}}
    {:noreply, s} = Player.handle_info({{:spell_reply, ref}, settled}, s)
    assert_receive {^tag, ^settled}
    assert s.spell_requests == %{}
    # 旧到期消息不再授权。
    {:noreply, _} = Player.handle_info({:release_cast, key}, s)
    refute_receive {:authorize_cast, _, _, _}, 0
  end

  test "干预剂量打断：前摇中收到 windup_disrupted 即以 interrupted_disrupted 取消；准备中、旧动作的通知忽略", c do
    {:noreply, s} = Player.handle_call({:spell, c.id, c.request, %{}}, c.from, c.state)
    assert_receive {:player_spell_request, _, _, {:prepare_cast, key, _, _, _}}

    # World 尚未接纳前摇：施法者不在 World 的待施放里，不会有剂量；到达的通知一律忽略。
    assert {:noreply, ^s} = Player.handle_info({:windup_disrupted, key, 0.44}, s)

    {:noreply, s} =
      Player.handle_info(
        {:cast_prepared, key,
         %{windup_s: 10.0, checkpoint_s: nil, steps: @steps, basic_attack: false}},
        s
      )

    assert {:noreply, ^s} = Player.handle_info({:windup_disrupted, {c.id, 0}, 0.44}, s)
    refute_received {:cancel_cast, _, _, _}

    {:noreply, s} = Player.handle_info({:windup_disrupted, key, 0.44}, s)
    # 刚进入前摇：仍在第 1 步调整段（0.1434 s），k = 0，免费。
    assert_receive {:cancel_cast, ^key, :interrupted_disrupted, 0}
    assert s.action == nil
  end

  # 用户 2026-11-26 裁定：持物普攻（World 判定的 basic_attack）只免除移动打断，驱散剂量与主动取消照样打断。
  test "持物普攻：驱散剂量与主动取消照样打断", c do
    for {notice, reason} <- [{:dose, :interrupted_disrupted}, {:cancel, :interrupted_cancelled}] do
      request = %{
        c.request
        | client_intent_seq: c.request.client_intent_seq + if(notice == :dose, do: 0, else: 1)
      }

      {:noreply, s} = Player.handle_call({:spell, c.id, request, %{}}, c.from, c.state)
      assert_receive {:player_spell_request, _, _, {:prepare_cast, key, _, _, _}}

      plan = %{
        windup_s: 0.3,
        checkpoint_s: nil,
        steps: [%{adjust_s: 0.0, inject_s: 0.0}],
        basic_attack: true
      }

      {:noreply, s} = Player.handle_info({:cast_prepared, key, plan}, s)
      assert s.action.basic_attack

      s =
        case notice do
          :dose ->
            elem(Player.handle_info({:windup_disrupted, key, 0.44}, s), 1)

          :cancel ->
            elem(Player.handle_call({:spell, c.id, %{request | action: 2}, %{}}, c.from, s), 2)
        end

      assert_receive {:cancel_cast, ^key, ^reason, _k}
      assert s.action == nil
    end
  end
end
