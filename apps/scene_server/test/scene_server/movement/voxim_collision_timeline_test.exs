Code.require_file("runtime_observation.exs", __DIR__)
defmodule SceneServer.Movement.VoximCollisionTimelineTest do
  use ExUnit.Case, async: false
  alias MmoContracts.{Session, Movement, Voxel}
  alias SceneServer.Movement.{Scene, Player, CollisionUpdates}
  import SceneServer.Movement.RuntimeObservation
  alias SceneServer.Native.VoximMovement, as: P1
  alias VoxelRegion.World

  @box {{-1, 7, -1}, {1, 9, 1}}
  @left {31, 550, 40}
  @right {32, 550, 40}
  @moduletag timeout: 120_000
  @moduletag e1_case: :other

  defmodule Clock do
    def now(ref), do: :atomics.get(ref, 1)
    def schedule(_, _, _), do: :ok
  end

  # 仅让第一次真实 source.ensure 延后，World 仍唯一发送 marker/delta。
  defmodule PreparingStore do
    defdelegate open(opts), to: VoxelRegion.FileStore
    defdelegate content_version(store), to: VoxelRegion.FileStore
    defdelegate world_dir(store), to: VoxelRegion.FileStore
    defdelegate read(store, level, region), to: VoxelRegion.FileStore
    defdelegate generated(store), to: VoxelRegion.FileStore

    def ensure(store, level, region) do
      case Application.get_env(:scene_server, :e1_prepare) do
        {counter, observer} when level == 0 and region == {-1, 7, -1} ->
          if :atomics.add_get(counter, 1, 1) == 1 do
            send(observer, {:e1_preparing, self()})

            receive do
              :e1_continue -> :ok
            end
          end

        _ ->
          :ok
      end

      VoxelRegion.FileStore.ensure(store, level, region)
    end
  end

  # 只观察及暂停既有调用，所有几何查询与积分仍交真实 P1。
  defmodule Native do
    alias SceneServer.Native.VoximMovement, as: P1
    defdelegate new_world(), to: P1
    defdelegate world_stats(world), to: P1
    defdelegate query_bounds(profile, state), to: P1
    defdelegate find_spawn(world, profile, probe, min_y), to: P1

    def set_chunks(world, operations) do
      observer = Application.fetch_env!(:scene_server, :e1_observer)

      if Application.get_env(:scene_server, :e1_block_install, false) do
        send(observer, {:p1_blocked, self(), operations})

        receive do
          :e1_continue -> :ok
        end
      end

      next = P1.set_chunks(world, operations)
      send(observer, {:p1_install, operations})
      next
    end

    def step_characters(world, profile, characters) do
      result = P1.step_characters(world, profile, characters)
      probes = for x <- [31.5, 32.5], do: P1.find_spawn(world, profile, {x, 555.0, 40.5}, 548.0)

      send(
        Application.fetch_env!(:scene_server, :e1_observer),
        {:p1_step, characters, result, probes}
      )

      result
    end
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "voxim_e1_#{System.unique_integer([:positive])}")
    File.cp_r!(System.fetch_env!("E1_FIXTURE"), root)

    on_exit(fn ->
      true =
        String.starts_with?(Path.expand(root), Path.expand(System.tmp_dir!()) <> "/voxim_e1_")

      File.rm_rf!(root)
      Application.delete_env(:scene_server, :e1_observer)
      Application.delete_env(:scene_server, :e1_block_install)
      Application.delete_env(:scene_server, :e1_prepare)
    end)

    Application.put_env(:scene_server, :e1_observer, self())
    source = if tags[:generated], do: VoxelRegion.GeneratedStore, else: PreparingStore

    if tags[:generated] do
      {:ok, store} =
        VoxelRegion.GeneratedStore.open(
          root: root,
          manifest_path: System.fetch_env!("E1_MANIFEST")
        )

      for level <- 1..5 do
        region = {0, div(550, 64 * Integer.pow(2, level)), 0}
        :ok = VoxelRegion.GeneratedStore.bake_region(store, level, region)
      end
    end

    world =
      start_supervised!(
        {World,
         root: root,
         name: :e1_actual_world,
         source: source,
         manifest_path: System.fetch_env!("E1_MANIFEST")}
      )

    profile =
      File.read!(System.fetch_env!("E1_PROFILE"))
      |> Jason.decode!()
      |> Map.fetch!("profile")
      |> Map.put("fixed_hz", 60)

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

    clock = :atomics.new(1, signed: true)

    scene =
      start_supervised!(
        {Scene,
         scene_id: 1,
         scene_epoch: 7,
         world_ref: world,
         config: config,
         clock: {Clock, clock},
         native: Native}
      )

    await(scene, & &1.initialized)
    assert_receive {:p1_install, initial}, 5000
    assert length(initial) == 512
    request = make_ref()
    assert :ok = World.canonical_snapshot_and_subscribe(world, @box, self(), request)

    assert {:canonical_snapshot, ^request,
            %Voxel.CanonicalSnapshot{transaction_seq: 0} = snapshot} = next_canonical()

    %{scene: scene, world: world, clock: clock, snapshot: snapshot, root: root, config: config}
  end

  defp identity(epoch), do: %Session.Identity{session_epoch: epoch, scene_id: 1, scene_epoch: 7}

  defp await(scene, predicate, attempts \\ 5000) do
    info = observe(scene)

    if predicate.(info),
      do: info,
      else:
        (
          assert attempts > 0, inspect(info)

          receive do
          after
            1 -> :ok
          end

          await(scene, predicate, attempts - 1)
        )
  end

  defp advance(ctx, tick) do
    :atomics.put(ctx.clock, 1, div(tick * 1_000_000 + 59, 60))
    send(ctx.scene, :tick)
    await(ctx.scene, &(&1.tick == tick))
  end

  # 不按期望 seq、marker ref 或具体消息种类选择接收。
  defp next_canonical do
    assert_receive message when elem(message, 0) in [:canonical_delta, :canonical_snapshot], 5000
    message
  end

  defp next_output do
    assert_receive message when elem(message, 0) in [:mmo_reliable, :mmo_datagram, :mmo_close],
                   5000

    message
  end

  defp outputs(acc \\ []) do
    receive do
      message when elem(message, 0) in [:mmo_reliable, :mmo_datagram, :mmo_close] ->
        outputs([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp native_events(acc \\ []) do
    receive do
      message when elem(message, 0) in [:p1_install, :p1_step] -> native_events([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp join(ctx, epoch \\ 1, cid \\ 10, inspect_bootstrap \\ fn _ -> :ok end) do
    {:ok, _} = Scene.join(ctx.scene, identity(epoch), %{id: cid}, self())
    await(ctx.scene, &(&1.queue_length > 0))
    info = advance(ctx, observe(ctx.scene).tick + 1)
    assert {:mmo_reliable, _, 1, %Session.SessionStart{} = start} = next_output()
    assert {:mmo_reliable, _, 2, %Voxel.CanonicalBootstrap{} = bootstrap} = next_output()
    assert {:mmo_reliable, _, 2, %Voxel.TimelineFence{} = fence} = next_output()
    assert start.identity == identity(epoch) and bootstrap.identity == identity(epoch)

    assert {start.baseline_transaction_seq, start.collision_revision, start.server_tick} ==
             {bootstrap.transaction_seq, bootstrap.collision_revision, fence.server_tick}

    assert fence.transaction_seq == start.baseline_transaction_seq
    assert info.tick == start.server_tick
    inspect_bootstrap.(bootstrap)
    native_events()
    start
  end

  defp delta(ctx, edits, seq) do
    assert {:ok, ^seq} = World.apply_edits(ctx.world, edits)

    assert {:canonical_delta, %Voxel.CanonicalDelta{transaction_seq: ^seq} = delta} =
             next_canonical()

    delta
  end

  defp log(delta, epoch \\ 1) do
    assert {:mmo_reliable, who, 2, {:voxel_log_transaction_payload, bytes}} = next_output()
    assert who == identity(epoch)
    assert bytes == IO.iodata_to_binary(Voxel.Codec.encode_transaction(delta.transaction))
    assert {:ok, %{seq: seq}} = Voxel.Codec.decode_transaction(bytes)
    assert seq == delta.transaction_seq
  end

  defp applied(delta, tick, revision, epoch \\ 1) do
    log(delta, epoch)
    assert {:mmo_reliable, who, 2, %Voxel.CollisionApplied{} = event} = next_output()
    assert who == identity(epoch) and event.identity == who

    assert {event.transaction_seq, event.apply_tick, event.collision_revision} ==
             {delta.transaction_seq, tick, revision}

    assert event.changed_chunks == Enum.map(delta.chunks, & &1.coord)
  end

  @tag e1_case: :atomic
  test "two-core transaction installs once at K and consecutive same-core versions each serve a P1 tick",
       ctx do
    join(ctx)
    advance(ctx, 2)
    assert [{:p1_step, _, _, [:not_found, :not_found]}] = native_events()
    d1 = delta(ctx, [{@left, 11}, {@right, 11}], 1)
    d2 = delta(ctx, [{@left, 0}], 2)
    d3 = delta(ctx, [{@left, 11}], 3)
    assert Enum.map(d1.chunks, & &1.coord) == [{1, 34, 2}, {2, 34, 2}]
    assert [d1.transaction, d2.transaction, d3.transaction] == World.entries_after(ctx.world, 0)
    await(ctx.scene, &(&1.queue_length == 3))
    assert observe(ctx.scene).collision_revision == 1
    assert [] == native_events()

    for {d, tick, revision, occupied} <- [
          {d1, 3, 2, [true, true]},
          {d2, 4, 3, [false, true]},
          {d3, 5, 4, [true, true]}
        ] do
      info = advance(ctx, tick)

      assert [{:p1_install, operations}, {:p1_step, [{10, _, _}], [{10, _}], probes}] =
               native_events()

      assert operations == CollisionUpdates.operations(d.chunks)
      assert Enum.map(probes, &match?({:ok, _}, &1)) == occupied
      assert {info.transaction_seq, info.collision_revision} == {d.transaction_seq, revision}
      applied(d, tick, revision)
      assert [] == outputs()
    end

    advance(ctx, 6)
    assert [{:p1_step, _, _, _}] = native_events()
    assert [] == outputs()

    IO.puts(
      "E1_CROSS_CORE K=3 seq/revision/tick=1/2/3,2/3/4,3/4/5; two real P1 support probes old/new and one install per transaction"
    )
  end

  test "real World commits and captures later immutable delta while Scene install is deliberately blocked",
       ctx do
    join(ctx)
    d1 = delta(ctx, [{@left, 11}], 1)
    await(ctx.scene, &(&1.queue_length == 1))
    Application.put_env(:scene_server, :e1_block_install, true)
    :atomics.put(ctx.clock, 1, 33_334)
    send(ctx.scene, :tick)
    assert_receive {:p1_blocked, installer, operations}, 5000
    assert installer == ctx.scene and operations == CollisionUpdates.operations(d1.chunks)

    try do
      {commit_us, d2} = :timer.tc(fn -> delta(ctx, [{@left, 0}], 2) end)
      assert World.seq(ctx.world) == 2
      assert [d1.transaction, d2.transaction] == World.entries_after(ctx.world, 0)
      assert hd(d1.chunks).cells != hd(d2.chunks).cells
      assert [] == native_events() and [] == outputs()
      Application.delete_env(:scene_server, :e1_block_install)
      send(installer, :e1_continue)
      await(ctx.scene, &(&1.tick == 2 and &1.queue_length == 1))

      assert [{:p1_install, ^operations}, {:p1_step, _, _, [{:ok, _}, :not_found]}] =
               native_events()

      applied(d1, 2, 2)
      advance(ctx, 3)
      assert [{:p1_install, later}, {:p1_step, _, _, [:not_found, :not_found]}] = native_events()
      assert later == CollisionUpdates.operations(d2.chunks)
      applied(d2, 3, 3)
      assert [] == outputs()

      IO.puts(
        "E1_BLOCKED_REAL_WORLD commit_capture_us=#{commit_us} seq2 committed while Scene blocked; seq1/2 served P1 ticks2/3"
      )
    after
      Application.delete_env(:scene_server, :e1_block_install)
      send(installer, :e1_continue)
    end
  end

  test "real air-water and same-blocking material/skin changes advance log seq without collision rebuild",
       ctx do
    join(ctx)

    water =
      MmoContracts.VoxelMaterialCatalog.table()
      |> Enum.find(&(&1["name"] == "water"))
      |> Map.fetch!("id")

    d1 = delta(ctx, [{@left, water}], 1)
    d2 = delta(ctx, [{@left, 0}], 2)
    d3 = delta(ctx, [{{40, 500, 40}, 12}], 3)
    d4 = delta(ctx, [{{40, 500, 40}, 11}], 4)
    for d <- [d1, d2, d3, d4], do: assert(d.chunks == [])
    await(ctx.scene, &(&1.queue_length == 4))
    info = advance(ctx, 2)
    assert {info.transaction_seq, info.collision_revision, info.queue_length} == {4, 1, 0}
    assert [{:p1_step, _, _, _}] = native_events()
    for d <- [d1, d2, d3, d4], do: log(d)
    assert [] == outputs()
    assert Enum.map([d1, d2, d3, d4], & &1.transaction) == World.entries_after(ctx.world, 0)

    assert Enum.any?(d3.transaction.coarse, fn a ->
             Enum.any?(d4.transaction.coarse, fn b ->
               {a.level, a.cell, a.material} == {b.level, b.cell, b.material} and
                 a.skins != b.skins
             end)
           end)

    IO.puts(
      "E1_EMPTY occupancy unchanged seq1..4, revision1; real canonical coarse skin records retained"
    )
  end

  @tag generated: true
  test "out-of-domain actual GeneratedStore World transaction retains sequence and log without outside collider",
       ctx do
    join(ctx)
    d1 = delta(ctx, [{{64, 550, 40}, 11}], 1)
    assert d1.chunks == []
    d2 = delta(ctx, [{@left, 11}, {{65, 550, 40}, 11}], 2)
    assert Enum.map(d2.chunks, & &1.coord) == [{1, 34, 2}]
    assert length(d2.transaction.entries) == 2
    await(ctx.scene, &(&1.queue_length == 2))
    info = advance(ctx, 2)
    assert {info.transaction_seq, info.collision_revision} == {2, 2}
    log(d1)
    applied(d2, 2, 2)
    assert [{:p1_install, operations}, {:p1_step, _, _, [{:ok, _}, :not_found]}] = native_events()
    assert operations == CollisionUpdates.operations(d2.chunks)
    assert [d1.transaction, d2.transaction] == World.entries_after(ctx.world, 0)
    assert [] == outputs()

    IO.puts(
      "E1_OUTSIDE real GeneratedStore seq1 outside-only no install; seq2 mixed World transaction only in-B core installed"
    )
  end

  @tag e1_case: :marker
  test "reversed real source preparation preserves World marker order and each edit version",
       ctx do
    d1 = delta(ctx, [{@left, 11}], 1)
    counter = :atomics.new(1, signed: true)
    Application.put_env(:scene_server, :e1_prepare, {counter, self()})
    {:ok, _} = Scene.join(ctx.scene, identity(1), %{id: 10}, self())
    assert_receive {:e1_preparing, first_worker}, 5000

    try do
      {:ok, _} = Scene.join(ctx.scene, identity(2), %{id: 20}, self())
      await(ctx.scene, &(&1.queue_length == 2))
      d2 = delta(ctx, [{@left, 12}], 2)
      assert d2.chunks == []
      send(first_worker, :e1_continue)
      await(ctx.scene, &(&1.queue_length == 4))
      d3 = delta(ctx, [{@left, 0}], 3)
      await(ctx.scene, &(&1.queue_length == 5))
      info = advance(ctx, 1)
      assert {info.transaction_seq, info.collision_revision, info.queue_length} == {1, 2, 3}

      assert {:mmo_reliable, _, 1,
              %Session.SessionStart{
                identity: who,
                baseline_transaction_seq: 1,
                collision_revision: 2
              }} = next_output()

      assert who == identity(2)

      assert {:mmo_reliable, ^who, 2, %Voxel.CanonicalBootstrap{transaction_seq: 1}} =
               next_output()

      assert {:mmo_reliable, ^who, 2, %Voxel.TimelineFence{server_tick: 1, transaction_seq: 1}} =
               next_output()

      # 首个角色在本 tick 的步进阶段之后才锚定；空角色列表不产生虚构物理步。
      assert [{:p1_install, ops1}] = native_events()
      assert ops1 == CollisionUpdates.operations(d1.chunks)
      info = advance(ctx, 2)
      assert {info.transaction_seq, info.collision_revision, info.queue_length} == {2, 2, 1}
      log(d2, 2)

      assert {:mmo_reliable, _, 1,
              %Session.SessionStart{
                identity: who,
                baseline_transaction_seq: 2,
                collision_revision: 2
              }} = next_output()

      assert who == identity(1)

      assert {:mmo_reliable, ^who, 2, %Voxel.CanonicalBootstrap{transaction_seq: 2}} =
               next_output()

      assert {:mmo_reliable, ^who, 2, %Voxel.TimelineFence{server_tick: 2, transaction_seq: 2}} =
               next_output()

      assert [{:p1_step, [{20, _, _}], _, [{:ok, _}, :not_found]}] = native_events()
      advance(ctx, 3)
      events = outputs()

      for epoch <- [1, 2] do
        assert [log_event, applied_event] = Enum.filter(events, &(elem(&1, 1) == identity(epoch)))
        assert {:mmo_reliable, _, 2, {:voxel_log_transaction_payload, bytes}} = log_event
        assert bytes == IO.iodata_to_binary(Voxel.Codec.encode_transaction(d3.transaction))

        assert {:mmo_reliable, _, 2,
                %Voxel.CollisionApplied{transaction_seq: 3, apply_tick: 3, collision_revision: 3}} =
                 applied_event
      end

      assert length(events) == 4

      assert [
               {:p1_install, ops3},
               {:p1_step, [{10, _, _}], _, [:not_found, :not_found]},
               {:p1_step, [{20, _, _}], _, [:not_found, :not_found]}
             ] = native_events()

      assert ops3 == CollisionUpdates.operations(d3.chunks)

      IO.puts(
        "E1_REVERSE_PREPARE second join anchors seq1/tick1 before first join seq2/tick2; later seq3 remains tick3"
      )
    after
      Application.delete_env(:scene_server, :e1_prepare)
      send(first_worker, :e1_continue)
    end
  end

  @tag :m3_remaining
  test "edits during joining retain Ready baseline, ordered InputStart/fence, ACK and reconnect cleanup",
       ctx do
    start = join(ctx)
    d1 = delta(ctx, [{@left, 11}], 1)
    Scene.join(ctx.scene, identity(2), %{id: 20}, self())
    await(ctx.scene, &(&1.queue_length == 2))
    d2 = delta(ctx, [{@left, 0}], 2)
    await(ctx.scene, &(&1.queue_length == 3))
    advance(ctx, 2)
    applied(d1, 2, 2)

    assert {:mmo_reliable, _, 1, %Session.SessionStart{baseline_transaction_seq: 1}} =
             next_output()

    assert {:mmo_reliable, _, 2, %Voxel.CanonicalBootstrap{transaction_seq: 1}} = next_output()
    assert {:mmo_reliable, _, 2, %Voxel.TimelineFence{transaction_seq: 1}} = next_output()

    Player.time_probe(player(ctx.scene, start.identity), start.identity, %Session.TimeProbe{
      request_id: 1,
      client_send_us: 1
    })

    assert {:mmo_reliable, _, 1, %Session.TimeReply{}} = next_output()
    Player.ready(player(ctx.scene, start.identity), start.identity, 0, 1)
    info = advance(ctx, 3)
    events = outputs()
    own = Enum.filter(events, &(elem(&1, 1) == start.identity))
    assert [log_event, collision, input_start, fence] = own
    assert {:mmo_reliable, _, 2, {:voxel_log_transaction_payload, bytes}} = log_event
    assert bytes == IO.iodata_to_binary(Voxel.Codec.encode_transaction(d2.transaction))

    assert {:mmo_reliable, _, 2,
            %Voxel.CollisionApplied{transaction_seq: 2, apply_tick: 3, collision_revision: 3}} =
             collision

    assert {:mmo_reliable, _, 1,
            %Session.InputStart{
              anchor_tick: 3,
              origin_tick: 33,
              transaction_seq: 2,
              collision_revision: 3,
              state: anchor
            }} = input_start

    assert anchor == hd(info.characters).state

    assert {:mmo_reliable, _, 2,
            %Voxel.TimelineFence{server_tick: 3, transaction_seq: 2, collision_revision: 3}} =
             fence

    assert length(events) == 6
    Player.ready(player(ctx.scene, start.identity), start.identity, 0, 1)
    advance(ctx, 32)
    assert [] == outputs()

    water =
      MmoContracts.VoxelMaterialCatalog.table()
      |> Enum.find(&(&1["name"] == "water"))
      |> Map.fetch!("id")

    d3 = delta(ctx, [{@left, water}], 3)
    assert d3.chunks == []
    await(ctx.scene, &(&1.queue_length == 1))
    # ACK1 必须来自真实输入，不能依赖旧版缺帧替代行为。
    Player.input(player(ctx.scene, start.identity), start.identity, %Movement.InputBatch{identity: start.identity,
      frames: [%Movement.InputFrame{input_seq: 1, axis_x: 0, axis_z: 0, yaw: 0, jump_pressed: 0}]})
    advance(ctx, 33)
    own = outputs() |> Enum.filter(&(elem(&1, 1) == start.identity))
    assert [log_event, fence, ack] = own
    assert {:mmo_reliable, _, 2, {:voxel_log_transaction_payload, _}} = log_event

    assert {:mmo_reliable, _, 2,
            %Voxel.TimelineFence{server_tick: 33, transaction_seq: 3, collision_revision: 3}} =
             fence

    assert {:mmo_datagram, _,
            %Movement.OwnerAck{server_tick: 33, simulation_tick: 33, collision_revision: 3,
              processed_input_seq: 1, substituted_through_seq: 0}} =
             ack

    Scene.leave(ctx.scene, start.identity)
    assert {:mmo_close, _, 1} = next_output()
    native_events()

    fresh =
      join(ctx, 3, 10, fn bootstrap ->
        for {_coord, bytes} <- bootstrap.regions do
          {:ok, payload} = Voxel.Payload.decode(bytes)
          assert payload.seq == 3
        end

        {{0, 8, 0}, bytes} = Enum.find(bootstrap.regions, &(elem(&1, 0) == {0, 8, 0}))
        {:ok, payload} = Voxel.Payload.decode(bytes)
        assert Voxel.Payload.material(payload, Voxel.Payload.local({0, 8, 0}, @left)) == water
      end)

    assert {fresh.baseline_transaction_seq, fresh.collision_revision} == {3, 3}
    Scene.leave(ctx.scene, start.identity)
    Player.ready(player(ctx.scene, fresh.identity), start.identity, 0, 1)

    Player.input(player(ctx.scene, fresh.identity), start.identity, %Movement.InputBatch{
      identity: start.identity,
      frames: []
    })

    info = observe(ctx.scene)
    assert info.character_count == 2 and info.queue_length == 0 and info.old_identity >= 2
    assert Enum.find(info.characters, &(&1.entity_id == 10)).identity == fresh.identity
    assert Enum.find(info.characters, &(&1.entity_id == 10)).processed_input_seq == 0
    assert [] == outputs()

    IO.puts(
      "E1_JOIN Ready retains N0/R1; InputStart A3/N2/R3/origin33 before same-A fence; ACK33 follows fence; reconnect N3/R3 survives three stale-epoch operations"
    )
  end

  @tag e1_case: :motion
  test "actual terrain support removal makes both joining characters fall only on the installed version",
       ctx do
    join(ctx)
    join(ctx, 2, 20)
    before = advance(ctx, 3)
    native_events()

    edits =
      for c <- before.characters,
          x <- (floor(elem(c.state.position, 0)) - 1)..floor(elem(c.state.position, 0)),
          z <- (floor(elem(c.state.position, 2)) - 1)..floor(elem(c.state.position, 2)),
          y <- (floor(elem(c.state.position, 1)) - 4)..floor(elem(c.state.position, 1)),
          do: {{x, y, z}, 0}

    d1 = delta(ctx, Enum.uniq(edits), 1)
    assert d1.chunks != []
    assert observe(ctx.scene).characters == before.characters
    assert [] == native_events() and [] == outputs()
    info = advance(ctx, 4)
    assert info.collision_revision == 2

    assert [{:p1_install, operations}, {:p1_step, [{10, _, _}], _, _}, {:p1_step, [{20, _, _}], _, _}] =
             native_events()

    assert operations == CollisionUpdates.operations(d1.chunks)
    events = outputs()
    assert length(events) == 4

    for c <- info.characters do
      previous = Enum.find(before.characters, &(&1.entity_id == c.entity_id))
      assert elem(c.state.position, 1) <= elem(previous.state.position, 1)
      assert c.state.grounded == 0
      assert not c.active and c.origin_tick == nil and c.processed_input_seq == 0

      assert [
               {:mmo_reliable, _, 2, {:voxel_log_transaction_payload, _}},
               {:mmo_reliable, _, 2,
                %Voxel.CollisionApplied{transaction_seq: 1, apply_tick: 4, collision_revision: 2}}
             ] =
               Enum.filter(events, &(elem(&1, 1) == c.identity))
    end

    first_fall = advance(ctx, 5)

    for c <- first_fall.characters do
      previous = Enum.find(before.characters, &(&1.entity_id == c.entity_id))
      assert elem(c.state.position, 1) < elem(previous.state.position, 1)
      assert elem(c.state.velocity, 1) < 0.0
    end

    fallen = advance(ctx, 14)

    for c <- fallen.characters do
      previous = Enum.find(before.characters, &(&1.entity_id == c.entity_id))
      assert elem(c.state.position, 1) < elem(previous.state.position, 1) - 0.1
    end

    IO.puts(
      "E1_DIG " <>
        inspect(%{
          tick: 4,
          seq: 1,
          revision: 2,
          before: Enum.map(before.characters, & &1.state),
          after: Enum.map(fallen.characters, & &1.state)
        })
    )
  end

  @tag e1_case: :motion
  @tag :m3_remaining
  test "actual Scene inputs hit an edited wall and pass its former plane after removal", ctx do
    start = join(ctx)

    Player.time_probe(player(ctx.scene, start.identity), start.identity, %Session.TimeProbe{
      request_id: 1,
      client_send_us: 1
    })

    assert {:mmo_reliable, _, 1, %Session.TimeReply{}} = next_output()
    Player.ready(player(ctx.scene, start.identity), start.identity, 0, 1)
    advance(ctx, 2)
    assert {:mmo_reliable, _, 1, %Session.InputStart{origin_tick: 32}} = next_output()
    assert {:mmo_reliable, _, 2, %Voxel.TimelineFence{server_tick: 2}} = next_output()
    native_events()
    {x, y, z} = start.state.position
    wall_z = floor(z) + 1

    cells =
      for wx <- (floor(x) - 2)..(floor(x) + 2),
          wy <- (floor(y) - 2)..(ceil(y) + 3),
          do: {wx, wy, wall_z}

    wall = delta(ctx, Enum.map(cells, &{&1, 11}), 1)
    assert observe(ctx.scene).collision_revision == 1
    advance(ctx, 3)
    applied(wall, 3, 2)
    native_events()
    advance(ctx, 31)
    native_events()
    blocked = walk(ctx, 32..81, 32)
    blocked_z = elem(hd(blocked.characters).state.position, 2)

    assert blocked_z > z + 0.1 and blocked_z < wall_z,
           inspect(%{start: start.state, blocked: hd(blocked.characters).state, wall_z: wall_z})

    removed = delta(ctx, Enum.map(cells, &{&1, 0}), 2)
    # 显式保留拆墙 tick 的连续输入号；缺少 seq51 时正确行为是等待。
    send_walk_input(ctx, 82, 32)
    advance(ctx, 82)
    events = outputs()

    assert [
             {:mmo_reliable, _, 2, {:voxel_log_transaction_payload, _}},
             {:mmo_reliable, _, 2,
              %Voxel.CollisionApplied{transaction_seq: 2, apply_tick: 82, collision_revision: 3}}
           ] = events

    assert [{:p1_install, operations}, {:p1_step, _, _, _}] = native_events()
    assert operations == CollisionUpdates.operations(removed.chunks)
    passed = walk(ctx, 83..112, 32)
    passed_z = elem(hd(passed.characters).state.position, 2)
    assert passed_z > wall_z + 0.35

    IO.puts(
      "E1_WALL " <>
        inspect(%{
          wall_z: wall_z,
          blocked_z: blocked_z,
          removed_tick: 82,
          passed_z: passed_z,
          seq: 2,
          revision: 3
        })
    )
  end

  defp walk(ctx, ticks, origin) do
    Enum.reduce(ticks, nil, fn tick, _ ->
      send_walk_input(ctx, tick, origin)

      info = advance(ctx, tick)
      assert info.character_count == 1
      assert hd(info.characters).processed_input_seq == tick - origin + 1
      assert [{:p1_step, [{10, _, _}], _, _}] = native_events()
      events = outputs()

      if rem(tick, 3) == 0 do
        assert [
                 {:mmo_reliable, _, 2, %Voxel.TimelineFence{}},
                 {:mmo_datagram, _, %Movement.OwnerAck{}}
               ] = events
      else
        assert events == []
      end

      info
    end)
  end

  defp send_walk_input(ctx, tick, origin) do
    frame = %Movement.InputFrame{input_seq: tick - origin + 1, axis_x: 0,
      axis_z: 32767, yaw: 0, jump_pressed: 0}
    Player.input(player(ctx.scene, identity(1)), identity(1), %Movement.InputBatch{identity: identity(1), frames: [frame]})
  end
end
