defmodule VisualizeServerWeb.PageController do
  use VisualizeServerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
