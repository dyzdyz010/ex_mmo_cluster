defmodule WorldServer.Voxel.RouteIndexTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.RegionAssignment
  alias WorldServer.Voxel.RouteIndex

  test "indexes active regions by logical scene and routes half-open bounds" do
    {:ok, index} =
      RouteIndex.build([
        assignment(1, 10, {0, 0, 0}, {2, 2, 2}),
        assignment(1, 20, {2, 0, 0}, {4, 2, 2}),
        assignment(2, 30, {0, 0, 0}, {2, 2, 2}),
        assignment(1, 40, {10, 0, 0}, {12, 2, 2}, state: :inactive)
      ])

    assert {:ok, routed_min} = RouteIndex.route_chunk(index, 1, {0, 0, 0})
    assert routed_min.region_id == 10

    assert {:ok, routed_max_minus_one} = RouteIndex.route_chunk(index, 1, {1, 1, 1})
    assert routed_max_minus_one.region_id == 10

    assert {:ok, routed_adjacent} = RouteIndex.route_chunk(index, 1, {2, 0, 0})
    assert routed_adjacent.region_id == 20

    assert {:ok, routed_other_scene} = RouteIndex.route_chunk(index, 2, {1, 0, 0})
    assert routed_other_scene.region_id == 30

    assert {:error, :unassigned_chunk} = RouteIndex.route_chunk(index, 1, {4, 0, 0})
    assert {:error, :unassigned_chunk} = RouteIndex.route_chunk(index, 1, {10, 0, 0})
  end

  test "builds deterministic stats regardless of assignment input order" do
    assignments = [
      assignment(1, 20, {2, 0, 0}, {4, 2, 2}),
      assignment(2, 30, {0, 0, 0}, {2, 2, 2}),
      assignment(1, 10, {0, 0, 0}, {2, 2, 2})
    ]

    {:ok, left} = RouteIndex.build(assignments)
    {:ok, right} = RouteIndex.build(Enum.reverse(assignments))

    assert RouteIndex.stats(left) == RouteIndex.stats(right)

    assert %{
             strategy: :scene_bucket_grid_v1,
             bucket_size: 16,
             scene_count: 2,
             region_count: 3,
             bucket_count: 2,
             entry_count: 3,
             max_candidates_per_bucket: 2,
             scenes: [
               %{logical_scene_id: 1, region_count: 2, bucket_count: 1, region_ids: [10, 20]},
               %{logical_scene_id: 2, region_count: 1, bucket_count: 1, region_ids: [30]}
             ]
           } = RouteIndex.stats(left)
  end

  test "surfaces overlapping active coverage instead of silently picking a region" do
    assert {:error, {:region_bounds_overlap, 10, 20}} =
             RouteIndex.build([
               assignment(1, 10, {0, 0, 0}, {3, 3, 3}),
               assignment(1, 20, {2, 0, 0}, {4, 3, 3})
             ])
  end

  test "routes a chunk list without mutating the index" do
    {:ok, index} =
      RouteIndex.build([
        assignment(1, 10, {0, 0, 0}, {1, 1, 1}),
        assignment(1, 20, {1, 0, 0}, {2, 1, 1})
      ])

    before_stats = RouteIndex.stats(index)

    assert %{
             {0, 0, 0} => {:ok, assignment_a},
             {1, 0, 0} => {:ok, assignment_b},
             {2, 0, 0} => {:error, :unassigned_chunk}
           } = RouteIndex.route_chunks(index, 1, [{0, 0, 0}, {1, 0, 0}, {2, 0, 0}])

    assert assignment_a.region_id == 10
    assert assignment_b.region_id == 20
    assert RouteIndex.stats(index) == before_stats
  end

  test "routes chunks across negative and positive bucket boundaries" do
    {:ok, index} =
      RouteIndex.build([
        assignment(1, 10, {-17, 0, 0}, {-16, 1, 1}),
        assignment(1, 20, {-16, 0, 0}, {0, 1, 1}),
        assignment(1, 30, {0, 0, 0}, {16, 1, 1}),
        assignment(1, 40, {16, 0, 0}, {17, 1, 1})
      ])

    assert {:ok, %{region_id: 10}} = RouteIndex.route_chunk(index, 1, {-17, 0, 0})
    assert {:ok, %{region_id: 20}} = RouteIndex.route_chunk(index, 1, {-16, 0, 0})
    assert {:ok, %{region_id: 20}} = RouteIndex.route_chunk(index, 1, {-1, 0, 0})
    assert {:ok, %{region_id: 30}} = RouteIndex.route_chunk(index, 1, {0, 0, 0})
    assert {:ok, %{region_id: 30}} = RouteIndex.route_chunk(index, 1, {15, 0, 0})
    assert {:ok, %{region_id: 40}} = RouteIndex.route_chunk(index, 1, {16, 0, 0})
    assert {:error, :unassigned_chunk} = RouteIndex.route_chunk(index, 1, {17, 0, 0})
  end

  defp assignment(logical_scene_id, region_id, bounds_min, bounds_max, opts \\ []) do
    RegionAssignment.new(%{
      logical_scene_id: logical_scene_id,
      region_id: region_id,
      bounds_chunk_min: bounds_min,
      bounds_chunk_max: bounds_max,
      owner_scene_instance_ref: Keyword.get(opts, :owner_scene_instance_ref, region_id * 100),
      owner_epoch: Keyword.get(opts, :owner_epoch, 0),
      assigned_scene_node: Keyword.get(opts, :assigned_scene_node, node()),
      state: Keyword.get(opts, :state, :active)
    })
  end
end
