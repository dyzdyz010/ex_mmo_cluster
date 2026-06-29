defmodule WorldServer.Voxel.WorldPackAuthorityCoverageTest do
  use ExUnit.Case, async: true

  alias MmoContracts.WorldPackIndex
  alias WorldServer.Voxel.WorldPackAuthorityCoverage

  test "reports incomplete canonical coverage without enumerating the full index" do
    index = small_index()
    present = MapSet.new([{0, 0, 0}, {1, 0, 0}])

    assert {:ok, report} =
             WorldPackAuthorityCoverage.verify(index,
               coverage_store: coverage_store(present),
               snapshot_store: snapshot_store(present),
               radius: 0,
               window_centers: [{0, 0, 0}, {2, 0, 0}],
               shard_coords: [{0, 0, 0}, {1, 0, 0}]
             )

    assert report.status == :incomplete
    assert report.expected_chunk_count == 4
    assert report.coverage.in_bounds_chunk_count == 2
    assert report.coverage.missing_in_bounds_chunk_count == 2
    assert report.coverage.out_of_bounds_chunk_count == 0

    assert [
             %{shard_coord: {0, 0, 0}, status: :ready, missing_chunk_count: 0},
             %{
               shard_coord: {1, 0, 0},
               status: :incomplete,
               missing_chunk_count: 2,
               first_missing_chunk: {2, 0, 0}
             }
           ] = report.sampled_shards

    assert [
             %{center: {0, 0, 0}, status: :ready, missing_chunk_count: 0},
             %{
               center: {2, 0, 0},
               status: :incomplete,
               missing_chunk_count: 1,
               first_missing_chunk: {2, 0, 0}
             }
           ] = report.sampled_windows
  end

  test "marks coverage ready only when DB count and sampled windows are complete" do
    index = small_index()
    present = MapSet.new([{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}])

    assert {:ok, report} =
             WorldPackAuthorityCoverage.verify(index,
               coverage_store: coverage_store(present),
               snapshot_store: snapshot_store(present),
               radius: 0,
               window_centers: [{0, 0, 0}, {3, 0, 0}],
               shard_coords: [{0, 0, 0}, {1, 0, 0}]
             )

    assert report.status == :ready
    assert report.coverage.missing_in_bounds_chunk_count == 0
    assert Enum.all?(report.sampled_shards, &(&1.status == :ready))
    assert Enum.all?(report.sampled_windows, &(&1.status == :ready))
  end

  defp small_index do
    WorldPackIndex.new!(
      logical_scene_id: 42,
      content_version: "coverage-test@1",
      chunk_min: {0, 0, 0},
      chunk_max: {3, 0, 0},
      payload_layout: %{
        layout: "regular_shard_grid_v1",
        chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
        shard_chunk_shape: {2, 1, 1},
        shard_origin: {0, 0, 0},
        file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
        footer_format: "chunk_offset_table_v1",
        compression: "none"
      },
      regions: [
        %{
          id: "small",
          chunk_min: {0, 0, 0},
          chunk_max: {3, 0, 0},
          chunk_count: 4,
          hash: "sha256:small"
        }
      ]
    )
  end

  defp coverage_store(present) do
    fn logical_scene_id, chunk_min, chunk_max ->
      in_bounds =
        Enum.count(present, fn coord ->
          inside_bounds?(coord, chunk_min, chunk_max)
        end)

      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         requested_chunk_min: chunk_min,
         requested_chunk_max: chunk_max,
         total_scene_chunk_count: MapSet.size(present),
         in_bounds_chunk_count: in_bounds,
         out_of_bounds_chunk_count: MapSet.size(present) - in_bounds,
         scene_min_chunk: nil,
         scene_max_chunk: nil,
         in_bounds_min_chunk: nil,
         in_bounds_max_chunk: nil
       }}
    end
  end

  defp snapshot_store(present) do
    fn _logical_scene_id, chunk_coord ->
      if MapSet.member?(present, chunk_coord) do
        {:ok, %{data: <<0x62, 1>>}}
      else
        {:error, :snapshot_not_found}
      end
    end
  end

  defp inside_bounds?({x, y, z}, {min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and z <= max_z
  end
end
