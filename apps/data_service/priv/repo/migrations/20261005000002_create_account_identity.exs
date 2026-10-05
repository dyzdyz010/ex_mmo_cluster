defmodule DataService.Repo.Migrations.CreateAccountIdentity do
  use Ecto.Migration

  def up do
    alter table(:accounts) do
      modify :password, :string, null: true
      modify :salt, :string, null: true
      add :password_hash, :text
      add :email_verified_at, :bigint
      add :disabled_at, :bigint
      add :auth_admin, :boolean, null: false, default: false
    end

    create unique_index(:accounts, ["lower(email)"], where: "password_hash IS NOT NULL", name: :accounts_login_email)
    execute "CREATE SEQUENCE auth_account_ids START WITH 4611686018427387904"
    execute "CREATE SEQUENCE auth_character_ids START WITH 4611686018427387904"

    create table(:auth_registration_policy, primary_key: false) do
      add :id, :integer, primary_key: true
      add :invite_required, :boolean, null: false
    end
    execute "INSERT INTO auth_registration_policy VALUES (1, true)"

    create table(:auth_invites, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :digest, :binary, null: false
      add :hint, :string, null: false
      add :batch, :string, null: false
      add :created_by, :string, null: false
      add :created_at, :bigint, null: false
      add :expires_at, :bigint
      add :revoked_at, :bigint
      add :deleted_at, :bigint
      add :used_by, references(:accounts, type: :bigint)
      add :used_at, :bigint
    end
    create unique_index(:auth_invites, [:digest])

    create table(:auth_challenges, primary_key: false) do
      add :email, :string, primary_key: true
      add :purpose, :string, primary_key: true
      add :digest, :binary, null: false
      add :expires_at, :bigint, null: false
      add :attempts, :integer, null: false, default: 0
    end

    create table(:auth_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :account_id, references(:accounts, type: :bigint), null: false
      add :expires_at, :bigint, null: false
      add :revoked_at, :bigint
    end
    create index(:auth_sessions, [:account_id])

    create table(:auth_tokens, primary_key: false) do
      add :digest, :binary, primary_key: true
      add :session_id, references(:auth_sessions, type: :uuid), null: false
      add :purpose, :string, null: false
      add :expires_at, :bigint, null: false
      add :consumed_at, :bigint
      add :scene_id, :bigint
      add :hello, :binary
    end
    create index(:auth_tokens, [:session_id])

    create table(:auth_audit) do
      add :actor, :string, null: false
      add :action, :string, null: false
      add :object_id, :string, null: false
      add :details, :map, null: false
      add :at, :bigint, null: false
    end
  end

  def down do
    drop table(:auth_audit)
    drop table(:auth_tokens)
    drop table(:auth_sessions)
    drop table(:auth_challenges)
    drop table(:auth_invites)
    drop table(:auth_registration_policy)
    execute "DROP SEQUENCE auth_character_ids"
    execute "DROP SEQUENCE auth_account_ids"
    drop index(:accounts, ["lower(email)"], name: :accounts_login_email)
    alter table(:accounts) do
      remove :password_hash
      remove :email_verified_at
      remove :disabled_at
      remove :auth_admin
    end
  end
end
