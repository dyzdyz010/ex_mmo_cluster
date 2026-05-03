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
end
