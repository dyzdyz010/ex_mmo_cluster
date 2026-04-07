defmodule GateServer.CodecTest do
  use ExUnit.Case, async: true

  alias GateServer.Codec

  # ═══════════════════════════════════════════════════════════
  # Client → Server: Decode tests
  # ═══════════════════════════════════════════════════════════

  describe "decode movement" do
    test "decodes movement with all fields" do
      msg =
        <<0x01, 42::64-big, 1000::64-big,
          1.0::float-64-big, 2.0::float-64-big, 3.0::float-64-big,
          4.0::float-64-big, 5.0::float-64-big, 6.0::float-64-big,
          7.0::float-64-big, 8.0::float-64-big, 9.0::float-64-big>>

      assert {:ok, {:movement, 42, 1000, {1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}, {7.0, 8.0, 9.0}}} ==
               Codec.decode(msg)
    end

    test "decodes movement with zero velocity" do
      msg =
        <<0x01, 1::64-big, 500::64-big,
          100.5::float-64-big, 200.5::float-64-big, 90.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

      assert {:ok, {:movement, 1, 500, {100.5, 200.5, 90.0}, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}}} ==
               Codec.decode(msg)
    end

    test "decodes movement with negative coordinates" do
      msg =
        <<0x01, 99::64-big, 0::64-big,
          -1.5::float-64-big, -2.5::float-64-big, -3.5::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

      {:ok, {:movement, 99, 0, {lx, ly, lz}, _, _}} = Codec.decode(msg)
      assert_in_delta lx, -1.5, 0.0001
      assert_in_delta ly, -2.5, 0.0001
      assert_in_delta lz, -3.5, 0.0001
    end
  end

  describe "decode enter_scene" do
    test "decodes enter_scene" do
      msg = <<0x02, 12345::64-big>>
      assert {:ok, {:enter_scene, 12345}} == Codec.decode(msg)
    end
  end

  describe "decode time_sync" do
    test "decodes time_sync" do
      assert {:ok, :time_sync} == Codec.decode(<<0x03>>)
    end
  end

  describe "decode heartbeat" do
    test "decodes heartbeat with timestamp" do
      ts = :os.system_time(:millisecond)
      msg = <<0x04, ts::64-big>>
      assert {:ok, {:heartbeat, ts}} == Codec.decode(msg)
    end
  end

  describe "decode auth_request" do
    test "decodes auth_request with username and code" do
      username = "player1"
      code = "abc123"
      ulen = byte_size(username)
      clen = byte_size(code)

      msg =
        <<0x05, ulen::16-big, username::binary, clen::16-big, code::binary>>

      assert {:ok, {:auth_request, "player1", "abc123"}} == Codec.decode(msg)
    end

    test "decodes auth_request with unicode username" do
      username = "玩家一"
      code = "token"
      ulen = byte_size(username)
      clen = byte_size(code)

      msg =
        <<0x05, ulen::16-big, username::binary, clen::16-big, code::binary>>

      assert {:ok, {:auth_request, ^username, "token"}} = Codec.decode(msg)
    end

    test "decodes auth_request with empty code" do
      username = "test"
      ulen = byte_size(username)

      msg = <<0x05, ulen::16-big, username::binary, 0::16-big>>
      assert {:ok, {:auth_request, "test", ""}} == Codec.decode(msg)
    end
  end

  describe "decode errors" do
    test "returns error for unknown message type" do
      assert {:error, {:unknown_message_type, 0xFF}} == Codec.decode(<<0xFF, 1, 2, 3>>)
    end

    test "returns error for empty binary" do
      assert {:error, :invalid_message} == Codec.decode(<<>>)
    end

    test "returns error for truncated movement" do
      # Movement needs 89 bytes, only provide 10
      assert {:error, {:unknown_message_type, 0x01}} ==
               Codec.decode(<<0x01, 42::64-big>>)
    end
  end

  # ═══════════════════════════════════════════════════════════
  # Server → Client: Encode tests
  # ═══════════════════════════════════════════════════════════

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
    test "encodes success with location" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :ok, 5, {1.0, 2.0, 3.0}})

      assert <<0x84, 5::64-big, 0x00,
               1.0::float-64-big, 2.0::float-64-big, 3.0::float-64-big>> == bin
    end

    test "encodes error" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :error, 5})
      assert <<0x84, 5::64-big, 0x01>> == bin
    end
  end

  describe "encode movement_result" do
    test "encodes movement ack with position" do
      {:ok, bin} = Codec.encode({:movement_result, :ok, 10, 42, {1.5, 2.5, 3.5}})

      assert <<0x80, 10::64-big, 0x00,
               42::64-big,
               1.5::float-64-big, 2.5::float-64-big, 3.5::float-64-big>> == bin
    end
  end

  describe "encode broadcast messages" do
    test "encodes player_enter" do
      {:ok, bin} = Codec.encode({:player_enter, 100, {10.0, 20.0, 30.0}})

      assert <<0x81, 100::64-big,
               10.0::float-64-big, 20.0::float-64-big, 30.0::float-64-big>> == bin
    end

    test "encodes player_leave" do
      {:ok, bin} = Codec.encode({:player_leave, 100})
      assert <<0x82, 100::64-big>> == bin
    end

    test "encodes player_move" do
      {:ok, bin} = Codec.encode({:player_move, 55, {1.0, 2.0, 3.0}})

      assert <<0x83, 55::64-big,
               1.0::float-64-big, 2.0::float-64-big, 3.0::float-64-big>> == bin
    end
  end

  describe "encode time_sync and heartbeat" do
    test "encodes time_sync_reply" do
      {:ok, bin} = Codec.encode(:time_sync_reply)
      assert <<0x85>> == bin
    end

    test "encodes heartbeat_reply" do
      {:ok, bin} = Codec.encode({:heartbeat_reply, 999})
      assert <<0x86, 999::64-big>> == bin
    end
  end

  describe "encode errors" do
    test "returns error for unknown message" do
      assert {:error, :unknown_message} == Codec.encode({:nonexistent, 1, 2})
    end
  end

  # ═══════════════════════════════════════════════════════════
  # Roundtrip tests: encode → decode for bidirectional messages
  # ═══════════════════════════════════════════════════════════

  describe "encode → decode roundtrip" do
    test "movement roundtrip from client perspective" do
      # Client encodes, server decodes
      original = {:movement, 42, 1000, {1.5, 2.5, 3.5}, {4.0, 5.0, 6.0}, {7.0, 8.0, 9.0}}

      # Manually build what the client would send
      {_, cid, ts, {lx, ly, lz}, {vx, vy, vz}, {ax, ay, az}} = original

      client_msg =
        <<0x01, cid::64-big, ts::64-big,
          lx::float-64-big, ly::float-64-big, lz::float-64-big,
          vx::float-64-big, vy::float-64-big, vz::float-64-big,
          ax::float-64-big, ay::float-64-big, az::float-64-big>>

      assert {:ok, ^original} = Codec.decode(client_msg)
    end

    test "broadcast messages encode to correct binary size" do
      {:ok, enter} = Codec.encode({:player_enter, 1, {0.0, 0.0, 0.0}})
      # 1 (type) + 8 (cid) + 24 (3 * float64) = 33 bytes
      assert byte_size(enter) == 33

      {:ok, leave} = Codec.encode({:player_leave, 1})
      # 1 (type) + 8 (cid) = 9 bytes
      assert byte_size(leave) == 9

      {:ok, move} = Codec.encode({:player_move, 1, {0.0, 0.0, 0.0}})
      # 1 (type) + 8 (cid) + 24 (3 * float64) = 33 bytes
      assert byte_size(move) == 33
    end
  end
end
