defmodule AuthServerWeb.GameSocketController do
  @moduledoc """
  Browser-facing raw WebSocket upgrade endpoint for game traffic.

  This stays transport-thin: after the HTTP upgrade it hands the session over to
  `AuthServerWeb.GameWebSocket`, which bridges browser frames to `GateServer.WsConnection`.
  """

  use AuthServerWeb, :controller

  def upgrade(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> WebSockAdapter.upgrade(AuthServerWeb.GameWebSocket, %{},
      timeout: 120_000,
      max_frame_size: 64 * 1024,
      compress: false
    )
    |> halt()
  end
end
