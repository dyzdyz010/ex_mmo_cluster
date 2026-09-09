Code.require_file("runtime_observation.exs", __DIR__)
defmodule SceneServer.Movement.VoximAoiSceneTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.{Scene, Player}

  import SceneServer.Movement.RuntimeObservation

  alias MmoContracts.{Session, Movement, Voxel}

  defmodule Clock do
    def now(ref), do: :atomics.get(ref, 1)
    def schedule(_, _, _), do: :ok
  end

  defmodule Source do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def canonical_snapshot_and_subscribe(pid, _, subscriber, ref),
      do: GenServer.call(pid, {:snapshot, subscriber, ref})

    def handle_call({:snapshot, subscriber, ref}, _, state) do
      send(subscriber, {:canonical_snapshot, ref, state.snapshot})
      send(state.owner, :snapshot_sent)
      {:reply, :ok, Map.put(state, :subscriber, subscriber)}
    end

    def handle_call({:delta, delta}, _, state) do
      send(state.subscriber, {:canonical_delta, delta})

      {:reply, :ok,
       %{state | snapshot: %{state.snapshot | transaction_seq: delta.transaction_seq}}}
    end
  end

  defp identity(epoch),
    do: %Session.Identity{session_epoch: epoch, scene_id: 1, scene_epoch: 7}

  setup do
    fixture = Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)

    profile =
      File.read!(fixture) |> Jason.decode!() |> Map.fetch!("profile") |> Map.put("fixed_hz", 60)

    config = %{
      "schema" => "voxim-m1-demo-v1",
      "l0_min" => [-1, 7, -1],
      "l0_max_exclusive" => [1, 9, 1],
      "travel_min_m" => [-48.0, 464.0, -48.0],
      "travel_max_exclusive_m" => [48.0, 560.0, 48.0],
      "spawn_probes_m" => [[40.0, 558.0, 40.0], [42.0, 558.0, 40.0]],
      "spawn_min_y_m" => 464.0,
      "profile" => profile
    }

    chunks =
      for x <- -4..3, y <- 28..35, z <- -4..3 do
        cells =
          for _z <- 0..15,
              cy <- 0..15,
              _x <- 0..15,
              into: <<>>,
              do: <<if(y * 16 + cy == 500, do: 1, else: 0)>>

        %Voxel.ChunkOccupancy{
          coord: {x, y, z},
          n: 16,
          scale_m: 1.0,
          origin_m: {x * 16.0, y * 16.0, z * 16.0},
          cells: cells
        }
      end

    snapshot = %Voxel.CanonicalSnapshot{
      content_version: 9,
      transaction_seq: 0,
      l0_min: {-1, 7, -1},
      l0_max_exclusive: {1, 9, 1},
      chunks: chunks,
      regions: for(x <- -1..0, y <- 7..8, z <- -1..0, do: {{x, y, z}, <<>>})
    }

    clock = :atomics.new(1, signed: true)
    source = start_supervised!({Source, %{snapshot: snapshot, owner: self()}})

    scene =
      start_supervised!(
        {Scene,
         [
           scene_id: 1,
           scene_epoch: 7,
           world_ref: source,
           world_api: Source,
           config: config,
           clock: {Clock, clock}
         ]}
      )

    assert_receive :snapshot_sent, 2000
    await(scene, & &1.initialized)
    %{scene: scene, clock: clock, source: source, snapshot: snapshot}
  end

  defp await(scene, predicate, attempts \\ 200) do
    info = observe(scene)

    if predicate.(info) do
      info
    else
      assert attempts > 0, inspect(info)

      receive do
      after
        1 -> :ok
      end

      await(scene, predicate, attempts - 1)
    end
  end

  defp advance(ctx, tick) do
    :atomics.put(ctx.clock, 1, div(tick * 1_000_000 + 59, 60))
    send(ctx.scene, :tick)
    await(ctx.scene, &(&1.tick == tick))
  end

  defp join(ctx, epoch, cid, gate \\ self()) do
    Scene.join(ctx.scene, identity(epoch), %{id: cid}, gate)
    assert_receive :snapshot_sent, 1000
    await(ctx.scene, &(&1.queue_length > 0))
    advance(ctx, observe(ctx.scene).tick + 1)
    assert_receive {:mmo_reliable, _, 1, %Session.SessionStart{} = start}
    start
  end

  defp ready(ctx, epoch) do
    Player.time_probe(player(ctx.scene, identity(epoch)), identity(epoch), %Session.TimeProbe{
      request_id: epoch,
      client_send_us: 1
    })

    Player.ready(player(ctx.scene, identity(epoch)), identity(epoch), 0, 1)
  end

  defp outputs(acc \\ []) do
    receive do
      {:mmo_reliable, _, _, _} = item -> outputs([item | acc])
      {:mmo_datagram, _, _} = item -> outputs([item | acc])
      {:mmo_close, _, _} = item -> outputs([item | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp lifecycle(events),
    do:
      for(
        {:mmo_reliable, _, 1, event} <- events,
        is_struct(event, Session.EntityEnter) or is_struct(event, Session.EntityLeave),
        do: event
      )

  defp snapshots(events),
    do: for({:mmo_datagram, _, %Movement.Snapshot{} = event} <- events, do: event)

  test "normal Scene stop terminates both owned roots, Players and observer workers", ctx do
    active_pair(ctx)
    info = Scene.observe(ctx.scene)
    owned = [info.player_supervisor_pid, info.replication_pid] ++
      Enum.map(info.characters, & &1.player_pid) ++
      SceneServer.Movement.Replication.workers(info.replication_pid)
    refs = Enum.map(owned, &Process.monitor/1)
    GenServer.stop(ctx.scene, :normal)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _})
    assert Enum.all?(owned, &(not Process.alive?(&1)))
  end

  defp active_pair(ctx) do
    a = join(ctx, 1, 20)
    b = join(ctx, 2, 10)
    ready(ctx, 1)
    ready(ctx, 2)
    advance(ctx, 3)
    advance(ctx, 33)
    advance(ctx, 36)
    # 复制机会可以先于某个 Player 结果；等公开关系而不假设相同调度顺序。
    await(ctx.scene, &(length(&1.aoi) == 2 and Enum.all?(&1.aoi, fn o -> length(o.visible) == 1 end)))
    outputs()
    {a, b}
  end

  defp commands(ctx, epoch, last, axis \\ 0) do
    owner = player(ctx.scene, identity(epoch))
    current = Player.observe(owner)
    frames = for seq <- (current.processed_input_seq + 1)..last do
      %Movement.InputFrame{input_seq: seq, axis_x: axis, axis_z: 0,
        yaw: if(axis < 0, do: 32768, else: 0), jump_pressed: 0}
    end
    for batch <- Enum.chunk_every(frames, 6),
      do: Player.input(owner, identity(epoch), %Movement.InputBatch{identity: identity(epoch), frames: batch})
  end

  defp sample(ctx, tick) do
    advance(ctx, tick)
    info = observe(ctx.scene)
    # 测试提供下次真实复制机会，没有给生产增加等待全部玩家的 barrier。
    SceneServer.Movement.Replication.publish(info.replication_pid, tick)
    SceneServer.Movement.Replication.observe(info.replication_pid)
    {info, outputs()}
  end

  test "origin gates reliable Enter whose anchor and snapshots use actual simulation ticks", ctx do
    a = join(ctx, 1, 20)
    b = join(ctx, 2, 10)
    ready(ctx, 1)
    ready(ctx, 2)
    advance(ctx, 3)
    advance(ctx, 32)
    assert lifecycle(outputs()) == []
    {info, events} = sample(ctx, 33)
    enters = lifecycle(events)
    assert length(enters) == 2
    for enter <- enters do
      assert enter.server_tick == 32
      assert enter.state == Enum.find(info.characters, &(&1.entity_id == enter.entity_id)).state
      snap = Enum.find(snapshots(events), &(&1.identity == enter.identity))
      assert snap.server_tick == 32
      assert [record] = snap.records
      assert record.state == enter.state and record.interest_generation == enter.interest_generation
    end
    assert Enum.map(enters, &{&1.identity, &1.entity_id}) |> MapSet.new() ==
      MapSet.new([{a.identity, 10}, {b.identity, 20}])
  end

  test "real P1 movement crosses 34m and returns within 30m with a newer generation", ctx do
    active_pair(ctx)
    commands(ctx, 1, 301, -32767)
    {away, events} = sample(ctx, 333)
    assert Enum.any?(lifecycle(events), &is_struct(&1, Session.EntityLeave))
    [q, p] = Enum.sort_by(away.characters, & &1.entity_id)
    assert elem(q.state.position, 0) - elem(p.state.position, 0) > 34.0
    commands(ctx, 1, 451, 32767)
    {back, events} = sample(ctx, 483)
    enters = Enum.filter(lifecycle(events), &is_struct(&1, Session.EntityEnter))
    assert length(enters) == 2
    assert Enum.all?(enters, &(&1.interest_generation == 2 and &1.entity_epoch in [1, 2]))
    [q, p] = Enum.sort_by(back.characters, & &1.entity_id)
    assert abs(elem(q.state.position, 0) - elem(p.state.position, 0)) <= 30.0
    for snapshot <- snapshots(events) do
      assert {:ok, bytes} = Movement.Codec.encode(snapshot)
      assert {:ok, ^snapshot} = Movement.Codec.decode(bytes)
    end
  end

  test "leave and reconnect generations cannot be revived by the removed Player result", ctx do
    {_a, old} = active_pair(ctx)
    old_player = player(ctx.scene, identity(2))
    old_value = Player.observe(old_player)
    Scene.leave(ctx.scene, old.identity)
    info = await(ctx.scene, &(&1.character_count == 1))
    SceneServer.Movement.Replication.observe(info.replication_pid)
    assert_receive {:mmo_reliable, _, 1, %Session.EntityLeave{entity_id: 10, interest_generation: 1}}
    fresh = join(ctx, 3, 10)
    assert fresh.entity_epoch > old.entity_epoch
    SceneServer.Movement.Replication.result(info.replication_pid, old_value)
    Scene.leave(ctx.scene, old.identity)
    ready(ctx, 3)
    advance(ctx, 38)
    assert_receive {:mmo_reliable, _, 1, %Session.InputStart{identity: fresh_identity, origin_tick: origin}}
    assert fresh_identity == fresh.identity
    {_info, events} = sample(ctx, origin + 3)
    assert Enum.any?(lifecycle(events), fn
      %Session.EntityEnter{entity_id: 10, entity_epoch: epoch, interest_generation: 2} -> epoch == fresh.entity_epoch
      _ -> false
    end)
    assert observe(ctx.scene).character_count == 2
    Scene.leave(ctx.scene, identity(1))
    Scene.leave(ctx.scene, identity(3))
    assert await(ctx.scene, &(&1.character_count == 0)).aoi == []
  end

  test "fast and stalled players retain distinct snapshot ticks and collision revisions", ctx do
    active_pair(ctx)
    old = Player.observe(player(ctx.scene, identity(1)))
    chunk = Enum.find(ctx.snapshot.chunks, &(&1.coord == {2, 31, 2}))
    GenServer.call(ctx.source, {:delta, %Voxel.CanonicalDelta{transaction_seq: 1,
      transaction: %{seq: 1, entries: [], coarse: []}, chunks: [%{chunk | cells: :binary.copy(<<0>>, 4096)}]}})
    await(ctx.scene, &(&1.queue_length == 1))
    commands(ctx, 2, 10)
    {info, events} = sample(ctx, 42)
    fast = Enum.find(info.characters, &(&1.entity_id == 10))
    assert fast.simulation_tick == 42 and fast.collision_revision == 2
    events = snapshots(events)
    assert Enum.any?(events, fn snapshot ->
      snapshot.server_tick == 42 and Enum.any?(snapshot.records, &(&1.entity_id == 10 and &1.collision_revision == 2 and &1.state == fast.state))
    end)
    assert Enum.any?(events, fn snapshot ->
      snapshot.server_tick == 32 and Enum.any?(snapshot.records, &(&1.entity_id == 20 and &1.collision_revision == 1 and &1.state == old.state))
    end)
  end

end

defmodule SceneServer.Movement.VoximAoiTest do
  use ExUnit.Case, async: true
  alias SceneServer.Movement.AOI
  alias MmoContracts.Session

  defp entity(id, position, epoch \\ 1) do
    %{
      identity: %Session.Identity{session_epoch: id, scene_id: 1, scene_epoch: 7},
      entity_id: id,
      entity_epoch: epoch,
      state: %Session.State{position: position, velocity: {0.0, 0.0, 0.0}, grounded: 1, yaw: 0}
    }
  end

  defp update(aoi, entities, tick, revision) do
    entities = Enum.map(entities, &Map.merge(&1, %{simulation_tick: tick, collision_revision: revision}))
    AOI.update(aoi, entities, tick)
  end

  defp position(entity, point), do: %{entity | state: %{entity.state | position: point}}

  @tag :m3_remaining
  test "one observer receives separate packets for distinct actual target ticks" do
    a = Map.merge(entity(10, {0.0, 500.0, 0.0}), %{simulation_tick: 40, collision_revision: 3})
    b = Map.merge(entity(20, {1.0, 500.0, 0.0}), %{simulation_tick: 31, collision_revision: 1})
    c = Map.merge(entity(30, {2.0, 500.0, 0.0}), %{simulation_tick: 39, collision_revision: 2})
    {_, enters, snapshots} = AOI.update(AOI.new(), [a, b, c], 42)
    targets = %{10 => a, 20 => b, 30 => c}
    assert length(Enum.filter(snapshots, &(&1.identity == a.identity))) == 2
    for snapshot <- snapshots, record <- snapshot.records do
      target = targets[record.entity_id]
      assert snapshot.server_tick == target.simulation_tick
      assert record.collision_revision == target.collision_revision
      assert record.state == target.state
    end
    for event <- enters, do: assert(event.server_tick == targets[event.entity_id].simulation_tick)
  end

  test "canonical XYZ distance, exact thresholds, symmetry and negative grid boundaries" do
    a = entity(10, {-0.5, 500.0, -0.5})

    for point <- [{-0.5, 540.0, -0.5}, {29.501, 500.0, -0.5}, {-0.5, 500.0, 29.501}] do
      {_, [], snapshots} = update(AOI.new(), [a, entity(20, point)], 3, 7)
      assert Enum.all?(snapshots, &(&1.records == []))
    end

    for point <- [{29.5, 500.0, -0.5}, {-0.5, 530.0, -0.5}, {-0.5, 500.0, 29.5}] do
      b = entity(20, point)
      {aoi, enters, snapshots} = update(AOI.new(), [b, a], 3, 7)
      assert length(enters) == 2
      assert Enum.all?(enters, &is_struct(&1, Session.EntityEnter))
      assert Enum.map(snapshots, &Enum.map(&1.records, fn r -> r.entity_id end)) == [[20], [10]]
      assert Enum.all?(snapshots, &Enum.all?(&1.records, fn r -> r.collision_revision == 7 end))
      assert length(AOI.observe(aoi)) == 2
    end

    b = entity(20, {29.5, 500.0, -0.5})
    {aoi, _, _} = update(AOI.new(), [a, b], 3, 1)
    b = position(b, {33.5, 500.0, -0.5})
    {aoi, [], retained} = update(aoi, [a, b], 6, 1)
    assert Enum.all?(retained, &(length(&1.records) == 1))
    b = position(b, {33.501, 500.0, -0.5})
    {aoi, leaves, empty} = update(aoi, [a, b], 9, 1)
    assert length(leaves) == 2
    assert Enum.all?(leaves, &is_struct(&1, Session.EntityLeave))
    assert Enum.all?(empty, &(&1.records == []))
    {aoi, [], _} = update(aoi, [a, position(b, {31.5, 500.0, -0.5})], 12, 1)
    {_, enters, _} = update(aoi, [a, position(b, {29.5, 500.0, -0.5})], 15, 1)
    assert Enum.all?(enters, &(&1.entity_epoch == 1 and &1.interest_generation == 2))
  end

  test "observer-local generations follow distinct histories and snapshots stay entity-sorted" do
    a = entity(10, {0.0, 500.0, 0.0})
    b = entity(20, {1.0, 500.0, 0.0})
    c = entity(30, {100.0, 500.0, 0.0})
    {aoi, _, _} = update(AOI.new(), [c, b, a], 3, 1)
    c = position(c, {2.0, 500.0, 0.0})
    {aoi, enters, snapshots} = update(aoi, [c, b, a], 6, 9)

    assert Enum.find(enters, &(&1.identity == a.identity and &1.entity_id == 30)).interest_generation ==
             2

    assert Enum.find(enters, &(&1.identity == c.identity and &1.entity_id == 10)).interest_generation ==
             1

    for snap <- snapshots do
      assert Enum.map(snap.records, & &1.entity_id) ==
               Enum.sort(Enum.map(snap.records, & &1.entity_id))

      refute Enum.any?(snap.records, &(&1.entity_id == snap.identity.session_epoch))
    end

    {aoi, leaves} = AOI.remove(aoi, b.identity, 20, 1, 7)
    assert length(leaves) == 2
    refute Enum.any?(AOI.observe(aoi), &(&1.identity == b.identity))
    b = %{b | identity: %{b.identity | session_epoch: 21}, entity_epoch: 2}
    {aoi, enters, snapshots} = update(aoi, [c, b, a], 9, 9)
    enter = Enum.find(enters, &(&1.identity == a.identity and &1.entity_id == 20))
    assert enter.entity_epoch == 2 and enter.interest_generation == 3
    snap = Enum.find(snapshots, &(&1.identity == a.identity))
    assert Enum.find(snap.records, &(&1.entity_id == 20)).interest_generation == 3
    {aoi, _} = AOI.remove(aoi, a.identity, 10, 1, 10)
    {aoi, _} = AOI.remove(aoi, b.identity, 20, 2, 10)
    {aoi, []} = AOI.remove(aoi, c.identity, 30, 1, 10)
    assert AOI.observe(aoi) == []
  end
end
