defmodule SceneServer.Voxel.RefinedCellDataTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.ObjectCoverRef
  alias SceneServer.Voxel.RefinedCellData

  defp zero_mask, do: List.duplicate(0, 8)

  defp single_slot_layer(slot_word_index, bit, attrs) do
    mask =
      zero_mask()
      |> List.replace_at(slot_word_index, Bitwise.bsl(1, bit))

    MicroLayer.new(Keyword.put(attrs, :mask_words, mask))
  end

  defp default_layer_attrs(material_id) do
    [
      material_id: material_id,
      state_flags: 0,
      health: 100,
      attribute_set_ref: 0,
      tag_set_ref: 0,
      owner_object_id: 0,
      owner_part_id: 0
    ]
  end

  test "default constructor builds an empty cell with zero mask and no layers" do
    cell = RefinedCellData.new()

    assert cell.occupancy_words == zero_mask()
    assert cell.layers == []
    assert cell.object_refs == []
    assert cell.boundary_cache == 0
  end

  test "validates invariant 1: occupancy_words length is exactly 8" do
    assert_raise ArgumentError, fn ->
      RefinedCellData.new(occupancy_words: List.duplicate(0, 7))
    end

    assert_raise ArgumentError, fn ->
      RefinedCellData.new(occupancy_words: List.duplicate(0, 9))
    end
  end

  test "validates invariant 2: occupancy = OR(layer masks)" do
    layer = single_slot_layer(0, 3, default_layer_attrs(1))

    # layer covers bit 3 of word 0, but we declare occupancy bit 4
    assert_raise ArgumentError, fn ->
      RefinedCellData.new(
        occupancy_words: List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 4)),
        layers: [layer]
      )
    end

    # correct: occupancy matches layer
    cell =
      RefinedCellData.new(
        occupancy_words: List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3)),
        layers: [layer]
      )

    assert cell.occupancy_words == List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3))
  end

  test "validates invariant 3: layer masks must be pairwise disjoint" do
    a = single_slot_layer(0, 3, default_layer_attrs(1))
    # layer b shares bit 3 with a, but uses different material so signature differs
    b = single_slot_layer(0, 3, default_layer_attrs(2))

    assert_raise ArgumentError, fn ->
      RefinedCellData.new(
        occupancy_words: List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3)),
        layers: [a, b]
      )
    end
  end

  test "validates invariant 4: layers with identical attribute signatures must be merged" do
    a = single_slot_layer(0, 3, default_layer_attrs(1))
    b = single_slot_layer(0, 4, default_layer_attrs(1))

    union_word = Bitwise.bor(Bitwise.bsl(1, 3), Bitwise.bsl(1, 4))

    assert_raise ArgumentError, fn ->
      RefinedCellData.new(
        occupancy_words: List.replace_at(zero_mask(), 0, union_word),
        layers: [a, b]
      )
    end

    # same union, expressed as a single merged layer — OK
    merged =
      MicroLayer.new(
        Keyword.put(
          default_layer_attrs(1),
          :mask_words,
          List.replace_at(zero_mask(), 0, union_word)
        )
      )

    cell =
      RefinedCellData.new(
        occupancy_words: List.replace_at(zero_mask(), 0, union_word),
        layers: [merged]
      )

    assert length(cell.layers) == 1
  end

  test "validates object_refs subset: a ref cannot claim an unoccupied slot" do
    # one occupied slot at word 0 / bit 3
    layer = single_slot_layer(0, 3, default_layer_attrs(1))
    occupancy = List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3))

    bad_ref =
      ObjectCoverRef.new(
        owner_object_id: 42,
        owner_part_id: 0,
        # claims bit 4, which is unoccupied
        mask_words: List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 4))
      )

    assert_raise ArgumentError, fn ->
      RefinedCellData.new(
        occupancy_words: occupancy,
        layers: [layer],
        object_refs: [bad_ref]
      )
    end

    good_ref =
      ObjectCoverRef.new(
        owner_object_id: 42,
        owner_part_id: 0,
        mask_words: occupancy
      )

    cell =
      RefinedCellData.new(
        occupancy_words: occupancy,
        layers: [layer],
        object_refs: [good_ref]
      )

    assert length(cell.object_refs) == 1
  end

  test "round-trips through to_map" do
    layer = single_slot_layer(0, 3, default_layer_attrs(1))
    occupancy = List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3))

    cell =
      RefinedCellData.new(
        occupancy_words: occupancy,
        layers: [layer],
        object_refs: [],
        boundary_cache: 0xCAFEBABE
      )

    m = RefinedCellData.to_map(cell)

    assert m.occupancy_words == occupancy
    assert m.boundary_cache == 0xCAFEBABE
    assert is_list(m.layers)
    assert length(m.layers) == 1
  end

  test "normalize! accepts struct, atom map and string map" do
    layer = single_slot_layer(0, 3, default_layer_attrs(1))
    occupancy = List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3))

    base =
      RefinedCellData.new(
        occupancy_words: occupancy,
        layers: [layer],
        boundary_cache: 0
      )

    assert ^base = RefinedCellData.normalize!(base)

    map_input = %{
      occupancy_words: occupancy,
      layers: [Map.from_struct(layer)],
      object_refs: [],
      boundary_cache: 0
    }

    assert ^base = RefinedCellData.normalize!(map_input)

    string_input = %{
      "occupancy_words" => occupancy,
      "layers" => [Map.from_struct(layer)],
      "object_refs" => [],
      "boundary_cache" => 0
    }

    assert ^base = RefinedCellData.normalize!(string_input)
  end

  test "boundary_cache rejects out-of-range value" do
    assert_raise ArgumentError, fn ->
      RefinedCellData.new(boundary_cache: 0x1_0000_0000_0000_0000)
    end

    assert_raise ArgumentError, fn ->
      RefinedCellData.new(boundary_cache: -1)
    end
  end

  test "exposes mask_word_count/0 = 8" do
    assert RefinedCellData.mask_word_count() == 8
  end

  describe "canonical normalization (Phase 1a hardening)" do
    test "rejects ghost layer (mask_words all-zero)" do
      ghost =
        MicroLayer.new(Keyword.put(default_layer_attrs(1), :mask_words, zero_mask()))

      assert_raise ArgumentError, ~r/ghost layer rejected/, fn ->
        RefinedCellData.new(
          occupancy_words: zero_mask(),
          layers: [ghost]
        )
      end
    end

    test "rejects ObjectCoverRef with all-zero mask" do
      occupied = single_slot_layer(0, 3, default_layer_attrs(1))
      occupancy = List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3))

      assert_raise ArgumentError, ~r/empty ObjectCoverRef rejected/, fn ->
        ref =
          ObjectCoverRef.new(
            owner_object_id: 1,
            owner_part_id: 0,
            mask_words: zero_mask()
          )

        RefinedCellData.new(
          occupancy_words: occupancy,
          layers: [occupied],
          object_refs: [ref]
        )
      end
    end

    test "rejects two ObjectCoverRefs sharing the same (owner_object_id, owner_part_id)" do
      occupied = single_slot_layer(0, 3, default_layer_attrs(1))
      occupancy = List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3))

      ref =
        ObjectCoverRef.new(
          owner_object_id: 42,
          owner_part_id: 0,
          mask_words: occupancy
        )

      assert_raise ArgumentError, ~r/must be merged/, fn ->
        RefinedCellData.new(
          occupancy_words: occupancy,
          layers: [occupied],
          object_refs: [ref, ref]
        )
      end
    end

    test "layers are sorted by attribute_signature regardless of input order" do
      # two distinct layers in two non-overlapping slots
      a = single_slot_layer(0, 3, default_layer_attrs(99))
      b = single_slot_layer(0, 4, default_layer_attrs(7))

      occupancy =
        List.replace_at(zero_mask(), 0, Bitwise.bor(Bitwise.bsl(1, 3), Bitwise.bsl(1, 4)))

      input_ab =
        RefinedCellData.new(occupancy_words: occupancy, layers: [a, b])

      input_ba =
        RefinedCellData.new(occupancy_words: occupancy, layers: [b, a])

      # canonical order: material 7 < material 99 → b first
      assert input_ab == input_ba
      assert hd(input_ab.layers) == b
    end

    test "object_refs are sorted by (owner_object_id, owner_part_id)" do
      occupancy = List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3))
      layer = single_slot_layer(0, 3, default_layer_attrs(1))

      ref_a =
        ObjectCoverRef.new(
          owner_object_id: 100,
          owner_part_id: 2,
          mask_words: occupancy
        )

      ref_b =
        ObjectCoverRef.new(
          owner_object_id: 50,
          owner_part_id: 9,
          mask_words: occupancy
        )

      input_ab =
        RefinedCellData.new(
          occupancy_words: occupancy,
          layers: [layer],
          object_refs: [ref_a, ref_b]
        )

      input_ba =
        RefinedCellData.new(
          occupancy_words: occupancy,
          layers: [layer],
          object_refs: [ref_b, ref_a]
        )

      assert input_ab == input_ba
      assert hd(input_ab.object_refs).owner_object_id == 50
    end

    test "two semantically equal cells produce equal structs regardless of input order" do
      occupancy =
        List.replace_at(zero_mask(), 0, Bitwise.bor(Bitwise.bsl(1, 3), Bitwise.bsl(1, 4)))

      l1 = single_slot_layer(0, 3, default_layer_attrs(1))
      l2 = single_slot_layer(0, 4, default_layer_attrs(2))

      ref1 =
        ObjectCoverRef.new(
          owner_object_id: 5,
          owner_part_id: 0,
          mask_words: List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 3))
        )

      ref2 =
        ObjectCoverRef.new(
          owner_object_id: 9,
          owner_part_id: 1,
          mask_words: List.replace_at(zero_mask(), 0, Bitwise.bsl(1, 4))
        )

      cell_x =
        RefinedCellData.new(
          occupancy_words: occupancy,
          layers: [l1, l2],
          object_refs: [ref1, ref2]
        )

      cell_y =
        RefinedCellData.new(
          occupancy_words: occupancy,
          layers: [l2, l1],
          object_refs: [ref2, ref1]
        )

      assert cell_x == cell_y
    end
  end
end
