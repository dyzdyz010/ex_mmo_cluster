defmodule SceneServer.Voxel.AttributeCatalogSnapshotTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.AttributeCatalogSnapshot
  alias SceneServer.Voxel.AttributeDefinition

  # ============================================================================
  # Phase 5.A — AttributeCatalogSnapshot + AttributeDefinition test suite
  #
  # 设计草案：docs/plans/2026-05-13-phase5a-attribute-catalog-snapshot.md
  # 用户 2026-05-13 approve A-1..A-6 全部推荐方案。
  #
  # opcode 0x6E payload-only wire layout (一旦发出即冻结)：
  #
  #   catalog_version: u64
  #   definition_count: u32
  #   definitions[definition_count] {
  #     id:           u32
  #     name_len:     u16
  #     name:         bytes(name_len)        # UTF-8, 非空
  #     unit_len:     u16
  #     unit:         bytes(unit_len)        # UTF-8, 允许为空
  #     value_type:   u8                     # 0x01..0x05
  #     default_value bytes(N)               # N = value_type 字节长度
  #     min_value     bytes(N)
  #     max_value     bytes(N)
  #     merge_rule    u8                     # 0x01..0x05
  #     dynamic       u8                     # 0 / 1
  #   }
  #
  # value_type 字节长度: 0x01 i16 → 2, 0x02 u16 → 2, 0x03 fixed32 → 4,
  #                     0x04 enum8 → 1, 0x05 bitset32 → 4.
  # merge_rule 枚举: 0x01 override / 0x02 add_delta / 0x03 max / 0x04 min /
  #                  0x05 material_default.
  # ============================================================================

  describe "AttributeDefinition.normalize! field validation" do
    test "accepts a minimal valid i16 definition" do
      defn =
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "temperature",
          unit: "C",
          value_type: 0x01,
          default_value: 20,
          min_value: -100,
          max_value: 1000,
          merge_rule: 0x01,
          dynamic: true
        })

      assert defn.id == 1
      assert defn.name == "temperature"
      assert defn.unit == "C"
      assert defn.value_type == 0x01
      assert defn.merge_rule == 0x01
      assert defn.dynamic == true
    end

    test "rejects empty name" do
      assert_raise ArgumentError, ~r/name/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "",
          unit: "C",
          value_type: 0x01,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects non-string name" do
      assert_raise ArgumentError, ~r/name/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: 123,
          unit: "C",
          value_type: 0x01,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "accepts empty unit (unitless attribute, e.g. boolean / enum)" do
      defn =
        AttributeDefinition.normalize!(%{
          id: 7,
          name: "is_burning",
          unit: "",
          value_type: 0x04,
          default_value: 0,
          min_value: 0,
          max_value: 1,
          merge_rule: 0x01,
          dynamic: true
        })

      assert defn.unit == ""
    end

    test "rejects unknown value_type 0x06" do
      assert_raise ArgumentError, ~r/value_type/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x06,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects unknown value_type 0xFF" do
      assert_raise ArgumentError, ~r/value_type/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0xFF,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects default_value out of value_type range (i16)" do
      assert_raise ArgumentError, ~r/default_value/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x01,
          default_value: 0x10_0000,
          min_value: -100,
          max_value: 1000,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects min_value out of value_type range (u16 negative)" do
      assert_raise ArgumentError, ~r/min_value/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x02,
          default_value: 0,
          min_value: -1,
          max_value: 100,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects max_value above u16 range" do
      assert_raise ArgumentError, ~r/max_value/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x02,
          default_value: 0,
          min_value: 0,
          max_value: 0x1_0000,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects min_value > max_value" do
      assert_raise ArgumentError, ~r/min_value/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x01,
          default_value: 5,
          min_value: 100,
          max_value: 0,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects default_value below min_value (in-range but ordering wrong)" do
      assert_raise ArgumentError, ~r/default_value/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x01,
          default_value: -50,
          min_value: 0,
          max_value: 100,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects default_value above max_value (in-range but ordering wrong)" do
      assert_raise ArgumentError, ~r/default_value/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x01,
          default_value: 200,
          min_value: 0,
          max_value: 100,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects unknown merge_rule 0x06" do
      assert_raise ArgumentError, ~r/merge_rule/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x01,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0x06,
          dynamic: false
        })
      end
    end

    test "rejects unknown merge_rule 0xFF" do
      assert_raise ArgumentError, ~r/merge_rule/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x01,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0xFF,
          dynamic: false
        })
      end
    end

    test "rejects dynamic = 2 (not in {0, 1})" do
      assert_raise ArgumentError, ~r/dynamic/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: "",
          value_type: 0x01,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0x01,
          dynamic: 2
        })
      end
    end

    test "accepts dynamic as 0 / 1 / true / false" do
      for d <- [0, 1, true, false] do
        defn =
          AttributeDefinition.normalize!(%{
            id: 1,
            name: "x",
            unit: "",
            value_type: 0x01,
            default_value: 0,
            min_value: 0,
            max_value: 0,
            merge_rule: 0x01,
            dynamic: d
          })

        assert defn.dynamic == (d == 1 or d == true)
      end
    end

    test "accepts all 5 merge_rule values" do
      for rule <- [0x01, 0x02, 0x03, 0x04, 0x05] do
        defn =
          AttributeDefinition.normalize!(%{
            id: 1,
            name: "x",
            unit: "",
            value_type: 0x01,
            default_value: 0,
            min_value: 0,
            max_value: 0,
            merge_rule: rule,
            dynamic: false
          })

        assert defn.merge_rule == rule
      end
    end

    test "accepts id at u32 boundaries (0 and 0xFFFF_FFFF)" do
      for id <- [0, 0xFFFF_FFFF] do
        defn =
          AttributeDefinition.normalize!(%{
            id: id,
            name: "x",
            unit: "",
            value_type: 0x01,
            default_value: 0,
            min_value: 0,
            max_value: 0,
            merge_rule: 0x01,
            dynamic: false
          })

        assert defn.id == id
      end
    end

    test "rejects id above u32 range" do
      assert_raise ArgumentError, ~r/id/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 0x1_0000_0000,
          name: "x",
          unit: "",
          value_type: 0x01,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end
  end

  describe "AttributeCatalogSnapshot.normalize! validation" do
    test "accepts empty catalog (version=0, definition_count=0)" do
      snap = AttributeCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      assert snap.catalog_version == 0
      assert snap.definitions == []
    end

    test "sorts definitions by id ascending" do
      snap =
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [
            sample_defn(99),
            sample_defn(1),
            sample_defn(42)
          ]
        })

      assert Enum.map(snap.definitions, & &1.id) == [1, 42, 99]
    end

    test "rejects duplicate definition ids" do
      assert_raise ArgumentError, ~r/duplicate/i, fn ->
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [
            sample_defn(1),
            sample_defn(2),
            sample_defn(1)
          ]
        })
      end
    end

    test "accepts catalog_version = 0 (initial / empty catalog)" do
      snap = AttributeCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      assert snap.catalog_version == 0
    end

    test "accepts large catalog_version near u64 upper bound" do
      v = 0xFFFF_FFFF_FFFF_FFFF
      snap = AttributeCatalogSnapshot.normalize!(%{catalog_version: v, definitions: []})
      assert snap.catalog_version == v
    end

    test "rejects negative catalog_version" do
      assert_raise ArgumentError, ~r/catalog_version/i, fn ->
        AttributeCatalogSnapshot.normalize!(%{catalog_version: -1, definitions: []})
      end
    end

    test "rejects catalog_version above u64 range" do
      assert_raise ArgumentError, ~r/catalog_version/i, fn ->
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 0x1_0000_0000_0000_0000,
          definitions: []
        })
      end
    end

    test "rejects non-list definitions" do
      assert_raise ArgumentError, ~r/definitions/i, fn ->
        AttributeCatalogSnapshot.normalize!(%{catalog_version: 1, definitions: %{}})
      end
    end
  end

  describe "encode_for_wire / decode_for_wire roundtrip" do
    test "roundtrips empty catalog (version=0, count=0)" do
      snap = AttributeCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      bin = AttributeCatalogSnapshot.encode_for_wire(snap)

      # envelope only: u64 catalog_version + u32 definition_count = 12 bytes
      assert byte_size(bin) == 12

      assert AttributeCatalogSnapshot.decode_for_wire(bin) == snap
    end

    test "roundtrips single i16 definition" do
      snap =
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [
            %{
              id: 1,
              name: "temperature",
              unit: "C",
              value_type: 0x01,
              default_value: 20,
              min_value: -100,
              max_value: 1000,
              merge_rule: 0x01,
              dynamic: true
            }
          ]
        })

      bin = AttributeCatalogSnapshot.encode_for_wire(snap)
      assert AttributeCatalogSnapshot.decode_for_wire(bin) == snap
    end

    test "roundtrips all 5 value_types in one catalog (mirrors Phase 5.C 第一批 sketch)" do
      snap =
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 5,
          definitions: [
            %{
              id: 1,
              name: "temperature",
              unit: "C",
              value_type: 0x01,
              default_value: 20,
              min_value: -100,
              max_value: 1000,
              merge_rule: 0x02,
              dynamic: true
            },
            %{
              id: 2,
              name: "humidity",
              unit: "%",
              value_type: 0x02,
              default_value: 50,
              min_value: 0,
              max_value: 100,
              merge_rule: 0x02,
              dynamic: true
            },
            %{
              id: 3,
              name: "density",
              unit: "kg/m3",
              value_type: 0x03,
              # Q16.16: 1.5 -> 0x0001_8000 = 98304
              default_value: 0x0001_8000,
              min_value: 0,
              max_value: 0x7FFF_FFFF,
              merge_rule: 0x05,
              dynamic: false
            },
            %{
              id: 4,
              name: "state",
              unit: "",
              value_type: 0x04,
              default_value: 0,
              min_value: 0,
              max_value: 7,
              merge_rule: 0x01,
              dynamic: true
            },
            %{
              id: 5,
              name: "flags",
              unit: "",
              value_type: 0x05,
              default_value: 0,
              min_value: 0,
              max_value: 0xFFFF_FFFF,
              merge_rule: 0x01,
              dynamic: true
            }
          ]
        })

      bin = AttributeCatalogSnapshot.encode_for_wire(snap)
      decoded = AttributeCatalogSnapshot.decode_for_wire(bin)
      assert decoded == snap
      assert length(decoded.definitions) == 5
    end

    test "encode is byte-stable across multiple invocations" do
      snap =
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 42,
          definitions: [sample_defn(2), sample_defn(1)]
        })

      bin1 = AttributeCatalogSnapshot.encode_for_wire(snap)
      bin2 = AttributeCatalogSnapshot.encode_for_wire(snap)
      bin3 = AttributeCatalogSnapshot.encode_for_wire(snap)
      assert bin1 == bin2
      assert bin2 == bin3
    end

    test "decode raises on truncated catalog header" do
      assert_raise ArgumentError, fn ->
        AttributeCatalogSnapshot.decode_for_wire(<<0, 0, 0>>)
      end
    end

    test "decode raises on trailing bytes after final definition" do
      snap = AttributeCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      bin = AttributeCatalogSnapshot.encode_for_wire(snap) <> <<0xAB>>

      assert_raise ArgumentError, ~r/trailing/i, fn ->
        AttributeCatalogSnapshot.decode_for_wire(bin)
      end
    end

    test "decode raises on unknown value_type tag mid-stream" do
      # catalog_version=0, def_count=1, id=1, name_len=1, name="x", unit_len=0,
      # value_type=0xFE (unknown), ...
      bad =
        <<0::64, 1::32, 1::32, 0x00, 0x01, "x", 0x00, 0x00, 0xFE>>

      assert_raise ArgumentError, ~r/value_type/i, fn ->
        AttributeCatalogSnapshot.decode_for_wire(bad)
      end
    end
  end

  describe "Golden fixture (byte-stable wire)" do
    test "single i16 definition produces 34-byte deterministic layout" do
      # Layout breakdown (all big-endian):
      #
      # catalog_version u64 = 7                                  # 8 B
      # definition_count u32 = 1                                 # 4 B
      # id u32 = 1                                               # 4 B
      # name_len u16 = 4                                         # 2 B
      # name "temp"                                              # 4 B
      # unit_len u16 = 1                                         # 2 B
      # unit "K"                                                 # 1 B
      # value_type u8 = 0x01 (i16)                               # 1 B
      # default_value i16 = 20  -> 0x00,0x14                     # 2 B
      # min_value     i16 = -100 -> 0xFF,0x9C                    # 2 B
      # max_value     i16 = 1000 -> 0x03,0xE8                    # 2 B
      # merge_rule u8 = 0x01 (override)                          # 1 B
      # dynamic    u8 = 0x01                                     # 1 B
      #
      # total: 8 + 4 + 4 + 2 + 4 + 2 + 1 + 1 + 2 + 2 + 2 + 1 + 1 = 34 bytes
      snap =
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 7,
          definitions: [
            %{
              id: 1,
              name: "temp",
              unit: "K",
              value_type: 0x01,
              default_value: 20,
              min_value: -100,
              max_value: 1000,
              merge_rule: 0x01,
              dynamic: true
            }
          ]
        })

      bin = AttributeCatalogSnapshot.encode_for_wire(snap)

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
          # name_len u16 = 4
          0x00,
          0x04,
          # name "temp"
          0x74,
          0x65,
          0x6D,
          0x70,
          # unit_len u16 = 1
          0x00,
          0x01,
          # unit "K"
          0x4B,
          # value_type u8 = 0x01
          0x01,
          # default_value i16 = 20
          0x00,
          0x14,
          # min_value i16 = -100 (0xFF9C)
          0xFF,
          0x9C,
          # max_value i16 = 1000 (0x03E8)
          0x03,
          0xE8,
          # merge_rule u8 = 0x01
          0x01,
          # dynamic u8 = 0x01
          0x01
        >>

      assert byte_size(bin) == 34
      assert bin == expected
    end

    test "empty catalog snapshot produces 12-byte envelope" do
      snap = AttributeCatalogSnapshot.normalize!(%{catalog_version: 0, definitions: []})
      bin = AttributeCatalogSnapshot.encode_for_wire(snap)

      assert bin == <<0::64, 0::32>>
      assert byte_size(bin) == 12
    end
  end

  describe "UTF-8 handling" do
    test "roundtrips Chinese characters in unit (e.g. 摄氏度)" do
      snap =
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [
            %{
              id: 1,
              name: "temperature",
              # "摄氏度" 在 UTF-8 下是 9 bytes (3 中文字符 × 3 bytes)
              unit: "摄氏度",
              value_type: 0x01,
              default_value: 0,
              min_value: -100,
              max_value: 100,
              merge_rule: 0x01,
              dynamic: true
            }
          ]
        })

      bin = AttributeCatalogSnapshot.encode_for_wire(snap)
      decoded = AttributeCatalogSnapshot.decode_for_wire(bin)
      assert decoded == snap
      assert hd(decoded.definitions).unit == "摄氏度"
      assert byte_size("摄氏度") == 9
    end

    test "roundtrips Chinese characters in name" do
      snap =
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [
            %{
              id: 1,
              name: "温度",
              unit: "",
              value_type: 0x01,
              default_value: 0,
              min_value: 0,
              max_value: 0,
              merge_rule: 0x01,
              dynamic: false
            }
          ]
        })

      bin = AttributeCatalogSnapshot.encode_for_wire(snap)
      decoded = AttributeCatalogSnapshot.decode_for_wire(bin)
      assert hd(decoded.definitions).name == "温度"
    end

    test "roundtrips emoji in name and unit (forward-compat)" do
      snap =
        AttributeCatalogSnapshot.normalize!(%{
          catalog_version: 1,
          definitions: [
            %{
              id: 1,
              name: "fire_intensity_🔥",
              unit: "🌡️",
              value_type: 0x02,
              default_value: 0,
              min_value: 0,
              max_value: 100,
              merge_rule: 0x03,
              dynamic: true
            }
          ]
        })

      bin = AttributeCatalogSnapshot.encode_for_wire(snap)
      decoded = AttributeCatalogSnapshot.decode_for_wire(bin)
      assert decoded == snap
      assert hd(decoded.definitions).name == "fire_intensity_🔥"
      assert hd(decoded.definitions).unit == "🌡️"
    end

    test "rejects invalid UTF-8 in name" do
      # 0xFF, 0xFE 是 UTF-8 非法字节序列
      assert_raise ArgumentError, ~r/name/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: <<0xFF, 0xFE>>,
          unit: "",
          value_type: 0x01,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end

    test "rejects invalid UTF-8 in unit (when non-empty)" do
      assert_raise ArgumentError, ~r/unit/i, fn ->
        AttributeDefinition.normalize!(%{
          id: 1,
          name: "x",
          unit: <<0xFF, 0xFE>>,
          value_type: 0x01,
          default_value: 0,
          min_value: 0,
          max_value: 0,
          merge_rule: 0x01,
          dynamic: false
        })
      end
    end
  end

  describe "AttributeDefinition struct sanity" do
    test "struct exists with expected default fields" do
      defn = %AttributeDefinition{}
      assert defn.id == 0
      assert defn.name == ""
      assert defn.value_type == 0x01
      assert defn.merge_rule == 0x01
      assert defn.dynamic == false
    end

    test "exposes value_type / merge_rule helpers" do
      assert AttributeDefinition.value_type_i16() == 0x01
      assert AttributeDefinition.value_type_u16() == 0x02
      assert AttributeDefinition.value_type_fixed32() == 0x03
      assert AttributeDefinition.value_type_enum8() == 0x04
      assert AttributeDefinition.value_type_bitset32() == 0x05

      assert AttributeDefinition.merge_override() == 0x01
      assert AttributeDefinition.merge_add_delta() == 0x02
      assert AttributeDefinition.merge_max() == 0x03
      assert AttributeDefinition.merge_min() == 0x04
      assert AttributeDefinition.merge_material_default() == 0x05
    end

    test "value_payload_size delegates to Phase 1.2 AttributeEntry" do
      assert AttributeDefinition.value_payload_size(0x01) == 2
      assert AttributeDefinition.value_payload_size(0x02) == 2
      assert AttributeDefinition.value_payload_size(0x03) == 4
      assert AttributeDefinition.value_payload_size(0x04) == 1
      assert AttributeDefinition.value_payload_size(0x05) == 4
    end
  end

  describe "AttributeCatalogSnapshot struct sanity" do
    test "struct exists with expected default fields" do
      snap = %AttributeCatalogSnapshot{}
      assert snap.catalog_version == 0
      assert snap.definitions == []
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp sample_defn(id) do
    %{
      id: id,
      name: "attr#{id}",
      unit: "",
      value_type: 0x01,
      default_value: 0,
      min_value: -10,
      max_value: 10,
      merge_rule: 0x01,
      dynamic: false
    }
  end
end
