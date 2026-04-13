defmodule GateServer.CodecTest do
  use ExUnit.Case, async: true

  alias GateServer.Codec

  describe "decode movement input" do
    test "decodes movement input with all fields" do
      msg =
        <<0x01, 55::32-big, 1000::32-big, 100::16-big, 1.0::float-32-big, 0.5::float-32-big,
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

    test "decodes movement input with zero direction" do
      msg =
        <<0x01, 1::32-big, 500::32-big, 33::16-big, 0.0::float-32-big, 0.0::float-32-big,
          1.0::float-32-big, 2::16-big>>

      assert {:ok,
              {:movement_input,
               %{
                 seq: 1,
                 client_tick: 500,
                 dt_ms: 33,
                 input_dir: {0.0, 0.0},
                 speed_scale: 1.0,
                 movement_flags: 2
               }}} == Codec.decode(msg)
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

    test "decodes skill_cast with request_id and skill id" do
      assert {:ok, {:skill_cast, 1, 43}} == Codec.decode(<<0x09, 43::64-big, 1::16-big>>)
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

    test "returns invalid_message for old movement layout" do
      assert {:error, :invalid_message} == Codec.decode(<<0x01, 42::64-big>>)
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
    test "encodes success with location" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :ok, 5, {1.0, 2.0, 3.0}})

      assert <<0x84, 5::64-big, 0x00, 1.0::float-64-big, 2.0::float-64-big, 3.0::float-64-big>> ==
               bin
    end

    test "encodes error" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :error, 5})
      assert <<0x84, 5::64-big, 0x01>> == bin
    end
  end

  describe "encode movement_ack" do
    test "encodes movement ack with authority fields" do
      {:ok, bin} =
        Codec.encode(
          {:movement_ack, 10, 77, 42, {1.5, 2.5, 3.5}, {4.5, 5.5, 6.5}, {0.1, 0.2, 0.3},
           :grounded, 3}
        )

      assert <<0x8B, 10::32-big, 77::32-big, 42::64-big, 1.5::float-64-big, 2.5::float-64-big,
               3.5::float-64-big, 4.5::float-64-big, 5.5::float-64-big, 6.5::float-64-big,
               0.1::float-64-big, 0.2::float-64-big, 0.3::float-64-big, 0::8, 3::32-big>> ==
               bin
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

    test "encodes player_move" do
      {:ok, bin} = Codec.encode({:player_move, 55, 9, {1.0, 2.0, 3.0}})

      assert <<0x83, 55::64-big, 9::64-big, 1.0::float-64-big, 2.0::float-64-big,
               3.0::float-64-big>> == bin
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
      {:ok, bin} = Codec.encode({:fast_lane_result, :ok, 5, 29001, "ticket"})
      assert <<0x87, 5::64-big, 0x00, 29001::16-big, 6::16-big, "ticket">> == bin
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
  end

  describe "encode errors" do
    test "returns error for unknown message" do
      assert {:error, :unknown_message} == Codec.encode({:nonexistent, 1, 2})
    end
  end

  describe "encode → decode roundtrip" do
    test "movement input roundtrip from client perspective" do
      client_msg =
        <<0x01, 9::32-big, 1000::32-big, 33::16-big, 1.0::float-32-big, 0.0::float-32-big,
          1.0::float-32-big, 2::16-big>>

      assert {:ok,
              {:movement_input,
               %{
                 seq: 9,
                 client_tick: 1000,
                 dt_ms: 33,
                 input_dir: {1.0, 0.0},
                 speed_scale: 1.0,
                 movement_flags: 2
               }}} = Codec.decode(client_msg)
    end

    test "broadcast messages encode to correct binary size" do
      {:ok, enter} = Codec.encode({:player_enter, 1, {0.0, 0.0, 0.0}})
      assert byte_size(enter) == 33

      {:ok, leave} = Codec.encode({:player_leave, 1})
      assert byte_size(leave) == 9

      {:ok, move} = Codec.encode({:player_move, 1, 1, {0.0, 0.0, 0.0}})
      assert byte_size(move) == 41
    end
  end
end
