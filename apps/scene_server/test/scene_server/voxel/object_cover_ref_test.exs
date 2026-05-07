defmodule SceneServer.Voxel.ObjectCoverRefTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.ObjectCoverRef

  test "accepts a valid ref and round-trips through to_map" do
    object_id = 0x1234_5678_9ABC_DEF0

    ref =
      ObjectCoverRef.new(
        owner_object_id: object_id,
        owner_part_id: 7,
        mask_words: [0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80]
      )

    assert ref.owner_object_id == object_id
    assert ref.owner_part_id == 7
    assert ref.mask_words == [0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80]

    assert ObjectCoverRef.to_map(ref) == %{
             owner_object_id: object_id,
             owner_part_id: 7,
             mask_words: [0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80]
           }
  end

  test "normalize! accepts struct, atom-keyed map, and string-keyed map alike" do
    base =
      ObjectCoverRef.new(
        owner_object_id: 1,
        owner_part_id: 0,
        mask_words: List.duplicate(0, 8)
      )

    assert ^base = ObjectCoverRef.normalize!(base)

    assert ^base =
             ObjectCoverRef.normalize!(%{
               owner_object_id: 1,
               owner_part_id: 0,
               mask_words: List.duplicate(0, 8)
             })

    assert ^base =
             ObjectCoverRef.normalize!(%{
               "owner_object_id" => 1,
               "owner_part_id" => 0,
               "mask_words" => List.duplicate(0, 8)
             })
  end

  test "rejects owner_object_id <= 0 (must be a positive id)" do
    assert_raise ArgumentError, fn ->
      ObjectCoverRef.new(owner_object_id: 0, mask_words: List.duplicate(0, 8))
    end

    assert_raise ArgumentError, fn ->
      ObjectCoverRef.new(owner_object_id: -1, mask_words: List.duplicate(0, 8))
    end
  end

  test "rejects owner_object_id beyond i63 (DataService bigint constraint)" do
    assert_raise ArgumentError, fn ->
      ObjectCoverRef.new(
        owner_object_id: 0x7FFF_FFFF_FFFF_FFFF + 1,
        mask_words: List.duplicate(0, 8)
      )
    end
  end

  test "rejects mask_words with the wrong length" do
    assert_raise ArgumentError, fn ->
      ObjectCoverRef.new(owner_object_id: 1, mask_words: List.duplicate(0, 7))
    end

    assert_raise ArgumentError, fn ->
      ObjectCoverRef.new(owner_object_id: 1, mask_words: List.duplicate(0, 9))
    end
  end

  test "rejects mask_word out of u64 range" do
    bad = List.duplicate(0, 7) ++ [0x1_0000_0000_0000_0000]

    assert_raise ArgumentError, fn ->
      ObjectCoverRef.new(owner_object_id: 1, mask_words: bad)
    end
  end

  test "rejects owner_part_id beyond u32" do
    assert_raise ArgumentError, fn ->
      ObjectCoverRef.new(
        owner_object_id: 1,
        owner_part_id: 0x1_0000_0000,
        mask_words: List.duplicate(0, 8)
      )
    end
  end

  test "exposes mask_word_count/0 = 8 for downstream code" do
    assert ObjectCoverRef.mask_word_count() == 8
  end
end
