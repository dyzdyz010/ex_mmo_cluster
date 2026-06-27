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
    WriteTokenStore.reset()
    :ok
  end

  test "lazily starts chunks and returns snapshot payloads" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
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
    directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})

    scene_id = unique_scene_id()
    lease = lease(scene_id)

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(Map.put(lease, :token_version, 1))

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
    directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})

    scene_id = unique_scene_id()
    lease = lease(scene_id)

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(Map.put(lease, :token_version, 1))

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

  test "apply_intent rejects missing leases before starting a chunk" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
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
    directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})

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
             WriteTokenStore.upsert_token(Map.put(old_lease, :token_version, 1))

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
      directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
      scene_id = unique_scene_id()

      assert :not_started = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {0, 0, 0})
    end

    test "returns {:ok, pid} for a chunk that was started via snapshot_payload" do
      chunk_sup = start_supervised!(VoxelChunkSup)
      directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
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
      directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
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
      directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
      scene_id = unique_scene_id()

      assert {:ok, _} =
               ChunkDirectory.snapshot_payload(directory, %{
                 request_id: 1,
                 logical_scene_id: scene_id,
                 center_chunk: {3, 3, 3}
               })

      assert {:ok, pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {3, 3, 3})

      Process.exit(pid, :kill)
      # Allow the EXIT to propagate.
      Process.sleep(20)

      assert :not_started = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {3, 3, 3})
    end
  end

  # 形态轨 C5.2:表面元件网络放置经 ChunkDirectory → ChunkProcess,带 lease 同步落库。
  test "apply_surface_element_intent places + persists a torch and clears it (durable)" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})

    scene_id = unique_scene_id()
    lease = lease(scene_id)

    assert {:ok, :inserted} = WriteTokenStore.upsert_token(Map.put(lease, :token_version, 1))

    macro_index = SceneServer.Voxel.Types.macro_index!({3, 0, 0})
    torch = SceneServer.Voxel.SurfaceCatalog.surface_type_id(:torch)

    # 火炬装饰实心块的面 —— 先放宿主块(version 1)。
    assert {:ok, %{chunk_version: 1}} =
             ChunkDirectory.apply_intent(directory, %{
               request_id: 1,
               logical_scene_id: scene_id,
               chunk_coord: {1, 1, 1},
               lease: lease,
               operation: :put_solid_block,
               macro: {3, 0, 0},
               block: NormalBlockData.new(11, health: 40)
             })

    # 放火炬(version → 2),durable-before-ack。
    assert {:ok, %{chunk_version: 2, chunk_coord: {1, 1, 1}}} =
             ChunkDirectory.apply_surface_element_intent(directory, %{
               request_id: 2,
               logical_scene_id: scene_id,
               chunk_coord: {1, 1, 1},
               lease: lease,
               action: :place,
               macro_index: macro_index,
               face: :x_pos,
               surface_type_id: torch,
               owner_actor_id: 4242
             })

    # 内存:元件在位、owner 注入正确。
    assert {:ok, chunk_pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {1, 1, 1})
    el = ChunkProcess.surface_element_at(chunk_pid, macro_index, :x_pos)
    assert el.surface_type_id == torch
    assert el.owner_actor_id == 4242

    # 落库:持久化快照带上该面 truth(durable-before-ack)。
    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(scene_id, {1, 1, 1})
    assert snapshot.chunk_version == 2
    assert {:ok, %{storage: storage}} = Codec.decode_chunk_snapshot_payload(snapshot.data)
    assert Storage.surface_element_at(storage, macro_index, :x_pos).surface_type_id == torch

    # 清除路径同样落库(version → 3,面 truth 消失)。
    assert {:ok, %{chunk_version: 3}} =
             ChunkDirectory.apply_surface_element_intent(directory, %{
               request_id: 3,
               logical_scene_id: scene_id,
               chunk_coord: {1, 1, 1},
               lease: lease,
               action: :clear,
               macro_index: macro_index,
               face: :x_pos
             })

    assert {:ok, snapshot2} = ChunkSnapshotStore.get_snapshot(scene_id, {1, 1, 1})
    assert snapshot2.chunk_version == 3
    assert {:ok, %{storage: storage2}} = Codec.decode_chunk_snapshot_payload(snapshot2.data)
    assert Storage.surface_element_at(storage2, macro_index, :x_pos) == nil
  end

  test "apply_surface_element_intent rejects a missing lease before starting a chunk" do
    chunk_sup = start_supervised!(VoxelChunkSup)
    directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
    scene_id = unique_scene_id()

    assert {:error, :missing_lease} =
             ChunkDirectory.apply_surface_element_intent(directory, %{
               request_id: 1,
               logical_scene_id: scene_id,
               chunk_coord: {1, 1, 1},
               action: :place,
               macro_index: 0,
               face: :x_pos,
               surface_type_id: SceneServer.Voxel.SurfaceCatalog.surface_type_id(:torch)
             })

    assert ChunkDirectory.snapshot(directory).chunk_count == 0
  end

  # 2026-06-27 透明崩溃恢复:ChunkProcess 崩溃后,目录自动把原订阅者重订到新进程,
  # 带快照让客户端追上,客户端完全无感。
  describe "transparent ChunkProcess crash recovery" do
    test "rebuilds the chunk and re-subscribes original subscribers with a snapshot on crash" do
      chunk_sup = start_supervised!(VoxelChunkSup)
      directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
      scene_id = unique_scene_id()

      # self() 作为订阅者:subscribe 立即推一个快照(known_version nil ≠ chunk_version)。
      assert {:ok, _payload} =
               ChunkDirectory.subscribe(directory, %{
                 request_id: 1,
                 logical_scene_id: scene_id,
                 chunk_coord: {2, 2, 2},
                 subscriber: self()
               })

      # 初次订阅快照。
      assert_receive {:voxel_chunk_snapshot_payload, _initial}, 2_000

      assert {:ok, old_pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {2, 2, 2})

      # 模拟崩溃。
      Process.exit(old_pid, :kill)

      # 等目录处理 DOWN + 重建。崩溃恢复推第二个快照。
      assert_receive {:voxel_chunk_snapshot_payload, _recovered}, 2_000

      # (b) chunk 有了新 pid 且 alive。
      assert {:ok, new_pid} = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {2, 2, 2})
      assert new_pid != old_pid
      assert Process.alive?(new_pid)

      # (a) 内部订阅者镜像仍含该订阅者(已重订到新进程)。
      assert MapSet.member?(directory_subscribers(directory, scene_id, {2, 2, 2}), self())
    end

    test "does not rebuild or error when an idle (no-subscriber) chunk goes DOWN" do
      chunk_sup = start_supervised!(VoxelChunkSup)
      directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
      scene_id = unique_scene_id()

      # 起一个 chunk 但不订阅(无订阅者镜像)。
      assert {:ok, pid} =
               ChunkDirectory.ensure_chunk(directory, %{
                 logical_scene_id: scene_id,
                 chunk_coord: {5, 5, 5}
               })

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

      # 目录仍存活、不重建。
      assert Process.alive?(directory)
      # 无订阅者 → 该 coord 不再 hot(不重建)。
      assert :not_started = ChunkDirectory.lookup_chunk_pid(directory, scene_id, {5, 5, 5})
    end

    test "clears the subscriber mirror when a subscriber process dies" do
      chunk_sup = start_supervised!(VoxelChunkSup)
      directory = start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})
      scene_id = unique_scene_id()

      # 临时订阅者进程:订阅后立即被 kill,不影响测试进程。
      parent = self()

      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end

          send(parent, :never)
        end)

      assert {:ok, _payload} =
               ChunkDirectory.subscribe(directory, %{
                 request_id: 1,
                 logical_scene_id: scene_id,
                 chunk_coord: {3, 3, 3},
                 subscriber: subscriber
               })

      assert MapSet.member?(directory_subscribers(directory, scene_id, {3, 3, 3}), subscriber)

      Process.exit(subscriber, :kill)

      # 等目录处理 subscriber DOWN —— 用一次同步 call 作为屏障(目录已串行处理完 DOWN)。
      _ = ChunkDirectory.snapshot(directory)
      wait_until(fn -> not MapSet.member?(directory_subscribers(directory, scene_id, {3, 3, 3}), subscriber) end)

      refute MapSet.member?(directory_subscribers(directory, scene_id, {3, 3, 3}), subscriber)
      assert Process.alive?(directory)
    end
  end

  # 读目录内部 subscribers 镜像(测试用 :sys.get_state,避免新增公共 API)。
  defp directory_subscribers(directory, scene_id, chunk_coord) do
    state = :sys.get_state(directory)
    Map.get(state.subscribers, {scene_id, chunk_coord}, MapSet.new())
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      attempts <= 0 -> :ok
      fun.() -> :ok
      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  defp unique_scene_id do
    System.unique_integer([:positive, :monotonic]) + 10_000_000
  end

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
end
