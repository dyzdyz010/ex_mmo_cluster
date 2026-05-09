defmodule SceneServer.Voxel.ObjectStateDeltaE2ETest do
  # Phase 4-bis Step 4-bis-11: end-to-end push pipeline:
  #
  #   ObjectRegistry.{accumulate_damage, destroy_part, destroy_object}
  #     → encode 0x6C ObjectStateDelta payload (scene_server/voxel/codec.ex)
  #     → ChunkDirectory.lookup_chunk_pid → ChunkProcess.cast push
  #     → ChunkProcess fan_out → subscriber send (here = self())
  #
  # The test process subscribes itself directly to a real ChunkProcess and
  # asserts that it receives `{:voxel_object_state_delta_payload, binary}`
  # carrying the canonical 0x6C wire bytes for each event.
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.SceneObjectStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.ObjectRegistry
  alias SceneServer.Voxel.PartState

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    SceneObjectStore.reset()
    WriteTokenStore.reset(WriteTokenStore)

    chunk_directory = start_or_reuse_chunk_directory!()
    registry = start_or_reuse_registry!(chunk_directory)
    :ok = ObjectRegistry.reset(registry)

    %{registry: registry, chunk_directory: chunk_directory}
  end

  describe "end-to-end ObjectStateDelta push" do
    test "destroy_object emits one 0x6C wire frame to chunk subscribers", ctx do
      chunk_coord = {3, 3, 3}
      lease = lease_with_token()

      chunk =
        start_chunk!(
          chunk_coord: chunk_coord,
          chunk_directory: ctx.chunk_directory,
          lease: lease
        )

      {:ok, _initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 99)
      assert_receive {:voxel_chunk_snapshot_payload, _}, 1_000

      :ok =
        ObjectRegistry.upsert_object(
          ctx.registry,
          instance_attrs(
            object_id: 7,
            covered_chunks: [chunk_coord],
            part_states: [PartState.new(part_id: 1, health: 50)]
          )
        )

      assert {:object_destroyed, _} = ObjectRegistry.destroy_object(ctx.registry, 1, 7)

      assert_receive {:voxel_object_state_delta_payload, payload}, 1_000

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload)
      assert decoded.logical_scene_id == 1
      assert decoded.object_id == 7
      assert decoded.state_flags == PartState.flag_destroyed()
      # destroy_object bumps object_version 1 → 2.
      assert decoded.object_version == 2
      assert decoded.affected_chunks == [chunk_coord]
      assert decoded.attribute_patch_count == 0
      assert decoded.tag_patch_count == 0
    end

    test "non-destroying damage emits flag_damaged 0x6C wire frame", ctx do
      chunk_coord = {2, 2, 2}
      lease = lease_with_token()

      chunk =
        start_chunk!(
          chunk_coord: chunk_coord,
          chunk_directory: ctx.chunk_directory,
          lease: lease
        )

      {:ok, _} = ChunkProcess.subscribe(chunk, self(), request_id: 100)
      assert_receive {:voxel_chunk_snapshot_payload, _}, 1_000

      :ok =
        ObjectRegistry.upsert_object(
          ctx.registry,
          instance_attrs(
            object_id: 8,
            covered_chunks: [chunk_coord],
            part_states: [PartState.new(part_id: 1, health: 100)]
          )
        )

      assert :ok = ObjectRegistry.accumulate_damage(ctx.registry, 1, 8, 1, 30)

      assert_receive {:voxel_object_state_delta_payload, payload}, 1_000

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload)
      assert decoded.object_id == 8
      assert decoded.state_flags == PartState.flag_damaged()
      assert decoded.object_version == 2
    end

    test "cascade(damage 致命)emits two 0x6C frames in version-monotone order", ctx do
      chunk_coord = {5, 5, 5}
      lease = lease_with_token()

      chunk =
        start_chunk!(
          chunk_coord: chunk_coord,
          chunk_directory: ctx.chunk_directory,
          lease: lease
        )

      {:ok, _} = ChunkProcess.subscribe(chunk, self(), request_id: 101)
      assert_receive {:voxel_chunk_snapshot_payload, _}, 1_000

      :ok =
        ObjectRegistry.upsert_object(
          ctx.registry,
          instance_attrs(
            object_id: 9,
            covered_chunks: [chunk_coord],
            part_states: [PartState.new(part_id: 1, health: 5)]
          )
        )

      assert {:object_destroyed, _} = ObjectRegistry.accumulate_damage(ctx.registry, 1, 9, 1, 50)

      assert_receive {:voxel_object_state_delta_payload, p1}, 1_000
      assert_receive {:voxel_object_state_delta_payload, p2}, 1_000

      assert {:ok, d1, ""} = Codec.decode_voxel_object_state_delta_payload(p1)
      assert {:ok, d2, ""} = Codec.decode_voxel_object_state_delta_payload(p2)

      # First message: cascade-triggered part_destroyed.
      # Second message: full destroyed (run_destroy_object bumps version).
      assert d1.state_flags == PartState.flag_part_destroyed()
      assert d2.state_flags == PartState.flag_destroyed()
      assert d1.object_version < d2.object_version
    end
  end

  ## Helpers

  defp start_or_reuse_chunk_directory! do
    case Process.whereis(ChunkDirectory) do
      nil ->
        chunk_sup = start_supervised!(SceneServer.VoxelChunkSup)
        start_supervised!({ChunkDirectory, chunk_sup: chunk_sup})

      pid ->
        pid
    end
  end

  defp start_or_reuse_registry!(chunk_directory) do
    case Process.whereis(ObjectRegistry) do
      nil ->
        start_supervised!({ObjectRegistry, chunk_directory: chunk_directory})

      pid ->
        pid
    end
  end

  # Start a chunk *through* the ChunkDirectory so it registers in
  # state.chunks under {logical_scene_id, chunk_coord}; ObjectRegistry's
  # dispatch path uses lookup_chunk_pid against the same directory.
  defp start_chunk!(opts) do
    chunk_coord = Keyword.fetch!(opts, :chunk_coord)
    lease = Keyword.fetch!(opts, :lease)
    chunk_directory = Keyword.fetch!(opts, :chunk_directory)

    {:ok, chunk_pid} =
      ChunkDirectory.ensure_chunk(chunk_directory, %{
        logical_scene_id: 1,
        chunk_coord: chunk_coord,
        lease: lease
      })

    chunk_pid
  end

  defp lease_with_token do
    lease = %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {10, 10, 10},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }

    {:ok, _} = WriteTokenStore.upsert_token(WriteTokenStore, Map.put(lease, :token_version, 1))
    lease
  end

  defp instance_attrs(overrides) do
    %{
      object_id: 42,
      logical_scene_id: 1,
      parcel_id: 13,
      blueprint_id: 7,
      blueprint_version: 2,
      anchor_world_micro: {0, 0, 0},
      rotation: 0,
      owner_actor_id: 1_001,
      state_flags: 0,
      object_attribute_ref: 0,
      object_tag_set_ref: 0,
      covered_chunks: [{1, 1, 1}],
      part_states: [PartState.new(part_id: 1, health: 80, state_flags: 0)],
      object_version: 1,
      owner_region_id: 1,
      owner_lease_id: 100
    }
    |> Map.merge(Map.new(overrides))
  end
end
