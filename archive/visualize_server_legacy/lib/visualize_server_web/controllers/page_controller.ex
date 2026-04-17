defmodule VisualizeServerWeb.PageController do
  use VisualizeServerWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
