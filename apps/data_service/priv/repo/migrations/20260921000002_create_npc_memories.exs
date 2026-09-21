defmodule DataService.Repo.Migrations.CreateNpcMemories do
  use Ecto.Migration

  # NPC 的长期记忆：只存世界里查不到的东西（当前蓝图、经历）。有 key 的行是可覆盖的工作记忆，没 key 的行是只追加的经历。
  def change do
    create table(:npc_memories) do
      add :cid, :bigint, null: false
      add :kind, :string, null: false
      add :key, :string
      add :body, :map, null: false
      add :x, :float
      add :y, :float
      add :z, :float
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:npc_memories, [:cid, :kind, :key], where: "key IS NOT NULL")
    create index(:npc_memories, [:cid, :kind, :inserted_at])
  end
end
