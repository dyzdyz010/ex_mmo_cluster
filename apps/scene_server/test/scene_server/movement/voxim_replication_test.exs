defmodule SceneServer.Movement.VoximReplicationTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.Replication
  alias MmoContracts.{Session, Movement}

  defp identity(id), do: %Session.Identity{session_epoch: id, scene_id: 1, scene_epoch: 7}

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  test "paused observer worker does not block peers, leave cleanup or read-only metrics" do
    {:ok, rep} = Replication.start_link(sink: GateServer.Session.Sink)

    values =
      for id <- 1..4 do
        value = %{
          identity: identity(id),
          entity_id: id,
          entity_epoch: id,
          player_pid: self(),
          active: true,
          simulation_tick: 300,
          collision_revision: 1,
          state: %Session.State{
            position: {id * 1.0, 500.0, 0.0},
            velocity: {0.0, 0.0, 0.0},
            grounded: 1,
            yaw: 0
          }
        }

        Replication.join(rep, value.identity, id, value.entity_epoch, self(), self())
        Replication.result(rep, value)
        value
      end

    Replication.publish(rep, 300)
    assert length(Replication.observe(rep)) == 4
    flush()
    workers = Replication.workers(rep)
    paused = hd(workers)
    :ok = :sys.suspend(paused)

    try do
      for value <- values,
          do: Replication.result(rep, %{value | simulation_tick: 303, collision_revision: 2})

      Replication.publish(rep, 303)
      peer = identity(1)

      assert_receive {:mmo_datagram, ^peer,
                      %Movement.Snapshot{server_tick: 303, records: records}}

      assert length(records) == 3
      assert Enum.all?(records, &(&1.collision_revision == 2))
      Replication.leave(rep, identity(4), 4, 4, 304)
      assert_receive {:mmo_reliable, ^peer, 1, %Session.EntityLeave{entity_id: 4}}
      Replication.result(rep, List.last(values))
      Replication.publish(rep, 306)
      assert_receive {:mmo_datagram, ^peer, %Movement.Snapshot{records: remaining}}
      refute Enum.any?(remaining, &(&1.entity_id == 4))
      metrics = Replication.metrics(rep)
      assert Enum.find(metrics.workers, &(&1.pid == paused)).message_queue_len > 0
      assert metrics.dispatcher.message_queue_len == 0
    after
      :ok = :sys.resume(paused)
    end

    relations = Replication.observe(rep)
    assert length(relations) == 3
    refute Enum.any?(relations, &(&1.identity == identity(4)))

    assert Enum.all?(relations, fn observer ->
             length(observer.visible) == 2 and Enum.all?(observer.visible, &(&1.entity_id != 4))
           end)

    refs = Enum.map(workers, &Process.monitor/1)
    GenServer.stop(rep)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, :normal})
  end

  test "the actual 200 player ids use all four observer workers evenly" do
    members =
      Path.join(__DIR__, "fixtures/m3_actual_members.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("members")

    assert Enum.frequencies_by(members, &rem(&1["entity_id"], 4)) == %{1 => 101, 3 => 99}
    {:ok, rep} = Replication.start_link(sink: GateServer.Session.Sink)

    for member <- members do
      epoch = member["entity_epoch"]
      Replication.join(rep, identity(epoch), member["entity_id"], epoch, self(), self())

      Replication.result(rep, %{
        identity: identity(epoch),
        entity_id: member["entity_id"],
        entity_epoch: epoch,
        player_pid: self(),
        active: true,
        simulation_tick: 300,
        collision_revision: 1,
        state: %Session.State{
          position: {epoch * 100.0, 500.0, 0.0},
          velocity: {0.0, 0.0, 0.0},
          grounded: 1,
          yaw: 0
        }
      })
    end

    Replication.publish(rep, 300)
    assert length(Replication.observe(rep)) == 200

    counts =
      for worker <- Replication.workers(rep),
          do: length(SceneServer.Movement.ReplicationWorker.observe(worker))

    assert counts == [50, 50, 50, 50]
    GenServer.stop(rep)
  end
end

defmodule SceneServer.Movement.M4aReplicationTransferTest do
  use ExUnit.Case, async: true
  @moduletag :m4a_transfer
  alias SceneServer.Movement.{AOI, Replication}
  alias MmoContracts.{Session, Movement}

  defp value(id, session, scene, x) do
    %{identity: %Session.Identity{session_epoch: session, scene_id: scene, scene_epoch: 7},
      entity_id: id, entity_epoch: id, player_pid: self(), active: true,
      simulation_tick: 60, collision_revision: 1,
      state: %Session.State{position: {x, 500.0, 0.0}, velocity: {0.0, 0.0, 0.0}, grounded: 1, yaw: 0}}
  end

  defp join(rep, value) do
    Replication.join(rep, value.identity, value.entity_id, value.entity_epoch, self(), self())
    Replication.result(rep, value)
  end

  defp sample(rep, tick) do
    Replication.publish(rep, tick)
    Replication.observe(rep)
  end

  defp discard_outputs do
    receive do
      {:mmo_reliable, _, _, _} -> discard_outputs()
      {:mmo_datagram, _, _} -> discard_outputs()
      {:neighbour_frame, _, _, _} -> discard_outputs()
    after
      0 -> :ok
    end
  end

  test "AOI chooses one newest session per incarnation before spatial indexing" do
    a = value(1, 1, 1, 0.0)
    old = value(2, 2, 1, 100.0)
    fresh = value(2, 3, 2, 1.0)
    for entities <- [[a, old, fresh], [fresh, old, a]] do
      frame = AOI.frame(entities)
      assert frame.entities == [a, fresh]
      assert frame.by_key[{2, 2}] == fresh
      {_, [enter], [snapshot]} = AOI.update_frame(AOI.new(), frame, 60, %{a.identity => true})
      assert enter.entity_id == 2 and enter.interest_generation == 1
      assert [%{entity_id: 2, entity_epoch: 2, state: state}] = snapshot.records
      assert state == fresh.state
    end
  end

  test "moving an observer keeps generation and visibility without emitting lifecycle" do
    source = start_supervised!({Replication, [sink: GateServer.Session.Sink]}, id: :source)
    target = start_supervised!({Replication, [sink: GateServer.Session.Sink]}, id: :target)
    a = value(1, 1, 1, 0.0)
    b = value(2, 2, 1, 1.0)
    join(source, a)
    join(source, b)
    sample(source, 60)
    discard_outputs()
    observer = Replication.take_observer(source, a.identity)
    assert observer == {1, %{{2, 2} => 1}, [{2, 2}]}
    assert Replication.take_observer(source, a.identity) == nil
    assert [%{identity: identity}] = Replication.observe(source)
    assert identity == b.identity
    fresh = %{a | identity: %{a.identity | session_epoch: 3, scene_id: 2}}
    fresh_identity = fresh.identity
    Replication.join(target, fresh.identity, fresh.entity_id, fresh.entity_epoch, self(), self())
    join(target, b)
    assert :ok = Replication.put_observer(target, fresh.identity, self(), observer)
    sample(target, 60)
    assert Enum.find(Replication.observe(target), &(&1.identity == fresh.identity)).last_generation == 1
    Replication.result(target, fresh)
    sample(target, 60)
    assert_receive {:mmo_datagram, ^fresh_identity, %Movement.Snapshot{records: [record]}}
    assert record.entity_id == 2 and record.interest_generation == 1
    refute_receive {:mmo_reliable, ^fresh_identity, _, %Session.EntityEnter{}}
    refute_receive {:mmo_reliable, _, _, %Session.EntityLeave{}}
    Replication.leave(target, b.identity, 2, 2, 61)
    sample(target, 63)
    discard_outputs()
    join(target, b)
    sample(target, 66)
    assert_receive {:mmo_reliable, ^fresh_identity, _, %Session.EntityEnter{interest_generation: 2}}
  end

  test "source cut bridge is exported until same-tick target frame while neighbour ghosts never are" do
    source = start_supervised!({Replication, [sink: GateServer.Session.Sink]})
    a = value(1, 1, 1, 0.0)
    b = value(2, 2, 1, 1.0)
    fresh = %{a | identity: %{a.identity | session_epoch: 3, scene_id: 2},
      state: %{a.state | position: {2.0, 500.0, 0.0}}}
    spectator = b.identity
    :ok = Replication.neighbour(source, self(), 0, 2)
    join(source, a)
    join(source, b)
    sample(source, 60)
    discard_outputs()
    Replication.take_observer(source, a.identity)
    assert :ok = Replication.handoff(source, a.identity, fresh.identity, 2)
    Replication.result(source, %{a | simulation_tick: 99})
    sample(source, 63)
    assert_receive {:neighbour_frame, ^source, 63, exported}
    assert Enum.map(exported, & &1.identity) |> Enum.sort() == Enum.sort([a.identity, b.identity])
    cut = Enum.find(exported, &(&1.identity == a.identity))
    assert cut.simulation_tick == 60 and cut.state == a.state
    assert_receive {:mmo_datagram, ^spectator, %Movement.Snapshot{records: [record]}}
    assert record.entity_epoch == 1 and record.interest_generation == 1
    refute_receive {:mmo_reliable, _, _, %Session.EntityLeave{}}
    send(source, {:neighbour_frame, self(), 63, []})
    ghost = value(3, 4, 2, 1000.0)
    send(source, {:neighbour_frame, self(), 63, [fresh, ghost]})
    Replication.flush(source)
    Replication.observe(source)
    assert_receive {:neighbour_frame, ^source, 63, exported}
    assert Enum.map(exported, & &1.identity) == [b.identity]
    assert_receive {:mmo_datagram, ^spectator, %Movement.Snapshot{records: [record]}}
    assert record.state == fresh.state and record.interest_generation == 1
    refute_receive {:mmo_reliable, ^spectator, _, %Session.EntityEnter{}}
    send(source, {:neighbour_frame, self(), 66, []})
    sample(source, 66)
    assert_receive {:mmo_reliable, ^spectator, _, %Session.EntityLeave{entity_id: 1}}
  end

  test "target peer loss removes a bridge even before its first populated frame" do
    for event <- [:neighbour_closed, :down] do
      {:ok, source} = Replication.start_link(sink: GateServer.Session.Sink)
      a = value(1, 1, 1, 0.0)
      b = value(2, 2, 1, 1.0)
      spectator = b.identity
      fresh = %{a.identity | session_epoch: 3, scene_id: 2}
      peer = spawn(fn -> receive do :stop -> :ok end end)
      :ok = Replication.neighbour(source, peer, 0, 2)
      join(source, a)
      join(source, b)
      sample(source, 60)
      discard_outputs()
      Replication.take_observer(source, a.identity)
      :ok = Replication.handoff(source, a.identity, fresh, 2)
      case event do
        :neighbour_closed -> send(source, {:neighbour_closed, peer})
        :down ->
          monitor = :sys.get_state(source).neighbours[peer].monitor
          send(source, {:DOWN, monitor, :process, peer, :normal})
      end
      sample(source, 63)
      assert_receive {:mmo_reliable, ^spectator, _, %Session.EntityLeave{entity_id: 1}}
      send(peer, :stop)
      GenServer.stop(source)
    end
  end
end
