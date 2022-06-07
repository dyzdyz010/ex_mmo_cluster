defmodule DataService.Dispatcher do
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_init_args) do
    {:ok, %{}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("New agent conneddddddddddddddcted.}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:register_account, username, password, email, phone}, _from, state) do
    acc = :poolboy.transaction(:worker, fn pid ->
      try do
        GenServer.call(pid, {:register_account, username, password, email, phone})
      catch
        e, r -> IO.inspect("poolboy transaction caught error: #{inspect(e)}, #{inspect(r)}")
        :err
      end
    end)
    {:reply, acc, state}
  end
end