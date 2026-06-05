defmodule DataService.Worker do
  use GenServer

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

  ############ Stateless public API ####################
  #
  # 这些操作本质上是无状态的 Ecto 调用：Repo 自带连接池负责并发，
  # 不需要再叠一层串行 GenServer。`AuthServer.Accounts` 直接在同
  # 一个 BEAM 内调用这些函数（auth 与 data_service 同节点共存），
  # 历史上的 `DataService.Dispatcher` + poolboy 中间层已删除。
  #
  # 下面的 GenServer `handle_call/3` 仅为既有 `DataService.WorkerTest`
  # 与潜在的进程内串行需求保留，全部委托到这里的纯函数实现。

  @spec account_by_email(String.t()) :: {:ok, Account.t() | nil}
  def account_by_email(email) do
    {:ok, Repo.get_by(Account, email: email)}
  end

  @spec account_by_username(String.t()) :: {:ok, Account.t() | nil}
  def account_by_username(username) do
    {:ok, Repo.get_by(Account, username: username)}
  end

  @spec character_owned_by_account(integer(), integer()) :: {:ok, Character.t() | nil}
  def character_owned_by_account(account_id, cid) do
    {:ok, Repo.get_by(Character, id: cid, account: account_id)}
  end

  @spec register_account(String.t(), String.t(), String.t(), String.t()) ::
          Account.t() | {:err, term()}
  def register_account(username, password, email, phone) do
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

  @spec upsert_dev_account(String.t()) ::
          {:ok, %{account: Account.t(), character: Character.t()}} | {:error, term()}
  def upsert_dev_account(username) do
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

  ############ GenServer CRUD callbacks (delegate to public API) ####

  @impl true
  def handle_call({:account_by_email, email}, _from, state) do
    {:reply, account_by_email(email), state}
  end

  @impl true
  def handle_call({:account_by_username, username}, _from, state) do
    {:reply, account_by_username(username), state}
  end

  @impl true
  def handle_call({:character_owned_by_account, account_id, cid}, _from, state) do
    {:reply, character_owned_by_account(account_id, cid), state}
  end

  @impl true
  def handle_call({:register_account, username, password, email, phone}, _from, state) do
    {:reply, register_account(username, password, email, phone), state}
  end

  @impl true
  def handle_call({:upsert_dev_account, username}, _from, state) do
    {:reply, upsert_dev_account(username), state}
  end

  ############ Private helpers ####################

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
      # Default spawn over the DevSeed 16×16 stone platform on chunk (0,0,0).
      # Movement world coords use server Z as vertical. The browser maps this
      # spawn to x=750,y=100,z=750, above DevSeed's voxel y=0 platform centered
      # at x/z = 750 in renderer units.
      position: %{"x" => 750.0, "y" => 750.0, "z" => 185.0},
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

  defp hash_password(password) do
    salt = Bcrypt.Base.gen_salt()
    hashed_password = Bcrypt.Base.hash_password(password, salt)
    {:ok, hashed_password, salt}
  end
end
