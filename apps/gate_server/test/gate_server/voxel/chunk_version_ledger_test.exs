defmodule GateServer.Voxel.ChunkVersionLedgerTest do
  use ExUnit.Case, async: true

  alias GateServer.Voxel.ChunkVersionLedger
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.Storage

  test "records forwarded snapshots and deltas as known chunk versions" do
    ledger = ChunkVersionLedger.new()
    snapshot_payload = snapshot_payload(7, {1, 2, 3}, 4)

    assert {:ok, ledger, snapshot_event} =
             ChunkVersionLedger.record_payload(ledger, :snapshot, snapshot_payload)

    assert snapshot_event == %{
             status: :recorded,
             frame_kind: :snapshot,
             logical_scene_id: 7,
             chunk_coord: {1, 2, 3},
             previous_version: nil,
             chunk_version: 4
           }

    delta_payload =
      SceneVoxelCodec.encode_chunk_delta_payload(%{
        logical_scene_id: 7,
        chunk_coord: {1, 2, 3},
        base_chunk_version: 4,
        new_chunk_version: 5,
        ops: []
      })

    assert {:ok, ledger, delta_event} =
             ChunkVersionLedger.record_payload(ledger, :delta, delta_payload)

    assert delta_event.status == :recorded
    assert delta_event.previous_version == 4
    assert delta_event.chunk_version == 5
    assert ChunkVersionLedger.known_versions(ledger, 7) == %{{1, 2, 3} => 5}
  end

  test "does not move a chunk backwards on stale deltas" do
    ledger =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(7, {1, 2, 3}, 5)

    stale_payload =
      SceneVoxelCodec.encode_chunk_delta_payload(%{
        logical_scene_id: 7,
        chunk_coord: {1, 2, 3},
        base_chunk_version: 3,
        new_chunk_version: 4,
        ops: []
      })

    assert {:ok, next_ledger, event} =
             ChunkVersionLedger.record_payload(ledger, :delta, stale_payload)

    assert event.status == :stale
    assert event.previous_version == 5
    assert event.chunk_version == 4
    assert ChunkVersionLedger.known_versions(next_ledger, 7) == %{{1, 2, 3} => 5}
  end

  test "does not advance a delta whose base version does not match the forwarded cache" do
    ledger =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(7, {1, 2, 3}, 5)

    gap_payload =
      SceneVoxelCodec.encode_chunk_delta_payload(%{
        logical_scene_id: 7,
        chunk_coord: {1, 2, 3},
        base_chunk_version: 3,
        new_chunk_version: 6,
        ops: []
      })

    assert {:ok, next_ledger, event} =
             ChunkVersionLedger.record_payload(ledger, :delta, gap_payload)

    assert event.status == :base_mismatch
    assert event.previous_version == 5
    assert event.base_chunk_version == 3
    assert event.chunk_version == 6
    assert ChunkVersionLedger.known_versions(next_ledger, 7) == %{{1, 2, 3} => 5}
  end

  test "merges client hints without overriding explicit client versions" do
    ledger =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(7, {0, 0, 0}, 3)
      |> ChunkVersionLedger.record_version!(7, {1, 0, 0}, 8)
      |> ChunkVersionLedger.record_version!(8, {9, 0, 0}, 2)

    merged =
      ChunkVersionLedger.merge_known_versions(ledger, 7, %{
        {0, 0, 0} => 1,
        {2, 0, 0} => 6
      })

    assert merged == %{
             {0, 0, 0} => 1,
             {1, 0, 0} => 8,
             {2, 0, 0} => 6
           }
  end

  test "clears invalidated chunks without touching other cached versions" do
    ledger =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(7, {0, 0, 0}, 3)
      |> ChunkVersionLedger.record_version!(7, {1, 0, 0}, 4)
      |> ChunkVersionLedger.record_version!(8, {9, 0, 0}, 2)

    invalidate_payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 7,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    assert {:ok, next_ledger, event} =
             ChunkVersionLedger.clear_invalidate_payload(ledger, invalidate_payload)

    assert event.status == :cleared
    assert event.reason_name == :migration_cutover

    assert ChunkVersionLedger.to_sorted_list(next_ledger) == [
             {7, {1, 0, 0}, 4},
             {8, {9, 0, 0}, 2}
           ]
  end

  test "formats a bounded deterministic debug summary" do
    ledger =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(7, {0, 0, 0}, 3)

    assert ChunkVersionLedger.format_debug(ledger) == "[{7, {0, 0, 0}, 3}]"
  end

  defp snapshot_payload(logical_scene_id, chunk_coord, chunk_version) do
    storage = Storage.empty(logical_scene_id, chunk_coord, chunk_version: chunk_version)
    SceneVoxelCodec.encode_chunk_snapshot_payload(%{request_id: 101, storage: storage})
  end
end
