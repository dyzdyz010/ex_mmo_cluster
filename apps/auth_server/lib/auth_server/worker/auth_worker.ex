defmodule AuthServer.AuthWorker do
  @behaviour GenServer
  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def init(_args) do
    {:ok, %{}}
  end

  def handle_call({:login, credential}, _from, state) do
    Logger.debug("User login: #{credential.username}, #{credential.password}")
    {:reply, {:ok, nil}, state}
  end
end
