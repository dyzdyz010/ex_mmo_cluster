defmodule VisualizeServerWeb.Layouts do
  use VisualizeServerWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, default: %{}

  def flash_group(assigns) do
    ~H"""
    <div class="fixed right-4 top-4 z-50 space-y-2">
      <p
        :if={info = Phoenix.Flash.get(@flash, :info)}
        class="rounded-lg border border-cyan-300/30 bg-cyan-400/15 px-4 py-3 text-sm text-cyan-100 shadow-lg shadow-cyan-950/30"
      >
        {info}
      </p>
      <p
        :if={error = Phoenix.Flash.get(@flash, :error)}
        class="rounded-lg border border-rose-300/30 bg-rose-400/15 px-4 py-3 text-sm text-rose-100 shadow-lg shadow-rose-950/30"
      >
        {error}
      </p>
    </div>
    """
  end
end
