defmodule AuthServerWeb.GameWebSocketTest do
  use ExUnit.Case, async: false

  setup do
    env_names = [
      "AUTH_GAME_WS_REALTIME_DRAIN_INTERVAL_MS",
      "AUTH_GAME_WS_REALTIME_MAX_QUEUE"
    ]

    previous = Map.new(env_names, &{&1, System.get_env(&1)})
    Enum.each(env_names, &System.delete_env/1)

    on_exit(fn -> restore_env(previous) end)
    :ok
  end

  test "pushes movement acks immediately as binary websocket frames" do
    ack = <<0x8B, 1, 0, 0, 0, 1>>

    assert {:push, {:binary, ^ack}, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, [<<0x8B>>, <<1, 0, 0, 0, 1>>]},
               %{}
             )

    assert :queue.is_empty(state.gate_ws_realtime_queue)
    assert state.gate_ws_realtime_drain_ref == nil
  end

  test "queues bulk voxel frames so later realtime frames can bypass them" do
    ack = <<0x8B, 1, 0, 0, 0, 9>>

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, [<<0x62>>, <<1, 2, 3>>]},
               %{}
             )

    assert {:push, {:binary, ^ack}, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, ack},
               state
             )

    assert {:push, {:binary, <<0x62, 1, 2, 3>>}, state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_bulk_drain, state)

    assert {:ok, _state} = AuthServerWeb.GameWebSocket.handle_info(:gate_ws_bulk_drain, state)
  end

  test "preserves movement acks as ordered immediate realtime payloads under normal load" do
    first_ack = <<0x8B, 1, 0, 0, 0, 1>>
    second_ack = <<0x8B, 1, 0, 0, 0, 2>>

    assert {:push, {:binary, ^first_ack}, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, first_ack},
               %{}
             )

    assert {:push, {:binary, ^second_ack}, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, second_ack},
               state
             )

    assert {:ok, _state} = AuthServerWeb.GameWebSocket.handle_info(:gate_ws_realtime_drain, state)
  end

  test "drops oldest realtime payloads only when the realtime queue is bounded" do
    first_ack = <<0x8B, 1, 0, 0, 0, 1>>
    second_ack = <<0x8B, 1, 0, 0, 0, 2>>
    third_ack = <<0x8B, 1, 0, 0, 0, 3>>

    with_env(
      %{
        "AUTH_GAME_WS_REALTIME_DRAIN_INTERVAL_MS" => "1",
        "AUTH_GAME_WS_REALTIME_MAX_QUEUE" => "2"
      },
      fn ->
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
      end
    )
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

  test "movement acks push before queued field region snapshots" do
    key = <<1::64, 0::32-signed, 0::32-signed, 0::32-signed, 44::64>>
    snapshot = <<0x73>> <> key <> <<1::32, 0::8, 0::16>>
    ack = <<0x8B, 1, 0, 0, 0, 1>>

    assert {:ok, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, snapshot},
               %{}
             )

    assert {:push, {:binary, ^ack}, state} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, ack},
               state
             )

    assert {:push, {:binary, ^snapshot}, _state} =
             AuthServerWeb.GameWebSocket.handle_info(:gate_ws_visual_drain, state)
  end

  test "queued field region snapshots wait when a delayed movement ack is ready" do
    key = <<1::64, 0::32-signed, 0::32-signed, 0::32-signed, 44::64>>
    snapshot = <<0x73>> <> key <> <<1::32, 0::8, 0::16>>
    ack = <<0x8B, 1, 0, 0, 0, 1>>

    with_env(%{"AUTH_GAME_WS_REALTIME_DRAIN_INTERVAL_MS" => "1"}, fn ->
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
    end)
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
    with_env(%{"AUTH_GAME_WS_REALTIME_DRAIN_INTERVAL_MS" => "1"}, fn ->
      assert {:ok, state} =
               AuthServerWeb.GameWebSocket.handle_info(
                 {:gate_ws_send, <<0x8B, 1, 0, 0, 0, 1>>},
                 %{connection_pid: self()}
               )

      assert is_reference(state.gate_ws_realtime_drain_ref)
      assert_receive :gate_ws_realtime_drain, 50
    end)
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

  defp with_env(overrides, fun) do
    previous = Map.new(Map.keys(overrides), &{&1, System.get_env(&1)})
    Enum.each(overrides, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      restore_env(previous)
    end
  end

  defp restore_env(previous) do
    Enum.each(previous, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
