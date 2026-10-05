defmodule SceneServer.Movement.VoximPlayerTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.{Scene, Player, CollisionUpdates}
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

  defmodule Source do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def canonical_snapshot_and_subscribe(pid, box, subscriber, ref, _include_chunks \\ true),
      do: GenServer.call(pid, {:snapshot, box, subscriber, ref})

    def handle_call({:snapshot, _, _, _}, _, %{error: true} = state) do
      send(state.owner, :snapshot_failed)
      {:reply, {:error, :canonical_incomplete}, state}
    end

    def handle_call({:snapshot, _, subscriber, ref}, _, %{hold: true} = state) do
      send(state.owner, {:snapshot_held, ref})
      {:reply, :ok, Map.update(state, :held, [{subscriber, ref}], &(&1 ++ [{subscriber, ref}]))}
    end

    # 只测试：冻结下一次入场快照的交付，仍允许此前 canonical delta 正常进入 Scene。
    def handle_call({:hold, snapshot}, _, state),
      do: {:reply, :ok, Map.merge(state, %{hold: true, snapshot: snapshot})}

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

  defp identity(epoch),
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
    body_store = start_supervised!({MmoTest.BodyStore, []})

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
           body_store: {MmoTest.BodyStore, store: body_store},
           world_api: Source
         ]}
      )

    wait(fn -> Scene.observe(scene).initialized end)
    %{scene: scene, source: source, clock: clock}
  end

  defp wait(fun, attempts \\ 2000) do
    value = fun.()

    if value,
      do: value,
      else:
        (
          assert(attempts > 0)
          Process.sleep(1)
          wait(fun, attempts - 1)
        )
  end

  defp tick(ctx, tick) do
    :atomics.put(ctx.clock, 1, div(tick * 1_000_000 + 59, 60))
    send(ctx.scene, :tick)
    wait(fn -> Scene.observe(ctx.scene).tick == tick end)
  end

  defp join(ctx, epoch, id, tick) do
    {:ok, player} = Scene.join(ctx.scene, identity(epoch), %{id: id}, self())
    wait(fn -> Scene.observe(ctx.scene).queue_length > 0 end)
    tick(ctx, tick)
    assert_receive {:reliable, _, :control, %Session.SessionStart{} = start}, 1000
    {player, start}
  end

  defp activate(ctx) do
    {p, start} = join(ctx, 1, 20, 1)
    {q, _} = join(ctx, 2, 10, 2)

    for {pid, epoch} <- [{p, 1}, {q, 2}] do
      Player.time_probe(pid, identity(epoch), %Session.TimeProbe{
        request_id: epoch,
        client_send_us: 1
      })

      Player.ready(pid, identity(epoch), 0, 1)
      Player.observe(pid)
    end

    tick(ctx, 3)

    for _ <- 1..2,
        do: assert_receive({:reliable, _, :control, %Session.InputStart{origin_tick: 33}}, 1000)

    tick(ctx, 32)

    wait(fn ->
      Player.observe(p).simulation_tick == 32 and Player.observe(q).simulation_tick == 32
    end)

    {p, q, start}
  end

  @tag :replication_phase
  test "20Hz结果晚于Scene发布机会到达时，下个公共tick即复制真实样本", ctx do
    {p, q, _} = activate(ctx)
    rep = Scene.observe(ctx.scene).replication_pid

    for {player, epoch} <- [{p, 1}, {q, 2}] do
      Player.input(
        player,
        identity(epoch),
        %Movement.InputBatch{
          identity: identity(epoch),
          frames: [
            %Movement.InputFrame{input_seq: 1, axis_x: 0, axis_z: 0, yaw: 0, jump_pressed: 0}
          ]
        },
        Clock.now(ctx.clock)
      )

      Player.observe(player)
    end

    # 只测试：先停住Player，确认Scene的tick33发布已处理，再交付该tick的真实结果。
    :ok = :sys.suspend(p)
    :ok = :sys.suspend(q)

    try do
      tick(ctx, 33)
      SceneServer.Movement.Replication.observe(rep)
      discard_datagrams()
    after
      :ok = :sys.resume(p)
      :ok = :sys.resume(q)
    end

    wait(fn ->
      Player.observe(p).simulation_tick == 33 and Player.observe(q).simulation_tick == 33
    end)

    SceneServer.Movement.Replication.observe(rep)
    tick(ctx, 34)
    observer = identity(1)

    assert_receive {:datagram, ^observer,
                    %Movement.Snapshot{server_tick: 33, records: [%{entity_id: 10}]}},
                   1000
  end

  defp discard_datagrams do
    receive do
      {:datagram, _, _} -> discard_datagrams()
    after
      0 -> :ok
    end
  end

  @tag :body_anchor
  test "入场前缀的较新食物不能让游标跳过完整快照中的旧收据", ctx do
    # 只测试：World 和存储是显式替身；验证真实 Scene/Player 的入场消息顺序，
    # 不验证扣料或数据库。两份不可变收据为手算小例，分别提供 1000 J 和 2000 J。
    first = %{protein_g: 0.0, energy_j: 1000.0}
    second = %{protein_g: 0.0, energy_j: 2000.0}

    delta = fn seq, food ->
      %Voxel.CanonicalDelta{
        transaction_seq: seq,
        transaction: %{seq: seq, entries: [], coarse: [], food_receipts: %{20 => %{seq => food}}},
        chunks: []
      }
    end

    :ok = GenServer.call(ctx.source, {:delta, delta.(1, first)})
    wait(fn -> Scene.observe(ctx.scene).queue_length == 1 end)
    tick(ctx, 1)

    :ok = GenServer.call(ctx.source, {:delta, delta.(2, second)})
    wait(fn -> Scene.observe(ctx.scene).queue_length == 1 end)

    complete =
      %{snapshot() | transaction_seq: 2}
      |> Map.put(:food_receipts, %{20 => %{1 => first, 2 => second}})

    :ok = GenServer.call(ctx.source, {:hold, complete})
    {:ok, player} = Scene.join(ctx.scene, identity(1), %{id: 20}, self())
    assert_receive {:snapshot_held, _}

    # 先前的 seq1 已发布给空 Scene；新 Player 在 anchor 前只看到 seq2。
    tick(ctx, 2)
    wait(fn -> Player.observe(player).published_tick == 2 end)
    refute_received {:reliable, _, :control, %Session.SessionStart{}}

    :ok = GenServer.call(ctx.source, :release)
    wait(fn -> Scene.observe(ctx.scene).queue_length == 1 end)
    tick(ctx, 3)
    assert_receive {:reliable, _, :control, %Session.SessionStart{}}, 1000
    saved = Player.body_snapshot(player)

    assert saved.food_cursors == %{9 => 2}
    assert saved.body.fat_reserve_j == SceneServer.Body.new().fat_reserve_j + 3000.0
    assert :ok = Scene.leave(ctx.scene, identity(1))
  end

  test "断流角色仍推进，迟到跳跃不补跑，另一角色保持正常输入", ctx do
    {p, q, _} = activate(ctx)
    f = %Movement.InputFrame{input_seq: 1, axis_x: 32767, axis_z: 0, yaw: 123, jump_pressed: 0}

    Player.input(
      p,
      identity(1),
      %Movement.InputBatch{identity: identity(1), frames: [f]},
      Clock.now(ctx.clock)
    )

    Player.observe(p)

    for t <- 33..56 do
      frame = %{f | input_seq: t - 32, axis_x: 0}

      Player.input(
        q,
        identity(2),
        %Movement.InputBatch{identity: identity(2), frames: [frame]},
        Clock.now(ctx.clock)
      )

      Player.observe(q)
      tick(ctx, t)
    end

    wait(fn ->
      Player.observe(p).simulation_tick == 56 and Player.observe(q).simulation_tick == 56
    end)

    before = Player.observe(p)

    Player.input(
      p,
      identity(1),
      %Movement.InputBatch{
        identity: identity(1),
        frames: [%{f | input_seq: 12, jump_pressed: 1}]
      },
      Clock.now(ctx.clock)
    )

    after_late = Player.observe(p)
    assert before.state == after_late.state
    assert before.physics_steps == after_late.physics_steps
    assert before.processed_input_seq == 24
    assert before.substitutions == 23
    assert Player.observe(q).substitutions == 0
  end

  test "已进入 owner 邮箱的输入排在切点之前，跨节点不使用发送方单调零点", ctx do
    {p, _q, _} = activate(ctx)
    state = :sys.get_state(p)
    wall = state.time_origin + Clock.now(ctx.clock) - state.time_mono_origin

    frame = %Movement.InputFrame{
      input_seq: 1,
      axis_x: 32767,
      axis_z: 0,
      yaw: 123,
      jump_pressed: 0
    }

    :ok = :sys.suspend(p)

    Player.input(
      p,
      identity(1),
      %Movement.InputBatch{identity: identity(1), frames: [frame]},
      {:another_node, 9_000_000_000, wall}
    )

    tick(ctx, 33)
    :ok = :sys.resume(p)
    wait(fn -> Player.observe(p).simulation_tick == 33 end)
    observed = Player.observe(p)
    assert observed.processed_input_seq == 1
    assert observed.substitutions == 0
    assert observed.state.yaw == 123
    assert elem(observed.state.velocity, 0) > 0
  end

  test "suspended P retains exact R history while Q consumes 60Hz real inputs across R+1", ctx do
    {p, q, start} = activate(ctx)
    assert p != q
    anchor = Player.observe(p)
    :ok = :sys.suspend(p)

    commands =
      for seq <- 1..24 do
        %Movement.InputFrame{
          input_seq: seq,
          axis_x: if(seq < 13, do: 32767, else: 0),
          axis_z: 0,
          yaw: 100,
          jump_pressed: if(seq == 7, do: 1, else: 0)
        }
      end

    removed =
      snapshot().chunks
      |> Enum.filter(&(&1.coord == {2, 31, 2}))
      |> Enum.map(&%{&1 | cells: :binary.copy(<<0>>, 4096)})

    started = System.monotonic_time(:millisecond)

    for frame <- commands do
      if frame.input_seq == 13 do
        GenServer.call(
          ctx.source,
          {:delta,
           %Voxel.CanonicalDelta{
             transaction_seq: 1,
             transaction: %{seq: 1, entries: [], coarse: []},
             chunks: removed
           }}
        )

        wait(fn -> Scene.observe(ctx.scene).queue_length == 1 end)
      end

      Player.input(p, identity(1), %Movement.InputBatch{identity: identity(1), frames: [frame]})
      Player.input(q, identity(2), %Movement.InputBatch{identity: identity(2), frames: [frame]})
      tick(ctx, frame.input_seq + 32)
      wait(fn -> Player.observe(q).processed_input_seq == frame.input_seq end)
      Process.sleep(17)
    end

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 400
    fast = Player.observe(q)
    assert fast.processed_input_seq == 24 and fast.collision_revision == 2
    assert Scene.observe(ctx.scene).tick == 56
    :ok = :sys.resume(p)
    wait(fn -> Player.observe(p).processed_input_seq == 24 end)
    recovered = Player.observe(p)
    assert recovered.simulation_tick == 56
    assert recovered.physics_steps - anchor.physics_steps == 24
    assert recovered.retained_versions == 1
    native = SceneServer.Native.VoximMovement

    old_world =
      native.set_chunks(native.new_world(), CollisionUpdates.operations(snapshot().chunks))

    edited = native.set_chunks(old_world, CollisionUpdates.operations(removed))
    <<bytes::binary-size(120), 60::16>> = Session.Codec.encode_profile(start.profile)
    profile = for(<<v::float-64 <- bytes>>, do: v) |> List.to_tuple()

    expected =
      Enum.reduce(
        commands,
        {anchor.state.position, anchor.state.velocity, anchor.state.grounded},
        fn f, state ->
          world = if f.input_seq < 13, do: old_world, else: edited
          {x, z} = Movement.Codec.axes(f)

          [{20, next}] =
            native.step_characters(world, profile, [{20, state, {x, z, f.jump_pressed}}])

          next
        end
      )

    assert {recovered.state.position, recovered.state.velocity, recovered.state.grounded} ==
             expected

    for frames <- Enum.chunk_every(commands, 6),
        do:
          Player.input(p, identity(1), %Movement.InputBatch{identity: identity(1), frames: frames})

    assert Player.observe(p).physics_steps == recovered.physics_steps
    tick(ctx, 57)

    assert_receive {:datagram, _,
                    %Movement.OwnerAck{
                      server_tick: 57,
                      simulation_tick: 57,
                      processed_input_seq: 25,
                      collision_revision: 2
                    }},
                   1000

    IO.puts(
      "M3_PLAYER_ISOLATION " <>
        inspect(%{
          pause_ms: elapsed,
          p: p,
          q: q,
          p_seq: recovered.processed_input_seq,
          q_seq: fast.processed_input_seq,
          historical_equal: true,
          duplicate_steps: 0,
          q_revision: fast.collision_revision
        })
    )
  end

  test "unknown future timeline blocks input and old route cannot move a rejoined identity",
       ctx do
    {p, q, _} = activate(ctx)

    frames =
      for seq <- 1..10,
          do: %Movement.InputFrame{
            input_seq: seq,
            axis_x: 0,
            axis_z: 0,
            yaw: 0,
            jump_pressed: if(seq == 1, do: 1, else: 0)
          }

    Player.input(p, identity(1), %Movement.InputBatch{identity: identity(1), frames: frames})
    assert Player.observe(p).processed_input_seq == 0
    tick(ctx, 33)
    wait(fn -> Player.observe(p).processed_input_seq == 1 end)
    assert Player.observe(p).pending_inputs == 9
    Scene.leave(ctx.scene, identity(1), 2)
    wait(fn -> Scene.observe(ctx.scene).character_count == 1 end)
    {fresh, _} = join(ctx, 3, 20, 34)
    assert fresh != p and Process.alive?(q)
    Player.input(p, identity(1), %Movement.InputBatch{identity: identity(1), frames: frames})
    Scene.leave(ctx.scene, identity(1), 2)
    assert Player.observe(fresh).processed_input_seq == 0
    assert Scene.observe(ctx.scene).character_count == 2
    Process.exit(fresh, :kill)
    wait(fn -> Scene.observe(ctx.scene).character_count == 1 end)
    assert_receive {:closed, _, 3}, 1000

    assert DynamicSupervisor.count_children(Scene.observe(ctx.scene).player_supervisor_pid).active ==
             1
  end

  @tag :clock_start
  test "input start deadline uses public clock when collision publication is delayed", ctx do
    {player, _} = join(ctx, 1, 20, 1)
    :ok = :sys.suspend(player)
    Player.time_probe(player, identity(1), %Session.TimeProbe{request_id: 1, client_send_us: 1})
    Player.ready(player, identity(1), 0, 1)
    tick(ctx, 2)

    # 只测试：模拟排队中的旧碰撞发布；公共时间继续走，不改历史状态。
    :atomics.put(ctx.clock, 1, 2_000_000)
    :ok = :sys.resume(player)
    assert_receive {:reliable, _, :control, %Session.TimeReply{server_tick: 120}}, 1000
    Player.observe(player)
    refute_receive {:reliable, _, :control, %Session.InputStart{}}, 0
    tick(ctx, 121)

    assert_receive {:reliable, _, :control,
                    %Session.InputStart{
                      collision_revision: 1,
                      first_input_seq: 1
                    } = start},
                   1000

    assert start.origin_tick == start.anchor_tick + 30
    assert start.origin_tick > 121 + start.prediction_lead_ticks
    assert {:ok, bytes} = Session.Codec.encode(start)
    assert {:ok, ^start} = Session.Codec.decode(bytes)
    assert Player.observe(player).processed_input_seq == 0
  end

  # Test-only：冷 bootstrap 的 Ready 与首批真实输入分别迟到，仍只积分原编号对应的历史步。
  test "慢入场保持origin，停流按截止推进且迟到首批不补跑", ctx do
    {player, _} = join(ctx, 1, 20, 1)
    tick(ctx, 120)
    wait(fn -> Player.observe(player).simulation_tick == 120 end)
    refute_receive {:reliable, _, :control, %Session.InputStart{}}, 0
    Player.time_probe(player, identity(1), %Session.TimeProbe{request_id: 1, client_send_us: 1})
    Player.ready(player, identity(1), 0, 1)
    Player.observe(player)
    tick(ctx, 121)

    assert_receive {:reliable, _, :control,
                    %Session.InputStart{anchor_tick: 121, origin_tick: 151}},
                   1000

    tick(ctx, 240)

    waiting =
      wait(fn ->
        value = Player.observe(player)
        if value.published_tick == 240, do: value
      end)

    assert waiting.simulation_tick == 240
    assert waiting.processed_input_seq == 90

    frames =
      for seq <- 1..91,
          do: %Movement.InputFrame{
            input_seq: seq,
            axis_x: if(seq < 31, do: 32767, else: 0),
            axis_z: 0,
            yaw: 0,
            jump_pressed: 0
          }

    Player.input(player, identity(1), %Movement.InputBatch{identity: identity(1), frames: frames})

    recovered =
      wait(fn ->
        value = Player.observe(player)
        if value.processed_input_seq == 90 and value.pending_inputs == 1, do: value
      end)

    assert recovered.simulation_tick == recovered.published_tick
    assert recovered.origin_tick == 151
    assert recovered.pending_inputs == 1
    assert recovered.physics_steps == waiting.physics_steps
    assert recovered.substitutions == 90
    assert recovered.state == waiting.state
    Player.ready(player, identity(1), 0, 1)
    Player.ready(player, identity(0), 0, 1)
    Player.input(player, identity(0), %Movement.InputBatch{identity: identity(0), frames: frames})
    assert Player.observe(player).origin_tick == 151
    tick(ctx, 241)
    assert wait(fn -> Player.observe(player).processed_input_seq == 91 end)
    assert Player.observe(player).simulation_tick == 241
    refute_receive {:reliable, _, :control, %Session.InputStart{}}, 0

    IO.puts(
      "M1_COLD_START origin=151 finalized_through=240 prefix=90 substituted=90 future_waited=1 stale_isolated=true"
    )
  end

  @tag :m3_remaining
  test "a queued TimeProbe pairs current server time with public clock tick despite a stalled owner",
       ctx do
    {p, _q, _} = activate(ctx)
    Player.time_probe(p, identity(1), %Session.TimeProbe{request_id: 100, client_send_us: 1})

    assert_receive {:reliable, _, :control,
                    %Session.TimeReply{request_id: 100, server_tick: 32} = before}

    :sys.suspend(p)
    Player.time_probe(p, identity(1), %Session.TimeProbe{request_id: 101, client_send_us: 2})
    :atomics.put(ctx.clock, 1, div(56 * 1_000_000 + 59, 60))
    :sys.resume(p)

    assert_receive {:reliable, _, :control,
                    %Session.TimeReply{request_id: 101, server_tick: 56} = after_probe}

    assert after_probe.server_send_us - before.server_send_us == 400_000
    assert Player.observe(p).published_tick == 32
    assert Player.observe(p).simulation_tick == 32
  end
end
