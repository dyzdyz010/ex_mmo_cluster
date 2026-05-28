defmodule GateServer.CodecTest do
  use ExUnit.Case, async: true

  alias GateServer.Codec

  describe "decode movement input" do
    test "decodes movement input with all fields (schema v1)" do
      msg =
        <<0x01, 1, 55::32-big, 1000::32-big, 100::16-big, 1.0::float-32-big, 0.5::float-32-big,
          1.25::float-32-big, 3::16-big>>

      assert {:ok,
              {:movement_input,
               %{
                 seq: 55,
                 client_tick: 1000,
                 dt_ms: 100,
                 input_dir: {1.0, 0.5},
                 speed_scale: 1.25,
                 movement_flags: 3
               }}} == Codec.decode(msg)
    end

    test "decodes movement input with zero direction (schema v1)" do
      msg =
        <<0x01, 1, 1::32-big, 500::32-big, 33::16-big, 0.0::float-32-big, 0.0::float-32-big,
          1.0::float-32-big, 2::16-big>>

      assert {:ok,
              {:movement_input,
               %{
                 seq: 1,
                 client_tick: 500,
                 dt_ms: 33,
                 input_dir: {+0.0, +0.0},
                 speed_scale: 1.0,
                 movement_flags: 2
               }}} == Codec.decode(msg)
    end

    test "rejects movement input with unknown schema version" do
      # schema byte is explicitly 9 (≠ @movement_wire_schema 1); the trailing
      # 24 bytes are payload-sized filler so length is sufficient and only the
      # schema mismatch triggers the rejection.
      msg = <<0x01, 9, 0::size(24)-unit(8)>>

      assert {:error, :unsupported_schema} = Codec.decode(msg)
    end

    test "rejects truncated movement input (schema present but payload short)" do
      assert {:error, :invalid_message} = Codec.decode(<<0x01, 1, 55::32-big>>)
    end

    test "rejects truncated movement input (opcode only, schema byte missing)" do
      assert {:error, :invalid_message} = Codec.decode(<<0x01>>)
    end
  end

  describe "decode enter_scene" do
    test "decodes enter_scene with request_id" do
      msg = <<0x02, 77::64-big, 12345::64-big>>
      assert {:ok, {:enter_scene, 12345, 77}} == Codec.decode(msg)
    end
  end

  describe "decode time_sync" do
    test "decodes redesigned time_sync" do
      assert {:ok, {:time_sync, 88, 999}} == Codec.decode(<<0x03, 88::64-big, 999::64-big>>)
    end
  end

  describe "decode heartbeat" do
    test "decodes heartbeat with timestamp" do
      ts = :os.system_time(:millisecond)
      msg = <<0x04, ts::64-big>>
      assert {:ok, {:heartbeat, ts}} == Codec.decode(msg)
    end
  end

  describe "decode fast-lane bootstrap" do
    test "decodes fast-lane TCP request" do
      assert {:ok, {:fast_lane_request, 7}} == Codec.decode(<<0x06, 7::64-big>>)
    end

    test "decodes UDP attach request" do
      ticket = "attach-ticket"
      msg = <<0x07, 8::64-big, byte_size(ticket)::16-big, ticket::binary>>
      assert {:ok, {:fast_lane_attach, 8, ^ticket}} = Codec.decode(msg)
    end
  end

  describe "decode chat and skill" do
    test "decodes chat_say with request_id and text" do
      text = "hello"
      msg = <<0x08, 42::64-big, byte_size(text)::16-big, text::binary>>
      assert {:ok, {:chat_say, "hello", 42}} == Codec.decode(msg)
    end

    test "decodes scoped chat_say with scope but no client authority payload" do
      text = "region hello"
      msg = <<0x0A, 43::64-big, 1::8, byte_size(text)::16-big, text::binary>>

      assert {:ok, {:chat_say_scoped, :region, "region hello", 43}} == Codec.decode(msg)
    end

    test "rejects malformed scoped chat_say" do
      assert {:error, :invalid_message} == Codec.decode(<<0x0A, 43::64-big, 1::8>>)
    end

    test "rejects scoped chat_say with trailing authority-shaped payload" do
      text = "region hello"
      frame = <<0x0A, 43::64-big, 1::8, byte_size(text)::16-big, text::binary>>

      assert {:error, :invalid_message} ==
               Codec.decode(
                 frame <> <<10::64-big, 0::32-big-signed, 0::32-big-signed, 0::32-big-signed>>
               )
    end

    test "decodes skill_cast with request_id and skill id" do
      assert {:ok,
              {:skill_cast,
               %{
                 skill_id: 1,
                 request_id: 43,
                 target_kind: :auto,
                 target_cid: nil,
                 target_position: {0.0, 0.0, 0.0}
               }}} ==
               Codec.decode(
                 <<0x09, 43::64-big, 1::16-big, 0::8, -1::64-big-signed, 0.0::float-64-big,
                   0.0::float-64-big, 0.0::float-64-big>>
               )
    end
  end

  describe "decode voxel messages" do
    test "decodes chunk subscribe with known chunk refs" do
      msg =
        <<0x60, 99::64-big, 1::64-big, -2::32-big-signed, 3::32-big-signed, 4::32-big-signed,
          5::8, 1::8, 2::16-big, -2::32-big-signed, 3::32-big-signed, 4::32-big-signed,
          10::64-big, -1::32-big-signed, 3::32-big-signed, 4::32-big-signed, 11::64-big>>

      assert {:ok,
              {:voxel_chunk_subscribe,
               %{
                 request_id: 99,
                 logical_scene_id: 1,
                 center_chunk: {-2, 3, 4},
                 radius_l_inf: 5,
                 want_snapshot: true,
                 known: [
                   %{chunk_coord: {-2, 3, 4}, chunk_version: 10},
                   %{chunk_coord: {-1, 3, 4}, chunk_version: 11}
                 ]
               }}} == Codec.decode(msg)
    end

    test "decodes chunk unsubscribe" do
      msg =
        <<0x61, 100::64-big, 1::64-big, 2::16-big, 0::32-big-signed, 0::32-big-signed,
          0::32-big-signed, 1::32-big-signed, 0::32-big-signed, 0::32-big-signed>>

      assert {:ok,
              {:voxel_chunk_unsubscribe,
               %{
                 request_id: 100,
                 logical_scene_id: 1,
                 chunks: [{0, 0, 0}, {1, 0, 0}]
               }}} == Codec.decode(msg)
    end

    test "decodes voxel impact intent" do
      msg =
        <<0x64, 101::64-big, 12::32-big, 77::64-big, 44::32-big, -8::64-big-signed,
          16::64-big-signed, 24::64-big-signed, 3::16-big, 0x0102030405060708::64-big>>

      assert {:ok,
              {:voxel_impact_intent,
               %{
                 request_id: 101,
                 client_intent_seq: 12,
                 logical_scene_id: 77,
                 source_skill_id: 44,
                 target_world_micro: {-8, 16, 24},
                 impact_kind: 3,
                 client_hint_hash: 0x0102030405060708
               }}} == Codec.decode(msg)
    end

    test "rejects malformed voxel impact intent" do
      assert {:error, :invalid_message} == Codec.decode(<<0x64, 101::64-big>>)
    end

    test "decodes voxel edit intent (typed, fixed 91-byte payload)" do
      msg =
        <<0x70, 1001::64-big, 17::32-big, 99::64-big, 0::8, 1::8, -8::64-big-signed,
          16::64-big-signed, 24::64-big-signed, 0::8-signed, 1::8-signed, 0::8-signed, 42::16-big,
          0::32-big, 0xDEAD_BEEF::64-big, 7::32-big, 0::32-big, 0xFFFF_FFFF_FFFF_FFFF::64-big,
          0xFFFF_FFFF::32-big, 0xCAFE_BABE_DEAD_BEEF::64-big>>

      assert byte_size(msg) == 92

      assert {:ok,
              {:voxel_edit_intent,
               %{
                 request_id: 1001,
                 client_intent_seq: 17,
                 logical_scene_id: 99,
                 action: 0,
                 target_granularity: 1,
                 target_world_micro: {-8, 16, 24},
                 face_normal: {0, 1, 0},
                 material_id: 42,
                 blueprint_ref: 0,
                 object_ref: 0xDEAD_BEEF,
                 part_ref: 7,
                 attribute_patch_ref: 0,
                 expected_chunk_version: 0xFFFF_FFFF_FFFF_FFFF,
                 expected_cell_hash: 0xFFFF_FFFF,
                 client_hint_hash: 0xCAFE_BABE_DEAD_BEEF
               }}} == Codec.decode(msg)
    end

    test "rejects malformed voxel edit intent (short payload)" do
      assert {:error, :invalid_message} == Codec.decode(<<0x70, 1001::64-big>>)
    end

    test "rejects voxel edit intent with payload longer than 91 bytes (no trailing bytes allowed)" do
      base = build_edit_intent_wire(edit_intent_default_fields())
      assert byte_size(base) == 92
      assert {:error, :invalid_message} == Codec.decode(base <> <<0xFF>>)
      assert {:error, :invalid_message} == Codec.decode(base <> <<0, 0, 0, 0>>)
    end

    test "rejects voxel edit intent with empty payload (just the opcode byte)" do
      assert {:error, :invalid_message} == Codec.decode(<<0x70>>)
    end

    test "decode is forward-compatible: accepts unknown action values up to u8 max" do
      for unknown_action <- [5, 99, 200, 0xFF] do
        msg = build_edit_intent_wire(%{edit_intent_default_fields() | action: unknown_action})

        assert {:ok, {:voxel_edit_intent, intent}} = Codec.decode(msg)
        assert intent.action == unknown_action
      end
    end

    test "decode is forward-compatible: accepts unknown target_granularity values" do
      for unknown_granularity <- [3, 99, 0xFF] do
        msg =
          build_edit_intent_wire(%{
            edit_intent_default_fields()
            | target_granularity: unknown_granularity
          })

        assert {:ok, {:voxel_edit_intent, intent}} = Codec.decode(msg)
        assert intent.target_granularity == unknown_granularity
      end
    end

    test "decode accepts wire-legal but semantically-invalid face_normal (e.g. (5, 0, 0))" do
      # Codec stays byte-faithful; `(5, 0, 0)` violates the "±1 / 0 only"
      # semantic rule but is a legal i8 triple. Business layer in Phase 1c
      # will reject; the decoder must not.
      msg = build_edit_intent_wire(%{edit_intent_default_fields() | face_normal: {5, 0, 0}})
      assert {:ok, {:voxel_edit_intent, intent}} = Codec.decode(msg)
      assert intent.face_normal == {5, 0, 0}
    end

    test "decode interprets face_normal bytes as signed i8 (e.g. byte 0xFF → -1)" do
      # We set the wire byte to 0xFF directly via -1 i8. Confirms that the
      # decoder uses `8-signed`, not unsigned.
      msg = build_edit_intent_wire(%{edit_intent_default_fields() | face_normal: {-1, -2, -3}})
      assert {:ok, {:voxel_edit_intent, intent}} = Codec.decode(msg)
      assert intent.face_normal == {-1, -2, -3}
    end

    test "decode preserves byte-level boundary values for u32 / u16 / u8" do
      msg =
        build_edit_intent_wire(%{
          edit_intent_default_fields()
          | client_intent_seq: 0xFFFF_FFFF,
            material_id: 0xFFFF,
            blueprint_ref: 0xFFFF_FFFF,
            part_ref: 0xFFFF_FFFF,
            attribute_patch_ref: 0xFFFF_FFFF,
            expected_cell_hash: 0xFFFF_FFFF,
            action: 0xFF,
            target_granularity: 0xFF
        })

      assert {:ok, {:voxel_edit_intent, intent}} = Codec.decode(msg)
      assert intent.client_intent_seq == 0xFFFF_FFFF
      assert intent.material_id == 0xFFFF
      assert intent.blueprint_ref == 0xFFFF_FFFF
      assert intent.part_ref == 0xFFFF_FFFF
      assert intent.attribute_patch_ref == 0xFFFF_FFFF
      assert intent.expected_cell_hash == 0xFFFF_FFFF
      assert intent.action == 0xFF
      assert intent.target_granularity == 0xFF
    end

    test "decode preserves byte-level boundary values for u64 fields" do
      msg =
        build_edit_intent_wire(%{
          edit_intent_default_fields()
          | request_id: 0xFFFF_FFFF_FFFF_FFFF,
            logical_scene_id: 0xFFFF_FFFF_FFFF_FFFF,
            object_ref: 0xFFFF_FFFF_FFFF_FFFF,
            expected_chunk_version: 0xFFFF_FFFF_FFFF_FFFF,
            client_hint_hash: 0xFFFF_FFFF_FFFF_FFFF
        })

      assert {:ok, {:voxel_edit_intent, intent}} = Codec.decode(msg)
      assert intent.request_id == 0xFFFF_FFFF_FFFF_FFFF
      assert intent.logical_scene_id == 0xFFFF_FFFF_FFFF_FFFF
      assert intent.object_ref == 0xFFFF_FFFF_FFFF_FFFF
      assert intent.expected_chunk_version == 0xFFFF_FFFF_FFFF_FFFF
      assert intent.client_hint_hash == 0xFFFF_FFFF_FFFF_FFFF
    end

    test "decode preserves i64 target_world_micro extremes" do
      for tuple <- [
            {-0x8000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF, 0},
            {0x7FFF_FFFF_FFFF_FFFF, -0x8000_0000_0000_0000, -1},
            {0, 0, -0x8000_0000_0000_0000}
          ] do
        msg = build_edit_intent_wire(%{edit_intent_default_fields() | target_world_micro: tuple})
        assert {:ok, {:voxel_edit_intent, intent}} = Codec.decode(msg)
        assert intent.target_world_micro == tuple
      end
    end

    test "decode round-trips zero values across all fields" do
      zero = edit_intent_default_fields()
      msg = build_edit_intent_wire(zero)
      assert {:ok, {:voxel_edit_intent, intent}} = Codec.decode(msg)

      # Only fields with sentinels diverge from zero by design; the rest
      # should equal exactly the zero defaults from `edit_intent_default_fields/0`.
      for {key, value} <- zero do
        assert Map.fetch!(intent, key) == value
      end
    end

    test "decodes voxel edit intent with all sentinels (no constraints)" do
      msg =
        <<0x70, 1::64-big, 1::32-big, 1::64-big, 1::8, 0::8, 0::64-big-signed, 0::64-big-signed,
          0::64-big-signed, 0::8-signed, 0::8-signed, 0::8-signed, 0::16-big, 0::32-big,
          0::64-big, 0::32-big, 0::32-big, 0xFFFF_FFFF_FFFF_FFFF::64-big, 0xFFFF_FFFF::32-big,
          0::64-big>>

      assert {:ok, {:voxel_edit_intent, intent}} = Codec.decode(msg)
      assert intent.action == 1
      assert intent.target_granularity == 0
      assert intent.expected_chunk_version == 0xFFFF_FFFF_FFFF_FFFF
      assert intent.expected_cell_hash == 0xFFFF_FFFF
      assert intent.material_id == 0
    end

    test "round-trips voxel edit intent via encode/decode" do
      intent = %{
        request_id: 555,
        client_intent_seq: 9,
        logical_scene_id: 12,
        action: 3,
        target_granularity: 2,
        target_world_micro: {-100, 0, 100},
        face_normal: {1, 0, -1},
        material_id: 0xABCD,
        blueprint_ref: 0x1234_5678,
        object_ref: 0x0000_0000_DEAD_BEEF,
        part_ref: 11,
        attribute_patch_ref: 0xFEED_FACE,
        expected_chunk_version: 0,
        expected_cell_hash: 0xCAFE_BABE,
        client_hint_hash: 0xFFFF_FFFF_FFFF_FFFF
      }

      assert {:ok, iodata} = Codec.encode({:voxel_edit_intent, intent})
      bytes = IO.iodata_to_binary(iodata)
      assert byte_size(bytes) == 92
      assert <<0x70, _payload::binary-size(91)>> = bytes

      assert {:ok, {:voxel_edit_intent, decoded}} = Codec.decode(bytes)
      assert decoded == intent
    end

    test "decodes the shared fixture voxel_edit_intent_v1.bin and matches expected fields" do
      bytes =
        File.read!(Path.join([__DIR__, "..", "fixtures", "voxel", "voxel_edit_intent_v1.bin"]))

      # The fixture concatenates two intents back-to-back (each 92 bytes).
      assert byte_size(bytes) == 184
      <<frame_a::binary-size(92), frame_b::binary-size(92)>> = bytes

      assert {:ok, {:voxel_edit_intent, intent_a}} = Codec.decode(frame_a)
      assert intent_a.request_id == 0x0000_0000_0000_00A1
      assert intent_a.action == 0
      assert intent_a.target_granularity == 0
      assert intent_a.target_world_micro == {16, 0, 32}
      assert intent_a.face_normal == {0, 1, 0}
      assert intent_a.material_id == 17
      assert intent_a.expected_chunk_version == 0xFFFF_FFFF_FFFF_FFFF
      assert intent_a.expected_cell_hash == 0xFFFF_FFFF

      assert {:ok, {:voxel_edit_intent, intent_b}} = Codec.decode(frame_b)
      assert intent_b.request_id == 0x0000_0000_0000_00B2
      assert intent_b.action == 1
      assert intent_b.target_granularity == 2
      assert intent_b.object_ref == 0x0000_0000_DEAD_BEEF
      assert intent_b.part_ref == 7
      assert intent_b.expected_chunk_version == 0x0000_0000_0000_0123
      assert intent_b.expected_cell_hash == 0xCAFE_BABE
    end

    test "fixture is in sync with the generator script (no stale bytes)" do
      bytes =
        File.read!(Path.join([__DIR__, "..", "fixtures", "voxel", "voxel_edit_intent_v1.bin"]))

      # Mirror of priv/scripts/gen_voxel_edit_intent_fixture.exs. Any change
      # in the script's intent definitions MUST be mirrored here, and vice
      # versa. The generated bytes must match the fixture byte-for-byte;
      # if they drift this test fails before any client/server divergence
      # can ship.
      intent_a = %{
        request_id: 0x0000_0000_0000_00A1,
        client_intent_seq: 1,
        logical_scene_id: 0x0000_0000_0000_002A,
        action: 0,
        target_granularity: 0,
        target_world_micro: {16, 0, 32},
        face_normal: {0, 1, 0},
        material_id: 17,
        blueprint_ref: 0,
        object_ref: 0,
        part_ref: 0,
        attribute_patch_ref: 0,
        expected_chunk_version: 0xFFFF_FFFF_FFFF_FFFF,
        expected_cell_hash: 0xFFFF_FFFF,
        client_hint_hash: 0
      }

      intent_b = %{
        request_id: 0x0000_0000_0000_00B2,
        client_intent_seq: 2,
        logical_scene_id: 0x0000_0000_0000_002A,
        action: 1,
        target_granularity: 2,
        target_world_micro: {-100, 0, 100},
        face_normal: {1, 0, -1},
        material_id: 0,
        blueprint_ref: 0,
        object_ref: 0x0000_0000_DEAD_BEEF,
        part_ref: 7,
        attribute_patch_ref: 0,
        expected_chunk_version: 0x0000_0000_0000_0123,
        expected_cell_hash: 0xCAFE_BABE,
        client_hint_hash: 0xFFFF_EEEE_DDDD_CCCC
      }

      {:ok, ia} = Codec.encode({:voxel_edit_intent, intent_a})
      {:ok, ib} = Codec.encode({:voxel_edit_intent, intent_b})
      regenerated = IO.iodata_to_binary([ia, ib])
      assert regenerated == bytes
    end

    test "encode rejects out-of-range u8 fields (action / target_granularity)" do
      base = edit_intent_zero_base()

      for {field, bad} <- [
            {:action, 256},
            {:action, -1},
            {:target_granularity, 256},
            {:target_granularity, -1}
          ] do
        assert {:error, {:invalid_field, ^field, ^bad}} =
                 Codec.encode({:voxel_edit_intent, Map.put(base, field, bad)}),
               "expected #{field}=#{bad} to be rejected"
      end
    end

    test "encode rejects out-of-range u16 field (material_id)" do
      base = edit_intent_zero_base()

      for bad <- [-1, 0x1_0000, 0xFFFF_FFFF_FFFF_FFFF] do
        assert {:error, {:invalid_field, :material_id, ^bad}} =
                 Codec.encode({:voxel_edit_intent, %{base | material_id: bad}}),
               "expected material_id=#{bad} to be rejected"
      end
    end

    test "encode rejects out-of-range u32 fields" do
      base = edit_intent_zero_base()

      for field <- [
            :client_intent_seq,
            :blueprint_ref,
            :part_ref,
            :attribute_patch_ref,
            :expected_cell_hash
          ] do
        for bad <- [-1, 0x1_0000_0000] do
          assert {:error, {:invalid_field, ^field, ^bad}} =
                   Codec.encode({:voxel_edit_intent, Map.put(base, field, bad)}),
                 "expected #{field}=#{bad} to be rejected as u32"
        end
      end
    end

    test "encode rejects out-of-range u64 fields" do
      base = edit_intent_zero_base()

      for field <- [
            :request_id,
            :logical_scene_id,
            :object_ref,
            :expected_chunk_version,
            :client_hint_hash
          ] do
        for bad <- [-1, 0x1_0000_0000_0000_0000] do
          assert {:error, {:invalid_field, ^field, ^bad}} =
                   Codec.encode({:voxel_edit_intent, Map.put(base, field, bad)}),
                 "expected #{field}=#{bad} to be rejected as u64"
        end
      end
    end

    test "encode accepts u64 sentinel value 0xFFFF_FFFF_FFFF_FFFF (max u64) and 0 (min)" do
      base = edit_intent_zero_base()

      for {field, bound} <- [
            {:request_id, 0xFFFF_FFFF_FFFF_FFFF},
            {:request_id, 0},
            {:object_ref, 0xFFFF_FFFF_FFFF_FFFF},
            {:expected_chunk_version, 0xFFFF_FFFF_FFFF_FFFF},
            {:client_hint_hash, 0xFFFF_FFFF_FFFF_FFFF}
          ] do
        assert {:ok, _} = Codec.encode({:voxel_edit_intent, Map.put(base, field, bound)}),
               "#{field}=#{bound} should be accepted"
      end
    end

    test "encode rejects out-of-range i64 target_world_micro coords" do
      base = edit_intent_zero_base()

      for bad_world <- [
            {0x1_0000_0000_0000_0000, 0, 0},
            {0, 0x1_0000_0000_0000_0000, 0},
            {0, 0, 0x1_0000_0000_0000_0000},
            {-0x8000_0000_0000_0001, 0, 0}
          ] do
        assert {:error, {:invalid_field, :target_world_micro, ^bad_world}} =
                 Codec.encode({:voxel_edit_intent, %{base | target_world_micro: bad_world}}),
               "expected target_world_micro=#{inspect(bad_world)} to be rejected"
      end
    end

    test "encode accepts i64 boundary target_world_micro values" do
      base = edit_intent_zero_base()

      boundaries = [
        {-0x8000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF, 0},
        {0x7FFF_FFFF_FFFF_FFFF, -0x8000_0000_0000_0000, 0},
        {0, 0, -0x8000_0000_0000_0000}
      ]

      for tuple <- boundaries do
        assert {:ok, _} =
                 Codec.encode({:voxel_edit_intent, %{base | target_world_micro: tuple}}),
               "target_world_micro=#{inspect(tuple)} should be accepted at i64 boundary"
      end
    end

    test "encode rejects out-of-range i8 face_normal components" do
      base = edit_intent_zero_base()

      for bad_normal <- [{128, 0, 0}, {-129, 0, 0}, {0, 128, 0}, {0, 0, 128}, {200, -200, 5}] do
        assert {:error, {:invalid_field, :face_normal, ^bad_normal}} =
                 Codec.encode({:voxel_edit_intent, %{base | face_normal: bad_normal}}),
               "expected face_normal=#{inspect(bad_normal)} to be rejected"
      end
    end

    test "encode accepts face_normal i8 boundaries (-128 / 127)" do
      base = edit_intent_zero_base()

      for tuple <- [{127, 0, 0}, {-128, 0, 0}, {0, 127, -128}] do
        assert {:ok, _} = Codec.encode({:voxel_edit_intent, %{base | face_normal: tuple}}),
               "face_normal=#{inspect(tuple)} should be accepted at i8 boundary"
      end
    end

    test "encode rejects non-integer fields (atoms / strings / nils)" do
      base = edit_intent_zero_base()

      assert {:error, {:invalid_field, :request_id, :not_a_number}} =
               Codec.encode({:voxel_edit_intent, %{base | request_id: :not_a_number}})

      assert {:error, {:invalid_field, :material_id, "0"}} =
               Codec.encode({:voxel_edit_intent, %{base | material_id: "0"}})

      # Nil falls through u64!/u32!/u8!/u16! since `nil` is not an integer; we
      # exercise both via :request_id (u64) and :action (u8).
      assert {:error, {:invalid_field, :request_id, nil}} =
               Codec.encode({:voxel_edit_intent, %{base | request_id: nil}})

      assert {:error, {:invalid_field, :action, nil}} =
               Codec.encode({:voxel_edit_intent, %{base | action: nil}})
    end

    test "encode rejects malformed target_world_micro / face_normal tuples" do
      base = edit_intent_zero_base()

      for {field, bad} <- [
            {:target_world_micro, {0, 0}},
            {:target_world_micro, [0, 0, 0]},
            {:target_world_micro, "abc"},
            {:target_world_micro, nil},
            {:face_normal, {0, 0}},
            {:face_normal, [0, 0, 0]},
            {:face_normal, nil}
          ] do
        assert {:error, {:invalid_field, ^field, ^bad}} =
                 Codec.encode({:voxel_edit_intent, Map.put(base, field, bad)}),
               "expected #{field}=#{inspect(bad)} to be rejected"
      end
    end

    test "encode treats missing keys as nil and reports {:invalid_field, _, nil}" do
      # Minimal map with only one key — encoder reaches request_id first.
      assert {:error, {:invalid_field, :request_id, nil}} =
               Codec.encode({:voxel_edit_intent, %{action: 0}})
    end

    defp edit_intent_default_fields do
      %{
        request_id: 0,
        client_intent_seq: 0,
        logical_scene_id: 0,
        action: 0,
        target_granularity: 0,
        target_world_micro: {0, 0, 0},
        face_normal: {0, 0, 0},
        material_id: 0,
        blueprint_ref: 0,
        object_ref: 0,
        part_ref: 0,
        attribute_patch_ref: 0,
        expected_chunk_version: 0,
        expected_cell_hash: 0,
        client_hint_hash: 0
      }
    end

    # Builds a wire-form 92-byte VoxelEditIntent message (opcode + 91-byte
    # payload) directly from a map of field values. Handy for decode tests
    # that want to construct a wire-level corner case (oversized payload,
    # forward-compatible action enum, signed face_normal byte etc.) without
    # going through the encoder's range checks.
    defp build_edit_intent_wire(fields) do
      {wx, wy, wz} = fields.target_world_micro
      {fnx, fny, fnz} = fields.face_normal

      <<0x70, fields.request_id::64-big, fields.client_intent_seq::32-big,
        fields.logical_scene_id::64-big, fields.action::8, fields.target_granularity::8,
        wx::64-big-signed, wy::64-big-signed, wz::64-big-signed, fnx::8-signed, fny::8-signed,
        fnz::8-signed, fields.material_id::16-big, fields.blueprint_ref::32-big,
        fields.object_ref::64-big, fields.part_ref::32-big, fields.attribute_patch_ref::32-big,
        fields.expected_chunk_version::64-big, fields.expected_cell_hash::32-big,
        fields.client_hint_hash::64-big>>
    end

    defp edit_intent_zero_base do
      %{
        request_id: 0,
        client_intent_seq: 0,
        logical_scene_id: 0,
        action: 0,
        target_granularity: 0,
        target_world_micro: {0, 0, 0},
        face_normal: {0, 0, 0},
        material_id: 0,
        blueprint_ref: 0,
        object_ref: 0,
        part_ref: 0,
        attribute_patch_ref: 0,
        expected_chunk_version: 0,
        expected_cell_hash: 0,
        client_hint_hash: 0
      }
    end

    test "decodes voxel build reservation intent" do
      # Wire layout (96 bytes after the 1-byte opcode):
      # request_id u64 + client_intent_seq u32 + logical_scene_id u64 +
      # parcel_id u64 + known_parcel_build_epoch u64 + AabbI64 (6 * i64) +
      # intent_hash u64 + ttl_ms u32.
      msg =
        <<0x65, 200::64-big, 5::32-big, 555::64-big, 9_001::64-big, 17::64-big,
          -100::64-big-signed, -50::64-big-signed, -25::64-big-signed, 200::64-big-signed,
          75::64-big-signed, 50::64-big-signed, 0xCAFE_BABE_DEAD_BEEF::64-big, 5_000::32-big>>

      assert {:ok,
              {:voxel_build_reservation_intent,
               %{
                 request_id: 200,
                 client_intent_seq: 5,
                 logical_scene_id: 555,
                 parcel_id: 9_001,
                 known_parcel_build_epoch: 17,
                 bounds_world_micro: {-100, -50, -25, 200, 75, 50},
                 intent_hash: 0xCAFE_BABE_DEAD_BEEF,
                 ttl_ms: 5_000
               }}} == Codec.decode(msg)
    end

    test "rejects malformed voxel build reservation intent" do
      assert {:error, :invalid_message} == Codec.decode(<<0x65, 1, 2, 3>>)
    end

    test "decodes voxel prefab place intent with known refs and objects" do
      msg =
        <<
          0x67,
          300::64-big,
          6::32-big,
          777::64-big,
          8_888::64-big,
          21::64-big,
          4_242::64-big,
          7::32-big,
          1_000::64-big-signed,
          -2_000::64-big-signed,
          3_000::64-big-signed,
          90::8,
          # known_ref_count = 1
          1::16-big,
          # known_refs[0]: chunk_coord (-1, 0, 1), chunk_version 11
          -1::32-big-signed,
          0::32-big-signed,
          1::32-big-signed,
          11::64-big,
          # known_object_count = 1
          1::16-big,
          # known_objects[0]: object_id 9_001, object_version 1
          9_001::64-big,
          1::64-big,
          # known_cell_ref_count = 1
          1::16-big,
          # known_cell_refs[0]: chunk_coord (-1, 0, 1), macro_index 1234,
          # cell_version 5, cell_hash 0xAABBCCDD
          -1::32-big-signed,
          0::32-big-signed,
          1::32-big-signed,
          1_234::16-big,
          5::32-big,
          0xAABB_CCDD::32-big,
          # placement_flags
          0x0000_0001::32-big
        >>

      assert {:ok,
              {:voxel_prefab_place_intent,
               %{
                 request_id: 300,
                 client_intent_seq: 6,
                 logical_scene_id: 777,
                 parcel_id: 8_888,
                 known_parcel_build_epoch: 21,
                 blueprint_id: 4_242,
                 blueprint_version: 7,
                 anchor_world_micro: {1_000, -2_000, 3_000},
                 rotation: 90,
                 known_refs: [%{chunk_coord: {-1, 0, 1}, chunk_version: 11}],
                 known_objects: [%{object_id: 9_001, object_version: 1}],
                 known_cell_refs: [
                   %{
                     chunk_coord: {-1, 0, 1},
                     macro_index: 1_234,
                     cell_version: 5,
                     cell_hash: 0xAABB_CCDD
                   }
                 ],
                 placement_flags: 0x0000_0001
               }}} == Codec.decode(msg)
    end

    test "rejects malformed voxel prefab place intent" do
      assert {:error, :invalid_message} == Codec.decode(<<0x67, 1, 2, 3>>)
    end

    test "decodes voxel field conduct intents" do
      msg =
        <<0x75, 1001::64-big, 42::32-big, 7::64-big, 15::64-big-signed, 4::64-big-signed,
          15::64-big-signed, 15::64-big-signed, 0::64-big-signed, 15::64-big-signed,
          300.0::float-64, 5::32-big, 1::8, 3::8, 0x003F::16-big, 300.0::float-64, 30.0::float-64,
          0.0::float-64, 18.0::float-64, 900.0::float-64>>

      assert {:ok, {:voxel_field_conduct_intent, intent}} = Codec.decode(msg)
      assert intent.request_id == 1001
      assert intent.client_intent_seq == 42
      assert intent.logical_scene_id == 7
      assert intent.source_world_macro == {15, 4, 15}
      assert intent.target_world_macro == {15, 0, 15}
      assert intent.source_potential == 300.0
      assert intent.max_ticks == 5
      assert intent.conduction_mode == :discharge
      assert intent.output_mode == :pulse
      assert intent.voltage == 300.0
      assert intent.current_limit_amps == 30.0
      assert intent.frequency_hz == 0.0
      assert intent.load_current_amps == 18.0
      assert intent.energy_budget_joules == 900.0
    end

    test "rejects truncated voxel field conduct intents" do
      assert {:error, :invalid_message} == Codec.decode(<<0x75, 1001::64-big>>)
    end

    test "decodes voxel debug probe" do
      command = "voxel_transport"
      msg = <<0x6F, 7::64-big, byte_size(command)::16-big, command::binary>>

      assert {:ok, {:voxel_debug_probe, %{request_id: 7, command: "voxel_transport"}}} ==
               Codec.decode(msg)
    end
  end

  describe "decode auth_request" do
    test "decodes auth_request with username and code" do
      username = "player1"
      code = "abc123"
      ulen = byte_size(username)
      clen = byte_size(code)

      msg = <<0x05, 99::64-big, ulen::16-big, username::binary, clen::16-big, code::binary>>

      assert {:ok, {:auth_request, "player1", "abc123", 99}} == Codec.decode(msg)
    end

    test "decodes auth_request with unicode username" do
      username = "玩家一"
      code = "token"
      ulen = byte_size(username)
      clen = byte_size(code)

      msg = <<0x05, 100::64-big, ulen::16-big, username::binary, clen::16-big, code::binary>>

      assert {:ok, {:auth_request, ^username, "token", 100}} = Codec.decode(msg)
    end

    test "decodes auth_request with empty code" do
      username = "test"
      ulen = byte_size(username)

      msg = <<0x05, 101::64-big, ulen::16-big, username::binary, 0::16-big>>
      assert {:ok, {:auth_request, "test", "", 101}} == Codec.decode(msg)
    end
  end

  describe "decode errors" do
    test "returns error for unknown message type" do
      assert {:error, {:unknown_message_type, 0xFF}} == Codec.decode(<<0xFF, 1, 2, 3>>)
    end

    test "returns error for empty binary" do
      assert {:error, :invalid_message} == Codec.decode(<<>>)
    end

    test "returns unsupported_schema for movement with unknown schema byte" do
      assert {:error, :unsupported_schema} == Codec.decode(<<0x01, 42::64-big>>)
    end

    test "returns invalid_message for old enter_scene layout" do
      assert {:error, :invalid_message} == Codec.decode(<<0x02, 42::64-big>>)
    end

    test "returns invalid_message for old time_sync layout" do
      assert {:error, :invalid_message} == Codec.decode(<<0x03>>)
    end
  end

  describe "encode result" do
    test "encodes ok result" do
      {:ok, bin} = Codec.encode({:result, :ok, 1})
      assert <<0x80, 1::64-big, 0x00>> == bin
    end

    test "encodes error result" do
      {:ok, bin} = Codec.encode({:result, :error, 99})
      assert <<0x80, 99::64-big, 0x01>> == bin
    end
  end

  describe "encode enter_scene_result" do
    test "ok frame carries protocol_version trailer" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :ok, 12, {10.0, 20.0, 30.0}, 1})

      assert <<0x84, 12::64-big, 0x00, 10.0::float-64-big, 20.0::float-64-big, 30.0::float-64-big,
               1::32-big, 1::16-big>> == bin
    end

    test "encodes error" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :error, 5})
      assert <<0x84, 5::64-big, 0x01>> == bin
    end
  end

  describe "encode movement_ack" do
    test "encodes movement ack with schema_version + server_send_ms + ground_z" do
      {:ok, bin} =
        Codec.encode(
          {:movement_ack, 10, 77, 1_700_000_000_123, 42, {1.5, 2.5, 3.5}, {4.5, 5.5, 6.5},
           {0.1, 0.2, 0.3}, :grounded, 3, 100, 3.5}
        )

      assert <<0x8B, 1, 10::32-big, 77::32-big, 1_700_000_000_123::64-big, 42::64-big,
               1.5::float-64-big, 2.5::float-64-big, 3.5::float-64-big, 4.5::float-64-big,
               5.5::float-64-big, 6.5::float-64-big, 0.1::float-64-big, 0.2::float-64-big,
               0.3::float-64-big, 0::8, 3::32-big, 100::16-big, 3.5::float-64-big>> == bin
    end

    test "rejects movement_ack with negative server_send_ms (no ArgumentError, clean error tuple)" do
      # server_send_ms is encoded as ::64-big (unsigned); a negative value must
      # fail the guard and fall through to the encode/1 fallback, not raise.
      assert {:error, :unknown_message} =
               Codec.encode(
                 {:movement_ack, 10, 77, -1, 42, {1.5, 2.5, 3.5}, {4.5, 5.5, 6.5}, {0.1, 0.2, 0.3},
                  :grounded, 3, 100, 3.5}
               )
    end
  end

  describe "encode broadcast messages" do
    test "encodes player_enter" do
      {:ok, bin} = Codec.encode({:player_enter, 100, {10.0, 20.0, 30.0}})

      assert <<0x81, 100::64-big, 10.0::float-64-big, 20.0::float-64-big, 30.0::float-64-big>> ==
               bin
    end

    test "encodes player_leave" do
      {:ok, bin} = Codec.encode({:player_leave, 100})
      assert <<0x82, 100::64-big>> == bin
    end

    test "encodes player_move (compact, schema v1 + server_send_ms)" do
      {:ok, bin} =
        Codec.encode(
          {:player_move, 55, 9, 1_700_000_000_123, {1.0, 2.0, 3.0}, {4.0, 5.0, 6.0},
           {0.1, 0.2, 0.3}, :airborne}
        )

      assert <<0x83, 1, 55::64-big, 9::32-big, 1_700_000_000_123::64-big, 1.0::float-64-big,
               2.0::float-64-big, 3.0::float-64-big, 4.0::float-64-big, 5.0::float-64-big,
               6.0::float-64-big, 0.1::float-64-big, 0.2::float-64-big, 0.3::float-64-big,
               1::8>> == bin
    end

    test "encodes player_move with AOI priority metadata (schema v1 + server_send_ms)" do
      {:ok, bin} =
        Codec.encode(
          {:player_move, 55, 9, 1_700_000_000_123, {1.0, 2.0, 3.0}, {4.0, 5.0, 6.0},
           {0.1, 0.2, 0.3}, :grounded, :medium, 0.75, 125.5, 2}
        )

      assert <<0x83, 1, 55::64-big, 9::32-big, 1_700_000_000_123::64-big, 1.0::float-64-big,
               2.0::float-64-big, 3.0::float-64-big, 4.0::float-64-big, 5.0::float-64-big,
               6.0::float-64-big, 0.1::float-64-big, 0.2::float-64-big, 0.3::float-64-big, 0::8,
               1::8, 0.75::float-32-big, 125.5::float-32-big, 2::16-big>> == bin
    end

    test "rejects player_move with negative server_send_ms (no ArgumentError, clean error tuple)" do
      # server_send_ms is encoded as ::64-big (unsigned); a negative value must
      # fail the guard and fall through to the encode/1 fallback, not raise.
      assert {:error, :unknown_message} =
               Codec.encode(
                 {:player_move, 55, 9, -1, {1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}, {0.1, 0.2, 0.3},
                  :airborne}
               )

      assert {:error, :unknown_message} =
               Codec.encode(
                 {:player_move, 55, 9, -1, {1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}, {0.1, 0.2, 0.3},
                  :grounded, :medium, 0.75, 125.5, 2}
               )
    end
  end

  describe "encode voxel messages" do
    test "encodes chunk snapshot with sections" do
      {:ok, iodata} =
        Codec.encode(
          {:voxel_chunk_snapshot,
           %{
             request_id: 9,
             logical_scene_id: 1,
             chunk_coord: {-1, 2, 3},
             schema_version: 1,
             chunk_size_in_macro: 16,
             micro_resolution: 8,
             chunk_version: 22,
             chunk_hash: 0x0102030405060708,
             sections: [{0x01, <<1, 2>>}, {0x02, <<3>>}]
           }}
        )

      bin = IO.iodata_to_binary(iodata)

      assert <<0x62, 9::64-big, 1::64-big, -1::32-big-signed, 2::32-big-signed, 3::32-big-signed,
               1::16-big, 16::8, 8::8, 22::64-big, 0x0102030405060708::64-big, 2::16-big, 0x01::8,
               2::32-big, 1, 2, 0x02::8, 1::32-big, 3>> == bin
    end

    test "encodes raw chunk snapshot payload" do
      {:ok, iodata} = Codec.encode({:voxel_chunk_snapshot_payload, <<1, 2, 3>>})
      assert <<0x62, 1, 2, 3>> == IO.iodata_to_binary(iodata)
    end

    test "encodes raw chunk delta payload with the 0x63 opcode" do
      {:ok, iodata} = Codec.encode({:voxel_chunk_delta_payload, <<9, 8, 7, 6>>})
      assert <<0x63, 9, 8, 7, 6>> == IO.iodata_to_binary(iodata)
    end

    test "encodes raw chunk invalidate payload with the 0x69 opcode" do
      {:ok, iodata} = Codec.encode({:voxel_chunk_invalidate_payload, <<5, 4, 3>>})
      assert <<0x69, 5, 4, 3>> == IO.iodata_to_binary(iodata)
    end

    test "encodes voxel intent result" do
      {:ok, iodata} =
        Codec.encode(
          {:voxel_intent_result,
           %{
             request_id: 9,
             client_intent_seq: 2,
             logical_scene_id: 1,
             result_code: :accepted,
             result_ref: 123,
             authoritative: [
               %{
                 chunk_coord: {0, 0, 0},
                 chunk_version: 10,
                 macro_index: 7,
                 cell_version: 3,
                 cell_hash: 0xAABBCCDD,
                 payload_kind: 1,
                 cell_payload: <<4, 5, 6>>
               }
             ],
             reason: "ok"
           }}
        )

      bin = IO.iodata_to_binary(iodata)

      assert <<0x68, 9::64-big, 2::32-big, 1::64-big, 0::8, 123::64-big, 1::16-big,
               0::32-big-signed, 0::32-big-signed, 0::32-big-signed, 10::64-big, 7::16-big,
               3::32-big, 0xAABBCCDD::32-big, 1::8, 3::32-big, 4, 5, 6, 2::16-big, "ok">> == bin
    end

    test "encodes voxel debug probe reply" do
      {:ok, bin} = Codec.encode({:voxel_debug_probe, %{request_id: 7, result: "ok"}})
      assert <<0x6F, 7::64-big, 2::16-big, "ok">> == bin
    end

    test "encodes a voxel build reservation intent that round-trips through decode" do
      intent = %{
        request_id: 200,
        client_intent_seq: 5,
        logical_scene_id: 555,
        parcel_id: 9_001,
        known_parcel_build_epoch: 17,
        bounds_world_micro: {-100, -50, -25, 200, 75, 50},
        intent_hash: 0xCAFE_BABE_DEAD_BEEF,
        ttl_ms: 5_000
      }

      {:ok, iodata} = Codec.encode({:voxel_build_reservation_intent, intent})
      bin = IO.iodata_to_binary(iodata)

      assert <<0x65, 200::64-big, 5::32-big, 555::64-big, 9_001::64-big, 17::64-big,
               -100::64-big-signed, -50::64-big-signed, -25::64-big-signed, 200::64-big-signed,
               75::64-big-signed, 50::64-big-signed, 0xCAFE_BABE_DEAD_BEEF::64-big,
               5_000::32-big>> = bin

      assert {:ok, {:voxel_build_reservation_intent, ^intent}} = Codec.decode(bin)
    end

    test "encodes a voxel prefab place intent that round-trips through decode" do
      intent = %{
        request_id: 300,
        client_intent_seq: 6,
        logical_scene_id: 777,
        parcel_id: 8_888,
        known_parcel_build_epoch: 21,
        blueprint_id: 4_242,
        blueprint_version: 7,
        anchor_world_micro: {1_000, -2_000, 3_000},
        rotation: 90,
        known_refs: [%{chunk_coord: {-1, 0, 1}, chunk_version: 11}],
        known_objects: [%{object_id: 9_001, object_version: 1}],
        known_cell_refs: [
          %{
            chunk_coord: {-1, 0, 1},
            macro_index: 1_234,
            cell_version: 5,
            cell_hash: 0xAABB_CCDD
          }
        ],
        placement_flags: 0x0000_0001
      }

      {:ok, iodata} = Codec.encode({:voxel_prefab_place_intent, intent})
      bin = IO.iodata_to_binary(iodata)

      assert <<0x67, 300::64-big, _rest::binary>> = bin
      assert {:ok, {:voxel_prefab_place_intent, ^intent}} = Codec.decode(bin)
    end
  end

  describe "encode time_sync and heartbeat" do
    test "encodes redesigned time_sync_reply" do
      {:ok, bin} = Codec.encode({:time_sync_reply, 321, 1000, 1100, 1200})
      assert <<0x85, 321::64-big, 1000::64-big, 1100::64-big, 1200::64-big>> == bin
    end

    test "encodes heartbeat_reply" do
      {:ok, bin} = Codec.encode({:heartbeat_reply, 999})
      assert <<0x86, 999::64-big>> == bin
    end

    test "encodes fast-lane bootstrap result" do
      {:ok, bin} = Codec.encode({:fast_lane_result, :ok, 5, 20003, "ticket"})
      assert <<0x87, 5::64-big, 0x00, 20003::16-big, 6::16-big, "ticket">> == bin
    end

    test "encodes fast-lane attached ack" do
      {:ok, bin} = Codec.encode({:fast_lane_attached, :ok, 6})
      assert <<0x88, 6::64-big, 0x00>> == bin
    end
  end

  describe "encode chat and skill broadcasts" do
    test "encodes chat_message" do
      {:ok, bin} = Codec.encode({:chat_message, 42, "tester", "hello"})
      assert <<0x89, 42::64-big, 6::16-big, "tester", 5::16-big, "hello">> = bin
    end

    test "encodes skill_event" do
      {:ok, bin} = Codec.encode({:skill_event, 42, 1, {1.0, 2.0, 3.0}})

      assert <<0x8A, 42::64-big, 1::16-big, 1.0::float-64-big, 2.0::float-64-big,
               3.0::float-64-big>> = bin
    end

    test "encodes player_state and combat_hit" do
      {:ok, state_bin} = Codec.encode({:player_state, 42, 75, 100, true})
      assert <<0x8C, 42::64-big, 75::16-big, 100::16-big, 1::8>> = state_bin

      {:ok, hit_bin} = Codec.encode({:combat_hit, 7, 42, 1, 25, 75, {1.0, 2.0, 3.0}})

      assert <<0x8D, 7::64-big, 42::64-big, 1::16-big, 25::16-big, 75::16-big, 1.0::float-64-big,
               2.0::float-64-big, 3.0::float-64-big>> = hit_bin
    end

    test "encodes actor_identity" do
      {:ok, bin} = Codec.encode({:actor_identity, 90_001, :npc, "Training Slime"})
      assert <<0x8E, 90_001::64-big, 1::8, 14::16-big, "Training Slime">> = bin
    end

    test "encodes effect_event" do
      {:ok, bin} =
        Codec.encode(
          {:effect_event, 7, 4, :projectile, {1.0, 2.0, 3.0}, 42, {4.0, 5.0, 6.0}, 96.0, 350}
        )

      assert <<0x8F, 7::64-big, 4::16-big, 1::8, 42::64-big, 1.0::float-64-big, 2.0::float-64-big,
               3.0::float-64-big, 4.0::float-64-big, 5.0::float-64-big, 6.0::float-64-big,
               96.0::float-64-big, 350::32-big>> = bin
    end
  end

  describe "encode errors" do
    test "returns error for unknown message" do
      assert {:error, :unknown_message} == Codec.encode({:nonexistent, 1, 2})
    end
  end

  describe "encode → decode roundtrip" do
    test "movement input roundtrip from client perspective (schema v1)" do
      client_msg =
        <<0x01, 1, 9::32-big, 1000::32-big, 33::16-big, 1.0::float-32-big, 0.0::float-32-big,
          1.0::float-32-big, 2::16-big>>

      assert {:ok,
              {:movement_input,
               %{
                 seq: 9,
                 client_tick: 1000,
                 dt_ms: 33,
                 input_dir: {1.0, +0.0},
                 speed_scale: 1.0,
                 movement_flags: 2
               }}} = Codec.decode(client_msg)
    end

    test "broadcast messages encode to correct binary size" do
      {:ok, enter} = Codec.encode({:player_enter, 1, {0.0, 0.0, 0.0}})
      assert byte_size(enter) == 33

      {:ok, leave} = Codec.encode({:player_leave, 1})
      assert byte_size(leave) == 9

      {:ok, move} =
        Codec.encode(
          {:player_move, 1, 1, 0, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, :grounded}
        )

      # schema v1: opcode(1) + schema(1) + cid(8) + server_tick(4) + server_send_ms(8) + 9*f64(72) + mode(1) = 95
      assert byte_size(move) == 95
    end
  end
end
