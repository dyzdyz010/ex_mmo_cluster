Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)

alias DataService.Schema.Account
alias DataService.Schema.Character

repo = DataService.Repo
repo_config = repo.config()

voxel_tables = [
  "voxel_transaction_coordinator_snapshots",
  "voxel_chunk_pending_transactions",
  "voxel_chunks",
  "voxel_scene_objects"
]

case Ecto.Adapters.Postgres.storage_up(repo_config) do
  :ok ->
    IO.puts("created database #{inspect(repo_config[:database])}")

  {:error, :already_up} ->
    IO.puts("database already exists #{inspect(repo_config[:database])}")

  {:error, reason} ->
    raise "could not create smoke database #{inspect(repo_config[:database])}: #{inspect(reason)}"
end

seed_smoke_user = fn started_repo, username, account_id, cid ->
  account =
    case started_repo.get_by(Account, username: username) do
      nil ->
        %Account{}
        |> Account.changeset(%{
          id: account_id,
          username: username,
          password: "ws-smoke-preseeded",
          salt: "ws-smoke-preseeded",
          email: "#{username}@dev.local",
          phone: "ws-smoke-#{account_id}"
        })
        |> started_repo.insert!()

      %Account{} = existing ->
        existing
    end

  character =
    case started_repo.get_by(Character, account: account.id) do
      nil ->
        %Character{}
        |> Character.changeset(%{
          id: cid,
          account: account.id,
          name: "#{username}_char",
          title: "smoke",
          base_attrs: %{},
          battle_attrs: %{},
          position: %{"x" => 1000.0, "y" => 1000.0, "z" => 100.0},
          hp: 500,
          sp: 100,
          mp: 100
        })
        |> started_repo.insert!()

      %Character{} = existing ->
        existing
    end

  IO.puts("seeded #{username} account=#{account.id} cid=#{character.id}")
end

migrations_path = Path.expand("../apps/data_service/priv/repo/migrations", __DIR__)

{:ok, _, migrated} =
  Ecto.Migrator.with_repo(repo, fn started_repo ->
    migrated = Ecto.Migrator.run(started_repo, migrations_path, :up, all: true)
    IO.puts("migrated #{length(migrated)} data_service migration(s)")

    Enum.each(voxel_tables, fn table ->
      case Ecto.Adapters.SQL.query(
             started_repo,
             "TRUNCATE TABLE #{table} RESTART IDENTITY CASCADE",
             []
           ) do
        {:ok, _result} ->
          IO.puts("truncated #{table}")

        {:error, %{postgres: %{message: message}}} ->
          IO.puts("skip #{table}: #{message}")
      end
    end)

    seed_smoke_user.(started_repo, "ws_smoke_a", 120_001, 220_001)
    seed_smoke_user.(started_repo, "ws_smoke_b", 120_002, 220_002)

    migrated
  end)

IO.puts("smoke database ready with #{length(migrated)} new migration(s)")
