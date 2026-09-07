defmodule DataService.Repo.Migrations.CreateVoxelOverlayLog do
  use Ecto.Migration

  @moduledoc """
  Voxim R6 权威 overlay 日志（决策稿 §9 第 1 项）：`VoxelRegion.World` 的每笔事务按条目落一行，
  代替 `<root>/<content_version>/overlay.log` 文件。

  一行 = 一个条目：`kind` 0 = L0 `cell`（payload = 0x77 kind0 线格式，含 seq / coord / material）、
  1 = `region`（payload = 完整 VXR4 字节，seq 已盖到头里）、2 = `coarse`（payload = 粗格线格式）；
  `ordinal` 保持事务内顺序。`seq` 由 World 内存计数分配（no-op 不消耗），不是数据库序列。
  压实 = 同一事务里删掉该 content_version 全部行、写入检查点事务。查询按世界与日志顺序读取，只保留唯一索引。
  """

  def change do
    create table(:voxel_overlay_log, primary_key: false) do
      add(:content_version, :bigint, null: false)
      add(:seq, :bigint, null: false)
      add(:ordinal, :integer, null: false)
      add(:kind, :smallint, null: false)
      add(:level, :smallint, null: false)
      add(:region_x, :integer, null: false)
      add(:region_y, :integer, null: false)
      add(:region_z, :integer, null: false)
      add(:payload, :binary, null: false)
    end

    create(unique_index(:voxel_overlay_log, [:content_version, :seq, :ordinal]))
  end
end
