defmodule AuthServerWeb.IngameHTML do
  @moduledoc """
  HTML templates for the in-game login flow.
  """

  use AuthServerWeb, :html

  embed_templates "ingame_html/*"
end
