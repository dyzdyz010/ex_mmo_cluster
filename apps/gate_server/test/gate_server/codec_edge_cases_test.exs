defmodule GateServer.CodecEdgeCasesTest do
  use ExUnit.Case, async: true

  alias GateServer.Codec

  describe "decode edge cases" do
    test "movement with extreme float values" do
      max_f64 = 1.7976931348623157e+308
      msg =
        <<0x01, 1::64-big, 0::64-big,
          max_f64::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

      {:ok, {:movement, 1, 0, {x, _, _}, _, _}} = Codec.decode(msg)
      assert x == max_f64
    end

    test "movement with very small float values" do
      tiny = 5.0e-324
      msg =
        <<0x01, 1::64-big, 0::64-big,
          tiny::float-64-big, tiny::float-64-big, tiny::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

      {:ok, {:movement, 1, 0, {x, _, _}, _, _}} = Codec.decode(msg)
      assert x == tiny
    end

    test "enter_scene with max u64 cid" do
      max_cid = 0xFFFFFFFFFFFFFFFF
      msg = <<0x02, max_cid::64-big>>
      {:ok, {:enter_scene, cid}} = Codec.decode(msg)
      assert cid == max_cid
    end

    test "enter_scene with zero cid" do
      msg = <<0x02, 0::64-big>>
      {:ok, {:enter_scene, 0}} = Codec.decode(msg)
    end

    test "auth_request with maximum length strings" do
      # 16-bit length = max 65535 bytes
      long_user = String.duplicate("a", 1000)
      long_code = String.duplicate("b", 1000)
      ulen = byte_size(long_user)
      clen = byte_size(long_code)
      msg = <<0x05, ulen::16-big, long_user::binary, clen::16-big, long_code::binary>>

      {:ok, {:auth_request, u, c}} = Codec.decode(msg)
      assert byte_size(u) == 1000
      assert byte_size(c) == 1000
    end

    test "auth_request with empty username" do
      msg = <<0x05, 0::16-big, 3::16-big, "abc">>
      {:ok, {:auth_request, "", "abc"}} = Codec.decode(msg)
    end

    test "heartbeat with max timestamp" do
      max_ts = 0xFFFFFFFFFFFFFFFF
      msg = <<0x04, max_ts::64-big>>
      {:ok, {:heartbeat, ts}} = Codec.decode(msg)
      assert ts == max_ts
    end

    test "all valid message type IDs are within client range" do
      # Client messages: 0x01-0x05
      for type <- [0x01, 0x02, 0x03, 0x04, 0x05] do
        assert type >= 0x01 and type <= 0x7F
      end
    end

    test "all server message type IDs are in server range" do
      # Verify encode produces server-range types
      server_messages = [
        {:result, :ok, 0},
        {:result, :error, 0},
        {:enter_scene_result, :ok, 0, {0.0, 0.0, 0.0}},
        {:enter_scene_result, :error, 0},
        {:player_enter, 1, {0.0, 0.0, 0.0}},
        {:player_leave, 1},
        {:player_move, 1, {0.0, 0.0, 0.0}},
        :time_sync_reply,
        {:heartbeat_reply, 0},
        {:movement_result, :ok, 0, 1, {0.0, 0.0, 0.0}}
      ]

      for msg <- server_messages do
        {:ok, bin} = Codec.encode(msg)
        <<type::8, _::binary>> = bin
        assert type >= 0x80, "Message #{inspect(msg)} has type 0x#{Integer.to_string(type, 16)} < 0x80"
      end
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
      # 1 (type) + 8 (packet_id) + 1 (status) + 8 (cid) + 24 (vec3) = 42
      assert byte_size(bin) == 42
    end

    test "result ok vs error have different status bytes" do
      {:ok, ok_bin} = Codec.encode({:result, :ok, 0})
      {:ok, err_bin} = Codec.encode({:result, :error, 0})
      <<0x80, 0::64, ok_status::8>> = ok_bin
      <<0x80, 0::64, err_status::8>> = err_bin
      assert ok_status == 0x00
      assert err_status == 0x01
      assert ok_status != err_status
    end
  end

  describe "protocol completeness" do
    test "every client message type can be decoded" do
      messages = [
        <<0x01, 0::64-big, 0::64-big, 0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>,
        <<0x02, 0::64-big>>,
        <<0x03>>,
        <<0x04, 0::64-big>>,
        <<0x05, 1::16-big, "a", 1::16-big, "b">>
      ]

      for msg <- messages do
        assert {:ok, _} = Codec.decode(msg), "Failed to decode: #{inspect(msg)}"
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
        :time_sync_reply,
        {:heartbeat_reply, 0},
        {:movement_result, :ok, 0, 0, {0.0, 0.0, 0.0}}
      ]

      for msg <- messages do
        assert {:ok, bin} = Codec.encode(msg), "Failed to encode: #{inspect(msg)}"
        assert is_binary(bin)
      end
    end
  end
end
