defmodule AuthServerWeb.PageController do
  use AuthServerWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
