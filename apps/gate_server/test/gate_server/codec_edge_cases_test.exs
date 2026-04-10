defmodule GateServer.CodecEdgeCasesTest do
  use ExUnit.Case, async: true

  alias GateServer.Codec

  describe "decode edge cases" do
    test "movement with extreme float values" do
      max_f64 = 1.7976931348623157e+308

      msg =
        <<0x01, 1::64-big, 1::64-big, 0::64-big, max_f64::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

      {:ok, {:movement, 1, 0, {x, _, _}, _, _, 1}} = Codec.decode(msg)
      assert x == max_f64
    end

    test "enter_scene with max u64 cid" do
      max_cid = 0xFFFFFFFFFFFFFFFF
      msg = <<0x02, 1::64-big, max_cid::64-big>>
      {:ok, {:enter_scene, cid, 1}} = Codec.decode(msg)
      assert cid == max_cid
    end

    test "auth_request with maximum length strings" do
      long_user = String.duplicate("a", 1000)
      long_code = String.duplicate("b", 1000)
      ulen = byte_size(long_user)
      clen = byte_size(long_code)

      msg =
        <<0x05, 123::64-big, ulen::16-big, long_user::binary, clen::16-big, long_code::binary>>

      {:ok, {:auth_request, u, c, 123}} = Codec.decode(msg)
      assert byte_size(u) == 1000
      assert byte_size(c) == 1000
    end

    test "auth_request with empty username" do
      msg = <<0x05, 123::64-big, 0::16-big, 3::16-big, "abc">>
      {:ok, {:auth_request, "", "abc", 123}} = Codec.decode(msg)
    end

    test "old request layouts are rejected as invalid_message" do
      assert {:error, :invalid_message} == Codec.decode(<<0x02, 0::64-big>>)
      assert {:error, :invalid_message} == Codec.decode(<<0x03>>)
      assert {:error, :invalid_message} == Codec.decode(<<0x05, 1::16-big, "a", 1::16-big, "b">>)
    end
  end

  describe "encode edge cases" do
    test "player_enter with negative coordinates" do
      {:ok, bin} = Codec.encode({:player_enter, 1, {-500.0, -300.0, -100.0}})
      <<0x81, 1::64-big, x::float-64-big, y::float-64-big, z::float-64-big>> = bin
      assert_in_delta x, -500.0, 0.001
      assert_in_delta y, -300.0, 0.001
      assert_in_delta z, -100.0, 0.001
    end

    test "movement_result binary size is correct" do
      {:ok, bin} = Codec.encode({:movement_result, :ok, 0, 42, {1.0, 2.0, 3.0}})
      assert byte_size(bin) == 42
    end

    test "redesigned time_sync_reply binary size is correct" do
      {:ok, bin} = Codec.encode({:time_sync_reply, 42, 1000, 1100, 1200})
      assert byte_size(bin) == 33
    end
  end

  describe "protocol completeness" do
    test "every request-response client message can be decoded in new format" do
      messages = [
        <<0x01, 1::64-big, 0::64-big, 0::64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>,
        <<0x02, 2::64-big, 0::64-big>>,
        <<0x03, 3::64-big, 4::64-big>>,
        <<0x05, 4::64-big, 1::16-big, "a", 1::16-big, "b">>,
        <<0x06, 5::64-big>>,
        <<0x07, 6::64-big, 3::16-big, "tok">>
      ]

      for msg <- messages do
        assert {:ok, _} = Codec.decode(msg), "Failed to decode new-format msg: #{inspect(msg)}"
      end
    end

    test "every server message type can be encoded" do
      messages = [
        {:result, :ok, 0},
        {:result, :error, 0},
        {:enter_scene_result, :ok, 0, {0.0, 0.0, 0.0}},
        {:enter_scene_result, :error, 0},
        {:player_enter, 0, {0.0, 0.0, 0.0}},
        {:player_leave, 0},
        {:player_move, 0, {0.0, 0.0, 0.0}},
        {:time_sync_reply, 0, 1000, 1100, 1200},
        {:heartbeat_reply, 0},
        {:fast_lane_result, :ok, 0, 29001, "ticket"},
        {:fast_lane_attached, :ok, 0},
        {:movement_result, :ok, 0, 0, {0.0, 0.0, 0.0}}
      ]

      for msg <- messages do
        assert {:ok, bin} = Codec.encode(msg), "Failed to encode: #{inspect(msg)}"
        assert is_binary(bin)
      end
    end
  end
end
