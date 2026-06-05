defmodule SceneServer.Voxel.MigrationPrewarmTest do
  # Phase 1d: ChunkSnapshotStore is Repo-backed; tests share `voxel_chunks`.
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MigrationPrewarm
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.VoxelChunkSup

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset(WriteTokenStore)
    :ok
  end

  # 阶段3.1：每个 ChunkDirectory 用隔离的进程身份注册表。否则 facade.snapshot 会扫到
  # 全局单例里其它测试残留的 chunk（导致 chunk_count 偏大），且同一测试里的 source /
  # target 两个 directory（代表两个独立 Scene 节点）会经全局注册表互相看到对方的
  # chunk，破坏迁移 drain 的隔离语义。
  defp isolated_registry!(label) do
    name = :"migration_prewarm_test_registry_#{label}_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: name}, id: {:registry, name})
    name
  end

  defp isolated_directory!(chunk_sup, label) do
    registry = isolated_registry!(label)

    start_supervised!(
      {ChunkDirectory, chunk_sup: chunk_sup, chunk_registry: registry},
      id: label
    )
  end

  test "prewarms handoff slices and returns world-ready ACK payloads" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = isolated_directory!(chunk_sup, :prewarm_directory)

    assert {:ok, %{acks: [ack_0, ack_1]}} =
             MigrationPrewarm.prewarm_slices(handoff(), chunk_directory: directory)

    assert ack_0.slice_id == "migration-10:slice:0"
    assert ack_0.scene_ref == 2_000
    assert ack_0.loaded_count == 0
    assert ack_0.empty_count == 2
    assert ack_0.max_chunk_version == 0

    assert ack_1.slice_id == "migration-10:slice:1"
    assert ack_1.empty_count == 2

    snapshot = ChunkDirectory.snapshot(directory)
    assert snapshot.chunk_count == 4
  end

  test "rejects handoff payloads without planned slices" do
    assert {:error, :migration_handoff_has_no_slices} =
             MigrationPrewarm.prewarm_slices(%{handoff() | planned_slices: []})
  end

  test "final catch-up persists source chunks and reloads target chunks" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    handoff = one_chunk_handoff()
    old_lease = handoff.old_lease

    source_directory = isolated_directory!(chunk_sup, :source_chunk_directory)
    target_directory = isolated_directory!(chunk_sup, :target_chunk_directory)

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(
               WriteTokenStore,
               Map.put(old_lease, :token_version, 1)
             )

    assert {:ok, %{chunk_version: 1}} =
             ChunkDirectory.apply_intent(source_directory, %{
               request_id: 900,
               logical_scene_id: 1,
               chunk_coord: {1, 0, 0},
               lease: old_lease,
               operation: :put_solid_block,
               macro: {2, 0, 0},
               block: NormalBlockData.new(23, health: 70)
             })

    assert {:ok, %{acks: [ack]}} =
             MigrationPrewarm.final_catchup_slices(handoff,
               source_chunk_directory: source_directory,
               target_chunk_directory: target_directory
             )

    assert ack.slice_id == "migration-10:slice:0"
    assert ack.scene_ref == 2_000
    assert ack.loaded_count == 1
    assert ack.empty_count == 0
    assert ack.max_chunk_version == 1
    assert ack.source_persisted_count == 1
    assert ack.source_missing_count == 0
    assert ack.source_error_count == 0

    assert {:ok, target_payload} =
             ChunkDirectory.snapshot_payload(target_directory, %{
               request_id: 901,
               logical_scene_id: 1,
               chunk_coord: {1, 0, 0}
             })

    assert {:ok, %{request_id: 901, storage: target_storage}} =
             Codec.decode_chunk_snapshot_payload(target_payload)

    assert target_storage.chunk_version == 1

    assert Storage.macro_header_at(target_storage, {2, 0, 0}).mode ==
             MacroCellHeader.cell_mode_solid_block()
  end

  test "final catch-up fails when source persistence is rejected" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    handoff = one_chunk_handoff()
    old_lease = handoff.old_lease

    source_directory = isolated_directory!(chunk_sup, :source_chunk_directory_rejected)
    target_directory = isolated_directory!(chunk_sup, :target_chunk_directory_rejected)

    assert {:ok, _chunk_pid} =
             ChunkDirectory.ensure_chunk(source_directory, %{
               logical_scene_id: 1,
               chunk_coord: {1, 0, 0},
               lease: old_lease
             })

    assert {:error, :migration_source_slice_persist_failed} =
             MigrationPrewarm.final_catchup_slices(handoff,
               source_chunk_directory: source_directory,
               target_chunk_directory: target_directory
             )

    assert %{chunk_count: 0} = ChunkDirectory.snapshot(target_directory)
  end

  defp handoff do
    %{
      migration_id: "migration-10",
      logical_scene_id: 1,
      region_id: 10,
      state: :prewarming,
      source_scene_instance_ref: 1_000,
      target_scene_instance_ref: 2_000,
      old_lease: lease(100, 1_000, 1),
      new_lease: lease(101, 2_000, 2),
      token_version: 2,
      affected_chunk_bounds: %{min: {0, 0, 0}, max: {4, 1, 1}},
      planned_slices: [
        %{
          slice_id: "migration-10:slice:0",
          index: 0,
          bounds_chunk_min: {0, 0, 0},
          bounds_chunk_max: {2, 1, 1},
          state: :planned
        },
        %{
          slice_id: "migration-10:slice:1",
          index: 1,
          bounds_chunk_min: {2, 0, 0},
          bounds_chunk_max: {4, 1, 1},
          state: :planned
        }
      ],
      next_slice_index: 2,
      total_slices: 2
    }
  end

  defp one_chunk_handoff do
    %{
      handoff()
      | affected_chunk_bounds: %{min: {1, 0, 0}, max: {2, 1, 1}},
        planned_slices: [
          %{
            slice_id: "migration-10:slice:0",
            index: 0,
            bounds_chunk_min: {1, 0, 0},
            bounds_chunk_max: {2, 1, 1},
            state: :prewarmed
          }
        ],
        next_slice_index: 1,
        total_slices: 1
    }
  end

  defp lease(lease_id, owner_ref, owner_epoch) do
    %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: lease_id,
      owner_scene_instance_ref: owner_ref,
      owner_epoch: owner_epoch,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 1, 1},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }
  end
end
