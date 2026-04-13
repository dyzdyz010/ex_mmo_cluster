defmodule SceneServer.Npc.ManagerTest do
  use ExUnit.Case, async: false

  defmodule FakePlayerRegistry do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      {:ok, %{players: %{}}}
    end

    @impl true
    def handle_call(:get_all_players, _from, state) do
      {:reply, {:ok, state.players}, state}
    end
  end

  setup do
    ensure_started(
      SceneServer.NpcActorSup,
      {SceneServer.NpcActorSup, name: SceneServer.NpcActorSup}
    )

    ensure_started(
      SceneServer.NpcManager,
      {SceneServer.Npc.Manager, name: SceneServer.NpcManager}
    )

    ensure_started(FakePlayerRegistry, {FakePlayerRegistry, []})
    :ok
  end

  test "manager can spawn an npc actor and return state summary" do
    assert {:ok, npc_pid} =
             GenServer.call(
               SceneServer.NpcManager,
               {:spawn_npc, 9001, [player_registry: FakePlayerRegistry, name: "Slime"]},
               5_000
             )

    assert {:ok, npcs} = GenServer.call(SceneServer.NpcManager, :get_all_npcs)
    assert Map.get(npcs, 9001) == npc_pid
    assert {:ok, summary} = GenServer.call(npc_pid, :get_state_summary)
    assert summary.npc_id == 9001
    assert summary.intent == :idle
  end

  defp ensure_started(name, spec) do
    case Process.whereis(name) do
      nil -> start_supervised!(spec)
      pid -> pid
    end
  end
end
