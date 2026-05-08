defmodule DataService.Voxel.SceneObjectStoreTest do
  # Phase 4: SceneObjectStore is a stateless module backed by Postgres. The
  # shared `voxel_scene_objects` table + `voxel_scene_object_id_seq` sequence
  # force sync execution + per-test reset.
  use ExUnit.Case, async: false

  alias DataService.Voxel.SceneObjectStore

  setup do
    SceneObjectStore.reset()
    :ok
  end

  describe "put_object/2" do
    test "inserts a new object row" do
      attrs = object_attrs()

      assert {:ok, :upserted} = SceneObjectStore.put_object(attrs)

      assert {:ok, obj} = SceneObjectStore.get_object(attrs.object_id)
      assert obj.object_id == attrs.object_id
      assert obj.logical_scene_id == attrs.logical_scene_id
      assert obj.parcel_id == attrs.parcel_id
      assert obj.blueprint_id == attrs.blueprint_id
      assert obj.blueprint_version == attrs.blueprint_version
      assert obj.anchor_world_micro == attrs.anchor_world_micro
      assert obj.rotation == attrs.rotation
      assert obj.owner_actor_id == attrs.owner_actor_id
      assert obj.state_flags == attrs.state_flags
      assert obj.object_attribute_ref == attrs.object_attribute_ref
      assert obj.object_tag_set_ref == attrs.object_tag_set_ref
      assert obj.covered_chunks == attrs.covered_chunks
      assert obj.part_states == attrs.part_states
      assert obj.object_version == attrs.object_version
    end

    test "is upsert: a second put on the same object_id updates the row" do
      assert {:ok, :upserted} = SceneObjectStore.put_object(object_attrs())

      updated =
        object_attrs(
          state_flags: 0x3,
          object_version: 7,
          part_states: [
            %{part_id: 1, health: 0, state_flags: 0x2},
            %{part_id: 2, health: 25, state_flags: 0}
          ]
        )

      assert {:ok, :upserted} = SceneObjectStore.put_object(updated)

      assert {:ok, obj} = SceneObjectStore.get_object(updated.object_id)
      assert obj.state_flags == 0x3
      assert obj.object_version == 7
      assert obj.part_states == updated.part_states
    end

    test "different object_ids accept independent rows" do
      assert {:ok, :upserted} = SceneObjectStore.put_object(object_attrs(object_id: 100))
      assert {:ok, :upserted} = SceneObjectStore.put_object(object_attrs(object_id: 101))

      assert {:ok, _} = SceneObjectStore.get_object(100)
      assert {:ok, _} = SceneObjectStore.get_object(101)
    end

    test "supports negative anchor coordinates (i64 world micro)" do
      attrs = object_attrs(anchor_world_micro: {-1_000_000, -2_000_000, -3_000_000})

      assert {:ok, :upserted} = SceneObjectStore.put_object(attrs)
      assert {:ok, obj} = SceneObjectStore.get_object(attrs.object_id)
      assert obj.anchor_world_micro == {-1_000_000, -2_000_000, -3_000_000}
    end

    test "rejects missing fields" do
      assert {:error, :missing_object_id} =
               SceneObjectStore.put_object(Map.delete(object_attrs(), :object_id))

      assert {:error, :missing_part_states} =
               SceneObjectStore.put_object(Map.delete(object_attrs(), :part_states))

      assert {:error, :missing_covered_chunks} =
               SceneObjectStore.put_object(Map.delete(object_attrs(), :covered_chunks))
    end

    test "rejects negative scalars (non-anchor)" do
      assert {:error, :invalid_object_id} =
               SceneObjectStore.put_object(object_attrs(object_id: -1))

      assert {:error, :invalid_state_flags} =
               SceneObjectStore.put_object(object_attrs(state_flags: -1))
    end

    test "rejects empty covered_chunks" do
      assert {:error, :invalid_covered_chunks} =
               SceneObjectStore.put_object(object_attrs(covered_chunks: []))
    end

    test "rejects empty part_states" do
      assert {:error, :invalid_part_states} =
               SceneObjectStore.put_object(object_attrs(part_states: []))
    end

    test "rejects malformed covered_chunks entries" do
      assert {:error, :invalid_covered_chunks} =
               SceneObjectStore.put_object(object_attrs(covered_chunks: [{"a", "b", "c"}]))
    end

    test "rejects malformed part_states entries" do
      assert {:error, :invalid_part_states} =
               SceneObjectStore.put_object(object_attrs(part_states: [%{part_id: 1, health: 50}]))
    end
  end

  describe "get_object/2" do
    test "returns object_not_found for an empty table" do
      assert {:error, :object_not_found} = SceneObjectStore.get_object(42)
    end

    test "decodes covered_chunks and part_states back to native Elixir terms" do
      covered = [{0, 0, 0}, {0, 0, 1}, {1, 0, 0}]

      parts = [
        %{part_id: 1, health: 80, state_flags: 0},
        %{part_id: 2, health: 40, state_flags: 0x1}
      ]

      attrs = object_attrs(covered_chunks: covered, part_states: parts)

      assert {:ok, :upserted} = SceneObjectStore.put_object(attrs)

      assert {:ok, obj} = SceneObjectStore.get_object(attrs.object_id)
      assert obj.covered_chunks == covered
      assert obj.part_states == parts
    end

    test "rejects negative object_id" do
      assert {:error, :invalid_object_id} = SceneObjectStore.get_object(-1)
    end
  end

  describe "delete_object/2" do
    test "deletes an existing row" do
      attrs = object_attrs()
      assert {:ok, :upserted} = SceneObjectStore.put_object(attrs)

      assert {:ok, :deleted} = SceneObjectStore.delete_object(attrs.object_id)

      assert {:error, :object_not_found} = SceneObjectStore.get_object(attrs.object_id)
    end

    test "returns :not_found when the row is missing" do
      assert {:ok, :not_found} = SceneObjectStore.delete_object(9_999_999)
    end
  end

  describe "list_in_scene/2" do
    test "returns objects scoped to one logical scene, ordered by object_id" do
      assert {:ok, :upserted} =
               SceneObjectStore.put_object(object_attrs(object_id: 10, logical_scene_id: 1))

      assert {:ok, :upserted} =
               SceneObjectStore.put_object(object_attrs(object_id: 11, logical_scene_id: 1))

      assert {:ok, :upserted} =
               SceneObjectStore.put_object(object_attrs(object_id: 20, logical_scene_id: 2))

      list = SceneObjectStore.list_in_scene(1)
      assert Enum.map(list, & &1.object_id) == [10, 11]

      assert SceneObjectStore.list_in_scene(2) |> Enum.map(& &1.object_id) == [20]
      assert SceneObjectStore.list_in_scene(99) == []
    end
  end

  describe "next_object_id/1" do
    test "returns monotonically increasing ids" do
      assert {:ok, id1} = SceneObjectStore.next_object_id()
      assert {:ok, id2} = SceneObjectStore.next_object_id()
      assert {:ok, id3} = SceneObjectStore.next_object_id()

      assert id1 < id2
      assert id2 < id3
    end

    test "starts at 1 after reset" do
      SceneObjectStore.reset()
      assert {:ok, 1} = SceneObjectStore.next_object_id()
    end
  end

  defp object_attrs(overrides \\ []) do
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
        %{part_id: 1, health: 80, state_flags: 0},
        %{part_id: 2, health: 40, state_flags: 0}
      ],
      object_version: 1
    }

    Map.merge(base, overrides)
  end
end
