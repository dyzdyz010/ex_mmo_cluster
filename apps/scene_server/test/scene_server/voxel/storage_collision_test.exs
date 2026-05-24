defmodule SceneServer.Voxel.StorageCollisionTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.{NormalBlockData, Storage}

  test "micro_slot_occupied? treats solid macros as fully occupied" do
    storage =
      Storage.empty(1, {0, 0, 0})
      |> Storage.put_solid_block({1, 0, 0}, NormalBlockData.new(2))

    assert Storage.micro_slot_occupied?(storage, {1, 0, 0}, 0)
    assert Storage.micro_slot_occupied?(storage, {1, 0, 0}, 511)
    refute Storage.micro_slot_occupied?(storage, {0, 0, 0}, 0)
  end

  test "micro_slot_occupied? reads refined occupancy words" do
    storage =
      Storage.empty(1, {0, 0, 0})
      |> Storage.put_micro_block({2, 0, 0}, 5, %{material_id: 7})

    assert Storage.micro_slot_occupied?(storage, {2, 0, 0}, 5)
    refute Storage.micro_slot_occupied?(storage, {2, 0, 0}, 6)
  end
end
