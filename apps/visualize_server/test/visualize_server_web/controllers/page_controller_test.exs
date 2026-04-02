defmodule VisualizeServerWeb.PageControllerTest do
  use VisualizeServerWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "Visualize Server"
  end
end
