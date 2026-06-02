defmodule GateServer.Voxel.ClientAckLedgerTest do
  use ExUnit.Case, async: true

  alias GateServer.Voxel.{ChunkVersionLedger, ClientAckLedger}
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec

  test "records only versions that Gate has already forwarded" do
    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(77, {1, 2, 3}, 5)

    assert {:ok, ledger, event} =
             ClientAckLedger.record_ack(ClientAckLedger.new(), forwarded, 77, {1, 2, 3}, 5)

    assert event.status == :ack_recorded
    assert event.ack_version == 5
    assert ClientAckLedger.known_versions(ledger, 77) == %{{1, 2, 3} => 5}

    assert {:error, ^ledger, ahead_event} =
             ClientAckLedger.record_ack(ledger, forwarded, 77, {1, 2, 3}, 6)

    assert ahead_event.status == :ack_ahead_of_forwarded
    assert ahead_event.forwarded_version == 5
    assert ClientAckLedger.known_versions(ledger, 77) == %{{1, 2, 3} => 5}
  end

  test "ignores ACKs whose forwarded cache entry was already pruned" do
    assert {:ok, ledger, event} =
             ClientAckLedger.record_ack(
               ClientAckLedger.new(),
               ChunkVersionLedger.new(),
               77,
               {1, 2, 3},
               0
             )

    assert event.status == :ack_without_forwarded
    assert event.forwarded_version == nil
    assert ClientAckLedger.known_versions(ledger, 77) == %{}
  end

  test "duplicate and stale ACKs do not move the acknowledged version backwards" do
    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(77, {1, 2, 3}, 9)

    {:ok, ledger, _event} =
      ClientAckLedger.record_ack(ClientAckLedger.new(), forwarded, 77, {1, 2, 3}, 8)

    assert {:ok, same_ledger, duplicate_event} =
             ClientAckLedger.record_ack(ledger, forwarded, 77, {1, 2, 3}, 8)

    assert duplicate_event.status == :duplicate_ack
    assert same_ledger == ledger

    assert {:ok, stale_ledger, stale_event} =
             ClientAckLedger.record_ack(ledger, forwarded, 77, {1, 2, 3}, 7)

    assert stale_event.status == :stale_ack
    assert stale_event.previous_ack_version == 8
    assert stale_ledger == ledger
  end

  test "chunk invalidation clears acknowledged versions for that chunk" do
    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(77, {1, 2, 3}, 5)

    {:ok, ledger, _event} =
      ClientAckLedger.record_ack(ClientAckLedger.new(), forwarded, 77, {1, 2, 3}, 5)

    payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 77,
        chunk_coord: {1, 2, 3},
        reason: 0x01
      })

    assert {:ok, cleared, event} = ClientAckLedger.clear_invalidate_payload(ledger, payload)
    assert event.status == :cleared
    assert event.previous_ack_version == 5
    assert event.reason_name == :migration_cutover
    assert ClientAckLedger.known_versions(cleared, 77) == %{}
  end

  test "records a validated batch of client known-version ACKs" do
    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(77, {1, 2, 3}, 5)
      |> ChunkVersionLedger.record_version!(77, {-1, 0, 0}, 2)

    {ledger, summary} =
      ClientAckLedger.record_known_versions(ClientAckLedger.new(), forwarded, 77, [
        %{chunk_coord: {1, 2, 3}, chunk_version: 5},
        %{chunk_coord: {-1, 0, 0}, chunk_version: 3}
      ])

    assert summary.status == :partial
    assert summary.accepted_count == 1
    assert summary.ignored_count == 0
    assert summary.rejected_count == 1
    assert Enum.map(summary.events, & &1.status) == [:ack_recorded, :ack_ahead_of_forwarded]
    assert ClientAckLedger.known_versions(ledger, 77) == %{{1, 2, 3} => 5}
  end

  test "can clear one retained ACK without touching other scenes" do
    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(77, {1, 2, 3}, 5)
      |> ChunkVersionLedger.record_version!(78, {1, 2, 3}, 9)

    {ledger, %{status: :ok}} =
      ClientAckLedger.record_known_versions(ClientAckLedger.new(), forwarded, 77, [
        {{1, 2, 3}, 5}
      ])

    {ledger, %{status: :ok}} =
      ClientAckLedger.record_known_versions(ledger, forwarded, 78, [
        {{1, 2, 3}, 9}
      ])

    cleared = ClientAckLedger.clear_chunk(ledger, 77, {1, 2, 3})

    assert ClientAckLedger.known_versions(cleared, 77) == %{}
    assert ClientAckLedger.known_versions(cleared, 78) == %{{1, 2, 3} => 9}
  end
end
