defmodule SceneServer.Voxel.TagCatalogSnapshotTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.TagCatalogSnapshot
  alias SceneServer.Voxel.TagDefinition

  # ============================================================================
  # Phase 5.B — TagCatalogSnapshot + TagDefinition test suite
  #
  # 与 Phase 5.A AttributeCatalogSnapshot 对称但更简单：TagDefinition 只有
  # id + name（无 value_type / default / min / max / merge_rule / dynamic）。
  #
  # 决策依据：
  #   - Phase 1.3 T-1: tag_id 扁平 u32，无 namespace
  #   - Phase 1.3 T-2: 不携带 value（要 value 走 AttributeSet）
  #   - Phase 5.A A-1: 全局 scope
  #   - Phase 5.A A-2: UTF-8 + u16 length prefix
  #   - definition_count: u32
  #   - catalog_version: u64 monotonic
  #
  # opcode 0x6D payload-only wire layout (一旦发出即冻结)：
  #
  #   catalog_version: u64
  #   definition_count: u32
  #   definitions[definition_count] {
  #     id:        u32
  #     name_len:  u16
  #     name:      bytes(name_len)        # UTF-8, 非空
  #   }
  #
  # 每条 TagDefinition wire 字节数 = 4 + 2 + name_byte_len。
  # 例如 name="flammable"(9B) → 15 B/definition。
  # ============================================================================

  describe "TagDefinition.normalize! field validation" do
    test "accepts a minimal valid definition" do
      defn = TagDefinition.normalize!(%{id: 1, name: "flammable"})
      assert defn.id == 1
      assert defn.name == "flammable"
    end

    test "rejects empty name" do
      assert_raise ArgumentError, ~r/name/i, fn ->
        TagDefinition.normalize!(%{id: 1, name: ""})
      end
    end

    test "rejects non-string name" do
      assert_raise ArgumentError, ~r/name/i, fn ->
        TagDefinition.normalize!(%{id: 1, name: 123})
      end
    end

    test "rejects invalid UTF-8 in name" do
      # 0xFF, 0xFE 是 UTF-8 非法字节序列
      assert_raise ArgumentError, ~r/name/i, fn ->
        TagDefinition.normalize!(%{id: 1, name: <<0xFF, 0xFE>>})
      end
    end

    test "accepts id at u32 boundaries (0 and 0xFFFF_FFFF)" do
      for id <- [0, 0xFFFF_FFFF] do
        defn = TagDefinition.normalize!(%{id: id, name: "x"})
        assert defn.id == id
      end
    end

    test "rejects id above u32 range" do
      assert_raise ArgumentError, ~r/id/i, fn ->
        TagDefinition.normalize!(%{id: 0x1_0000_0000, name: "x"})
      end
    end

    test "rejects negative id" do
      assert_raise ArgumentError, ~r/id/i, fn ->
        TagDefinition.normalize!(%{id: -1, name: "x"})
      end
    end

    test "rejects non-integer id" do
      assert_raise ArgumentError, ~r/id/i, fn ->
        TagDefinition.normalize!(%{id: "1", name: "x"})
      end
    end
  end

  describe "TagCatalogSnapshot.normalize! validation" do
    test "accepts empty catalog (version=0, definition_count=0)" do
      snap = TagCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      assert snap.catalog_version == 0
      assert snap.definitions == []
    end

    test "sorts definitions by id ascending" do
      snap =
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [
            %{id: 99, name: "t99"},
            %{id: 1, name: "t1"},
            %{id: 42, name: "t42"}
          ]
        })

      assert Enum.map(snap.definitions, & &1.id) == [1, 42, 99]
    end

    test "rejects duplicate definition ids" do
      assert_raise ArgumentError, ~r/duplicate/i, fn ->
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [
            %{id: 1, name: "a"},
            %{id: 2, name: "b"},
            %{id: 1, name: "c"}
          ]
        })
      end
    end

    test "accepts catalog_version = 0 (initial / empty catalog)" do
      snap = TagCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      assert snap.catalog_version == 0
    end

    test "accepts large catalog_version near u64 upper bound" do
      v = 0xFFFF_FFFF_FFFF_FFFF
      snap = TagCatalogSnapshot.normalize!(%{catalog_version: v, definitions: []})
      assert snap.catalog_version == v
    end

    test "rejects negative catalog_version" do
      assert_raise ArgumentError, ~r/catalog_version/i, fn ->
        TagCatalogSnapshot.normalize!(%{catalog_version: -1, definitions: []})
      end
    end

    test "rejects catalog_version above u64 range" do
      assert_raise ArgumentError, ~r/catalog_version/i, fn ->
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 0x1_0000_0000_0000_0000,
          definitions: []
        })
      end
    end

    test "rejects non-list definitions" do
      assert_raise ArgumentError, ~r/definitions/i, fn ->
        TagCatalogSnapshot.normalize!(%{catalog_version: 1, definitions: %{}})
      end
    end
  end

  describe "encode_for_wire / decode_for_wire roundtrip" do
    test "roundtrips empty catalog (version=0, count=0)" do
      snap = TagCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      bin = TagCatalogSnapshot.encode_for_wire(snap)

      # envelope only: u64 catalog_version + u32 definition_count = 12 bytes
      assert byte_size(bin) == 12

      assert TagCatalogSnapshot.decode_for_wire(bin) == snap
    end

    test "roundtrips single definition" do
      snap =
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [%{id: 1, name: "flammable"}]
        })

      bin = TagCatalogSnapshot.encode_for_wire(snap)
      assert TagCatalogSnapshot.decode_for_wire(bin) == snap
    end

    test "roundtrips multiple definitions (sketch of Phase 5.C 第一批 tag)" do
      snap =
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 5,
          definitions: [
            %{id: 1, name: "flammable"},
            %{id: 2, name: "conductive"},
            %{id: 3, name: "fragile"},
            %{id: 4, name: "magical"}
          ]
        })

      bin = TagCatalogSnapshot.encode_for_wire(snap)
      decoded = TagCatalogSnapshot.decode_for_wire(bin)
      assert decoded == snap
      assert length(decoded.definitions) == 4
    end

    test "encode is byte-stable across multiple invocations" do
      snap =
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 42,
          definitions: [%{id: 2, name: "b"}, %{id: 1, name: "a"}]
        })

      bin1 = TagCatalogSnapshot.encode_for_wire(snap)
      bin2 = TagCatalogSnapshot.encode_for_wire(snap)
      bin3 = TagCatalogSnapshot.encode_for_wire(snap)
      assert bin1 == bin2
      assert bin2 == bin3
    end

    test "encode normalizes input even if struct was hand-built unsorted" do
      # 手工构造一个 unsorted struct（绕过 normalize!）
      snap = %TagCatalogSnapshot{
        catalog_version: 1,
        definitions: [
          %TagDefinition{id: 99, name: "z"},
          %TagDefinition{id: 1, name: "a"}
        ]
      }

      bin = TagCatalogSnapshot.encode_for_wire(snap)
      decoded = TagCatalogSnapshot.decode_for_wire(bin)
      assert Enum.map(decoded.definitions, & &1.id) == [1, 99]
    end

    test "decode raises on truncated catalog header" do
      assert_raise ArgumentError, fn ->
        TagCatalogSnapshot.decode_for_wire(<<0, 0, 0>>)
      end
    end

    test "decode raises on trailing bytes after final definition" do
      snap = TagCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      bin = TagCatalogSnapshot.encode_for_wire(snap) <> <<0xAB>>

      assert_raise ArgumentError, ~r/trailing/i, fn ->
        TagCatalogSnapshot.decode_for_wire(bin)
      end
    end

    test "decode raises on truncated name payload" do
      # catalog_version=0, def_count=1, id=1, name_len=5, name truncated to 2B
      bad = <<0::64, 1::32, 1::32, 5::16, "ab">>

      assert_raise ArgumentError, fn ->
        TagCatalogSnapshot.decode_for_wire(bad)
      end
    end

    test "decode raises on duplicate ids in wire stream" do
      # catalog_version=0, def_count=2, id=1, name_len=1, name="a",
      # id=1, name_len=1, name="b" → duplicate
      bad =
        <<0::64, 2::32, 1::32, 1::16, "a", 1::32, 1::16, "b">>

      assert_raise ArgumentError, ~r/duplicate/i, fn ->
        TagCatalogSnapshot.decode_for_wire(bad)
      end
    end

    test "decode raises on empty name (out-of-band wire tampering)" do
      # catalog_version=0, def_count=1, id=1, name_len=0
      bad = <<0::64, 1::32, 1::32, 0::16>>

      assert_raise ArgumentError, ~r/name/i, fn ->
        TagCatalogSnapshot.decode_for_wire(bad)
      end
    end
  end

  describe "Golden fixture (byte-stable wire)" do
    test "single definition produces deterministic byte layout" do
      # Layout breakdown (all big-endian):
      #
      # catalog_version u64 = 7                                  # 8 B
      # definition_count u32 = 1                                 # 4 B
      # id u32 = 1                                               # 4 B
      # name_len u16 = 9                                         # 2 B
      # name "flammable"                                         # 9 B
      #
      # total: 8 + 4 + 4 + 2 + 9 = 27 bytes (envelope 12 + def 15)
      snap =
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 7,
          definitions: [%{id: 1, name: "flammable"}]
        })

      bin = TagCatalogSnapshot.encode_for_wire(snap)

      expected =
        <<
          # catalog_version u64 = 7
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x07,
          # definition_count u32 = 1
          0x00,
          0x00,
          0x00,
          0x01,
          # id u32 = 1
          0x00,
          0x00,
          0x00,
          0x01,
          # name_len u16 = 9
          0x00,
          0x09,
          # name "flammable" (ASCII)
          0x66,
          0x6C,
          0x61,
          0x6D,
          0x6D,
          0x61,
          0x62,
          0x6C,
          0x65
        >>

      assert byte_size(bin) == 27
      assert bin == expected
    end

    test "empty catalog snapshot produces 12-byte envelope" do
      snap = TagCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      bin = TagCatalogSnapshot.encode_for_wire(snap)

      assert bin == <<0::64, 0::32>>
      assert byte_size(bin) == 12
    end

    test "two definitions produce deterministic byte layout" do
      # catalog_version u64 = 2                                  # 8 B
      # definition_count u32 = 2                                 # 4 B
      # def[0]: id=1, name_len=1, name="a"                       # 7 B
      # def[1]: id=2, name_len=1, name="b"                       # 7 B
      # total: 12 + 7 + 7 = 26 bytes
      snap =
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 2,
          definitions: [
            %{id: 1, name: "a"},
            %{id: 2, name: "b"}
          ]
        })

      bin = TagCatalogSnapshot.encode_for_wire(snap)

      expected =
        <<2::64, 2::32, 1::32, 1::16, "a", 2::32, 1::16, "b">>

      assert byte_size(bin) == 26
      assert bin == expected
    end
  end

  describe "UTF-8 handling" do
    test "roundtrips Chinese characters in name (e.g. 易燃)" do
      snap =
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [%{id: 1, name: "易燃"}]
        })

      bin = TagCatalogSnapshot.encode_for_wire(snap)
      decoded = TagCatalogSnapshot.decode_for_wire(bin)
      assert decoded == snap
      assert hd(decoded.definitions).name == "易燃"
      # "易燃" 在 UTF-8 下是 6 bytes (2 中文字符 × 3 bytes)
      assert byte_size("易燃") == 6
    end

    test "roundtrips emoji in name (forward-compat)" do
      snap =
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [%{id: 1, name: "🔥"}]
        })

      bin = TagCatalogSnapshot.encode_for_wire(snap)
      decoded = TagCatalogSnapshot.decode_for_wire(bin)
      assert decoded == snap
      assert hd(decoded.definitions).name == "🔥"
    end

    test "roundtrips mixed ASCII + Chinese + emoji catalog" do
      snap =
        TagCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [
            %{id: 1, name: "flammable"},
            %{id: 2, name: "易燃"},
            %{id: 3, name: "🔥"}
          ]
        })

      bin = TagCatalogSnapshot.encode_for_wire(snap)
      decoded = TagCatalogSnapshot.decode_for_wire(bin)
      assert decoded == snap
      assert Enum.map(decoded.definitions, & &1.name) == ["flammable", "易燃", "🔥"]
    end
  end

  describe "TagDefinition struct sanity" do
    test "struct exists with expected default fields" do
      defn = %TagDefinition{}
      assert defn.id == 0
      assert defn.name == ""
    end
  end

  describe "TagCatalogSnapshot struct sanity" do
    test "struct exists with expected default fields" do
      snap = %TagCatalogSnapshot{}
      assert snap.catalog_version == 0
      assert snap.definitions == []
    end
  end
end
