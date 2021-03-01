defmodule GateServer.Interface do
  use GenServer

  @topic :gate
  @scope :interface

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    :pg.start_link(@scope)
    :pg.join(@scope, @topic, self())
    {:noreply, state}
  end
end
