defmodule SceneServer.Movement.VoximAoiSceneTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.Scene
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
    info = Scene.observe(scene)

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
    advance(ctx, Scene.observe(ctx.scene).tick + 1)
    assert_receive {:mmo_reliable, _, 1, %Session.SessionStart{} = start}
    start
  end

  defp ready(ctx, epoch) do
    Scene.time_probe(ctx.scene, identity(epoch), %Session.TimeProbe{
      request_id: epoch,
      client_send_us: 1
    })

    Scene.ready(ctx.scene, identity(epoch), 0, 1)
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

  defp active_pair(ctx) do
    a = join(ctx, 1, 20)
    b = join(ctx, 2, 10)
    ready(ctx, 1)
    ready(ctx, 2)
    advance(ctx, 3)
    advance(ctx, 33)
    outputs()
    {a, b}
  end

  defp assert_lifecycle_before_snapshot(events) do
    for {{:mmo_reliable, identity, 1, typed}, index} <- Enum.with_index(events),
        is_struct(typed, Session.EntityEnter) or is_struct(typed, Session.EntityLeave) do
      for {{:mmo_datagram, ^identity, %Movement.Snapshot{}}, snapshot_index} <-
            Enum.with_index(events) do
        assert index < snapshot_index
      end
    end
  end

  defp drive_until(ctx, axis, type) do
    first = Scene.observe(ctx.scene).tick + 1

    Enum.reduce_while(first..(first + 400), nil, fn tick, _ ->
      frame = %Movement.InputFrame{
        input_seq: tick - 32,
        axis_x: axis,
        axis_z: 0,
        yaw: if(axis < 0, do: 32768, else: 0),
        jump_pressed: 0
      }

      Scene.input(ctx.scene, identity(1), %Movement.InputBatch{
        identity: identity(1),
        frames: [frame]
      })

      info = advance(ctx, tick)
      events = outputs()

      for snapshot <- snapshots(events), record <- snapshot.records do
        assert record.state ==
                 Enum.find(info.characters, &(&1.entity_id == record.entity_id)).state

        assert snapshot.server_tick == tick
      end

      matching = Enum.filter(lifecycle(events), &is_struct(&1, type))

      if matching != [] do
        assert length(matching) == 2
        assert rem(tick, 3) == 0
        assert_lifecycle_before_snapshot(events)
        {:halt, {info, events}}
      else
        {:cont, nil}
      end
    end) || flunk("real P1 trajectory did not reach expected AOI boundary")
  end

  test "origin gates symmetric reliable Enter before third-tick absolute snapshots", ctx do
    a = join(ctx, 1, 20)
    b = join(ctx, 2, 10)
    ready(ctx, 1)
    ready(ctx, 2)
    advance(ctx, 3)
    advance(ctx, 32)
    waiting = outputs()
    assert lifecycle(waiting) == []
    assert snapshots(waiting) == []

    info = advance(ctx, 33)
    events = outputs()
    enters = lifecycle(events)
    assert length(enters) == 2
    assert Enum.all?(enters, &is_struct(&1, Session.EntityEnter))

    assert Enum.map(enters, &{&1.identity, &1.entity_id}) |> MapSet.new() ==
             MapSet.new([{a.identity, 10}, {b.identity, 20}])

    assert length(snapshots(events)) == 2

    for enter <- enters do
      remote = Enum.find(info.characters, &(&1.entity_id == enter.entity_id))
      assert enter.state == remote.state
      assert enter.server_tick == 33
      snap = Enum.find(snapshots(events), &(&1.identity == enter.identity))
      assert snap.server_tick == 33
      assert [record] = snap.records
      assert record.entity_id == enter.entity_id
      assert record.entity_epoch == enter.entity_epoch
      assert record.interest_generation == enter.interest_generation
      assert record.collision_revision == 1
      assert record.state == enter.state
      enter_index = Enum.find_index(events, &match?({:mmo_reliable, _, 1, ^enter}, &1))
      snapshot_index = Enum.find_index(events, &match?({:mmo_datagram, _, ^snap}, &1))
      assert enter_index < snapshot_index
    end

    advance(ctx, 35)
    assert outputs() == []
    advance(ctx, 36)
    stationary = outputs()
    assert lifecycle(stationary) == []
    assert length(snapshots(stationary)) == 2
    assert Enum.all?(snapshots(stationary), &(&1.server_tick == 36))

    IO.puts(
      "A1_ORIGIN_TRACE " <>
        inspect(%{starts: [a, b], tick33: events, tick36: stationary}, limit: :infinity)
    )
  end

  test "real P1 movement leaves beyond 34 and returns within 30 with same epoch and newer generation",
       ctx do
    {a, b} = active_pair(ctx)
    {away, leaves} = drive_until(ctx, -32767, Session.EntityLeave)
    [left, right] = Enum.sort_by(away.characters, & &1.entity_id)
    assert elem(left.state.position, 0) - elem(right.state.position, 0) > 34.0
    assert Enum.all?(snapshots(leaves), &(&1.records == []))
    assert Enum.all?(lifecycle(leaves), &(&1.interest_generation == 1))
    {back, enters} = drive_until(ctx, 32767, Session.EntityEnter)
    [left, right] = Enum.sort_by(back.characters, & &1.entity_id)
    assert elem(left.state.position, 0) - elem(right.state.position, 0) <= 30.0
    assert Enum.all?(lifecycle(enters), &(&1.interest_generation == 2))

    for event <- lifecycle(enters) do
      expected = if event.entity_id == a.entity_id, do: a, else: b
      assert event.entity_epoch == expected.entity_epoch
      assert {:ok, bytes} = Session.Codec.encode(event)
      assert {:ok, ^event} = Session.Codec.decode(bytes)
    end

    for snapshot <- snapshots(enters) do
      assert {:ok, bytes} = Movement.Codec.encode(snapshot)
      assert {:ok, ^snapshot} = Movement.Codec.decode(bytes)
      assert Enum.all?(snapshot.records, &(&1.interest_generation == 2))
    end

    IO.puts(
      "A1_DISTANCE_TRACE " <>
        inspect(%{leave: leaves, return: enters, final: back.aoi}, limit: :infinity)
    )
  end

  test "leave, reconnect origin and Gate DOWN clean relations without old identity removing new entity",
       ctx do
    {_a, old} = active_pair(ctx)
    Scene.leave(ctx.scene, old.identity)
    info = Scene.observe(ctx.scene)
    assert info.character_count == 1
    events = outputs()

    assert [%Session.EntityLeave{entity_id: 10, entity_epoch: epoch, interest_generation: 1}] =
             lifecycle(events)

    assert epoch == old.entity_epoch
    assert [%{visible: []}] = info.aoi

    parent = self()
    gate = spawn(fn -> relay(parent) end)
    on_exit(fn -> if Process.alive?(gate), do: send(gate, :stop) end)
    fresh = join(ctx, 3, 10, gate)
    assert fresh.entity_epoch > old.entity_epoch
    Scene.leave(ctx.scene, old.identity)
    assert Scene.observe(ctx.scene).character_count == 2
    ready(ctx, 3)
    advance(ctx, 35)
    assert_receive {:mmo_reliable, _, 1, %Session.InputStart{origin_tick: origin}}
    assert origin == 65
    advance(ctx, 64)
    joining = outputs()
    assert lifecycle(joining) == []
    assert Enum.all?(snapshots(joining), &(&1.identity == identity(1) and &1.records == []))
    advance(ctx, 66)

    assert_receive {:mmo_reliable, _, 1,
                    %Session.EntityEnter{identity: observer, entity_id: 10} = enter}

    assert observer == identity(1)
    assert enter.entity_epoch == fresh.entity_epoch and enter.interest_generation == 2

    assert_receive {:mmo_reliable, _, 1,
                    %Session.EntityEnter{
                      identity: fresh_identity,
                      entity_id: 20,
                      interest_generation: 1
                    }}

    assert fresh_identity == fresh.identity
    outputs()

    send(gate, :stop)
    info = await(ctx.scene, &(&1.character_count == 1))
    assert [%{identity: observer, visible: []}] = info.aoi
    assert observer == identity(1)

    assert_receive {:mmo_reliable, _, 1,
                    %Session.EntityLeave{
                      entity_id: 10,
                      entity_epoch: new_epoch,
                      interest_generation: 2
                    } = down}

    assert new_epoch == fresh.entity_epoch
    Scene.leave(ctx.scene, identity(1))
    info = Scene.observe(ctx.scene)
    assert info.character_count == 0 and info.aoi == []

    IO.puts(
      "A1_RECONNECT_TRACE " <>
        inspect(
          %{old: old.entity_epoch, new: new_epoch, enter: enter, down: down, final: info.aoi},
          limit: :infinity
        )
    )
  end

  defp relay(parent) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, message)
        relay(parent)
    end
  end

  test "snapshots contain step-after absolute state and collision revision from the same Scene tick",
       ctx do
    active_pair(ctx)
    chunk = Enum.find(ctx.snapshot.chunks, &(&1.coord == {2, 31, 2}))

    delta = %Voxel.CanonicalDelta{
      transaction_seq: 1,
      transaction: %{seq: 1, entries: [], coarse: []},
      chunks: [%{chunk | cells: :binary.copy(<<0>>, 4096)}]
    }

    GenServer.call(ctx.source, {:delta, delta})
    await(ctx.scene, &(&1.queue_length == 1))
    info = advance(ctx, 36)
    events = outputs()
    assert length(snapshots(events)) == 2

    for snapshot <- snapshots(events) do
      assert snapshot.server_tick == 36
      assert [record] = snapshot.records
      assert record.collision_revision == 2
      assert record.state == Enum.find(info.characters, &(&1.entity_id == record.entity_id)).state
      assert elem(record.state.velocity, 1) < 0.0
      index = Enum.find_index(events, &match?({:mmo_datagram, _, ^snapshot}, &1))

      assert Enum.any?(Enum.take(events, index), fn
               {:mmo_reliable, observer, 2,
                %Voxel.CollisionApplied{collision_revision: 2, apply_tick: 34}} ->
                 observer == snapshot.identity

               _ ->
                 false
             end)
    end

    IO.puts(
      "A1_STEP_AFTER_TRACE " <> inspect(%{tick: info.tick, events: events}, limit: :infinity)
    )
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

  defp position(entity, point), do: %{entity | state: %{entity.state | position: point}}

  test "canonical XYZ distance, exact thresholds, symmetry and negative grid boundaries" do
    a = entity(10, {-0.5, 500.0, -0.5})

    for point <- [{-0.5, 540.0, -0.5}, {29.501, 500.0, -0.5}, {-0.5, 500.0, 29.501}] do
      {_, [], snapshots} = AOI.update(AOI.new(), [a, entity(20, point)], 3, 7)
      assert Enum.all?(snapshots, &(&1.records == []))
    end

    for point <- [{29.5, 500.0, -0.5}, {-0.5, 530.0, -0.5}, {-0.5, 500.0, 29.5}] do
      b = entity(20, point)
      {aoi, enters, snapshots} = AOI.update(AOI.new(), [b, a], 3, 7)
      assert length(enters) == 2
      assert Enum.all?(enters, &is_struct(&1, Session.EntityEnter))
      assert Enum.map(snapshots, &Enum.map(&1.records, fn r -> r.entity_id end)) == [[20], [10]]
      assert Enum.all?(snapshots, &Enum.all?(&1.records, fn r -> r.collision_revision == 7 end))
      assert length(AOI.observe(aoi)) == 2
    end

    b = entity(20, {29.5, 500.0, -0.5})
    {aoi, _, _} = AOI.update(AOI.new(), [a, b], 3, 1)
    b = position(b, {33.5, 500.0, -0.5})
    {aoi, [], retained} = AOI.update(aoi, [a, b], 6, 1)
    assert Enum.all?(retained, &(length(&1.records) == 1))
    b = position(b, {33.501, 500.0, -0.5})
    {aoi, leaves, empty} = AOI.update(aoi, [a, b], 9, 1)
    assert length(leaves) == 2
    assert Enum.all?(leaves, &is_struct(&1, Session.EntityLeave))
    assert Enum.all?(empty, &(&1.records == []))
    {aoi, [], _} = AOI.update(aoi, [a, position(b, {31.5, 500.0, -0.5})], 12, 1)
    {_, enters, _} = AOI.update(aoi, [a, position(b, {29.5, 500.0, -0.5})], 15, 1)
    assert Enum.all?(enters, &(&1.entity_epoch == 1 and &1.interest_generation == 2))
  end

  test "observer-local generations follow distinct histories and snapshots stay entity-sorted" do
    a = entity(10, {0.0, 500.0, 0.0})
    b = entity(20, {1.0, 500.0, 0.0})
    c = entity(30, {100.0, 500.0, 0.0})
    {aoi, _, _} = AOI.update(AOI.new(), [c, b, a], 3, 1)
    c = position(c, {2.0, 500.0, 0.0})
    {aoi, enters, snapshots} = AOI.update(aoi, [c, b, a], 6, 9)

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
    {aoi, enters, snapshots} = AOI.update(aoi, [c, b, a], 9, 9)
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
