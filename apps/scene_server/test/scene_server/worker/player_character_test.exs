defmodule SceneServer.PlayerCharacterTest do
  use ExUnit.Case, async: false

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

  test "zero-velocity movement broadcasts the authoritative stop location" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    location = {4.0, 5.0, 6.0}
    state = movement_state(aoi_ref)

    assert {:reply, {:ok, ""}, %{last_location: ^location}} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement, 100, location, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}},
               {self(), make_ref()},
               state
             )

    assert_receive {:aoi_cast, {:self_move, ^location}}
  end

  test "non-zero velocity movement does not emit an immediate stop broadcast" do
    {:ok, aoi_ref} = start_supervised({FakeAoi, self()})
    location = {7.0, 8.0, 9.0}
    state = movement_state(aoi_ref)

    assert {:reply, {:ok, ""}, %{last_location: ^location}} =
             SceneServer.PlayerCharacter.handle_call(
               {:movement, 100, location, {15.0, 0.0, 0.0}, {0.0, 0.0, 0.0}},
               {self(), make_ref()},
               state
             )

    refute_receive {:aoi_cast, {:self_move, _location}}, 50
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
      last_location: location
    }
  end
end
