defmodule AuthServer.AuthWorkerTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.Account
  alias DataService.Schema.Character

  defmodule FakeInterface do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, Map.new(opts), name: AuthServer.Interface)
    end

    @impl true
    def init(attrs) do
      {:ok, Map.merge(%{data_service: nil}, attrs)}
    end

    @impl true
    def handle_call(:data_service, _from, state) do
      {:reply, state.data_service, state}
    end
  end

  setup_all do
    db_available = try_start_data_service()
    {:ok, db_available: db_available}
  end

  setup %{db_available: db_available} = context do
    if Map.get(context, :requires_db, false) and db_available do
      ensure_dispatcher_sup()
      Repo.delete_all(Character)
      Repo.delete_all(Account)
    end

    :ok
  end

  test "issue_token and verify_token roundtrip claims" do
    claims = %{"username" => "player1", "source" => "ingame_login"}

    token = AuthServer.AuthWorker.issue_token(claims)

    assert is_binary(token)
    assert {:ok, ^claims} = AuthServer.AuthWorker.verify_token(token)
  end

  test "verify_token rejects invalid tokens" do
    assert {:error, :mismatch} = AuthServer.AuthWorker.verify_token("not-a-real-token")
  end

  test "build_session_claims adds session_id and preserves optional cid restrictions" do
    claims =
      AuthServer.AuthWorker.build_session_claims("player1",
        source: "ingame_login",
        cid: 42,
        allowed_cids: ["42", 43]
      )

    assert claims["username"] == "player1"
    assert claims["source"] == "ingame_login"
    assert is_binary(claims["session_id"])
    assert claims["cid"] == 42
    assert claims["allowed_cids"] == [42, 43]
  end

  test "validate_username rejects mismatched usernames" do
    claims = %{"username" => "player1"}

    assert :ok = AuthServer.AuthWorker.validate_username(claims, "player1")

    assert {:error, :username_mismatch} =
             AuthServer.AuthWorker.validate_username(claims, "player2")
  end

  test "validate_cid only rejects when claims explicitly constrain cid" do
    unrestricted = %{"username" => "player1"}
    restricted = %{"username" => "player1", "cid" => 42}
    list_restricted = %{"username" => "player1", "allowed_cids" => [42, "43"]}

    assert :ok = AuthServer.AuthWorker.validate_cid(unrestricted, 99)
    assert :ok = AuthServer.AuthWorker.validate_cid(restricted, 42)
    assert {:error, :cid_mismatch} = AuthServer.AuthWorker.validate_cid(restricted, 99)
    assert :ok = AuthServer.AuthWorker.validate_cid(list_restricted, 43)
    assert {:error, :cid_mismatch} = AuthServer.AuthWorker.validate_cid(list_restricted, 99)
  end

  @tag requires_db: true
  test "authorize_character accepts a cid owned by the resolved account", %{
    db_available: db_available
  } do
    if db_available do
      {:ok, _account} =
        Repo.insert(%Account{id: 101, username: "player1", password: "pw", salt: "salt"})

      {:ok, _character} =
        Repo.insert(%Character{id: 201, account: 101, name: "PilotOne"})

      claims = %{"username" => "player1"}

      assert :ok = AuthServer.AuthWorker.authorize_character(claims, 201)
    end
  end

  @tag requires_db: true
  test "authorize_character rejects a cid not owned by the resolved account", %{
    db_available: db_available
  } do
    if db_available do
      {:ok, _account} =
        Repo.insert(%Account{id: 102, username: "player2", password: "pw", salt: "salt"})

      {:ok, _other_account} =
        Repo.insert(%Account{id: 103, username: "other", password: "pw", salt: "salt"})

      {:ok, _character} =
        Repo.insert(%Character{id: 202, account: 103, name: "OtherHero"})

      claims = %{"username" => "player2"}

      assert {:error, :cid_mismatch} = AuthServer.AuthWorker.authorize_character(claims, 202)
    end
  end

  @tag requires_db: true
  test "authorize_character reports data source unavailability", %{db_available: db_available} do
    if db_available do
      _ = start_supervised(FakeInterface)

      claims = %{"account_id" => 101, "username" => "player1"}

      assert {:error, :data_service_unavailable} =
               AuthServer.AuthWorker.authorize_character(claims, 201)
    end
  end

  defp try_start_data_service do
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)

    repo_config = DataService.Repo.config()

    case Ecto.Adapters.Postgres.storage_up(repo_config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, _reason} -> :db_unavailable
    end
    |> case do
      :db_unavailable ->
        false

      :ok ->
        case Application.ensure_all_started(:data_service) do
          {:ok, _} -> true
          {:error, {:data_service, {:already_started, _}}} -> true
          {:error, {:already_started, _}} -> true
          {:error, {_, {{:shutdown, {:failed_to_start_child, DataService.Repo, {:already_started, _}}}, _}}} -> true
          {:error, _} -> false
        end
        |> case do
          true ->
            wait_for_process(DataService.Repo)

            case wait_for_repo() do
              :ok ->
                migrations_path = Path.expand("../../../../data_service/priv/repo/migrations", __DIR__)

                try do
                  {:ok, _, _} =
                    Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
                      Ecto.Migrator.run(repo, migrations_path, :up, all: true)
                    end)

                  true
                rescue
                  _ -> false
                end

              :db_unavailable ->
                false
            end

          false ->
            false
        end
    end
  end

  defp ensure_dispatcher_sup do
    case DataService.DispatcherSup.start_link(name: DataService.DispatcherSup) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    wait_for_process(DataService.DispatcherSup)
    wait_for_process(DataService.Dispatcher)
  end

  defp wait_for_repo(attempts \\ 10)
  defp wait_for_repo(0), do: :db_unavailable

  defp wait_for_repo(attempts) do
    case Repo.query("SELECT 1") do
      {:ok, _result} ->
        :ok

      {:error, _reason} ->
        Process.sleep(100)
        wait_for_repo(attempts - 1)
    end
  end

  defp wait_for_process(name, attempts \\ 30)
  defp wait_for_process(_name, 0), do: flunk("process did not start in time")

  defp wait_for_process(name, attempts) do
    case Process.whereis(name) do
      nil ->
        Process.sleep(10)
        wait_for_process(name, attempts - 1)

      _pid ->
        :ok
    end
  end


end
