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
    test "movement message (0x01) is in codec range" do
      msg =
        <<0x01, 9::64-big, 1::64-big, 100::64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:movement, 1, 100, _, _, _, 9}} = Codec.decode(msg)
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
  end

  describe "server response encoding for codec dispatch" do
    test "movement_result encodes correctly for send back" do
      {:ok, bin} = Codec.encode({:movement_result, :ok, 9, 42, {1.0, 2.0, 3.0}})
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
  end

  describe "end-to-end codec flow" do
    test "movement request and response preserve request_id" do
      client_msg =
        <<0x01, 73::64-big, 42::64-big, 1000::64-big, 100.0::float-64-big, 200.0::float-64-big,
          90.0::float-64-big, 1.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

      {:ok, {:movement, cid, _ts, location, _vel, _acc, request_id}} = Codec.decode(client_msg)
      assert cid == 42
      assert request_id == 73
      assert location == {100.0, 200.0, 90.0}

      {:ok, response} = Codec.encode({:movement_result, :ok, request_id, cid, location})
      assert <<0x80, 73::64-big, 0x00, 42::64-big, _::binary>> = response
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
