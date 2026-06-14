defmodule DataService.Repo.Migrations.CreateVoxelCommandLog do
  use Ecto.Migration

  @moduledoc """
  Durable command replay-protection log(梯队1 step1.5,AUTH-4 / SEC-4)。

  改变 durable_authoritative 状态的权威命令以 `command_id`(全局唯一)登记一次;重复 `command_id`
  不得重复产生经济/资产/建筑/战斗副作用。`DataService.Voxel.CommandLog.record_once/2` 以
  `INSERT ... ON CONFLICT (command_id) DO NOTHING` 原子判定 fresh / duplicate;在写入事务内调用即
  与世界写入同事务,得到 exactly-once 语义。

  主键 `command_id`(string);辅以 `logical_scene_id` 便于审计/清理。
  """

  def change do
    create table(:voxel_command_log, primary_key: false) do
      add(:command_id, :string, null: false, primary_key: true)
      add(:logical_scene_id, :bigint, null: false)
      add(:result_code, :string)

      timestamps()
    end

    execute(
      "ALTER TABLE voxel_command_log ADD CONSTRAINT voxel_command_log_logical_scene_id_nonneg " <>
        "CHECK (logical_scene_id >= 0)",
      "ALTER TABLE voxel_command_log DROP CONSTRAINT voxel_command_log_logical_scene_id_nonneg"
    )

    create(index(:voxel_command_log, [:logical_scene_id]))
  end
end
