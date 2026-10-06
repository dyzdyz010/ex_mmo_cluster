defmodule AuthServerWeb.ClientIpTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test
  alias AuthServerWeb.Plugs.ClientIp

  defp from(peer, header) do
    conn = %{conn(:get, "/auth/login") | remote_ip: peer}
    conn = if header, do: put_req_header(conn, "x-real-ip", header), else: conn
    ClientIp.call(conn, []).remote_ip
  end

  test "the same-host proxy's X-Real-IP becomes the request source" do
    assert from({127, 0, 0, 1}, "203.0.113.9") == {203, 0, 113, 9}
    assert from({0, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::7") == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 7}
  end

  test "a client cannot choose its own source by sending the header directly" do
    assert from({198, 51, 100, 4}, "203.0.113.9") == {198, 51, 100, 4}
    assert from({127, 0, 0, 1}, "not-an-address") == {127, 0, 0, 1}
    assert from({127, 0, 0, 1}, nil) == {127, 0, 0, 1}
  end
end
