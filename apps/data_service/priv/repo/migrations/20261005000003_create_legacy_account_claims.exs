defmodule DataService.Repo.Migrations.CreateLegacyAccountClaims do
  use Ecto.Migration
  # Global system: one-time migration of old invite identities; new registration never reads it.
  def change do
    create table(:auth_legacy_claims, primary_key: false) do
      add :digest, :binary, primary_key: true
      add :account_id, references(:accounts, type: :bigint), null: false
      add :consumed_at, :bigint
    end
  end
end
