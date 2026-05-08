defmodule GateServer.Codec.ObjectStateDeltaTest do
  # Phase 4 Step 4-8: 0x6C ObjectStateDelta wire codec roundtrip.
  use ExUnit.Case, async: true

  alias GateServer.Codec

  describe "encode/1 + decode_voxel_object_state_delta_payload/1" do
    test "roundtrips a minimal delta with one affected chunk" do
      delta = %{
        logical_scene_id: 1,
        object_id: 42,
        object_version: 7,
        # damaged | part_destroyed
        state_flags: 0x3,
        affected_chunks: [{0, 0, 0}]
      }

      assert {:ok, iodata} = Codec.encode({:voxel_object_state_delta, delta})

      <<0x6C, payload::binary>> = IO.iodata_to_binary(iodata)

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

      assert {:ok, iodata} = Codec.encode({:voxel_object_state_delta, delta})
      <<0x6C, payload::binary>> = IO.iodata_to_binary(iodata)

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload)
      assert decoded.affected_chunks == [{-1, 0, 0}, {0, 0, 0}, {0, -2, 3}]
    end

    test "encode rejects malformed affected_chunks" do
      delta = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0,
        affected_chunks: ["not a coord"]
      }

      assert {:error, {:invalid_field, :affected_chunks, _}} =
               Codec.encode({:voxel_object_state_delta, delta})
    end

    test "encode rejects out-of-range scalars" do
      base = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0,
        affected_chunks: [{0, 0, 0}]
      }

      assert {:error, {:invalid_field, :state_flags, _}} =
               Codec.encode({:voxel_object_state_delta, %{base | state_flags: 0x1_FFFF_FFFF}})

      assert {:error, {:invalid_field, :object_id, _}} =
               Codec.encode({:voxel_object_state_delta, %{base | object_id: -1}})
    end

    test "decode rejects truncated payloads" do
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

    test "wire opcode is 0x6C" do
      delta = %{
        logical_scene_id: 1,
        object_id: 1,
        object_version: 1,
        state_flags: 0,
        affected_chunks: [{0, 0, 0}]
      }

      assert {:ok, iodata} = Codec.encode({:voxel_object_state_delta, delta})
      assert <<0x6C, _rest::binary>> = IO.iodata_to_binary(iodata)
    end
  end
end
