defmodule DataService.Repo.Migrations.CreateCharacters do
  use Ecto.Migration

  def change do
    create table(:characters, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :account, :bigint, null: false
      add :name, :string, null: false
      add :title, :string
      add :base_attrs, :map
      add :battle_attrs, :map
      add :position, :map
      add :hp, :integer
      add :sp, :integer
      add :mp, :integer

      timestamps()
    end

    create unique_index(:characters, [:name])
    create index(:characters, [:account])
  end
end
