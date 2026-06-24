defmodule GateServer.CodecEdgeCasesTest do
  use ExUnit.Case, async: true

  alias GateServer.Codec

  describe "decode edge cases" do
    test "movement input with extreme float values" do
      msg =
        <<0x01, 1::32-big, 0::32-big, 16::16-big, 1.0::float-32-big, -1.0::float-32-big,
          2.0::float-32-big, 3::16-big>>

      {:ok, {:movement_input, %{input_dir: {x, y}, speed_scale: speed_scale}}} = Codec.decode(msg)
      assert x == 1.0
      assert y == -1.0
      assert speed_scale == 2.0
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

    # DoS 护栏(batch 5):超限可变长字段不匹配主子句 → 落 fallthrough → {:error, :invalid_message}。
    # 配合 acceptor 的 2MB packet_size 总帧上限,客户端→服务端不可逼爆内存。
    test "auth_request over the username cap is rejected" do
      # username 上限 1024 字节;1025 应被拒。
      over_user = String.duplicate("a", 1025)
      ulen = byte_size(over_user)

      msg =
        <<0x05, 123::64-big, ulen::16-big, over_user::binary, 1::16-big, "b">>

      assert {:error, :invalid_message} == Codec.decode(msg)
    end

    test "chat_say over the text cap is rejected" do
      # chat text 上限 2048 字节;2049 应被拒。
      over_text = String.duplicate("x", 2049)
      tlen = byte_size(over_text)

      msg = <<0x08, 1::64-big, tlen::16-big, over_text::binary>>

      assert {:error, :invalid_message} == Codec.decode(msg)
    end

    test "voxel_chunk_subscribe over the known-chunks cap is rejected" do
      # known_count 上限 512;声明 513 应被拒(即便 body 不足也先被 guard 拦下)。
      msg =
        <<0x60, 1::64-big, 1::64-big, 0::32-big-signed, 0::32-big-signed, 0::32-big-signed, 1::8,
          1::8, 513::16-big>>

      assert {:error, :invalid_message} == Codec.decode(msg)
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

    test "movement_ack binary size is correct" do
      # Audit B-M2: 94 → 96 with trailing fixed_dt_ms u16.
      # Phase A1-4: 96 → 104 with trailing ground_z f64 BE.
      {:ok, bin} =
        Codec.encode(
          {:movement_ack, 0, 0, 42, {1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}, {7.0, 8.0, 9.0}, :grounded,
           0, 100, 3.0}
        )

      assert byte_size(bin) == 104
    end

    test "redesigned time_sync_reply binary size is correct" do
      {:ok, bin} = Codec.encode({:time_sync_reply, 42, 1000, 1100, 1200})
      assert byte_size(bin) == 33
    end
  end

  describe "protocol completeness" do
    test "every request-response client message can be decoded in new format" do
      messages = [
        <<0x01, 1::32-big, 0::32-big, 16::16-big, 0.0::float-32-big, 0.0::float-32-big,
          1.0::float-32-big, 0::16-big>>,
        <<0x02, 2::64-big, 0::64-big>>,
        <<0x03, 3::64-big, 4::64-big>>,
        <<0x05, 4::64-big, 1::16-big, "a", 1::16-big, "b">>,
        <<0x06, 5::64-big>>,
        <<0x07, 6::64-big, 3::16-big, "tok">>,
        <<0x08, 7::64-big, 2::16-big, "hi">>,
        <<0x09, 8::64-big, 1::16-big, 0::8, -1::64-big-signed, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big>>
      ]

      for msg <- messages do
        assert {:ok, _} = Codec.decode(msg), "Failed to decode new-format msg: #{inspect(msg)}"
      end
    end

    test "every server message type can be encoded" do
      messages = [
        {:result, :ok, 0},
        {:result, :error, 0},
        {:enter_scene_result, :ok, 0, {0.0, 0.0, 0.0}, 1},
        {:enter_scene_result, :error, 0},
        {:player_enter, 0, {0.0, 0.0, 0.0}},
        {:player_leave, 0},
        {:player_move, 0, 1, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, :grounded},
        {:time_sync_reply, 0, 1000, 1100, 1200},
        {:heartbeat_reply, 0},
        {:fast_lane_result, :ok, 0, 20003, "ticket"},
        {:fast_lane_attached, :ok, 0},
        {:movement_ack, 0, 0, 0, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, :grounded, 0,
         100, 0.0},
        {:chat_message, 0, "npc", "hi"},
        {:skill_event, 0, 1, {0.0, 0.0, 0.0}},
        {:effect_event, 0, 1, :projectile, {0.0, 0.0, 0.0}, nil, {0.0, 0.0, 0.0}, 0.0, 100}
      ]

      for msg <- messages do
        assert {:ok, bin} = Codec.encode(msg), "Failed to encode: #{inspect(msg)}"
        assert is_binary(bin)
      end
    end
  end
end
