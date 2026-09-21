defmodule DataService.Repo.Migrations.AddKindToCharacters do
  use Ecto.Migration

  # NPC 与玩家同表：唯一差别是 NPC 没有账号。cid 的唯一性与永不复用由主键保证。
  def change do
    alter table(:characters) do
      add :kind, :string, null: false, default: "player"
      modify :account, :bigint, null: true, from: {:bigint, null: false}
    end

    create constraint(:characters, :npc_has_no_account,
             check: "(kind = 'npc') = (account IS NULL)"
           )
  end
end
