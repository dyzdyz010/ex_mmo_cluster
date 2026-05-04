defmodule SceneServer.Voxel.CodecTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

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
end
