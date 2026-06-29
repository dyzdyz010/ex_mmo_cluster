defmodule MmoContracts.WorldPackIndexTest do
  use ExUnit.Case, async: true

  alias MmoContracts.WorldPackIndex

  @full_min {-1024, -3, -1024}
  @full_max {1023, 102, 1023}

  test "describes the 32km full-authority chunk space without enumerating chunks" do
    index =
      WorldPackIndex.new!(
        logical_scene_id: 1,
        content_version: "worldgen-32km@1",
        chunk_min: @full_min,
        chunk_max: @full_max,
        regions: [
          %{
            id: "full",
            chunk_min: @full_min,
            chunk_max: @full_max,
            chunk_count: 444_596_224,
            hash: "sha256:full"
          }
        ]
      )

    assert WorldPackIndex.chunk_count(index) == 444_596_224
    assert WorldPackIndex.horizontal_chunk_count(index) == 4_194_304
    assert WorldPackIndex.vertical_chunk_layers(index) == 106

    assert {:ok, summary} = WorldPackIndex.verify(index)
    assert summary.status == :ready
    assert summary.expected_chunk_count == 444_596_224
    assert summary.covered_chunk_count == 444_596_224
    assert summary.region_count == 1
  end

  test "rejects region indexes that do not cover the declared full-authority bounds" do
    index =
      WorldPackIndex.new!(
        logical_scene_id: 1,
        content_version: "worldgen-32km@incomplete",
        chunk_min: @full_min,
        chunk_max: @full_max,
        regions: [
          %{
            id: "missing-x-max",
            chunk_min: @full_min,
            chunk_max: {1022, 102, 1023},
            chunk_count: 444_379_136,
            hash: "sha256:missing"
          }
        ]
      )

    assert {:error, summary} = WorldPackIndex.verify(index)
    assert summary.status == :incomplete
    assert summary.reason == :bounds_not_fully_covered
    assert summary.expected_chunk_count == 444_596_224
    assert summary.covered_chunk_count == 444_379_136
    assert summary.missing_chunk_count == 217_088
  end

  test "rejects overlapping regions because coverage count alone would lie" do
    index =
      WorldPackIndex.new!(
        logical_scene_id: 7,
        content_version: "worldgen-overlap@1",
        chunk_min: {0, 0, 0},
        chunk_max: {3, 0, 0},
        regions: [
          %{id: "a", chunk_min: {0, 0, 0}, chunk_max: {2, 0, 0}, chunk_count: 3, hash: "a"},
          %{id: "b", chunk_min: {2, 0, 0}, chunk_max: {3, 0, 0}, chunk_count: 2, hash: "b"}
        ]
      )

    assert {:error, summary} = WorldPackIndex.verify(index)
    assert summary.status == :invalid
    assert summary.reason == :overlapping_regions
    assert summary.overlap_count == 1
  end

  test "sliding windows stay radius 3 while movement only changes entering and leaving chunks" do
    assert window0 = WorldPackIndex.sliding_window({0, 0, 0}, 3)
    assert window1 = WorldPackIndex.sliding_window({1, 0, 0}, 3)
    assert window2 = WorldPackIndex.sliding_window({2, 0, 0}, 3)

    assert window0.chunk_count == 343
    assert window1.chunk_count == 343
    assert window2.chunk_count == 343

    assert transition01 = WorldPackIndex.window_transition(window0, window1)
    assert transition01.kept_chunks == 294
    assert transition01.entering_chunks == 49
    assert transition01.leaving_chunks == 49

    assert transition12 = WorldPackIndex.window_transition(window1, window2)
    assert transition12.kept_chunks == 294
    assert transition12.entering_chunks == 49
    assert transition12.leaving_chunks == 49

    assert WorldPackIndex.window_bounds(window0).chunk_min == {-3, -3, -3}
    assert WorldPackIndex.window_bounds(window2).chunk_max == {5, 3, 3}
  end

  test "validates sampled sliding windows against the full 32km authority bounds" do
    index =
      WorldPackIndex.new!(
        logical_scene_id: 1,
        content_version: "worldgen-32km@1",
        chunk_min: @full_min,
        chunk_max: @full_max,
        regions: [
          %{
            id: "full",
            chunk_min: @full_min,
            chunk_max: @full_max,
            chunk_count: 444_596_224,
            hash: "sha256:full"
          }
        ]
      )

    for center <- [
          {0, 0, 0},
          {1, 0, 0},
          {2, 0, 0},
          {1020, 0, 0},
          {1020, 0, 1020},
          {-1021, 0, -1021}
        ] do
      assert :ok = WorldPackIndex.validate_window(index, center, 3)
    end

    assert {:error, %{reason: :window_out_of_bounds}} =
             WorldPackIndex.validate_window(index, {1021, 0, 0}, 3)
  end

  test "plans payload shard reads for a sliding window without enumerating the full pack" do
    index =
      WorldPackIndex.new!(
        logical_scene_id: 1,
        content_version: "worldgen-32km@payload",
        chunk_min: @full_min,
        chunk_max: @full_max,
        payload_layout: %{
          layout: "regular_shard_grid_v1",
          chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
          shard_chunk_shape: [16, 106, 16],
          shard_origin: [-1024, -3, -1024],
          file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
          footer_format: "chunk_offset_table_v1",
          compression: "none"
        },
        regions: [
          %{
            id: "full",
            chunk_min: @full_min,
            chunk_max: @full_max,
            chunk_count: 444_596_224,
            hash: "sha256:full"
          }
        ]
      )

    assert {:ok, plan} = WorldPackIndex.window_payload_plan(index, {0, 0, 0}, 3)

    assert plan.window.center == {0, 0, 0}
    assert plan.window.chunk_count == 343
    assert plan.chunk_count == 343
    assert Enum.count(plan.shards) == 4

    shard_counts =
      plan.shards
      |> Enum.map(fn shard -> {shard.shard_coord, shard.path, shard.chunk_count} end)
      |> Enum.sort()

    assert shard_counts == [
             {{63, 0, 63}, "packs/tile_63_0_63.vxpack", 63},
             {{63, 0, 64}, "packs/tile_63_0_64.vxpack", 84},
             {{64, 0, 63}, "packs/tile_64_0_63.vxpack", 84},
             {{64, 0, 64}, "packs/tile_64_0_64.vxpack", 112}
           ]

    all_refs = Enum.flat_map(plan.shards, & &1.chunks)
    assert length(all_refs) == 343
    assert Enum.uniq_by(all_refs, & &1.chunk_coord) == all_refs

    assert Enum.find(all_refs, &(&1.chunk_coord == {-3, -3, -3})).local_coord ==
             {13, 0, 13}

    assert Enum.find(all_refs, &(&1.chunk_coord == {0, 0, 0})).shard_coord == {64, 0, 64}

    assert {:ok, moved} = WorldPackIndex.window_payload_plan(index, {1, 0, 0}, 3)
    assert moved.chunk_count == 343
    assert Enum.count(moved.shards) == 4
  end

  test "describes full-pack payload shard grid without enumerating full chunk payload refs" do
    index =
      WorldPackIndex.new!(
        logical_scene_id: 1,
        content_version: "worldgen-32km@payload-grid",
        chunk_min: @full_min,
        chunk_max: @full_max,
        payload_layout: %{
          layout: "regular_shard_grid_v1",
          chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
          shard_chunk_shape: [16, 106, 16],
          shard_origin: [-1024, -3, -1024],
          file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
          footer_format: "chunk_offset_table_v1",
          compression: "none"
        },
        regions: [
          %{
            id: "full",
            chunk_min: @full_min,
            chunk_max: @full_max,
            chunk_count: 444_596_224,
            hash: "sha256:full"
          }
        ]
      )

    assert {:ok, grid} = WorldPackIndex.payload_shard_grid(index)
    assert grid.shard_min == {0, 0, 0}
    assert grid.shard_max == {127, 0, 127}
    assert grid.shard_count == 16_384
    assert hd(grid.shard_coords) == {0, 0, 0}
    assert List.last(grid.shard_coords) == {127, 0, 127}
  end

  test "plans one full payload shard from a 32km index without expanding the world" do
    index =
      WorldPackIndex.new!(
        logical_scene_id: 1,
        content_version: "worldgen-32km@payload-shard",
        chunk_min: @full_min,
        chunk_max: @full_max,
        payload_layout: %{
          layout: "regular_shard_grid_v1",
          chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
          shard_chunk_shape: [16, 106, 16],
          shard_origin: [-1024, -3, -1024],
          file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
          footer_format: "chunk_offset_table_v1",
          compression: "none"
        },
        regions: [
          %{
            id: "full",
            chunk_min: @full_min,
            chunk_max: @full_max,
            chunk_count: 444_596_224,
            hash: "sha256:full"
          }
        ]
      )

    assert {:ok, shard} = WorldPackIndex.payload_shard_plan(index, {64, 0, 64})
    assert shard.shard_coord == {64, 0, 64}
    assert shard.path == "packs/tile_64_0_64.vxpack"
    assert shard.chunk_min == {0, -3, 0}
    assert shard.chunk_max == {15, 102, 15}
    assert shard.chunk_count == 27_136
    assert length(shard.chunks) == 27_136

    assert hd(shard.chunks).chunk_coord == {0, -3, 0}
    assert hd(shard.chunks).local_coord == {0, 0, 0}
    assert List.last(shard.chunks).chunk_coord == {15, 102, 15}
    assert List.last(shard.chunks).local_coord == {15, 105, 15}
  end

  test "summarizes one payload shard path and bounds without chunk refs" do
    index =
      WorldPackIndex.new!(
        logical_scene_id: 1,
        content_version: "worldgen-32km@payload-shard-summary",
        chunk_min: @full_min,
        chunk_max: @full_max,
        payload_layout: %{
          layout: "regular_shard_grid_v1",
          chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
          shard_chunk_shape: [16, 106, 16],
          shard_origin: [-1024, -3, -1024],
          file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
          footer_format: "chunk_offset_table_v1",
          compression: "none"
        },
        regions: [
          %{
            id: "full",
            chunk_min: @full_min,
            chunk_max: @full_max,
            chunk_count: 444_596_224,
            hash: "sha256:full"
          }
        ]
      )

    assert {:ok, shard} = WorldPackIndex.payload_shard_summary(index, {64, 0, 64})
    assert shard.shard_coord == {64, 0, 64}
    assert shard.path == "packs/tile_64_0_64.vxpack"
    assert shard.chunk_min == {0, -3, 0}
    assert shard.chunk_max == {15, 102, 15}
    assert shard.chunk_count == 27_136
    refute Map.has_key?(shard, :chunks)
  end

  test "summarizes the full payload shard set without recalculating the grid per shard" do
    index =
      WorldPackIndex.new!(
        logical_scene_id: 1,
        content_version: "worldgen-32km@payload-shard-summaries",
        chunk_min: @full_min,
        chunk_max: @full_max,
        payload_layout: %{
          layout: "regular_shard_grid_v1",
          chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
          shard_chunk_shape: [16, 106, 16],
          shard_origin: [-1024, -3, -1024],
          file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
          footer_format: "chunk_offset_table_v1",
          compression: "none"
        },
        regions: [
          %{
            id: "full",
            chunk_min: @full_min,
            chunk_max: @full_max,
            chunk_count: 444_596_224,
            hash: "sha256:full"
          }
        ]
      )

    assert {:ok, summaries} = WorldPackIndex.payload_shard_summaries(index)
    assert length(summaries) == 16_384
    assert hd(summaries).path == "packs/tile_0_0_0.vxpack"
    assert List.last(summaries).path == "packs/tile_127_0_127.vxpack"

    assert Enum.reduce(summaries, 0, fn summary, acc -> acc + summary.chunk_count end) ==
             444_596_224

    refute Map.has_key?(hd(summaries), :chunks)
  end
end
