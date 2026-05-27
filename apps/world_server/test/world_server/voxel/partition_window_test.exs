defmodule WorldServer.Voxel.PartitionWindowTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.PartitionWindow

  test "builds inclusive near and halo chunk cubes around the center" do
    window =
      PartitionWindow.build(7, {10, -2, 3},
        near_radius: 1,
        halo_radius: 2
      )

    assert window.logical_scene_id == 7
    assert window.center_chunk == {10, -2, 3}
    assert window.near_radius == 1
    assert window.halo_radius == 2
    assert window.near_vertical_radius == 1
    assert window.halo_vertical_radius == 2

    assert length(window.near_chunks) == 27
    assert length(window.halo_chunks) == 98
    assert {10, -2, 3} in window.near_chunks
    assert {12, -2, 3} in window.halo_chunks
    refute {10, -2, 3} in window.halo_chunks

    assert Enum.uniq(window.near_chunks) == window.near_chunks
    assert Enum.uniq(window.halo_chunks) == window.halo_chunks
    assert window.missing_chunks == window.near_chunks ++ window.halo_chunks
    assert Enum.all?(window.route_entries, &(&1.status == :missing))
    assert window.region_summaries == []
  end

  test "clips open-world interest windows by vertical radius" do
    window =
      PartitionWindow.build(7, {0, 0, 5},
        near_radius: 1,
        halo_radius: 2,
        near_vertical_radius: 0,
        halo_vertical_radius: 1
      )

    assert window.near_vertical_radius == 0
    assert window.halo_vertical_radius == 1
    assert length(window.near_chunks) == 9
    assert length(window.halo_chunks) == 66

    assert {1, 1, 5} in window.near_chunks
    assert {0, 0, 6} in window.halo_chunks
    assert {2, 0, 5} in window.halo_chunks
    refute {0, 0, 7} in window.near_chunks
    refute {0, 0, 7} in window.halo_chunks
    refute {1, 1, 5} in window.halo_chunks
  end

  test "classifies routed chunks by tier and summarizes regions" do
    window =
      PartitionWindow.build(9, {0, 0, 0},
        near_radius: 0,
        halo_radius: 1
      )
      |> PartitionWindow.attach_routes(%{
        {0, 0, 0} => %{
          region_id: 10,
          lease_id: 101,
          lease: %{lease_id: 101, owner_scene_instance_ref: 1_001},
          assigned_scene_node: :"scene-a@local"
        },
        {1, 0, 0} => %{
          region_id: 10,
          lease_id: 101,
          assigned_scene_node: :"scene-a@local"
        },
        {-1, 0, 0} => %{
          region_id: 20,
          assigned_scene_node: :"scene-b@local",
          status: :region_without_lease
        }
      })

    assert [
             %{
               chunk_coord: {0, 0, 0},
               tier: :near,
               status: :assigned,
               region_id: 10,
               lease_id: 101,
               lease: %{lease_id: 101, owner_scene_instance_ref: 1_001}
             }
           ] =
             Enum.filter(window.route_entries, &(&1.chunk_coord == {0, 0, 0}))

    assert [
             %{
               chunk_coord: {1, 0, 0},
               tier: :halo,
               status: :assigned,
               region_id: 10,
               lease_id: 101
             }
           ] =
             Enum.filter(window.route_entries, &(&1.chunk_coord == {1, 0, 0}))

    assert [
             %{
               chunk_coord: {-1, 0, 0},
               tier: :halo,
               status: :region_without_lease,
               region_id: 20,
               lease_id: nil,
               lease: nil
             }
           ] =
             Enum.filter(window.route_entries, &(&1.chunk_coord == {-1, 0, 0}))

    assert {0, 1, 0} in window.missing_chunks
    refute {0, 0, 0} in window.missing_chunks

    assert window.region_summaries == [
             %{
               region_id: 10,
               near_count: 1,
               halo_count: 1,
               lease_id: 101,
               assigned_scene_node: :"scene-a@local"
             },
             %{
               region_id: 20,
               near_count: 0,
               halo_count: 1,
               lease_id: nil,
               assigned_scene_node: :"scene-b@local"
             }
           ]
  end

  test "rejects invalid window radii" do
    assert_raise ArgumentError, ~r/near_radius/, fn ->
      PartitionWindow.build(1, {0, 0, 0}, near_radius: -1, halo_radius: 0)
    end

    assert_raise ArgumentError, ~r/halo_radius/, fn ->
      PartitionWindow.build(1, {0, 0, 0}, near_radius: 2, halo_radius: 1)
    end

    assert_raise ArgumentError, ~r/near_vertical_radius/, fn ->
      PartitionWindow.build(1, {0, 0, 0}, near_vertical_radius: -1)
    end

    assert_raise ArgumentError, ~r/halo_vertical_radius/, fn ->
      PartitionWindow.build(1, {0, 0, 0},
        near_radius: 1,
        halo_radius: 2,
        near_vertical_radius: 1,
        halo_vertical_radius: 0
      )
    end
  end
end
