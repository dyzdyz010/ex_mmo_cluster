defmodule DataService.Voxel.ChunkSnapshotStoreTest do
  # Phase 1d: ChunkSnapshotStore is a stateless module backed by Postgres.
  # The shared `voxel_chunks` table forces sync execution + per-test cleanup.
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.WriteTokenStore

  setup do
    Repo.delete_all(VoxelChunkSnapshot)

    {:ok, token_store} =
      start_supervised({WriteTokenStore, name: :"#{__MODULE__}_#{:rand.uniform(1_000_000)}"})

    {:ok, token_store: token_store}
  end

  test "accepts snapshots from the current token holder", %{token_store: token_store} do
    token = upsert_token(token_store, token())

    attrs = snapshot_attrs(token, chunk_version: 1, chunk_hash: hash(<<1>>), data: <<1, 2, 3>>)

    assert {:ok, :inserted} =
             ChunkSnapshotStore.put_snapshot(attrs, write_token_store: token_store)

    debug_snapshot = ChunkSnapshotStore.snapshot()
    assert %{chunk_version: 1, data: <<1, 2, 3>>} = Map.fetch!(debug_snapshot, {1, {1, 1, 1}})
  end

  test "rejects stale token writes after the region token advances", %{token_store: token_store} do
    token_v1 = upsert_token(token_store, token())

    token_v2 =
      Map.merge(token_v1, %{
        lease_id: 101,
        owner_scene_instance_ref: 2_000,
        owner_epoch: 2,
        token_version: 2
      })

    assert {:ok, :updated} = WriteTokenStore.upsert_token(token_store, token_v2)

    assert {:error, :lease_id_mismatch} =
             ChunkSnapshotStore.put_snapshot(
               snapshot_attrs(token_v1),
               write_token_store: token_store
             )

    assert {:error, :snapshot_not_found} = ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
  end

  test "rejects older chunk versions from the current token holder", %{token_store: token_store} do
    token = upsert_token(token_store, token())

    assert {:ok, :inserted} =
             ChunkSnapshotStore.put_snapshot(
               snapshot_attrs(token, chunk_version: 3, chunk_hash: hash(<<3>>), data: <<3>>),
               write_token_store: token_store
             )

    assert {:error, :stale_chunk_version} =
             ChunkSnapshotStore.put_snapshot(
               snapshot_attrs(token, chunk_version: 2, chunk_hash: hash(<<2>>), data: <<2>>),
               write_token_store: token_store
             )
  end

  test "treats same version and same payload replays as idempotent", %{token_store: token_store} do
    token = upsert_token(token_store, token())
    attrs = snapshot_attrs(token, chunk_version: 7, chunk_hash: hash(<<7>>), data: <<7, 7>>)

    assert {:ok, :inserted} =
             ChunkSnapshotStore.put_snapshot(attrs, write_token_store: token_store)

    assert {:ok, :unchanged} =
             ChunkSnapshotStore.put_snapshot(attrs, write_token_store: token_store)
  end

  test "rejects same version writes with different payloads", %{token_store: token_store} do
    token = upsert_token(token_store, token())
    attrs = snapshot_attrs(token, chunk_version: 7, chunk_hash: hash(<<7>>), data: <<7, 7>>)

    assert {:ok, :inserted} =
             ChunkSnapshotStore.put_snapshot(attrs, write_token_store: token_store)

    assert {:error, :chunk_version_conflict} =
             ChunkSnapshotStore.put_snapshot(
               snapshot_attrs(token,
                 chunk_version: 7,
                 chunk_hash: hash(<<7, 7, 0xAB>>),
                 data: <<7, 8>>
               ),
               write_token_store: token_store
             )

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
    assert snapshot.chunk_hash == hash(<<7>>)
    assert snapshot.data == <<7, 7>>
  end

  test "reads stored snapshots by logical scene chunk", %{token_store: token_store} do
    token = upsert_token(token_store, token())

    attrs =
      snapshot_attrs(token, chunk_version: 1, chunk_hash: hash("read"), data: <<9, 8, 7>>)

    assert {:ok, :inserted} =
             ChunkSnapshotStore.put_snapshot(attrs, write_token_store: token_store)

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
    assert snapshot.logical_scene_id == 1
    assert snapshot.region_id == 10
    assert snapshot.chunk_version == 1
    assert snapshot.chunk_hash == hash("read")
    assert snapshot.data == <<9, 8, 7>>
  end

  test "rejects chunk_hash that is not exactly 8 bytes", %{token_store: token_store} do
    token = upsert_token(token_store, token())

    assert {:error, :invalid_chunk_hash} =
             ChunkSnapshotStore.put_snapshot(
               snapshot_attrs(token, chunk_hash: <<1, 2, 3>>, data: <<>>),
               write_token_store: token_store
             )
  end

  defp upsert_token(token_store, token) do
    {:ok, _} = WriteTokenStore.upsert_token(token_store, token)
    token
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
      schema_version: 1,
      chunk_size_in_macro: 16,
      micro_resolution: 8,
      chunk_version: 1,
      chunk_hash: hash(<<1>>),
      data: <<1>>
    })
    |> Map.merge(Map.new(overrides))
  end

  # Convert any input into a stable 8-byte binary so the test fixtures match
  # the bytea(8) constraint enforced by the migration.
  defp hash(seed) do
    :crypto.hash(:sha256, :erlang.term_to_binary(seed))
    |> :binary.part(0, 8)
  end
end
