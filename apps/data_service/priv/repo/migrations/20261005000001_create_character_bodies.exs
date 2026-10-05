defmodule DataService.Repo.Migrations.CreateCharacterBodies do
  use Ecto.Migration

  @moduledoc "Global system：角色身体完整快照与当前会话写入代次；旧 HP/SP/MP 不参与恢复。"

  def change do
    create table(:character_bodies, primary_key: false) do
      add(:cid, :bigint, primary_key: true)
      add(:owner_epoch, :bigint, null: false)
      # 新角色首次 claim 后、首次身体保存前允许空快照。
      add(:snapshot, :binary)
    end
  end
end
