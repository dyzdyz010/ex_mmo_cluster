defmodule Mix.Tasks.MigrateToPg do
  @moduledoc """
  Migrate data from Mnesia to PostgreSQL.

  Reads all User.Account and User.Character records from Mnesia
  and inserts them into PostgreSQL via Ecto, skipping duplicates.

  ## Usage

      mix migrate_to_pg

  Requires both Mnesia and PostgreSQL to be running.
  """

  use Mix.Task
  require Logger

  alias DataInit.TableDef.User
  alias DataService.Schema.Account
  alias DataService.Schema.Character
  alias DataService.Repo

  @shortdoc "Migrate Mnesia data to PostgreSQL"
  def run(_args) do
    Mix.Task.run("app.start")

    Logger.info("Starting Mnesia → PostgreSQL migration...")

    {acc_ok, acc_skip} = migrate_accounts()
    Logger.info("Accounts: #{acc_ok} inserted, #{acc_skip} skipped (already exist)")

    {char_ok, char_skip} = migrate_characters()
    Logger.info("Characters: #{char_ok} inserted, #{char_skip} skipped (already exist)")

    Logger.info("Migration complete.")
  end

  defp migrate_accounts do
    records =
      Memento.transaction!(fn ->
        Memento.Query.all(User.Account)
      end)

    Enum.reduce(records, {0, 0}, fn record, {ok, skip} ->
      case Repo.insert(
             %Account{
               id: record.id,
               username: record.username,
               password: record.password,
               salt: record.salt,
               email: record.email,
               phone: record.phone
             },
             on_conflict: :nothing
           ) do
        {:ok, %{id: nil}} -> {ok, skip + 1}
        {:ok, _} -> {ok + 1, skip}
        {:error, _} -> {ok, skip + 1}
      end
    end)
  end

  defp migrate_characters do
    records =
      Memento.transaction!(fn ->
        Memento.Query.all(User.Character)
      end)

    Enum.reduce(records, {0, 0}, fn record, {ok, skip} ->
      position =
        case record.position do
          {x, y, z} -> %{"x" => x, "y" => y, "z" => z}
          map when is_map(map) -> map
          _ -> nil
        end

      case Repo.insert(
             %Character{
               id: record.id,
               account: record.account,
               name: record.name,
               title: record.title,
               base_attrs: record.base_attrs,
               battle_attrs: record.battle_attrs,
               position: position,
               hp: record.hp,
               sp: record.sp,
               mp: record.mp
             },
             on_conflict: :nothing
           ) do
        {:ok, %{id: nil}} -> {ok, skip + 1}
        {:ok, _} -> {ok + 1, skip}
        {:error, _} -> {ok, skip + 1}
      end
    end)
  end
end
