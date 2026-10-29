defmodule DataService.Repo.Migrations.AddInviteCapacity do
  use Ecto.Migration

  def up do
    alter table(:auth_invites) do
      add :max_uses, :integer, null: false, default: 1
    end
    create constraint(:auth_invites, :auth_invites_positive_limit, check: "max_uses > 0")
    create table(:auth_invite_uses, primary_key: false) do
      add :invite_id, references(:auth_invites, type: :uuid), null: false
      add :account_id, references(:accounts, type: :bigint), primary_key: true
      add :used_at, :bigint, null: false
    end
    create index(:auth_invite_uses, [:invite_id, :used_at, :account_id])
    execute "INSERT INTO #{schema()}.auth_invite_uses(invite_id,account_id,used_at) SELECT id,used_by,used_at FROM #{schema()}.auth_invites WHERE used_by IS NOT NULL"
    alter table(:auth_invites) do
      remove :used_by
      remove :used_at
    end
  end

  def down do
    # 多人历史无法无损还原为单人字段，拒绝破坏性降级。
    execute "DO $$ BEGIN IF EXISTS(SELECT 1 FROM #{schema()}.auth_invite_uses GROUP BY invite_id HAVING count(*) > 1) THEN RAISE EXCEPTION 'cannot downgrade multi-user invitation history'; END IF; END $$"
    alter table(:auth_invites) do
      add :used_by, references(:accounts, type: :bigint)
      add :used_at, :bigint
    end
    execute "UPDATE #{schema()}.auth_invites i SET used_by=u.account_id,used_at=u.used_at FROM #{schema()}.auth_invite_uses u WHERE i.id=u.invite_id"
    drop table(:auth_invite_uses)
    drop constraint(:auth_invites, :auth_invites_positive_limit)
    alter table(:auth_invites), do: remove(:max_uses)
  end

  defp schema, do: "\"" <> String.replace(prefix() || "public", "\"", "\"\"") <> "\""
end
