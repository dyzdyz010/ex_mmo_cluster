defmodule SceneServer.Voxel.StorageMicroMutationTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.Storage

  defp default_layer_attrs(material_id \\ 1) do
    %{
      material_id: material_id,
      state_flags: 0,
      health: 100,
      attribute_set_ref: 0,
      tag_set_ref: 0,
      owner_object_id: 0,
      owner_part_id: 0
    }
  end

  defp empty_storage do
    Storage.empty(1, {0, 0, 0})
  end

  describe "put_micro_blocks — Phase A1-1b batch API" do
    test "batch on empty macro produces same shape as N x put_micro_block(同攻击 attrs)" do
      pairs = [
        {5, default_layer_attrs(17)},
        {9, default_layer_attrs(17)},
        {64, default_layer_attrs(17)}
      ]

      batch_storage = Storage.put_micro_blocks(empty_storage(), 0, pairs)

      sequential_storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs(17))
        |> Storage.put_micro_block(0, 9, default_layer_attrs(17))
        |> Storage.put_micro_block(0, 64, default_layer_attrs(17))

      assert Storage.macro_header_at(batch_storage, 0) ==
               Storage.macro_header_at(sequential_storage, 0)

      assert Storage.refined_cell_at(batch_storage, 0) ==
               Storage.refined_cell_at(sequential_storage, 0)
    end

    test "batch with mixed material_ids splits into multiple layers correctly" do
      pairs = [
        {5, default_layer_attrs(17)},
        {9, default_layer_attrs(42)},
        {10, default_layer_attrs(17)}
      ]

      storage = Storage.put_micro_blocks(empty_storage(), 0, pairs)
      cell = Storage.refined_cell_at(storage, 0)

      # 17 / 42 → 2 layers
      assert length(cell.layers) == 2
      [layer_17, layer_42] = Enum.sort_by(cell.layers, & &1.material_id)

      assert layer_17.material_id == 17
      # slot 5 + 10 in layer 17 → bits 5, 10 in word 0
      assert layer_17.mask_words == [
               Bitwise.bor(Bitwise.bsl(1, 5), Bitwise.bsl(1, 10)),
               0,
               0,
               0,
               0,
               0,
               0,
               0
             ]

      assert layer_42.material_id == 42
      # slot 9 in layer 42 → bit 9 in word 0
      assert layer_42.mask_words == [Bitwise.bsl(1, 9), 0, 0, 0, 0, 0, 0, 0]

      # Combined occupancy
      expected_occ =
        Bitwise.bor(Bitwise.bsl(1, 5), Bitwise.bor(Bitwise.bsl(1, 9), Bitwise.bsl(1, 10)))

      assert cell.occupancy_words == [expected_occ, 0, 0, 0, 0, 0, 0, 0]
    end

    test "batch on refined macro merges with existing layers (same signature)" do
      base = empty_storage() |> Storage.put_micro_block(0, 100, default_layer_attrs(99))
      pairs = [{5, default_layer_attrs(99)}, {9, default_layer_attrs(99)}]

      storage = Storage.put_micro_blocks(base, 0, pairs)
      cell = Storage.refined_cell_at(storage, 0)

      # Same material_id → merged into the existing layer
      assert length(cell.layers) == 1
      [layer] = cell.layers
      assert layer.material_id == 99
      # bits 5, 9, 100 set
      bit_5_9 = Bitwise.bor(Bitwise.bsl(1, 5), Bitwise.bsl(1, 9))
      bit_100_word = div(100, 64)
      bit_100_offset = rem(100, 64)
      expected = List.duplicate(0, 8)
      expected = List.replace_at(expected, 0, bit_5_9)
      expected = List.replace_at(expected, bit_100_word, Bitwise.bsl(1, bit_100_offset))
      assert layer.mask_words == expected
    end

    test "batch raises on already-occupied slot" do
      base = empty_storage() |> Storage.put_micro_block(0, 5, default_layer_attrs(1))

      assert_raise ArgumentError, ~r/micro_slot_already_occupied/, fn ->
        Storage.put_micro_blocks(base, 0, [{5, default_layer_attrs(2)}])
      end
    end

    test "batch raises on solid macro" do
      storage = empty_storage() |> Storage.put_solid_block(0, NormalBlockData.new(7))

      assert_raise ArgumentError, ~r/cannot_micro_edit_solid_macro/, fn ->
        Storage.put_micro_blocks(storage, 0, [{5, default_layer_attrs(2)}])
      end
    end

    test "empty pairs list is a no-op" do
      base = empty_storage() |> Storage.put_micro_block(0, 5, default_layer_attrs(1))
      result = Storage.put_micro_blocks(base, 0, [])
      assert Storage.macro_header_at(result, 0) == Storage.macro_header_at(base, 0)
      assert Storage.refined_cell_at(result, 0) == Storage.refined_cell_at(base, 0)
    end

    test "batch matches sequential for sphere-sized payload (280 slots)" do
      # Phase A1-1b 实际场景:sphere prefab 一次 280 个 micro slots。Storage
      # 行为必须跟 280 次 sequential put_micro_block 完全等价(像素级)。
      pairs = for slot <- 0..279, do: {slot, default_layer_attrs(4)}

      batch_storage = Storage.put_micro_blocks(empty_storage(), 0, pairs)

      sequential_storage =
        Enum.reduce(pairs, empty_storage(), fn {slot, attrs}, acc ->
          Storage.put_micro_block(acc, 0, slot, attrs)
        end)

      assert Storage.macro_header_at(batch_storage, 0) ==
               Storage.macro_header_at(sequential_storage, 0)

      assert Storage.refined_cell_at(batch_storage, 0) ==
               Storage.refined_cell_at(sequential_storage, 0)
    end
  end

  describe "put_micro_block — empty → refined transition" do
    test "promotes an empty macro cell to refined and creates one layer with one bit" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs(17))

      header = Storage.macro_header_at(storage, 0)
      assert header.mode == MacroCellHeader.cell_mode_refined()
      assert header.payload_index == 0

      cell = Storage.refined_cell_at(storage, 0)
      assert %RefinedCellData{} = cell
      assert length(cell.layers) == 1

      [layer] = cell.layers
      assert layer.material_id == 17
      assert layer.health == 100

      # Slot 5 is in word 0, bit 5
      expected_word = Bitwise.bsl(1, 5)
      assert layer.mask_words == [expected_word, 0, 0, 0, 0, 0, 0, 0]
      assert cell.occupancy_words == [expected_word, 0, 0, 0, 0, 0, 0, 0]
    end

    test "every micro slot index in 0..511 maps to the correct (word, bit) position" do
      for slot <- [0, 63, 64, 127, 128, 255, 256, 511] do
        storage = Storage.put_micro_block(empty_storage(), 0, slot, default_layer_attrs())
        cell = Storage.refined_cell_at(storage, 0)
        word_index = div(slot, 64)
        bit_index = rem(slot, 64)
        expected = List.replace_at(List.duplicate(0, 8), word_index, Bitwise.bsl(1, bit_index))
        assert cell.occupancy_words == expected, "slot #{slot} placed wrong"
      end
    end

    test "passes cell_version / cell_hash / flags through to the macro header" do
      storage =
        Storage.put_micro_block(empty_storage(), 100, 0, default_layer_attrs(),
          cell_version: 7,
          cell_hash: 0xCAFE_BABE,
          flags: 0x0010
        )

      header = Storage.macro_header_at(storage, 100)
      assert header.cell_version == 7
      assert header.cell_hash == 0xCAFE_BABE
      assert header.flags == 0x0010
    end
  end

  describe "put_micro_block — refined → refined transition with layer merging" do
    test "merges two slots with identical attribute signature into one layer" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs(17))
        |> Storage.put_micro_block(0, 9, default_layer_attrs(17))

      cell = Storage.refined_cell_at(storage, 0)
      assert length(cell.layers) == 1

      [layer] = cell.layers
      expected = Bitwise.bor(Bitwise.bsl(1, 5), Bitwise.bsl(1, 9))
      assert layer.mask_words == [expected, 0, 0, 0, 0, 0, 0, 0]
      assert cell.occupancy_words == [expected, 0, 0, 0, 0, 0, 0, 0]
    end

    test "creates a second layer when attribute signatures differ" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs(17))
        |> Storage.put_micro_block(0, 9, default_layer_attrs(42))

      cell = Storage.refined_cell_at(storage, 0)
      assert length(cell.layers) == 2

      union = Bitwise.bor(Bitwise.bsl(1, 5), Bitwise.bsl(1, 9))
      assert cell.occupancy_words == [union, 0, 0, 0, 0, 0, 0, 0]
    end

    test "preserves canonical layer order regardless of insertion order" do
      storage_ab =
        empty_storage()
        |> Storage.put_micro_block(0, 0, default_layer_attrs(99))
        |> Storage.put_micro_block(0, 1, default_layer_attrs(7))

      storage_ba =
        empty_storage()
        |> Storage.put_micro_block(0, 1, default_layer_attrs(7))
        |> Storage.put_micro_block(0, 0, default_layer_attrs(99))

      assert Storage.refined_cell_at(storage_ab, 0).layers ==
               Storage.refined_cell_at(storage_ba, 0).layers
    end

    test "rejects a put on a slot that is already occupied" do
      storage = Storage.put_micro_block(empty_storage(), 0, 5, default_layer_attrs())

      assert_raise ArgumentError, ~r/micro_slot_already_occupied/, fn ->
        Storage.put_micro_block(storage, 0, 5, default_layer_attrs(99))
      end
    end
  end

  describe "put_micro_block — solid macro rejection" do
    test "raises :cannot_micro_edit_solid_macro when target macro is :solid" do
      storage =
        empty_storage()
        |> Storage.put_solid_block(0, NormalBlockData.new(11, health: 50))

      assert_raise ArgumentError, ~r/cannot_micro_edit_solid_macro/, fn ->
        Storage.put_micro_block(storage, 0, 0, default_layer_attrs())
      end
    end
  end

  describe "put_micro_block — input validation" do
    test "rejects micro_slot_index out of 0..511" do
      assert_raise ArgumentError, ~r/micro_slot_index/, fn ->
        Storage.put_micro_block(empty_storage(), 0, -1, default_layer_attrs())
      end

      assert_raise ArgumentError, ~r/micro_slot_index/, fn ->
        Storage.put_micro_block(empty_storage(), 0, 512, default_layer_attrs())
      end
    end
  end

  describe "clear_micro_block — refined → refined" do
    test "removes a slot from the layer and updates occupancy" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs(17))
        |> Storage.put_micro_block(0, 9, default_layer_attrs(17))
        |> Storage.clear_micro_block(0, 5)

      cell = Storage.refined_cell_at(storage, 0)
      assert length(cell.layers) == 1

      [layer] = cell.layers
      assert layer.mask_words == [Bitwise.bsl(1, 9), 0, 0, 0, 0, 0, 0, 0]
      assert cell.occupancy_words == [Bitwise.bsl(1, 9), 0, 0, 0, 0, 0, 0, 0]
    end

    test "drops a layer that becomes all-zero (no ghost layers)" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs(17))
        |> Storage.put_micro_block(0, 9, default_layer_attrs(42))
        |> Storage.clear_micro_block(0, 5)

      cell = Storage.refined_cell_at(storage, 0)
      assert length(cell.layers) == 1
      [layer] = cell.layers
      assert layer.material_id == 42
    end
  end

  describe "clear_micro_block — refined → empty downgrade" do
    test "downgrades the macro header back to :empty when all slots are cleared" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs())
        |> Storage.clear_micro_block(0, 5)

      header = Storage.macro_header_at(storage, 0)
      assert header.mode == MacroCellHeader.cell_mode_empty()
      assert Storage.refined_cell_at(storage, 0) == nil
    end

    test "preserves cell_version / cell_hash when downgrading" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs(),
          cell_version: 3,
          cell_hash: 0xAAAA_BBBB
        )
        |> Storage.clear_micro_block(0, 5, cell_version: 4, cell_hash: 0xCCCC_DDDD)

      header = Storage.macro_header_at(storage, 0)
      assert header.cell_version == 4
      assert header.cell_hash == 0xCCCC_DDDD
    end
  end

  describe "clear_micro_block — idempotency and edge cases" do
    test "is a no-op on an empty macro" do
      original = empty_storage()
      cleared = Storage.clear_micro_block(original, 0, 5)
      assert cleared == original
    end

    test "is a no-op on a slot that wasn't occupied" do
      storage = Storage.put_micro_block(empty_storage(), 0, 5, default_layer_attrs())
      cleared = Storage.clear_micro_block(storage, 0, 7)
      assert Storage.refined_cell_at(cleared, 0) == Storage.refined_cell_at(storage, 0)
    end

    test "raises :cannot_micro_edit_solid_macro on solid macro" do
      storage =
        empty_storage()
        |> Storage.put_solid_block(0, NormalBlockData.new(11, health: 50))

      assert_raise ArgumentError, ~r/cannot_micro_edit_solid_macro/, fn ->
        Storage.clear_micro_block(storage, 0, 5)
      end
    end

    test "rejects micro_slot_index out of 0..511" do
      storage = Storage.put_micro_block(empty_storage(), 0, 5, default_layer_attrs())

      for bad <- [-1, 512, 1024] do
        assert_raise ArgumentError, ~r/micro_slot_index/, fn ->
          Storage.clear_micro_block(storage, 0, bad)
        end
      end
    end
  end

  describe "round-trip and invariants under sequences of edits" do
    test "10-slot put/clear sequence keeps all §5.4 invariants" do
      slots = [0, 7, 63, 64, 127, 128, 200, 300, 400, 511]

      after_puts =
        Enum.reduce(slots, empty_storage(), fn slot, acc ->
          Storage.put_micro_block(acc, 0, slot, default_layer_attrs(rem(slot, 5)))
        end)

      cell = Storage.refined_cell_at(after_puts, 0)

      # §5.4 invariant 2: occupancy = OR(layer masks)
      union =
        Enum.reduce(cell.layers, List.duplicate(0, 8), fn layer, acc ->
          Enum.zip_with(acc, layer.mask_words, &Bitwise.bor/2)
        end)

      assert union == cell.occupancy_words

      # Clear half of them and expect the remaining half to still be valid.
      after_clears =
        slots
        |> Enum.take(5)
        |> Enum.reduce(after_puts, fn slot, acc ->
          Storage.clear_micro_block(acc, 0, slot)
        end)

      cell2 = Storage.refined_cell_at(after_clears, 0)

      # No ghost layers
      refute Enum.any?(cell2.layers, fn layer ->
               Enum.all?(layer.mask_words, &(&1 == 0))
             end)

      # No layer overlaps
      seen =
        Enum.reduce(cell2.layers, List.duplicate(0, 8), fn layer, acc ->
          overlap = Enum.zip_with(acc, layer.mask_words, &Bitwise.band/2)
          assert Enum.all?(overlap, &(&1 == 0)), "layers must be pairwise disjoint"
          Enum.zip_with(acc, layer.mask_words, &Bitwise.bor/2)
        end)

      assert seen == cell2.occupancy_words
    end

    test "fully clearing all slots returns the macro to :empty" do
      slots = [0, 1, 2, 3, 4, 5]

      after_puts =
        Enum.reduce(slots, empty_storage(), fn slot, acc ->
          Storage.put_micro_block(acc, 0, slot, default_layer_attrs())
        end)

      after_clears =
        Enum.reduce(slots, after_puts, fn slot, acc ->
          Storage.clear_micro_block(acc, 0, slot)
        end)

      header = Storage.macro_header_at(after_clears, 0)
      assert header.mode == MacroCellHeader.cell_mode_empty()
    end
  end

  describe "multi-cell pool layout" do
    test "two refined cells in different macros each get their own pool slot" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs(1))
        |> Storage.put_micro_block(100, 5, default_layer_attrs(2))

      h0 = Storage.macro_header_at(storage, 0)
      h100 = Storage.macro_header_at(storage, 100)

      assert h0.mode == MacroCellHeader.cell_mode_refined()
      assert h100.mode == MacroCellHeader.cell_mode_refined()
      assert h0.payload_index == 0
      assert h100.payload_index == 1

      assert length(storage.refined_cells) == 2
      assert Storage.refined_cell_at(storage, 0).layers |> hd() |> Map.get(:material_id) == 1
      assert Storage.refined_cell_at(storage, 100).layers |> hd() |> Map.get(:material_id) == 2
    end

    test "downgrading one cell leaves an orphan in the pool but keeps the other intact" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(0, 5, default_layer_attrs(1))
        |> Storage.put_micro_block(100, 5, default_layer_attrs(2))
        |> Storage.clear_micro_block(0, 5)

      assert Storage.macro_header_at(storage, 0).mode == MacroCellHeader.cell_mode_empty()
      assert Storage.macro_header_at(storage, 100).mode == MacroCellHeader.cell_mode_refined()
      # Pool still has 2 entries — the orphan at index 0 is empty but valid.
      assert length(storage.refined_cells) == 2

      orphan = Enum.at(storage.refined_cells, 0)
      assert orphan.layers == []
      assert orphan.object_refs == []
      assert Enum.all?(orphan.occupancy_words, &(&1 == 0))

      # The intact cell is still reachable.
      assert Storage.refined_cell_at(storage, 100).layers |> hd() |> Map.get(:material_id) == 2
    end
  end

  describe "micro_solid?/3 — prefab adjacency primitive" do
    test "empty macro reports every slot as not solid" do
      storage = empty_storage()

      refute Storage.micro_solid?(storage, 0, 0)
      refute Storage.micro_solid?(storage, 0, 255)
      refute Storage.micro_solid?(storage, 0, 511)
    end

    test "solid macro reports every slot as solid" do
      storage = Storage.put_solid_block(empty_storage(), 7, %{material_id: 2, health: 100})

      assert Storage.micro_solid?(storage, 7, 0)
      assert Storage.micro_solid?(storage, 7, 320)
      assert Storage.micro_solid?(storage, 7, 511)
      # A different (still empty) macro stays not-solid.
      refute Storage.micro_solid?(storage, 8, 0)
    end

    test "refined macro reports only occupied slots as solid" do
      storage =
        empty_storage()
        |> Storage.put_micro_block(3, 17, default_layer_attrs(1))
        |> Storage.put_micro_block(3, 200, default_layer_attrs(1))

      assert Storage.micro_solid?(storage, 3, 17)
      assert Storage.micro_solid?(storage, 3, 200)
      refute Storage.micro_solid?(storage, 3, 18)
      refute Storage.micro_solid?(storage, 3, 0)
    end

    test "accepts a local macro coord just like a macro index" do
      storage =
        Storage.put_solid_block(empty_storage(), {1, 2, 3}, %{material_id: 2, health: 100})

      macro_index = SceneServer.Voxel.Types.macro_index!({1, 2, 3})

      assert Storage.micro_solid?(storage, {1, 2, 3}, 5)
      assert Storage.micro_solid?(storage, macro_index, 5)
    end
  end
end
