defmodule SceneServer.Movement.VoximNeighbourTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.{Replication, Clock}
  alias MmoContracts.{Session, Movement}

  defp value(id, scene, tick) do
    %{identity: %Session.Identity{session_epoch: id, scene_id: scene, scene_epoch: 1},
      entity_id: id, entity_epoch: 1, player_pid: self(), active: true,
      simulation_tick: tick, collision_revision: 1,
      state: %Session.State{position: {id * 1.0, 500.0, 0.0},
        velocity: {0.0, 0.0, 0.0}, grounded: 1, yaw: 0}}
  end

  defp join(rep, value) do
    Replication.join(rep, value.identity, value.entity_id, value.entity_epoch, self(), self())
    Replication.result(rep, value)
  end

  test "neighbour state is visible only to local observers in their clock and cannot be relayed" do
    {:ok, a} = Replication.start_link(sink: GateServer.Session.Sink)
    {:ok, b} = Replication.start_link(sink: GateServer.Session.Sink)
    on_exit(fn -> for p <- [a, b], Process.alive?(p), do: GenServer.stop(p) end)
    av = value(1, 1, 600)
    bv = value(2, 2, 60)
    join(a, av)
    join(b, bv)
    :ok = Replication.neighbour(a, b, 9_000_000)
    :ok = Replication.neighbour(b, a, -9_000_000)
    :ok = Replication.neighbour(b, self(), 0)
    Replication.publish(b, 60)
    # 同步读取发送者和接收者，确保异步帧已到达后才要求本地发布。
    Replication.workers(b)
    Replication.workers(a)
    Replication.publish(a, 600)
    ai = av.identity
    assert_receive {:mmo_reliable, ^ai, 1, %Session.EntityEnter{entity_id: 2, server_tick: 600}}, 1000
    assert_receive {:mmo_datagram, ^ai, %Movement.Snapshot{server_tick: 600, records: [%{entity_id: 2}]}}, 1000
    assert [%{identity: ^ai}] = Replication.observe(a)

    Replication.leave(b, bv.identity, 2, 1, 61)
    Replication.publish(b, 63)
    assert_receive {:neighbour_frame, ^b, 63, []}, 1000
    Replication.workers(b)
    Replication.workers(a)
    Replication.publish(a, 603)
    assert_receive {:mmo_reliable, ^ai, 1, %Session.EntityLeave{entity_id: 2}}, 1000
    # 离场前的整个旧帧晚到也不能恢复实体。
    send(a, {:neighbour_frame, b, 60, [bv]})
    Replication.publish(a, 606)
    assert [%{visible: []}] = Replication.observe(a)
    # A 发回的帧不能夹带已删除的 B；B 只有自己的观察者。
    assert Replication.observe(b) == []
  end

  test "tick conversion keeps historical age instead of stamping the arrival tick" do
    assert Clock.translate_tick(60, 9_000_000) == 600
    assert Clock.translate_tick(600, -9_000_000) == 60
    assert Clock.translate_tick(10, -1) == 9
    assert Clock.translate_tick(10, 1) == 10
  end

  test "endpoint death clears read-only neighbours without stopping local publication" do
    {:ok, a} = Replication.start_link(sink: GateServer.Session.Sink)
    b = spawn(fn -> receive do :stop -> :ok end end)
    av = value(1, 1, 60)
    bv = value(2, 2, 60)
    join(a, av)
    :ok = Replication.neighbour(a, b, 0)
    send(a, {:neighbour_frame, b, 60, [bv]})
    Replication.publish(a, 60)
    assert [%{visible: [_]}] = Replication.observe(a)
    monitor = Process.monitor(b)
    send(b, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^b, :normal}
    # 显式等待 monitor 已消费，不依赖测试进程与 Replication 的收信顺序。
    await_empty(a, 63, 100)
    send(a, {:neighbour_frame, b, 66, [bv]})
    Replication.publish(a, 66)
    assert [%{visible: []}] = Replication.observe(a)
    GenServer.stop(a)
  end

  defp await_empty(rep, tick, attempts) do
    Replication.publish(rep, tick)
    case Replication.observe(rep) do
      [%{visible: []}] -> :ok
      _ ->
        assert attempts > 0
        Process.sleep(1)
        await_empty(rep, tick + 3, attempts - 1)
    end
  end
end
