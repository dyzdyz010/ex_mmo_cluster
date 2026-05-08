defmodule SceneServer.Voxel.StorageObjectRefsTest do
  # Phase 4 Step 4-2: Storage.refresh_chunk_object_refs/1 + lookup_owner_at/3
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.ObjectCoverRef
  alias SceneServer.Voxel.Storage

  describe "lookup_owner_at/3" do
    test "returns nil for an empty chunk" do
      storage = Storage.empty(1, {0, 0, 0})

      assert Storage.lookup_owner_at(storage, 0, 0) == nil
      assert Storage.lookup_owner_at(storage, {0, 0, 0}, 0) == nil
      assert Storage.lookup_owner_at(storage, 100, 200) == nil
    end

    test "returns nil for a solid macro (no per-slot owner)" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_solid_block(0, %{material_id: 7})

      assert Storage.lookup_owner_at(storage, 0, 0) == nil
    end

    test "returns {object_id, part_id} for a refined slot owned by a placed object" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 5, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 3
        })

      assert Storage.lookup_owner_at(storage, 0, 5) == {42, 3}
      # other slots in the same macro are still empty
      assert Storage.lookup_owner_at(storage, 0, 0) == nil
      assert Storage.lookup_owner_at(storage, 0, 6) == nil
    end

    test "returns the right layer when multiple owners coexist in one macro" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 0, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.put_micro_block(0, 1, %{
          material_id: 7,
          owner_object_id: 99,
          owner_part_id: 1
        })
        |> Storage.put_micro_block(0, 2, %{material_id: 7})

      assert Storage.lookup_owner_at(storage, 0, 0) == {42, 3}
      assert Storage.lookup_owner_at(storage, 0, 1) == {99, 1}
      # terrain layer (owner=0) still returns {0, 0}; caller filters
      assert Storage.lookup_owner_at(storage, 0, 2) == {0, 0}
    end

    test "returns nil after the slot is cleared" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 5, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.clear_micro_block(0, 5)

      assert Storage.lookup_owner_at(storage, 0, 5) == nil
    end

    test "raises on invalid micro slot index" do
      storage = Storage.empty(1, {0, 0, 0})

      assert_raise ArgumentError, ~r/micro_slot_index must be in 0\.\.511/, fn ->
        Storage.lookup_owner_at(storage, 0, 512)
      end
    end
  end

  describe "refresh_chunk_object_refs/1" do
    test "no-op on an empty chunk" do
      storage = Storage.empty(1, {0, 0, 0})

      refreshed = Storage.refresh_chunk_object_refs(storage)

      assert refreshed.object_refs == []
      # refined cells unchanged (none exist)
      assert refreshed.refined_cells == storage.refined_cells
    end

    test "rebuilds cell-level ObjectCoverRef[] from layer truth" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 0, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.put_micro_block(0, 1, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.put_micro_block(0, 8, %{
          material_id: 7,
          owner_object_id: 99,
          owner_part_id: 1
        })

      # Before refresh,Storage.put_micro_block 路径不会自动维护 cell.object_refs
      # (设计上由 refresh 做整 chunk 重算)。
      cell_before = Storage.refined_cell_at(storage, 0)
      assert cell_before.object_refs == []

      refreshed = Storage.refresh_chunk_object_refs(storage)

      cell = Storage.refined_cell_at(refreshed, 0)
      assert length(cell.object_refs) == 2

      ref_42 = Enum.find(cell.object_refs, &(&1.owner_object_id == 42))
      ref_99 = Enum.find(cell.object_refs, &(&1.owner_object_id == 99))

      assert %ObjectCoverRef{owner_part_id: 3} = ref_42
      assert %ObjectCoverRef{owner_part_id: 1} = ref_99

      # 42 covers slots {0, 1} → mask_words[0] = 0b11 = 3
      assert hd(ref_42.mask_words) == 3
      # 99 covers slot 8 → mask_words[0] = 1 <<< 8 = 256
      assert hd(ref_99.mask_words) == 256

      # sorted by (owner_object_id, owner_part_id)
      assert Enum.map(cell.object_refs, & &1.owner_object_id) == [42, 99]
    end

    test "skips terrain layers (owner_object_id == 0)" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 0, %{material_id: 7})
        |> Storage.put_micro_block(0, 1, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 3
        })

      refreshed = Storage.refresh_chunk_object_refs(storage)

      cell = Storage.refined_cell_at(refreshed, 0)
      assert length(cell.object_refs) == 1
      assert hd(cell.object_refs).owner_object_id == 42

      # chunk-level: only object 42, terrain is excluded
      assert length(refreshed.object_refs) == 1
      assert hd(refreshed.object_refs).object_id == 42
    end

    test "aggregates chunk-level ChunkObjectRef[] across multiple refined cells" do
      # Object 42 spans macros at coords (0,0,0), (1,0,0), (0,1,0)
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block({0, 0, 0}, 0, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.put_micro_block({1, 0, 0}, 0, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.put_micro_block({0, 1, 0}, 0, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 3
        })

      refreshed = Storage.refresh_chunk_object_refs(storage)

      assert length(refreshed.object_refs) == 1
      [ref] = refreshed.object_refs

      assert ref.object_id == 42
      assert ref.object_version == 0
      # half-open AABB: covers x∈[0,2), y∈[0,2), z∈[0,1)
      assert ref.covered_macro_min == {0, 0, 0}
      assert ref.covered_macro_max == {2, 2, 1}
      assert is_integer(ref.cover_hash) and ref.cover_hash > 0
    end

    test "OR-aggregates masks when multiple parts of the same object live in one macro" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 0, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 1
        })
        |> Storage.put_micro_block(0, 1, %{
          material_id: 7,
          owner_object_id: 42,
          owner_part_id: 2
        })

      refreshed = Storage.refresh_chunk_object_refs(storage)

      cell = Storage.refined_cell_at(refreshed, 0)
      # Two distinct part refs at cell level
      assert length(cell.object_refs) == 2

      # But chunk level aggregates by object_id only → single entry
      assert length(refreshed.object_refs) == 1
      [chunk_ref] = refreshed.object_refs
      assert chunk_ref.object_id == 42
    end

    test "produces multiple ChunkObjectRef sorted by object_id" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block({2, 0, 0}, 0, %{
          material_id: 7,
          owner_object_id: 100,
          owner_part_id: 1
        })
        |> Storage.put_micro_block({0, 0, 0}, 0, %{
          material_id: 7,
          owner_object_id: 5,
          owner_part_id: 1
        })
        |> Storage.put_micro_block({1, 0, 0}, 0, %{
          material_id: 7,
          owner_object_id: 50,
          owner_part_id: 1
        })

      refreshed = Storage.refresh_chunk_object_refs(storage)

      assert Enum.map(refreshed.object_refs, & &1.object_id) == [5, 50, 100]
    end

    test "cover_hash is deterministic for identical coverage" do
      storage_a =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block({0, 0, 0}, 0, %{
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.put_micro_block({1, 0, 0}, 5, %{
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.refresh_chunk_object_refs()

      storage_b =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block({1, 0, 0}, 5, %{
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.put_micro_block({0, 0, 0}, 0, %{
          owner_object_id: 42,
          owner_part_id: 3
        })
        |> Storage.refresh_chunk_object_refs()

      [ref_a] = storage_a.object_refs
      [ref_b] = storage_b.object_refs

      assert ref_a.cover_hash == ref_b.cover_hash
    end

    test "cover_hash changes when coverage changes" do
      base =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 0, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.refresh_chunk_object_refs()

      extended =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 0, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.put_micro_block(0, 1, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.refresh_chunk_object_refs()

      assert hd(base.object_refs).cover_hash != hd(extended.object_refs).cover_hash
    end

    test "after break_micro the chunk-level ChunkObjectRef tracks the smaller coverage" do
      # Object covers two macros, then loses one → AABB and cover_hash should shrink
      built =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block({0, 0, 0}, 0, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.put_micro_block({1, 0, 0}, 0, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.refresh_chunk_object_refs()

      assert hd(built.object_refs).covered_macro_max == {2, 1, 1}

      shrunk =
        built
        # Remove the slot from macro (1,0,0) → that macro becomes empty
        |> Storage.clear_micro_block({1, 0, 0}, 0)
        |> Storage.refresh_chunk_object_refs()

      assert length(shrunk.object_refs) == 1
      [ref] = shrunk.object_refs
      assert ref.covered_macro_min == {0, 0, 0}
      assert ref.covered_macro_max == {1, 1, 1}
      assert ref.cover_hash != hd(built.object_refs).cover_hash
    end

    test "after the only object's last slot is cleared, ChunkObjectRef[] becomes empty" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 0, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.refresh_chunk_object_refs()

      assert length(storage.object_refs) == 1

      stripped =
        storage
        |> Storage.clear_micro_block(0, 0)
        |> Storage.refresh_chunk_object_refs()

      assert stripped.object_refs == []
    end
  end
end
