defmodule SceneServer.PlayerCharacterTest do
  use ExUnit.Case, async: false

  alias SceneServer.Movement.{InputFrame, RemoteSnapshot}

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
    assert snapshot.position == ack.position
    assert next_state.last_location == ack.position
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
      aoi_ref: aoi_ref,
      connection_pid: connection_pid,
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
      respawn_timer: nil
    }
  end
end
