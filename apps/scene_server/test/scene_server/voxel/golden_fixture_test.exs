defmodule SceneServer.Voxel.GoldenFixtureTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.CatalogPatch
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Storage

  # ============================================================================
  # Phase 1.6a — server-side snapshot / delta / catalog_patch / chunk_invalidate
  # / object_state_delta golden fixture roundtrip tests.
  #
  # Each test loads a binary fixture under
  #   apps/scene_server/priv/fixtures/voxel/<name>.golden
  # plus its sidecar
  #   apps/scene_server/priv/fixtures/voxel/<name>.yaml
  # then asserts:
  #
  #   1. decode succeeds and yields a sensible struct
  #   2. re-encoding the decoded value is byte-identical to the original
  #   3. (snapshot only) Codec.chunk_hash(storage) equals the value pinned in
  #      the .yaml sidecar's `chunk_hash` field
  #
  # Generation script:
  #   apps/scene_server/priv/scripts/gen_voxel_golden_fixtures.exs
  #
  # If a fixture diverges, regenerate (deterministic), inspect the diff, and
  # treat the change as a wire break needing explicit approval before bumping
  # the fixture / chunk_hash values.
  # ============================================================================

  @fixtures_dir Path.expand("../../../priv/fixtures/voxel", __DIR__)

  defp fixture_path(name, ext), do: Path.join(@fixtures_dir, "#{name}.#{ext}")

  defp load_golden(name), do: File.read!(fixture_path(name, "golden"))

  defp load_metadata(name) do
    fixture_path(name, "yaml")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          k = String.trim(key)
          v = String.trim(value)
          Map.put(acc, k, v)

        _ ->
          acc
      end
    end)
  end

  defp parse_hex!("0x" <> hex), do: String.to_integer(hex, 16)

  # ---- snapshot fixtures -----------------------------------------------------

  @snapshot_fixtures [
    "snapshot_empty",
    "snapshot_macro_only",
    "snapshot_refined",
    "snapshot_environment",
    "snapshot_attribute_pool",
    "snapshot_tag_pool",
    "snapshot_object_refs",
    "snapshot_full",
    "snapshot_surface_elements"
  ]

  for fixture <- @snapshot_fixtures do
    test "snapshot fixture #{fixture}: decode → re-encode byte-stable + chunk_hash equivalence" do
      binary = load_golden(unquote(fixture))
      meta = load_metadata(unquote(fixture))

      # Sanity: wire_size in metadata matches actual binary size.
      assert byte_size(binary) == String.to_integer(meta["wire_size"])

      assert {:ok, decoded} = Codec.decode_chunk_snapshot_payload(binary)

      # Storage decoded with logical_scene_id / chunk_coord stable.
      assert %Storage{} = decoded.storage

      # Re-encoding the decoded storage must produce the identical golden bytes
      # (with the same request_id = 0 we wrote into the fixture).
      reencoded =
        Codec.encode_chunk_snapshot_payload(%{
          request_id: decoded.request_id,
          storage: decoded.storage
        })

      assert reencoded == binary

      # chunk_hash computed off the decoded Storage must match the value pinned
      # in the sidecar metadata; this is the cross-language hash truth source.
      expected_hash = parse_hex!(meta["chunk_hash"])
      assert Codec.chunk_hash(decoded.storage) == expected_hash
      assert decoded.chunk_hash == expected_hash
      assert decoded.computed_chunk_hash == expected_hash
    end
  end

  # ---- delta fixtures --------------------------------------------------------

  @delta_fixtures [
    "delta_cell_solid",
    "delta_cell_empty",
    "delta_cell_refined",
    "delta_multi_op"
  ]

  for fixture <- @delta_fixtures do
    test "delta fixture #{fixture}: decode → re-encode byte-stable" do
      binary = load_golden(unquote(fixture))
      meta = load_metadata(unquote(fixture))

      assert byte_size(binary) == String.to_integer(meta["wire_size"])

      assert {:ok, decoded} = Codec.decode_chunk_delta_payload(binary)

      reencoded = Codec.encode_chunk_delta_payload(decoded)
      assert reencoded == binary
    end
  end

  # ---- chunk_invalidate fixtures --------------------------------------------

  @chunk_invalidate_fixtures [
    {"chunk_invalidate_unspecified", 0x00, :unspecified},
    {"chunk_invalidate_migration_cutover", 0x01, :migration_cutover},
    {"chunk_invalidate_region_removed", 0x02, :region_removed},
    {"chunk_invalidate_catalog_changed", 0x03, :catalog_changed}
  ]

  for {fixture, reason, reason_name} <- @chunk_invalidate_fixtures do
    test "chunk_invalidate fixture #{fixture}: decode → re-encode byte-stable, reason 0x#{Integer.to_string(reason, 16)}" do
      binary = load_golden(unquote(fixture))
      meta = load_metadata(unquote(fixture))

      assert byte_size(binary) == String.to_integer(meta["wire_size"])

      assert {:ok, decoded} = Codec.decode_chunk_invalidate_payload(binary)
      assert decoded.reason == unquote(reason)
      assert decoded.reason_name == unquote(reason_name)

      reencoded = Codec.encode_chunk_invalidate_payload(decoded)
      assert reencoded == binary
    end
  end

  # ---- object_state_delta fixtures ------------------------------------------

  @object_state_delta_fixtures [
    "object_state_delta_damaged",
    "object_state_delta_part_destroyed",
    "object_state_delta_destroyed"
  ]

  for fixture <- @object_state_delta_fixtures do
    test "object_state_delta fixture #{fixture}: decode → re-encode byte-stable" do
      binary = load_golden(unquote(fixture))
      meta = load_metadata(unquote(fixture))

      assert byte_size(binary) == String.to_integer(meta["wire_size"])

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(binary)

      reencoded = Codec.encode_voxel_object_state_delta_payload(decoded)
      assert reencoded == binary
    end
  end

  # ---- catalog_patch fixtures -----------------------------------------------

  @catalog_patch_fixtures [
    "catalog_patch_attribute_add",
    "catalog_patch_tag_remove",
    "catalog_patch_forward_compat_skip"
  ]

  for fixture <- @catalog_patch_fixtures do
    test "catalog_patch fixture #{fixture}: decode → re-encode byte-stable" do
      binary = load_golden(unquote(fixture))
      meta = load_metadata(unquote(fixture))

      assert byte_size(binary) == String.to_integer(meta["wire_size"])

      assert {:ok, patch} = CatalogPatch.decode_for_wire(binary)

      reencoded = CatalogPatch.encode_for_wire(patch)
      assert reencoded == binary
    end
  end

  # ---- specific structural assertions ---------------------------------------
  #
  # Light spot-checks on individual fixtures so a refactor that quietly fills
  # in different field values is caught even if the binary still roundtrips.

  test "snapshot_attribute_pool carries one AttributeSet covering all 5 value_type tags" do
    binary = load_golden("snapshot_attribute_pool")
    assert {:ok, decoded} = Codec.decode_chunk_snapshot_payload(binary)

    assert [set] = decoded.storage.attribute_sets
    value_types = set.entries |> Enum.map(& &1.value_type) |> Enum.sort()
    assert value_types == [0x01, 0x02, 0x03, 0x04, 0x05]
  end

  test "snapshot_tag_pool carries two TagSets" do
    binary = load_golden("snapshot_tag_pool")
    assert {:ok, decoded} = Codec.decode_chunk_snapshot_payload(binary)

    assert length(decoded.storage.tag_sets) == 2
  end

  test "snapshot_environment carries a non-empty environment_summaries section" do
    binary = load_golden("snapshot_environment")
    assert {:ok, decoded} = Codec.decode_chunk_snapshot_payload(binary)

    assert [env] = decoded.storage.environment_summaries
    assert env.field_mask != 0
    assert env.source_hash != 0
  end

  test "snapshot_surface_elements carries section 0x08 surface elements (torch/rust_decal/frost)" do
    alias SceneServer.Voxel.SurfaceCatalog
    binary = load_golden("snapshot_surface_elements")
    assert {:ok, decoded} = Codec.decode_chunk_snapshot_payload(binary)

    elements = decoded.storage.surface_elements
    assert length(elements) == 3

    type_ids = elements |> Enum.map(& &1.surface_type_id) |> Enum.sort()

    assert type_ids ==
             Enum.sort([
               SurfaceCatalog.surface_type_id(:torch),
               SurfaceCatalog.surface_type_id(:rust_decal),
               SurfaceCatalog.surface_type_id(:frost)
             ])

    # 带 attr/tag/owner 的那条(frost)字段还原。
    frost =
      Enum.find(elements, &(&1.surface_type_id == SurfaceCatalog.surface_type_id(:frost)))

    assert frost.attribute_set_ref == 3
    assert frost.tag_set_ref == 5
    assert frost.owner_actor_id == 12_345
  end

  test "snapshot_refined carries refined cells with owner_object_id provenance" do
    binary = load_golden("snapshot_refined")
    assert {:ok, decoded} = Codec.decode_chunk_snapshot_payload(binary)

    assert [cell] = decoded.storage.refined_cells

    assert Enum.any?(cell.layers, fn layer -> layer.owner_object_id != 0 end)
  end

  test "delta_cell_refined op carries a non-trivial RefinedCellData payload" do
    binary = load_golden("delta_cell_refined")
    assert {:ok, decoded} = Codec.decode_chunk_delta_payload(binary)

    assert [op] = decoded.ops
    assert op.delta_kind == 2

    refined = Codec.decode_refined_cell_payload!(op.payload)
    assert refined.layers |> length() >= 1
  end

  test "delta_multi_op carries exactly three ops with mixed delta_kinds" do
    binary = load_golden("delta_multi_op")
    assert {:ok, decoded} = Codec.decode_chunk_delta_payload(binary)

    assert length(decoded.ops) == 3
    kinds = decoded.ops |> Enum.map(& &1.delta_kind)
    assert 0 in kinds and 1 in kinds
  end

  test "catalog_patch_forward_compat_skip preserves unknown op_kind 0xFE round-trip" do
    binary = load_golden("catalog_patch_forward_compat_skip")
    assert {:ok, patch} = CatalogPatch.decode_for_wire(binary)

    assert Enum.any?(patch.ops, fn op -> op.op_kind == 0xFE end)

    # Re-encode is byte-identical (Phase 1.4 forward-compat pass-through).
    assert CatalogPatch.encode_for_wire(patch) == binary
  end

  test "catalog_patch_attribute_add carries schema_kind=0x01 with one add op" do
    binary = load_golden("catalog_patch_attribute_add")
    assert {:ok, patch} = CatalogPatch.decode_for_wire(binary)

    assert patch.schema_kind == 0x01
    assert [%{op_kind: 0x01}] = patch.ops
  end

  test "catalog_patch_tag_remove carries schema_kind=0x02 with one remove op" do
    binary = load_golden("catalog_patch_tag_remove")
    assert {:ok, patch} = CatalogPatch.decode_for_wire(binary)

    assert patch.schema_kind == 0x02
    assert [%{op_kind: 0x02}] = patch.ops
  end

  # ---- 3 pinned chunk_hash baseline byte-stability check --------------------
  #
  # The codec_test.exs pinned baselines `@empty_baseline_chunk_hash`,
  # `@seed_baseline_chunk_hash`, `@mixed_baseline_chunk_hash` come from
  # `priv/scripts/pin_chunk_hash_baseline.exs`. Phase 1.6a must not change
  # those values. Re-pin and assert here so this test file catches any drift
  # introduced by future fixture-generation refactors.

  test "Phase 1a pinned chunk_hash baselines remain byte-stable" do
    alias SceneServer.Voxel.MacroEnvironmentSummary
    alias SceneServer.Voxel.NormalBlockData

    empty = Storage.empty(42, {-1, 0, 2}, chunk_version: 7)

    seed_storage = fn ->
      base = Storage.empty(123, {0, 0, 0}, chunk_version: 9)
      block = NormalBlockData.new(11, health: 100)

      Enum.reduce(0..8, base, fn i, acc ->
        mx = rem(i, 3)
        mz = div(i, 3)

        Storage.put_solid_block(acc, {mx, 0, mz}, block,
          cell_version: 1,
          cell_hash: 0xA000_0000 + i
        )
      end)
    end

    seed = seed_storage.()

    mixed =
      %{
        seed
        | environment_summaries: [
            MacroEnvironmentSummary.new(
              default_temperature: 20,
              default_moisture: 40,
              current_temperature: 25,
              current_moisture: 38,
              field_mask: 0x000F,
              source_hash: 0xCAFE_BABE
            )
          ]
      }
      |> Storage.normalize!()

    assert Codec.chunk_hash(empty) == 0x0980_DF98_C2DA_1FFC
    assert Codec.chunk_hash(seed) == 0x7B46_B0F3_33B6_3489
    assert Codec.chunk_hash(mixed) == 0x7491_619E_9791_DFB9
  end
end
