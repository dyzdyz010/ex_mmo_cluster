defmodule DataService.Repo.Migrations.AddCellTickToVoxelChunks do
  use Ecto.Migration

  @moduledoc """
  Cell 时间字段(梯队1 step1.1,TIME-1)。

  为每个 chunk 增加 `cell_tick`(单调逻辑时钟)与 `sim_time_ms`(模拟时间),作为权威单位的时间轴。
  TIME-1 要求 `cell_tick` 单调递增且**所有权变更/重启不重置**;ChunkProcess 重启时从持久化值恢复
  并加保守 restart gap 以保证严格单调(逻辑时钟允许跳变,只要不回退)。

  additive,default 0:旧行兼容;不影响 `chunk_hash`(内容派生,与元数据列无关)。
  """

  def change do
    alter table(:voxel_chunks) do
      add(:cell_tick, :bigint, null: false, default: 0)
      add(:sim_time_ms, :bigint, null: false, default: 0)
    end

    for {field, name} <- [
          {"cell_tick", "voxel_chunks_cell_tick_nonneg"},
          {"sim_time_ms", "voxel_chunks_sim_time_ms_nonneg"}
        ] do
      execute(
        "ALTER TABLE voxel_chunks ADD CONSTRAINT #{name} CHECK (#{field} >= 0)",
        "ALTER TABLE voxel_chunks DROP CONSTRAINT #{name}"
      )
    end
  end
end
