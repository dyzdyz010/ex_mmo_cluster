defmodule SceneServer.Voxel.ChunkCollisionQueryTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{ChunkProcess, NormalBlockData, Storage}

  test "collision_query returns occupied solid samples only" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, {1, 0, 0}, NormalBlockData.new(2))

    assert {:ok, result} =
             ChunkProcess.collision_query(chunk, %{
               samples: [
                 %{macro: {1, 0, 0}, micro_slot: 5},
                 %{macro: {0, 0, 0}, micro_slot: 5}
               ]
             })

    assert result.sample_count == 2
    assert result.occupied_count == 1
    assert [%{macro: {1, 0, 0}, micro_slot: 5, mode: :solid}] = result.occupied
  end

  test "collision_query reads refined micro occupancy" do
    storage =
      Storage.empty(1, {0, 0, 0})
      |> Storage.put_micro_block({2, 0, 0}, 5, %{material_id: 7})

    chunk =
      start_supervised!(
        {ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}, storage: storage}
      )

    assert {:ok, result} =
             ChunkProcess.collision_query(chunk, %{
               samples: [
                 %{macro: {2, 0, 0}, micro_slot: 5},
                 %{macro: {2, 0, 0}, micro_slot: 6}
               ]
             })

    assert result.sample_count == 2
    assert result.occupied_count == 1
    assert [%{macro: {2, 0, 0}, micro_slot: 5, mode: :refined}] = result.occupied
  end
end
