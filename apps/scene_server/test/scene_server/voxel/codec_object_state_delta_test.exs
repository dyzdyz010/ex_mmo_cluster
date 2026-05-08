defmodule SceneServer.Voxel.CodecObjectStateDeltaTest do
  # Phase 4-bis Step 4-bis-1: 0x6C ObjectStateDelta wire codec moved from
  # gate_server/codec.ex to scene_server/voxel/codec.ex (decision D2).
  # Wire format unchanged from Phase 4 Step 4-8.
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Codec

  describe "encode_voxel_object_state_delta_payload/1 + decode_voxel_object_state_delta_payload/1" do
    test "roundtrips a minimal delta with one affected chunk" do
      delta = %{
        logical_scene_id: 1,
        object_id: 42,
        object_version: 7,
        # damaged | part_destroyed
        state_flags: 0x3,
        affected_chunks: [{0, 0, 0}]
      }

      payload = Codec.encode_voxel_object_state_delta_payload(delta)

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload)
      assert decoded.logical_scene_id == 1
      assert decoded.object_id == 42
      assert decoded.object_version == 7
      assert decoded.state_flags == 0x3
      assert decoded.attribute_patch_count == 0
      assert decoded.tag_patch_count == 0
      assert decoded.affected_chunks == [{0, 0, 0}]
    end

    test "roundtrips multi-chunk affected list with negative coords" do
      delta = %{
        logical_scene_id: 100,
        object_id: 99_999,
        object_version: 1_234,
        state_flags: 0x1,
        affected_chunks: [{-1, 0, 0}, {0, 0, 0}, {0, -2, 3}]
      }

      payload = Codec.encode_voxel_object_state_delta_payload(delta)

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload)
      assert decoded.affected_chunks == [{-1, 0, 0}, {0, 0, 0}, {0, -2, 3}]
    end

    test "roundtrips empty affected_chunks list" do
      delta = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0,
        affected_chunks: []
      }

      payload = Codec.encode_voxel_object_state_delta_payload(delta)

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload)
      assert decoded.affected_chunks == []
    end

    test "produces fixed header size + 12 bytes per affected chunk" do
      # Header: 8 (scene) + 8 (object) + 8 (version) + 4 (state_flags) +
      #         2 (attr_count) + 2 (tag_count) + 2 (affected_count) = 34 bytes.
      delta = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0,
        affected_chunks: [{0, 0, 0}, {1, 1, 1}]
      }

      payload = Codec.encode_voxel_object_state_delta_payload(delta)
      assert byte_size(payload) == 34 + 12 * 2
    end

    test "encode raises on out-of-range state_flags" do
      delta = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0x1_FFFF_FFFF,
        affected_chunks: [{0, 0, 0}]
      }

      assert_raise ArgumentError, fn ->
        Codec.encode_voxel_object_state_delta_payload(delta)
      end
    end

    test "encode raises on too many affected_chunks" do
      coords = for i <- 0..0xFFFF, do: {i, 0, 0}

      delta = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0,
        affected_chunks: coords
      }

      assert_raise ArgumentError, fn ->
        Codec.encode_voxel_object_state_delta_payload(delta)
      end
    end

    test "encode raises on non-integer chunk coord" do
      delta = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0,
        affected_chunks: ["not a coord"]
      }

      assert_raise ArgumentError, fn ->
        Codec.encode_voxel_object_state_delta_payload(delta)
      end
    end

    test "encode raises on out-of-range chunk coord" do
      delta = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0,
        # i32 max is 0x7FFF_FFFF
        affected_chunks: [{0x8000_0000, 0, 0}]
      }

      assert_raise ArgumentError, fn ->
        Codec.encode_voxel_object_state_delta_payload(delta)
      end
    end

    test "encode raises on negative scalar fields" do
      base = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0,
        affected_chunks: [{0, 0, 0}]
      }

      assert_raise FunctionClauseError, fn ->
        Codec.encode_voxel_object_state_delta_payload(%{base | object_id: -1})
      end
    end

    test "decode rejects truncated header" do
      assert {:error, :invalid_object_state_delta} =
               Codec.decode_voxel_object_state_delta_payload(<<0, 0, 0, 0>>)
    end

    test "decode rejects truncated affected_chunks block" do
      # Header claims 2 affected chunks, but only one chunk follows.
      truncated =
        <<1::64-big, 42::64-big, 1::64-big, 0::32-big, 0::16-big, 0::16-big, 2::16-big,
          0::32-big-signed, 0::32-big-signed, 0::32-big-signed>>

      assert {:error, :invalid_affected_chunks} =
               Codec.decode_voxel_object_state_delta_payload(truncated)
    end

    test "decode preserves trailing bytes as rest (forward compat)" do
      payload_main =
        <<1::64-big, 42::64-big, 7::64-big, 0::32-big, 0::16-big, 0::16-big, 0::16-big>>

      trailing = <<0xDE, 0xAD, 0xBE, 0xEF>>

      assert {:ok, decoded, ^trailing} =
               Codec.decode_voxel_object_state_delta_payload(payload_main <> trailing)

      assert decoded.affected_chunks == []
    end

    test "decode reads non-zero attribute_patch_count and tag_patch_count fields" do
      # Forward compat: Phase 5 will populate these; decoder must surface them
      # so consumers can refuse / log unexpected non-zero values.
      payload =
        <<1::64-big, 42::64-big, 7::64-big, 0::32-big, 5::16-big, 3::16-big, 0::16-big>>

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload)
      assert decoded.attribute_patch_count == 5
      assert decoded.tag_patch_count == 3
    end
  end
end
