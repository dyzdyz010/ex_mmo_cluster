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

  test "movement_input returns authoritative ack and broadcasts remote snapshot" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    state = movement_state(aoi_ref)

    frame = %InputFrame{
      seq: 1,
      client_tick: 1,
      dt_ms: 100,
      input_dir: {1.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }

    assert {:reply, {:ok, ack}, next_state} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement_input, frame},
               {self(), make_ref()},
               state
             )

    assert ack.ack_seq == 1
    assert ack.auth_tick == 1
    assert next_state.last_input_seq == 1
    assert next_state.last_client_tick == 1
    assert next_state.last_location == ack.position

    assert_receive {:aoi_cast, {:self_move, %RemoteSnapshot{} = snapshot}}
    assert snapshot.cid == 42
    assert snapshot.server_tick == 1
    assert snapshot.position == ack.position
  end

  test "stale movement_input is rejected before touching AOI" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})

    state =
      movement_state(aoi_ref)
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

  defp movement_state(aoi_ref) do
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
      character_data_ref: character_data_ref,
      physys_ref: physys_ref,
      last_location: location,
      movement_state: SceneServer.Movement.State.idle(location),
      movement_profile: SceneServer.Movement.Profile.default(),
      last_input_seq: 0,
      last_client_tick: 0,
      last_server_input_at_ms: System.monotonic_time(:millisecond) - 100
    }
  end
end
