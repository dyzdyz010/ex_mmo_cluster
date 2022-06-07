defmodule WorldServer.World do
  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{
      online_players: %{}
    }, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state}
  end
end
