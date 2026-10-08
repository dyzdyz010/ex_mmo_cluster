defmodule GateServer.NpcBodyCastTest do
  @moduledoc """
  只测试：NPC Body 的施法记账（角色能力函数库设计稿 docs/10-active/cross-cutting/2026-10-07-character-capability-library.md
  §7.8）——每次施法恰好一个终态、`cancel_cast` 取哪一次施放。被验证的责任主体是真实 `GateServer.Npc.Body`（含它的执行进程）；
  角色 owner（`Movement.Player`）、`Session.Claims` 与 World 是声明范围的替身：替身 Player 把收到的消息原样转给测试进程，
  测试进程充当 Claims 与 World（`magic_digest`），按场景需要决定何时回复、何时让替身退出，以造出真实模块里只在时序竞争中
  出现的情形（执行进程投递前旧 Player 已退出、Player 处理前退出、前一次结算后才投递下一次）。真实 Player / World 的施法语义由
  npc_cast_world_test 覆盖。
  """
  use ExUnit.Case, async: false
  alias GateServer.Npc.Body

  @npc 9301
  @digest <<7::256>>
  @old %{scene_id: 1, session_epoch: 1}
  @fresh %{scene_id: 2, session_epoch: 2}

  defmodule Route do
    def route(_scene_id),
      do:
        {:ok, %{scene_ref: nil, world_ref: Process.whereis(:npc_body_cast_owner), scene_epoch: 1}}
  end

  # 只测试：把每个 Outcome 原样转给测试进程；自己不发命令。
  defmodule Relay do
    @behaviour GateServer.Npc.Brain
    def init(%{owner: owner}), do: owner

    def handle_event({:outcome, outcome}, owner) do
      send(owner, {:outcome, outcome})
      {[], owner}
    end

    def handle_event(_event, owner), do: {[], owner}
  end

  setup do
    Process.register(self(), :npc_body_cast_owner)

    body =
      start_supervised!(
        {Body,
         claims: self(),
         route_module: Route,
         scene_id: 1,
         cid: @npc,
         spawn: {0.5, 1.0, 0.5},
         brain: {Relay, %{owner: self()}}},
        restart: :temporary
      )

    player = stand_in()
    assert_receive {:"$gen_call", from, {:claim, _, _, %{id: @npc, kind: "npc"}}}
    GenServer.reply(from, {@old, {:ok, player}})
    assert_receive {:player, ^player, {:"$gen_cast", {:time_probe, @old, _}}}
    %{body: body, player: player}
  end

  # 替身 Player：收到的一切原样转给测试进程；测试进程结束时随之退出。
  defp stand_in do
    owner = self()

    spawn(fn ->
      monitor = Process.monitor(owner)
      forward(owner, monitor)
    end)
  end

  defp forward(owner, monitor) do
    receive do
      {:DOWN, ^monitor, _, _, _} ->
        :ok

      message ->
        send(owner, {:player, self(), message})
        forward(owner, monitor)
    end
  end

  # 代码 Brain 写法的施放（方向已给，不需要眼点）；程序字节对 Body 不透明。
  defp cast(body, id) do
    Body.command(body, %{
      id: id,
      verb: :cast_spell,
      program: ~s({"v":1}),
      target: %{granularity: 0, micro: {8, 8, 8}, incarnation: 0, owner: {0, 0}, material: 11},
      direction: {1.0, 0.0, 0.0}
    })
  end

  # 执行进程投递前读目录 digest（测试进程充当 World）：返回调用方，由场景决定何时回复。
  defp digest_call do
    assert_receive {:"$gen_call", from, :magic_digest}
    from
  end

  # 替身 Player 收到的施放（`Player.cast_spell/5` 的消息）：回复目标与 caster_recipient 都是 {Body, {:npc_cast, id}}。
  defp delivered(player, body, id) do
    assert_receive {:player, ^player,
                    {:"$gen_cast",
                     {:spell, @old, %{action: 1, catalog_digest: @digest} = request,
                      %{caster_recipient: reply_to}, reply_to}}}

    assert reply_to == {body, {:npc_cast, id}}
    {request, reply_to}
  end

  defp outcome(id) do
    assert_receive {:outcome, %{id: ^id} = outcome}, 2_000
    outcome
  end

  test "跨 Scene 移交：seal 撤销的前摇回 cast_cancelled；旧 Player 退出后才投递的施放以 session_lost 结束，各恰好一个终态",
       %{body: body, player: old} do
    cast(body, :a)
    GenServer.reply(digest_call(), @digest)
    {_, reply_a} = delivered(old, body, :a)

    # 第二次施放停在执行进程里（读 digest 未返回），Body 先走完移交。
    cast(body, :b)
    held = digest_call()
    send(body, {:mmo_transfer_request, @old, old, 2})

    # 替身同时扮演旧 Player 与 World：seal 撤销前摇，World 的 cast_cancelled 先于 seal 的回复发出（真实链路里
    # cancel_cast 排在 body_detach fence 之前到 World）。
    assert_receive {:player, ^old, {:"$gen_call", seal, {:seal, @old}}}
    GenServer.reply(reply_a, {:error, :cast_cancelled})
    GenServer.reply(seal, {:ok, %{simulation_tick: 100}})
    next = stand_in()
    assert_receive {:"$gen_call", prepare, {:prepare_transfer, @old, 2, %{simulation_tick: 100}}}
    GenServer.reply(prepare, {:ok, @fresh, %{world_ref: self()}, next})
    assert_receive {:"$gen_call", commit, {:commit_transfer, @old, @fresh, @npc}}
    GenServer.reply(commit, :ok)

    assert %{verb: :cast_spell, status: :rejected, reason: :cast_cancelled} = outcome(:a)

    # 新 Scene 接管后旧 Player 被终止（Scene.detach_transfer）；执行进程这时才投递 b，投给已退出的进程，没有回复。
    Process.exit(old, :kill)
    GenServer.reply(held, @digest)

    assert %{verb: :cast_spell, status: :rejected, reason: :session_lost} = outcome(:b)
    refute_receive {:outcome, %{id: :a}}, 300
    refute_received {:outcome, %{id: :b}}
    refute_received {:player, ^next, {:"$gen_cast", {:spell, _, _, _, _}}}
  end

  test "会话丢失时两次在途施法（一次前摇中、一次 Player 来不及处理）各恰好一个 session_lost，迟到的回复被忽略",
       %{body: body, player: player} do
    cast(body, :a)
    GenServer.reply(digest_call(), @digest)
    {_, reply_a} = delivered(player, body, :a)
    cast(body, :b)
    GenServer.reply(digest_call(), @digest)
    {_, reply_b} = delivered(player, body, :b)

    # 替身既不结算 a、也不处理 b 就退出。
    Process.exit(player, :kill)

    assert %{status: :rejected, reason: :session_lost} = outcome(:a)
    assert %{status: :rejected, reason: :session_lost} = outcome(:b)

    GenServer.reply(reply_a, {:error, :invalid_session})
    GenServer.reply(reply_b, {:error, :cast_too_soon})
    refute_receive {:outcome, %{id: :a}}, 300
    refute_received {:outcome, %{id: :b}}
  end

  test "前一次施放在下一次投递前已结算：cancel_cast 取消的是后一次（同一 client_intent_seq 的 action 2）",
       %{body: body, player: player} do
    cast(body, :a)
    GenServer.reply(digest_call(), @digest)
    {_, reply_a} = delivered(player, body, :a)

    # b 提交时 a 还在途；b 停在执行进程里，a 先结算。
    cast(body, :b)
    held = digest_call()
    GenServer.reply(reply_a, {:ok, %{seq: 5, outcome: nil, caster: %{}}})
    assert %{status: :done, data: %{seq: 5}} = outcome(:a)

    GenServer.reply(held, @digest)
    {request_b, _} = delivered(player, body, :b)

    Body.command(body, %{id: :c, verb: :cancel_cast})

    assert_receive {:player, ^player, {:"$gen_call", from, {:spell, @old, cancel, _ingress}}}
    assert cancel.action == 2
    assert cancel.client_intent_seq == request_b.client_intent_seq
    assert cancel.request_id > request_b.request_id
    GenServer.reply(from, {:ok, :controlled})
    assert %{status: :done, data: data} = outcome(:c)
    assert data == %{}
  end
end
