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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  def init(_opts) do
    {:ok, %{}}
  end

  def handle_info({:tcp, socket, data}, state) do
    Logger.debug(data)
    result = "You'v typed: #{data}"
    :gen_tcp.send(socket, result)
    {:noreply, state}
  end

  def handle_call({:login, credentials}, _from, state) do
    if credentials.username == "dyz" and credentials.password == "duyizhuo" do
      {:reply, {:ok, "some agent"}, state}
    else
      {:reply, {:error, :mismatch}, state}
    end
  end
end
