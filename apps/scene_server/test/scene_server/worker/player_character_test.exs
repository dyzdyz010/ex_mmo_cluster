defmodule SceneServer.PlayerCharacterTest do
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Movement.{CorrectionFlags, InputFrame, Profile, RemoteSnapshot, State}

  defmodule FakeAoi do
    use GenServer

    def start_link(notify_pid) do
      GenServer.start_link(__MODULE__, notify_pid)
    end

    @impl true
    def init(notify_pid) do
      {:ok, notify_pid}
    end

    @impl true
    def handle_cast(message, notify_pid) do
      send(notify_pid, {:aoi_cast, message})
      {:noreply, notify_pid}
    end
  end

  defmodule FakeConnection do
    use GenServer

    def start_link(notify_pid) do
      GenServer.start_link(__MODULE__, notify_pid)
    end

    @impl true
    def init(notify_pid), do: {:ok, notify_pid}

    @impl true
    def handle_cast(message, notify_pid) do
      send(notify_pid, {:connection_cast, message})
      {:noreply, notify_pid}
    end
  end

  defmodule FakeAckConnection do
    use GenServer

    def start_link(notify_pid) do
      GenServer.start_link(__MODULE__, notify_pid)
    end

    @impl true
    def init(notify_pid), do: {:ok, notify_pid}

    @impl true
    def handle_cast(message, notify_pid) do
      send(notify_pid, {:movement_ack_cast, message})
      {:noreply, notify_pid}
    end
  end

  test "init migrates legacy dev seed center height to avatar center spawn" do
    cid = System.unique_integer([:positive])

    assert {:ok, state, {:continue, {:load, _timestamp}}} =
             SceneServer.PlayerCharacter.init(
               {cid, self(), :os.system_time(:millisecond),
                %{name: "legacy", position: {750.0, 750.0, 100.0}}}
             )

    assert state.character_profile.position == {750.0, 750.0, 185.0}
    assert state.spawn_location == {750.0, 750.0, 185.0}
    assert state.movement_state.position == {750.0, 750.0, 185.0}
  end

  test "movement_input is latched and authoritative tick broadcasts ack + snapshot" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    state = movement_state(aoi_ref, connection_pid)

    frame = %InputFrame{
      seq: 1,
      client_tick: 1,
      dt_ms: 100,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    assert {:reply, {:ok, :accepted}, latched_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, frame},
               {self(), make_ref()},
               state
             )

    assert latched_state.last_input_seq == 1
    assert latched_state.last_client_tick == 1
    assert latched_state.latched_input.seq == 1

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, latched_state)

    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = snapshot}}
    assert_receive {:connection_cast, {:movement_ack, ack}}
    assert snapshot.cid == 42
    assert snapshot.server_tick == 1
    assert snapshot.server_state_ms == ack.server_state_ms
    assert snapshot.server_state_ms > 0
    assert snapshot.position == ack.position
    assert is_integer(ack.scene_ack_ms)
    assert ack.scene_ack_ms > 0
    assert is_integer(ack.scene_input_age_ms)
    assert ack.scene_input_age_ms >= 0
    assert ack.scene_queue_len == 1
    assert ack.scene_replay_count == 1
    assert is_integer(ack.scene_mailbox_len)
    assert ack.scene_mailbox_len >= 0
    assert is_integer(ack.scene_tick_drift_ms)
    assert next_state.last_location == ack.position
  end

  test "buffered movement input drains on authority tick without actor mailbox casts" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    state = movement_state(aoi_ref, connection_pid)

    frames =
      for seq <- 1..12 do
        %InputFrame{
          seq: seq,
          client_tick: seq,
          dt_ms: 16,
          input_dir: {1.0, 0.0},
          speed_scale: 1.0,
          movement_flags: 0
        }
      end

    Enum.each(frames, fn frame ->
      assert :accepted = SceneServer.PlayerCharacter.submit_movement_input(self(), frame)
    end)

    refute_receive {:movement_input, _frame}, 20

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, state)

    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = snapshot}}
    assert_receive {:connection_cast, {:movement_ack, ack}}
    assert snapshot.cid == 42
    assert ack.ack_seq == 12
    assert ack.scene_queue_len == 8
    assert ack.scene_replay_count == 8
    assert ack.scene_dropped_input_count == 4
    assert next_state.last_ack_seq == 12
  end

  test "submit_movement_input rejects dead player pids without leaving buffered input" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    frame = %InputFrame{
      seq: 1,
      client_tick: 1,
      dt_ms: 16,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    assert {:error, :invalid_player} =
             SceneServer.PlayerCharacter.submit_movement_input(pid, frame)

    assert SceneServer.PlayerCharacter.pending_movement_input_count(pid) == 0
  end

  test "movement ack can use a dedicated fast path without rerouting AOI snapshots" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    {:ok, movement_ack_pid} = start_supervised({FakeAckConnection, self()})

    state =
      movement_state(aoi_ref, connection_pid)
      |> Map.put(:movement_ack_pid, movement_ack_pid)

    frame = %InputFrame{
      seq: 1,
      client_tick: 1,
      dt_ms: 100,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    assert {:reply, {:ok, :accepted}, latched_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, frame},
               {self(), make_ref()},
               state
             )

    assert {:noreply, _next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, latched_state)

    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{}}}
    assert_receive {:movement_ack_cast, {:movement_ack, ack}}
    assert ack.ack_seq == 1
    refute_receive {:connection_cast, {:movement_ack, _}}, 20
  end

  test "movement state time advances by the authoritative fixed tick, not send time" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    state = movement_state(aoi_ref, connection_pid)

    first_frame = %InputFrame{
      seq: 1,
      client_tick: 1,
      dt_ms: 100,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    second_frame = %{first_frame | seq: 2, client_tick: 2}

    assert {:reply, {:ok, :accepted}, state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, first_frame},
               {self(), make_ref()},
               state
             )

    assert {:noreply, state} = SceneServer.PlayerCharacter.handle_info(:movement_tick, state)
    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = first_snapshot}}
    assert_receive {:connection_cast, {:movement_ack, first_ack}}

    assert {:reply, {:ok, :accepted}, state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, second_frame},
               {self(), make_ref()},
               state
             )

    assert {:noreply, _state} = SceneServer.PlayerCharacter.handle_info(:movement_tick, state)
    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = second_snapshot}}
    assert_receive {:connection_cast, {:movement_ack, second_ack}}

    assert first_snapshot.server_state_ms == first_ack.server_state_ms
    assert second_snapshot.server_state_ms == second_ack.server_state_ms

    assert second_ack.server_state_ms - first_ack.server_state_ms ==
             state.movement_profile.fixed_dt_ms
  end

  test "idle movement tick publishes a fresh AOI snapshot when the remote timeline is stale" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})

    stale_movement_state = %{
      State.idle({1.0, 2.0, 3.0})
      | tick: 10,
        server_state_ms: :os.system_time(:millisecond) - 5_000
    }

    state =
      movement_state(aoi_ref, connection_pid)
      |> Map.put(:movement_state, stale_movement_state)
      |> Map.put(:last_location, stale_movement_state.position)
      |> Map.put(:last_remote_snapshot_sent_at_ms, System.monotonic_time(:millisecond) - 10_000)

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, state)

    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = snapshot}}, 300
    assert snapshot.cid == 42
    assert snapshot.position == stale_movement_state.position
    assert snapshot.movement_mode == :grounded
    assert snapshot.server_tick > stale_movement_state.tick
    assert snapshot.server_state_ms > stale_movement_state.server_state_ms
    assert next_state.movement_state.tick == snapshot.server_tick
    assert next_state.movement_state.server_state_ms == snapshot.server_state_ms
    assert next_state.last_remote_snapshot_sent_at_ms > state.last_remote_snapshot_sent_at_ms
    refute_receive {:connection_cast, {:movement_ack, _ack}}, 100
  end

  test "single movement tick ignores spoofed client_tick when assigning auth tick" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    state = movement_state(aoi_ref, connection_pid)

    frame = %InputFrame{
      seq: 1,
      client_tick: 9_999,
      dt_ms: 250,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    assert {:reply, {:ok, :accepted}, latched_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, frame},
               {self(), make_ref()},
               state
             )

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, latched_state)

    assert next_state.movement_state.tick == 1
    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = snapshot}}
    assert_receive {:connection_cast, {:movement_ack, ack}}
    assert snapshot.server_tick == 1
    assert ack.auth_tick == 1
    assert ack.ack_seq == 1
  end

  test "queued replay ignores spoofed client_tick sequence when assigning auth ticks" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    state = movement_state(aoi_ref, connection_pid)

    frames =
      for seq <- 1..3 do
        %InputFrame{
          seq: seq,
          client_tick: 10_000 + seq,
          dt_ms: 250,
          input_dir: {1.0, 0.0},
          speed_scale: 1.0,
          movement_flags: 0
        }
      end

    state =
      Enum.reduce(frames, state, fn frame, acc ->
        {:reply, {:ok, :accepted}, next_state} =
          SceneServer.PlayerCharacter.handle_call(
            {:movement_input, frame},
            {self(), make_ref()},
            acc
          )

        next_state
      end)

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, state)

    assert next_state.movement_state.tick == 3
    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = snapshot}}
    assert_receive {:connection_cast, {:movement_ack, ack}}
    assert snapshot.server_tick == 3
    assert ack.auth_tick == 3
    assert ack.ack_seq == 3
    assert ack.scene_queue_len == 3
    assert ack.scene_replay_count == 3
    assert is_integer(ack.scene_input_age_ms)
    assert is_integer(ack.scene_mailbox_len)
  end

  test "stale movement_input is rejected before touching AOI" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})

    state =
      movement_state(aoi_ref, self())
      |> Map.put(:last_input_seq, 5)
      |> Map.put(:last_client_tick, 5)

    frame = %InputFrame{
      seq: 5,
      client_tick: 6,
      dt_ms: 100,
      input_dir: {0.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 2
    }

    assert {:reply, {:error, :stale_input_seq}, returned_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, frame},
               {self(), make_ref()},
               state
             )

    assert returned_state.last_input_seq == 5
    refute_receive {:aoi_cast, _message}, 50
  end

  test "far future movement_input is rejected before poisoning the expected seq" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})

    state =
      movement_state(aoi_ref, self())
      |> Map.put(:last_input_seq, 5)
      |> Map.put(:last_client_tick, 5)

    frame = %InputFrame{
      seq: 100_000,
      client_tick: 100_000,
      dt_ms: 100,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    assert {:reply, {:error, :input_seq_too_far}, returned_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, frame},
               {self(), make_ref()},
               state
             )

    assert returned_state.last_input_seq == 5
    assert returned_state.last_client_tick == 5
    refute_receive {:aoi_cast, _message}, 50
  end

  test "legacy player chat call is rejected before touching AOI" do
    observe_log = Path.join(System.tmp_dir!(), "player-chat-legacy-#{unique_id()}.log")
    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.put_env(:scene_server, :cli_observe_log, observe_log)
    File.rm(observe_log)

    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    state = movement_state(aoi_ref, self())

    try do
      assert {:reply, {:error, :chat_runtime_required}, returned_state} =
               SceneServer.PlayerCharacter.handle_call(
                 {:chat_say, 42, "tester", "legacy scene chat"},
                 {self(), make_ref()},
                 state
               )

      assert returned_state == state
      refute_receive {:aoi_cast, _message}, 50

      CliObserve.flush()
      log = File.read!(observe_log)
      assert log =~ ~s(event="player_chat_legacy_rejected")
      assert log =~ "chat_runtime_required"
    after
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end
  end

  test "queued movement inputs are replayed in a single tick and advance auth_tick" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    state = movement_state(aoi_ref, connection_pid)

    frames =
      for seq <- 1..3 do
        %InputFrame{
          seq: seq,
          client_tick: seq,
          dt_ms: 100,
          input_dir: {1.0, 0.0},
          speed_scale: 1.0,
          movement_flags: 0
        }
      end

    state =
      Enum.reduce(frames, state, fn frame, acc ->
        {:reply, {:ok, :accepted}, next_state} =
          SceneServer.PlayerCharacter.handle_call(
            {:movement_input, frame},
            {self(), make_ref()},
            acc
          )

        next_state
      end)

    assert length(state.input_queue) == 3

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, state)

    assert next_state.input_queue == []
    assert next_state.last_ack_seq == 3
    assert next_state.movement_state.tick == 3

    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = snapshot}}
    assert_receive {:connection_cast, {:movement_ack, ack}}
    assert snapshot.server_tick == 3
    assert ack.auth_tick == 3
    assert ack.ack_seq == 3
    # three steps of eastward input should produce a distinctly positive x
    {x, _y, _z} = snapshot.position
    assert x > 1.0
  end

  test "queued movement burst resolves voxel collision after each replayed step" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    parent = self()
    location = {750.0, 750.0, 185.0}

    query_fun = fn attrs ->
      send(parent, {:collision_query, attrs})
      {:ok, %{occupied: [], chunk_version: 1}}
    end

    state =
      movement_state(aoi_ref, connection_pid)
      |> Map.put(:last_location, location)
      |> Map.put(:movement_state, State.idle(location))
      |> Map.put(:voxel_collision_opts, query_fun: query_fun)

    frames =
      for seq <- 1..3 do
        %InputFrame{
          seq: seq,
          client_tick: seq,
          dt_ms: 100,
          input_dir: {1.0, 0.0},
          speed_scale: 1.0,
          movement_flags: 0
        }
      end

    state =
      Enum.reduce(frames, state, fn frame, acc ->
        {:reply, {:ok, :accepted}, next_state} =
          SceneServer.PlayerCharacter.handle_call(
            {:movement_input, frame},
            {self(), make_ref()},
            acc
          )

        next_state
      end)

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, state)

    assert next_state.last_ack_seq == 3
    assert next_state.movement_state.tick == 3
    assert_receive {:collision_query, %{chunk_coord: {0, 0, 0}, samples: samples}}
    assert is_list(samples)
    assert_receive {:collision_query, %{chunk_coord: {0, 0, 0}, samples: samples}}
    assert is_list(samples)
    assert_receive {:collision_query, %{chunk_coord: {0, 0, 0}, samples: samples}}
    assert is_list(samples)
    refute_receive {:collision_query, _attrs}, 100
  end

  test "queued stationary inputs do not query voxel collision" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    parent = self()
    location = {750.0, 750.0, 185.0}

    query_fun = fn attrs ->
      send(parent, {:collision_query, attrs})
      {:ok, %{occupied: [], chunk_version: 1}}
    end

    state =
      movement_state(aoi_ref, connection_pid)
      |> Map.put(:last_location, location)
      |> Map.put(:movement_state, State.idle(location))
      |> Map.put(:voxel_collision_opts, query_fun: query_fun)

    frames =
      for seq <- 1..3 do
        %InputFrame{
          seq: seq,
          client_tick: seq,
          dt_ms: 100,
          input_dir: {0.0, 0.0},
          speed_scale: 1.0,
          movement_flags: 0b10
        }
      end

    state =
      Enum.reduce(frames, state, fn frame, acc ->
        {:reply, {:ok, :accepted}, next_state} =
          SceneServer.PlayerCharacter.handle_call(
            {:movement_input, frame},
            {self(), make_ref()},
            acc
          )

        next_state
      end)

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, state)

    assert next_state.last_ack_seq == 3
    assert next_state.movement_state.position == location
    refute_receive {:collision_query, _attrs}, 100
  end

  test "jump input is consumed as one-shot latch after authoritative tick" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    state = movement_state(aoi_ref, connection_pid)

    frame = %InputFrame{
      seq: 1,
      client_tick: 1,
      dt_ms: 100,
      input_dir: {0.0, 0.0},
      speed_scale: 1.0,
      movement_flags: Bitwise.bor(InputFrame.jump_flag(), 0b10)
    }

    assert {:reply, {:ok, :accepted}, latched_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, frame},
               {self(), make_ref()},
               state
             )

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, latched_state)

    assert next_state.movement_state.movement_mode == :airborne
    refute InputFrame.jumping?(next_state.latched_input)
  end

  test "queued jump remains authoritative when idle frames arrive before tick" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    location = {750.0, 750.0, 185.0}

    state =
      movement_state(aoi_ref, connection_pid)
      |> Map.put(:last_location, location)
      |> Map.put(:movement_state, State.idle(location))
      |> Map.put(:voxel_collision_opts, query_fun: fn _attrs -> {:ok, %{occupied: []}} end)

    frames = [
      %InputFrame{
        seq: 1,
        client_tick: 1,
        dt_ms: 100,
        input_dir: {0.0, 0.0},
        speed_scale: 1.0,
        movement_flags: Bitwise.bor(InputFrame.jump_flag(), 0b10)
      },
      %InputFrame{
        seq: 2,
        client_tick: 2,
        dt_ms: 100,
        input_dir: {0.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0b10
      },
      %InputFrame{
        seq: 3,
        client_tick: 3,
        dt_ms: 100,
        input_dir: {0.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0b10
      }
    ]

    state =
      Enum.reduce(frames, state, fn frame, acc ->
        {:reply, {:ok, :accepted}, next_state} =
          SceneServer.PlayerCharacter.handle_call(
            {:movement_input, frame},
            {self(), make_ref()},
            acc
          )

        next_state
      end)

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, state)

    assert next_state.last_ack_seq == 3
    assert next_state.movement_state.tick == 3
    assert next_state.movement_state.movement_mode == :airborne
    refute InputFrame.jumping?(next_state.latched_input)
  end

  test "AOI adapter DOWN is rebuilt and registered again" do
    SceneServer.TestAoiRuntime.ensure_started!()
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})

    cid = System.unique_integer([:positive])
    location = {1.0, 2.0, 3.0}

    {:ok, aoi_ref} =
      SceneServer.AoiManager.add_aoi_item(
        cid,
        0,
        location,
        connection_pid,
        self(),
        %{kind: :player, name: "tester"}
      )

    monitor_ref = Process.monitor(aoi_ref)
    GenServer.call(aoi_ref, :exit)
    assert_receive {:DOWN, ^monitor_ref, :process, ^aoi_ref, :normal}, 300

    state =
      movement_state(aoi_ref, connection_pid)
      |> Map.put(:cid, cid)
      |> Map.put(:aoi_monitor_ref, monitor_ref)
      |> Map.put(:character_profile, %{name: "tester", position: location})

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(
               {:DOWN, monitor_ref, :process, aoi_ref, :normal},
               state
             )

    on_exit(fn -> stop_real_aoi_item(next_state.aoi_ref) end)

    refute next_state.aoi_ref == aoi_ref
    assert Process.alive?(next_state.aoi_ref)

    [registered] = SceneServer.AoiManager.get_items_with_cids([cid])
    assert registered == next_state.aoi_ref
  end

  test "partition window update is stored and forwarded to current AOI adapter" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    partition_window = partition_window()
    state = movement_state(aoi_ref, self())

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_cast({:partition_window, partition_window}, state)

    assert next_state.partition_window_dto == partition_window
    assert is_integer(next_state.partition_updated_at_ms)
    assert_receive {:aoi_cast, {:partition_window, ^partition_window}}
  end

  test "nil partition window update preserves the previous authoritative window" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    partition_window = partition_window()

    state =
      movement_state(aoi_ref, self())
      |> Map.put(:partition_window_dto, partition_window)
      |> Map.put(:partition_updated_at_ms, 123)

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_cast({:partition_window, nil}, state)

    assert next_state.partition_window_dto == partition_window
    assert next_state.partition_updated_at_ms == 123
    refute_receive {:aoi_cast, {:partition_window, nil}}, 100
  end

  test "AOI adapter recovery replays the latest partition window" do
    SceneServer.TestAoiRuntime.ensure_started!()
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})

    cid = System.unique_integer([:positive])
    location = {100.0, 0.0, 0.0}
    partition_window = partition_window()

    {:ok, aoi_ref} =
      SceneServer.AoiManager.add_aoi_item(
        cid,
        0,
        location,
        connection_pid,
        self(),
        %{kind: :player, name: "tester"}
      )

    monitor_ref = Process.monitor(aoi_ref)
    GenServer.call(aoi_ref, :exit)
    assert_receive {:DOWN, ^monitor_ref, :process, ^aoi_ref, :normal}, 300

    state =
      movement_state(aoi_ref, connection_pid)
      |> Map.put(:cid, cid)
      |> Map.put(:aoi_monitor_ref, monitor_ref)
      |> Map.put(:character_profile, %{name: "tester", position: location})
      |> Map.put(:last_location, location)
      |> Map.put(:movement_state, SceneServer.Movement.State.idle(location))
      |> Map.put(:partition_window_dto, partition_window)

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(
               {:DOWN, monitor_ref, :process, aoi_ref, :normal},
               state
             )

    on_exit(fn -> stop_real_aoi_item(next_state.aoi_ref) end)

    assert next_state.partition_window_dto == partition_window
    refute next_state.aoi_ref == aoi_ref

    aoi_state = :sys.get_state(next_state.aoi_ref)
    assert aoi_state.partition_interest.logical_scene_id == partition_window.logical_scene_id
    assert aoi_state.partition_interest.near_query_count == 1
    assert aoi_state.partition_interest.halo_query_count == 1
  end

  test "connection monitor setup accepts remote connection pids" do
    assert is_reference(
             SceneServer.PlayerCharacter.connection_monitor_ref(self(), fn _pid -> :remote@app end)
           )
  end

  test "authoritative movement tick preserves correction flags from intent ack path" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})

    default_profile = Profile.default()
    movement_profile = %Profile{default_profile | max_speed: 0.0, max_accel: 0.0}

    state =
      movement_state(aoi_ref, connection_pid)
      |> Map.put(:movement_profile, movement_profile)

    frame = %InputFrame{
      seq: 1,
      client_tick: 1,
      dt_ms: 100,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    assert {:reply, {:ok, :accepted}, latched_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, frame},
               {self(), make_ref()},
               state
             )

    assert {:noreply, _next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, latched_state)

    assert_receive {:connection_cast, {:movement_ack, ack}}
    assert CorrectionFlags.collision_push?(ack.correction_flags)
  end

  test "a burst of queued inputs produces the same final state as stepping one per tick" do
    # Simulate jittery arrival: three inputs landing together in one wall-clock tick
    # should advance the server to the exact same position/velocity as three inputs
    # spaced one-per-tick. This is the "server sees the same input stream as the
    # client predictor" invariant that matters for reconcile divergence.
    {:ok, aoi_ref_a} = start_supervised({FakeAoi, self()}, id: :aoi_a)
    {:ok, conn_a} = start_supervised({FakeConnection, self()}, id: :conn_a)
    {:ok, aoi_ref_b} = start_supervised({FakeAoi, self()}, id: :aoi_b)
    {:ok, conn_b} = start_supervised({FakeConnection, self()}, id: :conn_b)

    frames =
      for {seq, dir} <- [{1, {1.0, 0.0}}, {2, {1.0, 0.5}}, {3, {0.5, 1.0}}] do
        %InputFrame{
          seq: seq,
          client_tick: seq,
          dt_ms: 100,
          input_dir: dir,
          speed_scale: 1.0,
          movement_flags: 0
        }
      end

    # Path A: one input per tick (3 wall-clock ticks)
    state_a =
      Enum.reduce(frames, movement_state(aoi_ref_a, conn_a), fn frame, acc ->
        {:reply, {:ok, :accepted}, s} =
          SceneServer.PlayerCharacter.handle_call(
            {:movement_input, frame},
            {self(), make_ref()},
            acc
          )

        {:noreply, s} = SceneServer.PlayerCharacter.handle_info(:movement_tick, s)
        s
      end)

    # Path B: all three inputs queued together, drained in one tick
    state_b0 =
      Enum.reduce(frames, movement_state(aoi_ref_b, conn_b), fn frame, acc ->
        {:reply, {:ok, :accepted}, s} =
          SceneServer.PlayerCharacter.handle_call(
            {:movement_input, frame},
            {self(), make_ref()},
            acc
          )

        s
      end)

    {:noreply, state_b} = SceneServer.PlayerCharacter.handle_info(:movement_tick, state_b0)

    assert state_a.movement_state.tick == state_b.movement_state.tick
    assert positions_match?(state_a.movement_state.position, state_b.movement_state.position)
    assert vectors_match?(state_a.movement_state.velocity, state_b.movement_state.velocity)
  end

  defp positions_match?({x1, y1, z1}, {x2, y2, z2}, eps \\ 1.0e-9) do
    abs(x1 - x2) < eps and abs(y1 - y2) < eps and abs(z1 - z2) < eps
  end

  defp vectors_match?(a, b, eps \\ 1.0e-9), do: positions_match?(a, b, eps)

  test "idle tick with residual velocity flushes a zero-velocity stop snapshot" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})

    initial = movement_state(aoi_ref, connection_pid)

    state =
      initial
      |> Map.put(:movement_state, %{
        initial.movement_state
        | velocity: {0.5, 0.0, 0.0},
          acceleration: {0.0, 0.0, 0.0}
      })
      |> Map.put(:latched_input, %InputFrame{
        seq: 7,
        client_tick: 7,
        dt_ms: 100,
        input_dir: {0.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0b10
      })
      |> Map.put(:last_input_seq, 7)
      |> Map.put(:last_ack_seq, 7)

    assert {:noreply, next_state} =
             SceneServer.PlayerCharacter.handle_info(:movement_tick, state)

    assert next_state.movement_state.velocity == {0.0, 0.0, 0.0}
    assert next_state.movement_state.acceleration == {0.0, 0.0, 0.0}
    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = snapshot}}
    assert snapshot.velocity == {0.0, 0.0, 0.0}
  end

  test "skill hit reduces hp and broadcasts combat state" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    state = movement_state(aoi_ref, connection_pid)

    assert {:reply, {:ok, 75}, next_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:apply_damage_effect, 7, 1, 25, {1.0, 2.0, 3.0}},
               {self(), make_ref()},
               state
             )

    assert next_state.combat_state.hp == 75
    assert_receive {:aoi_cast, {:combat_resolved, 7, 42, 1, 25, 75, {1.0, 2.0, 3.0}}}
    assert_receive {:aoi_cast, {:health_update, 42, 75, 100, true}}
  end

  defp movement_state(aoi_ref, connection_pid) do
    dev_attrs = %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20}
    location = {1.0, 2.0, 3.0}

    {:ok, physys_ref} = SceneServer.Native.SceneOps.new_physics_system()

    {:ok, character_data_ref} =
      SceneServer.Native.SceneOps.new_character_data(
        42,
        "tester",
        location,
        dev_attrs,
        physys_ref
      )

    %{
      cid: 42,
      status: :in_scene,
      logical_scene_id: 1,
      aoi_ref: aoi_ref,
      connection_pid: connection_pid,
      movement_ack_pid: connection_pid,
      character_data_ref: character_data_ref,
      physys_ref: physys_ref,
      spawn_location: location,
      last_location: location,
      movement_state: SceneServer.Movement.State.idle(location),
      movement_profile: SceneServer.Movement.Profile.default(),
      combat_profile: SceneServer.Combat.Profile.default(),
      combat_state: SceneServer.Combat.State.new(SceneServer.Combat.Profile.default()),
      latched_input: %SceneServer.Movement.InputFrame{
        seq: 0,
        client_tick: 0,
        dt_ms: 100,
        input_dir: {0.0, 0.0},
        speed_scale: 1.0,
        movement_flags: 0b10
      },
      input_queue: [],
      last_input_seq: 0,
      last_ack_seq: 0,
      last_client_tick: 0,
      last_input_received_at_ms: System.monotonic_time(:millisecond) - 100,
      movement_timer: nil,
      last_remote_snapshot_sent_at_ms: System.monotonic_time(:millisecond),
      respawn_timer: nil,
      aoi_monitor_ref: nil,
      partition_window_dto: nil,
      partition_updated_at_ms: nil,
      character_profile: %{name: "tester", position: location}
    }
  end

  defp partition_window do
    %{
      logical_scene_id: 7,
      center_chunk: {0, 0, 0},
      near_radius: 0,
      halo_radius: 1,
      route_entries: [
        %{
          chunk_coord: {0, 0, 0},
          tier: :near,
          status: :assigned,
          region_id: 10,
          lease_id: 100,
          assigned_scene_node: node()
        },
        %{
          chunk_coord: {1, 0, 0},
          tier: :halo,
          status: :assigned,
          region_id: 20,
          lease_id: 200,
          assigned_scene_node: node()
        }
      ]
    }
  end

  defp stop_real_aoi_item(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :exit)
      wait_until_dead(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  defp wait_until_dead(pid, attempts \\ 40)

  defp wait_until_dead(pid, attempts) when attempts > 0 do
    if Process.alive?(pid) do
      Process.sleep(25)
      wait_until_dead(pid, attempts - 1)
    else
      :ok
    end
  end

  defp wait_until_dead(_pid, 0), do: :ok

  defp unique_id, do: System.unique_integer([:positive])
end
