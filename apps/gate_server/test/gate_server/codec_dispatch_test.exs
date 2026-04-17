defmodule GateServer.CodecDispatchTest do
  use ExUnit.Case, async: true

  alias GateServer.Codec

  @moduledoc """
  Tests for codec-facing request/response layouts.

  Focus:
  - client message types stay in the codec range (0x01–0x7F)
  - server replies stay in the server range (0x80+)
  - request-id-aware request layouts and reply echoes remain consistent
  """

  describe "protocol routing by first byte" do
    test "movement input message (0x01) is in codec range" do
      msg =
        <<0x01, 9::32-big, 100::32-big, 16::16-big, 0.0::float-32-big, 0.0::float-32-big,
          1.0::float-32-big, 0::16-big>>

      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:movement_input, %{seq: 9, client_tick: 100}}} = Codec.decode(msg)
    end

    test "enter_scene message (0x02) is in codec range" do
      msg = <<0x02, 7::64-big, 42::64-big>>
      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:enter_scene, 42, 7}} = Codec.decode(msg)
    end

    test "time_sync message (0x03) is in codec range" do
      msg = <<0x03, 8::64-big, 999::64-big>>
      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:time_sync, 8, 999}} = Codec.decode(msg)
    end

    test "heartbeat message (0x04) is in codec range" do
      msg = <<0x04, 999::64-big>>
      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:heartbeat, 999}} = Codec.decode(msg)
    end

    test "auth_request with request_id is in codec range" do
      msg = <<0x05, 7::64-big, 4::16-big, "test", 5::16-big, "token">>
      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:auth_request, "test", "token", 7}} = Codec.decode(msg)
    end

    test "fast-lane request is in codec range" do
      msg = <<0x06, 7::64-big>>
      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:fast_lane_request, 7}} = Codec.decode(msg)
    end

    test "chat_say is in codec range" do
      msg = <<0x08, 11::64-big, 2::16-big, "hi">>
      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:chat_say, "hi", 11}} = Codec.decode(msg)
    end

    test "skill_cast is in codec range" do
      msg =
        <<0x09, 12::64-big, 1::16-big, 0::8, -1::64-big-signed, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big>>

      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F

      assert {:ok, {:skill_cast, %{skill_id: 1, request_id: 12, target_kind: :auto}}} =
               Codec.decode(msg)
    end
  end

  describe "server response encoding for codec dispatch" do
    test "movement_ack encodes correctly for send back" do
      {:ok, bin} =
        Codec.encode(
          {:movement_ack, 9, 12, 42, {1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}, {0.0, 0.0, 0.0}, :grounded,
           0}
        )

      <<type::8, _::binary>> = bin
      assert type >= 0x80
    end

    test "enter_scene_result success encodes with location" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :ok, 7, {100.0, 200.0, 90.0}})

      <<type::8, packet_id::64, status::8, x::float-64-big, y::float-64-big, z::float-64-big>> =
        bin

      assert type == 0x84
      assert packet_id == 7
      assert status == 0x00
      assert_in_delta x, 100.0, 0.001
      assert_in_delta y, 200.0, 0.001
      assert_in_delta z, 90.0, 0.001
    end

    test "time_sync_reply carries correlation and timing fields" do
      {:ok, bin} = Codec.encode({:time_sync_reply, 44, 1000, 1100, 1200})
      assert bin == <<0x85, 44::64-big, 1000::64-big, 1100::64-big, 1200::64-big>>
    end

    test "fast-lane bootstrap result is a server-range reply" do
      {:ok, bin} = Codec.encode({:fast_lane_result, :ok, 9, 29001, "ticket"})
      <<type::8, _::binary>> = bin
      assert type == 0x87
    end

    test "chat_message is a server-range reply" do
      {:ok, bin} = Codec.encode({:chat_message, 42, "tester", "hi"})
      <<type::8, _::binary>> = bin
      assert type == 0x89
    end

    test "skill_event is a server-range reply" do
      {:ok, bin} = Codec.encode({:skill_event, 42, 1, {0.0, 0.0, 0.0}})
      <<type::8, _::binary>> = bin
      assert type == 0x8A
    end
  end

  describe "end-to-end codec flow" do
    test "movement input and ack preserve sequencing metadata" do
      client_msg =
        <<0x01, 73::32-big, 1000::32-big, 33::16-big, 1.0::float-32-big, 0.0::float-32-big,
          1.0::float-32-big, 0::16-big>>

      assert {:ok, {:movement_input, %{seq: 73, client_tick: 1000}}} = Codec.decode(client_msg)

      {:ok, response} =
        Codec.encode(
          {:movement_ack, 73, 1000, 42, {100.0, 200.0, 90.0}, {1.0, 0.0, 0.0}, {0.0, 0.0, 0.0},
           :grounded, 0}
        )

      assert <<0x8B, 73::32-big, 1000::32-big, 42::64-big, _::binary>> = response
    end

    test "auth flow echoes request_id in result" do
      client_msg = <<0x05, 99::64-big, 4::16-big, "user", 5::16-big, "token">>

      {:ok, {:auth_request, "user", "token", request_id}} = Codec.decode(client_msg)
      assert request_id == 99

      {:ok, response} = Codec.encode({:result, :ok, request_id})
      assert <<0x80, 99::64-big, 0x00>> = response
    end
  end
end
