Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule GateServer.VoximSpellDispatchTest do
  @moduledoc """
  只测试：魔法增量 1 的 Gate 胶合——0x82 经正式解码与 Dispatch 进入真实 World；报价只回 0x83，
  施放（含走火）先回 0x83 再回 0x68 accepted，拒绝回 0x68 rejected；QUIC 接纳 0x76 后的施法者状态请求回 0x83（request_id 0）。
  World 用 Test-only 魔法目录 ff15757b… 与材料目录 b1aca503…；施法者能量 0（新角色），走火扣 0。
  施放前摇（Voxim Docs/Magic.md §13.6）：施放的回执在前摇结束后才到（真实定时器，点火前摇 0.892 s），
  Dispatch 立即返回；前摇中再施放立即回 0x68 rejected cast_too_soon。
  """
  use ExUnit.Case, async: false
  alias GateServer.Session.{Dispatch, Sink}
  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Actor}

  # 只测试：使用真实连接回调与可靠队列，替换最终 QUIC socket，把编码帧交给测试进程。
  defmodule Connection do
    use GenServer
    alias GateServer.Session.QuicConnection
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts) do
      {:ok, state} = QuicConnection.init(conn: :test, listener: opts.owner, hello: nil)
      {:ok, %{state: %{state | identity: opts.identity, edit_ref: :session}, owner: opts.owner}}
    end
    def handle_info(message, context) do
      {:noreply, state} = QuicConnection.handle_info(message, context.state)
      for {bytes, _, _} <- :queue.to_list(state.reliable[2]),
        do: send(context.owner, {:mmo_voxel_bytes, :session, bytes})
      {:noreply, %{context | state: put_in(state.reliable[2], :queue.new())}}
    end
  end

  @fixtures Path.expand("../../../voxel_region/test/fixtures", __DIR__)

  # 只测试：Player 施法协议替身。报价 / 准备按真实 `SceneServer.Movement.Player` 的消息转给 World，World 回
  # `cast_prepared` 后按前摇时长发 `authorize_cast`；前摇互斥与取消由真实 Player 负责（scene `cast_action_test`），
  # 这里只接通 Gate → Player 协议 → World。
  defmodule CastingPlayer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, Map.put(state, :requests, %{}))
    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:tool_context, id}, _, %{actor: %{identity: id} = actor} = state),
      do: {:reply, {:ok, Map.put(actor, :player, self())}, state}

    def handle_call({:spell, identity, request, ingress}, from, state),
      do: spell(identity, request, ingress, from, state)

    def handle_call(:hold_reply, _, state), do: {:reply, :ok, Map.put(state, :hold_reply, true)}
    def handle_call(:release_reply, _, %{held_reply: {from, result}} = state) do
      GenServer.reply(from, result)
      {:reply, :ok, Map.delete(state, :held_reply)}
    end

    @impl true
    def handle_cast({:spell, identity, request, ingress, from}, state),
      do: spell(identity, request, ingress, from, state)

    @impl true
    def handle_info({:cast_prepared, key, windup_s}, state) do
      Process.send_after(self(), {:release_cast, key}, ceil(windup_s * 1000))
      {:noreply, state}
    end

    def handle_info({:release_cast, key}, state) do
      send(state.world, {:authorize_cast, key, actor(state), state.requests[key]})
      {:noreply, state}
    end

    def handle_info({:cast_failed, _key}, state), do: {:noreply, state}

    # 只测试：控制报价调用回复的到达顺序，不延迟 World 自己的权威状态出口。
    def handle_info({ref, result}, %{reply_waiter: {ref, from}} = state) do
      send(state.actor.test_owner, :caster_reply_held)
      {:noreply, Map.put(state, :held_reply, {from, result})}
    end

    defp spell(identity, request, ingress, from, %{actor: %{identity: identity}} = state) do
      case request.action do
        0 ->
          if Map.get(state, :hold_reply, false) do
            ref = make_ref()
            send(state.world, {:quote_cast, Map.merge(actor(state), ingress), request, {self(), ref}})
            {:noreply, Map.put(state, :reply_waiter, {ref, from})}
          else
            send(state.world, {:quote_cast, Map.merge(actor(state), ingress), request, from})
            {:noreply, state}
          end

        1 ->
          key = MmoContracts.Action.key(identity, request.client_intent_seq)
          send(state.world, {:prepare_cast, key, Map.merge(actor(state), ingress), request, from})
          {:noreply, put_in(state.requests[key], request)}
      end
    end

    defp actor(state), do: Map.put(state.actor, :player, self())
  end

  @magic "ff15757b8a7bfc20954ffde9370f04f0bc22b8a0b93fe31e03eb893165c7e9b1"

  setup do
    root = Path.join(System.tmp_dir!(), "magic_dispatch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    world =
      start_supervised!(
        {World,
         source: Source,
         root: root,
         observer: self(),
         name: nil,
         property_catalog_path:
           Path.join([
             @fixtures,
             "combustion",
             "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec.json"
           ]),
         thermal_environment_path:
           Path.join([@fixtures, "combustion", "environment-radiation.json"]),
         magic_catalog_path: Path.join([@fixtures, "magic", @magic <> ".json"]),
         prefab_catalog_path: nil}
      )

    # 地面石 (0,0,0)、叶 (0,2,3)；脚 (0.5,1,0.5)、眼 (0.5,2.5,0.5)，叶在正 z 方向 3 m。
    {:ok, _} = World.apply_edits(world, [{{0, 0, 0}, 11}, {{0, 2, 3}, 28}])

    identity = make_ref()
    connection = start_supervised!({Connection, %{owner: self(), identity: identity}})
    actor = %{
      cid: 1001,
      gate: connection,
      test_owner: self(),
      identity: identity,
      refresh: &Actor.tool_context/2,
      coherence_factor: 1.0,
      eye: {0.5, 2.5, 0.5},
      feet: {0.5, 1.0, 0.5},
      tick_us: 16_667
    }

    player = start_supervised!({CastingPlayer, %{actor: actor, world: world}})

    state = %{
      status: :in_scene,
      voxim_overlay: true,
      player: player,
      identity: actor.identity,
      cid: 1001,
      world_ref: world,
      received_us: 1_000_000,
      clock_node: node(),
      sink: Sink.quic(connection, :session)
    }

    %{world: world, state: state}
  end

  # 0x82：rid 7、seq 8、scene 1、目标 = 叶宏格 (0,2,3) 的角微格 {0,16,24}、incarnation 1（作者编辑后的纪元）、
  # 方向 (0,0,1)、目标拟态 id {0, 0}（Hello 25；加热不用）、程序 = 契约预设 ignite_near。
  defp spell(action, digest) do
    program =
      ~s({"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":"act.heat","args":{"energy_j":400000,"power_w":50000}}]})

    <<0x82, 7::64, 8::32, 1::64, action, digest::binary-size(32), 0.0::float-64, 0.0::float-64,
      1.0::float-64, 0::signed-64, 16::signed-64, 24::signed-64, 1::64, 0::64, 0::32, 28::16, 0,
      0::64, 0::32, byte_size(program)::16, program::binary>>
  end

  defp dispatch(state, bytes) do
    {:ok, message} = Codec.decode(bytes)
    assert {:ok, ^state} = Dispatch.handle(message, state)
  end

  test "报价回 0x83（报价 402 292.5446 J、S 1）；施放立即返回，前摇中再施放 cast_too_soon，走完前摇后先 0x83 再 0x68 accepted misfire_energy；目录过期 0x68 rejected",
       c do
    digest = Base.decode16!(@magic, case: :lower)
    dispatch(c.state, spell(0, digest))

    # 报价：0.4 MJ + E_loss 2292.5445548 J（前摇契约 §2 手算表“远程点火”）= 402 292.5445548 J；能量 0、容量 5 MJ、相干度 4、支出 0；
    # Hello 28 末尾前摇 = 构型调整 0.49198349452 s + 注能 0.4 s = 0.89198349452 s。
    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 7::64, 1::64, +0.0::float-64, 5.0e6::float-64, 4.0::float-64,
                      quote::float-64, 1.0::float-64, +0.0::float-64, windup::float-64>>}

    assert_in_delta quote, 402_292.5445548, 1.0e-4
    assert_in_delta windup, 0.89198349452, 1.0e-9
    refute_receive {:mmo_voxel_bytes, :session, _}, 50
    assert World.seq(c.world) == 1

    started = System.monotonic_time(:millisecond)
    dispatch(c.state, spell(1, digest))
    # 前摇开始：World 出现该施法者的待施放记录，此时尚无回执。
    assert pending(c.world)
    refute_received {:mmo_voxel_bytes, :session, _}
    # 前摇中再施放：同一 request_id 7、入口时钟相同，立即拒绝。
    dispatch(c.state, spell(1, digest))

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 7::64, 8::32, 1::64, 2, 0::64, 0::16, 14::16, ":cast_too_soon">>},
                   500

    # 余额 0 < 402 292.5 J：前摇 0.892 s 后结算走火，扣 min(总支出, 0) = 0；结算事务在开始事务之后
    # （真实前摇期间 World 自身的 500 ms 热提交也可能占用 seq，故不断言具体值），0x83 与 0x68 引用同一 seq。
    # 结算后的状态不是报价：前摇字段为 0。
    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 7::64, settled::64, _::binary-size(48), +0.0::float-64>>},
                   5_000

    assert settled > 2
    assert System.monotonic_time(:millisecond) - started >= 892

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 7::64, 8::32, 1::64, 0, ^settled::64, 0::16, 14::16,
                      "misfire_energy">>}

    seq = World.seq(c.world)

    dispatch(c.state, spell(1, <<0::256>>))

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 7::64, 8::32, 1::64, 2, 0::64, 0::16, 20::16, ":stale_magic_catalog">>}

    assert World.seq(c.world) == seq
  end

  defp pending(world),
    do:
      Enum.find_value(1..2_000, fn _ ->
        VoxelRegion.TestSupport.observe(world, [1001], {{-2, -2, -2}, {2, 2, 2}}).casts[1001]
      end)

  test "QUIC 接纳 0x76 后的施法者状态请求回 0x83（request_id 0）", c do
    assert {:ok, _} =
             Dispatch.handle(
               {:voxel_caster_state_request, %{request_id: 0, logical_scene_id: 1}},
               c.state
             )

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 0::64, 1::64, +0.0::float-64, 5.0e6::float-64, 4.0::float-64,
                      +0.0::float-64, +0.0::float-64, +0.0::float-64, +0.0::float-64>>}
  end

  test "报价调用回复延迟时，World 仍先发报价再发身体状态；迟到回复不重发旧相干度", c do
    :ok = GenServer.call(c.state.player, :hold_reply)
    task = Task.async(fn -> dispatch(c.state, spell(0, Base.decode16!(@magic, case: :lower))) end)
    assert_receive :caster_reply_held
    assert_receive {:mmo_voxel_bytes, :session,
      <<0x83, 7::64, 1::64, +0.0::float-64, 5.0e6::float-64, 4.0::float-64, _::binary-size(32)>>}

    identity = c.state.identity
    {gate, _} = c.state.sink.ref
    send(c.world, {:body_coherence, c.state.cid, 0.45, gate, identity})
    assert_receive {:mmo_voxel_bytes, :session,
      <<0x83, 0::64, 1::64, +0.0::float-64, 5.0e6::float-64, 1.8::float-64,
        +0.0::float-64, +0.0::float-64, +0.0::float-64, +0.0::float-64>>}

    :ok = GenServer.call(c.state.player, :release_reply)
    Task.await(task)
    refute_receive {:mmo_voxel_bytes, _, <<0x83, _::binary>>}, 50
  end

  test "同一连接跨 Scene 的施法成功先状态后结果；旧连接及关闭连接不接纳" do
    alias GateServer.Session.QuicConnection
    {:ok, initial} = QuicConnection.init(conn: :test, listener: self(), hello: nil)
    moved = %{initial | identity: make_ref()}
    request = %{request_id: 7, client_intent_seq: 8, logical_scene_id: 1, action: 1}
    result = %{seq: 9, outcome: :misfire_coherence,
      caster: %{seq: 9, energy_j: 100.0, capacity_j: 5.0e6, coherence: 1.8,
        quote_j: 120.0, quote_s: 2.0, spent_j: 120.0, quote_windup_s: 0.0}}
    message = {:mmo_spell_reply, initial.edit_ref, request, result}
    assert {:noreply, accepted} = QuicConnection.handle_info(message, moved)
    assert [{caster, _, _}, {receipt, _, _}] = :queue.to_list(accepted.reliable[2])
    assert <<0x83, 7::64, 9::64, 100.0::float-64, 5.0e6::float-64, 1.8::float-64,
      120.0::float-64, 2.0::float-64, 120.0::float-64, +0.0::float-64>> == caster
    assert <<0x68, 7::64, 8::32, 1::64, 0, 9::64, 0::16, 17::16, "misfire_coherence">> == receipt

    {:ok, reconnected} = QuicConnection.init(conn: :next, listener: self(), hello: nil)
    assert {:noreply, ^reconnected} = QuicConnection.handle_info(message, reconnected)
    closing = %{moved | closing: true}
    assert {:noreply, ^closing} = QuicConnection.handle_info(message, closing)
  end
end
