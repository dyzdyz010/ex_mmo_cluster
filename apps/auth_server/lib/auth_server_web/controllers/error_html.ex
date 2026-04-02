defmodule AuthServerWeb.ErrorHTML do
  use AuthServerWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
