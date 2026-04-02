defmodule VisualizeServerWeb.SceneLiveTest do
  use VisualizeServerWeb.ConnCase, async: true

  test "renders scene dashboard", %{conn: conn} do
    conn = get(conn, "/scene")
    html = html_response(conn, 200)

    assert html =~ "Scene Visualizer"
    assert html =~ "scene1@127.0.0.1"
  end
end
