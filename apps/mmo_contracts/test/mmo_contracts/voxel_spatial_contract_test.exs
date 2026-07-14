defmodule MmoContracts.VoxelSpatialContractTest do
  use ExUnit.Case, async: true

  alias MmoContracts.VoxelSpatialContract

  test "defines the canonical complete XYZ near window" do
    assert VoxelSpatialContract.tile_size_chunks() == 7
    assert VoxelSpatialContract.near_tile_radius() == 1
    assert VoxelSpatialContract.near_chunk_radius() == 10
    assert VoxelSpatialContract.near_chunk_shape() == {21, 21, 21}
    assert VoxelSpatialContract.near_chunk_count() == 9_261
    assert VoxelSpatialContract.default_near_center_chunk() == {3, 3, 3}

    assert VoxelSpatialContract.near_window_bounds({3, 3, 3}) ==
             {{-7, -7, -7}, {13, 13, 13}}
  end

  test "maps positive and negative tile identities to chunk centers" do
    assert VoxelSpatialContract.tile_center_chunk({0, 0, 0}) == {3, 3, 3}
    assert VoxelSpatialContract.tile_center_chunk({1, 0, -1}) == {10, 3, -4}
    assert VoxelSpatialContract.tile_center_chunk({-1, -2, 2}) == {-4, -11, 17}
  end

  test "keeps full32km layer count while covering the default near lower face" do
    assert chunk_min = VoxelSpatialContract.full32km_chunk_min()
    assert chunk_max = VoxelSpatialContract.full32km_chunk_max()
    assert chunk_min == {-1024, -7, -1024}
    assert chunk_max == {1023, 98, 1023}
    assert VoxelSpatialContract.full32km_shard_chunk_shape() == {16, 106, 16}
    assert elem(chunk_max, 1) - elem(chunk_min, 1) + 1 == 106

    {near_min, near_max} =
      VoxelSpatialContract.default_near_center_chunk()
      |> VoxelSpatialContract.near_window_bounds()

    assert elem(near_min, 1) == elem(chunk_min, 1)
    assert elem(near_max, 1) <= elem(chunk_max, 1)
  end
end
