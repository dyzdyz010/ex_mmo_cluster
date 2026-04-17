defmodule AuthServerWeb.PageController do
  use AuthServerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
