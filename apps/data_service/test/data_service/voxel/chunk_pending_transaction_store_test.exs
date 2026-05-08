defmodule DataService.Voxel.ChunkPendingTransactionStoreTest do
  # Phase 3-bis: ChunkPendingTransactionStore is a stateless module backed by
  # Postgres. The shared `voxel_chunk_pending_transactions` table forces sync
  # execution + per-test cleanup.
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Voxel.ChunkPendingTransactionStore

  setup do
    Repo.delete_all(VoxelChunkPendingTransaction)
    :ok
  end

  describe "put_fence/2" do
    test "inserts a new fence row" do
      attrs = fence_attrs()

      assert {:ok, :inserted} = ChunkPendingTransactionStore.put_fence(attrs)

      assert {:ok, fence} = ChunkPendingTransactionStore.get_fence(1, {1, 1, 1})
      assert fence.transaction_id == attrs.transaction_id
      assert fence.intents == attrs.intents
      assert fence.owner_region_id == attrs.owner_region_id
      assert fence.owner_lease_id == attrs.owner_lease_id
      assert fence.owner_scene_instance_ref == attrs.owner_scene_instance_ref
      assert fence.owner_epoch == attrs.owner_epoch
      assert fence.decision_version == attrs.decision_version
      assert fence.fenced_at_ms == attrs.fenced_at_ms
    end

    test "rejects a second fence on the same chunk" do
      assert {:ok, :inserted} = ChunkPendingTransactionStore.put_fence(fence_attrs())

      assert {:error, :fence_already_present} =
               ChunkPendingTransactionStore.put_fence(
                 fence_attrs(transaction_id: <<"txn-conflict">>)
               )
    end

    test "different chunks accept independent fences" do
      assert {:ok, :inserted} =
               ChunkPendingTransactionStore.put_fence(fence_attrs(chunk_coord: {1, 1, 1}))

      assert {:ok, :inserted} =
               ChunkPendingTransactionStore.put_fence(fence_attrs(chunk_coord: {1, 1, 2}))

      assert {:ok, :inserted} =
               ChunkPendingTransactionStore.put_fence(
                 fence_attrs(logical_scene_id: 2, chunk_coord: {1, 1, 1})
               )

      assert map_size(ChunkPendingTransactionStore.snapshot()) == 3
    end

    test "rejects missing fields" do
      assert {:error, :missing_logical_scene_id} =
               ChunkPendingTransactionStore.put_fence(
                 Map.delete(fence_attrs(), :logical_scene_id)
               )

      assert {:error, :missing_intents} =
               ChunkPendingTransactionStore.put_fence(Map.delete(fence_attrs(), :intents))
    end

    test "rejects empty transaction_id" do
      assert {:error, :invalid_transaction_id} =
               ChunkPendingTransactionStore.put_fence(fence_attrs(transaction_id: <<>>))
    end

    test "rejects empty intents list" do
      assert {:error, :invalid_intents} =
               ChunkPendingTransactionStore.put_fence(fence_attrs(intents: []))
    end

    test "rejects negative scalars" do
      assert {:error, :invalid_owner_epoch} =
               ChunkPendingTransactionStore.put_fence(fence_attrs(owner_epoch: -1))
    end
  end

  describe "get_fence/3" do
    test "returns fence_not_found for an empty table" do
      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(1, {1, 1, 1})
    end

    test "decodes intents back to the original list" do
      intents = [
        %{operation: :put_solid_block, macro: 0, lease: %{lease_id: 200}},
        %{operation: :break_block, macro: 5, lease: %{lease_id: 200}}
      ]

      assert {:ok, :inserted} =
               ChunkPendingTransactionStore.put_fence(fence_attrs(intents: intents))

      assert {:ok, fence} = ChunkPendingTransactionStore.get_fence(1, {1, 1, 1})
      assert fence.intents == intents
    end
  end

  describe "delete_fence/3" do
    test "deletes an existing row" do
      assert {:ok, :inserted} = ChunkPendingTransactionStore.put_fence(fence_attrs())

      assert {:ok, :deleted} = ChunkPendingTransactionStore.delete_fence(1, {1, 1, 1})

      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(1, {1, 1, 1})
    end

    test "returns :not_found when the row is missing" do
      assert {:ok, :not_found} = ChunkPendingTransactionStore.delete_fence(1, {1, 1, 1})
    end
  end

  describe "snapshot/1" do
    test "is keyed by {logical_scene_id, chunk_coord}" do
      assert ChunkPendingTransactionStore.snapshot() == %{}

      assert {:ok, :inserted} = ChunkPendingTransactionStore.put_fence(fence_attrs())

      snap = ChunkPendingTransactionStore.snapshot()
      assert Map.keys(snap) == [{1, {1, 1, 1}}]
    end
  end

  defp fence_attrs(overrides \\ []) do
    overrides = Map.new(overrides)

    base = %{
      logical_scene_id: 1,
      chunk_coord: {1, 1, 1},
      transaction_id: <<"txn-default">>,
      decision_version: 1,
      owner_region_id: 10,
      owner_lease_id: 200,
      owner_scene_instance_ref: 3_000,
      owner_epoch: 1,
      intents: [%{operation: :put_solid_block, macro: 0}],
      fenced_at_ms: 1_700_000_000_000
    }

    Map.merge(base, overrides)
  end
end
