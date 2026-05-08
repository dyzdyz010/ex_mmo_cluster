defmodule SceneServer.Voxel.ChunkProcessObjectProvenanceTest do
  # Phase 4 Step 4-5: ChunkProcess apply_normalized_intents 调用
  # Storage.refresh_chunk_object_refs/1,以及 BuildTransactionApplier.
  # register_scene_objects/2 把 BuildTransaction.scene_objects upsert 到
  # ObjectRegistry。
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.SceneObjectStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.BuildTransactionApplier
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.ChunkObjectRef
  alias SceneServer.Voxel.ObjectRegistry
  alias SceneServer.Voxel.PartState
  alias SceneServer.Voxel.Storage

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    SceneObjectStore.reset()
    WriteTokenStore.reset(WriteTokenStore)
    :ok
  end

  describe "apply_intent / apply_intents — owner provenance refresh (Phase 4 D6)" do
    test "put_micro_block with owner_object_id refreshes ChunkObjectRef[]" do
      lease = lease_with_token()
      chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      intent =
        micro_intent_attrs(lease,
          macro: {0, 0, 0},
          micro_slot: 5,
          micro_layer: %{
            material_id: 1,
            health: 100,
            owner_object_id: 42,
            owner_part_id: 3
          }
        )

      assert {:ok, _reply} = ChunkProcess.apply_intent(chunk, intent)

      storage = ChunkProcess.debug_state(chunk).storage

      # Layer-level truth: MicroLayer carries owner_object_id / owner_part_id
      cell = Storage.refined_cell_at(storage, {0, 0, 0})
      assert length(cell.layers) == 1
      [layer] = cell.layers
      assert layer.owner_object_id == 42
      assert layer.owner_part_id == 3

      # Cell-level reverse index rebuilt from layers
      assert length(cell.object_refs) == 1
      [cell_ref] = cell.object_refs
      assert cell_ref.owner_object_id == 42
      assert cell_ref.owner_part_id == 3

      # Chunk-level ChunkObjectRef[] aggregated from cell.object_refs
      assert length(storage.object_refs) == 1
      [chunk_ref] = storage.object_refs
      assert %ChunkObjectRef{object_id: 42} = chunk_ref
      assert chunk_ref.covered_macro_min == {0, 0, 0}
      assert chunk_ref.covered_macro_max == {1, 1, 1}
      assert chunk_ref.cover_hash > 0
    end

    test "apply_intents with multiple owner_object_ids produces sorted ChunkObjectRef[]" do
      lease = lease_with_token()
      chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      attrs = [
        micro_intent_attrs(lease,
          request_id: 1,
          macro: {0, 0, 0},
          micro_slot: 0,
          micro_layer: %{material_id: 1, owner_object_id: 99, owner_part_id: 1}
        ),
        micro_intent_attrs(lease,
          request_id: 2,
          macro: {1, 0, 0},
          micro_slot: 0,
          micro_layer: %{material_id: 1, owner_object_id: 5, owner_part_id: 1}
        ),
        micro_intent_attrs(lease,
          request_id: 3,
          macro: {2, 0, 0},
          micro_slot: 0,
          micro_layer: %{material_id: 1, owner_object_id: 50, owner_part_id: 1}
        )
      ]

      assert {:ok, _reply} = ChunkProcess.apply_intents(chunk, attrs)

      storage = ChunkProcess.debug_state(chunk).storage
      assert Enum.map(storage.object_refs, & &1.object_id) == [5, 50, 99]
    end

    test "break_micro_block prunes cell.object_refs and shrinks ChunkObjectRef[]" do
      lease = lease_with_token()
      chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      # Place owner=42 at slots 0 and 1
      attrs = [
        micro_intent_attrs(lease,
          request_id: 1,
          macro: {0, 0, 0},
          micro_slot: 0,
          micro_layer: %{material_id: 1, owner_object_id: 42, owner_part_id: 3}
        ),
        micro_intent_attrs(lease,
          request_id: 2,
          macro: {0, 0, 0},
          micro_slot: 1,
          micro_layer: %{material_id: 1, owner_object_id: 42, owner_part_id: 3}
        )
      ]

      assert {:ok, _reply} = ChunkProcess.apply_intents(chunk, attrs)

      storage_before = ChunkProcess.debug_state(chunk).storage
      assert length(storage_before.object_refs) == 1
      hash_before = hd(storage_before.object_refs).cover_hash

      # Break slot 0 → still owner=42 at slot 1, ChunkObjectRef stays but cover_hash changes
      break = %{
        request_id: 3,
        logical_scene_id: 1,
        chunk_coord: {1, 1, 1},
        lease: lease,
        operation: :clear_micro_block,
        macro: {0, 0, 0},
        micro_slot: 0
      }

      assert {:ok, _reply} = ChunkProcess.apply_intent(chunk, break)

      storage_partial = ChunkProcess.debug_state(chunk).storage
      assert length(storage_partial.object_refs) == 1
      assert hd(storage_partial.object_refs).cover_hash != hash_before

      # Break slot 1 → owner=42 fully gone, ChunkObjectRef[] becomes empty
      break_last = %{
        request_id: 4,
        logical_scene_id: 1,
        chunk_coord: {1, 1, 1},
        lease: lease,
        operation: :clear_micro_block,
        macro: {0, 0, 0},
        micro_slot: 1
      }

      assert {:ok, _reply} = ChunkProcess.apply_intent(chunk, break_last)

      storage_empty = ChunkProcess.debug_state(chunk).storage
      assert storage_empty.object_refs == []
    end
  end

  describe "ChunkProcess.destroy_part/2 (Phase 4 D8)" do
    test "wipes every micro slot owned by (object_id, part_id)" do
      lease = lease_with_token()
      chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      # Place owner=42 part=3 at slots 0,1; owner=42 part=4 at slot 2;
      # owner=99 part=1 at slot 3.
      attrs = [
        micro_intent_attrs(lease,
          request_id: 1,
          macro: {0, 0, 0},
          micro_slot: 0,
          micro_layer: %{material_id: 1, owner_object_id: 42, owner_part_id: 3}
        ),
        micro_intent_attrs(lease,
          request_id: 2,
          macro: {0, 0, 0},
          micro_slot: 1,
          micro_layer: %{material_id: 1, owner_object_id: 42, owner_part_id: 3}
        ),
        micro_intent_attrs(lease,
          request_id: 3,
          macro: {0, 0, 0},
          micro_slot: 2,
          micro_layer: %{material_id: 1, owner_object_id: 42, owner_part_id: 4}
        ),
        micro_intent_attrs(lease,
          request_id: 4,
          macro: {0, 0, 0},
          micro_slot: 3,
          micro_layer: %{material_id: 1, owner_object_id: 99, owner_part_id: 1}
        )
      ]

      assert {:ok, _reply} = ChunkProcess.apply_intents(chunk, attrs)

      # Apply lease to the chunk so destroy_part's persist call works
      {:ok, _} = GenServer.call(chunk, {:apply_lease, lease})

      # Destroy part 3 of object 42 — should clear slots 0,1 only
      assert {:ok, %{changed?: true, cleared_count: 2}} =
               ChunkProcess.destroy_part(chunk, %{object_id: 42, part_id: 3})

      storage = ChunkProcess.debug_state(chunk).storage

      # Part 4 of object 42 still alive (slot 2)
      assert Storage.lookup_owner_at(storage, {0, 0, 0}, 2) == {42, 4}
      # Part 3 slots cleared
      assert Storage.lookup_owner_at(storage, {0, 0, 0}, 0) == nil
      assert Storage.lookup_owner_at(storage, {0, 0, 0}, 1) == nil
      # Object 99 still alive
      assert Storage.lookup_owner_at(storage, {0, 0, 0}, 3) == {99, 1}

      # Chunk-level ChunkObjectRef still has 42 (part 4 alive) and 99
      assert Enum.map(storage.object_refs, & &1.object_id) |> Enum.sort() == [42, 99]
    end

    test "is a no-op when no matching slots exist" do
      lease = lease_with_token()
      chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, _} = GenServer.call(chunk, {:apply_lease, lease})

      # Empty chunk → destroy_part is a clean no-op
      assert {:ok, %{changed?: false, cleared_count: 0}} =
               ChunkProcess.destroy_part(chunk, %{object_id: 42, part_id: 3})
    end

    test "fully drains the only object → ChunkObjectRef[] becomes empty" do
      lease = lease_with_token()
      chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      attrs = [
        micro_intent_attrs(lease,
          request_id: 1,
          macro: {0, 0, 0},
          micro_slot: 0,
          micro_layer: %{material_id: 1, owner_object_id: 42, owner_part_id: 3}
        )
      ]

      assert {:ok, _} = ChunkProcess.apply_intents(chunk, attrs)
      {:ok, _} = GenServer.call(chunk, {:apply_lease, lease})

      assert {:ok, %{changed?: true, cleared_count: 1}} =
               ChunkProcess.destroy_part(chunk, %{object_id: 42, part_id: 3})

      storage = ChunkProcess.debug_state(chunk).storage
      assert storage.object_refs == []
    end
  end

  describe "ChunkProcess.cleanup_object_refs/2 (Phase 4 D9)" do
    test "drops a stale ChunkObjectRef[] entry by object_id" do
      lease = lease_with_token()
      chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      attrs = [
        micro_intent_attrs(lease,
          request_id: 1,
          macro: {0, 0, 0},
          micro_slot: 0,
          micro_layer: %{material_id: 1, owner_object_id: 42, owner_part_id: 3}
        )
      ]

      assert {:ok, _} = ChunkProcess.apply_intents(chunk, attrs)
      assert {:ok, _} = GenServer.call(chunk, {:apply_lease, lease})

      # Sanity: ref present
      assert [%{object_id: 42}] = ChunkProcess.debug_state(chunk).storage.object_refs

      # cleanup
      assert :ok = ChunkProcess.cleanup_object_refs(chunk, %{object_id: 42})

      assert ChunkProcess.debug_state(chunk).storage.object_refs == []
    end

    test "is idempotent when no stale entry exists" do
      lease = lease_with_token()
      chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, _} = GenServer.call(chunk, {:apply_lease, lease})

      assert :ok = ChunkProcess.cleanup_object_refs(chunk, %{object_id: 42})
    end
  end

  describe "BuildTransactionApplier.register_scene_objects/2 (Phase 4 D5)" do
    test "upserts every scene_object into the ObjectRegistry" do
      registry =
        start_supervised!(
          {ObjectRegistry, name: :"test_registry_#{System.unique_integer([:positive])}"}
        )

      scene_objects = [
        instance_attrs(object_id: 100),
        instance_attrs(object_id: 101, blueprint_id: 9)
      ]

      assert :ok =
               BuildTransactionApplier.register_scene_objects(
                 scene_objects,
                 object_registry: registry
               )

      assert obj1 = ObjectRegistry.lookup_object(registry, 1, 100)
      assert obj1.object_id == 100
      assert obj1.blueprint_id == 7
      # part_states normalized to PartState struct in memory
      assert match?([%PartState{} | _], obj1.part_states)

      assert obj2 = ObjectRegistry.lookup_object(registry, 1, 101)
      assert obj2.blueprint_id == 9

      # Persisted to Postgres too
      assert {:ok, _} = SceneObjectStore.get_object(100)
      assert {:ok, _} = SceneObjectStore.get_object(101)
    end

    test "is a cheap no-op for empty list" do
      assert :ok = BuildTransactionApplier.register_scene_objects([])
    end

    test "swallows individual upsert failures and emits observe" do
      registry =
        start_supervised!(
          {ObjectRegistry, name: :"failing_registry_#{System.unique_integer([:positive])}"}
        )

      # An invalid seed (negative object_id) — store will reject
      bad_seed = instance_attrs(object_id: -1)

      # Returns :ok regardless of inner failures (per moduledoc)
      assert :ok =
               BuildTransactionApplier.register_scene_objects(
                 [bad_seed],
                 object_registry: registry
               )
    end
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

    {:ok, _} = WriteTokenStore.upsert_token(WriteTokenStore, Map.put(lease, :token_version, 1))
    lease
  end

  defp micro_intent_attrs(lease, overrides) do
    %{
      request_id: 70,
      logical_scene_id: lease.logical_scene_id,
      chunk_coord: {1, 1, 1},
      lease: lease,
      operation: :put_micro_block,
      macro: {0, 0, 0},
      micro_slot: 0,
      micro_layer: %{material_id: 1, health: 100}
    }
    |> Map.merge(Map.new(overrides))
  end

  defp instance_attrs(overrides) do
    %{
      object_id: 42,
      logical_scene_id: 1,
      parcel_id: 13,
      blueprint_id: 7,
      blueprint_version: 1,
      anchor_world_micro: {0, 0, 0},
      rotation: 0,
      owner_actor_id: 1_001,
      state_flags: 0,
      object_attribute_ref: 0,
      object_tag_set_ref: 0,
      covered_chunks: [{0, 0, 0}],
      part_states: [
        %{part_id: 1, health: 80, state_flags: 0}
      ],
      object_version: 1
    }
    |> Map.merge(Map.new(overrides))
  end
end
