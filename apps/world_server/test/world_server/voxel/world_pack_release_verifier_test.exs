defmodule WorldServer.Voxel.WorldPackReleaseVerifierTest do
  use ExUnit.Case, async: true

  alias MmoContracts.WorldPackIndex
  alias MmoContracts.WorldPackShard
  alias WorldServer.Voxel.WorldPackArtifactBuilder
  alias WorldServer.Voxel.WorldPackReleaseVerifier

  defp index do
    WorldPackIndex.new!(
      logical_scene_id: 91_016,
      content_version: "worldgen-release-test@1",
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

  defp temp_dir do
    Path.join(
      System.tmp_dir!(),
      "world_pack_release_verifier_#{System.unique_integer([:positive])}"
    )
  end

  defp snapshot_store do
    fn 91_016, chunk_coord ->
      {:ok, %{data: :erlang.term_to_binary(chunk_coord)}}
    end
  end

  defp build_shards!(output_dir, shard_coords) do
    Enum.each(shard_coords, fn shard_coord ->
      assert {:ok, _summary} =
               WorldPackArtifactBuilder.build_shard(index(), shard_coord,
                 output_dir: output_dir,
                 snapshot_store: snapshot_store()
               )
    end)
  end

  test "verifies a complete release manifest and sampled sliding windows" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    assert {:ok, grid} = WorldPackIndex.payload_shard_grid(index())
    build_shards!(output_dir, grid.shard_coords)

    assert {:ok, manifest} = WorldPackReleaseVerifier.build_manifest(index(), output_dir)
    json_manifest = manifest |> Jason.encode!() |> Jason.decode!()

    assert {:ok, summary} =
             WorldPackReleaseVerifier.verify(index(), output_dir,
               manifest: json_manifest,
               window_centers: [{0, 0, 0}, {1, 0, 0}],
               radius: 1
             )

    assert summary.status == :ready
    assert summary.authority_expected_chunks == 36
    assert summary.expected_shards == 2
    assert summary.verified_shards == 2
    assert summary.window_count == 2
    assert summary.window_planned_chunks == 54
    assert summary.window_unique_chunks == 36

    assert Enum.map(
             summary.windows,
             &{&1.center, &1.planned_chunks, &1.loaded_chunks, &1.held_chunks}
           ) ==
             [
               {{0, 0, 0}, 27, 27, 0},
               {{1, 0, 0}, 27, 9, 18}
             ]
  end

  test "fails when any expected full-pack shard is missing even if a sampled window could read another shard" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    build_shards!(output_dir, [{0, 0, 0}])

    assert {:error, {:world_pack_release_invalid, summary}} =
             WorldPackReleaseVerifier.verify(index(), output_dir,
               window_centers: [{0, 0, 0}],
               radius: 0
             )

    assert summary.status == :invalid
    assert summary.reason == :missing_pack_shards
    assert summary.expected_shards == 2
    assert summary.verified_shards == 1
    assert summary.missing_shard_count == 1
    assert summary.first_missing_shards == ["packs/tile_1_0_0.vxpack"]
  end

  test "fails on manifest hash mismatch before sliding window validation" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    assert {:ok, grid} = WorldPackIndex.payload_shard_grid(index())
    build_shards!(output_dir, grid.shard_coords)
    assert {:ok, manifest} = WorldPackReleaseVerifier.build_manifest(index(), output_dir)

    bad_manifest =
      Map.update!(manifest, :shards, fn
        [first | rest] -> [%{first | sha256: "sha256:bad"} | rest]
      end)

    assert {:error, {:world_pack_release_invalid, summary}} =
             WorldPackReleaseVerifier.verify(index(), output_dir,
               manifest: bad_manifest,
               window_centers: [{0, 0, 0}],
               radius: 1
             )

    assert summary.status == :invalid
    assert summary.reason == :shard_hash_mismatch
    assert summary.path == "packs/tile_0_0_0.vxpack"
  end

  test "fails when manifest declares extra shard entries outside the compact index" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    assert {:ok, grid} = WorldPackIndex.payload_shard_grid(index())
    build_shards!(output_dir, grid.shard_coords)
    assert {:ok, manifest} = WorldPackReleaseVerifier.build_manifest(index(), output_dir)

    bad_manifest =
      Map.update!(manifest, :shards, fn shards ->
        shards ++
          [
            %{
              path: "packs/unexpected.vxpack",
              size_bytes: 1,
              sha256: "sha256:unexpected"
            }
          ]
      end)

    assert {:error, {:world_pack_release_invalid, summary}} =
             WorldPackReleaseVerifier.verify(index(), output_dir,
               manifest: bad_manifest,
               window_centers: [{0, 0, 0}],
               radius: 1
             )

    assert summary.status == :invalid
    assert summary.reason == :manifest_unexpected_shards
    assert summary.unexpected_shards == ["packs/unexpected.vxpack"]
  end

  test "fails when manifest repeats a shard path" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    assert {:ok, grid} = WorldPackIndex.payload_shard_grid(index())
    build_shards!(output_dir, grid.shard_coords)
    assert {:ok, manifest} = WorldPackReleaseVerifier.build_manifest(index(), output_dir)
    [first | _rest] = manifest.shards

    bad_manifest = Map.update!(manifest, :shards, &[first | &1])

    assert {:error, {:world_pack_release_invalid, summary}} =
             WorldPackReleaseVerifier.verify(index(), output_dir,
               manifest: bad_manifest,
               window_centers: [{0, 0, 0}],
               radius: 1
             )

    assert summary.status == :invalid
    assert summary.reason == :manifest_duplicate_shards
    assert summary.duplicate_shards == [first.path]
  end

  test "fails when an existing shard footer does not cover every expected local chunk" do
    output_dir = temp_dir()
    on_exit(fn -> File.rm_rf(output_dir) end)

    build_shards!(output_dir, [{1, 0, 0}])
    shard_path = Path.join(output_dir, "packs/tile_0_0_0.vxpack")
    File.mkdir_p!(Path.dirname(shard_path))

    assert {:ok, incomplete_shard} =
             WorldPackShard.encode([
               %{local_coord: {0, 0, 0}, payload: <<0x62, 0x00>>}
             ])

    File.write!(shard_path, incomplete_shard)

    assert {:error, {:world_pack_release_invalid, summary}} =
             WorldPackReleaseVerifier.verify(index(), output_dir,
               window_centers: [{-1, -1, -1}],
               radius: 0
             )

    assert summary.status == :invalid
    assert summary.reason == :shard_footer_entry_count_mismatch
    assert summary.path == "packs/tile_0_0_0.vxpack"
    assert summary.expected_entries == 18
    assert summary.actual_entries == 1
  end
end
