defmodule AuthServer.InviteCapacityMigrationTest do
  use ExUnit.Case, async: false
  alias DataService.Repo
  alias Ecto.Adapters.SQL
  Code.require_file("../../../data_service/test/support/database.exs", __DIR__)

  Code.require_file(
    "../../../data_service/priv/repo/migrations/20261028000001_add_invite_capacity.exs",
    __DIR__
  )

  test "legacy usage is backfilled and a lossy downgrade is rejected" do
    MmoTest.Database.start!()
    prefix = "invite_migration_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, "CREATE SCHEMA #{prefix}", [])

    try do
      # 只测试迁移：隔离 schema 中建立旧字段夹具，不修改运行中的账号真值。
      SQL.query!(Repo, "CREATE TABLE #{prefix}.accounts(id bigint PRIMARY KEY)", [])

      SQL.query!(
        Repo,
        "CREATE TABLE #{prefix}.auth_invites(id uuid PRIMARY KEY,used_by bigint REFERENCES #{prefix}.accounts(id),used_at bigint)",
        []
      )

      SQL.query!(Repo, "INSERT INTO #{prefix}.accounts VALUES(1),(2)", [])
      id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
      SQL.query!(Repo, "INSERT INTO #{prefix}.auth_invites VALUES($1,1,123)", [id])
      migration = DataService.Repo.Migrations.AddInviteCapacity
      assert :ok = Ecto.Migrator.up(Repo, 1, migration, prefix: prefix, log: false)

      assert %{rows: [[1, 1, 123]]} =
               SQL.query!(
                 Repo,
                 "SELECT i.max_uses,u.account_id,u.used_at FROM #{prefix}.auth_invites i JOIN #{prefix}.auth_invite_uses u ON u.invite_id=i.id",
                 []
               )

      assert :ok = Ecto.Migrator.down(Repo, 1, migration, prefix: prefix, log: false)

      assert %{rows: [[1, 123]]} =
               SQL.query!(Repo, "SELECT used_by,used_at FROM #{prefix}.auth_invites", [])

      assert :ok = Ecto.Migrator.up(Repo, 1, migration, prefix: prefix, log: false)
      SQL.query!(Repo, "INSERT INTO #{prefix}.auth_invite_uses VALUES($1,2,124)", [id])

      assert_raise Postgrex.Error, ~r/cannot downgrade multi-user invitation history/, fn ->
        Ecto.Migrator.down(Repo, 1, migration, prefix: prefix, log: false)
      end

      assert %{rows: [[2]]} =
               SQL.query!(Repo, "SELECT count(*) FROM #{prefix}.auth_invite_uses", [])
    after
      SQL.query!(Repo, "DROP SCHEMA #{prefix} CASCADE", [])
    end
  end
end
