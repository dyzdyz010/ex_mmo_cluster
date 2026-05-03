defmodule DataService.Voxel.ChunkSnapshotStoreTest do
  use ExUnit.Case, async: true

  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.WriteTokenStore

  test "accepts snapshots from the current token holder" do
    {_token_store, snapshot_store, token} = start_stores()
    attrs = snapshot_attrs(token, chunk_version: 1, chunk_hash: "hash-v1", data: <<1, 2, 3>>)

    assert {:ok, :inserted} = ChunkSnapshotStore.put_snapshot(snapshot_store, attrs)

    debug_snapshot = ChunkSnapshotStore.snapshot(snapshot_store)
    assert %{chunk_version: 1, data: <<1, 2, 3>>} = Map.fetch!(debug_snapshot, {1, {1, 1, 1}})
  end

  test "rejects stale token writes after the region token advances" do
    {token_store, snapshot_store, token_v1} = start_stores()

    token_v2 = %{
      token_v1
      | lease_id: 101,
        owner_scene_instance_ref: 2_000,
        owner_epoch: 2,
        token_version: 2
    }

    assert {:ok, :updated} = WriteTokenStore.upsert_token(token_store, token_v2)

    assert {:error, :lease_id_mismatch} =
             ChunkSnapshotStore.put_snapshot(snapshot_store, snapshot_attrs(token_v1))

    assert {:error, :snapshot_not_found} =
             ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})
  end

  test "rejects older chunk versions from the current token holder" do
    {_token_store, snapshot_store, token} = start_stores()

    assert {:ok, :inserted} =
             ChunkSnapshotStore.put_snapshot(
               snapshot_store,
               snapshot_attrs(token, chunk_version: 3, chunk_hash: "hash-v3", data: <<3>>)
             )

    assert {:error, :stale_chunk_version} =
             ChunkSnapshotStore.put_snapshot(
               snapshot_store,
               snapshot_attrs(token, chunk_version: 2, chunk_hash: "hash-v2", data: <<2>>)
             )
  end

  test "treats same version and same payload replays as idempotent" do
    {_token_store, snapshot_store, token} = start_stores()
    attrs = snapshot_attrs(token, chunk_version: 7, chunk_hash: "hash-v7", data: <<7, 7>>)

    assert {:ok, :inserted} = ChunkSnapshotStore.put_snapshot(snapshot_store, attrs)
    assert {:ok, :unchanged} = ChunkSnapshotStore.put_snapshot(snapshot_store, attrs)
  end

  test "rejects same version writes with different payloads" do
    {_token_store, snapshot_store, token} = start_stores()
    attrs = snapshot_attrs(token, chunk_version: 7, chunk_hash: "hash-v7", data: <<7, 7>>)

    assert {:ok, :inserted} = ChunkSnapshotStore.put_snapshot(snapshot_store, attrs)

    assert {:error, :chunk_version_conflict} =
             ChunkSnapshotStore.put_snapshot(
               snapshot_store,
               snapshot_attrs(token, chunk_version: 7, chunk_hash: "hash-v7b", data: <<7, 8>>)
             )

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})
    assert snapshot.chunk_hash == "hash-v7"
    assert snapshot.data == <<7, 7>>
  end

  test "reads stored snapshots by logical scene chunk" do
    {_token_store, snapshot_store, token} = start_stores()
    attrs = snapshot_attrs(token, chunk_version: 1, chunk_hash: "hash-read", data: <<9, 8, 7>>)

    assert {:ok, :inserted} = ChunkSnapshotStore.put_snapshot(snapshot_store, attrs)

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})
    assert snapshot.logical_scene_id == 1
    assert snapshot.region_id == 10
    assert snapshot.chunk_version == 1
    assert snapshot.chunk_hash == "hash-read"
    assert snapshot.data == <<9, 8, 7>>
  end

  defp start_stores do
    token_store = start_supervised!(WriteTokenStore)

    snapshot_store =
      start_supervised!({ChunkSnapshotStore, write_token_store: token_store})

    token = token()
    assert {:ok, :inserted} = WriteTokenStore.upsert_token(token_store, token)

    {token_store, snapshot_store, token}
  end

  defp token do
    %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000,
      token_version: 1
    }
  end

  defp snapshot_attrs(token, overrides \\ []) do
    token
    |> Map.take([
      :logical_scene_id,
      :region_id,
      :lease_id,
      :owner_scene_instance_ref,
      :owner_epoch
    ])
    |> Map.merge(%{
      chunk_coord: {1, 1, 1},
      chunk_version: 1,
      chunk_hash: "hash-v1",
      data: <<1>>
    })
    |> Map.merge(Map.new(overrides))
  end
end
