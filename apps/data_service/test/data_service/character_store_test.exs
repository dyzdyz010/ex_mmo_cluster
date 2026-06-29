defmodule DataService.CharacterStoreTest do
  @moduledoc """
  玩法 loop Phase 0:角色运行态持久化(位置/HP)round-trip。DB-backed。
  """
  use ExUnit.Case, async: false

  alias DataService.CharacterStore
  alias DataService.Repo
  alias DataService.Schema.Account
  alias DataService.Schema.Character

  setup do
    Repo.delete_all(Character)
    Repo.delete_all(Account)
    :ok
  end

  defp insert_character(id, position) do
    {:ok, character} =
      %Character{}
      |> Character.changeset(%{
        id: id,
        account: 1,
        name: "char-#{id}",
        title: "t",
        base_attrs: %{},
        battle_attrs: %{},
        position: position,
        hp: 500,
        sp: 100,
        mp: 100
      })
      |> Repo.insert()

    character
  end

  test "save_runtime_state patches position (tuple → map) and hp; round-trips" do
    insert_character(7001, %{"x" => 750.0, "y" => 750.0, "z" => 185.0})

    assert {:ok, updated} =
             CharacterStore.save_runtime_state(7001, %{position: {120.5, -3.0, 64.0}, hp: 317})

    assert updated.position == %{"x" => 120.5, "y" => -3.0, "z" => 64.0}
    assert updated.hp == 317

    # Read back from DB (the load path the gate uses reads `position`).
    assert CharacterStore.persisted_position(7001) == {120.5, -3.0, 64.0}
    assert CharacterStore.get_character(7001).hp == 317
  end

  test "save_runtime_state only patches given fields (identity untouched)" do
    insert_character(7002, %{"x" => 1.0, "y" => 2.0, "z" => 3.0})

    assert {:ok, updated} = CharacterStore.save_runtime_state(7002, %{position: {9.0, 9.0, 9.0}})

    # Name/account (identity) preserved; hp untouched (still seed 500).
    assert updated.name == "char-7002"
    assert updated.account == 1
    assert updated.hp == 500
    assert updated.position == %{"x" => 9.0, "y" => 9.0, "z" => 9.0}
  end

  test "save_runtime_state on a missing character → {:error, :not_found}" do
    assert {:error, :not_found} =
             CharacterStore.save_runtime_state(999_999, %{position: {0, 0, 0}})
  end

  test "persisted_position handles integer-keyed and missing positions" do
    insert_character(7003, %{"x" => 5.0, "y" => 6.0, "z" => 7.0})
    assert CharacterStore.persisted_position(7003) == {5.0, 6.0, 7.0}
    assert CharacterStore.persisted_position(424_242) == nil
  end
end
