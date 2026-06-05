defmodule SceneServer.Voxel.ChunkDirectoryTest do
  # Phase 1d: ChunkSnapshotStore is Repo-backed; tests share `voxel_chunks`.
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.VoxelChunkSup

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset(WriteTokenStore)

    # 阶段3.1：每个测试用隔离的 chunk 进程身份注册表，避免 facade.snapshot
    # 的 Registry 扫描串到全局单例 / 其它测试的 chunk。directory 经
    # `directory/1` helper 注入该注册表。
    registry_name = :"chunk_directory_test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})
    Process.put(:chunk_registry, registry_name)

    :ok
  end

  # 在显式 `chunk_sup` 之外注入隔离注册表，统一 facade 的进程身份解析视图。
  defp directory(opts) do
    opts = Keyword.put_new(opts, :chunk_registry, Process.get(:chunk_registry))
    start_supervised!({ChunkDirectory, opts})
  end

  test "lazily starts chunks and returns snapshot payloads" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = directory(chunk_sup: chunk_sup)
    scene_id = unique_scene_id()

    assert {:ok, payload} =
             ChunkDirectory.snapshot_payload(directory, %{
               request_id: 55,
               logical_scene_id: scene_id,
               center_chunk: {0, 0, 0}
             })

    assert {:ok, %{request_id: 55, storage: storage}} =
             Codec.decode_chunk_snapshot_payload(payload)

    assert storage.logical_scene_id == scene_id
    assert storage.chunk_coord == {0, 0, 0}

    snapshot = ChunkDirectory.snapshot(directory)
    assert snapshot.chunk_count == 1
  end

  test "apply_intent starts a chunk, writes through the lease fence, and persists" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = directory(chunk_sup: chunk_sup)

    scene_id = unique_scene_id()
    lease = lease(scene_id)

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(
               WriteTokenStore,
               Map.put(lease, :token_version, 1)
             )

    assert {:ok,
            %{
              chunk_version: 1,
              persist_result: :inserted,
              snapshot_payload: payload
            }} =
             ChunkDirectory.apply_intent(directory, %{
               request_id: 90,
               logical_scene_id: scene_id,
               chunk_coord: {1, 1, 1},
               lease: lease,
               operation: :put_solid_block,
               macro: {3, 0, 0},
               block: NormalBlockData.new(11, health: 40)
             })

    assert {:ok, %{request_id: 90, storage: storage}} =
             Codec.decode_chunk_snapshot_payload(payload)

    assert storage.chunk_version == 1

    assert Storage.macro_header_at(storage, {3, 0, 0}).mode ==
             MacroCellHeader.cell_mode_solid_block()

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(scene_id, {1, 1, 1})
    assert snapshot.chunk_version == 1

    directory_snapshot = ChunkDirectory.snapshot(directory)
    assert directory_snapshot.chunk_count == 1
  end

  test "apply_intents batches same-chunk writes through one persisted snapshot" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = directory(chunk_sup: chunk_sup)

    scene_id = unique_scene_id()
    lease = lease(scene_id)

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(
               WriteTokenStore,
               Map.put(lease, :token_version, 1)
             )

    attrs =
      for x <- 0..2 do
        %{
          request_id: 100 + x,
          logical_scene_id: scene_id,
          chunk_coord: {1, 1, 1},
          lease: lease,
          operation: :put_solid_block,
          macro: {x, 0, 0},
          block: NormalBlockData.new(11, health: 40)
        }
      end

    assert {:ok,
            %{
              chunk_version: 1,
              changed_count: 3,
              skipped_count: 0,
              snapshot_payload: payload
            }} = ChunkDirectory.apply_intents(directory, attrs)

    assert {:ok, %{storage: storage}} = Codec.decode_chunk_snapshot_payload(payload)
    assert storage.chunk_version == 1

    assert {:ok, chunk_pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {1, 1, 1})
    assert :ok = ChunkProcess.flush_persistence(chunk_pid)

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(scene_id, {1, 1, 1})
    assert snapshot.chunk_version == 1
  end

  test "collision_query reports a stalled chunk without crashing the directory" do
    chunk_sup = start_supervised!(VoxelChunkSup)

    directory =
      directory(chunk_sup: chunk_sup, collision_query_timeout_ms: 10)

    scene_id = unique_scene_id()

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(directory, %{
               logical_scene_id: scene_id,
               chunk_coord: {0, 0, 0}
             })

    :ok = :sys.suspend(chunk_pid)

    try do
      assert {:error, {:chunk_unavailable, {:timeout, :collision_query}}} =
               ChunkDirectory.collision_query(directory, %{
                 logical_scene_id: scene_id,
                 chunk_coord: {0, 0, 0},
                 samples: []
               })

      assert Process.alive?(directory)
      assert {:ok, ^chunk_pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {0, 0, 0})
    after
      _ = :sys.resume(chunk_pid)
    end
  end

  test "collision_query honors a per-request timeout override" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = directory(chunk_sup: chunk_sup)
    scene_id = unique_scene_id()

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(directory, %{
               logical_scene_id: scene_id,
               chunk_coord: {0, 0, 0}
             })

    :ok = :sys.suspend(chunk_pid)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:error, {:chunk_unavailable, {:timeout, :collision_query}}} =
               ChunkDirectory.collision_query(
                 directory,
                 %{
                   logical_scene_id: scene_id,
                   chunk_coord: {0, 0, 0},
                   samples: [],
                   collision_query_timeout_ms: 10
                 },
                 200
               )

      assert System.monotonic_time(:millisecond) - started < 200
      assert Process.alive?(directory)
    after
      _ = :sys.resume(chunk_pid)
    end
  end

  test "apply_intents reports a stalled lease apply without crashing the directory" do
    chunk_sup = start_supervised!(VoxelChunkSup)

    directory =
      directory(chunk_sup: chunk_sup, chunk_call_timeout_ms: 10)

    scene_id = unique_scene_id()

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(directory, %{
               logical_scene_id: scene_id,
               chunk_coord: {0, 0, 0}
             })

    :ok = :sys.suspend(chunk_pid)

    try do
      assert {:error, {:chunk_unavailable, {:timeout, :apply_lease}}} =
               ChunkDirectory.apply_intents(directory, [
                 %{
                   logical_scene_id: scene_id,
                   chunk_coord: {0, 0, 0},
                   lease: lease(scene_id),
                   operation: :put_solid_block,
                   macro: {0, 0, 0},
                   block: NormalBlockData.new(1)
                 }
               ])

      assert Process.alive?(directory)
      assert {:ok, ^chunk_pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {0, 0, 0})
    after
      _ = :sys.resume(chunk_pid)
    end
  end

  test "subscribe preserves per-subscriber delivery mode across later chunk updates" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = directory(chunk_sup: chunk_sup)

    scene_id = unique_scene_id()
    lease = lease(scene_id)

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(
               WriteTokenStore,
               Map.put(lease, :token_version, 1)
             )

    legacy_subscriber = start_forwarding_subscriber(:legacy_directory)
    envelope_subscriber = start_forwarding_subscriber(:envelope_directory)

    assert {:ok, legacy_payload} =
             ChunkDirectory.subscribe(directory, %{
               request_id: 501,
               logical_scene_id: scene_id,
               chunk_coord: {1, 1, 1},
               lease: lease,
               subscriber: legacy_subscriber
             })

    assert_receive {:subscriber_message, :legacy_directory,
                    {:voxel_chunk_snapshot_payload, ^legacy_payload}}

    assert {:ok, envelope_payload} =
             ChunkDirectory.subscribe(directory, %{
               request_id: 502,
               logical_scene_id: scene_id,
               chunk_coord: {1, 1, 1},
               lease: lease,
               subscriber: envelope_subscriber,
               delivery_format: :envelope,
               tier: :halo
             })

    assert_receive {:subscriber_message, :envelope_directory,
                    {:voxel_delivery_envelope, %{payload: ^envelope_payload}}}

    assert {:ok, %{chunk_version: 1, persist_result: :inserted}} =
             ChunkDirectory.apply_intent(directory, %{
               request_id: 503,
               logical_scene_id: scene_id,
               chunk_coord: {1, 1, 1},
               lease: lease,
               operation: :put_solid_block,
               macro: {3, 0, 0},
               block: NormalBlockData.new(11, health: 40)
             })

    assert_receive {:subscriber_message, :legacy_directory,
                    {:voxel_chunk_delta_payload, delta_payload}}

    assert_receive {:subscriber_message, :envelope_directory,
                    {:voxel_delivery_envelope, envelope}}

    assert envelope.frame_kind == :delta
    assert envelope.logical_scene_id == scene_id
    assert envelope.chunk_coord == {1, 1, 1}
    assert envelope.tier == :halo
    assert envelope.stream_class == :voxel_delta
    assert envelope.base_server_version == 0
    assert envelope.server_version == 1
    assert envelope.lease_id == lease.lease_id
    assert envelope.owner_epoch == lease.owner_epoch
    assert envelope.byte_size == byte_size(delta_payload)
    assert envelope.payload == delta_payload
  end

  test "apply_intent rejects missing leases before starting a chunk" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = directory(chunk_sup: chunk_sup)
    scene_id = unique_scene_id()

    assert {:error, :missing_lease} =
             ChunkDirectory.apply_intent(directory, %{
               request_id: 91,
               logical_scene_id: scene_id,
               chunk_coord: {1, 1, 1},
               operation: :put_solid_block,
               macro: 0,
               block: NormalBlockData.new(11)
             })

    assert ChunkDirectory.snapshot(directory).chunk_count == 0
  end

  test "prewarm_handoff loads persisted snapshots into target chunks without rewriting" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = directory(chunk_sup: chunk_sup)

    scene_id = unique_scene_id()
    old_lease = lease(scene_id)
    new_lease = %{old_lease | lease_id: 101, owner_scene_instance_ref: 2_000, owner_epoch: 2}

    storage =
      scene_id
      |> Storage.empty({1, 0, 0})
      |> Storage.put_solid_block({2, 0, 0}, NormalBlockData.new(19, health: 80))
      |> Map.put(:chunk_version, 3)

    payload = Codec.encode_chunk_snapshot_payload(%{request_id: 0, storage: storage})

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(
               WriteTokenStore,
               Map.put(old_lease, :token_version, 1)
             )

    assert {:ok, :inserted} =
             ChunkSnapshotStore.put_snapshot(%{
               logical_scene_id: scene_id,
               region_id: old_lease.region_id,
               chunk_coord: {1, 0, 0},
               lease_id: old_lease.lease_id,
               owner_scene_instance_ref: old_lease.owner_scene_instance_ref,
               owner_epoch: old_lease.owner_epoch,
               chunk_version: storage.chunk_version,
               chunk_hash: Hash.encode64(Codec.chunk_hash(storage)),
               data: payload
             })

    handoff = %{
      migration_id: "migration-1",
      logical_scene_id: scene_id,
      region_id: old_lease.region_id,
      new_lease: new_lease,
      planned_slices: [
        %{
          slice_id: "migration-1:slice:0",
          bounds_chunk_min: {1, 0, 0},
          bounds_chunk_max: {2, 1, 1}
        }
      ]
    }

    assert {:ok, %{chunk_count: 1, loaded_count: 1, empty_count: 0, chunks: [chunk]}} =
             ChunkDirectory.prewarm_handoff(directory, handoff)

    assert chunk.chunk_coord == {1, 0, 0}
    assert chunk.chunk_version == 3

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(directory, %{
               logical_scene_id: scene_id,
               chunk_coord: {1, 0, 0}
             })

    assert %{lease: %{lease_id: 101, owner_scene_instance_ref: 2_000, owner_epoch: 2}} =
             SceneServer.Voxel.ChunkProcess.debug_state(chunk_pid)

    assert {:ok, prewarmed_payload} =
             ChunkDirectory.snapshot_payload(directory, %{
               request_id: 77,
               logical_scene_id: scene_id,
               chunk_coord: {1, 0, 0}
             })

    assert {:ok, %{request_id: 77, storage: prewarmed_storage}} =
             Codec.decode_chunk_snapshot_payload(prewarmed_payload)

    assert prewarmed_storage.chunk_version == 3

    assert Storage.macro_header_at(prewarmed_storage, {2, 0, 0}).mode ==
             MacroCellHeader.cell_mode_solid_block()
  end

  describe "lookup_chunk_pid/3 (Phase 4-bis D1)" do
    test "returns :not_started when no chunk has been registered for the coord" do
      chunk_sup = start_supervised!(VoxelChunkSup)
      directory = directory(chunk_sup: chunk_sup)
      scene_id = unique_scene_id()

      assert :not_started = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {0, 0, 0})
    end

    test "returns {:ok, pid} for a chunk that was started via snapshot_payload" do
      chunk_sup = start_supervised!(VoxelChunkSup)
      directory = directory(chunk_sup: chunk_sup)
      scene_id = unique_scene_id()

      assert {:ok, _payload} =
               ChunkDirectory.snapshot_payload(directory, %{
                 request_id: 1,
                 logical_scene_id: scene_id,
                 center_chunk: {7, 7, 7}
               })

      assert {:ok, pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {7, 7, 7})
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "scopes lookup by logical_scene_id (different scene with same coord misses)" do
      chunk_sup = start_supervised!(VoxelChunkSup)
      directory = directory(chunk_sup: chunk_sup)
      scene_id = unique_scene_id()
      other_scene_id = unique_scene_id()

      assert {:ok, _} =
               ChunkDirectory.snapshot_payload(directory, %{
                 request_id: 1,
                 logical_scene_id: scene_id,
                 center_chunk: {0, 0, 0}
               })

      assert {:ok, _pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {0, 0, 0})
      # Same coord, different scene → miss
      assert :not_started = ChunkDirectory.lookup_chunk_pid(directory, other_scene_id, {0, 0, 0})
    end

    test "returns :not_started when the registered chunk pid is dead" do
      chunk_sup = start_supervised!(VoxelChunkSup)
      directory = directory(chunk_sup: chunk_sup)
      scene_id = unique_scene_id()

      assert {:ok, _} =
               ChunkDirectory.snapshot_payload(directory, %{
                 request_id: 1,
                 logical_scene_id: scene_id,
                 center_chunk: {3, 3, 3}
               })

      assert {:ok, pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {3, 3, 3})

      # 阶段3.1：经监督树终止该权威进程，使它**不**按 :transient 重启回同一身份槽位
      # （直接 `Process.exit(pid, :kill)` 是异常退出，会触发重启并注册新 pid，无法
      # 观察到"已死但仍注册"的窗口）。terminate_child 后进程不再重启，注册表对该死
      # 条目的摘除仍是异步的，因此用轮询等到 facade 解析为 :not_started——验证 facade
      # 主动过滤死 pid 的契约，而不是把死 / 残留条目泄漏给调用方。
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(chunk_sup, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      wait_until(fn ->
        ChunkDirectory.lookup_chunk_pid(directory, scene_id, {3, 3, 3}) == :not_started
      end)

      assert :not_started = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {3, 3, 3})
    end
  end

  defp unique_scene_id do
    System.unique_integer([:positive, :monotonic]) + 10_000_000
  end

  # 轮询等待 `fun` 为真，替代固定 sleep 后立即断言（注册表死条目摘除 / 监督树
  # 重建是异步的，固定窗口会 flaky）。
  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not met before timeout")

  defp lease(scene_id) do
    %{
      logical_scene_id: scene_id,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }
  end

  defp start_forwarding_subscriber(label) do
    parent = self()
    spawn_link(fn -> forward_subscriber_messages(parent, label) end)
  end

  defp forward_subscriber_messages(parent, label) do
    receive do
      message ->
        send(parent, {:subscriber_message, label, message})
        forward_subscriber_messages(parent, label)
    end
  end
end
