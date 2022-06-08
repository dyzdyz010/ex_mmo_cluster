defmodule DataService.Dispatcher do
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
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
    result = :poolboy.transaction(:worker, fn pid ->
      try do
        GenServer.call(pid, {:register_account, username, password, email, phone})
      catch
        e, r -> IO.inspect("poolboy transaction caught error: #{inspect(e)}, #{inspect(r)}")
        :err
      end
    end)
    {:reply, result, state}
  end

  def regtest() do
    case GenServer.call(__MODULE__, {:register_account, "dyz", "duyizhuo", "dyzdyz010@sina.com", "13848584989"}) do
      {:err, reason} -> Logger.error("Accout creation failed: #{inspect(reason)}")
      acc ->
        Logger.debug("Account created: #{inspect(acc.id)}")
    end
  end
end
