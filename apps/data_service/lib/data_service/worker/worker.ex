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
    account =
      if Application.get_env(:data_service, :use_ecto, false) do
        DataService.Repo.get_by(DataService.Schema.Account, email: email)
      else
        Memento.Query.read(DataInit.TableDef.User.Account, email)
      end

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

    if Application.get_env(:data_service, :use_ecto, false) do
      register_account_ecto(uid, username, password, email, phone)
    else
      register_account_mnesia(uid, username, password, email, phone)
    end
  end

  defp register_account_ecto(uid, username, password, email, phone) do
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

  defp register_account_mnesia(uid, username, password, email, phone) do
    case DataService.DbOps.UserAccount.check_duplicate(username, email, phone) do
      {:duplicate, duplicate_list} ->
        {:err, {:duplicate, duplicate_list}}

      _ ->
        {:ok, hashed_password, salt} = hash_password(password)

        result =
          Memento.transaction!(fn ->
            Memento.Query.write(%Tables.User.Account{
              id: uid,
              username: username,
              password: hashed_password,
              salt: salt,
              email: email,
              phone: phone
            })
          end)

        # Dual-write to PostgreSQL (non-fatal)
        try do
          DataService.Repo.insert(
            %DataService.Schema.Account{
              id: uid,
              username: username,
              password: hashed_password,
              salt: salt,
              email: email,
              phone: phone
            },
            on_conflict: :nothing
          )
        rescue
          e -> Logger.error("Dual-write to PostgreSQL failed: #{inspect(e)}")
        end

        result
    end
  end

  defp hash_password(password) do
    salt = Bcrypt.Base.gen_salt()
    hashed_password = Bcrypt.Base.hash_password(password, salt)
    {:ok, hashed_password, salt}
  end
end
