defmodule SceneServer.Movement.P0BodyLifecycleTest do
  @moduledoc "只测试：真实 Player、Native、PostgreSQL 的恢复切点。World 热/收据与 Gate 下行/进程生命周期为显式替身；不冒充完整 World 或客户端链路。"
  use ExUnit.Case, async: false
  alias MmoContracts.{Session, Voxel}
  alias SceneServer.Movement.{Player, CollisionUpdates, Replication}
  alias SceneServer.Body

  setup do
    MmoTest.Database.start!()
    cid = System.unique_integer([:positive]) + 500_000
    replication = start_supervised!({Replication, [sink: MmoContracts.Session.Outbound]})

    profile =
      File.read!(Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__))
      |> Jason.decode!()
      |> Map.fetch!("profile")
      |> Map.put("fixed_hz", 60)

    raw = %{
      "schema" => "voxim-m1-demo-v1",
      "profile" => profile,
      "l0_min" => [0, 0, 0],
      "l0_max_exclusive" => [1, 1, 1],
      "travel_min_m" => [2, 2, 2],
      "travel_max_exclusive_m" => [14, 14, 14],
      "test_combat_bounds_m" => [[2, 2, 2], [14, 14, 14]],
      "spawn_probes_m" => [[4, 10, 4]],
      "spawn_min_y_m" => 3
    }

    path = Path.join(System.tmp_dir!(), "body-config-#{cid}.json")
    File.write!(path, Jason.encode!(raw))
    on_exit(fn -> File.rm!(path) end)
    config = SceneServer.Movement.Scene.load_config!(path)

    cells =
      for _z <- 0..15, y <- 0..15, _x <- 0..15, into: <<>>, do: <<if(y == 3, do: 1, else: 0)>>

    snapshot = %Voxel.CanonicalSnapshot{
      content_version: 731,
      transaction_seq: 0,
      l0_min: {0, 0, 0},
      l0_max_exclusive: {1, 1, 1},
      regions: [{{0, 0, 0}, <<>>}],
      chunks: [
        %Voxel.ChunkOccupancy{
          coord: {0, 0, 0},
          n: 16,
          scale_m: 1.0,
          origin_m: {0.0, 0.0, 0.0},
          cells: cells
        }
      ]
    }

    %{cid: cid, replication: replication, config: config, snapshot: snapshot}
  end

  defp open(ctx, epoch, snapshot \\ nil) do
    identity = %Session.Identity{session_epoch: epoch, scene_id: 1, scene_epoch: 1}
    snapshot = snapshot || ctx.snapshot

    updates =
      CollisionUpdates.new(SceneServer.Native.VoximMovement)
      |> CollisionUpdates.initialize(snapshot)

    now = System.monotonic_time(:microsecond)

    opts = [
      id: ctx.cid,
      epoch: epoch,
      kind: 0,
      scene: self(),
      gate: Map.get(ctx, :gate, self()),
      replication: ctx.replication,
      identity: identity,
      config: ctx.config,
      probe: {4.0, 10.0, 4.0},
      updates: updates,
      content_version: snapshot.content_version,
      authority_ref: Map.get(ctx, :authority_ref),
      scene_id: 1,
      scene_epoch: 1,
      sink: MmoContracts.Session.Outbound,
      clock: {SceneServer.Movement.Clock, nil},
      mono_origin: now,
      time_mono_origin: now,
      time_origin: System.system_time(:microsecond),
      body_store: {DataService.BodyStore, []}
    ]

    player = start_supervised!(Supervisor.child_spec({Player, opts}, id: {:player, epoch}))
    send(player, {:anchor, 0, updates, snapshot.content_version, snapshot})
    assert_receive {:mmo_reliable, ^identity, 1, %Session.SessionStart{}}, 2000
    Player.ready(player, identity, snapshot.transaction_seq, 1)
    Player.observe(player)
    {player, identity}
  end

  defp wound(player, identity) do
    {:ok, target} = Player.hit_context(player)

    hit = %{
      target: target,
      key: {identity, 1},
      request_id: 1,
      part: :legs,
      impact: %{depth: 0.2, protein_g: 3.0, heal_s: 60.0},
      actor: %{position: target.position, cid: 999, life_generation: 1, identity: identity}
    }

    assert {:ok, receipt} = Player.receive_hit(player, hit)
    receipt
  end

  defp forward_gate(receiver) do
    receive do
      :shutdown ->
        :ok

      message ->
        send(receiver, message)
        forward_gate(receiver)
    end
  end

  test "伤后重登保留身体和已扣食物，重复快照不重吃，停机时间不推进身体", ctx do
    {player, old} = open(ctx, 1)
    receipt = wound(player, old)
    assert receipt.body.life < 100

    # 仅 World 发送者替身：提交序号及营养量为手写小例，不调用被测算法构造期望。
    food = %{ctx.cid => %{9 => %{protein_g: 0.0, energy_j: 1000.0}}}
    snapshot = Map.put(ctx.snapshot, :food_receipts, food)
    assert :ok = Player.stop(player)
    {fresh, _} = open(ctx, 2, snapshot)
    saved = Player.body_snapshot(fresh)
    assert saved.body.traumas.legs.depth == 0.2
    assert saved.body.traumas.legs.heal == 0.0
    assert saved.food_cursors == %{731 => 9}
    assert_in_delta Body.heat_content_j(saved.body), Body.heat_content_j(Body.new()), 1.0e-6
    assert saved.body.fat_reserve_j == Body.new().fat_reserve_j + 1000.0
    assert :ok = Player.stop(fresh)
    {again, _} = open(ctx, 3, snapshot)
    assert Player.body_snapshot(again) == saved
    assert :ok = Player.stop(again)
  end

  test "已回复的伤害在 owner 被kill后仍可恢复", ctx do
    {player, identity} = open(ctx, 1)
    wound(player, identity)
    ref = Process.monitor(player)
    Process.exit(player, :kill)
    assert_receive {:DOWN, ^ref, :process, ^player, :killed}
    {restored, _} = open(ctx, 2)
    assert Player.body_snapshot(restored).body.traumas.legs.depth == 0.2
    assert :ok = Player.stop(restored)
  end

  test "两个停止请求共用一次 World fence，确认前收到的热量随身体恢复", ctx do
    cid = ctx.cid
    {player, _} = open(Map.put(ctx, :authority_ref, self()), 1)
    monitor = Process.monitor(player)
    first = Task.async(fn -> Player.stop(player) end)
    assert_receive {:body_detach, ^cid, ^player, fence}

    # 第二个真实 GenServer 请求与后续只读调用来自同一发送者：读回是已处理第二个 stop 的屏障。
    # 不能仅启动第二个 Task 就发 fence，否则它可能在 Player 已退出后才调用 stop，产生假通过。
    second = :gen_server.send_request(player, :stop)
    Player.body_snapshot(player)
    refute_receive {:body_detach, ^cid, ^player, _}, 0
    assert :timeout = :gen_server.wait_response(second, 0)
    assert Task.yield(first, 0) == nil

    # World 发送者替身：同一发送者保证最后一笔 90 J 热作用先于 detach 确认。
    send(
      player,
      {:body_heat,
       %{
         q_j: 90.0,
         tissue_j: 30.0,
         max_contact_k: 320.0,
         sole_k: 315.0,
         immersed: 0.25,
         dt_s: 0.5,
         seq: 11
       }}
    )

    send(player, {:body_detached, fence})
    assert :ok = Task.await(first)
    assert {:reply, :ok} = :gen_server.wait_response(second, 1000)
    assert_receive {:DOWN, ^monitor, :process, ^player, :normal}
    refute_receive {:body_detach, ^cid, ^player, _}, 0

    {restored, _} = open(ctx, 2)
    saved = Player.body_snapshot(restored)
    assert saved.body_exchange_j == 90.0

    assert saved.body_heat == %{
             q_j: 90.0,
             tissue_j: 30.0,
             max_contact_k: 320.0,
             sole_k: 315.0,
             immersed: 0.25
           }

    assert :ok = Player.stop(restored)
  end

  test "Gate 进程 DOWN 开始的退出可接纳 stop 等待者，收到原 fence 才结束", ctx do
    cid = ctx.cid
    receiver = self()
    gate = spawn(fn -> forward_gate(receiver) end)
    on_exit(fn -> if Process.alive?(gate), do: Process.exit(gate, :kill) end)
    {player, _} = open(ctx |> Map.put(:gate, gate) |> Map.put(:authority_ref, self()), 1)
    monitor = Process.monitor(player)
    send(gate, :shutdown)
    assert_receive {:body_detach, ^cid, ^player, fence}

    waiter = :gen_server.send_request(player, :stop)
    Player.body_snapshot(player)
    assert :timeout = :gen_server.wait_response(waiter, 0)
    refute_receive {:body_detach, ^cid, ^player, _}, 0
    send(player, {:body_detached, fence})
    assert {:reply, :ok} = :gen_server.wait_response(waiter, 1000)
    assert_receive {:DOWN, ^monitor, :process, ^player, :normal}
  end

  test "相同收据序号按 content_version 分开消费，回到原世界不会重吃", ctx do
    first_world =
      Map.put(ctx.snapshot, :food_receipts, %{
        ctx.cid => %{9 => %{protein_g: 0.0, energy_j: 1000.0}}
      })

    second_world =
      %{ctx.snapshot | content_version: 732}
      |> Map.put(:food_receipts, %{ctx.cid => %{9 => %{protein_g: 0.0, energy_j: 2000.0}}})

    {first, _} = open(ctx, 1, first_world)
    assert :ok = Player.stop(first)
    {second, _} = open(ctx, 2, second_world)
    saved = Player.body_snapshot(second)
    assert saved.food_cursors == %{731 => 9, 732 => 9}
    assert saved.body.fat_reserve_j == Body.new().fat_reserve_j + 3000.0
    assert :ok = Player.stop(second)
    {returned, _} = open(ctx, 3, first_world)
    assert Player.body_snapshot(returned) == saved
    assert :ok = Player.stop(returned)
  end
end
