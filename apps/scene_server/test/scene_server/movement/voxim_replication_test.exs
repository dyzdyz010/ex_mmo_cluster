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
