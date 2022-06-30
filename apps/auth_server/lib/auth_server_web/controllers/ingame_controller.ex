defmodule AuthServerWeb.IngameController do
  use AuthServerWeb, :controller

  def login(conn, _params) do
    render(conn, "login.html")
  end
end
