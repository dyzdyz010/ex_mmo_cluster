defmodule DataService.Repo.Migrations.CreateNpcSpecs do
  use Ecto.Migration

  # 全局系统功能：NPC 注册表（docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §2）。
  # 一行 = 一个随节点启动的 NPC。身份是 characters 的 NPC 行（名字即身份，cid 不复用），角色行删掉时它的登记随之删除；
  # 大脑参数是登记时已校验的 JSON 形。位置不持久化：每次入场从 spawn 开始（与玩家出生探测同义）。
  def change do
    create table(:npc_specs, primary_key: false) do
      add :character_id, references(:characters, type: :bigint, on_delete: :delete_all),
        primary_key: true

      add :scene_id, :integer, null: false
      add :spawn, :map, null: false
      add :brain, :text, null: false
      add :params, :map, null: false
      add :enabled, :boolean, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
