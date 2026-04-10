defmodule AuthServer.AuthWorkerTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.Account
  alias DataService.Schema.Character

  setup_all do
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)

    repo_config = DataService.Repo.config()

    case Ecto.Adapters.Postgres.storage_up(repo_config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    case DataService.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    migrations_path = Path.expand("../../../../data_service/priv/repo/migrations", __DIR__)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    case DataService.DispatcherSup.start_link(name: DataService.DispatcherSup) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    case DataService.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case DataService.DispatcherSup.start_link(name: DataService.DispatcherSup) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Repo.delete_all(Character)
    Repo.delete_all(Account)
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

  test "authorize_character accepts a cid owned by the resolved account" do
    {:ok, _account} =
      Repo.insert(%Account{id: 101, username: "player1", password: "pw", salt: "salt"})

    {:ok, _character} =
      Repo.insert(%Character{id: 201, account: 101, name: "PilotOne"})

    claims = %{"username" => "player1"}

    assert :ok = AuthServer.AuthWorker.authorize_character(claims, 201)
  end

  test "authorize_character rejects a cid not owned by the resolved account" do
    {:ok, _account} =
      Repo.insert(%Account{id: 102, username: "player2", password: "pw", salt: "salt"})

    {:ok, _other_account} =
      Repo.insert(%Account{id: 103, username: "other", password: "pw", salt: "salt"})

    {:ok, _character} =
      Repo.insert(%Character{id: 202, account: 103, name: "OtherHero"})

    claims = %{"username" => "player2"}

    assert {:error, :cid_mismatch} = AuthServer.AuthWorker.authorize_character(claims, 202)
  end

  test "authorize_character reports data source unavailability" do
    sup = Process.whereis(DataService.DispatcherSup)
    assert is_pid(sup)
    Process.exit(sup, :kill)
    Process.sleep(50)

    on_exit(fn ->
      case DataService.DispatcherSup.start_link(name: DataService.DispatcherSup) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)

    claims = %{"account_id" => 101, "username" => "player1"}

    assert {:error, :data_service_unavailable} =
             AuthServer.AuthWorker.authorize_character(claims, 201)
  end
end
