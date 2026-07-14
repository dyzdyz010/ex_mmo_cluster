defmodule WorldServer.Voxel.Legacy.XzSvoSourceMaterializerTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.Legacy.XzSvoSourceMaterializer

  test "is disabled unless the caller explicitly enters legacy offline mode" do
    assert {:error, :legacy_xz_svo_source_materializer_disabled} =
             XzSvoSourceMaterializer.coverage(logical_scene_id: 91_015)
  end

  test "refuses 8km SVO source materialization before writing above the chunk budget" do
    test_pid = self()

    assert {:error, {:svo_source_materialization_exceeds_budget, summary}} =
             XzSvoSourceMaterializer.materialize(
               legacy_offline?: true,
               logical_scene_id: 91_015,
               center_tile: {0, 0, 0},
               radius_tiles: 72,
               near_skip_radius_tiles: 1,
               macro_cell_tiles: 1,
               max_chunks: 3_000,
               coverage_store: coverage_store(MapSet.new()),
               materializer: fn opts ->
                 send(test_pid, {:unexpected_svo_source_materialization, opts})
                 {:ok, %{chunk_count: Keyword.fetch!(opts, :max_chunks), errors: 0}}
               end
             )

    assert summary.status == :rejected
    assert summary.logical_scene_id == 91_015
    assert summary.center_tile == {0, 0, 0}
    assert summary.radius_tiles == 72
    assert summary.near_skip_radius_tiles == 1
    assert summary.macro_cell_tiles == 1
    assert summary.macro_cell_count == 21_016
    assert summary.expected_source_chunk_count == 7_208_488
    assert summary.present_source_chunk_count == 0
    assert summary.missing_source_chunk_count == 7_208_488
    assert summary.planned_materialization_chunk_count == 7_208_488
    assert summary.max_chunks == 3_000

    refute_received {:unexpected_svo_source_materialization, _opts}
  end

  test "fails visibly when the post-materialization coverage is still incomplete" do
    assert {:error, {:svo_source_materialization_incomplete, summary}} =
             XzSvoSourceMaterializer.materialize(
               legacy_offline?: true,
               logical_scene_id: 91_015,
               center_tile: {0, 0, 0},
               radius_tiles: 0,
               near_skip_radius_tiles: -1,
               macro_cell_tiles: 1,
               max_chunks: 400,
               coverage_store: coverage_store(MapSet.new()),
               materializer: fn opts ->
                 assert Keyword.fetch!(opts, :chunk_min) == {0, 0, 0}
                 assert Keyword.fetch!(opts, :chunk_max) == {6, 6, 6}
                 assert Keyword.fetch!(opts, :max_chunks) == 343
                 {:ok, %{chunk_count: 343, inserted: 343, updated: 0, unchanged: 0, errors: 0}}
               end
             )

    assert summary.status == :failed
    assert summary.materialized_macro_cell_count == 1
    assert summary.materialized_chunk_count == 343
    assert summary.final_missing_source_chunk_count == 343
  end

  test "reports read-only SVO source coverage with client-matching macro-cell counts" do
    present = tile_chunks({0, 0, 0})

    assert {:ok, summary} =
             XzSvoSourceMaterializer.coverage(
               legacy_offline?: true,
               logical_scene_id: 91_015,
               center_tile: {0, 0, 0},
               radius_tiles: 1,
               near_skip_radius_tiles: -1,
               macro_cell_tiles: 1,
               coverage_store: coverage_store(present)
             )

    assert summary.status == :incomplete
    assert summary.macro_cell_count == 9
    assert summary.expected_source_chunk_count == 3_087
    assert summary.present_source_chunk_count == 343
    assert summary.missing_source_chunk_count == 2_744
    assert summary.planned_materialization_chunk_count == 2_744
    assert summary.materialized_macro_cell_count == 0
  end

  defp tile_chunks({tile_x, tile_y, tile_z}) do
    chunk_min = {tile_x * 7, tile_y * 7, tile_z * 7}
    chunks(chunk_min, {elem(chunk_min, 0) + 6, elem(chunk_min, 1) + 6, elem(chunk_min, 2) + 6})
  end

  defp chunks({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    for x <- min_x..max_x,
        y <- min_y..max_y,
        z <- min_z..max_z,
        into: MapSet.new() do
      {x, y, z}
    end
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
         total_scene_chunk_count: MapSet.size(present),
         in_bounds_chunk_count: in_bounds,
         out_of_bounds_chunk_count: MapSet.size(present) - in_bounds
       }}
    end
  end

  defp inside_bounds?({x, y, z}, {min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and z <= max_z
  end
end
