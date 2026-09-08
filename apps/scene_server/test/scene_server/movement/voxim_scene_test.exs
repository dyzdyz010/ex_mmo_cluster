defmodule SceneServer.Movement.VoximSceneTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.InputSlots
  alias MmoContracts.Movement.{Codec, InputBatch, InputFrame}

  @fixtures Path.expand("../../../../../../Voxim/Docs/M1/fixtures/movement-wire", __DIR__)
  defp packet(name) do
    {:ok, packet} = File.read!(Path.join(@fixtures, "elixir_#{name}.bin")) |> Codec.decode()
    packet
  end

  test "C1 declarative scenarios execute a continuous prefix only at the assigned tick" do
    scenarios = File.read!(Path.join(@fixtures, "input-slot-scenarios.json")) |> Jason.decode!()
    identity = packet("input_gap").identity

    for scenario <- scenarios["scenarios"] do
      Enum.reduce(scenario["events"], InputSlots.new(identity, 100), fn event, slots ->
        next =
          case event["op"] do
            "receive" ->
              {next, _} = InputSlots.receive_batch(slots, packet(event["packet"]))
              next

            "tick" ->
              {next, frame} = InputSlots.take(slots, event["server_tick"])

              if Map.has_key?(event, "expected_jump_pressed"),
                do: assert(frame.jump_pressed == event["expected_jump_pressed"])

              assert next.substituted_through_seq == event["expected_substituted_through_seq"]
              next
          end

        assert next.processed_input_seq == event["expected_processed_input_seq"], scenario["name"]
        next
      end)
    end
  end

  test "flood, duplicate jump, future and late slots cannot execute extra steps" do
    identity = packet("input_gap").identity
    one = %InputFrame{input_seq: 1, axis_x: 32767, axis_z: 0, yaw: 100, jump_pressed: 1}
    batch = %InputBatch{identity: identity, frames: [one]}

    slots =
      Enum.reduce(1..1000, InputSlots.new(identity, 100), fn _, slots ->
        {next, _} = InputSlots.receive_batch(slots, batch)
        next
      end)

    assert slots.processed_input_seq == 0
    assert map_size(slots.pending) == 1
    assert {^slots, :waiting} = InputSlots.take(slots, 99)
    {slots, first} = InputSlots.take(slots, 100)
    assert first.jump_pressed == 1
    assert {^slots, :waiting} = InputSlots.take(slots, 100)
    {slots, :duplicate} = InputSlots.receive_batch(slots, batch)
    for tick <- 101..124 do
      assert {^slots, :waiting} = InputSlots.take(slots, tick)
    end
    assert slots.processed_input_seq == 1
    {slots, :accepted} = InputSlots.receive_batch(slots, %{batch | frames: [%{one | input_seq: 2, jump_pressed: 0, axis_x: 0}]})
    {slots, release} = InputSlots.take(slots, 124)
    assert release.input_seq == 2 and release.axis_x == 0 and release.jump_pressed == 0
    assert {^slots, :waiting} = InputSlots.take(slots, 124)
  end

  test "1 3 2 ordering retains first value and conflicting duplicate is rejected" do
    batch = packet("input_gap")
    {slots, :accepted} = InputSlots.receive_batch(InputSlots.new(batch.identity, 100), batch)
    {slots, :accepted} = InputSlots.receive_batch(slots, packet("input_seq2"))
    conflict = %{batch | frames: [%{hd(batch.frames) | yaw: 42}]}
    assert {^slots, :conflict} = InputSlots.receive_batch(slots, conflict)

    final =
      Enum.reduce(100..102, slots, fn tick, s ->
        {s, frame} = InputSlots.take(s, tick)
        assert frame.input_seq == tick - 99
        assert s.substituted_through_seq == 0
        s
      end)

    assert final.processed_input_seq == 3
  end


end

defmodule SceneServer.Movement.VoximSceneRuntimeTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.Scene
  alias MmoContracts.{Session, Movement, Voxel}

  defmodule Clock do
    def now(ref), do: :atomics.get(ref, 1)
    def schedule(_ref, _pid, _delay), do: :ok
  end

  defmodule Sink do
    def reliable(pid, identity, purpose, message),
      do: send(pid, {:reliable, identity, purpose, message})

    def datagram(pid, identity, message), do: send(pid, {:datagram, identity, message})
    def close(pid, identity, reason), do: send(pid, {:closed, identity, reason})
  end

  defmodule NativeProbe do
    alias SceneServer.Native.VoximMovement, as: Native

    def new_world(),
      do: {Native.new_world(), Application.fetch_env!(:scene_server, :s1_native_observer)}

    def world_stats({world, _observer}), do: Native.world_stats(world)

    def set_chunks({world, observer}, operations) do
      if length(operations) == 1 do
        send(observer, {:install_wait, self()})

        receive do
          :install_continue -> :ok
        end
      end

      Native.set_chunks(world, operations)
    end

    def step_characters({world, observer}, profile, characters) do
      states = Native.step_characters(world, profile, characters)
      send(observer, {:native_stepped, Enum.map(characters, &elem(&1, 0))})

      case Application.get_env(:scene_server, :s1_native_candidate) do
        nil -> states
        candidate -> Enum.map(states, fn {id, _} -> {id, candidate} end)
      end
    end

    def query_bounds(profile, state), do: Native.query_bounds(profile, state)

    def find_spawn({world, observer}, profile, probe, min_y) do
      send(observer, :spawn_called)
      Native.find_spawn(world, profile, probe, min_y)
    end
  end

  defmodule Source do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def canonical_snapshot_and_subscribe(pid, box, subscriber, ref),
      do: GenServer.call(pid, {:snapshot, box, subscriber, ref})

    def handle_call({:snapshot, _, _, _}, _, %{error: true} = state) do
      send(state.owner, :snapshot_failed)
      {:reply, {:error, :canonical_incomplete}, state}
    end

    def handle_call({:snapshot, _, subscriber, ref}, _, %{hold: true} = state) do
      send(state.owner, {:snapshot_held, ref})
      {:reply, :ok, Map.update(state, :held, [{subscriber, ref}], &(&1 ++ [{subscriber, ref}]))}
    end

    def handle_call(:release, _, state) do
      for {subscriber, ref} <- state.held do
        send(subscriber, {:canonical_snapshot, ref, state.snapshot})
        send(state.owner, {:snapshot_sent, ref})
      end

      {:reply, :ok, %{state | hold: false}}
    end

    def handle_call({:snapshot, _, subscriber, ref}, _, state) do
      send(subscriber, {:canonical_snapshot, ref, state.snapshot})
      send(state.owner, {:snapshot_sent, ref})
      {:reply, :ok, Map.put(state, :subscriber, subscriber)}
    end

    def handle_call({:delta, delta}, _, state) do
      send(state.subscriber, {:canonical_delta, delta})

      {:reply, :ok,
       %{state | snapshot: %{state.snapshot | transaction_seq: delta.transaction_seq}}}
    end
  end

  defp identity(epoch \\ 1),
    do: %Session.Identity{session_epoch: epoch, scene_id: 1, scene_epoch: 7}

  defp config do
    path = Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)

    profile =
      File.read!(path) |> Jason.decode!() |> Map.fetch!("profile") |> Map.put("fixed_hz", 60)

    %{
      "schema" => "voxim-m1-demo-v1",
      "l0_min" => [-1, 7, -1],
      "l0_max_exclusive" => [1, 9, 1],
      "travel_min_m" => [-48.0, 464.0, -48.0],
      "travel_max_exclusive_m" => [48.0, 560.0, 48.0],
      "spawn_probes_m" => [[40.0, 558.0, 40.0], [42.0, 558.0, 40.0]],
      "spawn_min_y_m" => 464.0,
      "profile" => profile
    }
  end

  defp snapshot do
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

    %Voxel.CanonicalSnapshot{
      content_version: 9,
      transaction_seq: 0,
      l0_min: {-1, 7, -1},
      l0_max_exclusive: {1, 9, 1},
      chunks: chunks,
      regions: for(x <- -1..0, y <- 7..8, z <- -1..0, do: {{x, y, z}, <<>>})
    }
  end

  setup do
    clock = :atomics.new(1, signed: true)
    source = start_supervised!({Source, %{snapshot: snapshot(), owner: self()}})

    scene =
      start_supervised!(
        {Scene,
         [
           scene_id: 1,
           scene_epoch: 7,
           world_ref: source,
           config: config(),
           clock: {Clock, clock},
           sink: Sink,
           world_api: Source
         ]}
      )

    assert_receive {:snapshot_sent, _}, 2000
    await(scene, & &1.initialized)
    %{scene: scene, source: source, clock: clock}
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

  defp advance(%{scene: scene, clock: clock}, tick) do
    :atomics.put(clock, 1, div(tick * 1_000_000 + 59, 60))
    send(scene, :tick)
    await(scene, &(&1.tick == tick))
  end

  defp join(ctx, epoch \\ 1, cid \\ 20) do
    :ok = Scene.join(ctx.scene, identity(epoch), %{id: cid}, self())
    assert_receive {:snapshot_sent, _}, 1000
    await(ctx.scene, &(&1.queue_length > 0))
    advance(ctx, Scene.observe(ctx.scene).tick + 1)
    assert {:reliable, _, :control, %Session.SessionStart{} = start} = next_reliable()
    assert {:reliable, _, :voxel, %Voxel.CanonicalBootstrap{}} = next_reliable()
    assert {:reliable, _, :voxel, %Voxel.TimelineFence{}} = next_reliable()
    start
  end

  defp next_reliable do
    assert_receive {:reliable, _, _, _} = output, 1000
    output
  end

  defp next_log(seq) do
    assert {:reliable, _, :voxel, {:voxel_log_transaction_payload, bytes}} = next_reliable()
    assert {:ok, %{seq: ^seq}} = Voxel.Codec.decode_transaction(bytes)
  end

  @tag :input_recovery
  test "late real commands catch up once using the collision at each simulation tick", ctx do
    start = join(ctx)
    Scene.time_probe(ctx.scene, identity(), %Session.TimeProbe{request_id: 7, client_send_us: 44})
    Scene.ready(ctx.scene, identity(), 0, 1)
    advance(ctx, 2)
    assert_receive {:reliable, _, :control, %Session.InputStart{origin_tick: 32}}
    at31 = advance(ctx, 31)
    anchor = hd(at31.characters).state
    commands = for seq <- 1..24 do
      %Movement.InputFrame{input_seq: seq,
        axis_x: cond do seq < 9 -> 32767; seq < 17 -> -32767; true -> 0 end,
        axis_z: 0, yaw: 100, jump_pressed: if(seq == 12, do: 1, else: 0)}
    end
    advance(ctx, 43)
    removed = snapshot().chunks |> Enum.filter(&(&1.coord == {2, 31, 2}))
      |> Enum.map(&%{&1 | cells: :binary.copy(<<0>>, 4096)})
    GenServer.call(ctx.source, {:delta, %Voxel.CanonicalDelta{transaction_seq: 1,
      transaction: %{seq: 1, entries: [], coarse: []}, chunks: removed}})
    await(ctx.scene, &(&1.queue_length == 1))
    advance(ctx, 44)
    stalled = advance(ctx, 55)
    assert hd(stalled.characters).processed_input_seq == 0
    assert hd(stalled.characters).simulation_tick == 31
    assert hd(stalled.characters).state == anchor
    assert stalled.physics_steps == at31.physics_steps
    for frames <- commands |> Enum.chunk_every(6) |> Enum.reverse() do
      Scene.input(ctx.scene, identity(), %Movement.InputBatch{identity: identity(), frames: frames})
    end
    recovered = advance(ctx, 56)
    assert hd(recovered.characters).processed_input_seq == 24
    assert hd(recovered.characters).simulation_tick == 55
    assert recovered.physics_steps - stalled.physics_steps == 24
    assert recovered.tick == 56
    # 独立按原时段推进真实 P1，R2 只在第13条命令开始生效。
    native = SceneServer.Native.VoximMovement
    world = native.new_world()
    :ok = native.set_chunks(world, SceneServer.Movement.CollisionUpdates.operations(snapshot().chunks))
    <<bytes::binary-size(120), 60::16>> = Session.Codec.encode_profile(start.profile)
    profile = for(<<v::float-64 <- bytes>>, do: v) |> List.to_tuple()
    expected = Enum.reduce(commands, {anchor.position, anchor.velocity, anchor.grounded}, fn f, state ->
      if f.input_seq == 13, do: native.set_chunks(world, SceneServer.Movement.CollisionUpdates.operations(removed))
      {x, z} = Movement.Codec.axes(f)
      [{20, next}] = native.step_characters(world, profile, [{20, state, {x, z, f.jump_pressed}}])
      next
    end)
    actual = hd(recovered.characters).state
    assert {actual.position, actual.velocity, actual.grounded} == expected
    for frames <- Enum.chunk_every(commands, 6) do
      Scene.input(ctx.scene, identity(), %Movement.InputBatch{identity: identity(), frames: frames})
    end
    duplicate = advance(ctx, 57)
    assert duplicate.physics_steps == recovered.physics_steps
    assert_receive {:datagram, _, %Movement.OwnerAck{server_tick: 57,
      simulation_tick: 55, processed_input_seq: 24, collision_revision: 2}}
    IO.puts("M1_SCENE_RECOVERY " <> inspect(%{delay_ms: 400, recovered: 24,
      world_tick: recovered.tick, simulation_tick: 55, collision_revision: 2, duplicate_steps: 0}))
  end

  test "joining falls after ordered edit; Ready anchors fresh state and origin gates ACK", ctx do
    start = join(ctx)

    removed =
      Enum.filter(snapshot().chunks, &(&1.coord == {2, 31, 2}))
      |> Enum.map(&%{&1 | cells: :binary.copy(<<0>>, 4096)})

    delta = %Voxel.CanonicalDelta{
      transaction_seq: 1,
      transaction: %{seq: 1, entries: [], coarse: []},
      chunks: removed
    }

    :ok = GenServer.call(ctx.source, {:delta, delta})
    await(ctx.scene, &(&1.queue_length == 1))
    advance(ctx, 10)
    refute_receive {:datagram, _, %Movement.OwnerAck{}}

    Scene.time_probe(ctx.scene, identity(), %Session.TimeProbe{request_id: 1, client_send_us: 100})

    Scene.ready(ctx.scene, identity(), 0, 1)
    advance(ctx, 11)
    assert_receive {:reliable, _, :control, %Session.InputStart{} = input_start}
    assert input_start.anchor_tick == 11 and input_start.origin_tick == 41
    assert elem(input_start.state.position, 1) < elem(start.state.position, 1)
    assert input_start.collision_revision == 2 and input_start.transaction_seq == 1
    Scene.ready(ctx.scene, identity(), 0, 1)
    advance(ctx, 40)
    refute_receive {:reliable, _, :control, %Session.InputStart{}}
    refute_receive {:datagram, _, %Movement.OwnerAck{}}
    advance(ctx, 42)
    assert_receive {:datagram, _, %Movement.OwnerAck{server_tick: 42, processed_input_seq: 0, simulation_tick: 40}}
    assert Scene.observe(ctx.scene).physics_steps == 39
  end

  test "two immutable versions get separate ticks; marker fences the join prefix", ctx do
    join(ctx)
    chunk = Enum.find(snapshot().chunks, &(&1.coord == {2, 31, 2}))

    for {seq, cells} <- [{1, :binary.copy(<<0>>, 4096)}, {2, chunk.cells}] do
      GenServer.call(
        ctx.source,
        {:delta,
         %Voxel.CanonicalDelta{
           transaction_seq: seq,
           transaction: %{seq: seq, entries: [], coarse: []},
           chunks: [%{chunk | cells: cells}]
         }}
      )
    end

    Scene.join(ctx.scene, identity(2), %{id: 10}, self())
    assert_receive {:snapshot_sent, _}, 1000
    await(ctx.scene, &(&1.queue_length == 3))
    advance(ctx, 2)

    next_log(1)

    assert {:reliable, _, :voxel,
            %Voxel.CollisionApplied{
              transaction_seq: 1,
              apply_tick: 2,
              collision_revision: 2
            }} = next_reliable()

    refute_receive {:reliable, _, :control, %Session.SessionStart{}}
    advance(ctx, 3)

    next_log(2)

    assert {:reliable, _, :voxel,
            %Voxel.CollisionApplied{
              transaction_seq: 2,
              apply_tick: 3,
              collision_revision: 3
            }} = next_reliable()

    assert {:reliable, _, :control,
            %Session.SessionStart{
              server_tick: 3,
              baseline_transaction_seq: 2,
              collision_revision: 3
            }} = next_reliable()

    assert {:reliable, _, :voxel, %Voxel.CanonicalBootstrap{transaction_seq: 2}} = next_reliable()

    assert {:reliable, _, :voxel, %Voxel.TimelineFence{server_tick: 3, transaction_seq: 2}} =
             next_reliable()

    assert Scene.observe(ctx.scene).physics_steps == 2
  end

  test "old epochs cannot remove new character; duplicate cid and invalid Ready close exactly their identity",
       ctx do
    join(ctx)
    Scene.join(ctx.scene, identity(2), %{id: 20}, self())
    assert_receive {:closed, _, 2}
    Scene.leave(ctx.scene, identity())
    await(ctx.scene, &(&1.character_count == 0))
    start = join(ctx, 3)
    assert start.entity_epoch > 1
    Scene.leave(ctx.scene, identity())
    Scene.ready(ctx.scene, identity(), 0, 1)
    assert Scene.observe(ctx.scene).character_count == 1
    Scene.ready(ctx.scene, identity(3), 88, 1)
    assert_receive {:closed, _, 8}
    assert Scene.observe(ctx.scene).character_count == 0
  end

  test "actual fake clock writer consumes C1 gapped frames and flood only on due slots", ctx do
    join(ctx)
    Scene.time_probe(ctx.scene, identity(), %Session.TimeProbe{request_id: 7, client_send_us: 44})
    Scene.ready(ctx.scene, identity(), 0, 1)
    advance(ctx, 2)
    assert_receive {:reliable, _, :control, %Session.InputStart{origin_tick: 32}}

    path =
      Path.expand(
        "../../../../../../Voxim/Docs/M1/fixtures/movement-wire/elixir_input_gap.bin",
        __DIR__
      )

    {:ok, batch} = File.read!(path) |> Movement.Codec.decode()
    batch = %{batch | identity: identity()}
    for _ <- 1..1000, do: Scene.input(ctx.scene, identity(), batch)
    Scene.input(ctx.scene, identity(99), %{batch | identity: identity(99)})
    Scene.input(ctx.scene, identity(), %{batch | frames: [%{hd(batch.frames) | input_seq: 33}]})
    info = Scene.observe(ctx.scene)
    assert info.tick == 2 and info.physics_steps == 1
    assert info.old_identity == 1 and info.rejected_inputs == 0
    advance(ctx, 31)
    refute_receive {:datagram, _, %Movement.OwnerAck{}}
    advance(ctx, 32)
    assert hd(Scene.observe(ctx.scene).characters).processed_input_seq == 1
    advance(ctx, 33)

    assert_receive {:datagram, _,
                    %Movement.OwnerAck{
                      server_tick: 33,
                      simulation_tick: 32,
                      processed_input_seq: 1,
                      substituted_through_seq: 0
                    }}

    Scene.input(ctx.scene, identity(), %{
      batch
      | frames: [%{hd(batch.frames) | input_seq: 2, jump_pressed: 1}]
    })

    advance(ctx, 34)
    info = Scene.observe(ctx.scene)
    assert hd(info.characters).processed_input_seq == 3 and info.physics_steps == 33
    assert info.substitutions == 0
    :atomics.put(ctx.clock, 1, 999_999)
    send(ctx.scene, :tick)
    info = await(ctx.scene, &(&1.tick == 59))
    assert info.physics_steps == 33
    :atomics.put(ctx.clock, 1, 1_000_000)
    send(ctx.scene, :tick)
    assert await(ctx.scene, &(&1.tick == 60)).physics_steps == 33
  end

  test "Ready waits for TimeProbe and Gate DOWN frees its slot", ctx do
    parent = self()

    gate =
      spawn(fn ->
        receive do
          {:join, scene} -> Scene.join(scene, identity(), %{id: 77}, self())
        end

        send(parent, :gate_joined)

        receive do
          :finish -> :ok
        end
      end)

    send(gate, {:join, ctx.scene})
    assert_receive :gate_joined
    assert_receive {:snapshot_sent, _}
    await(ctx.scene, &(&1.queue_length == 1))
    advance(ctx, 1)
    Scene.ready(ctx.scene, identity(), 0, 1)
    advance(ctx, 10)
    assert hd(Scene.observe(ctx.scene).characters).origin_tick == nil
    send(gate, :finish)
    await(ctx.scene, &(&1.character_count == 0))
    assert join(ctx, 2).entity_id == 20
  end

  test "joining exits finite travel domain explicitly without committing or clamping outside state",
       ctx do
    join(ctx)
    chunk = Enum.find(snapshot().chunks, &(&1.coord == {2, 31, 2}))

    GenServer.call(
      ctx.source,
      {:delta,
       %Voxel.CanonicalDelta{
         transaction_seq: 1,
         transaction: %{seq: 1, entries: [], coarse: []},
         chunks: [%{chunk | cells: :binary.copy(<<0>>, 4096)}]
       }}
    )

    await(ctx.scene, &(&1.queue_length == 1))
    advance(ctx, 240)
    assert_receive {:closed, _, 4}
    assert Scene.observe(ctx.scene).character_count == 0
    refute_receive {:datagram, _, %Movement.OwnerAck{}}
  end

  test "World loss ends all characters with canonical_incomplete and stops physics", ctx do
    join(ctx)
    stop_supervised!(Source)
    assert_receive {:closed, _, 5}
    info = await(ctx.scene, &(&1.failure == 5))
    :atomics.put(ctx.clock, 1, 10_000_000)
    send(ctx.scene, :tick)
    assert Scene.observe(ctx.scene).physics_steps == info.physics_steps
  end

  test "spawn query is authorized against B before entering the kernel", ctx do
    Application.put_env(:scene_server, :s1_native_observer, self())
    on_exit(fn -> Application.delete_env(:scene_server, :s1_native_observer) end)
    bad = put_in(config(), ["profile", "speed"], 10_000.0)

    scene =
      start_supervised!(
        Supervisor.child_spec(
          {Scene,
           [
             scene_id: 1,
             scene_epoch: 7,
             world_ref: ctx.source,
             config: bad,
             clock: {Clock, ctx.clock},
             sink: Sink,
             world_api: Source,
             native: NativeProbe
           ]},
          id: :query_scene
        )
      )

    assert_receive {:snapshot_sent, _}
    await(scene, & &1.initialized)
    Scene.join(scene, identity(), %{id: 10}, self())
    assert_receive {:snapshot_sent, _}
    await(scene, &(&1.queue_length == 1))
    advance(%{ctx | scene: scene}, 1)
    assert_receive {:closed, _, 4}
    refute_receive :spawn_called
  end

  test "World commits during a blocked install and both immutable revisions serve their own tick",
       ctx do
    Application.put_env(:scene_server, :s1_native_observer, self())
    on_exit(fn -> Application.delete_env(:scene_server, :s1_native_observer) end)

    scene =
      start_supervised!(
        Supervisor.child_spec(
          {Scene,
           [
             scene_id: 1,
             scene_epoch: 7,
             world_ref: ctx.source,
             config: config(),
             clock: {Clock, ctx.clock},
             sink: Sink,
             world_api: Source,
             native: NativeProbe
           ]},
          id: :blocked_scene
        )
      )

    assert_receive {:snapshot_sent, _}
    await(scene, & &1.initialized)
    join(%{ctx | scene: scene})
    assert_receive :spawn_called
    chunk = Enum.find(snapshot().chunks, &(&1.coord == {2, 31, 2}))
    removed = %{chunk | cells: :binary.copy(<<0>>, 4096)}

    delta = %Voxel.CanonicalDelta{
      transaction_seq: 1,
      transaction: %{seq: 1, entries: [], coarse: []},
      chunks: [removed]
    }

    GenServer.call(ctx.source, {:delta, delta})
    await(scene, &(&1.queue_length == 1))
    :atomics.put(ctx.clock, 1, 33_334)
    send(scene, :tick)
    assert_receive {:install_wait, ^scene}

    assert :ok =
             GenServer.call(
               ctx.source,
               {:delta,
                %{
                  delta
                  | transaction_seq: 2,
                    transaction: %{seq: 2, entries: [], coarse: []},
                    chunks: [chunk]
                }}
             )

    send(scene, :install_continue)
    await(scene, &(&1.tick == 2))

    next_log(1)

    assert {:reliable, _, :voxel, %Voxel.CollisionApplied{apply_tick: 2, collision_revision: 2}} =
             next_reliable()

    refute_receive {:reliable, _, :voxel, %Voxel.CollisionApplied{collision_revision: 3}}
    :atomics.put(ctx.clock, 1, 50_000)
    send(scene, :tick)
    assert_receive {:install_wait, ^scene}
    send(scene, :install_continue)
    await(scene, &(&1.tick == 3))

    next_log(2)

    assert {:reliable, _, :voxel, %Voxel.CollisionApplied{apply_tick: 3, collision_revision: 3}} =
             next_reliable()
  end

  test "all XYZ sides reject outside D candidates and B queries before another step", ctx do
    Application.put_env(:scene_server, :s1_native_observer, self())

    on_exit(fn ->
      Application.delete_env(:scene_server, :s1_native_observer)
      Application.delete_env(:scene_server, :s1_native_candidate)
    end)

    for mode <- [:center, :query],
        {axis, min, max} <- [{0, -48.0, 48.0}, {1, 464.0, 560.0}, {2, -48.0, 48.0}],
        side <- [:min, :max] do
      :atomics.put(ctx.clock, 1, 0)

      scene =
        start_supervised!(
          Supervisor.child_spec(
            {Scene,
             [
               scene_id: 1,
               scene_epoch: 7,
               world_ref: ctx.source,
               config: config(),
               clock: {Clock, ctx.clock},
               sink: Sink,
               world_api: Source,
               native: NativeProbe
             ]},
            id: :domain_scene
          )
        )

      assert_receive {:snapshot_sent, _}
      await(scene, & &1.initialized)
      join(%{ctx | scene: scene})
      assert_receive :spawn_called

      coordinate =
        case {mode, side} do
          {:center, :min} -> min - 0.001
          {:center, :max} -> max
          {:query, :min} -> min + 0.1
          {:query, :max} -> max - 0.1
        end

      position = put_elem({0.0, 512.0, 0.0}, axis, coordinate)

      velocity =
        if mode == :query, do: put_elem({0.0, 0.0, 0.0}, axis, 2000.0), else: {0.0, 0.0, 0.0}

      Application.put_env(:scene_server, :s1_native_candidate, {position, velocity, 0})
      advance(%{ctx | scene: scene}, 2)
      assert_receive {:native_stepped, [20]}
      Application.delete_env(:scene_server, :s1_native_candidate)

      if mode == :query do
        assert Scene.observe(scene).character_count == 1
        advance(%{ctx | scene: scene}, 3)
        refute_receive {:native_stepped, [20]}
      end

      assert_receive {:closed, _, 4}
      assert Scene.observe(scene).character_count == 0
      refute_receive {:datagram, _, %Movement.OwnerAck{}}
      stop_supervised!(:domain_scene)
    end
  end

  test "same-blocking transactions advance canonical prefix but stop at join marker", ctx do
    join(ctx)

    for seq <- [1, 2] do
      GenServer.call(
        ctx.source,
        {:delta,
         %Voxel.CanonicalDelta{
           transaction_seq: seq,
           transaction: %{seq: seq, entries: [], coarse: []},
           chunks: []
         }}
      )
    end

    Scene.join(ctx.scene, identity(2), %{id: 10}, self())
    assert_receive {:snapshot_sent, _}

    GenServer.call(
      ctx.source,
      {:delta,
       %Voxel.CanonicalDelta{
         transaction_seq: 3,
         transaction: %{seq: 3, entries: [], coarse: []},
         chunks: []
       }}
    )

    await(ctx.scene, &(&1.queue_length == 4))
    advance(ctx, 2)

    next_log(1)
    next_log(2)

    assert {:reliable, _, :control,
            %Session.SessionStart{baseline_transaction_seq: 2, collision_revision: 1}} =
             next_reliable()

    assert {:reliable, _, :voxel, %Voxel.CanonicalBootstrap{transaction_seq: 2}} = next_reliable()
    assert {:reliable, _, :voxel, %Voxel.TimelineFence{transaction_seq: 2}} = next_reliable()

    assert Scene.observe(ctx.scene).transaction_seq == 2
    refute_receive {:reliable, _, :voxel, %Voxel.CollisionApplied{}}
    advance(ctx, 3)
    next_log(3)
    next_log(3)
    assert Scene.observe(ctx.scene).transaction_seq == 3
    assert Scene.observe(ctx.scene).collision_revision == 1
  end

  test "incomplete initial canonical source cannot move or admit a join", ctx do
    source =
      start_supervised!(
        Supervisor.child_spec({Source, %{owner: self(), error: true}}, id: :missing_source)
      )

    scene =
      start_supervised!(
        Supervisor.child_spec(
          {Scene,
           [
             scene_id: 1,
             scene_epoch: 7,
             world_ref: source,
             config: config(),
             clock: {Clock, ctx.clock},
             sink: Sink,
             world_api: Source
           ]},
          id: :missing_scene
        )
      )

    assert_receive :snapshot_failed
    await(scene, &(&1.failure == 5))
    Scene.join(scene, identity(), %{id: 10}, self())
    assert_receive {:closed, _, 5}

    send(
      scene,
      {:canonical_delta,
       %Voxel.CanonicalDelta{
         transaction_seq: 1,
         transaction: %{seq: 1, entries: [], coarse: []},
         chunks: []
       }}
    )

    info = Scene.observe(scene)
    assert not info.initialized and info.physics_steps == 0 and info.queue_length == 0
    refute_receive {:reliable, _, :control, %Session.SessionStart{}}
  end

  test "both probes without support close spawn_unavailable without a fallback", ctx do
    air = snapshot()
    air = %{air | chunks: Enum.map(air.chunks, &%{&1 | cells: :binary.copy(<<0>>, 4096)})}

    source =
      start_supervised!(
        Supervisor.child_spec({Source, %{owner: self(), snapshot: air}}, id: :air_source)
      )

    scene =
      start_supervised!(
        Supervisor.child_spec(
          {Scene,
           [
             scene_id: 1,
             scene_epoch: 7,
             world_ref: source,
             config: config(),
             clock: {Clock, ctx.clock},
             sink: Sink,
             world_api: Source
           ]},
          id: :air_scene
        )
      )

    assert_receive {:snapshot_sent, _}
    await(scene, & &1.initialized)
    for epoch <- [1, 2], do: Scene.join(scene, identity(epoch), %{id: epoch}, self())
    assert_receive {:snapshot_sent, _}
    assert_receive {:snapshot_sent, _}
    await(scene, &(&1.queue_length == 2))
    advance(%{ctx | scene: scene}, 2)
    assert_receive {:closed, _, 10}
    assert_receive {:closed, _, 10}
    assert Scene.observe(scene).character_count == 0
    refute_receive {:reliable, _, :control, %Session.SessionStart{}}
  end

  test "explicit exported JSON loader consumes profile values and never supplies missing defaults",
       _ctx do
    path =
      Path.join(System.tmp_dir!(), "voxim_s1_config_#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm!(path) end)
    File.write!(path, Jason.encode!(config()))
    parsed = Scene.load_config!(path)
    assert %Session.Profile{fixed_hz: 60} = parsed.profile

    assert Session.Codec.profile_id(
             parsed.profile,
             MmoContracts.VoxelMaterialCatalog.blocking_hash()
           ) ==
             Base.decode16!("83DC05376B0D77AA8D985969E33872CD1ACC13C16B568460B76D0F29C05ADC71")

    assert parsed.l0 == {{-1, 7, -1}, {1, 9, 1}} and tuple_size(parsed.profile_tuple) == 15
    File.write!(path, Jason.encode!(Map.delete(config(), "profile")))
    assert_raise Protocol.UndefinedError, fn -> Scene.load_config!(path) end
  end

  test "admission during initial source preparation cannot establish a second baseline subscription",
       _ctx do
    source =
      start_supervised!(
        Supervisor.child_spec({Source, %{snapshot: snapshot(), owner: self(), hold: true}},
          id: :held_source
        )
      )

    clock = :atomics.new(1, signed: true)

    scene =
      start_supervised!(
        Supervisor.child_spec(
          {Scene,
           [
             scene_id: 1,
             scene_epoch: 7,
             world_ref: source,
             config: config(),
             clock: {Clock, clock},
             sink: Sink,
             world_api: Source
           ]},
          id: :held_scene
        )
      )

    assert_receive {:snapshot_held, _}
    Scene.join(scene, identity(), %{id: 1}, self())
    refute_receive {:snapshot_held, _}
    assert Scene.observe(scene).physics_steps == 0
    :atomics.put(clock, 1, 100_000)
    Scene.time_probe(scene, identity(), %Session.TimeProbe{request_id: 1, client_send_us: 10})
    assert_receive {:reliable, _, :control, %Session.TimeReply{} = before_start}
    GenServer.call(source, :release)
    assert_receive {:snapshot_sent, _}
    assert_receive {:snapshot_sent, _}
    await(scene, &(&1.initialized and &1.queue_length == 1))
    Scene.time_probe(scene, identity(), %Session.TimeProbe{request_id: 2, client_send_us: 11})
    assert_receive {:reliable, _, :control, %Session.TimeReply{} = after_start}
    assert after_start.server_send_us >= before_start.server_send_us
    :atomics.put(clock, 1, 116_667)
    send(scene, :tick)
    await(scene, &(&1.tick == 1))
    assert_receive {:reliable, _, :control, %Session.SessionStart{server_tick: 1}}
  end

  @tag timeout: 120_000
  test "actual saved R6 World artifact installs 512 cores, spawns both probes and steps with P1 NIF",
       _ctx do
    fixture = Path.expand("../../../../../../Voxim/Docs/M1/runtime/S1/world-fixture", __DIR__)
    root = Path.join(System.tmp_dir!(), "voxim_s1_world_#{System.unique_integer([:positive])}")
    File.cp_r!(fixture, root)

    on_exit(fn ->
      true =
        String.starts_with?(
          Path.expand(root),
          Path.expand(System.tmp_dir!()) <> "/voxim_s1_world_"
        )

      File.rm_rf!(root)
    end)

    world = start_supervised!({VoxelRegion.World, [root: root, name: :s1_actual_world]})
    request = make_ref()

    {snapshot_us, :ok} =
      :timer.tc(fn ->
        VoxelRegion.World.canonical_snapshot_and_subscribe(
          world,
          {{-1, 7, -1}, {1, 9, 1}},
          self(),
          request
        )
      end)

    assert_receive {:canonical_snapshot, ^request, snapshot}, 2000
    assert length(snapshot.chunks) == 512 and length(snapshot.regions) == 8
    assert Enum.sum(Enum.map(snapshot.chunks, &byte_size(&1.cells))) == 2_097_152
    assert snapshot.content_version == 0x256B33610344964F and snapshot.transaction_seq == 0

    for {coord, bytes} <- snapshot.regions do
      {:ok, payload} = Voxel.Payload.decode(bytes)

      assert payload.region == coord and payload.seq == 0 and
               payload.content_version == snapshot.content_version
    end

    clock = :atomics.new(1, signed: true)

    scene =
      start_supervised!(
        Supervisor.child_spec(
          {Scene,
           [
             scene_id: 1,
             scene_epoch: 7,
             world_ref: world,
             config: config(),
             clock: {Clock, clock},
             sink: Sink
           ]},
          id: :real_scene
        )
      )

    await(scene, & &1.initialized, 10_000)

    for {epoch, cid, tick} <- [{11, 20, 1}, {12, 10, 2}] do
      Scene.join(scene, identity(epoch), %{id: cid, position: {99999, 99999, 99999}}, self())
      await(scene, &(&1.queue_length == 1), 10_000)
      advance(%{scene: scene, clock: clock}, tick)
      assert_receive {:reliable, _, :control, %Session.SessionStart{} = start}, 2000
      assert start.state.grounded == 1 and start.content_version == 0x256B33610344964F
      assert elem(start.state.position, 0) == if(epoch == 11, do: 40.0, else: 42.0)
      IO.puts("S1_REAL_SPAWN " <> inspect(%{entity: cid, state: start.state, tick: tick}))

      Scene.time_probe(scene, identity(epoch), %Session.TimeProbe{
        request_id: epoch,
        client_send_us: 1
      })

      Scene.ready(scene, identity(epoch), 0, 1)
    end

    advance(%{scene: scene, clock: clock}, 32)
    assert Enum.all?(Scene.observe(scene).characters, &(&1.processed_input_seq == 0))
    for c <- Scene.observe(scene).characters do
      frames = for seq <- 1..(600 - c.origin_tick + 1), do:
        %Movement.InputFrame{input_seq: seq, axis_x: 0, axis_z: 0, yaw: 0, jump_pressed: 0}
      for batch <- Enum.chunk_every(frames, 6), do:
        Scene.input(scene, c.identity, %Movement.InputBatch{identity: c.identity, frames: batch})
    end
    advance(%{scene: scene, clock: clock}, 600)
    info = Scene.observe(scene)
    assert info.character_count == 2 and info.physics_steps == 1197
    assert Enum.map(info.characters, & &1.entity_id) == [10, 20]

    IO.puts(
      "S1_REAL_COST " <>
        inspect(%{
          snapshot_us: snapshot_us,
          region_bytes: Enum.sum(Enum.map(snapshot.regions, &byte_size(elem(&1, 1)))),
          build_us: info.build_us,
          step_us: info.step_us,
          tick_us: info.tick_us,
          max_tick_us: info.max_tick_us,
          physics_steps: info.physics_steps,
          mailbox_peak: info.mailbox_peak,
          overdue_ticks: info.overdue_ticks,
          characters: info.characters
        })
    )

    assert {:ok, 1} = VoxelRegion.World.apply_edit(world, {40, 500, 40}, 0)

    assert_receive {:canonical_delta,
                    %Voxel.CanonicalDelta{
                      transaction_seq: 1,
                      transaction: %{seq: 1, entries: [_], coarse: _}
                    }},
                   5000

    await(scene, &(&1.queue_length == 1), 10_000)
    advance(%{scene: scene, clock: clock}, 601)

    assert_receive {:reliable, _, :voxel,
                    %Voxel.CollisionApplied{transaction_seq: 1, apply_tick: 601}}
  end

  @tag timeout: 120_000
  test "cold Linux GeneratedStore produces the same actual canonical artifacts and legal Scene spawns",
       _ctx do
    root =
      Path.join(System.tmp_dir!(), "voxim_s1_generated_#{System.unique_integer([:positive])}")

    manifest =
      Path.expand("../../../../../../Voxim/Docs/R6/runtime/s4_worldgen_manifest.json", __DIR__)

    on_exit(fn ->
      true =
        String.starts_with?(
          Path.expand(root),
          Path.expand(System.tmp_dir!()) <> "/voxim_s1_generated_"
        )

      File.rm_rf!(root)
    end)

    world =
      start_supervised!(
        {VoxelRegion.World,
         [
           root: root,
           source: VoxelRegion.GeneratedStore,
           manifest_path: manifest,
           name: :s1_generated_world
         ]}
      )

    request = make_ref()

    {cold_us, :ok} =
      :timer.tc(fn ->
        VoxelRegion.World.canonical_snapshot_and_subscribe(
          world,
          {{-1, 7, -1}, {1, 9, 1}},
          self(),
          request
        )
      end)

    assert_receive {:canonical_snapshot, ^request, snapshot}, 5000
    assert length(snapshot.regions) == 8 and length(snapshot.chunks) == 512

    fixture =
      Path.expand(
        "../../../../../../Voxim/Docs/M1/runtime/S1/world-fixture/256b33610344964f/L0",
        __DIR__
      )

    for {{x, y, z}, bytes} <- snapshot.regions do
      {:ok, actual} = Voxel.Payload.decode(bytes)

      {:ok, saved} =
        File.read!(Path.join(fixture, "r_#{x}_#{y}_#{z}.vxr")) |> Voxel.Payload.decode()

      assert actual.cells == saved.cells and actual.records == saved.records and
               actual.maps == saved.maps

      assert actual.content_version == 0x256B33610344964F and actual.seq == 0
    end

    clock = :atomics.new(1, signed: true)

    scene =
      start_supervised!(
        Supervisor.child_spec(
          {Scene,
           [
             scene_id: 1,
             scene_epoch: 7,
             world_ref: world,
             config: config(),
             clock: {Clock, clock},
             sink: Sink
           ]},
          id: :generated_scene
        )
      )

    await(scene, & &1.initialized, 10_000)

    for {epoch, cid, tick} <- [{41, 10, 1}, {42, 20, 2}] do
      Scene.join(scene, identity(epoch), %{id: cid}, self())
      await(scene, &(&1.queue_length == 1), 10_000)
      advance(%{scene: scene, clock: clock}, tick)
      assert_receive {:reliable, _, :control, %Session.SessionStart{state: %{grounded: 1}}}, 5000
    end

    advance(%{scene: scene, clock: clock}, 60)
    info = Scene.observe(scene)
    assert info.character_count == 2 and info.physics_steps == 117

    IO.puts(
      "S1_LINUX_COLD " <>
        inspect(%{
          cold_snapshot_us: cold_us,
          build_us: info.build_us,
          step_us: info.step_us,
          full_tick_us: info.tick_us,
          max_tick_us: info.max_tick_us,
          physics_steps: info.physics_steps,
          source: VoxelRegion.World.stats(world),
          characters: info.characters
        })
    )
  end
end
