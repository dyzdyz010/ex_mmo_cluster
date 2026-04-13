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

  test "skill hit reduces hp and broadcasts combat state" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    {:ok, connection_pid} = start_supervised({FakeConnection, self()})
    state = movement_state(aoi_ref, connection_pid)
    {:ok, skill} = SceneServer.Combat.Skill.fetch(1)

    assert {:reply, {:ok, 75}, next_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:apply_skill_hit, 7, skill, {1.0, 2.0, 3.0}},
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
      last_input_seq: 0,
      last_ack_seq: 0,
      last_client_tick: 0,
      last_input_received_at_ms: System.monotonic_time(:millisecond) - 100,
      movement_timer: nil,
      respawn_timer: nil
    }
  end
end
