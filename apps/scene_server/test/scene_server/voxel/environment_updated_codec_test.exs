defmodule SceneServer.Voxel.EnvironmentUpdatedCodecTest do
  @moduledoc """
  Phase 5.F EnvironmentUpdated (opcode 0x72) codec roundtrip + golden tests.

  Wire layout（一旦发出即冻结）：

      EnvironmentUpdated (opcode 0x72)
        logical_scene_id: u64
        chunk_coord: i32 cx, i32 cy, i32 cz
        base_chunk_version: u64
        new_chunk_version: u64
        update_count: u16
        updates[update_count] {
          macro_index: u16            // 0..4095
          field_mask: u8              // 0x01 temperature / 0x02 moisture
          temperature: i16            // 仅 field_mask 含 0x01 时存在
          moisture: i16               // 仅 field_mask 含 0x02 时存在
          source_hash: u32
        }
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias SceneServer.Voxel.Codec

  describe "encode/decode roundtrip" do
    test "empty updates payload" do
      payload = %{
        logical_scene_id: 7,
        chunk_coord: {1, 2, 3},
        base_chunk_version: 100,
        new_chunk_version: 101,
        updates: []
      }

      encoded = Codec.encode_environment_updated_payload(payload)
      assert is_binary(encoded)

      decoded = Codec.decode_environment_updated_payload!(encoded)
      assert decoded.logical_scene_id == 7
      assert decoded.chunk_coord == {1, 2, 3}
      assert decoded.base_chunk_version == 100
      assert decoded.new_chunk_version == 101
      assert decoded.updates == []
    end

    test "single temperature update" do
      payload = %{
        logical_scene_id: 9,
        chunk_coord: {0, 0, 0},
        base_chunk_version: 10,
        new_chunk_version: 11,
        updates: [
          %{macro_index: 42, field_mask: 0x01, temperature: 1234, source_hash: 0xDEAD_BEEF}
        ]
      }

      encoded = Codec.encode_environment_updated_payload(payload)
      decoded = Codec.decode_environment_updated_payload!(encoded)

      assert [op] = decoded.updates
      assert op.macro_index == 42
      assert op.field_mask == 0x01
      assert op.temperature == 1234
      refute Map.has_key?(op, :moisture)
      assert op.source_hash == 0xDEAD_BEEF
    end

    test "single moisture update" do
      payload = %{
        logical_scene_id: 9,
        chunk_coord: {-1, -2, -3},
        base_chunk_version: 10,
        new_chunk_version: 11,
        updates: [
          %{macro_index: 100, field_mask: 0x02, moisture: -500, source_hash: 0xCAFE_BABE}
        ]
      }

      encoded = Codec.encode_environment_updated_payload(payload)
      decoded = Codec.decode_environment_updated_payload!(encoded)

      assert decoded.chunk_coord == {-1, -2, -3}
      assert [op] = decoded.updates
      assert op.field_mask == 0x02
      assert op.moisture == -500
      refute Map.has_key?(op, :temperature)
      assert op.source_hash == 0xCAFE_BABE
    end

    test "combined temperature+moisture update" do
      payload = %{
        logical_scene_id: 9,
        chunk_coord: {0, 0, 0},
        base_chunk_version: 10,
        new_chunk_version: 11,
        updates: [
          %{
            macro_index: 4095,
            field_mask: 0x03,
            temperature: 32_000,
            moisture: -32_000,
            source_hash: 0x1234_5678
          }
        ]
      }

      encoded = Codec.encode_environment_updated_payload(payload)
      decoded = Codec.decode_environment_updated_payload!(encoded)

      assert [op] = decoded.updates
      assert op.field_mask == 0x03
      assert op.temperature == 32_000
      assert op.moisture == -32_000
      assert op.source_hash == 0x1234_5678
    end

    test "multiple updates of mixed kinds roundtrip" do
      updates = [
        %{macro_index: 0, field_mask: 0x01, temperature: 100, source_hash: 1},
        %{macro_index: 1, field_mask: 0x02, moisture: 200, source_hash: 2},
        %{
          macro_index: 2,
          field_mask: 0x03,
          temperature: 300,
          moisture: 400,
          source_hash: 3
        },
        %{macro_index: 4095, field_mask: 0x01, temperature: -1, source_hash: 4}
      ]

      payload = %{
        logical_scene_id: 0xDEAD_BEEF_DEAD_BEEF,
        chunk_coord: {0x7FFF_FFFF, -0x8000_0000, 0},
        base_chunk_version: 0xFFFF_FFFF_FFFF_FFFF - 1,
        new_chunk_version: 0xFFFF_FFFF_FFFF_FFFF,
        updates: updates
      }

      encoded = Codec.encode_environment_updated_payload(payload)
      decoded = Codec.decode_environment_updated_payload!(encoded)

      assert decoded.logical_scene_id == 0xDEAD_BEEF_DEAD_BEEF
      assert decoded.chunk_coord == {0x7FFF_FFFF, -0x8000_0000, 0}
      assert decoded.base_chunk_version == 0xFFFF_FFFF_FFFF_FFFF - 1
      assert decoded.new_chunk_version == 0xFFFF_FFFF_FFFF_FFFF
      assert length(decoded.updates) == 4

      Enum.zip(decoded.updates, updates)
      |> Enum.each(fn {a, b} ->
        assert a.macro_index == b.macro_index
        assert a.field_mask == b.field_mask
        assert a.source_hash == b.source_hash

        if (b.field_mask &&& 0x01) != 0 do
          assert a.temperature == b.temperature
        end

        if (b.field_mask &&& 0x02) != 0 do
          assert a.moisture == b.moisture
        end
      end)
    end
  end

  describe "byte-level golden" do
    test "encoded byte sequence matches pinned hex (1 temp + 1 moist)" do
      payload = %{
        logical_scene_id: 1,
        chunk_coord: {0, 0, 0},
        base_chunk_version: 2,
        new_chunk_version: 3,
        updates: [
          %{macro_index: 7, field_mask: 0x01, temperature: 256, source_hash: 0x0A0B_0C0D},
          %{macro_index: 8, field_mask: 0x02, moisture: -1, source_hash: 0x11223344}
        ]
      }

      encoded = Codec.encode_environment_updated_payload(payload)

      # logical_scene_id(8) + chunk_coord(12) + base_v(8) + new_v(8) + count(2)
      # + op1: macro_index(2) + field_mask(1) + temperature i16(2) + source_hash(4) = 9
      # + op2: macro_index(2) + field_mask(1) + moisture i16(2) + source_hash(4) = 9
      # total = 8+12+8+8+2+9+9 = 56
      assert byte_size(encoded) == 56

      <<logical_scene_id::unsigned-big-integer-size(64), cx::signed-big-integer-size(32),
        cy::signed-big-integer-size(32), cz::signed-big-integer-size(32),
        base_v::unsigned-big-integer-size(64), new_v::unsigned-big-integer-size(64),
        count::unsigned-big-integer-size(16), rest::binary>> = encoded

      assert logical_scene_id == 1
      assert {cx, cy, cz} == {0, 0, 0}
      assert base_v == 2
      assert new_v == 3
      assert count == 2

      <<m1::unsigned-big-integer-size(16), fm1::unsigned-integer-size(8),
        t1::signed-big-integer-size(16), sh1::unsigned-big-integer-size(32), op2::binary>> = rest

      assert m1 == 7
      assert fm1 == 0x01
      assert t1 == 256
      assert sh1 == 0x0A0B_0C0D

      <<m2::unsigned-big-integer-size(16), fm2::unsigned-integer-size(8),
        m_val::signed-big-integer-size(16), sh2::unsigned-big-integer-size(32)>> = op2

      assert m2 == 8
      assert fm2 == 0x02
      assert m_val == -1
      assert sh2 == 0x11223344
    end
  end

  describe "forward-compat field_mask" do
    test "decoder rejects unknown field_mask bits" do
      # Build a hand-crafted payload with field_mask=0x04 (unknown).
      bad_payload =
        <<1::unsigned-big-integer-size(64), 0::signed-big-integer-size(32),
          0::signed-big-integer-size(32), 0::signed-big-integer-size(32),
          0::unsigned-big-integer-size(64), 1::unsigned-big-integer-size(64),
          1::unsigned-big-integer-size(16), 0::unsigned-big-integer-size(16),
          0x04::unsigned-integer-size(8), 0::unsigned-big-integer-size(32)>>

      assert_raise ArgumentError, fn ->
        Codec.decode_environment_updated_payload!(bad_payload)
      end
    end

    test "encoder rejects unknown field_mask bits" do
      payload = %{
        logical_scene_id: 1,
        chunk_coord: {0, 0, 0},
        base_chunk_version: 0,
        new_chunk_version: 1,
        updates: [
          %{macro_index: 0, field_mask: 0x80, source_hash: 0}
        ]
      }

      assert_raise ArgumentError, fn ->
        Codec.encode_environment_updated_payload(payload)
      end
    end

    test "decoder rejects field_mask=0 (no field set)" do
      bad_payload =
        <<1::unsigned-big-integer-size(64), 0::signed-big-integer-size(32),
          0::signed-big-integer-size(32), 0::signed-big-integer-size(32),
          0::unsigned-big-integer-size(64), 1::unsigned-big-integer-size(64),
          1::unsigned-big-integer-size(16), 0::unsigned-big-integer-size(16),
          0x00::unsigned-integer-size(8), 0::unsigned-big-integer-size(32)>>

      assert_raise ArgumentError, fn ->
        Codec.decode_environment_updated_payload!(bad_payload)
      end
    end
  end
end
