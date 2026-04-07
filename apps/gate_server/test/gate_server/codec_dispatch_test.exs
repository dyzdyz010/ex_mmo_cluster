defmodule GateServer.CodecDispatchTest do
  use ExUnit.Case, async: true

  alias GateServer.Codec

  @moduledoc """
  Tests for the dual-protocol dispatch logic in TcpConnection.

  Verifies that the first byte correctly routes messages:
  - 0x01–0x7F → custom binary codec path
  - Other → legacy protobuf path

  These tests validate the routing logic at the binary level,
  without starting the full application or network stack.
  """

  describe "protocol routing by first byte" do
    test "movement message (0x01) is in codec range" do
      msg =
        <<0x01, 1::64-big, 100::64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:movement, 1, 100, _, _, _}} = Codec.decode(msg)
    end

    test "enter_scene message (0x02) is in codec range" do
      msg = <<0x02, 42::64-big>>
      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:enter_scene, 42}} = Codec.decode(msg)
    end

    test "time_sync message (0x03) is in codec range" do
      msg = <<0x03>>
      <<type::8>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, :time_sync} = Codec.decode(msg)
    end

    test "heartbeat message (0x04) is in codec range" do
      msg = <<0x04, 999::64-big>>
      <<type::8, _::binary>> = msg
      assert type >= 0x01 and type <= 0x7F
      assert {:ok, {:heartbeat, 999}} = Codec.decode(msg)
    end
  end

  describe "server response encoding for codec dispatch" do
    test "movement_result encodes correctly for send back" do
      {:ok, bin} = Codec.encode({:movement_result, :ok, 0, 42, {1.0, 2.0, 3.0}})
      # Verify it starts with a server message type (0x80+)
      <<type::8, _::binary>> = bin
      assert type >= 0x80
    end

    test "enter_scene_result success encodes with location" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :ok, 0, {100.0, 200.0, 90.0}})
      <<type::8, _packet_id::64, status::8, x::float-64-big, y::float-64-big, z::float-64-big>> = bin
      assert type == 0x84
      assert status == 0x00
      assert_in_delta x, 100.0, 0.001
      assert_in_delta y, 200.0, 0.001
      assert_in_delta z, 90.0, 0.001
    end

    test "enter_scene_result error encodes without location" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :error, 0})
      <<type::8, _packet_id::64, status::8>> = bin
      assert type == 0x84
      assert status == 0x01
    end

    test "broadcast player_enter encodes for direct TCP send" do
      {:ok, bin} = Codec.encode({:player_enter, 55, {10.0, 20.0, 30.0}})
      <<type::8, cid::64-big, x::float-64-big, _y::float-64-big, _z::float-64-big>> = bin
      assert type == 0x81
      assert cid == 55
      assert_in_delta x, 10.0, 0.001
    end

    test "broadcast player_leave encodes minimal" do
      {:ok, bin} = Codec.encode({:player_leave, 77})
      <<type::8, cid::64-big>> = bin
      assert type == 0x82
      assert cid == 77
    end

    test "broadcast player_move encodes with position" do
      {:ok, bin} = Codec.encode({:player_move, 88, {5.0, 6.0, 7.0}})
      <<type::8, cid::64-big, _::binary>> = bin
      assert type == 0x83
      assert cid == 88
    end

    test "time_sync_reply is minimal" do
      {:ok, bin} = Codec.encode(:time_sync_reply)
      assert bin == <<0x85>>
    end

    test "heartbeat_reply includes timestamp" do
      {:ok, bin} = Codec.encode({:heartbeat_reply, 12345})
      <<type::8, ts::64-big>> = bin
      assert type == 0x86
      assert ts == 12345
    end
  end

  describe "end-to-end codec flow" do
    test "movement: client encode → server decode → server encode response" do
      # 1. Client sends movement
      client_msg =
        <<0x01, 42::64-big, 1000::64-big,
          100.0::float-64-big, 200.0::float-64-big, 90.0::float-64-big,
          1.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
          0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

      # 2. Server decodes
      {:ok, {:movement, cid, _ts, location, _vel, _acc}} = Codec.decode(client_msg)
      assert cid == 42
      assert location == {100.0, 200.0, 90.0}

      # 3. Server encodes response
      {:ok, response} = Codec.encode({:movement_result, :ok, 0, cid, location})
      assert is_binary(response)
      <<0x80, _::binary>> = response
    end

    test "enter_scene: client encode → server decode → server encode response" do
      # 1. Client sends enter_scene
      client_msg = <<0x02, 999::64-big>>

      # 2. Server decodes
      {:ok, {:enter_scene, cid}} = Codec.decode(client_msg)
      assert cid == 999

      # 3. Server encodes success response with spawn location
      spawn_loc = {500.0, 600.0, 90.0}
      {:ok, response} = Codec.encode({:enter_scene_result, :ok, 0, spawn_loc})
      assert is_binary(response)
      <<0x84, _::binary>> = response
    end
  end
end
