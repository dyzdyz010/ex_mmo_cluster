defmodule AuthServerWeb.GameWebSocketTest do
  use ExUnit.Case, async: true

  test "pushes realtime gate iodata as one binary websocket frame" do
    assert {:push, {:binary, <<0x6D, 1, 2, 3>>}, %{}} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, [<<0x6D>>, <<1, 2, 3>>]},
               %{}
             )
  end

  test "queues bulk voxel frames so later realtime frames can bypass them" do
    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, [<<0x62>>, <<1, 2, 3>>]},
               %{}
             )

    assert {:push, {:binary, <<0x6D, 9, 8, 7>>}, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, [<<0x6D>>, <<9, 8, 7>>]},
               state
             )

    assert {:push, {:binary, <<0x62, 1, 2, 3>>}, state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_bulk_drain, state)

    assert {:ok, _state} = AuthServerWeb.GameWebSocket.handle_info(:gate_ws_bulk_drain, state)
  end

  test "preserves movement acks as ordered realtime payloads under normal load" do
    first_ack = <<0x8B, 1, 0, 0, 0, 1>>
    second_ack = <<0x8B, 1, 0, 0, 0, 2>>

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, first_ack},
               %{}
             )

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, second_ack},
               state
             )

    assert {:push, {:binary, ^first_ack}, state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_realtime_drain, state)

    assert {:push, {:binary, ^second_ack}, state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_realtime_drain, state)

    assert {:ok, _state} = AuthServerWeb.GameWebSocket.handle_info(:gate_ws_realtime_drain, state)
  end

  test "drops oldest realtime payloads only when the realtime queue is bounded" do
    first_ack = <<0x8B, 1, 0, 0, 0, 1>>
    second_ack = <<0x8B, 1, 0, 0, 0, 2>>
    third_ack = <<0x8B, 1, 0, 0, 0, 3>>

    previous = System.get_env("AUTH_GAME_WS_REALTIME_MAX_QUEUE")
    System.put_env("AUTH_GAME_WS_REALTIME_MAX_QUEUE", "2")

    try do
      assert {:ok, state} =
               AuthServerWeb.GameWebSocket.handle_info(
                 {:gate_ws_send, first_ack},
                 %{}
               )

      assert {:ok, state} =
               AuthServerWeb.GameWebSocket.handle_info(
                 {:gate_ws_send, second_ack},
                 state
               )

      assert {:ok, state} =
               AuthServerWeb.GameWebSocket.handle_info(
                 {:gate_ws_send, third_ack},
                 state
               )

      assert {:push, {:binary, ^second_ack}, state} =
               AuthServerWeb.GameWebSocket.handle_info(:gate_ws_realtime_drain, state)

      assert {:push, {:binary, ^third_ack}, state} =
               AuthServerWeb.GameWebSocket.handle_info(:gate_ws_realtime_drain, state)

      assert {:ok, _state} =
               AuthServerWeb.GameWebSocket.handle_info(:gate_ws_realtime_drain, state)
    after
      case previous do
        nil -> System.delete_env("AUTH_GAME_WS_REALTIME_MAX_QUEUE")
        value -> System.put_env("AUTH_GAME_WS_REALTIME_MAX_QUEUE", value)
      end
    end
  end

  test "coalesces field region snapshots by region identity on the visual lane" do
    key = <<1::64, 0::32-signed, 0::32-signed, 0::32-signed, 44::64>>
    first_snapshot = <<0x73>> <> key <> <<1::32, 0::8, 0::16>>
    second_snapshot = <<0x73>> <> key <> <<2::32, 0::8, 0::16>>

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, first_snapshot},
               %{}
             )

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, second_snapshot},
               state
             )

    assert {:push, {:binary, ^second_snapshot}, state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_visual_drain, state)

    assert {:ok, _state} = AuthServerWeb.GameWebSocket.handle_info(:gate_ws_visual_drain, state)
  end

  test "movement acks drain before queued field region snapshots" do
    key = <<1::64, 0::32-signed, 0::32-signed, 0::32-signed, 44::64>>
    snapshot = <<0x73>> <> key <> <<1::32, 0::8, 0::16>>
    ack = <<0x8B, 1, 0, 0, 0, 1>>

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, snapshot},
               %{}
             )

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, ack},
               state
             )

    assert {:push, {:binary, ^ack}, state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_realtime_drain, state)

    assert {:push, {:binary, ^snapshot}, _state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_visual_drain, state)
  end

  test "queued field region snapshots wait when a movement ack is ready" do
    key = <<1::64, 0::32-signed, 0::32-signed, 0::32-signed, 44::64>>
    snapshot = <<0x73>> <> key <> <<1::32, 0::8, 0::16>>
    ack = <<0x8B, 1, 0, 0, 0, 1>>

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, snapshot},
               %{}
             )

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, ack},
               state
             )

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_visual_drain, state)

    assert {:push, {:binary, ^ack}, state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_realtime_drain, state)

    assert {:push, {:binary, ^snapshot}, _state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_visual_drain, state)
  end

  test "schedules bulk drain for initialized websocket state" do
    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, [<<0x62>>, <<1, 2, 3>>]},
               %{connection_pid: self()}
             )

    assert is_reference(state.gate_ws_bulk_drain_ref)
    assert_receive :gate_ws_bulk_drain, 50
  end

  test "schedules realtime drain for initialized websocket state" do
    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, <<0x8B, 1, 0, 0, 0, 1>>},
               %{connection_pid: self()}
             )

    assert is_reference(state.gate_ws_realtime_drain_ref)
    assert_receive :gate_ws_realtime_drain, 50
  end

  test "schedules visual drain for initialized websocket state" do
    key = <<1::64, 0::32-signed, 0::32-signed, 0::32-signed, 44::64>>
    snapshot = <<0x73>> <> key <> <<1::32, 0::8, 0::16>>

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, snapshot},
               %{connection_pid: self()}
             )

    assert is_reference(state.gate_ws_visual_drain_ref)
    assert_receive :gate_ws_visual_drain, 350
  end
end
