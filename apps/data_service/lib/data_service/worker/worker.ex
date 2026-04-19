defmodule DataService.Worker do
  use GenServer
  require Logger

  alias DataService.Repo
  alias DataService.Schema.Account
  alias DataService.Schema.Character

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
    account = Repo.get_by(Account, email: email)
    {:reply, {:ok, account}, state}
  end

  @impl true
  def handle_call({:account_by_username, username}, _from, state) do
    account = Repo.get_by(Account, username: username)
    {:reply, {:ok, account}, state}
  end

  @impl true
  def handle_call({:character_owned_by_account, account_id, cid}, _from, state) do
    character = Repo.get_by(Character, id: cid, account: account_id)
    {:reply, {:ok, character}, state}
  end

  @impl true
  def handle_call({:register_account, username, password, email, phone}, _from, state) do
    acc = register_account(username, password, email, phone)
    {:reply, acc, state}
  end

  @impl true
  def handle_call({:upsert_dev_account, username}, _from, state) do
    {:reply, upsert_dev_account(username), state}
  end

  defp upsert_dev_account(username) do
    with %Account{} = account <-
           Repo.get_by(Account, username: username) || insert_dev_account(username),
         %Character{} = character <-
           Repo.get_by(Character, account: account.id) ||
             insert_dev_character(account.id, username) do
      {:ok, %{account: account, character: character}}
    else
      {:error, _} = error -> error
    end
  end

  defp insert_dev_account(username) do
    <<uid::64>> = DataService.UidGenerator.generate()
    {:ok, hashed, salt} = hash_password("dev_auto_login")

    case Repo.insert(%Account{
           id: uid,
           username: username,
           password: hashed,
           salt: salt,
           email: "#{username}@dev.local",
           phone: "dev-#{uid}"
         }) do
      {:ok, account} -> account
      {:error, changeset} -> {:error, {:insert_account_failed, changeset}}
    end
  end

  defp insert_dev_character(account_id, username) do
    <<cid::64>> = DataService.UidGenerator.generate()

    %Character{}
    |> Character.changeset(%{
      id: cid,
      account: account_id,
      name: "#{username}_char",
      title: "dev",
      base_attrs: %{},
      battle_attrs: %{},
      position: %{"x" => 1000.0, "y" => 1000.0, "z" => 100.0},
      hp: 500,
      sp: 100,
      mp: 100
    })
    |> Repo.insert()
    |> case do
      {:ok, character} -> character
      {:error, changeset} -> {:error, {:insert_character_failed, changeset}}
    end
  end

  defp register_account(username, password, email, phone) do
    <<uid::64>> = DataService.UidGenerator.generate()

    case DataService.DbOps.UserAccount.check_duplicate_ecto(username, email, phone) do
      {:duplicate, duplicate_list} ->
        {:err, {:duplicate, duplicate_list}}

      :ok ->
        {:ok, hashed_password, salt} = hash_password(password)

        case Repo.insert(%Account{
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
