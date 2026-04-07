defmodule DataService.SchemaTest do
  use ExUnit.Case, async: false

  alias DataService.Schema.Account
  alias DataService.Schema.Character
  alias DataService.Repo

  setup_all do
    # Start required applications for Ecto
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Repo.start_link()
    :ok
  end

  setup do
    # Clean tables before each test
    Repo.delete_all(Character)
    Repo.delete_all(Account)
    :ok
  end

  describe "Account schema" do
    test "insert and retrieve an account" do
      account = %Account{
        id: 1001,
        username: "test_user",
        password: "hashed_pw",
        salt: "salt123",
        email: "test@example.com",
        phone: "1234567890"
      }

      {:ok, inserted} = Repo.insert(account)
      assert inserted.id == 1001
      assert inserted.username == "test_user"

      found = Repo.get(Account, 1001)
      assert found.username == "test_user"
      assert found.email == "test@example.com"
    end

    test "unique username constraint" do
      {:ok, _} =
        Repo.insert(%Account{
          id: 2001,
          username: "unique_user",
          password: "pw",
          salt: "s"
        })

      {:error, changeset} =
        Repo.insert(
          Account.changeset(%Account{}, %{
            id: 2002,
            username: "unique_user",
            password: "pw2",
            salt: "s2"
          })
        )

      assert {"has already been taken", _} = changeset.errors[:username]
    end

    test "get_by email" do
      {:ok, _} =
        Repo.insert(%Account{
          id: 3001,
          username: "email_test",
          password: "pw",
          salt: "s",
          email: "find@me.com"
        })

      found = Repo.get_by(Account, email: "find@me.com")
      assert found.id == 3001
      assert found.username == "email_test"
    end
  end

  describe "Character schema" do
    test "insert and retrieve a character" do
      {:ok, _} =
        Repo.insert(%Account{
          id: 4001,
          username: "char_owner",
          password: "pw",
          salt: "s"
        })

      character = %Character{
        id: 5001,
        account: 4001,
        name: "Hero",
        title: "Warrior",
        hp: 100,
        sp: 50,
        mp: 30,
        position: %{"x" => 100.0, "y" => 200.0, "z" => 90.0}
      }

      {:ok, inserted} = Repo.insert(character)
      assert inserted.name == "Hero"

      found = Repo.get(Character, 5001)
      assert found.account == 4001
      assert found.position["x"] == 100.0
    end
  end

  describe "check_duplicate_ecto" do
    test "returns :ok when no duplicates" do
      assert :ok == DataService.DbOps.UserAccount.check_duplicate_ecto("new_user", "new@email.com", "999")
    end

    test "detects duplicate username" do
      {:ok, _} =
        Repo.insert(%Account{
          id: 6001,
          username: "taken_name",
          password: "pw",
          salt: "s"
        })

      assert {:duplicate, [:username]} =
               DataService.DbOps.UserAccount.check_duplicate_ecto("taken_name", "other@email.com", "111")
    end

    test "detects multiple duplicates" do
      {:ok, _} =
        Repo.insert(%Account{
          id: 7001,
          username: "dup_user",
          password: "pw",
          salt: "s",
          email: "dup@email.com"
        })

      assert {:duplicate, dups} =
               DataService.DbOps.UserAccount.check_duplicate_ecto("dup_user", "dup@email.com", "222")

      assert :username in dups
      assert :email in dups
    end

    test "ignores nil and empty phone" do
      assert :ok == DataService.DbOps.UserAccount.check_duplicate_ecto("someone", "some@mail.com", nil)
      assert :ok == DataService.DbOps.UserAccount.check_duplicate_ecto("someone", "some@mail.com", "")
    end
  end
end
