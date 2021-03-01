defmodule GameServerManager.Monitor do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    {:ok, %{
      game_server_list: []
    }}
  end
end
