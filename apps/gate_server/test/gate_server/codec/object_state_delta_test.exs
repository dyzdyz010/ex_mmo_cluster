defmodule GateServer.Codec.ObjectStateDeltaTest do
  # Phase 4-bis Step 4-bis-2: 0x6C ObjectStateDelta encoder 已挪到
  # scene_server/voxel/codec.ex (decision D2)。gate codec 端只做 binary
  # pass-through(prefix 0x6C opcode);decode 仍保留在 gate 端供 server-side
  # 调试 / 测试用。
  use ExUnit.Case, async: true

  alias GateServer.Codec

  describe "encode/1 binary pass-through" do
    test "prefixes pre-encoded payload with 0x6C opcode" do
      payload = <<1, 2, 3, 4>>
      assert {:ok, iodata} = Codec.encode({:voxel_object_state_delta_payload, payload})
      assert IO.iodata_to_binary(iodata) == <<0x6C, 1, 2, 3, 4>>
    end

    test "handles an empty payload" do
      assert {:ok, iodata} = Codec.encode({:voxel_object_state_delta_payload, ""})
      assert IO.iodata_to_binary(iodata) == <<0x6C>>
    end

    test "round-trips a real scene-encoded payload through gate prefix" do
      # The scene codec is the canonical encoder; this test verifies that
      # the gate prefix layer produces a wire-correct frame when paired with
      # whatever scene_server emits.
      payload =
        SceneServer.Voxel.Codec.encode_voxel_object_state_delta_payload(%{
          logical_scene_id: 1,
          object_id: 42,
          object_version: 7,
          state_flags: 0x3,
          affected_chunks: [{0, 0, 0}]
        })

      assert {:ok, iodata} = Codec.encode({:voxel_object_state_delta_payload, payload})
      framed = IO.iodata_to_binary(iodata)

      assert <<0x6C, decoded_payload::binary>> = framed
      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(decoded_payload)
      assert decoded.logical_scene_id == 1
      assert decoded.object_id == 42
      assert decoded.object_version == 7
      assert decoded.state_flags == 0x3
      assert decoded.affected_chunks == [{0, 0, 0}]
    end

    test "rejects map-form input (encoder moved to scene codec)" do
      assert {:error, :unknown_message} = Codec.encode({:voxel_object_state_delta, %{}})
    end
  end

  describe "decode_voxel_object_state_delta_payload/1" do
    test "decodes a minimal payload with one affected chunk" do
      payload =
        <<1::64-big, 42::64-big, 7::64-big, 3::32-big, 0::16-big, 0::16-big, 1::16-big,
          0::32-big-signed, 0::32-big-signed, 0::32-big-signed>>

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload)
      assert decoded.logical_scene_id == 1
      assert decoded.object_id == 42
      assert decoded.object_version == 7
      assert decoded.state_flags == 0x3
      assert decoded.attribute_patch_count == 0
      assert decoded.tag_patch_count == 0
      assert decoded.affected_chunks == [{0, 0, 0}]
    end

    test "decodes multi-chunk affected list with negative coords" do
      payload =
        <<100::64-big, 99_999::64-big, 1234::64-big, 1::32-big, 0::16-big, 0::16-big, 3::16-big,
          -1::32-big-signed, 0::32-big-signed, 0::32-big-signed, 0::32-big-signed,
          0::32-big-signed, 0::32-big-signed, 0::32-big-signed, -2::32-big-signed,
          3::32-big-signed>>

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload)
      assert decoded.affected_chunks == [{-1, 0, 0}, {0, 0, 0}, {0, -2, 3}]
    end

    test "rejects truncated header" do
      assert {:error, :invalid_object_state_delta} =
               Codec.decode_voxel_object_state_delta_payload(<<0, 0, 0, 0>>)
    end

    test "rejects truncated affected_chunks block" do
      truncated =
        <<1::64-big, 42::64-big, 1::64-big, 0::32-big, 0::16-big, 0::16-big, 2::16-big,
          0::32-big-signed, 0::32-big-signed, 0::32-big-signed>>

      assert {:error, :invalid_affected_chunks} =
               Codec.decode_voxel_object_state_delta_payload(truncated)
    end
  end
end
