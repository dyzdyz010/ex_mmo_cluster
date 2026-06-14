defmodule DataService.Repo.Migrations.AddStatusToVoxelCommandLog do
  use Ecto.Migration

  @moduledoc """
  幂等键状态机列(梯队1 step1.5b-2,AUTH-4 prefab idempotency key)。

  单方块编辑走 `CommandLog.record_once`(单条原子 INSERT,落库即 committed);多步/跨节点的
  prefab 命令走 `claim`(status='pending')→ 工作 → `confirm`(status='committed' + 缓存结果)/
  `release`(DELETE) 的 idempotency-key 形态。`status` DEFAULT 'committed' 使既有 record_once
  插入的行天然为 committed;`result_code` 复用为 prefab duplicate 重建 ack 的结果摘要。
  """

  def change do
    alter table(:voxel_command_log) do
      add(:status, :string, null: false, default: "committed")
    end

    execute(
      "ALTER TABLE voxel_command_log ADD CONSTRAINT voxel_command_log_status_valid " <>
        "CHECK (status IN ('pending', 'committed'))",
      "ALTER TABLE voxel_command_log DROP CONSTRAINT voxel_command_log_status_valid"
    )
  end
end
