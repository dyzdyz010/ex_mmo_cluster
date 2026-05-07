defmodule SceneServer.Voxel.MicroLayerTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.MicroLayer

  defp default_layer_attrs do
    [
      mask_words: [0x1, 0, 0, 0, 0, 0, 0, 0],
      material_id: 1,
      state_flags: 0,
      health: 100,
      attribute_set_ref: 0,
      tag_set_ref: 0,
      owner_object_id: 0,
      owner_part_id: 0
    ]
  end

  test "accepts a valid layer and round-trips through to_map" do
    layer = MicroLayer.new(default_layer_attrs())

    assert layer.material_id == 1
    assert layer.health == 100
    assert layer.mask_words == [0x1, 0, 0, 0, 0, 0, 0, 0]

    assert MicroLayer.to_map(layer) == %{
             mask_words: [0x1, 0, 0, 0, 0, 0, 0, 0],
             material_id: 1,
             state_flags: 0,
             health: 100,
             attribute_set_ref: 0,
             tag_set_ref: 0,
             owner_object_id: 0,
             owner_part_id: 0
           }
  end

  test "normalize! accepts struct, atom-keyed map, and string-keyed map" do
    base = MicroLayer.new(default_layer_attrs())
    assert ^base = MicroLayer.normalize!(base)
    assert ^base = MicroLayer.normalize!(Map.from_struct(base))

    string_keys =
      base
      |> Map.from_struct()
      |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Map.new()

    assert ^base = MicroLayer.normalize!(string_keys)
  end

  test "owner_object_id may be 0 (terrain) but layer-level u64 ceiling enforced" do
    layer = MicroLayer.new(Keyword.put(default_layer_attrs(), :owner_object_id, 0))
    assert layer.owner_object_id == 0

    assert_raise ArgumentError, fn ->
      MicroLayer.new(
        Keyword.put(default_layer_attrs(), :owner_object_id, 0x7FFF_FFFF_FFFF_FFFF + 1)
      )
    end
  end

  test "rejects mask_words wrong length and out-of-range words" do
    assert_raise ArgumentError, fn ->
      MicroLayer.new(Keyword.put(default_layer_attrs(), :mask_words, List.duplicate(0, 7)))
    end

    assert_raise ArgumentError, fn ->
      bad = List.duplicate(0, 7) ++ [0x1_0000_0000_0000_0000]
      MicroLayer.new(Keyword.put(default_layer_attrs(), :mask_words, bad))
    end
  end

  test "rejects out-of-range integer fields" do
    Enum.each(
      [
        {:material_id, 0x1_0000},
        {:state_flags, 0x1_0000_0000},
        {:health, 0x1_0000},
        {:attribute_set_ref, 0x1_0000_0000},
        {:tag_set_ref, 0x1_0000_0000},
        {:owner_part_id, 0x1_0000_0000}
      ],
      fn {field, bad_value} ->
        assert_raise ArgumentError, fn ->
          MicroLayer.new(Keyword.put(default_layer_attrs(), field, bad_value))
        end
      end
    )
  end

  test "attribute_signature ignores mask_words and groups by everything else" do
    a = MicroLayer.new(default_layer_attrs())

    b =
      MicroLayer.new(Keyword.put(default_layer_attrs(), :mask_words, [0, 0x2, 0, 0, 0, 0, 0, 0]))

    c = MicroLayer.new(Keyword.put(default_layer_attrs(), :material_id, 2))

    assert MicroLayer.attribute_signature(a) == MicroLayer.attribute_signature(b)
    refute MicroLayer.attribute_signature(a) == MicroLayer.attribute_signature(c)
  end

  test "exposes mask_word_count/0 = 8" do
    assert MicroLayer.mask_word_count() == 8
  end
end
