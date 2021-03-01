defmodule BeaconServer.Worker do
  @behaviour GenServer

  @topic :beacon
  @scope :interface

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(init_arg) do
    {:ok, init_arg, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    :pg.start_link(@scope)
    :pg.join(@scope, @topic, self())
    {:noreply, state}
  end
end
