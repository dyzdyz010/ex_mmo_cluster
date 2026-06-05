defmodule SceneServer.Voxel.ChunkProcessObjectStateDeltaPushTest do
  # Phase 4-bis Step 4-bis-4: ChunkProcess.push_object_state_delta_payload/2
  # cast handler + fan_out_object_state_delta_payload/2 helper.
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Codec

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset(WriteTokenStore)

    # 阶段3.1：隔离 chunk 进程身份注册表，避免全局单例 {1, {0,0,0}} 槽位跨测试串扰。
    chunk_registry =
      :"chunk_process_object_state_delta_push_test_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, keys: :unique, name: chunk_registry},
      id: {:registry, chunk_registry}
    )

    Process.put(:chunk_registry, chunk_registry)
    :ok
  end

  describe "push_object_state_delta_payload/2 cast (Phase 4-bis D1)" do
    test "is a no-op when the chunk has no subscribers" do
      chunk = start_supervised!({ChunkProcess, chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}})

      payload = sample_payload()

      :ok = ChunkProcess.push_object_state_delta_payload(chunk, payload)

      # Allow cast to be processed.
      _ = ChunkProcess.debug_state(chunk)

      refute_received {:voxel_object_state_delta_payload, _}
    end

    test "delivers the payload to a single subscriber" do
      chunk = start_supervised!({ChunkProcess, chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}})

      assert {:ok, _snapshot_payload} =
               ChunkProcess.subscribe(chunk, self(), request_id: 55)

      # Drain initial snapshot push first so we don't confuse it with the
      # 0x6C delivery below.
      assert_receive {:voxel_chunk_snapshot_payload, _}

      payload = sample_payload()

      :ok = ChunkProcess.push_object_state_delta_payload(chunk, payload)

      assert_receive {:voxel_object_state_delta_payload, ^payload}
    end

    test "delivers the same payload to multiple subscribers" do
      chunk = start_supervised!({ChunkProcess, chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}})

      parent = self()

      sub_pids =
        for i <- 1..3 do
          spawn_link(fn ->
            assert {:ok, _} = ChunkProcess.subscribe(chunk, self(), request_id: 100 + i)

            receive do
              {:voxel_chunk_snapshot_payload, _} -> :ok
            after
              500 -> raise "subscriber #{i} timed out waiting for snapshot"
            end

            receive do
              {:voxel_object_state_delta_payload, payload} ->
                send(parent, {:received, i, payload})
            after
              500 -> raise "subscriber #{i} timed out waiting for 0x6C"
            end
          end)
        end

      # Give subscribers time to register. We send the cast after; the chunk
      # serializes subscribe + cast in its mailbox order, so as long as the
      # spawned subscribers complete `ChunkProcess.subscribe` before this
      # test code reaches `push_object_state_delta_payload` the cast will
      # see all three subscribers.
      #
      # Using a `debug_state` round-trip blocks until subscribe calls are drained.
      Enum.reduce_while(1..30, nil, fn _, _acc ->
        if length(ChunkProcess.debug_state(chunk).subscribers) >= 3 do
          {:halt, :ok}
        else
          Process.sleep(10)
          {:cont, nil}
        end
      end)

      payload = sample_payload()

      :ok = ChunkProcess.push_object_state_delta_payload(chunk, payload)

      received_ids =
        for _ <- 1..3 do
          receive do
            {:received, i, ^payload} -> i
          after
            500 -> raise "did not receive from one of the subscribers"
          end
        end

      assert Enum.sort(received_ids) == [1, 2, 3]

      Enum.each(sub_pids, &Process.exit(&1, :normal))
    end

    test "rejects non-binary payloads at the public API boundary" do
      chunk = start_supervised!({ChunkProcess, chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}})

      assert_raise FunctionClauseError, fn ->
        ChunkProcess.push_object_state_delta_payload(chunk, %{not: :a_binary})
      end
    end
  end

  defp sample_payload do
    Codec.encode_voxel_object_state_delta_payload(%{
      logical_scene_id: 1,
      object_id: 42,
      object_version: 7,
      state_flags: 0x1,
      affected_chunks: [{0, 0, 0}]
    })
  end
end
