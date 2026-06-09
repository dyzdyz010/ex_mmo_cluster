defmodule SceneServer.Voxel.ChunkProcessPersistenceTest do
  # Phase 3-bis: ChunkProcess persists `pending_fence` into
  # `voxel_chunk_pending_transactions`. The shared table forces sync
  # execution + per-test cleanup.
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkPendingTransactionStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.NormalBlockData

  @logical_scene_id 1
  @chunk_coord {0, 0, 0}
  @region_id 10
  @lease_id 100
  @owner_scene_instance_ref 1_000
  @owner_epoch 1
  @transaction_id "tx-persistence-1"

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset(WriteTokenStore)

    chunk_registry = :"#{__MODULE__}.ChunkRegistry.#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: chunk_registry})
    Process.put(:chunk_registry, chunk_registry)

    :ok
  end

  describe "prepare_transaction persists fence" do
    test "writes a row that mirrors the in-memory pending_fence" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, summary} =
               ChunkProcess.prepare_transaction(
                 chunk,
                 @transaction_id,
                 [intent_attrs(lease)],
                 decision_version: 7
               )

      assert summary.transaction_id == @transaction_id
      assert summary.intent_count == 1

      assert {:ok, persisted} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)

      assert persisted.transaction_id == @transaction_id
      assert persisted.decision_version == 7
      assert persisted.owner_region_id == @region_id
      assert persisted.owner_lease_id == @lease_id
      assert persisted.owner_scene_instance_ref == @owner_scene_instance_ref
      assert persisted.owner_epoch == @owner_epoch
      assert length(persisted.intents) == 1
    end

    test "the persisted row uses the lease attached to the first intent" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, @transaction_id, [intent_attrs(lease)])

      assert {:ok, persisted} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)

      assert persisted.owner_lease_id == @lease_id
    end

    test "retains in-memory chunk_already_fenced check before hitting the DB" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, @transaction_id, [intent_attrs(lease)])

      # Second prepare with a different transaction id is rejected by the
      # in-memory fence guard, so the DB row never collides.
      assert {:error, {:chunk_already_fenced, @transaction_id}} =
               ChunkProcess.prepare_transaction(chunk, "tx-other", [intent_attrs(lease)])
    end
  end

  describe "commit_transaction releases the persisted row" do
    test "deletes the row after a successful commit" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, @transaction_id, [intent_attrs(lease)])

      assert {:ok, _} = ChunkProcess.commit_transaction(chunk, @transaction_id)

      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)

      assert ChunkProcess.debug_state(chunk).chunk_version == 1
    end
  end

  describe "abort_transaction releases the persisted row" do
    test "deletes the row after abort" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, @transaction_id, [intent_attrs(lease)])

      assert :ok = ChunkProcess.abort_transaction(chunk, @transaction_id)

      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)
    end

    test "abort against a transaction that does not own the fence leaves the row alone" do
      lease = lease()
      seed_token!(lease)
      chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(chunk, @transaction_id, [intent_attrs(lease)])

      assert :ok = ChunkProcess.abort_transaction(chunk, "tx-not-owner")

      assert {:ok, _} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)
    end
  end

  describe "init reload" do
    test "loads an existing fence row when the lease matches" do
      lease = lease()
      seed_token!(lease)

      # Prepare on the first chunk process.
      first_chunk = boot_chunk(lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(first_chunk, @transaction_id, [
                 intent_attrs(lease)
               ])

      # Stop and start a fresh chunk process with the same lease — simulates
      # a Scene-side process restart while the row stays in DB.
      stop_chunk!()
      reborn = boot_chunk(lease)

      # The fence is in memory again, so the same transaction id can commit.
      assert {:ok, %{changed_count: 1}} =
               ChunkProcess.commit_transaction(reborn, @transaction_id)

      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)
    end

    test "drops orphan row when the new lease has a different epoch" do
      old_lease = lease()
      seed_token!(old_lease)

      first_chunk = boot_chunk(old_lease)

      assert {:ok, _} =
               ChunkProcess.prepare_transaction(first_chunk, @transaction_id, [
                 intent_attrs(old_lease)
               ])

      stop_chunk!()

      # Lease bumped epoch — the persisted fence is now an orphan.
      new_lease = lease(owner_epoch: 2)
      seed_token!(new_lease)
      reborn = boot_chunk(new_lease)

      assert ChunkProcess.debug_state(reborn).has_lease?

      # The orphan is gone from DB, and a fresh prepare on this chunk works.
      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)

      assert {:error, :transaction_not_prepared} =
               ChunkProcess.commit_transaction(reborn, @transaction_id)
    end

    test "drops orphan row when the new process has no lease at startup" do
      # Manually plant an orphan row that does not match any current lease.
      :ok = plant_orphan_fence!()

      # Boot ChunkProcess without a lease — init load should drop the orphan.
      chunk =
        start_supervised!(
          {ChunkProcess,
           [
             logical_scene_id: @logical_scene_id,
             chunk_coord: @chunk_coord,
             chunk_registry: chunk_registry!()
           ]}
        )

      refute ChunkProcess.debug_state(chunk).has_lease?

      assert {:error, :fence_not_found} =
               ChunkPendingTransactionStore.get_fence(@logical_scene_id, @chunk_coord)
    end
  end

  defp lease(overrides \\ []) do
    base = %{
      logical_scene_id: @logical_scene_id,
      region_id: @region_id,
      lease_id: @lease_id,
      owner_scene_instance_ref: @owner_scene_instance_ref,
      owner_epoch: @owner_epoch,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }

    Map.merge(base, Map.new(overrides))
  end

  defp seed_token!(lease) do
    {:ok, _} =
      WriteTokenStore.upsert_token(
        WriteTokenStore,
        Map.put(lease, :token_version, lease.owner_epoch)
      )

    :ok
  end

  defp boot_chunk(lease) do
    start_supervised!({
      ChunkProcess,
      [
        logical_scene_id: @logical_scene_id,
        chunk_coord: @chunk_coord,
        lease: lease,
        chunk_registry: chunk_registry!()
      ]
    })
  end

  defp stop_chunk! do
    stop_supervised!(ChunkProcess)
    wait_for_unregistered_chunk()
  end

  defp wait_for_unregistered_chunk(attempts \\ 20)
  defp wait_for_unregistered_chunk(0), do: :ok

  defp wait_for_unregistered_chunk(attempts) do
    case Registry.lookup(chunk_registry!(), {@logical_scene_id, @chunk_coord}) do
      [] ->
        :ok

      _entries ->
        Process.sleep(10)
        wait_for_unregistered_chunk(attempts - 1)
    end
  end

  defp chunk_registry! do
    Process.get(:chunk_registry) || raise "missing chunk registry"
  end

  defp intent_attrs(lease) do
    %{
      request_id: 0,
      logical_scene_id: @logical_scene_id,
      chunk_coord: @chunk_coord,
      lease: lease,
      operation: :put_solid_block,
      macro: 0,
      block: NormalBlockData.new(2, health: 50)
    }
  end

  defp plant_orphan_fence! do
    {:ok, :inserted} =
      ChunkPendingTransactionStore.put_fence(%{
        logical_scene_id: @logical_scene_id,
        chunk_coord: @chunk_coord,
        transaction_id: <<"tx-orphan">>,
        decision_version: 1,
        owner_region_id: @region_id,
        owner_lease_id: 999_999,
        owner_scene_instance_ref: 999_999,
        owner_epoch: 999_999,
        intents: [%{operation: :put_solid_block, macro: 0}],
        fenced_at_ms: System.system_time(:millisecond)
      })

    :ok
  end
end
