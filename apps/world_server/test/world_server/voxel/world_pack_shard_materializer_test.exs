defmodule WorldServer.Voxel.WorldPackShardMaterializerTest do
  use ExUnit.Case, async: true

  alias MmoContracts.WorldPackIndex
  alias WorldServer.Voxel.WorldPackShardMaterializer

  defp small_index do
    WorldPackIndex.new!(
      logical_scene_id: 91_016,
      content_version: "worldgen-shard-materializer-test@1",
      chunk_min: {-1, -1, -1},
      chunk_max: {2, 1, 1},
      payload_layout: %{
        layout: "regular_shard_grid_v1",
        chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
        shard_chunk_shape: {2, 3, 3},
        shard_origin: {-1, -1, -1},
        file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
        footer_format: "chunk_offset_table_v1",
        compression: "none"
      },
      regions: [
        %{
          id: "small-full",
          chunk_min: {-1, -1, -1},
          chunk_max: {2, 1, 1},
          chunk_count: 36,
          hash: "sha256:small-full"
        }
      ]
    )
  end

  test "skips ready shards and materializes the next missing shard within the work limit" do
    {:ok, covered} = Agent.start_link(fn -> shard_chunks({0, 0, 0}) end)
    coverage_store = coverage_store(covered)

    materializer = fn opts ->
      assert Keyword.fetch!(opts, :logical_scene_id) == 91_016
      assert Keyword.fetch!(opts, :chunk_min) == {1, -1, -1}
      assert Keyword.fetch!(opts, :chunk_max) == {2, 1, 1}
      assert Keyword.fetch!(opts, :max_chunks) == 18
      assert Keyword.fetch!(opts, :materializer_opts) == [lod_projection?: false]
      Agent.update(covered, &MapSet.union(&1, shard_chunks({1, 0, 0})))
      {:ok, %{chunk_count: 18, inserted: 18, updated: 0, unchanged: 0, errors: 0}}
    end

    assert {:ok, summary} =
             WorldPackShardMaterializer.materialize(small_index(),
               coverage_store: coverage_store,
               materializer: materializer,
               max_shards: 1,
               materializer_opts: [lod_projection?: false]
             )

    assert summary.status == :ready
    assert summary.expected_shards == 2
    assert summary.index_expected_chunks == 36
    assert summary.index_region_covered_chunks == 36
    assert summary.canonical_initial_in_bounds_chunks == 18
    assert summary.canonical_initial_missing_chunks == 18
    assert summary.canonical_final_in_bounds_chunks == 36
    assert summary.canonical_final_missing_chunks == 0
    assert summary.ready_before_shards == 1
    assert summary.skipped_shards == 1
    assert summary.materialized_shards == 1
    assert summary.remaining_unready_shards == 0
    assert [%{shard_coord: {1, 0, 0}, status: :materialized}] = summary.shards_materialized
  end

  test "fails visibly when a materialized shard remains incomplete after the write pass" do
    coverage_store = fn _scene_id, _chunk_min, _chunk_max ->
      {:ok,
       %{
         logical_scene_id: 91_016,
         total_scene_chunk_count: 0,
         in_bounds_chunk_count: 0,
         out_of_bounds_chunk_count: 0
       }}
    end

    materializer = fn _opts ->
      {:ok, %{chunk_count: 18, inserted: 18, updated: 0, unchanged: 0, errors: 0}}
    end

    assert {:error, {:world_pack_shard_materialization_incomplete, summary}} =
             WorldPackShardMaterializer.materialize(small_index(),
               coverage_store: coverage_store,
               materializer: materializer,
               shard_coords: [{0, 0, 0}],
               max_shards: 1
             )

    assert summary.status == :failed
    assert summary.errors == 1

    assert [
             %{
               shard_coord: {0, 0, 0},
               error: :shard_materialization_incomplete,
               present_chunk_count: 0,
               expected_chunk_count: 18
             }
           ] = summary.chunk_errors
  end

  test "keeps selected shard success partial until full index coverage is complete" do
    {:ok, covered} = Agent.start_link(fn -> shard_chunks({0, 0, 0}) end)

    materializer = fn _opts ->
      flunk("ready selected shards must be skipped without writing")
    end

    assert {:ok, summary} =
             WorldPackShardMaterializer.materialize(small_index(),
               coverage_store: coverage_store(covered),
               materializer: materializer,
               shard_coords: [{0, 0, 0}],
               max_shards: 1
             )

    assert summary.status == :partial
    assert summary.expected_shards == 2
    assert summary.selected_shards == 1
    assert summary.skipped_shards == 1
    assert summary.materialized_shards == 0
    assert summary.remaining_unready_shards == 0
    assert summary.canonical_final_in_bounds_chunks == 18
    assert summary.canonical_final_missing_chunks == 18
  end

  defp shard_chunks({0, 0, 0}), do: chunks({-1, -1, -1}, {0, 1, 1})
  defp shard_chunks({1, 0, 0}), do: chunks({1, -1, -1}, {2, 1, 1})

  defp chunks({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    for x <- min_x..max_x,
        y <- min_y..max_y,
        z <- min_z..max_z,
        into: MapSet.new() do
      {x, y, z}
    end
  end

  defp coverage_store(agent) do
    fn logical_scene_id, chunk_min, chunk_max ->
      covered = Agent.get(agent, & &1)

      in_bounds =
        Enum.count(covered, fn coord ->
          inside_bounds?(coord, chunk_min, chunk_max)
        end)

      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         total_scene_chunk_count: MapSet.size(covered),
         in_bounds_chunk_count: in_bounds,
         out_of_bounds_chunk_count: MapSet.size(covered) - in_bounds
       }}
    end
  end

  defp inside_bounds?({x, y, z}, {min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and z <= max_z
  end
end
