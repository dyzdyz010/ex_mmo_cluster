defmodule DataService.WorkerTest do
  use ExUnit.Case, async: false

  alias DataService.Worker
  alias DataService.Schema.Account
  alias DataService.Schema.Character
  alias DataService.Repo

  setup_all do
    # Repo started in test_helper.exs
    case DataService.UidGenerator.start_link(name: DataService.UidGenerator) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    Repo.delete_all(Character)
    Repo.delete_all(Account)
    {:ok, pid} = Worker.start_link()
    %{worker: pid}
  end

  describe "register_account" do
    test "registers a new account successfully", %{worker: pid} do
      result =
        GenServer.call(
          pid,
          {:register_account, "new_player", "password123", "new@test.com", "555-0001"}
        )

      assert %Account{username: "new_player", email: "new@test.com"} = result
      assert result.id > 0
      # Should be hashed
      assert result.password != "password123"
    end

    test "rejects duplicate username", %{worker: pid} do
      GenServer.call(pid, {:register_account, "dup_name", "pw1", "a@test.com", "111"})
      result = GenServer.call(pid, {:register_account, "dup_name", "pw2", "b@test.com", "222"})
      assert {:err, {:duplicate, [:username]}} = result
    end

    test "rejects duplicate email", %{worker: pid} do
      GenServer.call(pid, {:register_account, "user1", "pw1", "same@test.com", "111"})
      result = GenServer.call(pid, {:register_account, "user2", "pw2", "same@test.com", "222"})
      assert {:err, {:duplicate, [:email]}} = result
    end

    test "detects multiple duplicates at once", %{worker: pid} do
      GenServer.call(pid, {:register_account, "multi_dup", "pw1", "multi@test.com", "333"})

      result =
        GenServer.call(pid, {:register_account, "multi_dup", "pw2", "multi@test.com", "444"})

      assert {:err, {:duplicate, dups}} = result
      assert :username in dups
      assert :email in dups
    end

    test "hashes password with bcrypt", %{worker: pid} do
      result =
        GenServer.call(
          pid,
          {:register_account, "hash_test", "mypassword", "hash@test.com", "555"}
        )

      assert %Account{} = result
      assert String.starts_with?(result.password, "$2b$")
      assert result.salt != nil
    end
  end

  describe "account_by_email" do
    test "finds account by email", %{worker: pid} do
      GenServer.call(pid, {:register_account, "finder", "pw", "find@test.com", "666"})
      {:ok, account} = GenServer.call(pid, {:account_by_email, "find@test.com"})
      assert account.username == "finder"
    end

    test "returns nil for non-existent email", %{worker: pid} do
      {:ok, account} = GenServer.call(pid, {:account_by_email, "nobody@test.com"})
      assert account == nil
    end
  end

  describe "account and character ownership lookups" do
    test "finds account by username", %{worker: pid} do
      GenServer.call(pid, {:register_account, "lookup_user", "pw", "lookup@test.com", "999"})

      {:ok, account} = GenServer.call(pid, {:account_by_username, "lookup_user"})
      assert account.username == "lookup_user"
    end

    test "returns nil when username does not exist", %{worker: pid} do
      {:ok, account} = GenServer.call(pid, {:account_by_username, "missing_user"})
      assert account == nil
    end

    test "finds character owned by account", %{worker: pid} do
      account = GenServer.call(pid, {:register_account, "owner", "pw", "owner@test.com", "123"})

      {:ok, _character} =
        Repo.insert(%Character{
          id: 9001,
          account: account.id,
          name: "OwnerHero"
        })

      {:ok, character} = GenServer.call(pid, {:character_owned_by_account, account.id, 9001})
      assert character.name == "OwnerHero"
    end

    test "returns nil when character does not belong to account", %{worker: pid} do
      owner = GenServer.call(pid, {:register_account, "owner2", "pw", "owner2@test.com", "321"})
      other = GenServer.call(pid, {:register_account, "other2", "pw", "other2@test.com", "654"})

      {:ok, _character} =
        Repo.insert(%Character{
          id: 9002,
          account: other.id,
          name: "OtherHero"
        })

      {:ok, character} = GenServer.call(pid, {:character_owned_by_account, owner.id, 9002})
      assert character == nil
    end
  end
end
