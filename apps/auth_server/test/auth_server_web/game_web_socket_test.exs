defmodule AuthServerWeb.GameWebSocketTest do
  @moduledoc "只测试：纯 WebSocket frame 适配回调，不启动或注入已鉴权会话。"
  use ExUnit.Case, async: true

  test "pushes gate iodata as one binary websocket frame" do
    assert {:push, {:binary, <<0x62, 1, 2, 3>>}, %{}} =
             AuthServerWeb.GameWebSocket.handle_info(
               {:gate_ws_send, [<<0x62>>, <<1, 2, 3>>]},
               %{}
             )
  end
end
