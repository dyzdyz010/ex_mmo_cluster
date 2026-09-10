Code.require_file("runtime_observation.exs", __DIR__)
defmodule SceneServer.Movement.VoximInstrumentationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias MmoContracts.{Session, Movement}
  alias SceneServer.Movement.{Scene, Player}

  import SceneServer.Movement.RuntimeObservation

  alias VoxelRegion.World

  defmodule Clock do
    def now(ref), do: :atomics.get(ref, 1)
    def schedule(_, _, _), do: :ok
  end

  # 只记录实际参数和返回值，所有构建、查询、积分均委托现有 P1。
  defmodule Native do
    alias SceneServer.Native.VoximMovement, as: P1
    defdelegate new_world(), to: P1
    defdelegate world_stats(world), to: P1
    defdelegate set_chunks(world, operations), to: P1
    defdelegate query_bounds(profile, state), to: P1
    defdelegate find_spawn(world, profile, probe, min_y), to: P1

    def step_characters(world, profile, characters) do
      result = P1.step_characters(world, profile, characters)
      send(Application.fetch_env!(:scene_server, :is_observer), {:p1_step, characters, result})
      result
    end
  end

  defp identity(epoch), do: %Session.Identity{session_epoch: epoch, scene_id: 1, scene_epoch: 7}

  defp start_scene(real_clock \\ false) do
    root = Path.join(System.tmp_dir!(), "voxim_is_#{System.unique_integer([:positive])}")
    File.cp_r!(System.fetch_env!("IS_FIXTURE"), root)

    on_exit(fn ->
      true =
        String.starts_with?(Path.expand(root), Path.expand(System.tmp_dir!()) <> "/voxim_is_")

      File.rm_rf!(root)
      Application.delete_env(:scene_server, :is_observer)
    end)

    Application.put_env(:scene_server, :is_observer, self())

    world =
      start_supervised!(
        {World, root: root, name: :is_actual_world, source: VoxelRegion.FileStore}
      )

    profile =
      File.read!(System.fetch_env!("IS_PROFILE"))
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
    :atomics.put(clock, 1, 7_000_000)
    clock_options = if real_clock, do: [], else: [clock: {Clock, clock}]

    scene =
      start_supervised!(
        {Scene,
         [scene_id: 1, scene_epoch: 7, world_ref: world, config: config, native: Native] ++
           clock_options}
      )

    initial = await(scene, & &1.initialized)
    %{scene: scene, world: world, clock: clock, initial: initial}
  end

  defp await(scene, predicate, attempts \\ 5000) do
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
    before = observe(ctx.scene)
    :atomics.put(ctx.clock, 1, 7_000_000 + div(tick * 1_000_000 + 59, 60))
    send(ctx.scene, :tick)
    after_tick = await(ctx.scene, &(&1.tick == tick))
    steps = native_steps([])
    arguments = Enum.flat_map(steps, &elem(&1, 0))
    results = Enum.flat_map(steps, &elem(&1, 1))
    %{before: before, after: after_tick, arguments: arguments, results: results}
  end

  defp frame(seq, x, z, jump),
    do: %Movement.InputFrame{input_seq: seq, axis_x: x, axis_z: z, yaw: 100, jump_pressed: jump}

  defp input(ctx, frames),
    do:
      Player.input(player(ctx.scene, identity(1)), identity(1), %Movement.InputBatch{
        identity: identity(1),
        frames: frames
      })

  # 删除日志、错报原始轴/代际/到期槽、把累计成本当单步成本都会失败。
  test "normal INFO retains lifecycle and one summary per second without per-input rows" do
    log = capture_log([level: :info, format: "$message\n"], fn ->
      ctx = start_scene()
      Scene.join(ctx.scene, identity(1), %{id: 10}, self())
      await(ctx.scene, &(&1.queue_length == 1))
      for tick <- 1..60, do: advance(ctx, tick)
    end)
    rows = log |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "{")) |> Enum.map(&Jason.decode!/1)
    assert length(events(rows, "session_start")) == 1
    assert events(rows, "input_selected") == []
    assert events(rows, "input_wait") == []
    assert events(rows, "input_arrival") == []
    assert Enum.map(events(rows, "region_tick"), & &1["server_tick"]) == [60]
  end

  test "ordinary Scene P1 operation emits exact lifecycle input and per-tick facts" do
    log =
      capture_log([format: "$message\n"], fn ->
        ctx = start_scene()
        Scene.join(ctx.scene, identity(1), %{id: 10}, self())
        await(ctx.scene, &(&1.queue_length == 1))
        first = advance(ctx, 1)
        assert_receive {:mmo_reliable, _, 1, %Session.SessionStart{} = start}

        Player.ready(
          player(ctx.scene, identity(1)),
          identity(1),
          start.baseline_transaction_seq,
          start.collision_revision
        )

        Player.time_probe(player(ctx.scene, identity(1)), identity(1), %Session.TimeProbe{
          request_id: 1,
          client_send_us: 1
        })

        second = advance(ctx, 2)
        assert_receive {:mmo_reliable, _, 1, %Session.InputStart{origin_tick: 32} = input_start}
        warm = for tick <- 3..31, do: advance(ctx, tick)
        one = frame(1, 20000, 0, 1)
        input(ctx, [one])
        arrival = observe(ctx.scene)
        active = advance(ctx, 32)
        two = frame(2, 16000, -10000, 0)
        input(ctx, [one, two])
        normal = advance(ctx, 33)

        rest =
          for tick <- 34..40 do
            input(ctx, [frame(tick - 31, if(tick < 40, do: 16000, else: 0),
              if(tick < 40, do: -10000, else: 0), 0)])
            if tick == 35 do
              assert {:ok, 1} = World.apply_edits(ctx.world, [{{40, 550, 40}, 1}])
              await(ctx.scene, &(&1.queue_length == 1))
            end

            advance(ctx, tick)
          end

        input(ctx, [frame(10, 0, 0, 0)])
        stop = advance(ctx, 41)
        Scene.leave(ctx.scene, identity(1))
        assert observe(ctx.scene).character_count == 0
        Scene.join(ctx.scene, identity(2), %{id: 10}, self())
        await(ctx.scene, &(&1.queue_length == 1))
        rejoin = advance(ctx, 42)

        assert_receive {:mmo_reliable, _, 1,
                        %Session.SessionStart{identity: %{session_epoch: 2}} = restarted}

        send(
          self(),
          {:facts, ctx.initial, start, input_start, arrival, restarted,
           [first, second] ++ warm ++ [active, normal] ++ rest ++ [stop, rejoin]}
        )
      end)

    File.write!(Path.join(System.fetch_env!("IS_CACHE"), "ordinary.jsonl"), log)
    assert_receive {:facts, initial, start, input_start, arrival, restarted, ticks}

    behavior =
      for step <- ticks do
        %{
          tick: step.after.tick,
          physics_steps: step.after.physics_steps,
          transaction_seq: step.after.transaction_seq,
          collision_revision: step.after.collision_revision,
          substitutions: step.after.substitutions,
          characters:
            for c <- step.after.characters do
              %{
                session_epoch: c.identity.session_epoch,
                entity_id: c.entity_id,
                entity_epoch: c.entity_epoch,
                position: Tuple.to_list(c.state.position),
                velocity: Tuple.to_list(c.state.velocity),
                grounded: c.state.grounded,
                yaw: c.state.yaw,
                origin_tick: c.origin_tick,
                processed_input_seq: c.processed_input_seq
              }
            end
        }
      end

    File.write!(
      Path.join(System.fetch_env!("IS_CACHE"), "behavior.json"),
      Jason.encode!(behavior)
    )

    rows =
      log
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "{"))
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["schema"] == "voxim-scene-v1"))

    assert length(rows) > 0, "ordinary Scene emits no parseable runtime rows"

    for row <- rows do
      assert row["scene_id"] == 1 and row["scene_epoch"] == 7
      assert row["time_domain"] == "scene_clock_monotonic_us"
      assert is_binary(row["process"]) and row["node"] == "nonode@nohost"
      assert is_integer(row["server_tick"]) and is_integer(row["monotonic_us"])
    end

    [bootstrap] = events(rows, "bootstrap_resident")
    assert bootstrap["build_us"] == initial.build_us
    assert bootstrap["region_count"] == 8 and bootstrap["core_count"] == 512
    assert bootstrap["occupancy_bytes"] == 2_097_152
    assert bootstrap["prepare_start_us"] == 7_000_000
    starts = events(rows, "session_start")

    assert Enum.map(starts, &{&1["session_epoch"], &1["entity_id"], &1["entity_epoch"]}) == [
             {1, 10, start.entity_epoch},
             {2, 10, restarted.entity_epoch}
           ]

    assert restarted.entity_epoch > start.entity_epoch
    assert hd(starts)["content_version"] == start.content_version
    [origin] = events(rows, "input_start")

    assert {origin["server_tick"], origin["origin_tick"]} ==
             {input_start.anchor_tick, input_start.origin_tick}

    arrivals = events(rows, "input_arrival")

    assert Enum.map(arrivals, &{&1["input_seq"], &1["disposition"], &1["due_tick"]}) == [
             {1, "accepted", 32},
             {1, "duplicate", 32},
             {2, "accepted", 33}
           ] ++ Enum.map(3..10, &{&1, "accepted", &1 + 31})

    assert hd(arrivals)["server_tick"] == arrival.tick
    assert hd(arrivals)["monotonic_us"] == 7_516_667
    selected = events(rows, "input_selected")
    active = Enum.filter(selected, &(&1["input_seq"] != nil))

    assert Enum.map(active, & &1["selection"]) ==
             List.duplicate("received", 10)

    assert Enum.map(active, & &1["jump_pressed"]) == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    assert Enum.map(active, & &1["axis_x"]) == [
             20000,
             16000,
             16000,
             16000,
             16000,
             16000,
             16000,
             16000,
             0,
             0
           ]

    assert Enum.all?(active, &(&1["due_tick"] == &1["server_tick"]))

    for step <- ticks, {id, _, {x, z, jump}} <- step.arguments do
      row = Enum.find(selected, &(&1["server_tick"] == step.after.tick and &1["entity_id"] == id))
      assert {row["native_axis_x"], row["native_axis_z"], row["jump_pressed"]} == {x, z, jump}
      assert row["entity_epoch"] == start.entity_epoch
      assert row["session_epoch"] == 1
      assert row["collision_revision"] == step.after.collision_revision
      [{^id, {p, v, grounded}}] = step.results
      [character] = step.after.characters

      assert {character.state.position, character.state.velocity, character.state.grounded} ==
               {p, v, grounded}
    end

    costs = events(rows, "region_tick")
    assert length(costs) == length(ticks)

    for {row, step} <- Enum.zip(costs, ticks) do
      assert row["server_tick"] == step.after.tick
      assert row["nif_us"] == 0
      assert row["tick_us"] == step.after.tick_us - step.before.tick_us
      assert row["build_us"] == step.after.build_us - step.before.build_us
      assert row["stepped_count"] == 0
      assert row["due_us"] == 7_000_000 + div(step.after.tick * 1_000_000 + 59, 60)
      assert row["start_us"] == row["due_us"] and row["end_us"] == row["start_us"]
      assert row["overdue_ticks"] == 0
      assert row["queue_before"] == step.before.queue_length
      assert row["queue_after"] == step.after.queue_length
      assert is_integer(row["mailbox_at_start"])
    end

    edited = Enum.find(costs, &(&1["server_tick"] == 35))
    assert edited["queue_oldest_age_us"] == 16_667
    assert edited["transaction_seq"] == 1 and edited["collision_revision"] == 2
    [ended] = events(rows, "session_end")

    assert {ended["session_epoch"], ended["entity_epoch"], ended["reason"]} ==
             {1, start.entity_epoch, 1}
  end

  # 正常生产时钟的真实定时消息；不把注入时钟的零跨度当运行耗时。
  test "ordinary production clock emits ordered deadlines and real elapsed boundaries" do
    log =
      capture_log([format: "$message\n"], fn ->
        ctx = start_scene(true)
        Scene.join(ctx.scene, identity(1), %{id: 10}, self())
        assert_receive {:mmo_reliable, _, 1, %Session.SessionStart{} = start}, 5000
        await(ctx.scene, &(&1.tick >= start.server_tick + 3))
        stop_supervised!(Scene)
      end)

    File.write!(Path.join(System.fetch_env!("IS_CACHE"), "real-clock.jsonl"), log)

    rows =
      log
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "{"))
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["schema"] == "voxim-scene-v1"))

    costs = events(rows, "region_tick")
    assert length(costs) >= 4
    assert Enum.all?(costs, &(&1["stepped_count"] == 0))
    [bootstrap] = events(rows, "bootstrap_resident")
    assert bootstrap["prepare_start_us"] <= bootstrap["snapshot_received_us"]
    assert bootstrap["snapshot_received_us"] <= bootstrap["installed_us"]

    for {row, tick} <- Enum.with_index(costs, 1) do
      assert row["server_tick"] == tick
      assert row["due_us"] == bootstrap["installed_us"] + div(tick * 1_000_000 + 59, 60)
      assert row["start_us"] >= row["due_us"]
      assert row["end_us"] >= row["start_us"]
      assert row["tick_us"] <= row["end_us"] - row["start_us"] + 1
      assert row["nif_us"] <= row["tick_us"]
      assert row["elapsed_time_domain"] == "beam_monotonic_elapsed_us"
    end
  end

  defp events(rows, name), do: Enum.filter(rows, &(&1["event"] == name))

  test "production wall clock bounds flood displacement and executes only the legal jump slot" do
    ctx = start_scene(true)
    current = identity(2)
    stale = identity(1)
    Scene.join(ctx.scene, current, %{id: 10}, self())
    assert_receive {:mmo_reliable, ^current, 1, %Session.SessionStart{} = start}, 5000
    Player.time_probe(player(ctx.scene, current), current, %Session.TimeProbe{request_id: 1, client_send_us: 1})
    Player.ready(player(ctx.scene, current), current, start.baseline_transaction_seq, start.collision_revision)
    assert_receive {:mmo_reliable, ^current, 1, %Session.InputStart{} = input_start}, 5000

    batch = %Movement.InputBatch{identity: current, frames: [frame(1, 0, -32767, 1)]}
    {:ok, wire} = Movement.Codec.encode(batch)
    wire = IO.iodata_to_binary(wire)
    <<header::binary-size(5), body_length::32, body::binary>> = wire
    # Extra dt, speed and position bytes are rejected at the actual wire decoder.
    for forged <- [<<10.0::float-64>>, <<10000.0::float-64>>, <<9999.0::float-64, 9999.0::float-64, 9999.0::float-64>>] do
      injected = <<header::binary, body_length + byte_size(forged)::32, body::binary, forged::binary>>
      assert {:error, :invalid_m1_message} = Movement.Codec.decode(injected)
    end
    {:ok, decoded} = Movement.Codec.decode(wire)
    before_us = System.monotonic_time(:microsecond)
    before = observe(ctx.scene)
    for _ <- 1..1000, do: Player.input(player(ctx.scene, current), current, decoded)
    for _ <- 1..1000, do: Player.input(player(ctx.scene, current), stale, %{decoded | identity: stale})
    Scene.leave(ctx.scene, stale)
    Player.ready(player(ctx.scene, current), stale, 0, 1)
    Player.input(player(ctx.scene, current), current, %{decoded | frames: [frame(10000, 0, -32767, 1)]})
    Player.input(player(ctx.scene, current), current, %{decoded | frames: [frame(1, 32767, 0, 1)]})

    after_run = await(ctx.scene, &(&1.tick >= input_start.origin_tick + 90))
    after_us = System.monotonic_time(:microsecond)
    stop_supervised!(Scene)
    [character] = after_run.characters
    assert character.identity == current
    assert after_run.old_identity >= 1001
    assert after_run.rejected_inputs == 1
    assert character.processed_input_seq == 1
    assert character.simulation_tick == input_start.origin_tick
    assert character.pending_inputs == 1
    assert after_run.physics_steps - before.physics_steps <= div((after_us - before_us) * 60, 1_000_000) + 1
    {x0, _, z0} = hd(before.characters).state.position
    {x1, _, z1} = character.state.position
    distance = :math.sqrt((x1 - x0) ** 2 + (z1 - z0) ** 2)
    assert distance > 0.0
    assert distance <= start.profile.speed * ((after_us - before_us) / 1_000_000 + 1 / 60)

    steps = native_steps([])
    jumps = for {arguments, result} <- steps, {10, _, {_, _, 1}} <- arguments, do: result
    assert length(jumps) == 1
    assert [{10, {_, {_, jump_speed, _}, 0}}] = hd(jumps)
    assert jump_speed > 0.0
    IO.puts("M1_WALL_CLOCK_NEGATIVE " <> Jason.encode!(%{
      elapsed_us: after_us - before_us, physics_steps: after_run.physics_steps - before.physics_steps,
      horizontal_displacement_m: distance, speed_limit_mps: start.profile.speed,
      duplicate_batches: 1000, stale_batches: 1000, malformed_authority_fields_rejected: 3,
      old_identity: after_run.old_identity, rejected_inputs: after_run.rejected_inputs,
      legal_jump_slots: 1, native_jump_calls: length(jumps), origin_tick: input_start.origin_tick,
      final_tick: after_run.tick, final_processed_seq: character.processed_input_seq,
      time_domain: "production_scene_beam_monotonic_us", boundary: "decoded_scene_input_not_authenticated_transport"
    }))
  end

  defp native_steps(acc) do
    receive do
      {:p1_step, arguments, result} -> native_steps([{arguments, result} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
