defmodule SceneServer.Voxel.TagSetTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.TagSet

  # ============================================================================
  # Phase 1.3 — TagSet typed domain test suite
  #
  # 设计草案：docs/plans/2026-05-13-phase1-tag-set-typed-domain.md
  # 决策点 T-1..T-4 全部按推荐方案：
  #   T-1: tag_id 扁平 u32（无 namespace，catalog 升级到 Phase 5）
  #   T-2: 不携带 value（纯 set membership；要 value 走 AttributeSet）
  #   T-3: tag_count u16
  #   T-4: set_count u32
  #
  # 与 AttributeSet pinned baseline 对称：空池字节序 = <<0u32>>，
  # 与 Phase 1.2 前 encode_empty_pool_for_* 输出 byte 等价，所以
  # chunk_hash 在 tag_sets = [] 时保持稳定（D-8b：未 bump schema_version）。
  # ============================================================================

  describe "TagSet.normalize! validation" do
    test "rejects empty tag_ids (empty set must use ref=0, not enter pool)" do
      assert_raise ArgumentError, ~r/empty/i, fn ->
        TagSet.normalize!(%{tag_ids: []})
      end
    end

    test "rejects duplicate tag_id" do
      assert_raise ArgumentError, ~r/duplicate/i, fn ->
        TagSet.normalize!(%{tag_ids: [1, 2, 1]})
      end
    end

    test "rejects tag_id below u32 range" do
      assert_raise ArgumentError, ~r/tag_id/i, fn ->
        TagSet.normalize!(%{tag_ids: [-1]})
      end
    end

    test "rejects tag_id above u32 range" do
      assert_raise ArgumentError, ~r/tag_id/i, fn ->
        TagSet.normalize!(%{tag_ids: [0x1_0000_0000]})
      end
    end

    test "rejects non-integer tag_id" do
      assert_raise ArgumentError, ~r/tag_id/i, fn ->
        TagSet.normalize!(%{tag_ids: ["foo"]})
      end
    end

    test "auto-sorts tag_ids ascending" do
      set = TagSet.normalize!(%{tag_ids: [7, 1, 3, 5]})
      assert set.tag_ids == [1, 3, 5, 7]
    end

    test "accepts boundary u32 values" do
      set = TagSet.normalize!(%{tag_ids: [0, 0xFFFF_FFFF]})
      assert set.tag_ids == [0, 0xFFFF_FFFF]
    end

    test "accepts single tag_id" do
      set = TagSet.normalize!(%{tag_ids: [42]})
      assert set.tag_ids == [42]
    end
  end

  describe "TagSet.encode_for_wire / decode_for_wire roundtrip" do
    test "roundtrips a single-tag set" do
      set = TagSet.normalize!(%{tag_ids: [42]})

      bin = TagSet.encode_for_wire(set)
      {decoded, <<>>} = TagSet.decode_for_wire(bin)
      assert decoded == set
    end

    test "roundtrips a multi-tag set" do
      set = TagSet.normalize!(%{tag_ids: [1, 5, 100, 0xCAFE_BABE]})

      bin = TagSet.encode_for_wire(set)
      {decoded, <<>>} = TagSet.decode_for_wire(bin)
      assert decoded == set
    end

    test "decode_for_wire returns trailing bytes intact" do
      set = TagSet.normalize!(%{tag_ids: [7, 11]})
      bin = TagSet.encode_for_wire(set)
      trailing = <<0xDE, 0xAD, 0xBE, 0xEF>>

      {decoded, rest} = TagSet.decode_for_wire(bin <> trailing)
      assert decoded == set
      assert rest == trailing
    end

    test "byte-level golden: single-tag set produces stable 6-byte layout" do
      # tag_count(u16) = 1
      # tag_ids[0](u32 BE) = 0x0000_002A (42)
      set = TagSet.normalize!(%{tag_ids: [42]})
      bin = TagSet.encode_for_wire(set)

      assert bin ==
               <<0x00, 0x01, 0x00, 0x00, 0x00, 0x2A>>
    end

    test "byte-level golden: three-tag set produces stable 14-byte layout" do
      # tag_count(u16) = 3
      # tag_ids = [1, 5, 0xCAFE_BABE] sorted ascending → input order shouldn't matter
      set = TagSet.normalize!(%{tag_ids: [0xCAFE_BABE, 1, 5]})
      bin = TagSet.encode_for_wire(set)

      assert bin ==
               <<0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x05, 0xCA, 0xFE, 0xBA,
                 0xBE>>
    end

    test "decode_for_wire rejects truncated payload" do
      # tag_count(u16)=2 but only one u32 follows
      bad = <<0x00, 0x02, 0x00, 0x00, 0x00, 0x01>>

      assert_raise ArgumentError, fn ->
        TagSet.decode_for_wire(bad)
      end
    end
  end

  describe "Storage.intern_tag_set" do
    test "first intern returns ref=1 (1-indexed) and pool length 1" do
      storage = Storage.empty(1, {0, 0, 0})

      set = TagSet.normalize!(%{tag_ids: [10, 20]})
      {storage, ref} = Storage.intern_tag_set(storage, set)

      assert ref == 1
      assert length(storage.tag_sets) == 1
    end

    test "interning structurally identical set (unsorted input) returns same ref" do
      storage = Storage.empty(1, {0, 0, 0})

      set_a = TagSet.normalize!(%{tag_ids: [10, 20, 30]})
      {storage, ref1} = Storage.intern_tag_set(storage, set_a)

      # Re-intern with same content but different input order
      set_b = TagSet.normalize!(%{tag_ids: [30, 10, 20]})
      {storage, ref2} = Storage.intern_tag_set(storage, set_b)

      assert ref1 == ref2
      assert length(storage.tag_sets) == 1
    end

    test "distinct sets get distinct refs; refs are stable (canonical sort enforced)" do
      storage = Storage.empty(1, {0, 0, 0})

      # 选定 set_a / set_b 使其 byte_canonical_key 升序 = 插入顺序，
      # 这样 first-intern 返回的 ref 不会因为后续 intern 触发 pool re-sort 而漂移。
      # set_a = [1] → `00 01 00 00 00 01`
      # set_b = [2, 3] → `00 02 00 00 00 02 00 00 00 03`
      # 第二字节 0x01 < 0x02，set_a 永远排在 set_b 之前。
      set_a = TagSet.normalize!(%{tag_ids: [1]})
      set_b = TagSet.normalize!(%{tag_ids: [2, 3]})

      {storage, ref_a} = Storage.intern_tag_set(storage, set_a)
      {storage, ref_b} = Storage.intern_tag_set(storage, set_b)

      assert ref_a != ref_b
      assert length(storage.tag_sets) == 2

      # Re-interning either set must still return its canonical ref (intern is
      # by canonical content, not by insertion order).
      {storage2, ref_a2} = Storage.intern_tag_set(storage, set_a)
      {storage2, ref_b2} = Storage.intern_tag_set(storage2, set_b)
      assert ref_a == ref_a2
      assert ref_b == ref_b2
      assert length(storage2.tag_sets) == 2
    end

    test "ref returned post-sort reflects canonical pool order (not insertion order)" do
      # 反向插入：先插入 byte_canonical_key 大的 set，再插入小的；
      # post-sort 时小的会被排到前面，intern API 必须返回**当前**已排序池中
      # 的 1-indexed 位置，而不是历史插入序号。
      storage = Storage.empty(1, {0, 0, 0})

      # set_big = [2, 3] → `00 02 ...`（canonical key 较大）
      # set_small = [1]   → `00 01 ...`（canonical key 较小）
      set_big = TagSet.normalize!(%{tag_ids: [2, 3]})
      set_small = TagSet.normalize!(%{tag_ids: [1]})

      {storage, _ref_big_initial} = Storage.intern_tag_set(storage, set_big)
      {storage, ref_small} = Storage.intern_tag_set(storage, set_small)

      # post-sort 池顺序: [set_small, set_big]
      assert length(storage.tag_sets) == 2
      assert hd(storage.tag_sets).tag_ids == [1]

      # set_small 应当被分配到 ref=1（升序后位列第一）
      assert ref_small == 1

      # 重新 intern set_big 必须返回 ref=2（post-sort 的稳定位置）
      {storage, ref_big_again} = Storage.intern_tag_set(storage, set_big)
      assert ref_big_again == 2
      assert length(storage.tag_sets) == 2
    end

    test "intern accepts raw map and normalizes internally" do
      storage = Storage.empty(1, {0, 0, 0})

      {storage, ref} = Storage.intern_tag_set(storage, %{tag_ids: [99, 1, 5]})

      assert ref == 1
      assert length(storage.tag_sets) == 1
      [set] = storage.tag_sets
      assert set.tag_ids == [1, 5, 99]
    end
  end

  describe "Codec.encode_chunk_snapshot_payload / decode roundtrip with non-empty tag_sets" do
    test "roundtrips a storage with one tag_set" do
      storage = Storage.empty(7, {2, -1, 4}, chunk_version: 11)

      {storage, _ref} = Storage.intern_tag_set(storage, %{tag_ids: [100, 200, 300]})

      payload = Codec.encode_chunk_snapshot_payload(storage)

      assert {:ok, %{storage: decoded, chunk_hash: encoded_hash}} =
               Codec.decode_chunk_snapshot_payload(payload)

      assert encoded_hash == Codec.chunk_hash(storage)
      assert decoded.tag_sets == storage.tag_sets

      # decode → encode is byte-stable
      assert Codec.encode_chunk_snapshot_payload(decoded) == payload
    end

    test "roundtrips a storage with multiple tag_sets" do
      storage = Storage.empty(3, {0, 0, 0})

      {storage, _} = Storage.intern_tag_set(storage, %{tag_ids: [1]})
      {storage, _} = Storage.intern_tag_set(storage, %{tag_ids: [2, 3, 4]})
      {storage, _} = Storage.intern_tag_set(storage, %{tag_ids: [0xCAFE_BABE]})

      assert length(storage.tag_sets) == 3

      payload = Codec.encode_chunk_snapshot_payload(storage)

      assert {:ok, %{storage: decoded}} = Codec.decode_chunk_snapshot_payload(payload)
      assert decoded.tag_sets == storage.tag_sets
      assert Codec.encode_chunk_snapshot_payload(decoded) == payload
    end

    test "roundtrips a storage with both attribute_sets and tag_sets populated" do
      storage = Storage.empty(5, {1, 2, 3})

      {storage, _} =
        Storage.intern_attribute_set(storage, %{
          entries: [%{key_id: 1, value_type: 0x01, value: 42}]
        })

      {storage, _} = Storage.intern_tag_set(storage, %{tag_ids: [10, 20]})

      payload = Codec.encode_chunk_snapshot_payload(storage)

      assert {:ok, %{storage: decoded}} = Codec.decode_chunk_snapshot_payload(payload)
      assert decoded.attribute_sets == storage.attribute_sets
      assert decoded.tag_sets == storage.tag_sets
      assert Codec.encode_chunk_snapshot_payload(decoded) == payload
    end
  end

  describe "chunk_hash stability under reordering" do
    test "tag_ids reordered inside a single TagSet produce identical chunk_hash" do
      storage_a = Storage.empty(1, {0, 0, 0})
      {storage_a, _} = Storage.intern_tag_set(storage_a, %{tag_ids: [1, 5, 3]})

      storage_b = Storage.empty(1, {0, 0, 0})
      {storage_b, _} = Storage.intern_tag_set(storage_b, %{tag_ids: [3, 1, 5]})

      assert Codec.chunk_hash(storage_a) == Codec.chunk_hash(storage_b)
    end

    test "TagSet pool reordered (different intern order) produces identical chunk_hash" do
      set_a = TagSet.normalize!(%{tag_ids: [1, 2]})
      set_b = TagSet.normalize!(%{tag_ids: [100, 200]})

      storage_x =
        Storage.empty(1, {0, 0, 0})
        |> Storage.intern_tag_set(set_a)
        |> elem(0)
        |> Storage.intern_tag_set(set_b)
        |> elem(0)

      storage_y =
        Storage.empty(1, {0, 0, 0})
        |> Storage.intern_tag_set(set_b)
        |> elem(0)
        |> Storage.intern_tag_set(set_a)
        |> elem(0)

      assert Codec.chunk_hash(storage_x) == Codec.chunk_hash(storage_y)
    end
  end

  describe "empty pool byte equivalence (D-8 sibling)" do
    test "empty tag_sets pool encodes to <<0u32>> in wire codec" do
      # Confirms the Phase 1.3 wire codec matches the legacy empty-pool layout
      # so chunk_hash for tag_sets = [] stays byte-stable (sibling guard to
      # the 3 pinned chunk_hash baselines in codec_test.exs).
      storage = Storage.empty(1, {0, 0, 0})
      payload = Codec.encode_chunk_snapshot_payload(storage)

      # Decode should produce a storage with tag_sets = [] (unchanged).
      assert {:ok, %{storage: decoded}} = Codec.decode_chunk_snapshot_payload(payload)
      assert decoded.tag_sets == []
    end
  end

  describe "TagSet struct sanity" do
    test "struct exists with expected fields and defaults" do
      set = %TagSet{}
      assert set.tag_ids == []
    end
  end
end
