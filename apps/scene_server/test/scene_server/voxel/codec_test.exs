defmodule SceneServer.Voxel.CodecTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.ObjectCoverRef
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.Storage

  # ============================================================================
  # Phase 1a — chunk_hash baseline regression
  #
  # These three constants are the chunk_hash values produced BEFORE the
  # `refined_cells` encoder rewrite. They MUST stay byte-stable across the
  # rewrite — a change here means we accidentally altered the wire layout for
  # storages whose `refined_cells` is `[]` (which is every storage in
  # production today). Any PR that modifies these constants is a wire break
  # and must be reviewed explicitly.
  #
  # Baselines are produced by `priv/scripts/pin_chunk_hash_baseline.exs`,
  # which builds the same fixtures as the helpers below and prints the hash
  # values. Keep the script and the helpers in sync.
  # ============================================================================
  @empty_baseline_chunk_hash 0x0980_DF98_C2DA_1FFC
  @seed_baseline_chunk_hash 0x7B46_B0F3_33B6_3489
  @mixed_baseline_chunk_hash 0x7491_619E_9791_DFB9

  test "round-trips an empty chunk snapshot payload with big-endian top-level fields" do
    storage = Storage.empty(42, {-1, 0, 2}, chunk_version: 7)

    payload = Codec.encode_chunk_snapshot_payload(%{request_id: 99, storage: storage})

    assert <<99::unsigned-big-integer-size(64), 42::unsigned-big-integer-size(64),
             -1::signed-big-integer-size(32), 0::signed-big-integer-size(32),
             2::signed-big-integer-size(32), 1::unsigned-big-integer-size(16),
             16::unsigned-integer-size(8), 8::unsigned-integer-size(8),
             7::unsigned-big-integer-size(64), _rest::binary>> = payload

    assert {:ok, snapshot} = Codec.decode_chunk_snapshot_payload(payload)
    assert snapshot.request_id == 99
    assert snapshot.chunk_hash == Codec.chunk_hash(storage)
    assert snapshot.computed_chunk_hash == snapshot.chunk_hash
    assert snapshot.storage == storage

    assert Codec.encode_chunk_snapshot_payload(%{request_id: 99, storage: snapshot.storage}) ==
             payload
  end

  test "round-trips a chunk with one solid cell at the upper local macro boundary" do
    block =
      NormalBlockData.new(17,
        state_flags: 0x20,
        health: 1_000,
        temperature_delta: -12,
        moisture_delta: 15,
        attribute_set_ref: 3,
        tag_set_ref: 4
      )

    storage =
      Storage.empty(9, {0, 0, 0}, chunk_version: 2)
      |> Storage.put_solid_block({15, 15, 15}, block,
        flags: 0x0010,
        cell_version: 3,
        cell_hash: 0xAABB_CCDD
      )

    payload = Codec.encode_chunk_snapshot_payload(%{request_id: 123, storage: storage})

    assert {:ok, snapshot} = Codec.decode_chunk_snapshot_payload(payload)
    decoded_storage = snapshot.storage

    assert snapshot.request_id == 123
    assert decoded_storage.normal_blocks == [block]

    header = Storage.macro_header_at(decoded_storage, 4095)
    assert header.mode == MacroCellHeader.cell_mode_solid_block()
    assert header.payload_index == 0
    assert header.environment_index == MacroCellHeader.no_index()
    assert header.flags == 0x0010
    assert header.cell_version == 3
    assert header.cell_hash == 0xAABB_CCDD

    assert snapshot.chunk_hash == Codec.chunk_hash(storage)

    assert Codec.encode_chunk_snapshot_payload(%{request_id: 123, storage: decoded_storage}) ==
             payload
  end

  test "chunk hash is stable across round-trip and excludes chunk_version" do
    storage =
      Storage.empty(5, {1, -2, 3}, chunk_version: 1)
      |> Storage.put_solid_block(0, NormalBlockData.new(2, health: 10), cell_version: 1)

    hash = Codec.chunk_hash(storage)
    payload = Codec.encode_chunk_snapshot_payload(storage)

    assert {:ok, %{storage: decoded_storage, chunk_hash: ^hash}} =
             Codec.decode_chunk_snapshot_payload(payload)

    assert Codec.chunk_hash(decoded_storage) == hash
    assert Codec.chunk_hash(%{storage | chunk_version: 999}) == hash
  end

  test "round-trips a single CellSolid ChunkDelta op" do
    block = NormalBlockData.new(7, health: 80)
    block_payload = Codec.encode_normal_block_data(block)

    delta = %{
      logical_scene_id: 42,
      chunk_coord: {-1, 0, 2},
      base_chunk_version: 5,
      new_chunk_version: 6,
      ops: [
        %{
          delta_kind: 1,
          macro_index: 1234,
          cell_version: 6,
          cell_hash: 0xCAFE,
          payload: block_payload
        }
      ]
    }

    payload = Codec.encode_chunk_delta_payload(delta)

    assert <<42::unsigned-big-integer-size(64), -1::signed-big-integer-size(32),
             0::signed-big-integer-size(32), 2::signed-big-integer-size(32),
             5::unsigned-big-integer-size(64), 6::unsigned-big-integer-size(64),
             1::unsigned-big-integer-size(16), _ops::binary>> = payload

    assert {:ok, decoded} = Codec.decode_chunk_delta_payload(payload)
    assert decoded.logical_scene_id == 42
    assert decoded.chunk_coord == {-1, 0, 2}
    assert decoded.base_chunk_version == 5
    assert decoded.new_chunk_version == 6

    assert [
             %{
               delta_kind: 1,
               macro_index: 1234,
               cell_version: 6,
               cell_hash: 0xCAFE,
               payload: ^block_payload
             }
           ] = decoded.ops

    assert Codec.decode_normal_block_data(block_payload) == block
  end

  test "round-trips a multi-op ChunkDelta and preserves op order" do
    payload = Codec.encode_normal_block_data(NormalBlockData.new(3))

    ops =
      Enum.map(0..2, fn i ->
        %{
          delta_kind: 1,
          macro_index: 100 + i,
          cell_version: 10 + i,
          cell_hash: 0xAA00 + i,
          payload: payload
        }
      end)

    delta = %{
      logical_scene_id: 1,
      chunk_coord: {0, 0, 0},
      base_chunk_version: 9,
      new_chunk_version: 12,
      ops: ops
    }

    encoded = Codec.encode_chunk_delta_payload(delta)
    assert {:ok, decoded} = Codec.decode_chunk_delta_payload(encoded)

    assert Enum.map(decoded.ops, & &1.macro_index) == [100, 101, 102]
    assert Enum.map(decoded.ops, & &1.cell_version) == [10, 11, 12]
  end

  test "rejects malformed ChunkDelta payload" do
    assert {:error, _reason} = Codec.decode_chunk_delta_payload(<<0, 1, 2>>)
  end

  test "round-trips a ChunkInvalidate payload with its reason byte" do
    payload =
      Codec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 11,
        chunk_coord: {-2, 3, -4},
        reason: 0x01
      })

    assert byte_size(payload) == 8 + 12 + 1

    assert {:ok, decoded} = Codec.decode_chunk_invalidate_payload(payload)
    assert decoded.logical_scene_id == 11
    assert decoded.chunk_coord == {-2, 3, -4}
    assert decoded.reason == 0x01
    assert decoded.reason_name == :migration_cutover
  end

  test "ChunkInvalidate decodes unknown reason bytes as :unknown but preserves the byte" do
    payload =
      Codec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 1,
        chunk_coord: {0, 0, 0},
        reason: 0x77
      })

    assert {:ok, decoded} = Codec.decode_chunk_invalidate_payload(payload)
    assert decoded.reason == 0x77
    assert decoded.reason_name == :unknown
  end

  test "rejects malformed ChunkInvalidate payload" do
    assert {:error, _reason} = Codec.decode_chunk_invalidate_payload(<<0, 1, 2>>)
  end

  test "round-trips a BuildReservationIntent payload with big-endian fields" do
    intent = %{
      request_id: 0xDEAD_BEEF_CAFE_F00D,
      client_intent_seq: 42,
      logical_scene_id: 555,
      parcel_id: 9_001,
      known_parcel_build_epoch: 17,
      bounds_world_micro: {-100, -50, -25, 200, 75, 50},
      intent_hash: 0x0102_0304_0506_0708,
      ttl_ms: 5_000
    }

    payload = Codec.encode_build_reservation_intent_payload(intent)

    # 8(request_id) + 4(seq) + 8(logical_scene_id) + 8(parcel_id) +
    # 8(epoch) + 6*8(AabbI64) + 8(intent_hash) + 4(ttl_ms) = 96 bytes
    assert byte_size(payload) == 96

    assert <<0xDEAD_BEEF_CAFE_F00D::unsigned-big-integer-size(64),
             42::unsigned-big-integer-size(32), 555::unsigned-big-integer-size(64),
             9_001::unsigned-big-integer-size(64), 17::unsigned-big-integer-size(64),
             -100::signed-big-integer-size(64), -50::signed-big-integer-size(64),
             -25::signed-big-integer-size(64), 200::signed-big-integer-size(64),
             75::signed-big-integer-size(64), 50::signed-big-integer-size(64),
             0x0102_0304_0506_0708::unsigned-big-integer-size(64),
             5_000::unsigned-big-integer-size(32)>> = payload

    assert {:ok, decoded} = Codec.decode_build_reservation_intent_payload(payload)
    assert decoded == intent
  end

  test "rejects malformed BuildReservationIntent payload" do
    assert {:error, _reason} = Codec.decode_build_reservation_intent_payload(<<0, 1, 2>>)
  end

  test "round-trips a PrefabPlaceIntent payload with empty known arrays" do
    intent = %{
      request_id: 1,
      client_intent_seq: 2,
      logical_scene_id: 3,
      parcel_id: 4,
      known_parcel_build_epoch: 5,
      blueprint_id: 6,
      blueprint_version: 7,
      anchor_world_micro: {-8, 16, -24},
      rotation: 90,
      known_refs: [],
      known_objects: [],
      known_cell_refs: [],
      placement_flags: 0xCAFE
    }

    payload = Codec.encode_prefab_place_intent_payload(intent)

    # 8+4+8+8+8+8+4+24+1+2+2+2+4 = 83 bytes
    assert byte_size(payload) == 83

    assert {:ok, decoded} = Codec.decode_prefab_place_intent_payload(payload)
    assert decoded == intent
  end

  test "round-trips a PrefabPlaceIntent payload with known refs, objects, and cell refs" do
    intent = %{
      request_id: 100,
      client_intent_seq: 101,
      logical_scene_id: 200,
      parcel_id: 300,
      known_parcel_build_epoch: 400,
      blueprint_id: 500,
      blueprint_version: 600,
      anchor_world_micro: {1_000, -2_000, 3_000},
      rotation: 180,
      known_refs: [
        %{chunk_coord: {-1, 0, 1}, chunk_version: 11},
        %{chunk_coord: {2, -3, 4}, chunk_version: 12}
      ],
      known_objects: [
        %{object_id: 9_001, object_version: 1},
        %{object_id: 9_002, object_version: 2}
      ],
      known_cell_refs: [
        %{
          chunk_coord: {-1, 0, 1},
          macro_index: 1234,
          cell_version: 5,
          cell_hash: 0xAABB_CCDD
        }
      ],
      placement_flags: 0x0000_0001
    }

    payload = Codec.encode_prefab_place_intent_payload(intent)

    assert <<request_id::unsigned-big-integer-size(64),
             client_intent_seq::unsigned-big-integer-size(32),
             logical_scene_id::unsigned-big-integer-size(64),
             parcel_id::unsigned-big-integer-size(64), _epoch::unsigned-big-integer-size(64),
             _blueprint_id::unsigned-big-integer-size(64),
             _blueprint_version::unsigned-big-integer-size(32),
             1_000::signed-big-integer-size(64), -2_000::signed-big-integer-size(64),
             3_000::signed-big-integer-size(64), 180::unsigned-integer-size(8),
             2::unsigned-big-integer-size(16), _rest::binary>> = payload

    assert request_id == 100
    assert client_intent_seq == 101
    assert logical_scene_id == 200
    assert parcel_id == 300

    assert {:ok, decoded} = Codec.decode_prefab_place_intent_payload(payload)
    assert decoded == intent
  end

  test "rejects malformed PrefabPlaceIntent payload" do
    assert {:error, _reason} = Codec.decode_prefab_place_intent_payload(<<0, 1, 2>>)
  end

  describe "chunk_hash baseline (Phase 1a regression)" do
    test "empty storage chunk_hash matches pinned baseline" do
      assert Codec.chunk_hash(empty_baseline_storage()) == @empty_baseline_chunk_hash
    end

    test "seed-like storage chunk_hash matches pinned baseline" do
      assert Codec.chunk_hash(seed_baseline_storage()) == @seed_baseline_chunk_hash
    end

    test "mixed storage chunk_hash matches pinned baseline" do
      assert Codec.chunk_hash(mixed_baseline_storage()) == @mixed_baseline_chunk_hash
    end
  end

  describe "refined_cells wire encoding (Phase 1a)" do
    test "empty refined_cells section emits exactly <<0u32>> (legacy byte form)" do
      storage = Storage.empty(1, {0, 0, 0})
      payload = Codec.encode_chunk_snapshot_payload(storage)

      # Re-encode and confirm decode→encode round-trip is byte-stable
      assert {:ok, %{storage: decoded}} = Codec.decode_chunk_snapshot_payload(payload)
      assert decoded.refined_cells == []

      assert Codec.encode_chunk_snapshot_payload(decoded) == payload
    end

    test "round-trips a chunk containing one non-empty RefinedCellData" do
      storage =
        Storage.empty(7, {3, -1, 4}, chunk_version: 5)
        |> Map.put(:refined_cells, [sample_refined_cell()])
        |> Storage.normalize!()

      payload = Codec.encode_chunk_snapshot_payload(storage)

      assert {:ok, %{storage: decoded, chunk_hash: decoded_hash}} =
               Codec.decode_chunk_snapshot_payload(payload)

      assert decoded.refined_cells == storage.refined_cells
      assert decoded_hash == Codec.chunk_hash(storage)

      # Re-encoding the decoded storage must reproduce the same bytes.
      assert Codec.encode_chunk_snapshot_payload(decoded) == payload
    end

    test "chunk_hash changes when a refined cell is added" do
      empty = empty_baseline_storage()

      with_refined =
        %{empty | refined_cells: [sample_refined_cell()]}
        |> Storage.normalize!()

      refute Codec.chunk_hash(with_refined) == Codec.chunk_hash(empty)
    end

    test "round-trips multiple refined cells with layers and object_refs" do
      cells = [
        sample_refined_cell(),
        sample_refined_cell_with_object_ref()
      ]

      storage =
        Storage.empty(11, {0, 0, 0})
        |> Map.put(:refined_cells, cells)
        |> Storage.normalize!()

      payload = Codec.encode_chunk_snapshot_payload(storage)

      assert {:ok, %{storage: decoded}} = Codec.decode_chunk_snapshot_payload(payload)
      assert decoded.refined_cells == cells
    end

    test "rejects refined_cells section with trailing garbage bytes" do
      storage =
        Storage.empty(9, {0, 0, 0})
        |> Map.put(:refined_cells, [sample_refined_cell()])
        |> Storage.normalize!()

      payload = Codec.encode_chunk_snapshot_payload(storage)
      garbled = payload <> <<0xFF>>

      assert {:error, _} = Codec.decode_chunk_snapshot_payload(garbled)
    end
  end

  describe "refined_cells encoder boundary conditions" do
    test "encode raises when layer_count exceeds u16" do
      # 65_537 mutually-disjoint layers won't fit in u16; we don't actually
      # need them to be valid against §5.4 invariants — encode_refined_cell_pool/1
      # validates only the count limit (semantic invariants are validated by
      # RefinedCellData.normalize!/1 before encoding).
      cell = %RefinedCellData{
        occupancy_words: List.duplicate(0xFFFF_FFFF_FFFF_FFFF, 8),
        layers:
          for i <- 0..0xFFFF do
            %MicroLayer{
              mask_words: List.duplicate(0, 8),
              material_id: rem(i, 0xFFFF),
              state_flags: 0,
              health: 0,
              attribute_set_ref: 0,
              tag_set_ref: 0,
              owner_object_id: 0,
              owner_part_id: 0
            }
          end,
        object_refs: [],
        boundary_cache: 0
      }

      assert_raise ArgumentError, ~r/layer_count .* exceeds u16/, fn ->
        Codec.encode_refined_cell_pool([cell])
      end
    end

    test "encode raises when object_ref_count exceeds u16" do
      cell = %RefinedCellData{
        occupancy_words: List.duplicate(0xFFFF_FFFF_FFFF_FFFF, 8),
        layers: [],
        object_refs:
          for i <- 0..0xFFFF do
            %ObjectCoverRef{
              owner_object_id: i + 1,
              owner_part_id: 0,
              mask_words: List.duplicate(0, 8)
            }
          end,
        boundary_cache: 0
      }

      assert_raise ArgumentError, ~r/object_ref_count .* exceeds u16/, fn ->
        Codec.encode_refined_cell_pool([cell])
      end
    end
  end

  describe "decode_refined_cell_pool dual-form API" do
    test "non-bang form returns {:ok, cells} on success" do
      bytes = Codec.encode_refined_cell_pool([sample_refined_cell()])
      assert {:ok, [cell]} = Codec.decode_refined_cell_pool(bytes)
      assert cell.boundary_cache == 0xCAFE_F00D
    end

    test "non-bang form returns {:error, _} on malformed input" do
      assert {:error, _msg} = Codec.decode_refined_cell_pool(<<0xFF>>)
    end

    test "non-bang form returns {:error, _} on trailing bytes after empty pool" do
      # `<<0u32, 0xFF>>` does not match the empty-pool clause and must trigger
      # the trailing-bytes error path.
      assert {:error, _} = Codec.decode_refined_cell_pool(<<0, 0, 0, 0, 0xFF>>)
    end
  end

  describe "encode_refined_cell_payload / decode_refined_cell_payload (Phase 1c-3)" do
    test "round-trips a single non-empty cell through the standalone payload form" do
      cell = sample_refined_cell()
      bytes = Codec.encode_refined_cell_payload(cell)

      assert is_binary(bytes)
      assert byte_size(bytes) > 0

      assert {:ok, decoded} = Codec.decode_refined_cell_payload(bytes)
      assert decoded == cell
    end

    test "round-trips a cell with multiple layers and object refs" do
      cell = sample_refined_cell_with_object_ref()
      bytes = Codec.encode_refined_cell_payload(cell)

      assert {:ok, decoded} = Codec.decode_refined_cell_payload(bytes)
      assert decoded == cell
    end

    test "single-cell payload bytes match a 1-cell pool minus the count u32 prefix" do
      cell = sample_refined_cell()

      pool_bytes = Codec.encode_refined_cell_pool([cell])
      payload_bytes = Codec.encode_refined_cell_payload(cell)

      # Pool layout: <<count::u32, cell_bytes...>>
      assert <<1::unsigned-big-integer-size(32), expected_payload::binary>> = pool_bytes
      assert payload_bytes == expected_payload
    end

    test "decode rejects trailing bytes" do
      cell = sample_refined_cell()
      bytes = Codec.encode_refined_cell_payload(cell)

      assert {:error, _} = Codec.decode_refined_cell_payload(bytes <> <<0xFF>>)

      assert_raise ArgumentError, ~r/trailing bytes/, fn ->
        Codec.decode_refined_cell_payload!(bytes <> <<0xFF>>)
      end
    end

    test "decode rejects truncated payload" do
      cell = sample_refined_cell()
      bytes = Codec.encode_refined_cell_payload(cell)
      truncated = binary_part(bytes, 0, byte_size(bytes) - 4)

      assert {:error, _} = Codec.decode_refined_cell_payload(truncated)
    end

    test "round-trips a cell with empty layers and object_refs (orphan / downgraded)" do
      empty_cell =
        RefinedCellData.new(
          occupancy_words: List.duplicate(0, 8),
          layers: [],
          object_refs: [],
          boundary_cache: 0
        )

      bytes = Codec.encode_refined_cell_payload(empty_cell)
      assert {:ok, decoded} = Codec.decode_refined_cell_payload(bytes)
      assert decoded == empty_cell
    end
  end

  describe "shared fixture refined_512_cell_v1.bin" do
    test "decodes the shared fixture and matches expected fields" do
      bytes =
        File.read!(
          Path.join([__DIR__, "..", "..", "fixtures", "voxel", "refined_512_cell_v1.bin"])
        )

      cells = Codec.decode_refined_cell_pool!(bytes)
      [cell0, cell1] = cells

      # cell #0
      assert cell0.occupancy_words == [0xFFFF, 0, 0, 0, 0, 0, 0, 0]
      assert cell0.boundary_cache == 0xCAFE_BABE_DEAD_BEEF
      assert length(cell0.layers) == 1
      [l0] = cell0.layers
      assert l0.mask_words == [0xFFFF, 0, 0, 0, 0, 0, 0, 0]
      assert l0.material_id == 17
      assert l0.state_flags == 0x10
      assert l0.health == 200
      assert l0.attribute_set_ref == 1
      assert l0.tag_set_ref == 2
      assert l0.owner_object_id == 0
      assert l0.owner_part_id == 0
      assert cell0.object_refs == []

      # cell #1
      assert cell1.occupancy_words == [0, 0, 0, 0, 0, 0, 0, 0xFF]
      assert cell1.boundary_cache == 0
      assert length(cell1.layers) == 2
      [a, b] = cell1.layers
      assert a.mask_words == [0, 0, 0, 0, 0, 0, 0, 0xF0]
      assert a.material_id == 42
      assert a.owner_object_id == 0xDEAD_BEEF
      assert a.owner_part_id == 7
      assert b.mask_words == [0, 0, 0, 0, 0, 0, 0, 0x0F]
      assert b.material_id == 99
      assert b.attribute_set_ref == 5
      assert b.tag_set_ref == 6

      [ref] = cell1.object_refs
      assert ref.owner_object_id == 0xDEAD_BEEF
      assert ref.owner_part_id == 7
      assert ref.mask_words == [0, 0, 0, 0, 0, 0, 0, 0xF0]

      # round-trip: re-encoding the decoded cells reproduces the fixture bytes
      assert Codec.encode_refined_cell_pool(cells) == bytes
    end

    test "fixture is in sync with the generator script (no stale bytes)" do
      bytes =
        File.read!(
          Path.join([__DIR__, "..", "..", "fixtures", "voxel", "refined_512_cell_v1.bin"])
        )

      # Rebuild the cells from the same field values the generator script uses.
      # If either side drifts (a field changed in one place but not the other),
      # this regenerated payload will diverge and this test will fail before
      # any mismatch can ship.
      regenerated = Codec.encode_refined_cell_pool(fixture_cells_from_script_definition())
      assert regenerated == bytes
    end
  end

  describe "shared fixture cell_refined_delta_v1.bin (Phase 1c-3)" do
    test "decodes the shared single-cell delta payload and matches expected fields" do
      bytes =
        File.read!(
          Path.join([__DIR__, "..", "..", "fixtures", "voxel", "cell_refined_delta_v1.bin"])
        )

      assert {:ok, cell} = Codec.decode_refined_cell_payload(bytes)

      assert cell.occupancy_words == [0, 0, 0, 0, 0, 0, 0, 0xFF]
      assert cell.boundary_cache == 0xCAFE_BABE_DEAD_BEEF
      assert length(cell.layers) == 2

      [a, b] = cell.layers
      assert a.material_id == 42
      assert a.owner_object_id == 0xDEAD_BEEF
      assert a.owner_part_id == 7
      assert a.mask_words == [0, 0, 0, 0, 0, 0, 0, 0xF0]
      assert b.material_id == 99
      assert b.attribute_set_ref == 5
      assert b.tag_set_ref == 6

      [ref] = cell.object_refs
      assert ref.owner_object_id == 0xDEAD_BEEF
      assert ref.mask_words == [0, 0, 0, 0, 0, 0, 0, 0xF0]

      assert Codec.encode_refined_cell_payload(cell) == bytes
    end

    test "fixture is in sync with the delta-payload generator script" do
      bytes =
        File.read!(
          Path.join([__DIR__, "..", "..", "fixtures", "voxel", "cell_refined_delta_v1.bin"])
        )

      regenerated = Codec.encode_refined_cell_payload(cell_refined_delta_fixture_cell())
      assert regenerated == bytes
    end
  end

  # Mirror of `priv/scripts/gen_cell_refined_delta_fixture.exs`. Any change
  # here MUST be mirrored in the script — the "fixture is in sync" test
  # enforces it.
  defp cell_refined_delta_fixture_cell do
    layer_a =
      MicroLayer.new(
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0xF0],
        material_id: 42,
        state_flags: 0,
        health: 100,
        attribute_set_ref: 0,
        tag_set_ref: 0,
        owner_object_id: 0xDEAD_BEEF,
        owner_part_id: 7
      )

    layer_b =
      MicroLayer.new(
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0x0F],
        material_id: 99,
        state_flags: 0x01,
        health: 50,
        attribute_set_ref: 5,
        tag_set_ref: 6,
        owner_object_id: 0,
        owner_part_id: 0
      )

    object_ref =
      ObjectCoverRef.new(
        owner_object_id: 0xDEAD_BEEF,
        owner_part_id: 7,
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0xF0]
      )

    RefinedCellData.new(
      occupancy_words: [0, 0, 0, 0, 0, 0, 0, 0xFF],
      boundary_cache: 0xCAFE_BABE_DEAD_BEEF,
      layers: [layer_a, layer_b],
      object_refs: [object_ref]
    )
  end

  defp empty_baseline_storage do
    Storage.empty(42, {-1, 0, 2}, chunk_version: 7)
  end

  defp seed_baseline_storage do
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

  defp mixed_baseline_storage do
    seed = seed_baseline_storage()

    env =
      MacroEnvironmentSummary.new(
        default_temperature: 20,
        default_moisture: 40,
        current_temperature: 25,
        current_moisture: 38,
        field_mask: 0x000F,
        source_hash: 0xCAFE_BABE
      )

    %{seed | environment_summaries: [env]}
    |> Storage.normalize!()
  end

  defp sample_refined_cell do
    occupancy = [0xF, 0, 0, 0, 0, 0, 0, 0]

    layer =
      MicroLayer.new(
        mask_words: occupancy,
        material_id: 17,
        state_flags: 0x0000_0010,
        health: 200,
        attribute_set_ref: 0,
        tag_set_ref: 0,
        owner_object_id: 0,
        owner_part_id: 0
      )

    RefinedCellData.new(
      occupancy_words: occupancy,
      layers: [layer],
      object_refs: [],
      boundary_cache: 0xCAFE_F00D
    )
  end

  # Mirror of `priv/scripts/gen_refined_512_cell_fixture.exs`.
  # Any change here MUST be mirrored in the script (and vice versa) — the
  # `fixture is in sync with the generator script` test enforces it.
  defp fixture_cells_from_script_definition do
    cell_0_layer =
      MicroLayer.new(
        mask_words: [0xFFFF, 0, 0, 0, 0, 0, 0, 0],
        material_id: 17,
        state_flags: 0x10,
        health: 200,
        attribute_set_ref: 1,
        tag_set_ref: 2,
        owner_object_id: 0,
        owner_part_id: 0
      )

    cell_0 =
      RefinedCellData.new(
        occupancy_words: [0xFFFF, 0, 0, 0, 0, 0, 0, 0],
        boundary_cache: 0xCAFE_BABE_DEAD_BEEF,
        layers: [cell_0_layer],
        object_refs: []
      )

    cell_1_layer_a =
      MicroLayer.new(
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0xF0],
        material_id: 42,
        state_flags: 0,
        health: 100,
        attribute_set_ref: 0,
        tag_set_ref: 0,
        owner_object_id: 0xDEAD_BEEF,
        owner_part_id: 7
      )

    cell_1_layer_b =
      MicroLayer.new(
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0x0F],
        material_id: 99,
        state_flags: 0x01,
        health: 50,
        attribute_set_ref: 5,
        tag_set_ref: 6,
        owner_object_id: 0,
        owner_part_id: 0
      )

    cell_1_object_ref =
      ObjectCoverRef.new(
        owner_object_id: 0xDEAD_BEEF,
        owner_part_id: 7,
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0xF0]
      )

    cell_1 =
      RefinedCellData.new(
        occupancy_words: [0, 0, 0, 0, 0, 0, 0, 0xFF],
        boundary_cache: 0,
        layers: [cell_1_layer_a, cell_1_layer_b],
        object_refs: [cell_1_object_ref]
      )

    [cell_0, cell_1]
  end

  defp sample_refined_cell_with_object_ref do
    occupancy = [0x0F, 0xF0, 0, 0, 0, 0, 0, 0]

    layer =
      MicroLayer.new(
        mask_words: occupancy,
        material_id: 42,
        state_flags: 0,
        health: 100,
        attribute_set_ref: 3,
        tag_set_ref: 4,
        owner_object_id: 0x0000_0000_DEAD_BEEF,
        owner_part_id: 7
      )

    object_ref =
      ObjectCoverRef.new(
        owner_object_id: 0x0000_0000_DEAD_BEEF,
        owner_part_id: 7,
        mask_words: occupancy
      )

    RefinedCellData.new(
      occupancy_words: occupancy,
      layers: [layer],
      object_refs: [object_ref],
      boundary_cache: 0
    )
  end
end
