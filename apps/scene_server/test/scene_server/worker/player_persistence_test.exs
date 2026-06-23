defmodule SceneServer.PlayerPersistenceTest do
  @moduledoc """
  玩法 loop Phase 0:PlayerCharacter 运行态落库端到端(handle_info(:persist_checkpoint) /
  terminate → DataService.CharacterStore → DB)。DB-backed。
  """
  use ExUnit.Case, async: false

  alias DataService.CharacterStore
  alias DataService.Repo
  alias DataService.Schema.Account
  alias DataService.Schema.Character
  alias SceneServer.Combat.Profile, as: CombatProfile
  alias SceneServer.Combat.State, as: CombatState
  alias SceneServer.PlayerCharacter

  setup do
    SceneServer.TestVoxelRuntime.ensure_started!()
    Repo.delete_all(Character)
    Repo.delete_all(Account)
    :ok
  end

  defp insert_character(id) do
    {:ok, _} =
      %Character{}
      |> Character.changeset(%{
        id: id,
        account: 1,
        name: "char-#{id}",
        title: "t",
        base_attrs: %{},
        battle_attrs: %{},
        position: %{"x" => 750.0, "y" => 750.0, "z" => 185.0},
        hp: 500,
        sp: 100,
        mp: 100
      })
      |> Repo.insert()

    :ok
  end

  # Minimal state with exactly the fields persist_runtime_state + the checkpoint
  # handler read (cid / last_location / combat_state / checkpoint_timer).
  defp persist_state(cid, location) do
    %{
      cid: cid,
      last_location: location,
      combat_state: %{CombatState.new(CombatProfile.default()) | hp: 271},
      checkpoint_timer: nil
    }
  end

  test "periodic checkpoint writes the player's current position + hp to the DB" do
    cid = System.unique_integer([:positive])
    insert_character(cid)

    {:noreply, next} =
      PlayerCharacter.handle_info(:persist_checkpoint, persist_state(cid, {300.0, 12.5, 64.0}))

    # Re-armed the checkpoint timer.
    assert is_reference(next.checkpoint_timer)

    # Position + hp landed (the gate's load path reads `position` back on next login).
    assert CharacterStore.persisted_position(cid) == {300.0, 12.5, 64.0}
    assert CharacterStore.get_character(cid).hp == 271
  end

  test "checkpoint for an unknown character is a safe no-op (no crash)" do
    # No DB row for this cid → persist returns {:error, :not_found}, swallowed.
    {:noreply, next} =
      PlayerCharacter.handle_info(:persist_checkpoint, persist_state(424_242, {1.0, 2.0, 3.0}))

    assert is_reference(next.checkpoint_timer)
  end
end
