defmodule SceneServer.Voxel.CatalogPatchTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.CatalogPatch

  # ============================================================================
  # Phase 1.4 — CatalogPatch envelope test suite
  #
  # 设计草案：docs/plans/2026-05-13-phase1-catalog-patch-minimum.md
  # 用户 2026-05-13 approve P-1..P-3 全部推荐方案；opcode 改 0x71（设计原本
  # 推荐 0x6F，但与生产 VoxelDebugProbe 冲突）。
  #
  # Wire layout (一旦发出即冻结):
  #   schema_kind:u8 (0x01 attribute / 0x02 tag)
  #   base_version:u64 / new_version:u64
  #   op_count:u16
  #   ops[op_count] {
  #     op_kind:u8 (0x01 add / 0x02 remove / 0x03 update)
  #     entry_id:u32
  #     payload_len:u16
  #     payload:bytes(payload_len)
  #   }
  #
  # Phase 1.4 不解释 payload 字节内容（Phase 5 落地 AttributeDefinition /
  # TagDefinition 时再解释）。Forward-compat：未知 op_kind 保留 raw payload
  # 不 raise；未知 schema_kind 是协议演进硬错误。
  # ============================================================================

  describe "CatalogPatch.normalize! validation" do
    test "accepts empty ops (op_count = 0 合法)" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 0,
          ops: []
        })

      assert patch.schema_kind == 0x01
      assert patch.base_version == 0
      assert patch.new_version == 0
      assert patch.ops == []
    end

    test "accepts schema_kind = 0x01 (attribute)" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: []
        })

      assert patch.schema_kind == 0x01
    end

    test "accepts schema_kind = 0x02 (tag)" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x02,
          base_version: 0,
          new_version: 1,
          ops: []
        })

      assert patch.schema_kind == 0x02
    end

    test "rejects unknown schema_kind on normalize! (envelope-level hard error)" do
      assert_raise ArgumentError, ~r/schema_kind/i, fn ->
        CatalogPatch.normalize!(%{
          schema_kind: 0xFE,
          base_version: 0,
          new_version: 1,
          ops: []
        })
      end
    end

    test "rejects base_version > new_version (catalog version must be monotonic)" do
      assert_raise ArgumentError, ~r/version/i, fn ->
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 5,
          new_version: 3,
          ops: []
        })
      end
    end

    test "accepts base_version == new_version (no-op patch)" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 7,
          new_version: 7,
          ops: []
        })

      assert patch.base_version == 7
      assert patch.new_version == 7
    end

    test "rejects base_version below u64 range" do
      assert_raise ArgumentError, ~r/version/i, fn ->
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: -1,
          new_version: 1,
          ops: []
        })
      end
    end

    test "rejects new_version above u64 range" do
      assert_raise ArgumentError, ~r/version/i, fn ->
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 0x1_0000_0000_0000_0000,
          ops: []
        })
      end
    end

    test "accepts ops with valid op_kind (0x01 add / 0x02 remove / 0x03 update)" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: [
            %{op_kind: 0x01, entry_id: 1, payload: <<0xAB, 0xCD>>},
            %{op_kind: 0x02, entry_id: 2, payload: <<>>},
            %{op_kind: 0x03, entry_id: 3, payload: <<0x42>>}
          ]
        })

      assert length(patch.ops) == 3
    end

    test "preserves op order (not auto-sorted; catalog patch order matters)" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: [
            %{op_kind: 0x03, entry_id: 99, payload: <<>>},
            %{op_kind: 0x01, entry_id: 1, payload: <<0xFF>>},
            %{op_kind: 0x02, entry_id: 50, payload: <<>>}
          ]
        })

      # Catalog patch ops are sequentially applied; order matters and must NOT
      # be canonicalized (unlike AttributeSet / TagSet which are canonical pools).
      entry_ids = Enum.map(patch.ops, & &1.entry_id)
      assert entry_ids == [99, 1, 50]
    end

    test "rejects entry_id below u32 range" do
      assert_raise ArgumentError, ~r/entry_id/i, fn ->
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: [%{op_kind: 0x01, entry_id: -1, payload: <<>>}]
        })
      end
    end

    test "rejects entry_id above u32 range" do
      assert_raise ArgumentError, ~r/entry_id/i, fn ->
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: [%{op_kind: 0x01, entry_id: 0x1_0000_0000, payload: <<>>}]
        })
      end
    end

    test "rejects payload_len exceeding u16 range" do
      big_payload = :binary.copy(<<0>>, 0x1_0000)

      assert_raise ArgumentError, ~r/payload/i, fn ->
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: [%{op_kind: 0x01, entry_id: 1, payload: big_payload}]
        })
      end
    end

    test "rejects op_count exceeding u16 range on encode" do
      # Build a struct that bypasses normalize sanity (directly construct);
      # encode_for_wire/1 must still guard at the wire boundary.
      ops = for i <- 1..(0xFFFF + 1), do: %{op_kind: 0x01, entry_id: i, payload: <<>>}

      patch = %CatalogPatch{
        schema_kind: 0x01,
        base_version: 0,
        new_version: 1,
        ops: ops
      }

      assert_raise ArgumentError, ~r/op_count/i, fn ->
        CatalogPatch.encode_for_wire(patch)
      end
    end

    test "rejects unknown op_kind on normalize! (only forward-compat at decode)" do
      assert_raise ArgumentError, ~r/op_kind/i, fn ->
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: [%{op_kind: 0xFE, entry_id: 1, payload: <<>>}]
        })
      end
    end

    test "rejects non-binary payload (e.g. integer)" do
      assert_raise ArgumentError, ~r/payload/i, fn ->
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: [%{op_kind: 0x01, entry_id: 1, payload: 12345}]
        })
      end
    end
  end

  describe "CatalogPatch.encode_for_wire / decode_for_wire roundtrip" do
    test "roundtrips empty ops (0-op envelope)" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 0,
          ops: []
        })

      bin = CatalogPatch.encode_for_wire(patch)
      assert {:ok, decoded} = CatalogPatch.decode_for_wire(bin)
      assert decoded == patch
    end

    test "roundtrips 1 op" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: [%{op_kind: 0x01, entry_id: 42, payload: <<0xCA, 0xFE>>}]
        })

      bin = CatalogPatch.encode_for_wire(patch)
      assert {:ok, decoded} = CatalogPatch.decode_for_wire(bin)
      assert decoded == patch
    end

    test "roundtrips multiple ops (mixed op_kind)" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 10,
          new_version: 15,
          ops: [
            %{op_kind: 0x01, entry_id: 1, payload: <<0xDE, 0xAD>>},
            %{op_kind: 0x03, entry_id: 2, payload: <<0xBE, 0xEF, 0x00, 0x11>>},
            %{op_kind: 0x02, entry_id: 3, payload: <<>>}
          ]
        })

      bin = CatalogPatch.encode_for_wire(patch)
      assert {:ok, decoded} = CatalogPatch.decode_for_wire(bin)
      assert decoded == patch
    end

    test "roundtrips schema_kind = 0x02 (tag)" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x02,
          base_version: 7,
          new_version: 8,
          ops: [%{op_kind: 0x01, entry_id: 100, payload: <<0x55>>}]
        })

      bin = CatalogPatch.encode_for_wire(patch)
      assert {:ok, decoded} = CatalogPatch.decode_for_wire(bin)
      assert decoded == patch
      assert decoded.schema_kind == 0x02
    end

    test "decode! raises on malformed envelope" do
      assert_raise ArgumentError, fn ->
        CatalogPatch.decode_for_wire!(<<0x01, 0x00>>)
      end
    end

    test "decode returns {:error, _} on truncated payload bytes" do
      # schema_kind = 0x01, base = 0, new = 1, op_count = 1
      # op_kind = 0x01, entry_id = 7, payload_len = 4, but only 2 payload bytes follow
      bad =
        <<0x01, 0::64, 1::64, 1::16, 0x01, 7::32, 4::16, 0xAA, 0xBB>>

      assert {:error, _} = CatalogPatch.decode_for_wire(bad)
    end

    test "decode returns {:error, _} on truncated envelope" do
      assert {:error, _} = CatalogPatch.decode_for_wire(<<0x01, 0::64, 1::64>>)
    end

    test "encode is byte-stable across multiple invocations" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 100,
          new_version: 105,
          ops: [
            %{op_kind: 0x01, entry_id: 5, payload: <<0xAA, 0xBB, 0xCC>>},
            %{op_kind: 0x03, entry_id: 5, payload: <<0xDD>>}
          ]
        })

      bin1 = CatalogPatch.encode_for_wire(patch)
      bin2 = CatalogPatch.encode_for_wire(patch)
      bin3 = CatalogPatch.encode_for_wire(patch)
      assert bin1 == bin2
      assert bin2 == bin3
    end
  end

  describe "Forward-compat: unknown op_kind (decoder must NOT raise)" do
    test "decode preserves unknown op_kind = 0xFE with raw payload" do
      # Construct wire bytes directly with unknown op_kind = 0xFE.
      # schema_kind = 0x01, base = 0, new = 1, op_count = 1
      # op_kind = 0xFE, entry_id = 99, payload_len = 3, payload = <<0xAA,0xBB,0xCC>>
      bin =
        <<0x01, 0::64, 1::64, 1::16, 0xFE, 99::32, 3::16, 0xAA, 0xBB, 0xCC>>

      assert {:ok, patch} = CatalogPatch.decode_for_wire(bin)
      assert [op] = patch.ops
      assert op.op_kind == 0xFE
      assert op.entry_id == 99
      assert op.payload == <<0xAA, 0xBB, 0xCC>>
    end

    test "decode preserves unknown op_kind = 0xFF with raw payload" do
      bin =
        <<0x01, 0::64, 1::64, 1::16, 0xFF, 7::32, 1::16, 0x42>>

      assert {:ok, patch} = CatalogPatch.decode_for_wire(bin)
      assert [op] = patch.ops
      assert op.op_kind == 0xFF
      assert op.payload == <<0x42>>
    end

    test "decode -> re-encode of unknown op_kind is byte-identical (forward-compat skip pass-through)" do
      bin =
        <<
          0x01,
          5::64,
          10::64,
          2::16,
          # op 1: known add
          0x01,
          1::32,
          2::16,
          0xDE,
          0xAD,
          # op 2: unknown op_kind 0xFE
          0xFE,
          2::32,
          3::16,
          0xCA,
          0xFE,
          0xBA
        >>

      assert {:ok, patch} = CatalogPatch.decode_for_wire(bin)
      re_encoded = CatalogPatch.encode_for_wire(patch)
      assert re_encoded == bin
    end

    test "decode preserves multiple unknown op_kinds mixed with known ones" do
      bin =
        <<0x01, 0::64, 3::64, 4::16, 0x01, 10::32, 1::16, 0xAA, 0xFE, 20::32, 0::16, 0x03, 30::32,
          2::16, 0xBB, 0xCC, 0xFF, 40::32, 1::16, 0xDD>>

      assert {:ok, patch} = CatalogPatch.decode_for_wire(bin)
      assert length(patch.ops) == 4
      assert Enum.map(patch.ops, & &1.op_kind) == [0x01, 0xFE, 0x03, 0xFF]
      assert Enum.map(patch.ops, & &1.entry_id) == [10, 20, 30, 40]
      # Re-encode must be byte-identical (pass-through preserves wire bytes).
      assert CatalogPatch.encode_for_wire(patch) == bin
    end
  end

  describe "Forward-compat: unknown schema_kind (decoder hard error)" do
    test "decode_for_wire returns {:error, :unknown_schema_kind} on schema_kind = 0xFE" do
      bin = <<0xFE, 0::64, 1::64, 0::16>>
      assert {:error, :unknown_schema_kind} = CatalogPatch.decode_for_wire(bin)
    end

    test "decode_for_wire! raises on unknown schema_kind" do
      bin = <<0xFE, 0::64, 1::64, 0::16>>

      assert_raise ArgumentError, ~r/schema_kind/i, fn ->
        CatalogPatch.decode_for_wire!(bin)
      end
    end

    test "decode rejects reserved schema_kind = 0x00 as hard error" do
      bin = <<0x00, 0::64, 1::64, 0::16>>
      assert {:error, :unknown_schema_kind} = CatalogPatch.decode_for_wire(bin)
    end
  end

  describe "Golden fixture (byte-stable wire)" do
    test "single-op attribute add patch produces stable 28-byte layout" do
      # schema_kind(u8) = 0x01 (attribute)                           # 1 B
      # base_version(u64 BE) = 0                                     # 8 B
      # new_version(u64 BE) = 1                                      # 8 B
      # op_count(u16 BE) = 1                                         # 2 B
      # op:                                                          #
      #   op_kind(u8) = 0x01 (add)                                   # 1 B
      #   entry_id(u32 BE) = 0x0000_002A (42)                        # 4 B
      #   payload_len(u16 BE) = 2                                    # 2 B
      #   payload = <<0xCA, 0xFE>>                                   # 2 B
      #
      # envelope (1+8+8+2) + op_header (1+4+2) + payload (2) = 19 + 7 + 2 = 28 bytes
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 0,
          new_version: 1,
          ops: [%{op_kind: 0x01, entry_id: 42, payload: <<0xCA, 0xFE>>}]
        })

      bin = CatalogPatch.encode_for_wire(patch)

      assert bin ==
               <<0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x02,
                 0xCA, 0xFE>>

      assert byte_size(bin) == 28
    end

    test "empty-ops tag patch produces stable 19-byte envelope" do
      # schema_kind(u8) = 0x02 (tag)
      # base_version(u64 BE) = 7
      # new_version(u64 BE) = 7
      # op_count(u16 BE) = 0
      #
      # total: 1 + 8 + 8 + 2 = 19 bytes (envelope-only)
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x02,
          base_version: 7,
          new_version: 7,
          ops: []
        })

      bin = CatalogPatch.encode_for_wire(patch)

      assert bin ==
               <<0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00,
                 0x00, 0x00, 0x00, 0x07, 0x00, 0x00>>

      assert byte_size(bin) == 19
    end

    test "three-op mixed patch produces deterministic byte layout" do
      patch =
        CatalogPatch.normalize!(%{
          schema_kind: 0x01,
          base_version: 100,
          new_version: 103,
          ops: [
            %{op_kind: 0x01, entry_id: 1, payload: <<0xAA>>},
            %{op_kind: 0x02, entry_id: 2, payload: <<>>},
            %{op_kind: 0x03, entry_id: 3, payload: <<0xBB, 0xCC>>}
          ]
        })

      bin = CatalogPatch.encode_for_wire(patch)

      # envelope = 19 bytes
      # op1 header = 7 + 1 payload = 8 bytes
      # op2 header = 7 + 0 payload = 7 bytes
      # op3 header = 7 + 2 payload = 9 bytes
      # total = 19 + 8 + 7 + 9 = 43 bytes
      assert byte_size(bin) == 43

      assert bin ==
               <<
                 0x01,
                 0x00,
                 0x00,
                 0x00,
                 0x00,
                 0x00,
                 0x00,
                 0x00,
                 0x64,
                 0x00,
                 0x00,
                 0x00,
                 0x00,
                 0x00,
                 0x00,
                 0x00,
                 0x67,
                 0x00,
                 0x03,
                 # op 1
                 0x01,
                 0x00,
                 0x00,
                 0x00,
                 0x01,
                 0x00,
                 0x01,
                 0xAA,
                 # op 2
                 0x02,
                 0x00,
                 0x00,
                 0x00,
                 0x02,
                 0x00,
                 0x00,
                 # op 3
                 0x03,
                 0x00,
                 0x00,
                 0x00,
                 0x03,
                 0x00,
                 0x02,
                 0xBB,
                 0xCC
               >>
    end
  end

  describe "CatalogPatch struct sanity" do
    test "struct exists with expected default fields" do
      patch = %CatalogPatch{}
      assert patch.schema_kind == 0x01
      assert patch.base_version == 0
      assert patch.new_version == 0
      assert patch.ops == []
    end

    test "exposes schema_attribute / schema_tag / op_add / op_remove / op_update helpers" do
      assert CatalogPatch.schema_attribute() == 0x01
      assert CatalogPatch.schema_tag() == 0x02
      assert CatalogPatch.op_add() == 0x01
      assert CatalogPatch.op_remove() == 0x02
      assert CatalogPatch.op_update() == 0x03
    end
  end
end
