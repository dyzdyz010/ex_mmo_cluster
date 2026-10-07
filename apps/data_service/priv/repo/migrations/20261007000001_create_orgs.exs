defmodule DataService.Repo.Migrations.CreateOrgs do
  use Ecto.Migration

  # 阵营 P1（Voxim Docs/Factions.md §2、§3）：国家与公会同表，公会挂在一个国家下或无国家。
  # 角色主链每层最多一个，所以直接放 characters 两列，不建成员关联表。
  def change do
    create table(:orgs) do
      add :kind, :string, null: false
      add :name, :string, null: false
      add :nation_id, references(:orgs, on_delete: :restrict)

      timestamps()
    end

    create unique_index(:orgs, [:name])
    create constraint(:orgs, :org_kind, check: "kind IN ('nation', 'guild')")
    create constraint(:orgs, :nation_has_no_nation, check: "kind = 'guild' OR nation_id IS NULL")

    # 组织对组织的立场：锁定条目（战争、盟约）下级不能覆盖。
    create table(:org_standings, primary_key: false) do
      add :from_org_id, references(:orgs, on_delete: :delete_all), primary_key: true
      add :to_org_id, references(:orgs, on_delete: :delete_all), primary_key: true
      add :relation, :string, null: false
      add :locked, :boolean, null: false, default: false
      add :source, :string, null: false

      timestamps()
    end

    create constraint(:org_standings, :standing_relation,
             check: "relation IN ('friendly', 'neutral', 'hostile')"
           )

    alter table(:characters) do
      add :guild_id, references(:orgs, on_delete: :nilify_all)
      add :nation_id, references(:orgs, on_delete: :nilify_all)
    end
  end
end
