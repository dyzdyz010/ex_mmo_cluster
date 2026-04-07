defmodule DataService.Worker do
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_init_args) do
    {:ok, %{}}
  end

  ############ CRUD methods ####################

  @impl true
  def handle_call({:account_by_email, email}, _from, state) do
    account = DataService.Repo.get_by(DataService.Schema.Account, email: email)
    {:reply, {:ok, account}, state}
  end

  @impl true
  def handle_call({:register_account, username, password, email, phone}, _from, state) do
    acc = register_account(username, password, email, phone)
    {:reply, acc, state}
  end

  defp register_account(username, password, email, phone) do
    uid = DataService.UidGenerator.generate()

    case DataService.DbOps.UserAccount.check_duplicate_ecto(username, email, phone) do
      {:duplicate, duplicate_list} ->
        {:err, {:duplicate, duplicate_list}}

      :ok ->
        {:ok, hashed_password, salt} = hash_password(password)

        case DataService.Repo.insert(%DataService.Schema.Account{
               id: uid,
               username: username,
               password: hashed_password,
               salt: salt,
               email: email,
               phone: phone
             }) do
          {:ok, account} -> account
          {:error, changeset} -> {:err, {:insert_failed, changeset}}
        end
    end
  end

  defp hash_password(password) do
    salt = Bcrypt.Base.gen_salt()
    hashed_password = Bcrypt.Base.hash_password(password, salt)
    {:ok, hashed_password, salt}
  end
end
