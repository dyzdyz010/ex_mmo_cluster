defmodule DataService.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :username, :string, null: false
      add :password, :string, null: false
      add :salt, :string, null: false
      add :email, :string
      add :phone, :string

      timestamps()
    end

    create unique_index(:accounts, [:username])
    create unique_index(:accounts, [:email])
  end
end
