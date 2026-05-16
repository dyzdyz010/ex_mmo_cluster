defmodule SceneServer.Voxel.AttributeSetTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.AttributeEntry
  alias SceneServer.Voxel.AttributeSet
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Storage

  # ============================================================================
  # Phase 1.2 — AttributeSet typed domain test suite
  #
  # 设计草案：docs/plans/2026-05-13-phase1-attribute-set-typed-domain.md
  # 决策点 D-1..D-8 全部按推荐方案。
  # ============================================================================

  describe "AttributeSet.normalize! validation" do
    test "rejects empty entries (empty set must use ref=0, not enter pool)" do
      assert_raise ArgumentError, ~r/empty/i, fn ->
        AttributeSet.normalize!(%{entries: []})
      end
    end

    test "rejects duplicate key_id" do
      assert_raise ArgumentError, ~r/duplicate/i, fn ->
        AttributeSet.normalize!(%{
          entries: [
            %{key_id: 1, value_type: 0x01, value: 100},
            %{key_id: 1, value_type: 0x01, value: 200}
          ]
        })
      end
    end

    test "rejects unknown value_type" do
      assert_raise ArgumentError, ~r/value_type/i, fn ->
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0xEE, value: 0}]
        })
      end
    end

    test "rejects i16 value out of range" do
      assert_raise ArgumentError, ~r/value/i, fn ->
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0x01, value: 0x8000}]
        })
      end
    end

    test "rejects u16 value out of range" do
      assert_raise ArgumentError, ~r/value/i, fn ->
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0x02, value: -1}]
        })
      end
    end

    test "rejects enum8 value out of range" do
      assert_raise ArgumentError, ~r/value/i, fn ->
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0x04, value: 256}]
        })
      end
    end

    test "rejects bitset32 value out of range" do
      assert_raise ArgumentError, ~r/value/i, fn ->
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0x05, value: 0x1_0000_0000}]
        })
      end
    end

    test "rejects fixed32 value out of i32 range" do
      assert_raise ArgumentError, ~r/value/i, fn ->
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0x03, value: 0x8000_0000}]
        })
      end
    end

    test "rejects key_id out of u32 range" do
      assert_raise ArgumentError, ~r/key_id/i, fn ->
        AttributeSet.normalize!(%{
          entries: [%{key_id: -1, value_type: 0x01, value: 0}]
        })
      end
    end

    test "auto-sorts entries by key_id ascending" do
      set =
        AttributeSet.normalize!(%{
          entries: [
            %{key_id: 7, value_type: 0x01, value: 1},
            %{key_id: 1, value_type: 0x02, value: 2},
            %{key_id: 3, value_type: 0x04, value: 3}
          ]
        })

      assert Enum.map(set.entries, & &1.key_id) == [1, 3, 7]
    end

    test "accepts all five value_type tags" do
      set =
        AttributeSet.normalize!(%{
          entries: [
            %{key_id: 1, value_type: 0x01, value: -1000},
            %{key_id: 2, value_type: 0x02, value: 60000},
            %{key_id: 3, value_type: 0x03, value: 32768},
            %{key_id: 4, value_type: 0x04, value: 200},
            %{key_id: 5, value_type: 0x05, value: 0xDEAD_BEEF}
          ]
        })

      assert length(set.entries) == 5
    end
  end

  describe "AttributeSet.encode_for_wire / decode_for_wire roundtrip" do
    test "roundtrips a single i16 entry" do
      set =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 42, value_type: 0x01, value: -1234}]
        })

      bin = AttributeSet.encode_for_wire(set)
      {decoded, <<>>} = AttributeSet.decode_for_wire(bin)
      assert decoded == set
    end

    test "roundtrips a single u16 entry" do
      set =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0x02, value: 65000}]
        })

      bin = AttributeSet.encode_for_wire(set)
      {decoded, <<>>} = AttributeSet.decode_for_wire(bin)
      assert decoded == set
    end

    test "roundtrips a single fixed32 entry (Q16.16)" do
      # 1.5 represented as Q16.16 = 1.5 * 65536 = 98304
      set =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 9, value_type: 0x03, value: 98_304}]
        })

      bin = AttributeSet.encode_for_wire(set)
      {decoded, <<>>} = AttributeSet.decode_for_wire(bin)
      assert decoded == set
    end

    test "roundtrips a single enum8 entry" do
      set =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 5, value_type: 0x04, value: 7}]
        })

      bin = AttributeSet.encode_for_wire(set)
      {decoded, <<>>} = AttributeSet.decode_for_wire(bin)
      assert decoded == set
    end

    test "roundtrips a single bitset32 entry" do
      set =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 11, value_type: 0x05, value: 0xCAFE_BABE}]
        })

      bin = AttributeSet.encode_for_wire(set)
      {decoded, <<>>} = AttributeSet.decode_for_wire(bin)
      assert decoded == set
    end

    test "roundtrips multi-entry mixed value_type set" do
      set =
        AttributeSet.normalize!(%{
          entries: [
            %{key_id: 1, value_type: 0x01, value: -100},
            %{key_id: 2, value_type: 0x02, value: 200},
            %{key_id: 3, value_type: 0x03, value: 0x0001_0000},
            %{key_id: 4, value_type: 0x04, value: 17},
            %{key_id: 5, value_type: 0x05, value: 0xFFFF_FFFF}
          ]
        })

      bin = AttributeSet.encode_for_wire(set)
      {decoded, <<>>} = AttributeSet.decode_for_wire(bin)
      assert decoded == set
    end

    test "decode_for_wire rejects unknown value_type" do
      # entry_count=1, key_id=1 (u32), value_type=0xEE, then 1 byte payload
      bad =
        <<1::unsigned-big-integer-size(16), 1::unsigned-big-integer-size(32),
          0xEE::unsigned-integer-size(8), 0x00::unsigned-integer-size(8)>>

      assert_raise ArgumentError, ~r/value_type/i, fn ->
        AttributeSet.decode_for_wire(bad)
      end
    end

    test "byte-level golden: single i16 entry produces stable layout" do
      # entry_count(u16) = 1
      # key_id(u32) = 0x0000_002A (42)
      # value_type(u8) = 0x01
      # value(i16 signed BE) = -1234 → 0xFB2E
      set =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 42, value_type: 0x01, value: -1234}]
        })

      bin = AttributeSet.encode_for_wire(set)

      assert bin ==
               <<0x00, 0x01, 0x00, 0x00, 0x00, 0x2A, 0x01, 0xFB, 0x2E>>
    end

    test "byte-level golden: single enum8 entry produces 8-byte layout" do
      # entry_count(u16)=1, key_id(u32)=1, value_type(u8)=0x04, value(u8)=7
      set =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0x04, value: 7}]
        })

      bin = AttributeSet.encode_for_wire(set)

      assert bin ==
               <<0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x07>>
    end

    test "byte-level golden: single bitset32 entry produces 11-byte layout" do
      # entry_count(u16)=1, key_id(u32)=11, value_type(u8)=0x05, value(u32 BE)=0xCAFEBABE
      set =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 11, value_type: 0x05, value: 0xCAFE_BABE}]
        })

      bin = AttributeSet.encode_for_wire(set)

      assert bin ==
               <<0x00, 0x01, 0x00, 0x00, 0x00, 0x0B, 0x05, 0xCA, 0xFE, 0xBA, 0xBE>>
    end
  end

  describe "Storage.intern_attribute_set" do
    test "first intern returns ref=1 (1-indexed) and pool length 1" do
      storage = Storage.empty(1, {0, 0, 0})

      set =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0x01, value: 10}]
        })

      {storage, ref} = Storage.intern_attribute_set(storage, set)

      assert ref == 1
      assert length(storage.attribute_sets) == 1
    end

    test "interning structurally identical set returns same ref, pool unchanged" do
      storage = Storage.empty(1, {0, 0, 0})

      set =
        AttributeSet.normalize!(%{
          entries: [
            %{key_id: 1, value_type: 0x01, value: 10},
            %{key_id: 2, value_type: 0x02, value: 20}
          ]
        })

      {storage, ref1} = Storage.intern_attribute_set(storage, set)

      # Second intern with same content but unsorted input map
      set_unsorted =
        AttributeSet.normalize!(%{
          entries: [
            %{key_id: 2, value_type: 0x02, value: 20},
            %{key_id: 1, value_type: 0x01, value: 10}
          ]
        })

      {storage, ref2} = Storage.intern_attribute_set(storage, set_unsorted)

      assert ref1 == ref2
      assert length(storage.attribute_sets) == 1
    end

    test "distinct sets get distinct refs; refs are stable (canonical sort enforced)" do
      storage = Storage.empty(1, {0, 0, 0})

      set_a =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 1, value_type: 0x01, value: 10}]
        })

      set_b =
        AttributeSet.normalize!(%{
          entries: [%{key_id: 2, value_type: 0x02, value: 20}]
        })

      {storage, ref_a} = Storage.intern_attribute_set(storage, set_a)
      {storage, ref_b} = Storage.intern_attribute_set(storage, set_b)

      # refs are distinct
      assert ref_a != ref_b
      assert length(storage.attribute_sets) == 2

      # Re-interning either set must still return its canonical ref (intern is
      # by canonical content, not by insertion order).
      {storage2, ref_a2} = Storage.intern_attribute_set(storage, set_a)
      {storage2, ref_b2} = Storage.intern_attribute_set(storage2, set_b)
      assert ref_a == ref_a2
      assert ref_b == ref_b2
      assert length(storage2.attribute_sets) == 2
    end

    test "intern accepts raw map and normalizes internally" do
      storage = Storage.empty(1, {0, 0, 0})

      {storage, ref} =
        Storage.intern_attribute_set(storage, %{
          entries: [%{key_id: 99, value_type: 0x02, value: 1234}]
        })

      assert ref == 1
      assert length(storage.attribute_sets) == 1
    end
  end

  describe "Codec.encode_chunk_snapshot_payload / decode roundtrip with non-empty attribute_sets" do
    test "roundtrips a storage with one attribute_set" do
      storage = Storage.empty(7, {2, -1, 4}, chunk_version: 11)

      {storage, _ref} =
        Storage.intern_attribute_set(storage, %{
          entries: [
            %{key_id: 100, value_type: 0x01, value: -50},
            %{key_id: 200, value_type: 0x03, value: 65_536}
          ]
        })

      payload = Codec.encode_chunk_snapshot_payload(storage)

      assert {:ok, %{storage: decoded, chunk_hash: encoded_hash}} =
               Codec.decode_chunk_snapshot_payload(payload)

      assert encoded_hash == Codec.chunk_hash(storage)
      assert decoded.attribute_sets == storage.attribute_sets

      # decode → encode is byte-stable
      assert Codec.encode_chunk_snapshot_payload(decoded) == payload
    end

    test "roundtrips a storage with multiple attribute_sets" do
      storage = Storage.empty(3, {0, 0, 0})

      {storage, _} =
        Storage.intern_attribute_set(storage, %{
          entries: [%{key_id: 1, value_type: 0x01, value: 100}]
        })

      {storage, _} =
        Storage.intern_attribute_set(storage, %{
          entries: [
            %{key_id: 2, value_type: 0x02, value: 200},
            %{key_id: 3, value_type: 0x04, value: 5}
          ]
        })

      {storage, _} =
        Storage.intern_attribute_set(storage, %{
          entries: [%{key_id: 50, value_type: 0x05, value: 0xCAFE_BABE}]
        })

      assert length(storage.attribute_sets) == 3

      payload = Codec.encode_chunk_snapshot_payload(storage)

      assert {:ok, %{storage: decoded}} = Codec.decode_chunk_snapshot_payload(payload)
      assert decoded.attribute_sets == storage.attribute_sets
      assert Codec.encode_chunk_snapshot_payload(decoded) == payload
    end
  end

  describe "chunk_hash stability under reordering" do
    test "entries reordered inside a single AttributeSet produce identical chunk_hash" do
      storage_a = Storage.empty(1, {0, 0, 0})

      {storage_a, _} =
        Storage.intern_attribute_set(storage_a, %{
          entries: [
            %{key_id: 1, value_type: 0x01, value: 10},
            %{key_id: 5, value_type: 0x02, value: 50},
            %{key_id: 3, value_type: 0x04, value: 7}
          ]
        })

      storage_b = Storage.empty(1, {0, 0, 0})

      {storage_b, _} =
        Storage.intern_attribute_set(storage_b, %{
          entries: [
            %{key_id: 3, value_type: 0x04, value: 7},
            %{key_id: 1, value_type: 0x01, value: 10},
            %{key_id: 5, value_type: 0x02, value: 50}
          ]
        })

      assert Codec.chunk_hash(storage_a) == Codec.chunk_hash(storage_b)
    end

    test "AttributeSet pool reordered (different intern order) produces identical chunk_hash" do
      set_a =
        AttributeSet.normalize!(%{entries: [%{key_id: 1, value_type: 0x01, value: 10}]})

      set_b =
        AttributeSet.normalize!(%{entries: [%{key_id: 2, value_type: 0x02, value: 20}]})

      storage_x =
        Storage.empty(1, {0, 0, 0})
        |> Storage.intern_attribute_set(set_a)
        |> elem(0)
        |> Storage.intern_attribute_set(set_b)
        |> elem(0)

      storage_y =
        Storage.empty(1, {0, 0, 0})
        |> Storage.intern_attribute_set(set_b)
        |> elem(0)
        |> Storage.intern_attribute_set(set_a)
        |> elem(0)

      assert Codec.chunk_hash(storage_x) == Codec.chunk_hash(storage_y)
    end
  end

  describe "AttributeEntry struct sanity" do
    test "struct exists with expected fields and defaults" do
      entry = %AttributeEntry{}
      assert entry.key_id == 0
      assert entry.value_type == 0x01
      assert entry.value == 0
    end
  end
end
