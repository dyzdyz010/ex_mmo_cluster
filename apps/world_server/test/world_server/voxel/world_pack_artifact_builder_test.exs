defmodule WorldServer.Voxel.WorldPackArtifactBuilderTest do
  use ExUnit.Case, async: true

  alias MmoContracts.VoxelSpatialContract
  alias MmoContracts.WorldPackIndex
  alias MmoContracts.WorldPackShard
  alias WorldServer.Voxel.WorldPackArtifactBuilder
  alias WorldServer.Voxel.WorldPackReleaseVerifier

  defp index do
    WorldPackIndex.new!(
      logical_scene_id: 91_015,
      content_version: "worldgen-32km-xyz-window@2",
      chunk_min: VoxelSpatialContract.full32km_chunk_min(),
      chunk_max: VoxelSpatialContract.full32km_chunk_max(),
      payload_layout: %{
        layout: "regular_shard_grid_v1",
        chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
        shard_chunk_shape: VoxelSpatialContract.full32km_shard_chunk_shape(),
        shard_origin: VoxelSpatialContract.full32km_chunk_min(),
        file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
        footer_format: "chunk_offset_table_v1",
        compression: "none"
      },
      regions: [
        %{
          id: "full-32km",
          chunk_min: VoxelSpatialContract.full32km_chunk_min(),
          chunk_max: VoxelSpatialContract.full32km_chunk_max(),
          chunk_count: 444_596_224,
          hash: "sha256:full-32km-xyz-window-v2"
        }
      ]
    )
  end

  defp incomplete_index do
    WorldPackIndex.new!(
      logical_scene_id: 91_015,
      content_version: "worldgen-32km-index-pack@incomplete",
      chunk_min: VoxelSpatialContract.full32km_chunk_min(),
      chunk_max: VoxelSpatialContract.full32km_chunk_max(),
      payload_layout: %{
        layout: "regular_shard_grid_v1",
        chunk_payload_format: "chunk_snapshot_frame_0x62_v1",
        shard_chunk_shape: VoxelSpatialContract.full32km_shard_chunk_shape(),
        shard_origin: VoxelSpatialContract.full32km_chunk_min(),
        file_template: "packs/tile_{sx}_{sy}_{sz}.vxpack",
        footer_format: "chunk_offset_table_v1",
        compression: "none"
      },
      regions: [
        %{
          id: "missing-x-max",
          chunk_min: VoxelSpatialContract.full32km_chunk_min(),
          chunk_max: {1022, 98, 1023},
          chunk_count: 444_379_136,
          hash: "sha256:missing"
        }
      ]
    )
  end

  defp small_release_index do
    WorldPackIndex.new!(
      logical_scene_id: 91_016,
      content_version: "worldgen-release-builder-test@1",
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
          id: "small-release-builder-full",
          chunk_min: {-1, -1, -1},
          chunk_max: {2, 1, 1},
          chunk_count: 36,
          hash: "sha256:small-release-builder-full"
        }
      ]
    )
  end

  defp temp_dir do
    Path.join(
      System.tmp_dir!(),
      "world_pack_artifact_builder_#{System.unique_integer([:positive])}"
    )
  end

  test "builds vxpack shard payloads from canonical snapshot bodies" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    snapshot_store = fn 91_015, {0, 0, 0} -> {:ok, %{data: <<1, 2, 3>>}} end

    assert {:ok, summary} =
             WorldPackArtifactBuilder.build_window(index(), {0, 0, 0}, 0,
               output_dir: output_dir,
               snapshot_store: snapshot_store
             )

    assert summary.logical_scene_id == 91_015
    assert summary.center == {0, 0, 0}
    assert summary.radius == 0
    assert summary.planned_chunks == 1
    assert summary.written_chunks == 1
    assert summary.shard_count == 1
    assert summary.shard_paths == ["packs/tile_64_0_64.vxpack"]

    shard = File.read!(Path.join(output_dir, "packs/tile_64_0_64.vxpack"))
    assert {:ok, <<0x62, 1, 2, 3>>} = WorldPackShard.fetch(shard, {0, 7, 0})
  end

  test "builds one full shard from the verified 32km authority index" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    snapshot_store = fn 91_015, chunk_coord ->
      {:ok, %{data: :erlang.term_to_binary(chunk_coord)}}
    end

    assert {:ok, summary} =
             WorldPackArtifactBuilder.build_shard(index(), {64, 0, 64},
               output_dir: output_dir,
               snapshot_store: snapshot_store
             )

    assert summary.logical_scene_id == 91_015
    assert summary.authority_expected_chunks == 444_596_224
    assert summary.authority_covered_chunks == 444_596_224
    assert summary.shard_coord == {64, 0, 64}
    assert summary.planned_chunks == 27_136
    assert summary.written_chunks == 27_136
    assert summary.shard_paths == ["packs/tile_64_0_64.vxpack"]

    shard = File.read!(Path.join(output_dir, "packs/tile_64_0_64.vxpack"))
    assert {:ok, <<0x62, body::binary>>} = WorldPackShard.fetch(shard, {0, 0, 0})
    assert :erlang.binary_to_term(body) == {0, -7, 0}
  end

  test "builds a sliding-window payload sequence from a full 32km authority index" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    snapshot_store = fn 91_015, chunk_coord ->
      {:ok, %{data: :erlang.term_to_binary(chunk_coord)}}
    end

    assert {:ok, summary} =
             WorldPackArtifactBuilder.build_window_sequence(
               index(),
               [{3, 3, 3}, {10, 3, 3}, {17, 3, 3}],
               10,
               output_dir: output_dir,
               snapshot_store: snapshot_store
             )

    assert summary.logical_scene_id == 91_015
    assert summary.authority_expected_chunks == 444_596_224
    assert summary.authority_covered_chunks == 444_596_224
    assert summary.window_count == 3
    assert summary.planned_chunks == 27_783
    assert summary.written_chunks == 15_435
    assert summary.shard_count == 6

    assert Enum.map(
             summary.windows,
             &{&1.center, &1.planned_chunks, &1.new_chunks, &1.held_chunks}
           ) == [
             {{3, 3, 3}, 9_261, 9_261, 0},
             {{10, 3, 3}, 9_261, 3_087, 6_174},
             {{17, 3, 3}, 9_261, 3_087, 6_174}
           ]

    shard = File.read!(Path.join(output_dir, "packs/tile_65_0_64.vxpack"))
    assert {:ok, <<0x62, body::binary>>} = WorldPackShard.fetch(shard, {11, 10, 3})
    assert :erlang.binary_to_term(body) == {27, 3, 3}
  end

  test "builds a complete release payload set and manifest from every payload shard" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    snapshot_store = fn 91_016, chunk_coord ->
      {:ok, %{data: :erlang.term_to_binary(chunk_coord)}}
    end

    assert {:ok, summary} =
             WorldPackArtifactBuilder.build_release(small_release_index(),
               output_dir: output_dir,
               snapshot_store: snapshot_store
             )

    assert summary.logical_scene_id == 91_016
    assert summary.status == :ready
    assert summary.authority_expected_chunks == 36
    assert summary.authority_covered_chunks == 36
    assert summary.expected_shards == 2
    assert summary.built_shards == 2
    assert summary.remaining_shards == 0
    assert summary.planned_chunks == 36
    assert summary.written_chunks == 36

    assert Enum.sort(summary.shard_paths) == [
             "packs/tile_0_0_0.vxpack",
             "packs/tile_1_0_0.vxpack"
           ]

    assert summary.manifest.expected_shards == 2
    assert length(summary.manifest.shards) == 2
    assert File.exists?(Path.join(output_dir, "packs/tile_0_0_0.vxpack"))
    assert File.exists?(Path.join(output_dir, "packs/tile_1_0_0.vxpack"))

    assert {:ok, verify_summary} =
             WorldPackReleaseVerifier.verify(small_release_index(), output_dir,
               manifest: summary.manifest,
               window_centers: [{0, 0, 0}, {1, 0, 0}],
               radius: 1
             )

    assert verify_summary.status == :ready
    assert verify_summary.window_unique_chunks == 36
  end

  test "builds a bounded release batch without claiming a ready manifest" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    snapshot_store = fn 91_016, chunk_coord ->
      {:ok, %{data: :erlang.term_to_binary(chunk_coord)}}
    end

    assert {:ok, summary} =
             WorldPackArtifactBuilder.build_release(small_release_index(),
               output_dir: output_dir,
               snapshot_store: snapshot_store,
               max_shards: 1
             )

    assert summary.status == :partial
    assert summary.expected_shards == 2
    assert summary.built_shards == 1
    assert summary.remaining_shards == 1
    assert summary.manifest == nil
    assert summary.shard_paths == ["packs/tile_0_0_0.vxpack"]
    assert File.exists?(Path.join(output_dir, "packs/tile_0_0_0.vxpack"))
    refute File.exists?(Path.join(output_dir, "packs/tile_1_0_0.vxpack"))

    assert {:error, {:world_pack_release_invalid, verify_summary}} =
             WorldPackReleaseVerifier.verify(small_release_index(), output_dir,
               window_centers: [{0, 0, 0}],
               radius: 0
             )

    assert verify_summary.status == :invalid
    assert verify_summary.reason == :missing_pack_shards
  end

  test "explicit release shard selection stays partial until the full grid is built" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    snapshot_store = fn 91_016, chunk_coord ->
      {:ok, %{data: :erlang.term_to_binary(chunk_coord)}}
    end

    assert {:ok, summary} =
             WorldPackArtifactBuilder.build_release(small_release_index(),
               output_dir: output_dir,
               snapshot_store: snapshot_store,
               shard_coords: [{1, 0, 0}]
             )

    assert summary.status == :partial
    assert summary.expected_shards == 2
    assert summary.built_shards == 1
    assert summary.remaining_shards == 1
    assert summary.manifest == nil
    assert summary.shard_paths == ["packs/tile_1_0_0.vxpack"]
    refute File.exists?(Path.join(output_dir, "packs/tile_0_0_0.vxpack"))
    assert File.exists?(Path.join(output_dir, "packs/tile_1_0_0.vxpack"))

    assert {:error, {:world_pack_release_invalid, verify_summary}} =
             WorldPackReleaseVerifier.verify(small_release_index(), output_dir,
               window_centers: [{1, 0, 0}],
               radius: 0
             )

    assert verify_summary.status == :invalid
    assert verify_summary.reason == :missing_pack_shards
  end

  test "refuses to build payloads when the authority index is incomplete" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    snapshot_store = fn 91_015, chunk_coord ->
      {:ok, %{data: :erlang.term_to_binary(chunk_coord)}}
    end

    assert {:error, {:invalid_world_pack_index, summary}} =
             WorldPackArtifactBuilder.build_window_sequence(incomplete_index(), [{3, 3, 3}], 10,
               output_dir: output_dir,
               snapshot_store: snapshot_store
             )

    assert summary.status == :incomplete
    assert summary.reason == :bounds_not_fully_covered
    assert summary.expected_chunk_count == 444_596_224
    refute File.exists?(Path.join(output_dir, "packs/tile_64_0_64.vxpack"))
  end

  test "fails visibly when a planned snapshot is missing" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    snapshot_store = fn 91_015, {0, 0, 0} -> {:error, :snapshot_not_found} end

    assert {:error, {:missing_world_pack_snapshots, summary}} =
             WorldPackArtifactBuilder.build_window(index(), {0, 0, 0}, 0,
               output_dir: output_dir,
               snapshot_store: snapshot_store
             )

    assert summary.planned_chunks == 1
    assert summary.written_chunks == 0
    assert summary.errors == 1
    assert [%{chunk_coord: [0, 0, 0], error: ":snapshot_not_found"}] = summary.chunk_errors
    refute File.exists?(Path.join(output_dir, "packs/tile_64_0_64.vxpack"))
  end
end
