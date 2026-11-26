Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule GateServer.VoximSpellDispatchTest do
  @moduledoc """
  只测试：魔法线协议 v2（Hello 46，决策稿 `docs/10-active/magic/2026-11-19-slice3-protocol.md` §3、§9 G-1）的 Gate 胶合——
  0x82 v2（127 + n B，无拟态 id）经正式解码与 Dispatch 进入真实 World；报价只回 0x83 v2（161 B）；拒绝回 0x68 rejected；
  QUIC 接纳 0x76 后的施法者状态请求回 0x83（request_id 0）；World 的施法回复在连接里先 0x83 后 0x68。

  World 用目录 v5 发布物 `apps/voxel_region/priv/magic/<sha256>.json`（P9）与材料目录 b1aca503…；施法者能量 0（新角色）。
  蓄能石 (1,1,0) 的 10 MJ 储能是作者初态，经持久化边界安装一次（同 voxel_region 的魔法 World 用例）。
  程序字节取自 `ir-v2-samples.json`（唯一来源）；期望值只来自线契约、目录常数（η 0.9）与报价样本
  （`quote-v2-samples.json` 的 draw_1mj：total 560 750 mJ、前摇 0.430375 s、S·P = 1），不调 `Magic.Cost`。
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
  # 蓄能石宏格与准星微格（格内中心附近）。
  @battery {1, 1, 0}
  @battery_micro {12, 12, 4}

  # 只测试：Player 施法协议替身。与真实 `SceneServer.Movement.Player` 同一消息：同步入口 `{:spell_request, ref, …}`、
  # 异步入口 `{:spell, …, reply_to}`；报价 / 准备以 `{:player_spell_request, ref, relay, message}` 交给 World，
  # World 的回执先回 Player 的本请求 relay `{self(), {:spell_reply, ref}}`，再由 Player 转交原调用方一次。
  # World 回 `cast_prepared` 计划后按它计时：有第 k 步检查时先发 `check_cast`，回 :continue 再为剩余前摇计时，最后发
  # `authorize_cast`（设计 v2.11 W1）。前摇互斥、超时取消与会话取消由真实 Player 负责（scene `cast_action_test`），
  # 这里只接通 Gate → Player 协议 → World。
  defmodule CastingPlayer do
    use GenServer

    def start_link(state),
      do: GenServer.start_link(__MODULE__, Map.merge(state, %{requests: %{}, waiters: %{}}))

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:tool_context, id}, _, %{actor: %{identity: id} = actor} = state),
      do: {:reply, {:ok, Map.put(actor, :player, self())}, state}

    def handle_call({:spell_request, ref, identity, request, ingress}, from, state),
      do: spell(ref, identity, request, ingress, from, state)

    def handle_call(:hold_reply, _, state), do: {:reply, :ok, Map.put(state, :hold_reply, true)}

    def handle_call(:release_reply, _, %{held_reply: {from, result}} = state) do
      GenServer.reply(from, result)
      {:reply, :ok, Map.delete(state, :held_reply)}
    end

    @impl true
    def handle_cast({:spell, identity, request, ingress, from}, state),
      do: spell(make_ref(), identity, request, ingress, from, state)

    @impl true
    def handle_info({:cast_prepared, key, %{windup_s: windup_s, checkpoint_s: nil}}, state) do
      Process.send_after(self(), {:release_cast, key}, ceil(windup_s * 1000))
      {:noreply, state}
    end

    def handle_info(
          {:cast_prepared, key, %{windup_s: windup_s, checkpoint_s: checkpoint_s}},
          state
        ) do
      Process.send_after(self(), {:checkpoint, key}, ceil(checkpoint_s * 1000))

      {:noreply,
       put_in(
         state.requests[{:remaining, key}],
         ceil(windup_s * 1000) - ceil(checkpoint_s * 1000)
       )}
    end

    def handle_info({:checkpoint, key}, state) do
      send(state.world, {:check_cast, key, actor(state), state.requests[key]})
      {:noreply, state}
    end

    def handle_info({:cast_checked, key, :continue}, state) do
      Process.send_after(self(), {:release_cast, key}, state.requests[{:remaining, key}])
      {:noreply, state}
    end

    def handle_info({:cast_checked, _key, :ended}, state), do: {:noreply, state}

    def handle_info({:release_cast, key}, state) do
      send(state.world, {:authorize_cast, key, actor(state), state.requests[key]})
      {:noreply, state}
    end

    def handle_info({:cast_failed, _key}, state), do: {:noreply, state}

    # World 回执经本请求 relay 到达；`hold_reply` 只控制转交给调用方的时机，不延迟 World 自己的权威状态出口。
    def handle_info({{:spell_reply, ref}, result}, state) do
      {from, waiters} = Map.pop!(state.waiters, ref)
      state = %{state | waiters: waiters}

      if Map.get(state, :hold_reply, false) do
        send(state.actor.test_owner, :caster_reply_held)
        {:noreply, Map.put(state, :held_reply, {from, result})}
      else
        GenServer.reply(from, result)
        {:noreply, state}
      end
    end

    defp spell(ref, identity, request, ingress, from, %{actor: %{identity: identity}} = state) do
      relay = {self(), {:spell_reply, ref}}
      actor = Map.merge(actor(state), ingress)

      {message, state} =
        case request.action do
          0 ->
            {{:quote_cast, actor, request, relay}, state}

          1 ->
            key = MmoContracts.Action.key(identity, request.client_intent_seq)
            {{:prepare_cast, key, actor, request, relay}, put_in(state.requests[key], request)}
        end

      send(state.world, {:player_spell_request, ref, relay, message})
      {:noreply, put_in(state.waiters[ref], from)}
    end

    defp actor(state), do: Map.put(state.actor, :player, self())
  end

  # Test-only: isolate World from background 500 ms thermal commits during windup
  # so post-rejection World.seq assertions cannot race an unrelated thermal tick.
  defmodule ManualClock do
    @behaviour VoxelRegion.World.Clock
    @impl true
    def now(_), do: 0
    @impl true
    def schedule(_, _, _, _), do: make_ref()
    @impl true
    def cancel(_, _), do: false
  end

  @catalog_dir Path.expand("../../../voxel_region/priv/magic", __DIR__)
  @catalog @catalog_dir |> Path.join("*.json") |> Path.wildcard() |> then(fn [path] -> path end)
  @digest @catalog |> Path.basename(".json") |> Base.decode16!(case: :lower)
  @ir Path.join(@fixtures, "magic/ir-v2-samples.json") |> File.read!() |> Jason.decode!()
  @external_resource @catalog
  @external_resource Path.join(@fixtures, "magic/ir-v2-samples.json")

  defp ir_program(id),
    do:
      Enum.find(@ir["samples"], &(&1["id"] == id))["program_hex"] |> Base.decode16!(case: :lower)

  setup do
    root = Path.join(System.tmp_dir!(), "magic_dispatch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    world_spec =
      {World,
       source: Source,
       root: root,
       observer: self(),
       name: nil,
       clock: {ManualClock, nil},
       property_catalog_path:
         Path.join([
           @fixtures,
           "combustion",
           "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec.json"
         ]),
       thermal_environment_path:
         Path.join([@fixtures, "combustion", "environment-radiation.json"]),
       magic_catalog_path: @catalog,
       prefab_catalog_path: nil}

    world = start_supervised!(world_spec, id: :world)

    # 地面石 (0,0,0)、叶 (0,2,3)、蓄能石 (1,1,0)；脚 (0.5,1,0.5)、眼 (0.5,2.5,0.5)，叶在正 z 方向 3 m，石格心在 √2 m。
    {:ok, _} =
      World.apply_edits(world, [{{0, 0, 0}, 11}, {{0, 2, 3}, 28}, {{1, 0, 0}, 11}, {@battery, 42}])

    scout = scout()
    {:ok, row} = World.tool_intent(world, scout, query(scout, @battery_micro))
    seq = World.seq(world)
    :ok = stop_supervised(:world)

    VoxelRegion.OverlayLog.File.append(Path.join(root, "overlay.log"), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]
    })

    world = start_supervised!(world_spec, id: :world)

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
      tick_us: 16_667,
      controller: :player
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

    %{world: world, state: state, actor: Map.put(actor, :player, player)}
  end

  # 作者初态与目标身份的查询者：施法者同一位置的 Test-only 角色（`TestSupport.Actor`）。
  defp scout do
    a = %{
      cid: 9,
      gate: self(),
      identity: make_ref(),
      refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5},
      feet: {0.5, 1.0, 0.5},
      tick_us: 16_667
    }

    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp aim({ex, ey, ez}, {x, y, z}) do
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    {dx / n, dy / n, dz / n}
  end

  defp query(a, micro) do
    %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: aim(a.eye, micro),
      micro: micro,
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }
  end

  # 0x82 v2：rid 7、seq 8、scene 1、action、digest、方向 (0,0,1)、目标 = 叶宏格 (0,2,3) 的角微格 {0,16,24}、
  # incarnation 1（作者编辑后的纪元）、owner {0,0}、material 28、granularity 0、u16 程序长度（偏移 125）+ 程序。
  defp spell(action, digest, program) do
    <<0x82, 7::64, 8::32, 1::64, action, digest::binary-size(32), 0.0::float-64, 0.0::float-64,
      1.0::float-64, 0::signed-64, 16::signed-64, 24::signed-64, 1::64, 0::64, 0::32, 28::16, 0,
      byte_size(program)::16, program::binary>>
  end

  # 同一帧，目标是工具查询给出的身份、方向瞄准它的微格中心。
  defp spell_at(action, program, target, aimed) do
    {dx, dy, dz} = aim({0.5, 2.5, 0.5}, aimed)
    {x, y, z} = target.micro
    {birth, occurrence} = target.owner
    digest = @digest

    <<0x82, 7::64, 8::32, 1::64, action, digest::binary-size(32), dx::float-64, dy::float-64,
      dz::float-64, x::signed-64, y::signed-64, z::signed-64, target.incarnation::64, birth::64,
      occurrence::32, target.material::16, target.granularity, byte_size(program)::16,
      program::binary>>
  end

  defp dispatch(state, bytes) do
    assert byte_size(bytes) == 127 + (bytes |> binary_part(125, 2) |> :binary.decode_unsigned())
    {:ok, {:voxel_spell_intent, request} = message} = Codec.decode(bytes)
    refute Map.has_key?(request, :semblance)
    assert {:ok, ^state} = Dispatch.handle(message, state)
  end

  # 0x83 v2 的报价扩展段（偏移 73 起 11 个 f64）。
  defp extension(<<_::binary-size(73), ext::binary-size(88)>>),
    do: for(<<x::float-64 <- ext>>, do: x)

  test "报价只回 0x83 v2（161 B）：取能 1 MJ 的报价、Ω_eff 16、S·P 1，结构类扩展字段为 0；报价不改世界", c do
    seq = World.seq(c.world)
    dispatch(c.state, spell(0, @digest, ir_program("draw_1mj")))

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 7::64, ^seq::64, +0.0::float-64, 5.0e6::float-64, 16.0::float-64,
                      quote::float-64, 1.0::float-64, +0.0::float-64, windup::float-64,
                      _::binary-size(88)>> = frame},
                   2_000

    assert byte_size(frame) == 161
    assert_in_delta quote, 560.75, 1.0e-9
    assert_in_delta windup, 0.430375, 1.0e-6

    # 施法者动作程序（kind 0）：x0…detect_w 为 0；余额 0 < 第 1 步累计 560 750 mJ → fail_step 1；
    # 叶在眼前 3 m（≤ 施法域 6 m）→ rejects 0；entries_* 与 first_tick_min_j 为 0（设计 v2.10 E4）。
    assert extension(frame) == [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]
    refute_receive {:mmo_voxel_bytes, :session, _}, 50
    assert World.seq(c.world) == seq
  end

  # G-1：〈取〉施放成功的端到端。若 World 结算回复没有先经施法者状态出口，或 Gate 把成功编成别的原因串，这里的帧序或
  # 字节对不上。
  test "G-1 〈取〉1 MJ 施放：先 0x83 v2（余额 = η·1 MJ − 560.75 J、spent_j = 560.75 J、扩展段 0），后 0x68 \"ok\"",
       c do
    {:ok, target} = World.tool_intent(c.world, c.actor, query(c.actor, @battery_micro))
    dispatch(c.state, spell_at(1, ir_program("draw_1mj"), target, @battery_micro))

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 7::64, seq::64, energy::float-64, 5.0e6::float-64, 16.0::float-64,
                      quote::float-64, 1.0::float-64, spent::float-64, +0.0::float-64,
                      0::size(88)-unit(8)>>},
                   5_000

    assert_in_delta quote, 560.75, 1.0e-9
    assert_in_delta spent, 560.75, 1.0e-9
    assert_in_delta energy, 0.9 * 1.0e6 - 560.75, 1.0e-6

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 7::64, 8::32, 1::64, 0, ^seq::64, 0::16, 2::16, "ok">>},
                   5_000
  end

  test "施放被拒回 0x68 rejected：目录 digest 过期 :stale_magic_catalog、v1 JSON 程序 :invalid_program；不改世界",
       c do
    seq = World.seq(c.world)

    dispatch(c.state, spell(1, <<0::256>>, ir_program("draw_1mj")))

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 7::64, 8::32, 1::64, 2, 0::64, 0::16, 20::16, ":stale_magic_catalog">>},
                   2_000

    v1 =
      ~s({"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":"energy.draw","args":{"energy_j":1000000}}]})

    dispatch(c.state, spell(1, @digest, v1))

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 7::64, 8::32, 1::64, 2, 0::64, 0::16, 16::16, ":invalid_program">>},
                   2_000

    assert World.seq(c.world) == seq
  end

  # 接纳即开户：该角色尚无施法者账，World 先提交一次性充能事务（seq → seq + 1），余额 = initial_charge_mj / 1000；
  # 同一请求再发一次（重连）不再充，扩展段全 0。
  test "QUIC 接纳 0x76 后的施法者状态请求回 0x83 v2（request_id 0，扩展段全 0）：首次开户充能，再请求不重复", c do
    seq0 = World.seq(c.world)
    seq = seq0 + 1
    granted_j = VoxelRegion.World.Casting.initial_charge_mj() / 1000
    request = {:voxel_caster_state_request, %{request_id: 0, logical_scene_id: 1}}
    assert {:ok, _} = Dispatch.handle(request, c.state)

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 0::64, ^seq::64, ^granted_j::float-64, 5.0e6::float-64,
                      16.0::float-64, +0.0::float-64, +0.0::float-64, +0.0::float-64,
                      +0.0::float-64, 0::size(88)-unit(8)>>}

    assert {:ok, _} = Dispatch.handle(request, c.state)

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 0::64, ^seq::64, ^granted_j::float-64, _::binary>>}

    assert World.seq(c.world) == seq
  end

  test "报价调用回复延迟时，World 仍先发报价再发身体状态；身体推送的 Ω_eff = 16 × 0.45，迟到回复不重发", c do
    seq = World.seq(c.world)
    :ok = GenServer.call(c.state.player, :hold_reply)
    task = Task.async(fn -> dispatch(c.state, spell(0, @digest, ir_program("draw_1mj"))) end)
    assert_receive :caster_reply_held

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 7::64, ^seq::64, +0.0::float-64, 5.0e6::float-64, 16.0::float-64,
                      _::binary-size(120)>>}

    identity = c.state.identity
    {gate, _} = c.state.sink.ref
    send(c.world, {:body_coherence, c.state.cid, 0.45, gate, identity})

    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 0::64, ^seq::64, +0.0::float-64, 5.0e6::float-64, omega::float-64,
                      +0.0::float-64, +0.0::float-64, +0.0::float-64, +0.0::float-64,
                      0::size(88)-unit(8)>>}

    assert_in_delta omega, 7.2, 1.0e-12
    :ok = GenServer.call(c.state.player, :release_reply)
    Task.await(task)
    refute_receive {:mmo_voxel_bytes, _, <<0x83, _::binary>>}, 50
  end

  test "同一连接跨 Scene 的施法回复先 0x83 v2 后 0x68（第 k 步中断 interrupted_energy）；旧连接及关闭连接不接纳" do
    alias GateServer.Session.QuicConnection
    {:ok, initial} = QuicConnection.init(conn: :test, listener: self(), hello: nil)
    moved = %{initial | identity: make_ref()}
    request = %{request_id: 7, client_intent_seq: 8, logical_scene_id: 1, action: 1}

    # World 的结算回复：结算后的状态扩展段为 0（只有报价回复带），spent_j 是本次实际扣除。
    result = %{
      seq: 9,
      outcome: :interrupted_energy,
      caster: %{
        seq: 9,
        energy_j: 0.0,
        capacity_j: 5.0e6,
        resolution_eff: 16.0,
        quote_j: 0.0,
        quote_s: 0.0,
        spent_j: 300.0,
        quote_windup_s: 0.0,
        x0: 0.0,
        x_star: 0.0,
        e_min_j: 0.0,
        p_maint_w: 0.0,
        life_s: 0.0,
        detect_w: 0.0,
        fail_step: 0,
        rejects: [],
        entries_charge: 0,
        entries_spoof: 0,
        first_tick_min_j: 0.0
      }
    }

    message = {:mmo_spell_reply, initial.edit_ref, request, result}
    assert {:noreply, accepted} = QuicConnection.handle_info(message, moved)
    assert [{caster, _, _}, {receipt, _, _}] = :queue.to_list(accepted.reliable[2])

    assert <<0x83, 7::64, 9::64, +0.0::float-64, 5.0e6::float-64, 16.0::float-64, +0.0::float-64,
             +0.0::float-64, 300.0::float-64, 0::size(96)-unit(8)>> == caster

    assert <<0x68, 7::64, 8::32, 1::64, 0, 9::64, 0::16, 18::16, "interrupted_energy">> == receipt

    {:ok, reconnected} = QuicConnection.init(conn: :next, listener: self(), hello: nil)
    assert {:noreply, ^reconnected} = QuicConnection.handle_info(message, reconnected)
    closing = %{moved | closing: true}
    assert {:noreply, ^closing} = QuicConnection.handle_info(message, closing)
  end

  test "计价数值检查违规的 0x68 原因串是 rejects:<检查名,…>（位序同 0x83），射线落空是 :no_target" do
    request = %{request_id: 7, client_intent_seq: 8, logical_scene_id: 1, action: 1}

    for {reason, text} <- [
          {{:rejects, [:domain]}, "rejects:domain"},
          {{:rejects, [:thermal_step, :first_tick]}, "rejects:first_tick,thermal_step"},
          {:no_target, ":no_target"}
        ] do
      {:ok, frame} = GateServer.Voxel.ResultFrame.error(request, reason) |> Codec.encode()
      size = byte_size(text)

      assert <<0x68, 7::64, 8::32, 1::64, 2, 0::64, 0::16, ^size::16, ^text::binary>> =
               IO.iodata_to_binary(frame)
    end
  end

  # G6-1（魔法 v2 切片 6，决策稿 §3.4、Q6-4）：四条前摇打断原因。进行到第 k ≥ 1 步的打断是已提交事务（扣第 1..k 步），
  # 0x68 accepted、result_ref = seq、原因串为 outcome 文本；第一笔注能前（k = 0）免费，0x68 rejected、原因串为 inspect 形式。
  # 准入原因（切片 7，`VoxelRegion.World.MagicAdmission`）同 rejected 形式：:structure_quota、:flight_quota、:region_budget
  # （客户端文案：结构数已满、飞行中的法术已满、分区魔法拥挤）。
  test "G6-1 前摇打断的 0x68 原因串：k ≥ 1 accepted \"interrupted_*\"，k = 0 rejected \":interrupted_*\"" do
    alias GateServer.Session.QuicConnection
    {:ok, conn} = QuicConnection.init(conn: :test, listener: self(), hello: nil)
    request = %{request_id: 7, client_intent_seq: 8, logical_scene_id: 1, action: 1}
    caster = %{seq: 9, energy_j: 1.0, capacity_j: 5.0e6, resolution_eff: 16.0, quote_j: 0.0, quote_s: 0.0, spent_j: 870.689,
      quote_windup_s: 0.0, x0: 0.0, x_star: 0.0, e_min_j: 0.0, p_maint_w: 0.0, life_s: 0.0, detect_w: 0.0, fail_step: 0,
      rejects: [], entries_charge: 0, entries_spoof: 0, first_tick_min_j: 0.0}

    for reason <- [:interrupted_cancelled, :interrupted_moved, :interrupted_disrupted, :interrupted_wounded] do
      text = Atom.to_string(reason)
      size = byte_size(text)
      reply = %{seq: 9, outcome: reason, fail_step: 2, caster: caster}
      assert {:noreply, sent} = QuicConnection.handle_info({:mmo_spell_reply, conn.edit_ref, request, reply}, conn)
      assert [{<<0x83, _::binary>>, _, _}, {receipt, _, _}] = :queue.to_list(sent.reliable[2])
      assert <<0x68, 7::64, 8::32, 1::64, 0, 9::64, 0::16, ^size::16, ^text::binary>> = receipt

      {:ok, frame} = GateServer.Voxel.ResultFrame.error(request, reason) |> Codec.encode()
      text = ":" <> text
      size = byte_size(text)
      assert <<0x68, 7::64, 8::32, 1::64, 2, 0::64, 0::16, ^size::16, ^text::binary>> = IO.iodata_to_binary(frame)
    end

    for {reason, text} <- [structure_quota: ":structure_quota", flight_quota: ":flight_quota", region_budget: ":region_budget"] do
      {:ok, frame} = GateServer.Voxel.ResultFrame.error(request, reason) |> Codec.encode()
      size = byte_size(text)
      assert <<0x68, 7::64, 8::32, 1::64, 2, 0::64, 0::16, ^size::16, ^text::binary>> = IO.iodata_to_binary(frame)
    end
  end
end
