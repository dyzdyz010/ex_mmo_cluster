defmodule AuthServerWeb.GameWebSocketTest do
  use ExUnit.Case, async: true

  test "pushes gate iodata as one binary websocket frame" do
    assert {:push, {:binary, <<0x62, 1, 2, 3>>}, %{}} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, [<<0x62>>, <<1, 2, 3>>]},
               %{}
             )
  end
end
