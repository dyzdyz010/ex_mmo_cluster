defmodule SceneServer.Voxel.ObjectRegistryTest do
  # Phase 4 Step 4-3: ObjectRegistry GenServer 基本 API。
  # The shared `voxel_scene_objects` table forces sync execution.
  use ExUnit.Case, async: false

  alias DataService.Voxel.SceneObjectStore
  alias SceneServer.Voxel.ObjectRegistry
  alias SceneServer.Voxel.PartState

  setup do
    SceneObjectStore.reset()

    registry =
      start_supervised!(
        {ObjectRegistry, name: :"object_registry_#{System.unique_integer([:positive])}"}
      )

    %{registry: registry, name: GenServer.whereis(registry) |> safe_name(registry)}
  end

  defp safe_name(_pid, name_or_pid), do: name_or_pid

  describe "lookup_object/3" do
    test "returns nil when object not present", %{registry: r} do
      assert ObjectRegistry.lookup_object(r, 1, 999) == nil
    end

    test "returns the upserted object", %{registry: r} do
      instance = build_instance()
      assert :ok = ObjectRegistry.upsert_object(r, instance)

      assert obj = ObjectRegistry.lookup_object(r, instance.logical_scene_id, instance.object_id)
      assert obj.object_id == instance.object_id
      assert obj.logical_scene_id == instance.logical_scene_id
      assert obj.part_states == instance.part_states
    end
  end

  describe "list_objects_in_chunk/3" do
    test "returns objects covering the chunk, sorted by object_id", %{registry: r} do
      ObjectRegistry.upsert_object(
        r,
        build_instance(object_id: 100, covered_chunks: [{0, 0, 0}, {0, 0, 1}])
      )

      ObjectRegistry.upsert_object(
        r,
        build_instance(object_id: 50, covered_chunks: [{0, 0, 0}])
      )

      ObjectRegistry.upsert_object(
        r,
        build_instance(object_id: 200, covered_chunks: [{1, 0, 0}])
      )

      ids =
        ObjectRegistry.list_objects_in_chunk(r, 1, {0, 0, 0})
        |> Enum.map(& &1.object_id)

      assert ids == [50, 100]

      assert [%{object_id: 200}] = ObjectRegistry.list_objects_in_chunk(r, 1, {1, 0, 0})
      assert [] = ObjectRegistry.list_objects_in_chunk(r, 1, {99, 99, 99})
    end

    test "scopes to logical_scene_id", %{registry: r} do
      ObjectRegistry.upsert_object(
        r,
        build_instance(object_id: 1, logical_scene_id: 1, covered_chunks: [{0, 0, 0}])
      )

      ObjectRegistry.upsert_object(
        r,
        build_instance(object_id: 2, logical_scene_id: 2, covered_chunks: [{0, 0, 0}])
      )

      assert [%{object_id: 1}] = ObjectRegistry.list_objects_in_chunk(r, 1, {0, 0, 0})
      assert [%{object_id: 2}] = ObjectRegistry.list_objects_in_chunk(r, 2, {0, 0, 0})
    end
  end

  describe "upsert_object/2" do
    test "writes the row to Postgres", %{registry: r} do
      instance = build_instance()
      assert :ok = ObjectRegistry.upsert_object(r, instance)

      # Check the persisted row directly via the store
      assert {:ok, persisted} = SceneObjectStore.get_object(instance.object_id)
      assert persisted.object_id == instance.object_id
      assert persisted.covered_chunks == instance.covered_chunks
      assert persisted.part_states == Enum.map(instance.part_states, &PartState.to_map/1)
    end

    test "is upsert: a second call updates the row", %{registry: r} do
      first = build_instance(state_flags: 0, object_version: 1)
      second = build_instance(state_flags: 0x4, object_version: 7)

      assert :ok = ObjectRegistry.upsert_object(r, first)
      assert :ok = ObjectRegistry.upsert_object(r, second)

      assert obj = ObjectRegistry.lookup_object(r, second.logical_scene_id, second.object_id)
      assert obj.state_flags == 0x4
      assert obj.object_version == 7

      assert {:ok, persisted} = SceneObjectStore.get_object(second.object_id)
      assert persisted.state_flags == 0x4
      assert persisted.object_version == 7
    end

    test "normalizes part_states maps to PartState structs in memory", %{registry: r} do
      instance =
        build_instance(
          part_states: [
            %{part_id: 1, health: 80, state_flags: 0},
            %{part_id: 2, health: 40, state_flags: 0}
          ]
        )

      assert :ok = ObjectRegistry.upsert_object(r, instance)

      obj = ObjectRegistry.lookup_object(r, 1, instance.object_id)
      assert Enum.all?(obj.part_states, &match?(%PartState{}, &1))
      assert Enum.map(obj.part_states, & &1.part_id) == [1, 2]
    end
  end

  describe "apply_chunk_cover_change/5" do
    test ":add appends a chunk to covered_chunks (sorted, idempotent)", %{registry: r} do
      instance = build_instance(covered_chunks: [{0, 0, 0}])
      ObjectRegistry.upsert_object(r, instance)

      assert :ok =
               ObjectRegistry.apply_chunk_cover_change(r, 1, instance.object_id, {1, 0, 0}, :add)

      assert obj = ObjectRegistry.lookup_object(r, 1, instance.object_id)
      assert obj.covered_chunks == [{0, 0, 0}, {1, 0, 0}]
      assert obj.object_version == instance.object_version + 1

      # Idempotent: adding existing chunk doesn't bump version
      version_before = obj.object_version

      assert :ok =
               ObjectRegistry.apply_chunk_cover_change(r, 1, instance.object_id, {1, 0, 0}, :add)

      assert ObjectRegistry.lookup_object(r, 1, instance.object_id).object_version ==
               version_before
    end

    test ":remove drops a chunk from covered_chunks", %{registry: r} do
      instance = build_instance(covered_chunks: [{0, 0, 0}, {1, 0, 0}])
      ObjectRegistry.upsert_object(r, instance)

      assert :ok =
               ObjectRegistry.apply_chunk_cover_change(
                 r,
                 1,
                 instance.object_id,
                 {1, 0, 0},
                 :remove
               )

      assert obj = ObjectRegistry.lookup_object(r, 1, instance.object_id)
      assert obj.covered_chunks == [{0, 0, 0}]
      assert obj.object_version == instance.object_version + 1
    end

    test ":remove of last chunk surfaces :covered_chunks_would_be_empty", %{registry: r} do
      instance = build_instance(covered_chunks: [{0, 0, 0}])
      ObjectRegistry.upsert_object(r, instance)

      assert {:error, :covered_chunks_would_be_empty} =
               ObjectRegistry.apply_chunk_cover_change(
                 r,
                 1,
                 instance.object_id,
                 {0, 0, 0},
                 :remove
               )

      # Original row is untouched
      assert obj = ObjectRegistry.lookup_object(r, 1, instance.object_id)
      assert obj.covered_chunks == [{0, 0, 0}]
    end

    test "returns :object_not_found for unknown object_id", %{registry: r} do
      assert {:error, :object_not_found} =
               ObjectRegistry.apply_chunk_cover_change(r, 1, 9_999_999, {0, 0, 0}, :add)
    end
  end

  describe "load_scene/2" do
    test "lazy-loads existing objects from store on first lookup", %{registry: r} do
      # Pre-existing rows directly in store, registry has not loaded them yet.
      SceneObjectStore.put_object(
        build_instance(object_id: 1)
        |> Map.update!(:part_states, &Enum.map(&1, fn ps -> PartState.to_map(ps) end))
      )

      SceneObjectStore.put_object(
        build_instance(object_id: 2)
        |> Map.update!(:part_states, &Enum.map(&1, fn ps -> PartState.to_map(ps) end))
      )

      assert obj = ObjectRegistry.lookup_object(r, 1, 1)
      assert obj.object_id == 1
      assert match?([%PartState{} | _], obj.part_states)

      # Second scene's objects are not loaded by the first lookup
      snap = ObjectRegistry.snapshot(r)
      assert MapSet.member?(snap.scenes_loaded, 1)
      refute MapSet.member?(snap.scenes_loaded, 99)
    end

    test "explicit load_scene marks the scene as loaded", %{registry: r} do
      assert :ok = ObjectRegistry.load_scene(r, 42)

      snap = ObjectRegistry.snapshot(r)
      assert MapSet.member?(snap.scenes_loaded, 42)
    end

    test "is idempotent (second call is a no-op)", %{registry: r} do
      ObjectRegistry.load_scene(r, 7)

      # Insert a row in the store after first load
      ObjectRegistry.upsert_object(r, build_instance(object_id: 100, logical_scene_id: 7))

      # A new sibling registry would see the row, but our registry already has it
      # (because upsert_object also caches). The idempotent guarantee is that
      # load_scene/2 itself does not refetch and clobber in-memory state.
      pre_lookup = ObjectRegistry.lookup_object(r, 7, 100)

      ObjectRegistry.load_scene(r, 7)
      assert ObjectRegistry.lookup_object(r, 7, 100) == pre_lookup
    end
  end

  describe "snapshot/1 and reset/1" do
    test "snapshot exposes scenes_loaded + objects", %{registry: r} do
      ObjectRegistry.upsert_object(r, build_instance())

      snap = ObjectRegistry.snapshot(r)
      assert MapSet.member?(snap.scenes_loaded, 1)
      assert is_map(snap.objects[1])
    end

    test "reset clears in-memory state but does not touch Postgres", %{registry: r} do
      instance = build_instance()
      ObjectRegistry.upsert_object(r, instance)

      assert :ok = ObjectRegistry.reset(r)

      snap = ObjectRegistry.snapshot(r)
      assert snap.scenes_loaded == MapSet.new()
      assert snap.objects == %{}

      # Postgres row still there → next lookup re-loads from store
      assert obj = ObjectRegistry.lookup_object(r, 1, instance.object_id)
      assert obj.object_id == instance.object_id
    end
  end

  defp build_instance(overrides \\ []) do
    overrides = Map.new(overrides)

    base = %{
      object_id: 42,
      logical_scene_id: 1,
      parcel_id: 13,
      blueprint_id: 7,
      blueprint_version: 1,
      anchor_world_micro: {1_000, 0, -500},
      rotation: 0,
      owner_actor_id: 1_001,
      state_flags: 0,
      object_attribute_ref: 0,
      object_tag_set_ref: 0,
      covered_chunks: [{0, 0, 0}, {0, 0, 1}],
      part_states: [
        PartState.new(part_id: 1, health: 80, state_flags: 0),
        PartState.new(part_id: 2, health: 40, state_flags: 0)
      ],
      object_version: 1
    }

    Map.merge(base, overrides)
  end
end
