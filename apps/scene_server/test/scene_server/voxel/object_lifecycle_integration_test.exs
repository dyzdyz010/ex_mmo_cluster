defmodule SceneServer.Voxel.ObjectLifecycleIntegrationTest do
  # Phase 4 Step 4-7: end-to-end prefab → place → attack → part_destroyed →
  # object_destroyed across real ObjectRegistry + ChunkDirectory + ChunkProcess.
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.SceneObjectStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.ObjectRegistry
  alias SceneServer.Voxel.PartState

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    SceneObjectStore.reset()
    WriteTokenStore.reset()

    # Use already-running ObjectRegistry / ChunkDirectory instances if the
    # SceneServer.Application boot has supplied them (full integration), but
    # otherwise spin up fresh ones.
    registry = start_or_reuse_registry!()
    chunk_directory = start_or_reuse_chunk_directory!()

    # Reset registry's in-memory state so prior tests don't contaminate.
    :ok = ObjectRegistry.reset(registry)

    %{registry: registry, chunk_directory: chunk_directory}
  end

  describe "single-part object lifecycle" do
    test "place → damage → part_destroyed → object_destroyed full chain", %{
      registry: registry,
      chunk_directory: chunk_directory
    } do
      lease = lease_with_token()

      chunk =
        start_chunk!(
          chunk_coord: {1, 1, 1},
          object_registry: registry,
          chunk_directory: chunk_directory,
          lease: lease
        )

      # Step 1:simulate the executor registering the SceneObjectInstance
      # post-commit (BuildTransactionApplier.register_scene_objects).
      instance =
        instance_attrs(
          object_id: 42,
          covered_chunks: [{1, 1, 1}],
          part_states: [PartState.new(part_id: 1, health: 2, state_flags: 0)]
        )

      :ok = ObjectRegistry.upsert_object(registry, instance)

      # Step 2:place 2 owner=42 micros via apply_intents (the intents that
      # would have been driven by a transactional commit dispatch).
      place = [
        micro_intent(lease, request_id: 1, micro_slot: 0, owner_object_id: 42, owner_part_id: 1),
        micro_intent(lease, request_id: 2, micro_slot: 1, owner_object_id: 42, owner_part_id: 1)
      ]

      assert {:ok, _} = ChunkProcess.apply_intents(chunk, place)

      assert [%{object_id: 42}] = chunk_object_refs(chunk)

      # Step 3:break the 2 micros → 2 damage → part 1 health 2 → 0 →
      # part_destroyed → object_destroyed (only one part).
      break = [
        clear_micro_intent(lease, request_id: 3, micro_slot: 0),
        clear_micro_intent(lease, request_id: 4, micro_slot: 1)
      ]

      assert {:ok, _} = ChunkProcess.apply_intents(chunk, break)

      # Damage dispatch is async (Task.start). Wait for the cascade to
      # propagate.
      assert_eventually(fn ->
        ObjectRegistry.lookup_object(registry, 1, 42) == nil
      end)

      # Object row gone from Postgres
      assert {:error, :object_not_found} = SceneObjectStore.get_object(42)

      # Chunk-level ChunkObjectRef[] empty
      assert chunk_object_refs(chunk) == []
    end
  end

  describe "multi-part object lifecycle" do
    test "destroying one part leaves the object alive, second part destroys it", %{
      registry: registry,
      chunk_directory: chunk_directory
    } do
      lease = lease_with_token()

      chunk =
        start_chunk!(
          chunk_coord: {1, 1, 1},
          object_registry: registry,
          chunk_directory: chunk_directory,
          lease: lease
        )

      instance =
        instance_attrs(
          object_id: 50,
          covered_chunks: [{1, 1, 1}],
          part_states: [
            PartState.new(part_id: 1, health: 1, state_flags: 0),
            PartState.new(part_id: 2, health: 1, state_flags: 0)
          ]
        )

      :ok = ObjectRegistry.upsert_object(registry, instance)

      # Place one micro per part
      place = [
        micro_intent(lease, request_id: 1, micro_slot: 0, owner_object_id: 50, owner_part_id: 1),
        micro_intent(lease, request_id: 2, micro_slot: 1, owner_object_id: 50, owner_part_id: 2)
      ]

      assert {:ok, _} = ChunkProcess.apply_intents(chunk, place)

      # Break part 1's micro → part 1 health 1 → 0 → destroy_part(part 1)
      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 clear_micro_intent(lease, request_id: 3, micro_slot: 0)
               )

      # Object still alive (part 2 unscathed)
      assert_eventually(fn ->
        case ObjectRegistry.lookup_object(registry, 1, 50) do
          nil -> false
          obj -> Enum.any?(obj.part_states, &PartState.destroyed?/1)
        end
      end)

      obj = ObjectRegistry.lookup_object(registry, 1, 50)
      [p1, p2] = obj.part_states
      assert PartState.destroyed?(p1)
      refute PartState.destroyed?(p2)

      # Break part 2's micro → cascade → object_destroyed
      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 clear_micro_intent(lease, request_id: 4, micro_slot: 1)
               )

      assert_eventually(fn ->
        ObjectRegistry.lookup_object(registry, 1, 50) == nil
      end)

      assert {:error, :object_not_found} = SceneObjectStore.get_object(50)
    end
  end

  ## Helpers

  defp start_or_reuse_registry! do
    case Process.whereis(ObjectRegistry) do
      nil ->
        start_supervised!(
          {ObjectRegistry, name: :"life_registry_#{System.unique_integer([:positive])}"}
        )

      pid ->
        pid
    end
  end

  defp start_or_reuse_chunk_directory! do
    case Process.whereis(ChunkDirectory) do
      nil ->
        start_supervised!(
          {ChunkDirectory, name: :"life_chunk_dir_#{System.unique_integer([:positive])}"}
        )

      pid ->
        pid
    end
  end

  defp start_chunk!(opts) do
    chunk_coord = Keyword.fetch!(opts, :chunk_coord)
    lease = Keyword.fetch!(opts, :lease)

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1,
         chunk_coord: chunk_coord,
         object_registry: Keyword.fetch!(opts, :object_registry),
         chunk_directory: Keyword.fetch!(opts, :chunk_directory)}
      )

    {:ok, _} = GenServer.call(chunk, {:apply_lease, lease})
    chunk
  end

  defp chunk_object_refs(chunk) do
    ChunkProcess.debug_state(chunk).storage.object_refs
  end

  defp lease_with_token do
    lease = %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }

    {:ok, _} = WriteTokenStore.upsert_token(Map.put(lease, :token_version, 1))
    lease
  end

  defp micro_intent(lease, opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    micro_slot = Keyword.fetch!(opts, :micro_slot)
    owner_object_id = Keyword.fetch!(opts, :owner_object_id)
    owner_part_id = Keyword.fetch!(opts, :owner_part_id)

    %{
      request_id: request_id,
      logical_scene_id: lease.logical_scene_id,
      chunk_coord: {1, 1, 1},
      lease: lease,
      operation: :put_micro_block,
      macro: {0, 0, 0},
      micro_slot: micro_slot,
      micro_layer: %{
        material_id: 1,
        owner_object_id: owner_object_id,
        owner_part_id: owner_part_id
      }
    }
  end

  defp clear_micro_intent(lease, opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    micro_slot = Keyword.fetch!(opts, :micro_slot)

    %{
      request_id: request_id,
      logical_scene_id: lease.logical_scene_id,
      chunk_coord: {1, 1, 1},
      lease: lease,
      operation: :clear_micro_block,
      macro: {0, 0, 0},
      micro_slot: micro_slot
    }
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

  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline, timeout_ms)
  end

  defp do_assert_eventually(fun, deadline, timeout_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true within #{timeout_ms}ms")
      else
        Process.sleep(10)
        do_assert_eventually(fun, deadline, timeout_ms)
      end
    end
  end
end
