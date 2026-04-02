defmodule AuthServerWeb.PageControllerTest do
  use AuthServerWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "Auth Server"
  end
end
