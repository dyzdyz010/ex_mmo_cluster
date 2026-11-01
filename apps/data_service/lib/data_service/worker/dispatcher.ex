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
    Logger.debug("data_service_dispatcher_started")
    {:noreply, state}
  end

  @impl true
  def handle_call({:register_account, username, password, email, phone}, _from, state) do
    result =
      :poolboy.transaction(:worker, fn pid ->
        try do
          GenServer.call(pid, {:register_account, username, password, email, phone})
        catch
          kind, _reason ->
            # 失败原因里带着注册参数（含密码），日志只记失败类别。
            Logger.error("data_service_register_account_failed kind=#{kind}")
            :err
        end
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:account_by_username, username}, _from, state) do
    result =
      :poolboy.transaction(:worker, fn pid ->
        GenServer.call(pid, {:account_by_username, username})
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:character_owned_by_account, account_id, cid}, _from, state) do
    result =
      :poolboy.transaction(:worker, fn pid ->
        GenServer.call(pid, {:character_owned_by_account, account_id, cid})
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:upsert_dev_account, username}, _from, state) do
    result =
      :poolboy.transaction(:worker, fn pid ->
        GenServer.call(pid, {:upsert_dev_account, username})
      end)

    {:reply, result, state}
  end

  def regtest() do
    case GenServer.call(
           __MODULE__,
           {:register_account, "dyz", "duyizhuo", "dyzdyz010@sina.com", "13848584989"}
         ) do
      {:err, reason} ->
        Logger.error("Account creation failed: #{inspect(reason)}")

      acc ->
        Logger.debug("Account created: #{inspect(acc.id)}")
    end
  end
end
