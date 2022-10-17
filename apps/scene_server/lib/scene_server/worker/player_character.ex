defmodule SceneServer.PlayerCharacter do
  use GenServer

  require Logger

  def start_link(socket, opts \\ []) do
    GenServer.start_link(__MODULE__, socket, opts)
  end

  @impl true
  def init(socket) do
    # :pg.start_link(@scope)
    # :pg.join(@scope, @topic, self())
    Logger.debug("New client connected.")
    {:ok, %{socket: socket, agent: nil, status: :world, player_data: %{
      cid: 0,
      movement: %{
        position: {0.0, 0.0, 0.0},
        velocity: {0.0, 0.0, 0.0}
      }
    }}}
  end
end
