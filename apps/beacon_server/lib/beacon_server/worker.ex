defmodule BeaconServer.Worker do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  def init(init_arg) do
    {:ok, init_arg}
  end
end
