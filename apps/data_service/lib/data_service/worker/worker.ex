defmodule DataService.Worker do
  use GenServer
  require Logger

  def start_link(agent, opts \\ []) do
    GenServer.start_link(__MODULE__, agent, opts)
  end

  @impl true
  def init(agent) do
    Logger.debug("New agent connected.")
    {:ok, %{agent: agent}}
  end

  ############ CRUD methods ####################

  @impl true
  def handle_call({:account_by_email, email}, _from, state) do
    account = Memento.Query.read(DataInit.TableDef.User.Account, email)
    {:reply, {:ok, account}, state}
  end
end
