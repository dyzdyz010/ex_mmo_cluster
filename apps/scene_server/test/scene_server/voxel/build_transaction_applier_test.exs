defmodule SceneServer.Voxel.BuildTransactionApplierTest do
  use ExUnit.Case, async: true

  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.BuildTransactionApplier
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.VoxelChunkSup

  @logical_scene_id 1
  @region_id 10
  @lease_id 100
  @owner_scene_instance_ref 1_000
  @owner_epoch 1

  test "prepares every affected chunk and commit applies the staged intent" do
    {directory, lease} = boot()

    participant = participant(affected_chunks: [{0, 0, 0}, {1, 0, 0}])

    intents = %{
      {0, 0, 0} => intent_attrs(lease, {0, 0, 0}, {2, 0, 0}, 21),
      {1, 0, 0} => intent_attrs(lease, {1, 0, 0}, {3, 0, 0}, 22)
    }

    assert {:ok, %{prepared_chunks: prepared}} =
             BuildTransactionApplier.prepare(participant, "tx-happy", intents,
               chunk_directory: directory,
               logical_scene_id: @logical_scene_id
             )

    assert length(prepared) == 2
    assert Enum.all?(prepared, fn {_chunk, summary} -> summary.transaction_id == "tx-happy" end)

    assert {:ok, %{committed_chunks: committed}} =
             BuildTransactionApplier.commit(participant, "tx-happy",
               chunk_directory: directory,
               logical_scene_id: @logical_scene_id
             )

    assert length(committed) == 2

    Enum.each(committed, fn {_chunk_coord, summary} ->
      assert summary.chunk_version == 1
      assert is_binary(summary.snapshot_payload)
    end)
  end

  test "abort releases fences without applying the staged intent" do
    {directory, lease} = boot()

    participant = participant(affected_chunks: [{0, 0, 0}])

    intents = %{{0, 0, 0} => intent_attrs(lease, {0, 0, 0}, {1, 1, 1}, 30)}

    assert {:ok, _summary} =
             BuildTransactionApplier.prepare(participant, "tx-abort", intents,
               chunk_directory: directory,
               logical_scene_id: @logical_scene_id
             )

    # While the fence is held, ad-hoc apply_intent on the same chunk is rejected.
    assert {:error, {:chunk_fenced_by_transaction, "tx-abort"}} =
             ChunkDirectory.apply_intent(directory, intent_attrs(lease, {0, 0, 0}, {0, 0, 0}, 99))

    assert :ok =
             BuildTransactionApplier.abort(participant, "tx-abort",
               chunk_directory: directory,
               logical_scene_id: @logical_scene_id
             )

    # After abort the chunk is writable again with an unrelated intent.
    assert {:ok, %{chunk_version: 1}} =
             ChunkDirectory.apply_intent(directory, intent_attrs(lease, {0, 0, 0}, {0, 0, 0}, 99))
  end

  test "rolls back already-prepared chunks when a later chunk fails" do
    {directory, lease} = boot()

    chunk_a = {0, 0, 0}
    chunk_b = {1, 0, 0}

    # Pre-fence chunk_b under a different transaction so the second prepare in
    # the participant fails.
    assert {:ok, _summary} =
             ChunkDirectory.prepare_transaction(
               directory,
               "tx-other",
               intent_attrs(lease, chunk_b, {0, 0, 0}, 7)
             )

    participant = participant(affected_chunks: [chunk_a, chunk_b])

    intents = %{
      chunk_a => intent_attrs(lease, chunk_a, {2, 0, 0}, 11),
      chunk_b => intent_attrs(lease, chunk_b, {3, 0, 0}, 12)
    }

    assert {:error, {:prepare_failed, ^chunk_b, {:chunk_already_fenced, "tx-other"}}} =
             BuildTransactionApplier.prepare(participant, "tx-rollback", intents,
               chunk_directory: directory,
               logical_scene_id: @logical_scene_id
             )

    # chunk_a's fence was rolled back, so the original intent goes through.
    assert {:ok, %{chunk_version: 1}} =
             ChunkDirectory.apply_intent(directory, intent_attrs(lease, chunk_a, {2, 0, 0}, 11))
  end

  test "raises when :logical_scene_id is missing from opts" do
    {directory, _lease} = boot()

    participant = participant(affected_chunks: [{0, 0, 0}])

    assert_raise ArgumentError, ~r/missing required :logical_scene_id/, fn ->
      BuildTransactionApplier.prepare(participant, "tx-bad", %{}, chunk_directory: directory)
    end
  end

  defp participant(overrides) do
    %{
      region_id: @region_id,
      lease_id: @lease_id,
      owner_scene_instance_ref: @owner_scene_instance_ref,
      owner_epoch: @owner_epoch,
      affected_chunks: Keyword.fetch!(overrides, :affected_chunks)
    }
  end

  defp boot do
    chunk_sup = start_supervised!(VoxelChunkSup)
    token_store = start_supervised!(WriteTokenStore)
    snapshot_store = start_supervised!({ChunkSnapshotStore, write_token_store: token_store})

    directory =
      start_supervised!({ChunkDirectory, chunk_sup: chunk_sup, snapshot_store: snapshot_store})

    lease = %{
      logical_scene_id: @logical_scene_id,
      region_id: @region_id,
      lease_id: @lease_id,
      owner_scene_instance_ref: @owner_scene_instance_ref,
      owner_epoch: @owner_epoch,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(token_store, Map.put(lease, :token_version, 1))

    {directory, lease}
  end

  defp intent_attrs(lease, chunk_coord, macro_index, block_id) do
    %{
      request_id: 0,
      logical_scene_id: @logical_scene_id,
      chunk_coord: chunk_coord,
      lease: lease,
      operation: :put_solid_block,
      macro: macro_index,
      block: NormalBlockData.new(block_id, health: 70)
    }
  end
end
