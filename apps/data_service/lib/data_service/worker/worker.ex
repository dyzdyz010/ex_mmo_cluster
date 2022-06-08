defmodule DataService.Worker do
  use GenServer
  require Logger

  alias DataInit.TableDef, as: Tables

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_init_args) do
    # Logger.debug("New agent connected.")
    {:ok, %{}}
  end

  ############ CRUD methods ####################

  @impl true
  def handle_call({:account_by_email, email}, _from, state) do
    account = Memento.Query.read(DataInit.TableDef.User.Account, email)
    {:reply, {:ok, account}, state}
  end

  @impl true
  def handle_call({:register_account, username, password, email, phone}, _from, state) do
    acc = register_account(username, password, email, phone)
    {:reply, acc, state}
  end

  defp register_account(username, password, email, phone) do
    uid = DataService.UidGenerator.generate()
    Logger.debug("UID: #{inspect(uid)}")

    case DataService.DbOps.UserAccount.check_duplicate(username, email, phone) do
      {:duplicate, duplicate_list} ->
        {:err, {:duplicate, duplicate_list}}

      _ ->
        Memento.transaction!(fn ->
          Memento.Query.write(%Tables.User.Account{
            id: uid,
            username: username,
            password: password,
            email: email,
            phone: phone
          })
        end)
    end
  end
end
